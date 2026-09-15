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

/// One armour part: triangles in part space, a bounding-volume tree over them,
/// and the part's placement in ship space.
pub struct PartMesh {
    pub tris: Vec<Tri>,
    nodes: Vec<BvhNode>,
    order: Vec<u32>,
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
        let mut m = Self { tris, nodes, order, armor_type, dynamic, xform, inv: xform.affine_inverse(),
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

    fn segment_hits_box(from: V3, inv_dir: V3, tmax: f64, min: V3, max: V3) -> bool {
        let mut t0 = 0.0f64;
        let mut t1 = tmax;
        for axis in 0..3 {
            let inv = inv_dir.axis(axis);
            let o = from.axis(axis);
            let mut a = (min.axis(axis) - o) * inv;
            let mut b = (max.axis(axis) - o) * inv;
            if inv.is_infinite() {
                if o < min.axis(axis) || o > max.axis(axis) {
                    return false;
                }
                continue;
            }
            if a > b {
                std::mem::swap(&mut a, &mut b);
            }
            t0 = t0.max(a);
            t1 = t1.min(b);
            if t0 > t1 {
                return false;
            }
        }
        true
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

    /// Closest hit along the part-space segment, as (t, face).
    fn raycast_local(&self, from: V3, to: V3) -> Option<(f64, usize)> {
        if self.nodes.is_empty() {
            return None;
        }
        let dir = to.sub(from);
        let inv_dir = V3::new(1.0 / dir.x, 1.0 / dir.y, 1.0 / dir.z);
        let mut best: Option<(f64, usize)> = None;
        let mut stack = [0u32; 64];
        let mut sp: usize = 1;
        while sp > 0 {
            sp -= 1;
            let ni = stack[sp];
            let n = &self.nodes[ni as usize];
            let tmax = best.map(|b| b.0).unwrap_or(1.0);
            if !Self::segment_hits_box(from, inv_dir, tmax, n.min, n.max) {
                continue;
            }
            if n.count > 0 {
                for k in n.first..n.first + n.count {
                    let face = self.order[k as usize] as usize;
                    if let Some(t) = Self::hit_tri(&self.tris[face], from, dir) {
                        let better = match best {
                            None => true,
                            Some((bt, bf)) => t < bt || (t == bt && face < bf),
                        };
                        if better {
                            best = Some((t, face));
                        }
                    }
                }
            } else if sp + 2 <= stack.len() {
                stack[sp] = n.right;
                stack[sp + 1] = n.first;
                sp += 2;
            }
        }
        best
    }

    fn any_hit_local(&self, from: V3, to: V3) -> bool {
        self.raycast_local(from, to).is_some()
    }
}

/// Every armour part of one ship, in ship space.
#[derive(Default)]
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
            // Coincident faces of adjacent parts: the citadel boundary wins,
            // then the thicker plate, then registration order.
            let better = match &best {
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
                continue;
            }
            let tri = &part.tris[face];
            let ldir = lt.sub(lf);
            let mut n = tri.v1.sub(tri.v0).cross(tri.v2.sub(tri.v0)).normalized();
            if n.dot(ldir) > 0.0 {
                n = n.scale(-1.0);
            }
            let pos = from.add(to.sub(from).scale(t));
            let normal = V3::from_godot(part.xform.basis * n.to_godot()).normalized();
            best = Some(Hit { part: pi, face, t, pos, normal });
        }
        best
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
        let np = self.parts.len();
        let mut count = vec![0u8; np];
        let mut discovered: Vec<usize> = Vec::new();
        for d in DIRS {
            let from = p.add(d.scale(400.0));
            let mut side: Vec<(f64, usize)> = Vec::new();
            for (pi, part) in self.parts.iter().enumerate() {
                if !part.segment_reaches(from, p) {
                    continue;
                }
                let lf = self.to_part(pi, from);
                let lt = self.to_part(pi, p);
                if let Some((t, _)) = part.raycast_local(lf, lt) {
                    side.push((t, pi));
                }
            }
            if side.is_empty() {
                return None;
            }
            side.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then(a.1.cmp(&b.1)));
            for (_, pi) in side {
                count[pi] += 1;
                if !discovered.contains(&pi) {
                    discovered.push(pi);
                }
            }
        }
        let inside: Vec<usize> = discovered.into_iter().filter(|&pi| count[pi] == 6).collect();
        if let Some(&c) = inside.iter().find(|&&pi| self.is_citadel(pi)) {
            return Some(c);
        }
        inside.first().copied()
    }

    /// Whether any part is crossed by the segment; used by nothing yet but the
    /// probe.
    pub fn any_hit(&self, from: V3, to: V3) -> bool {
        self.parts.iter().enumerate().any(|(pi, part)| {
            part.any_hit_local(self.to_part(pi, from), self.to_part(pi, to))
        })
    }
}
