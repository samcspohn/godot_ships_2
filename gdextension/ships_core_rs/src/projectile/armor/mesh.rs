//! Per-ship armour geometry with its own ray queries: the narrowphase the
//! armour walk runs against, in place of a physics-server space. Plain data,
//! usable from worker threads.

use godot::prelude::*;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl V3 {
    pub const fn new(x: f64, y: f64, z: f64) -> Self { Self { x, y, z } }
    pub fn from_godot(v: Vector3) -> Self { Self::new(v.x as f64, v.y as f64, v.z as f64) }
    pub fn to_godot(self) -> Vector3 { Vector3::new(self.x as f32, self.y as f32, self.z as f32) }
    pub fn sub(self, o: V3) -> V3 { V3::new(self.x - o.x, self.y - o.y, self.z - o.z) }
    pub fn add(self, o: V3) -> V3 { V3::new(self.x + o.x, self.y + o.y, self.z + o.z) }
    pub fn scale(self, s: f64) -> V3 { V3::new(self.x * s, self.y * s, self.z * s) }
    pub fn dot(self, o: V3) -> f64 { self.x * o.x + self.y * o.y + self.z * o.z }
    pub fn cross(self, o: V3) -> V3 {
        V3::new(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)
    }
    pub fn length(self) -> f64 { self.dot(self).sqrt() }
    pub fn normalized(self) -> V3 {
        let l = self.length();
        if l > 0.0 { self.scale(1.0 / l) } else { self }
    }
    fn min(self, o: V3) -> V3 { V3::new(self.x.min(o.x), self.y.min(o.y), self.z.min(o.z)) }
    fn max(self, o: V3) -> V3 { V3::new(self.x.max(o.x), self.y.max(o.y), self.z.max(o.z)) }
    fn axis(self, i: usize) -> f64 { match i { 0 => self.x, 1 => self.y, _ => self.z } }
}

#[derive(Clone, Copy, Debug)]
pub struct Tri {
    pub v0: V3,
    pub v1: V3,
    pub v2: V3,
    pub thickness: f32,
}

#[derive(Clone, Copy, Debug)]
struct BvhNode {
    min: V3,
    max: V3,
    /// Leaf: index into `order` and count. Inner: `first` is the left child,
    /// `right` the right child, `count` is 0.
    first: u32,
    count: u32,
    right: u32,
}

const LEAF_TRIS: usize = 4;
const TIE_EPS: f64 = 1e-9;
/// Outward padding of the f32 boxes, metres: far above f32 rounding at hull scale, so a box can only be visited
/// when the exact test would skip it, never the other way round.
const BOX_PAD: f64 = 1e-3;
const EMPTY: u32 = u32::MAX;

/// Four child boxes side by side (one SIMD lane each), f32 and padded outward.
#[derive(Clone, Copy, Debug)]
struct Bvh4Node {
    lo: [[f32; 4]; 3],
    hi: [[f32; 4]; 3],
    /// Inner lane: child node index, count 0. Leaf lane: first index into `order` and its count. EMPTY: unused.
    child: [u32; 4],
    count: [u32; 4],
}

/// One binary leaf's triangles lane by lane (up to LEAF_TRIS); unused lanes are degenerate and never hit.
#[derive(Clone, Copy, Debug, Default)]
struct Leaf4 {
    v0: [[f64; 4]; 3],
    e1: [[f64; 4]; 3],
    e2: [[f64; 4]; 3],
    face: [u32; 4],
    n: u32,
}

/// Moller-Trumbore on every lane, operation for operation as hit_pre (no fused multiply-adds), so each lane's
/// `t` is bit-identical to the scalar test; NaN where a lane misses.
#[inline(always)]
fn leaf_hits_body(l: &Leaf4, from: V3, dir: V3) -> [f64; 4] {
    let mut out = [f64::NAN; 4];
    let (fx, fy, fz) = (from.x, from.y, from.z);
    let (dx, dy, dz) = (dir.x, dir.y, dir.z);
    for i in 0..4 {
        let (e1x, e1y, e1z) = (l.e1[0][i], l.e1[1][i], l.e1[2][i]);
        let (e2x, e2y, e2z) = (l.e2[0][i], l.e2[1][i], l.e2[2][i]);
        let px = dy * e2z - dz * e2y;
        let py = dz * e2x - dx * e2z;
        let pz = dx * e2y - dy * e2x;
        let det = e1x * px + e1y * py + e1z * pz;
        let inv_det = 1.0 / det;
        let sx = fx - l.v0[0][i];
        let sy = fy - l.v0[1][i];
        let sz = fz - l.v0[2][i];
        let u = (sx * px + sy * py + sz * pz) * inv_det;
        let qx = sy * e1z - sz * e1y;
        let qy = sz * e1x - sx * e1z;
        let qz = sx * e1y - sy * e1x;
        let v = (dx * qx + dy * qy + dz * qz) * inv_det;
        let t = (e2x * qx + e2y * qy + e2z * qz) * inv_det;
        let ok = det.abs() >= 1e-14 && (0.0..=1.0).contains(&u) && v >= 0.0 && u + v <= 1.0 && t > 0.0 && t <= 1.0;
        out[i] = if ok { t } else { f64::NAN };
    }
    out
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn leaf_hits_avx2(l: &Leaf4, from: V3, dir: V3) -> [f64; 4] {
    leaf_hits_body(l, from, dir)
}

#[inline(always)]
fn leaf_hits(l: &Leaf4, from: V3, dir: V3) -> [f64; 4] {
    #[cfg(target_arch = "x86_64")]
    {
        if std::arch::is_x86_feature_detected!("avx2") {
            // SAFETY: the CPU supports AVX2, checked just above.
            return unsafe { leaf_hits_avx2(l, from, dir) };
        }
    }
    leaf_hits_body(l, from, dir)
}

/// One part-space segment as the 4-wide box test wants it.
struct Ray4 {
    o: [f32; 3],
    inv: [f32; 3],
}

impl Ray4 {
    fn new(from: V3, dir: V3) -> Self {
        Ray4 { o: [from.x as f32, from.y as f32, from.z as f32],
            inv: [(1.0 / dir.x) as f32, (1.0 / dir.y) as f32, (1.0 / dir.z) as f32] }
    }

    /// Entry fraction per lane, +inf where the segment misses the box before `tmax`. NaN slabs (a zero
    /// direction component exactly on a face) are ignored, which the padding makes immaterial.
    #[inline(always)]
    fn entries(&self, n: &Bvh4Node, tmax: f32) -> [f32; 4] {
        #[cfg(target_arch = "x86_64")]
        // SAFETY: SSE is part of the x86_64 baseline; loads are unaligned-safe.
        unsafe {
            use std::arch::x86_64::*;
            let mut t0 = _mm_setzero_ps();
            let mut t1 = _mm_set1_ps(tmax);
            for a in 0..3 {
                let o = _mm_set1_ps(self.o[a]);
                let inv = _mm_set1_ps(self.inv[a]);
                let x = _mm_mul_ps(_mm_sub_ps(_mm_loadu_ps(n.lo[a].as_ptr()), o), inv);
                let y = _mm_mul_ps(_mm_sub_ps(_mm_loadu_ps(n.hi[a].as_ptr()), o), inv);
                // min/max return their second operand when either is NaN, so a NaN slab leaves t0/t1 alone.
                t0 = _mm_max_ps(_mm_min_ps(x, y), t0);
                t1 = _mm_min_ps(_mm_max_ps(x, y), t1);
            }
            let hit = _mm_cmple_ps(t0, t1);
            let r = _mm_or_ps(_mm_and_ps(hit, t0), _mm_andnot_ps(hit, _mm_set1_ps(f32::INFINITY)));
            let mut out = [0.0f32; 4];
            _mm_storeu_ps(out.as_mut_ptr(), r);
            for l in 0..4 {
                if n.child[l] == EMPTY {
                    out[l] = f32::INFINITY;
                }
            }
            out
        }
        #[cfg(not(target_arch = "x86_64"))]
        {
            let mut t0 = [0.0f32; 4];
            let mut t1 = [tmax; 4];
            for a in 0..3 {
                for l in 0..4 {
                    let x = (n.lo[a][l] - self.o[a]) * self.inv[a];
                    let y = (n.hi[a][l] - self.o[a]) * self.inv[a];
                    t0[l] = t0[l].max(x.min(y));
                    t1[l] = t1[l].min(x.max(y));
                }
            }
            let mut out = [f32::INFINITY; 4];
            for l in 0..4 {
                if t0[l] <= t1[l] && n.child[l] != EMPTY {
                    out[l] = t0[l];
                }
            }
            out
        }
    }
}

/// `t` widened so f32 rounding of the box entries cannot prune a node that holds a hit at `t`.
#[inline(always)]
fn slack(t: f64) -> f32 {
    (t * (1.0 + 1e-5) + 1e-6) as f32
}

/// One armour part: triangles in part space, a bounding-volume tree over them,
/// and the part's placement in ship space.
#[derive(Clone)]
pub struct PartMesh {
    pub tris: Vec<Tri>,
    nodes: Vec<BvhNode>,
    order: Vec<u32>,
    nodes4: Vec<Bvh4Node>,
    leaves: Vec<Leaf4>,
    pub armor_type: i32,
    pub dynamic: bool,
    pub xform: Transform3D,
    inv: Transform3D,
    /// Bounds in ship space, for skipping parts a segment cannot reach.
    ship_min: V3,
    ship_max: V3,
}

#[derive(Clone, Copy, Debug)]
pub struct Hit {
    pub part: usize,
    pub face: usize,
    /// Fraction along the segment.
    pub t: f64,
    /// Ship space. The normal faces against the ray.
    pub pos: V3,
    pub normal: V3,
}

impl PartMesh {
    pub fn new(tris: Vec<Tri>, armor_type: i32, dynamic: bool, xform: Transform3D) -> Self {
        let mut order: Vec<u32> = (0..tris.len() as u32).collect();
        let mut nodes = Vec::with_capacity(tris.len() / 2 + 1);
        if !tris.is_empty() {
            Self::build(&tris, &mut order, &mut nodes, 0, tris.len());
        }
        let mut nodes4 = Vec::new();
        let mut leaves = Vec::new();
        if !nodes.is_empty() {
            Self::collapse(&nodes, &tris, &order, &mut nodes4, &mut leaves, 0);
        }
        let mut m = Self { tris, nodes, order, nodes4, leaves, armor_type, dynamic, xform, inv: xform.affine_inverse(),
            ship_min: V3::default(), ship_max: V3::default() };
        m.update_ship_bounds();
        m
    }

    pub fn set_xform(&mut self, xform: Transform3D) {
        self.xform = xform;
        self.inv = xform.affine_inverse();
        self.update_ship_bounds();
    }

    fn update_ship_bounds(&mut self) {
        if self.nodes.is_empty() {
            return;
        }
        let (min, max) = (self.nodes[0].min, self.nodes[0].max);
        let mut smin = V3::new(f64::INFINITY, f64::INFINITY, f64::INFINITY);
        let mut smax = V3::new(f64::NEG_INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
        for i in 0..8 {
            let c = V3::new(
                if i & 1 == 0 { min.x } else { max.x },
                if i & 2 == 0 { min.y } else { max.y },
                if i & 4 == 0 { min.z } else { max.z },
            );
            let w = V3::from_godot(self.xform * c.to_godot());
            smin = smin.min(w);
            smax = smax.max(w);
        }
        self.ship_min = smin;
        self.ship_max = smax;
    }

    fn segment_reaches(&self, from: V3, to: V3) -> bool {
        let dir = to.sub(from);
        let inv_dir = V3::new(1.0 / dir.x, 1.0 / dir.y, 1.0 / dir.z);
        Self::segment_hits_box(from, inv_dir, 1.0, self.ship_min, self.ship_max)
    }

    fn bounds(tris: &[Tri], order: &[u32], lo: usize, hi: usize) -> (V3, V3) {
        let mut min = V3::new(f64::INFINITY, f64::INFINITY, f64::INFINITY);
        let mut max = V3::new(f64::NEG_INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
        for &i in &order[lo..hi] {
            let t = &tris[i as usize];
            min = min.min(t.v0).min(t.v1).min(t.v2);
            max = max.max(t.v0).max(t.v1).max(t.v2);
        }
        (min, max)
    }

    fn build(tris: &[Tri], order: &mut Vec<u32>, nodes: &mut Vec<BvhNode>, lo: usize, hi: usize) -> u32 {
        let (min, max) = Self::bounds(tris, order, lo, hi);
        let idx = nodes.len() as u32;
        nodes.push(BvhNode { min, max, first: lo as u32, count: (hi - lo) as u32, right: 0 });
        if hi - lo <= LEAF_TRIS {
            return idx;
        }
        let ext = max.sub(min);
        let axis = if ext.x >= ext.y && ext.x >= ext.z { 0 } else if ext.y >= ext.z { 1 } else { 2 };
        let centroid = |t: &Tri| (t.v0.axis(axis) + t.v1.axis(axis) + t.v2.axis(axis)) / 3.0;
        order[lo..hi].sort_by(|a, b| {
            centroid(&tris[*a as usize]).partial_cmp(&centroid(&tris[*b as usize])).unwrap()
                .then(a.cmp(b))
        });
        let mid = (lo + hi) / 2;
        let left = Self::build(tris, order, nodes, lo, mid);
        let right = Self::build(tris, order, nodes, mid, hi);
        nodes[idx as usize].first = left;
        nodes[idx as usize].right = right;
        nodes[idx as usize].count = 0;
        idx
    }

    /// The 4-wide node for binary node `bi`: its children, opened two levels down where they are inner nodes.
    fn collapse(bin: &[BvhNode], tris: &[Tri], order: &[u32], out: &mut Vec<Bvh4Node>, leaves: &mut Vec<Leaf4>, bi: usize) -> u32 {
        let idx = out.len();
        out.push(Bvh4Node { lo: [[0.0; 4]; 3], hi: [[0.0; 4]; 3], child: [EMPTY; 4], count: [0; 4] });
        let n = &bin[bi];
        let mut kids: Vec<usize> = if n.count > 0 { vec![bi] } else { vec![n.first as usize, n.right as usize] };
        while kids.len() < 4 {
            let Some(pos) = kids.iter().position(|&k| bin[k].count == 0) else { break };
            let k = kids.remove(pos);
            kids.insert(pos, bin[k].right as usize);
            kids.insert(pos, bin[k].first as usize);
        }
        for (l, &k) in kids.iter().enumerate() {
            let b = &bin[k];
            let lo = [b.min.x - BOX_PAD, b.min.y - BOX_PAD, b.min.z - BOX_PAD];
            let hi = [b.max.x + BOX_PAD, b.max.y + BOX_PAD, b.max.z + BOX_PAD];
            for a in 0..3 {
                out[idx].lo[a][l] = lo[a] as f32;
                out[idx].hi[a][l] = hi[a] as f32;
            }
            if b.count > 0 {
                let mut lf = Leaf4 { n: b.count, ..Default::default() };
                for (i, &f) in order[b.first as usize..(b.first + b.count) as usize].iter().enumerate() {
                    let t = &tris[f as usize];
                    let (e1, e2) = (t.v1.sub(t.v0), t.v2.sub(t.v0));
                    for (a, (v, (x, y))) in [(t.v0.x, (e1.x, e2.x)), (t.v0.y, (e1.y, e2.y)), (t.v0.z, (e1.z, e2.z))].into_iter().enumerate() {
                        lf.v0[a][i] = v;
                        lf.e1[a][i] = x;
                        lf.e2[a][i] = y;
                    }
                    lf.face[i] = f;
                }
                out[idx].child[l] = leaves.len() as u32;
                out[idx].count[l] = b.count;
                leaves.push(lf);
            } else {
                let c = Self::collapse(bin, tris, order, out, leaves, k);
                out[idx].child[l] = c;
            }
        }
        idx as u32
    }

    fn segment_hits_box(from: V3, inv_dir: V3, tmax: f64, min: V3, max: V3) -> bool {
        Self::box_entry(from, inv_dir, tmax, min, max).is_some()
    }

    /// Where the segment enters the box, as a fraction, if it does before `tmax`.
    fn box_entry(from: V3, inv_dir: V3, tmax: f64, min: V3, max: V3) -> Option<f64> {
        let mut t0 = 0.0f64;
        let mut t1 = tmax;
        for axis in 0..3 {
            let inv = inv_dir.axis(axis);
            let o = from.axis(axis);
            let mut a = (min.axis(axis) - o) * inv;
            let mut b = (max.axis(axis) - o) * inv;
            if inv.is_infinite() {
                if o < min.axis(axis) || o > max.axis(axis) {
                    return None;
                }
                continue;
            }
            if a > b {
                std::mem::swap(&mut a, &mut b);
            }
            t0 = t0.max(a);
            t1 = t1.min(b);
            if t0 > t1 {
                return None;
            }
        }
        Some(t0)
    }

    /// Two-sided Moller-Trumbore; `t` is the fraction of `dir`.
    fn hit_tri(tri: &Tri, from: V3, dir: V3) -> Option<f64> {
        let e1 = tri.v1.sub(tri.v0);
        let e2 = tri.v2.sub(tri.v0);
        let p = dir.cross(e2);
        let det = e1.dot(p);
        if det.abs() < 1e-14 {
            return None;
        }
        let inv_det = 1.0 / det;
        let s = from.sub(tri.v0);
        let u = s.dot(p) * inv_det;
        if !(0.0..=1.0).contains(&u) {
            return None;
        }
        let q = s.cross(e1);
        let v = dir.dot(q) * inv_det;
        if v < 0.0 || u + v > 1.0 {
            return None;
        }
        let t = e2.dot(q) * inv_det;
        if t > 0.0 && t <= 1.0 { Some(t) } else { None }
    }

    /// Closest hit along the part-space segment, as (t, face): lowest t, ties to the lowest face. 4-wide nodes,
    /// nearest child first, nodes entered beyond the best hit skipped.
    fn raycast_local(&self, from: V3, to: V3) -> Option<(f64, usize)> {
        if self.nodes4.is_empty() {
            return None;
        }
        let dir = to.sub(from);
        let ray = Ray4::new(from, dir);
        let mut best: Option<(f64, usize)> = None;
        let mut stack = [(0u32, 0.0f32); 96];
        let mut sp: usize = 1;
        while sp > 0 {
            sp -= 1;
            let (ni, entry) = stack[sp];
            let tmax = best.map_or(1.0f32 + 1e-6, |b| slack(b.0));
            if entry > tmax {
                continue;
            }
            let n = &self.nodes4[ni as usize];
            let e = ray.entries(n, tmax);
            let mut order: [usize; 4] = [0, 1, 2, 3];
            order.sort_unstable_by(|&a, &b| e[b].partial_cmp(&e[a]).unwrap_or(std::cmp::Ordering::Equal));
            // Leaves nearest first so the best hit tightens early; inner nodes pushed farthest first.
            for &l in order.iter().rev() {
                if !e[l].is_finite() || n.count[l] == 0 {
                    continue;
                }
                let lf = &self.leaves[n.child[l] as usize];
                let ts = leaf_hits(lf, from, dir);
                for i in 0..lf.n as usize {
                    let t = ts[i];
                    if t.is_nan() {
                        continue;
                    }
                    let face = lf.face[i] as usize;
                    let better = match best {
                        None => true,
                        Some((bt, bf)) => t < bt || (t == bt && face < bf),
                    };
                    if better {
                        best = Some((t, face));
                    }
                }
            }
            for &l in &order {
                if e[l].is_finite() && n.count[l] == 0 && sp < stack.len() {
                    stack[sp] = (n.child[l], e[l]);
                    sp += 1;
                }
            }
        }
        best
    }

    pub fn local_bounds(&self) -> Option<(V3, V3)> {
        self.nodes.first().map(|n| (n.min, n.max))
    }

    /// All triangles crossed, not just the closest.
    pub fn crossings(&self, from: V3, to: V3) -> u32 {
        if self.nodes.is_empty() {
            return 0;
        }
        let dir = to.sub(from);
        let inv_dir = V3::new(1.0 / dir.x, 1.0 / dir.y, 1.0 / dir.z);
        let mut n_hits = 0;
        let mut stack = [0u32; 64];
        let mut sp: usize = 1;
        while sp > 0 {
            sp -= 1;
            let n = &self.nodes[stack[sp] as usize];
            if !Self::segment_hits_box(from, inv_dir, 1.0, n.min, n.max) {
                continue;
            }
            if n.count > 0 {
                for k in n.first..n.first + n.count {
                    if Self::hit_tri(&self.tris[self.order[k as usize] as usize], from, dir).is_some() {
                        n_hits += 1;
                    }
                }
            } else if sp + 2 <= stack.len() {
                stack[sp] = n.right;
                stack[sp + 1] = n.first;
                sp += 2;
            }
        }
        n_hits
    }

    /// any_hit in the mesh's own space.
    pub fn hits(&self, from: V3, to: V3) -> bool {
        self.any_hit_local(from, to)
    }

    fn any_hit_local(&self, from: V3, to: V3) -> bool {
        if self.nodes4.is_empty() {
            return false;
        }
        let dir = to.sub(from);
        let ray = Ray4::new(from, dir);
        let mut stack = [0u32; 96];
        let mut sp: usize = 1;
        while sp > 0 {
            sp -= 1;
            let n = &self.nodes4[stack[sp] as usize];
            let e = ray.entries(n, 1.0 + 1e-6);
            for l in 0..4 {
                if !e[l].is_finite() {
                    continue;
                }
                if n.count[l] > 0 {
                    let lf = &self.leaves[n.child[l] as usize];
                    let ts = leaf_hits(lf, from, dir);
                    if ts[..lf.n as usize].iter().any(|t| !t.is_nan()) {
                        return true;
                    }
                } else if sp < stack.len() {
                    stack[sp] = n.child[l];
                    sp += 1;
                }
            }
        }
        false
    }
}

/// Every armour part of one ship, in ship space.
#[derive(Default, Clone)]
pub struct ArmorMesh {
    pub parts: Vec<PartMesh>,
}

impl ArmorMesh {
    fn to_part(&self, part: usize, p: V3) -> V3 {
        V3::from_godot(self.parts[part].inv * p.to_godot())
    }

    /// Closest hit along a ship-space segment, skipping parts flagged in `skip`.
    pub fn raycast_skip(&self, from: V3, to: V3, skip: &[bool]) -> Option<Hit> {
        let mut best: Option<Hit> = None;
        for (pi, part) in self.parts.iter().enumerate() {
            if pi < skip.len() && skip[pi] {
                continue;
            }
            if !part.segment_reaches(from, to) {
                continue;
            }
            let lf = self.to_part(pi, from);
            let lt = self.to_part(pi, to);
            let Some((t, face)) = part.raycast_local(lf, lt) else { continue };
            self.merge(&mut best, pi, t, face, from, to, lf, lt);
        }
        best
    }

    /// Keeps the nearer of `best` and part `pi`'s hit. Coincident faces of adjacent parts: the citadel
    /// boundary wins, then the thicker plate, then registration order.
    #[allow(clippy::too_many_arguments)]
    fn merge(&self, best: &mut Option<Hit>, pi: usize, t: f64, face: usize, from: V3, to: V3, lf: V3, lt: V3) {
        let part = &self.parts[pi];
        let better = match &*best {
            None => true,
            Some(b) => {
                if (t - b.t).abs() > TIE_EPS {
                    t < b.t
                } else {
                    let (ca, cb) = (part.armor_type == 1, self.parts[b.part].armor_type == 1);
                    let (ta, tb) = (part.tris[face].thickness, self.parts[b.part].tris[b.face].thickness);
                    ca && !cb || (ca == cb && (ta > tb || (ta == tb && pi < b.part)))
                }
            }
        };
        if !better {
            return;
        }
        let tri = &part.tris[face];
        let ldir = lt.sub(lf);
        let mut n = tri.v1.sub(tri.v0).cross(tri.v2.sub(tri.v0)).normalized();
        if n.dot(ldir) > 0.0 {
            n = n.scale(-1.0);
        }
        let pos = from.add(to.sub(from).scale(t));
        let normal = V3::from_godot(part.xform.basis * n.to_godot()).normalized();
        *best = Some(Hit { part: pi, face, t, pos, normal });
    }

    pub fn raycast(&self, from: V3, to: V3) -> Option<Hit> {
        self.raycast_skip(from, to, &[])
    }

    pub fn thickness(&self, part: usize, face: usize) -> f64 {
        self.parts.get(part).and_then(|p| p.tris.get(face)).map(|t| t.thickness as f64).unwrap_or(0.0)
    }

    pub fn armor_type(&self, part: usize) -> i32 {
        self.parts.get(part).map(|p| p.armor_type).unwrap_or(0)
    }

    pub fn is_citadel(&self, part: usize) -> bool {
        self.armor_type(part) == 1
    }

    pub fn is_dynamic(&self, part: usize) -> bool {
        self.parts.get(part).map(|p| p.dynamic).unwrap_or(false)
    }

    /// Which part a ship-space point is inside: the six-direction rule of
    /// PrecisionPhysicsWorld.precision_get_part_hit. A part counts when a
    /// 400 m ray from every axis direction meets it before reaching the point;
    /// citadel wins, then the first part discovered.
    pub fn part_at(&self, p: V3) -> Option<usize> {
        const DIRS: [V3; 6] = [
            V3::new(1.0, 0.0, 0.0), V3::new(-1.0, 0.0, 0.0),
            V3::new(0.0, 1.0, 0.0), V3::new(0.0, -1.0, 0.0),
            V3::new(0.0, 0.0, -1.0), V3::new(0.0, 0.0, 1.0),
        ];
        // A part hit from all six sides spans p on every axis, so only parts whose
        // bounds every side's segment reaches can count. Every one of those is hit from +x, so the first
        // discovered is the nearest from +x.
        let lp_of = |pi: usize| self.to_part(pi, p);
        let mut inside: Vec<(f64, usize)> = Vec::new();
        for (pi, part) in self.parts.iter().enumerate() {
            if part.nodes.is_empty() || !DIRS.iter().all(|d| part.segment_reaches(p.add(d.scale(400.0)), p)) {
                continue;
            }
            let lp = lp_of(pi);
            if !DIRS[1..].iter().all(|d| part.any_hit_local(self.to_part(pi, p.add(d.scale(400.0))), lp)) {
                continue;
            }
            if let Some((t, _)) = part.raycast_local(self.to_part(pi, p.add(DIRS[0].scale(400.0))), lp) {
                inside.push((t, pi));
            }
        }
        inside.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then(a.1.cmp(&b.1)));
        if let Some(&(_, c)) = inside.iter().find(|&&(_, pi)| self.is_citadel(pi)) {
            return Some(c);
        }
        inside.first().map(|&(_, pi)| pi)
    }

    /// Whether any part is crossed by the segment; used by nothing yet but the
    /// probe.
    pub fn any_hit(&self, from: V3, to: V3) -> bool {
        self.parts.iter().enumerate().any(|(pi, part)| {
            part.any_hit_local(self.to_part(pi, from), self.to_part(pi, to))
        })
    }
}
