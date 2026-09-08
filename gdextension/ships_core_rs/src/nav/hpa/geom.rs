use godot::prelude::*;

use super::{
    HpaGraph, PathBias, PATH_BIAS_MAX_STEPS_PER_SEG, PULL_BISECT_STEPS, PULL_MAX_VERTS,
    PULL_RELAX_ITERS,
};
use crate::nav::map::NavigationMap;

// True if segment (ax,az)-(bx,bz) clips any part of the AABB [x0,x1]x[z0,z1].
// Uses Liang-Barsky parametric clipping -- exact, no sqrt required.
fn segment_clips_aabb(
    ax: f32,
    az: f32,
    bx: f32,
    bz: f32,
    x0: f32,
    z0: f32,
    x1: f32,
    z1: f32,
) -> bool {
    let dx = bx - ax;
    let dz = bz - az;
    let mut t0 = 0.0f32;
    let mut t1 = 1.0f32;
    let mut clip = |p: f32, q: f32| -> bool {
        if p == 0.0 {
            return q >= 0.0;
        }
        let r = q / p;
        if p < 0.0 {
            if r > t1 {
                return false;
            }
            if r > t0 {
                t0 = r;
            }
        } else {
            if r < t0 {
                return false;
            }
            if r < t1 {
                t1 = r;
            }
        }
        true
    };
    clip(-dx, ax - x0)
        && clip(dx, x1 - ax)
        && clip(-dz, az - z0)
        && clip(dz, z1 - az)
        && t0 <= t1
}

// Exact line-of-sight on the smooth SDF, given an already-bound NavigationMap
// guard. Kept free of `&self` so hot loops (the string pull) can bind the map
// once and reuse the guard instead of re-borrowing per sample.
fn los_clear_raw(map: &NavigationMap, cell_size: f32, a: Vector2, b: Vector2, cl: f32) -> bool {
    let step = cell_size * 0.25;
    let thresh = cl + step * 0.5;
    let d = b - a;
    let len = d.length();
    if len < 1e-4 {
        return map.get_distance_impl(a.x, a.y) >= thresh;
    }
    let n = d / len;
    let mut t = 0.0f32;
    while t < len {
        let p = a + n * t;
        let sdf = map.get_distance_impl(p.x, p.y);
        if sdf < thresh {
            return false;
        }
        t += (sdf - thresh).max(step);
    }
    map.get_distance_impl(b.x, b.y) >= thresh
}

impl HpaGraph {
    /// Exact line-of-sight: sphere-traces the smooth (bilinear) SDF.
    /// NavigationMap::line_of_sight samples nearest-neighbour and is optimistic
    /// by up to half a cell diagonal, which is most of the margin once routes
    /// are planned at the hull minimum. Every place this planner *chooses* to
    /// jump a gap uses this instead.
    pub(crate) fn los_clear(&self, a: Vector2, b: Vector2, cl: f32) -> bool {
        let map = self.nav_map.as_ref().unwrap().bind();
        los_clear_raw(&map, self.cell_size, a, b, cl)
    }

    /// True when segment a-b clips no threat-blocked cluster AABB. `active`
    /// short-circuits to true when no threat layer is in play.
    pub(crate) fn segment_threat_clear(&self, a: Vector2, b: Vector2, active: bool) -> bool {
        if !active {
            return true;
        }
        let hc = self.cell_size * 0.5;
        for &cid in &self.threat_blocked_cids {
            let cl = &self.clusters[cid as usize];
            let (wx0, wz0) = self.grid_to_world(cl.x0, cl.z0);
            let (wx1, wz1) = self.grid_to_world(cl.x1, cl.z1);
            if segment_clips_aabb(a.x, a.y, b.x, b.y, wx0 - hc, wz0 - hc, wx1 + hc, wz1 + hc) {
                return false;
            }
        }
        true
    }

    /// Coastline-hugging string pull. `hard_cl` is the passability floor the
    /// input already satisfies and the output may never breach; `hug_cl` is the
    /// preferred stand-off the pull aims for and falls back from.
    ///
    /// Re-derives corners from the terrain in four steps:
    ///   1. Tangent sweep: from the anchor, find the farthest visible route
    ///      point, then bisect the next segment for the last point still
    ///      visible -- a real tangent, not a cluster centre.
    ///   2. Subdivide, so step 3 has vertices along the long straights the
    ///      sweep leaves behind.
    ///   3. Relax: each interior vertex slides toward the chord between its
    ///      neighbours as far as line-of-sight allows.
    ///   4. Sweep again to drop vertices step 3 made redundant.
    ///
    /// Homotopy is preserved by construction -- a vertex only moves to a
    /// position whose two legs are both clear, and the sweep only ever
    /// shortcuts along segments of the route it was given.
    pub(crate) fn hug_string_pull(
        &self,
        input: &[Vector2],
        hard_cl: f32,
        hug_cl: f32,
        threat_active: bool,
    ) -> Vec<Vector2> {
        if input.len() < 3 {
            return input.to_vec();
        }

        // Bind once: los_clear and this pass are both called in tight loops.
        let map = self.nav_map.as_ref().unwrap().bind();

        // Terrain + threat visibility, the single predicate the whole pass runs on.
        let clear = |a: Vector2, b: Vector2, cl: f32| -> bool {
            los_clear_raw(&map, self.cell_size, a, b, cl)
                && self.segment_threat_clear(a, b, threat_active)
        };

        let merge_eps = self.cell_size * 0.1;

        // -- Steps 1 & 4: tangent sweep --
        let sweep_pass = |src: &[Vector2]| -> Vec<Vector2> {
            let n = src.len() as i32;
            let mut out: Vec<Vector2> = Vec::with_capacity(src.len());
            out.push(src[0]);

            let mut i: i32 = 0;
            while i + 1 < n {
                let a_anchor = *out.last().unwrap();

                // Farthest route point the anchor can still see. Two tiers:
                // preferred stand-off first; if nothing ahead is reachable at
                // hug_cl, retry at the passability floor. That second scan
                // cannot fail because the input route already satisfies
                // hard_cl throughout, so t = i + 1 is always reachable.
                let mut j: i32 = -1;
                let mut use_cl = hug_cl;
                for t in (i + 1..n).rev() {
                    if clear(a_anchor, src[t as usize], hug_cl) {
                        j = t;
                        break;
                    }
                }
                if j < 0 && hug_cl > hard_cl {
                    use_cl = hard_cl;
                    for t in (i + 1..n).rev() {
                        if clear(a_anchor, src[t as usize], hard_cl) {
                            j = t;
                            break;
                        }
                    }
                }

                if j < 0 {
                    // Belt-and-braces: the input route itself fails its own
                    // floor. Copy its next vertex rather than inventing one.
                    out.push(src[(i + 1) as usize]);
                    i += 1;
                    continue;
                }
                if j >= n - 1 {
                    break; // goal is visible -- appended below
                }

                // src[j + 1] is hidden from the anchor. Bisect src[j] -> src[j+1]
                // for the last point that is not: the ray that just grazes the
                // obstacle, validated at whichever tier found j.
                let mut lo = 0.0f32;
                let mut hi = 1.0f32;
                for _ in 0..PULL_BISECT_STEPS {
                    let mid = (lo + hi) * 0.5;
                    if clear(a_anchor, src[j as usize].lerp(src[(j + 1) as usize], mid), use_cl) {
                        lo = mid;
                    } else {
                        hi = mid;
                    }
                }
                let p = src[j as usize].lerp(src[(j + 1) as usize], lo);

                // P collapses onto the anchor only when the anchor already sits
                // on src[j]; advancing i is then the whole of this iteration's work.
                if out.last().unwrap().distance_to(p) > merge_eps {
                    out.push(p);
                }
                i = j;

                if out.len() as i32 >= PULL_MAX_VERTS {
                    // Ceiling hit -- keep the remaining route verbatim so the
                    // result is still a valid path, just a less pretty one.
                    for k in (i + 1)..(n - 1) {
                        out.push(src[k as usize]);
                    }
                    break;
                }
            }

            if out.last().unwrap().distance_to(src[(n - 1) as usize]) > merge_eps {
                out.push(src[(n - 1) as usize]);
            }
            out
        };

        // -- Step 2: subdivide --
        let subdivide = |src: &[Vector2], spacing: f32| -> Vec<Vector2> {
            let mut out: Vec<Vector2> = Vec::with_capacity(src.len() * 2);
            out.push(src[0]);
            for k in 1..src.len() {
                let budget = PULL_MAX_VERTS - out.len() as i32;
                let splits = if spacing > 0.0 {
                    (src[k - 1].distance_to(src[k]) / spacing) as i32
                } else {
                    0
                };
                let splits = splits.min(budget).max(0);
                for sp in 1..=splits {
                    out.push(src[k - 1].lerp(src[k], sp as f32 / (splits + 1) as f32));
                }
                out.push(src[k]);
            }
            out
        };

        // -- Step 3: relax --
        // One sweep over the interior vertices; returns true if any of them moved.
        let relax_once = |p: &mut Vec<Vector2>| -> bool {
            let mut moved = false;
            for k in 1..p.len() - 1 {
                let u = p[k - 1];
                let v = p[k];
                let w = p[k + 1];

                let chord = w - u;
                let l2 = chord.length_squared();
                if l2 < 1e-6 {
                    continue;
                }

                // Foot of V on the chord -- where this vertex would sit if
                // nothing were in the way.
                let t = ((v - u).dot(chord) / l2).min(1.0).max(0.0);
                let delta = (u + chord * t) - v;
                let travel = delta.length();
                if travel <= merge_eps {
                    continue;
                }

                // Which clearance this vertex relaxes under. One sitting in
                // open water may not come closer than the preferred stand-off;
                // one already inside it -- threading a strait, or holding a
                // cover slot against a headland -- may keep relaxing down to
                // the floor, since refusing to move it there would strand it
                // on the coarse corner this pass exists to remove.
                let v_cl = if map.get_distance_impl(v.x, v.y) >= hug_cl {
                    hug_cl
                } else {
                    hard_cl
                };

                let mut lo = 0.0f32;
                if clear(u, v + delta, v_cl) && clear(v + delta, w, v_cl) {
                    lo = 1.0; // whole detour was unnecessary
                } else {
                    let mut hi = 1.0f32;
                    for _ in 0..PULL_BISECT_STEPS {
                        let mid = (lo + hi) * 0.5;
                        let c = v + delta * mid;
                        if clear(u, c, v_cl) && clear(c, w, v_cl) {
                            lo = mid;
                        } else {
                            hi = mid;
                        }
                    }
                }

                if lo * travel <= merge_eps {
                    continue;
                }
                p[k] = v + delta * lo;
                moved = true;
            }
            moved
        };

        let mut path = sweep_pass(input);
        if path.len() < 3 {
            return path;
        }

        path = subdivide(&path, hug_cl.max(self.cell_size * 2.0));
        for _ in 0..PULL_RELAX_ITERS {
            if !relax_once(&mut path) {
                break;
            }
        }
        sweep_pass(&path)
    }

    /// Rasterise a route polyline into per-cluster and per-sub-cluster masks.
    /// Steps along each segment at half a sub-cluster so the stamped chain is
    /// contiguous. Leaves `out.active` false when there is nothing to stamp.
    pub(crate) fn build_path_bias(&self, path: &[Vector2], out: &mut PathBias) {
        out.active = false;
        if !self.built || path.len() < 2 {
            return;
        }

        out.macro_mask = vec![0u8; self.clusters.len()];
        out.sub = vec![0u8; self.sub_clusters.len()];

        // Half a sub-cluster per step: fine enough that the stamped subs form
        // an unbroken chain (a coarser stride would leave gaps the biased
        // search cannot follow), coarse enough that a 20 km route is a few
        // hundred marks.
        let step = (self.sub_size as f32 * self.cell_size * 0.5).max(1.0);

        self.mark_path_bias(path[0], out);
        for i in 0..path.len() - 1 {
            let a = path[i];
            let b = path[i + 1];
            let len = a.distance_to(b);
            if !(len > 0.0) {
                continue; // also rejects NaN
            }
            let n = ((len / step) as i32).min(PATH_BIAS_MAX_STEPS_PER_SEG);
            for s in 1..=n {
                self.mark_path_bias(a.lerp(b, s as f32 / (n + 1) as f32), out);
            }
            self.mark_path_bias(b, out);
        }

        out.active = true;
    }

    fn mark_path_bias(&self, p: Vector2, out: &mut PathBias) {
        let gx = (((p.x - self.min_x) / self.cell_size) as i32)
            .min(self.grid_w - 1)
            .max(0);
        let gz = (((p.y - self.min_z) / self.cell_size) as i32)
            .min(self.grid_h - 1)
            .max(0);
        let cid = self.cluster_id(self.cell_cx(gx), self.cell_cz(gz));
        let sid = self.sub_id(self.cell_scx(gx), self.cell_scz(gz));
        if cid >= 0 && (cid as usize) < out.macro_mask.len() {
            out.macro_mask[cid as usize] = 1;
        }
        if sid >= 0 && (sid as usize) < out.sub.len() {
            out.sub[sid as usize] = 1;
        }
    }
}
