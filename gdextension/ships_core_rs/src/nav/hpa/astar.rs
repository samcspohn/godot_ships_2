use godot::prelude::*;
use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;

use super::HpaGraph;
use crate::nav::types::waypoint_flags::WP_NONE;
use crate::nav::types::PathResult;

/// Priority-queue entry mirroring the C++ `std::tuple<float, float, int>` pushed
/// as `(f, -g, id)` into a `priority_queue<..., greater<>>`. That comparator is
/// lexicographic over all three fields — a total order — so pop order is fully
/// determined: ties on f break on -g (preferring larger g, i.e. the frontier
/// closer to the goal), and remaining ties break on the raw id. `PqEntry` in
/// `types.rs` only carries two fields, so this local type reproduces the full
/// 3-key comparator instead of dropping the middle key.
#[derive(Clone, Copy, Debug, PartialEq)]
struct AstarPq(f32, f32, i32);

impl Eq for AstarPq {}

impl Ord for AstarPq {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0
            .total_cmp(&other.0)
            .then_with(|| self.1.total_cmp(&other.1))
            .then_with(|| self.2.cmp(&other.2))
    }
}

impl PartialOrd for AstarPq {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl HpaGraph {
    /// A* over the cluster grid. Ordered cluster IDs from from_cid to to_cid
    /// inclusive, or empty if no path exists. Clusters with max_sdf < q_cl are
    /// impassable. `bias_mask` flags clusters the caller's existing route runs
    /// through; entering one costs `bias_factor` of a normal step, and the
    /// heuristic is scaled by the same factor so it stays admissible.
    pub(crate) fn cluster_astar(
        &self,
        from_cid: i32,
        to_cid: i32,
        q_cl: f32,
        bias_mask: Option<&[u8]>,
        bias_factor: f32,
    ) -> Vec<i32> {
        if from_cid == to_cid {
            return vec![from_cid];
        }
        if from_cid < 0
            || to_cid < 0
            || from_cid >= self.clusters.len() as i32
            || to_cid >= self.clusters.len() as i32
        {
            return Vec::new();
        }

        let n = self.clusters.len();
        const INF: f32 = f32::INFINITY;

        // Discounting in-corridor steps lowers the cheapest possible cost per unit
        // distance to bias_factor, so the heuristic has to come down by the same
        // factor or it stops being admissible and A* can return a non-optimal
        // route under the biased metric.
        let biased = bias_mask.map_or(false, |m| m.len() == self.clusters.len())
            && bias_factor > 0.0
            && bias_factor < 1.0;
        let h_scale = if biased { bias_factor } else { 1.0 };

        let mut g = vec![INF; n];
        let mut parent = vec![-1i32; n];
        let mut closed = vec![false; n];

        let goal_wx = self.clusters[to_cid as usize].wx_center;
        let goal_wz = self.clusters[to_cid as usize].wz_center;
        let heur = |cid: i32| -> f32 {
            let c = &self.clusters[cid as usize];
            let dx = c.wx_center - goal_wx;
            let dz = c.wz_center - goal_wz;
            (dx * dx + dz * dz).sqrt() * h_scale
        };

        // (f, -g, id): see the AstarPq doc comment above.
        let mut open: BinaryHeap<Reverse<AstarPq>> = BinaryHeap::new();

        g[from_cid as usize] = 0.0;
        open.push(Reverse(AstarPq(heur(from_cid), 0.0, from_cid)));

        while let Some(Reverse(AstarPq(_f, _ng, cur))) = open.pop() {
            let curu = cur as usize;
            if closed[curu] {
                continue;
            }
            closed[curu] = true;
            if cur == to_cid {
                break;
            }

            let cc_cx = self.clusters[curu].cx;
            let cc_cz = self.clusters[curu].cz;

            for dz in -1..=1 {
                for dx in -1..=1 {
                    if dx == 0 && dz == 0 {
                        continue;
                    }

                    let ncx = cc_cx + dx;
                    let ncz = cc_cz + dz;
                    if ncx < 0 || ncx >= self.ncx || ncz < 0 || ncz >= self.ncz {
                        continue;
                    }

                    let ncid = self.cluster_id(ncx, ncz);
                    let ncidu = ncid as usize;
                    if closed[ncidu] {
                        continue;
                    }

                    // Impassable: no navigable cell for this ship's clearance.
                    if self.clusters[ncidu].max_sdf < q_cl {
                        continue;
                    }

                    // Blocked by obstacle / threat (allow reaching the goal cluster).
                    if ncid != to_cid && self.cluster_blocked(ncid) {
                        continue;
                    }

                    // Diagonal: both cardinal neighbours must also be passable
                    // to prevent cutting through impassable corners.
                    let is_diag = dx != 0 && dz != 0;
                    if is_diag {
                        let cid_x = self.cluster_id(cc_cx + dx, cc_cz);
                        let cid_z = self.cluster_id(cc_cx, cc_cz + dz);
                        if self.clusters[cid_x as usize].max_sdf < q_cl {
                            continue;
                        }
                        if self.clusters[cid_z as usize].max_sdf < q_cl {
                            continue;
                        }
                    }

                    // Congestion averaged over the two endpoints: how much water
                    // this step actually crosses, not merely whether it may.
                    let mut step_cost = (if is_diag {
                        self.diagonal_step_cost
                    } else {
                        self.cardinal_step_cost
                    }) * 0.5
                        * (self.cluster_cost_mul(cur) + self.cluster_cost_mul(ncid));
                    if biased && bias_mask.unwrap()[ncidu] != 0 {
                        step_cost *= bias_factor;
                    }
                    let ng = g[curu] + step_cost;

                    if ng < g[ncidu] {
                        g[ncidu] = ng;
                        parent[ncidu] = cur;
                        open.push(Reverse(AstarPq(ng + heur(ncid), -ng, ncid)));
                    }
                }
            }
        }

        if g[to_cid as usize] == INF {
            return Vec::new();
        }

        let mut path = Vec::new();
        let mut c = to_cid;
        while c != -1 {
            path.push(c);
            if c == from_cid {
                break;
            }
            c = parent[c as usize];
        }
        path.reverse();
        path
    }

    /// A* over the sub-cluster grid. If `allowed_macros` is supplied, only
    /// sub-clusters whose parent_cid bit is set are passable, constraining the
    /// search to a corridor of macros along an abstract path.
    pub(crate) fn sub_cluster_astar(
        &self,
        from_sid: i32,
        to_sid: i32,
        q_cl: f32,
        allowed_macros: Option<&[u8]>,
        bias_mask: Option<&[u8]>,
        bias_factor: f32,
    ) -> Vec<i32> {
        if from_sid == to_sid {
            return vec![from_sid];
        }
        let n = self.sub_clusters.len() as i32;
        if from_sid < 0 || to_sid < 0 || from_sid >= n || to_sid >= n {
            return Vec::new();
        }

        const INF: f32 = f32::INFINITY;

        // Step costs at sub-cluster granularity — constant, no per-edge sqrt.
        let sub_card = self.sub_size as f32 * self.cell_size;
        let sub_diag = sub_card * 1.41421356237f32;

        // See cluster_astar(): the heuristic is scaled by bias_factor to stay
        // admissible against the discounted in-corridor step cost.
        let biased = bias_mask.map_or(false, |m| m.len() == self.sub_clusters.len())
            && bias_factor > 0.0
            && bias_factor < 1.0;
        let h_scale = if biased { bias_factor } else { 1.0 };

        let nu = n as usize;
        let mut g = vec![INF; nu];
        let mut parent = vec![-1i32; nu];
        let mut closed = vec![false; nu];

        let goal_wx = self.sub_clusters[to_sid as usize].wx_center;
        let goal_wz = self.sub_clusters[to_sid as usize].wz_center;
        let heur = |sid: i32| -> f32 {
            let s = &self.sub_clusters[sid as usize];
            let dx = s.wx_center - goal_wx;
            let dz = s.wz_center - goal_wz;
            (dx * dx + dz * dz).sqrt() * h_scale
        };

        let macro_allowed = |parent_cid: i32| -> bool {
            match allowed_macros {
                None => true,
                Some(m) => parent_cid >= 0 && (parent_cid as usize) < m.len() && m[parent_cid as usize] != 0,
            }
        };

        // The goal sub may legitimately lie in a non-allowed macro (e.g. start/goal
        // pinned to a coastal macro the abstract pass excluded); waive the corridor
        // rule for from_sid and to_sid only.
        let sub_passable = |sid: i32| -> bool {
            let s = &self.sub_clusters[sid as usize];
            if s.max_sdf < q_cl {
                return false;
            }
            if sid == from_sid || sid == to_sid {
                return true;
            }
            if !macro_allowed(s.parent_cid) {
                return false;
            }
            // Re-use macro-level obstacle/threat blocking. A sub inside a blocked
            // macro is blocked too — except when it's the goal sub (mirror of the
            // macro A* rule that lets the path reach a blocked goal).
            if self.cluster_blocked(s.parent_cid) {
                return false;
            }
            true
        };

        if !sub_passable(from_sid) && from_sid != to_sid {
            // from_sid impassable on its own merits (max_sdf < q_cl) — caller must
            // have picked a bad start. Bail rather than silently routing nowhere.
            return Vec::new();
        }

        // (f, -g, id) — see the tie-break note on AstarPq above.
        let mut open: BinaryHeap<Reverse<AstarPq>> = BinaryHeap::new();

        g[from_sid as usize] = 0.0;
        open.push(Reverse(AstarPq(heur(from_sid), 0.0, from_sid)));

        while let Some(Reverse(AstarPq(_f, _ng, cur))) = open.pop() {
            let curu = cur as usize;
            if closed[curu] {
                continue;
            }
            closed[curu] = true;
            if cur == to_sid {
                break;
            }

            let cs_scx = self.sub_clusters[curu].scx;
            let cs_scz = self.sub_clusters[curu].scz;

            for dz in -1..=1 {
                for dx in -1..=1 {
                    if dx == 0 && dz == 0 {
                        continue;
                    }

                    let nscx = cs_scx + dx;
                    let nscz = cs_scz + dz;
                    if nscx < 0 || nscx >= self.nsubx || nscz < 0 || nscz >= self.nsubz {
                        continue;
                    }

                    let nsid = self.sub_id(nscx, nscz);
                    let nsidu = nsid as usize;
                    if closed[nsidu] {
                        continue;
                    }
                    if !sub_passable(nsid) {
                        continue;
                    }

                    // Diagonal corner-cutting rule: both cardinal neighbours must
                    // also be passable, otherwise we'd slip through an impassable
                    // corner that the ship physically cannot fit through.
                    let is_diag = dx != 0 && dz != 0;
                    if is_diag {
                        let sid_x = self.sub_id(cs_scx + dx, cs_scz);
                        let sid_z = self.sub_id(cs_scx, cs_scz + dz);
                        if !sub_passable(sid_x) {
                            continue;
                        }
                        if !sub_passable(sid_z) {
                            continue;
                        }
                    }

                    // Same shaping as the macro layer, at sub granularity: a sub
                    // passable only through one of its sixteen cells should not
                    // price like open water.
                    let mut step_cost = (if is_diag { sub_diag } else { sub_card })
                        * 0.5
                        * (self.sub_cost_mul(cur) + self.sub_cost_mul(nsid));
                    if biased && bias_mask.unwrap()[nsidu] != 0 {
                        step_cost *= bias_factor;
                    }
                    let ng = g[curu] + step_cost;

                    if ng < g[nsidu] {
                        g[nsidu] = ng;
                        parent[nsidu] = cur;
                        open.push(Reverse(AstarPq(ng + heur(nsid), -ng, nsid)));
                    }
                }
            }
        }

        if g[to_sid as usize] == INF {
            return Vec::new();
        }

        let mut path = Vec::new();
        let mut c = to_sid;
        while c != -1 {
            path.push(c);
            if c == from_sid {
                break;
            }
            c = parent[c as usize];
        }
        path.reverse();
        path
    }

    /// Corridor-constrained cell A*, used by refinement when LOS/sub-cluster
    /// connectors cannot directly bridge a guide segment.
    pub(crate) fn constrained_cell_astar(
        &self,
        from: Vector2,
        to: Vector2,
        q_cl: f32,
        allowed_macros: &[u8],
    ) -> PathResult {
        let mut result = PathResult::default();
        result.valid = false;
        result.total_distance = 0.0;

        if !self.built || self.nav_map.is_none() {
            return result;
        }
        // Bound once; every cell_allowed() call below reuses this guard.
        let map = self.nav_map.as_ref().unwrap().bind();

        let world_to_gx = |wx: f32| -> i32 {
            (((wx - self.min_x) / self.cell_size) as i32)
                .max(0)
                .min(self.grid_w - 1)
        };
        let world_to_gz = |wz: f32| -> i32 {
            (((wz - self.min_z) / self.cell_size) as i32)
                .max(0)
                .min(self.grid_h - 1)
        };
        let idx = |gx: i32, gz: i32| -> i32 { gz * self.grid_w + gx };

        let sx = world_to_gx(from.x);
        let sz = world_to_gz(from.y);
        let ex = world_to_gx(to.x);
        let ez = world_to_gz(to.y);
        let start_idx = idx(sx, sz);
        let end_idx = idx(ex, ez);

        let macro_allowed = |cid: i32| -> bool {
            cid >= 0 && (cid as usize) < allowed_macros.len() && allowed_macros[cid as usize] != 0
        };
        let cell_allowed = |gx: i32, gz: i32| -> bool {
            if gx < 0 || gx >= self.grid_w || gz < 0 || gz >= self.grid_h {
                return false;
            }
            let cidx = idx(gx, gz);
            let cid = self.cluster_id(self.cell_cx(gx), self.cell_cz(gz));
            if cidx != start_idx && cidx != end_idx {
                if !macro_allowed(cid) {
                    return false;
                }
                if self.cluster_blocked(cid) {
                    return false;
                }
            }
            map.get_distance_impl(
                self.min_x + (gx as f32 + 0.5) * self.cell_size,
                self.min_z + (gz as f32 + 0.5) * self.cell_size,
            ) >= q_cl
        };
        let line_allowed = |x0: i32, z0: i32, x1: i32, z1: i32| -> bool {
            let dx = (x1 - x0).abs();
            let dz = (z1 - z0).abs();
            let step_x_dir = if x0 < x1 { 1 } else { -1 };
            let step_z_dir = if z0 < z1 { 1 } else { -1 };
            let mut cx = x0;
            let mut cz = z0;
            if !cell_allowed(cx, cz) {
                return false;
            }
            if dx == 0 && dz == 0 {
                return true;
            }
            let mut err = dx - dz;
            while !(cx == x1 && cz == z1) {
                let e2 = 2 * err;
                let step_x = (e2 > -dz) || (e2 == -dz && dx > 0);
                let step_z = (e2 < dx) || (e2 == dx && dz > 0);
                if step_x && step_z {
                    if !cell_allowed(cx + step_x_dir, cz) {
                        return false;
                    }
                    if !cell_allowed(cx, cz + step_z_dir) {
                        return false;
                    }
                    err -= dz;
                    err += dx;
                    cx += step_x_dir;
                    cz += step_z_dir;
                } else if step_x {
                    err -= dz;
                    cx += step_x_dir;
                } else {
                    err += dx;
                    cz += step_z_dir;
                }
                if !cell_allowed(cx, cz) {
                    return false;
                }
            }
            true
        };

        if !cell_allowed(sx, sz) || !cell_allowed(ex, ez) {
            return result;
        }

        if sx == ex && sz == ez {
            result.waypoints = vec![from, to];
            result.flags = vec![WP_NONE, WP_NONE];
            result.total_distance = from.distance_to(to);
            result.valid = true;
            return result;
        }

        if line_allowed(sx, sz, ex, ez) {
            result.waypoints = vec![from, to];
            result.flags = vec![WP_NONE, WP_NONE];
            result.total_distance = from.distance_to(to);
            result.valid = true;
            return result;
        }

        let total = (self.grid_w * self.grid_h) as usize;
        const INF: f32 = f32::INFINITY;
        let mut g = vec![INF; total];
        let mut parent = vec![-1i32; total];
        let mut closed = vec![0u8; total];

        let heur = |gx: i32, gz: i32| -> f32 {
            let dx = (gx - ex) as f32;
            let dz = (gz - ez) as f32;
            (dx * dx + dz * dz).sqrt()
        };

        // (f, -g, id) — see the tie-break note on AstarPq above.
        let mut open: BinaryHeap<Reverse<AstarPq>> = BinaryHeap::new();
        g[start_idx as usize] = 0.0;
        parent[start_idx as usize] = start_idx;
        open.push(Reverse(AstarPq(heur(sx, sz), 0.0, start_idx)));

        const DX8: [i32; 8] = [-1, 0, 1, -1, 1, -1, 0, 1];
        const DZ8: [i32; 8] = [-1, -1, -1, 0, 0, 1, 1, 1];

        while let Some(Reverse(AstarPq(_f, _ng, cur))) = open.pop() {
            let curu = cur as usize;
            if closed[curu] != 0 {
                continue;
            }
            closed[curu] = 1;
            if cur == end_idx {
                break;
            }

            let cx = cur % self.grid_w;
            let cz = cur / self.grid_w;

            for d in 0..8usize {
                let nx = cx + DX8[d];
                let nz = cz + DZ8[d];
                if !cell_allowed(nx, nz) {
                    continue;
                }
                let nidx = idx(nx, nz);
                let nidxu = nidx as usize;
                if closed[nidxu] != 0 {
                    continue;
                }

                let is_diag = DX8[d] != 0 && DZ8[d] != 0;
                if is_diag {
                    if !cell_allowed(cx + DX8[d], cz) {
                        continue;
                    }
                    if !cell_allowed(cx, cz + DZ8[d]) {
                        continue;
                    }
                }

                let step_cost = if is_diag { 1.41421356237f32 } else { 1.0f32 };
                let ng = g[curu] + step_cost;
                if ng < g[nidxu] {
                    g[nidxu] = ng;
                    parent[nidxu] = cur;
                    open.push(Reverse(AstarPq(ng + heur(nx, nz), -ng, nidx)));
                }
            }
        }

        if parent[end_idx as usize] < 0 {
            return result;
        }

        let mut raw: Vec<Vector2> = Vec::new();
        let mut cur = end_idx;
        while cur != start_idx {
            let gx = cur % self.grid_w;
            let gz = cur / self.grid_w;
            let (wx, wz) = self.grid_to_world(gx, gz);
            raw.push(Vector2::new(wx, wz));
            if parent[cur as usize] < 0 || parent[cur as usize] == cur {
                return result;
            }
            cur = parent[cur as usize];
        }
        raw.push(from);
        raw.reverse();
        if raw.len() >= 2 {
            let last = raw.len() - 1;
            raw[last] = to;
        }

        let mut simplified: Vec<Vector2> = Vec::new();
        simplified.push(raw[0]);
        let mut anchor: usize = 0;
        while anchor < raw.len() - 1 {
            let mut farthest = anchor + 1;
            let mut test = raw.len() - 1;
            while test > anchor + 1 {
                let ax = world_to_gx(raw[anchor].x);
                let az = world_to_gz(raw[anchor].y);
                let bx = world_to_gx(raw[test].x);
                let bz = world_to_gz(raw[test].y);
                // line_allowed() enforces the macro corridor but samples cells
                // nearest-neighbour; los_clear() is what makes the shortcut exact.
                if line_allowed(ax, az, bx, bz) && self.los_clear(raw[anchor], raw[test], q_cl) {
                    farthest = test;
                    break;
                }
                test -= 1;
            }
            simplified.push(raw[farthest]);
            anchor = farthest;
        }

        result.flags = vec![WP_NONE; simplified.len()];
        result.valid = simplified.len() >= 2;
        for i in 0..simplified.len().saturating_sub(1) {
            result.total_distance += simplified[i].distance_to(simplified[i + 1]);
        }
        result.waypoints = simplified;
        result
    }
}
