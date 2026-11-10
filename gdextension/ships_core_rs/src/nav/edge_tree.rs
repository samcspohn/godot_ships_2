//! Our guns' shot over the real island colliders, answered from per-target quadtrees over shooter positions that
//! worker threads build ahead of need, so no shot is simulated on the main thread.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock};

use godot::prelude::*;

use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2 as P;

const CELL_M: f32 = 10.0;
const TILE: i32 = 8;
const LEAF_M: f32 = 37.5;
/// Hits at or below this are the water, as the live shot ignores them.
const LAND_Y: f32 = 0.001;
const THREADS: usize = 2;

/// Greatest collider height per CELL_M square, stored only in TILE-square tiles some island reaches.
pub(crate) struct Raster {
    min_x: f32,
    min_z: f32,
    w: i32,
    h: i32,
    tw: i32,
    tiles: Vec<Option<Box<[f32]>>>,
    /// Level k: maxima over 2^k x 2^k tiles, (width, height, values).
    pyr: Vec<(i32, i32, Vec<f32>)>,
}

/// Highest point of triangle `t` over the square [x0, x1] x [z0, z1], None when they do not meet.
fn clip_max(t: &[Vector3; 3], x0: f32, x1: f32, z0: f32, z1: f32) -> Option<f32> {
    let mut poly: Vec<Vector3> = t.to_vec();
    let planes: [(usize, f32, f32); 4] = [(0, x0, 1.0), (0, x1, -1.0), (2, z0, 1.0), (2, z1, -1.0)];
    for (axis, at, sign) in planes {
        let side = |v: &Vector3| (if axis == 0 { v.x } else { v.z } - at) * sign;
        let mut out = Vec::with_capacity(poly.len() + 2);
        for i in 0..poly.len() {
            let (a, b) = (poly[i], poly[(i + 1) % poly.len()]);
            let (da, db) = (side(&a), side(&b));
            if da >= 0.0 {
                out.push(a);
            }
            if (da >= 0.0) != (db >= 0.0) {
                out.push(a + (b - a) * (da / (da - db)));
            }
        }
        poly = out;
        if poly.is_empty() {
            return None;
        }
    }
    poly.iter().map(|v| v.y).reduce(f32::max)
}

impl Raster {
    fn build(tris: &[[Vector3; 3]], min_x: f32, min_z: f32, max_x: f32, max_z: f32) -> Self {
        let w = ((max_x - min_x) / CELL_M).ceil() as i32 + 1;
        let h = ((max_z - min_z) / CELL_M).ceil() as i32 + 1;
        let (tw, th) = ((w + TILE - 1) / TILE, (h + TILE - 1) / TILE);
        let mut r = Raster { min_x, min_z, w, h, tw, tiles: (0..tw * th).map(|_| None).collect(), pyr: Vec::new() };
        for t in tris {
            if t.iter().all(|v| v.y <= LAND_Y) {
                continue;
            }
            let lo_x = t.iter().map(|v| v.x).fold(f32::INFINITY, f32::min);
            let hi_x = t.iter().map(|v| v.x).fold(f32::NEG_INFINITY, f32::max);
            let lo_z = t.iter().map(|v| v.z).fold(f32::INFINITY, f32::min);
            let hi_z = t.iter().map(|v| v.z).fold(f32::NEG_INFINITY, f32::max);
            let ix0 = (((lo_x - min_x) / CELL_M).floor() as i32).max(0);
            let ix1 = (((hi_x - min_x) / CELL_M).floor() as i32).min(w - 1);
            let iz0 = (((lo_z - min_z) / CELL_M).floor() as i32).max(0);
            let iz1 = (((hi_z - min_z) / CELL_M).floor() as i32).min(h - 1);
            for iz in iz0..=iz1 {
                for ix in ix0..=ix1 {
                    let (x0, z0) = (min_x + ix as f32 * CELL_M, min_z + iz as f32 * CELL_M);
                    if let Some(y) = clip_max(t, x0, x0 + CELL_M, z0, z0 + CELL_M).filter(|&y| y > LAND_Y) {
                        let tile = r.tiles[((iz / TILE) * tw + ix / TILE) as usize]
                            .get_or_insert_with(|| vec![0.0; (TILE * TILE) as usize].into_boxed_slice());
                        let c = &mut tile[((iz % TILE) * TILE + ix % TILE) as usize];
                        *c = c.max(y);
                    }
                }
            }
        }
        let mut level: Vec<f32> = r.tiles.iter().map(|t| t.as_ref().map_or(0.0, |t| t.iter().copied().fold(0.0, f32::max))).collect();
        let (mut lw, mut lh) = (tw, th);
        loop {
            r.pyr.push((lw, lh, level.clone()));
            if lw <= 1 && lh <= 1 {
                break;
            }
            let (nw, nh) = ((lw + 1) / 2, (lh + 1) / 2);
            let mut up = vec![0.0f32; (nw * nh) as usize];
            for z in 0..lh {
                for x in 0..lw {
                    let i = ((z / 2) * nw + x / 2) as usize;
                    up[i] = up[i].max(level[(z * lw + x) as usize]);
                }
            }
            (lw, lh, level) = (nw, nh, up);
        }
        r
    }

    /// Levels: 0 a cell, 1 a tile, k > 1 2^(k-1) tiles a side.
    fn top(&self) -> usize {
        self.pyr.len()
    }

    fn size(&self, l: usize) -> f32 {
        if l == 0 { CELL_M } else { CELL_M * TILE as f32 * (1 << (l - 1)) as f32 }
    }

    fn dims(&self, l: usize) -> (i32, i32) {
        if l == 0 { (self.w, self.h) } else { (self.pyr[l - 1].0, self.pyr[l - 1].1) }
    }

    fn max_at(&self, l: usize, bx: i32, bz: i32) -> f32 {
        if l == 0 {
            return self.tiles[((bz / TILE) * self.tw + bx / TILE) as usize]
                .as_ref().map_or(0.0, |t| t[((bz % TILE) * TILE + bx % TILE) as usize]);
        }
        let (w, _, v) = &self.pyr[l - 1];
        v[(bz * w + bx) as usize]
    }
}

/// One gun kind's shell, from its muzzle height onto a target at the waterline, tabulated by distance short of the
/// target (x'): far from an obstacle the arc only rises with range, so each (x', height) blocks the ranges below one
/// threshold; within mono_d of it, where a flat shot still falls, the arc is kept per range step.
pub(crate) struct Gun {
    v0: f64,
    beta: f64,
    vt: f64,
    tau: f64,
    gun_h: f64,
    /// Farthest answered: the gun's range, within the arc's reach.
    r_cap: f64,
    mono_d: f64,
    nx: usize,
    nd: usize,
    nh: usize,
    /// Per x' step: arc height at x' for range x' + j * DS, j = 1..=nd, and its extremes.
    near: Vec<f32>,
    near_max: Vec<f32>,
    near_min: Vec<f32>,
    /// Per x' step and height step from H_LO: least range past x' + mono_d whose arc clears it, 0 the first, INF none.
    far: Vec<f32>,
}

const XS: f64 = 20.0;
const DS: f64 = 20.0;
const DR: f64 = 10.0;
const HS: f64 = 2.0;
const H_TOP: f64 = 1200.0;

impl Gun {
    pub(crate) fn new(raw: [f64; 6]) -> Self {
        let [v0, beta, vt, tau, gun_h, cap] = raw;
        let mut g = Gun { v0, beta, vt, tau, gun_h, r_cap: 0.0, mono_d: 0.0, nx: 0, nd: 0, nh: 0, near: Vec::new(),
            near_max: Vec::new(), near_min: Vec::new(), far: Vec::new() };
        let range_of = |theta: f64| -> f64 {
            let (mut lo, mut hi) = (0.0f64, 1000.0f64);
            while g.y(theta, hi) > -gun_h && hi < 200000.0 {
                hi *= 2.0;
            }
            for _ in 0..40 {
                let mid = 0.5 * (lo + hi);
                if g.y(theta, mid) > -gun_h { lo = mid } else { hi = mid }
            }
            lo
        };
        let r_max = (1..=140).map(|d| range_of((d as f64 * 0.5).to_radians())).fold(0.0, f64::max) * 0.995;
        g.r_cap = if cap > 0.0 { cap.min(r_max) } else { r_max };
        let n_r = (g.r_cap / DR).ceil() as usize + 1;
        let thetas: Vec<f64> = (0..n_r).map(|j| g.theta(j as f64 * DR).unwrap_or(f64::NAN)).collect();
        let ym = |g: &Gun, back: f64, j: usize| -> f64 { g.y(thetas[j], j as f64 * DR - back) };
        let mut d = 0.0f64;
        let mut back = 0.0;
        while back < g.r_cap {
            let (mut prev, mut low_at) = (f64::INFINITY, back);
            let j0 = (back / DR).ceil() as usize + 1;
            for j in j0..n_r.min(j0 + 500) {
                let y = ym(&g, back, j);
                if y < prev {
                    low_at = j as f64 * DR;
                }
                prev = prev.min(y);
            }
            d = d.max(low_at - back);
            back += 100.0;
        }
        g.mono_d = d + 100.0;
        g.nx = (g.r_cap / XS).ceil() as usize + 2;
        g.nd = (g.mono_d / DS).ceil() as usize;
        g.nh = ((H_TOP - g.h_lo()) / HS).ceil() as usize + 1;
        let step = (XS / DR) as usize;
        let dstep = (DS / DR) as usize;
        g.near = vec![0.0; g.nx * g.nd];
        g.near_max = vec![f32::NEG_INFINITY; g.nx];
        g.near_min = vec![f32::INFINITY; g.nx];
        g.far = vec![f32::INFINITY; g.nx * g.nh];
        for i in 0..g.nx {
            let back = i as f64 * XS;
            for jd in 1..=g.nd {
                let j = i * step + jd * dstep;
                let y = if j < n_r { ym(&g, back, j) as f32 } else { f32::INFINITY };
                g.near[i * g.nd + jd - 1] = y;
                if y.is_finite() {
                    g.near_max[i] = g.near_max[i].max(y);
                    g.near_min[i] = g.near_min[i].min(y);
                }
            }
            let mut k = 0usize;
            let j0 = ((back + g.mono_d) / DR).ceil() as usize;
            for j in j0..n_r {
                let y = ym(&g, back, j);
                // Cleared from the first range past mono_d: nothing there is blocked.
                let r = if j == j0 { 0.0 } else { (j as f64 * DR) as f32 };
                while k < g.nh && g.h_lo() + k as f64 * HS <= y {
                    g.far[i * g.nh + k] = r;
                    k += 1;
                }
                if k >= g.nh {
                    break;
                }
            }
        }
        g
    }

    fn h_lo(&self) -> f64 {
        -self.gun_h - HS
    }

    /// The live solver's low-arc launch angle onto a target `r` away.
    fn theta(&self, r: f64) -> Option<f64> {
        if r <= 0.0 {
            return None;
        }
        let t = P::vacuum_angle(r, -self.gun_h, self.v0, false);
        if t.is_nan() {
            return None;
        }
        let t = P::newton_refine_angle(t, r, -self.gun_h, 4, self.v0, self.beta, self.vt, self.tau);
        t.is_finite().then_some(t)
    }

    /// Height above the muzzle `x` downrange.
    fn y(&self, theta: f64, x: f64) -> f64 {
        P::vertical_position(theta.sin(), P::time_from_x(x, theta, self.v0, self.beta), self.v0, self.vt, self.tau)
    }

    /// Ranges an obstacle `h` above the muzzle at `back` short of the target blocks, into `out`; the neighbouring
    /// table rows' worse answer.
    fn blocks(&self, back: f32, h: f32, out: &mut Vec<(f32, f32)>) {
        let i0 = ((back as f64 / XS) as usize).min(self.nx - 1);
        let i1 = (i0 + 1).min(self.nx - 1);
        let top = back + self.nd as f32 * DS as f32;
        if h > self.near_max[i0].max(self.near_max[i1]) {
            out.push((back, top));
        } else if h > self.near_min[i0].min(self.near_min[i1]) {
            let (r0, r1) = (&self.near[i0 * self.nd..(i0 + 1) * self.nd], &self.near[i1 * self.nd..(i1 + 1) * self.nd]);
            let mut open: Option<f32> = None;
            for j in 0..self.nd {
                let r = back + (j as f32 + 0.5) * DS as f32;
                let blocked = r0[j].min(r1[j]) < h;
                match (blocked, open) {
                    (true, None) => open = Some(if j == 0 { back } else { r }),
                    (false, Some(lo)) => {
                        out.push((lo, r));
                        open = None;
                    }
                    _ => {}
                }
            }
            if let Some(lo) = open {
                out.push((lo, top));
            }
        }
        let k = (((h as f64 - self.h_lo()) / HS).ceil().max(0.0)) as usize;
        let rb = if k >= self.nh { f32::INFINITY } else { self.far[i0 * self.nh + k].max(self.far[i1 * self.nh + k]) };
        let from = back + self.mono_d as f32;
        if rb > from {
            out.push((from, rb.min(self.r_cap as f32 + 1.0)));
        }
    }
}

impl Gun {
    /// A superset of what blocks() gives for any obstacle up to `h` above the muzzle between `s` and `end` short of the
    /// target.
    fn superset(&self, s: f32, end: f32, h: f32, out: &mut Vec<(f32, f32)>) {
        let i0 = ((s as f64 / XS) as usize).min(self.nx - 1);
        let i1 = ((end as f64 / XS).ceil() as usize + 1).min(self.nx - 1);
        if (i0..=i1).any(|i| h > self.near_min[i]) {
            out.push((s, end + self.nd as f32 * DS as f32));
        }
        let k = (((h as f64 - self.h_lo()) / HS).ceil().max(0.0)) as usize;
        let rb = if k >= self.nh { f32::INFINITY } else { (i0..=i1).map(|i| self.far[i * self.nh + k]).fold(0.0, f32::max) };
        let from = s + self.mono_d as f32;
        if rb > from {
            out.push((from, rb.min(self.r_cap as f32 + 1.0)));
        }
    }
}

impl Raster {
    /// Each land cell along `u` from `o` out to `len`: (entry distance, exit distance, height), until `f` says stop;
    /// a land block `skip` (entry, exit, its height) accepts is passed over whole.
    fn walk(&self, o: Vector2, u: Vector2, len: f32, mut skip: impl FnMut(f32, f32, f32) -> bool,
            mut f: impl FnMut(f32, f32, f32) -> bool) {
        let top = self.top();
        let (mut s, mut l) = (0.0f32, top);
        let exit = |p: f32, d: f32, lo: f32, size: f32| -> f32 {
            if d > 1e-6 { (lo + size - p) / d } else if d < -1e-6 { (lo - p) / d } else { f32::INFINITY }
        };
        'ray: while s < len {
            let p = o + u * s;
            loop {
                let size = self.size(l);
                let (bx, bz) = (((p.x - self.min_x) / size).floor() as i32, ((p.y - self.min_z) / size).floor() as i32);
                let (w, h) = self.dims(l);
                if bx < 0 || bz < 0 || bx >= w || bz >= h {
                    return;
                }
                let t = exit(p.x, u.x, self.min_x + bx as f32 * size, size).min(exit(p.y, u.y, self.min_z + bz as f32 * size, size));
                let end = (s + t.max(0.0)).min(len);
                let hmax = self.max_at(l, bx, bz);
                if hmax <= LAND_Y {
                    s = end.max(s + 0.01);
                    l = (l + 1).min(top);
                    continue 'ray;
                }
                if l == 0 {
                    if !f(s, end, hmax) {
                        return;
                    }
                    s = end.max(s + 0.01);
                    l = 1;
                    continue 'ray;
                }
                if skip(s, end, hmax) {
                    s = end.max(s + 0.01);
                    l = (l + 1).min(top);
                    continue 'ray;
                }
                l -= 1;
            }
        }
    }
}

/// Disjoint blocked ranges in order, gaps under MERGE_M closed.
#[derive(Default)]
struct Cover(Vec<(f32, f32)>);

impl Cover {
    fn insert(&mut self, lo: f32, hi: f32) {
        if hi <= lo {
            return;
        }
        let v = &mut self.0;
        let i = v.partition_point(|m| m.1 + MERGE_M < lo);
        let mut j = i;
        let (mut nlo, mut nhi) = (lo, hi);
        while j < v.len() && v[j].0 <= nhi + MERGE_M {
            nlo = nlo.min(v[j].0);
            nhi = nhi.max(v[j].1);
            j += 1;
        }
        v.splice(i..j, [(nlo, nhi)]);
    }

    fn contains(&self, lo: f32, hi: f32) -> bool {
        if hi <= lo {
            return true;
        }
        let i = self.0.partition_point(|m| m.0 <= lo);
        i > 0 && self.0[i - 1].1 >= hi
    }
}

/// One sector of bearings round a target: per bearing, the shooter ranges (whole metres) whose shot the colliders
/// stop; bearings answering alike share one list.
pub(crate) struct Sector {
    r_cap: f32,
    /// Bearings round the whole target; this sector holds n / SECTORS of them.
    n: usize,
    ray_of: Vec<u32>,
    start: Vec<u32>,
    blocked: Vec<(u16, u16)>,
}

/// One target cell's answer, its sectors built as shooters need them.
pub(crate) struct Target {
    q: Vector2,
    sectors: [OnceLock<Sector>; SECTORS],
}

const SECTORS: usize = 32;
const SAME_M: f32 = LEAF_M * 0.5;
/// Gaps closer than this are the sampling, not open water: the table steps are this coarse.
const MERGE_M: f32 = 20.0;
const STRIDE: usize = 4;
/// Prefetch only toward shooters within the gun's range of the target plus this.
const PREFETCH_SLACK_M: f32 = 4000.0;
const MAX_SECTORS: usize = 30000;
const MAX_QUEUE: usize = 4000;

type Ray = Arc<Vec<(f32, f32)>>;

fn bearing(q: Vector2, p: Vector2) -> f32 {
    let d = p - q;
    d.x.atan2(d.y).rem_euclid(std::f32::consts::TAU)
}

fn sector_of(a: f32) -> usize {
    ((a / std::f32::consts::TAU * SECTORS as f32) as usize).min(SECTORS - 1)
}

/// The shooter ranges blocked along bearing `i` of `n` round `q`.
fn ray(r: &Raster, g: &Gun, q: Vector2, n: usize, i: usize) -> Ray {
    let a = std::f32::consts::TAU * i as f32 / n as f32;
    let u = Vector2::new(a.sin(), a.cos());
    let r_cap = g.r_cap as f32;
    let end = r_cap + 1.0;
    let cover = std::cell::RefCell::new(Cover::default());
    let mut out = Vec::new();
    r.walk(q, u, r_cap, |s0, s1, hmax| {
        let mut sup = Vec::new();
        g.superset(s0, s1, hmax - g.gun_h as f32, &mut sup);
        let c = cover.borrow();
        sup.iter().all(|&(lo, hi)| c.contains(lo, hi.min(end)))
    }, |s0, s1, hmax| {
        let h = hmax - g.gun_h as f32;
        out.clear();
        g.blocks(s0, h, &mut out);
        g.blocks(s1, h, &mut out);
        let mut c = cover.borrow_mut();
        for &(lo, hi) in &out {
            c.insert(lo, hi.min(end));
        }
        // Everything past here already stopped: nothing further along adds to it.
        !c.contains(s1, end)
    });
    Arc::new(cover.into_inner().0)
}

impl Sector {
    fn build(r: &Raster, g: &Gun, q: Vector2, k: usize) -> Sector {
        let r_cap = g.r_cap as f32;
        let n = (((std::f32::consts::TAU * r_cap / LEAF_M).ceil() as usize).max(SECTORS * STRIDE)).div_ceil(SECTORS * STRIDE) * SECTORS * STRIDE;
        let m = n / SECTORS;
        let base = k * m;
        let same = |a: &Ray, b: &Ray| {
            Arc::ptr_eq(a, b) || a.len() == b.len() && a.iter().zip(b.iter()).all(|(x, y)| (x.0 - y.0).abs() < SAME_M && (x.1 - y.1).abs() < SAME_M)
        };
        let mut rays: Vec<Option<Ray>> = vec![None; m + 1];
        for i in (0..=m).step_by(STRIDE) {
            rays[i] = Some(ray(r, g, q, n, (base + i) % n));
        }
        fn fill(rays: &mut [Option<Ray>], a: usize, b: usize, get: &dyn Fn(usize) -> Ray, same: &dyn Fn(&Ray, &Ray) -> bool) {
            if b - a <= 1 {
                return;
            }
            let (ra, rb) = (rays[a].clone().unwrap(), rays[b].clone().unwrap());
            if same(&ra, &rb) {
                for k in a + 1..b {
                    rays[k] = Some(ra.clone());
                }
                return;
            }
            let mid = (a + b) / 2;
            rays[mid] = Some(get(mid));
            fill(rays, a, mid, get, same);
            fill(rays, mid, b, get, same);
        }
        let get = |i: usize| ray(r, g, q, n, (base + i) % n);
        for i in (0..m).step_by(STRIDE) {
            fill(&mut rays, i, i + STRIDE, &get, &same);
        }
        let mut ray_of = Vec::with_capacity(m);
        let mut start = vec![0u32];
        let mut blocked: Vec<(u16, u16)> = Vec::new();
        let mut last: Option<Ray> = None;
        for r in rays.into_iter().take(m) {
            let r = r.unwrap();
            if !last.as_ref().is_some_and(|l| Arc::ptr_eq(l, &r)) {
                blocked.extend(r.iter().map(|&(lo, hi)| (lo.floor().clamp(0.0, 65535.0) as u16, hi.ceil().clamp(0.0, 65535.0) as u16)));
                start.push(blocked.len() as u32);
                last = Some(r);
            }
            ray_of.push(start.len() as u32 - 2);
        }
        Sector { r_cap, n, ray_of, start, blocked }
    }

    /// Bearing `a` (in this sector, `k`) to its index here.
    fn index(&self, k: usize, a: f32) -> usize {
        let m = self.n / SECTORS;
        let i = (a / std::f32::consts::TAU * self.n as f32).round() as usize;
        i.saturating_sub(k * m).min(m - 1)
    }

    fn intervals(&self, i: usize) -> &[(u16, u16)] {
        let k = self.ray_of[i] as usize;
        &self.blocked[self.start[k] as usize..self.start[k + 1] as usize]
    }

    fn answer(&self, k: usize, a: f32, r: f32) -> bool {
        r <= self.r_cap && !self.intervals(self.index(k, a)).iter().any(|&(lo, hi)| r >= lo as f32 && r < hi as f32)
    }

    fn size(&self) -> usize {
        self.blocked.len() * 4 + self.ray_of.len() * 4 + self.start.len() * 4
    }
}

#[derive(Default)]
struct Queue {
    items: VecDeque<(i64, i32, usize)>,
    queued: HashSet<(i64, i32, usize)>,
}

/// Targets per (gun key, VisibilityGrid cell), the guns they are for, and the workers building their sectors.
pub(crate) struct EdgeTrees {
    sig: (usize, i64),
    raster: OnceLock<Raster>,
    /// Per key the shell's (v0, beta, vt, tau, gun_h, range), and its Gun once a worker has worked it out.
    guns: RwLock<HashMap<i64, Arc<([f64; 6], OnceLock<Gun>)>>>,
    targets: RwLock<HashMap<(i64, i32), Arc<Target>>>,
    queue: Mutex<Queue>,
    cv: Condvar,
    stop: AtomicBool,
    pub(crate) stats: [AtomicU64; 7],
}

/// stats: asked, answered, sectors built, build ns, bytes built, raster ms, sectors held.
pub(crate) const ST_ASKED: usize = 0;
pub(crate) const ST_ANSWERED: usize = 1;
const ST_BUILT: usize = 2;
const ST_BUILD_NS: usize = 3;
const ST_BYTES: usize = 4;
const ST_RASTER_MS: usize = 5;
const ST_HELD: usize = 6;

static EDGE: Mutex<Option<Arc<EdgeTrees>>> = Mutex::new(None);

/// The running EdgeTrees, if a map started one.
pub(crate) fn get() -> Option<Arc<EdgeTrees>> {
    EDGE.lock().unwrap().clone()
}

/// Starts the workers for this map's colliders, replacing those of another map.
pub(crate) fn start(tris: &[[Vector3; 3]], min_x: f32, min_z: f32, max_x: f32, max_z: f32) {
    let sig = (tris.len(), (min_x.to_bits() as i64) << 32 ^ max_z.to_bits() as i64);
    let mut slot = EDGE.lock().unwrap();
    if slot.as_ref().is_some_and(|e| e.sig == sig) {
        return;
    }
    if let Some(old) = slot.take() {
        old.stop.store(true, Relaxed);
        old.cv.notify_all();
    }
    let et = Arc::new(EdgeTrees {
        sig,
        raster: OnceLock::new(),
        guns: RwLock::new(HashMap::new()),
        targets: RwLock::new(HashMap::new()),
        queue: Mutex::new(Queue::default()),
        cv: Condvar::new(),
        stop: AtomicBool::new(false),
        stats: Default::default(),
    });
    *slot = Some(et.clone());
    let tris = tris.to_vec();
    let builder = et.clone();
    std::thread::Builder::new().name("edge-tree-raster".into()).spawn(move || {
        let t0 = std::time::Instant::now();
        let r = Raster::build(&tris, min_x, min_z, max_x, max_z);
        builder.stats[ST_RASTER_MS].store(t0.elapsed().as_millis() as u64, Relaxed);
        let _ = builder.raster.set(r);
        builder.cv.notify_all();
        for i in 0..THREADS {
            let w = builder.clone();
            let _ = std::thread::Builder::new().name(format!("edge-tree-{i}")).spawn(move || w.work());
        }
    }).ok();
}

impl EdgeTrees {
    pub(crate) fn register(&self, key: i64, shell: impl FnOnce() -> Option<[f64; 6]>) {
        if self.guns.read().unwrap().contains_key(&key) {
            return;
        }
        if let Some(raw) = shell() {
            self.guns.write().unwrap().entry(key).or_insert_with(|| Arc::new((raw, OnceLock::new())));
        }
    }

    fn target(&self, key: i64, cell: i32, q: Vector2) -> Arc<Target> {
        if let Some(t) = self.targets.read().unwrap().get(&(key, cell)) {
            return t.clone();
        }
        self.targets.write().unwrap().entry((key, cell))
            .or_insert_with(|| Arc::new(Target { q, sectors: std::array::from_fn(|_| OnceLock::new()) })).clone()
    }

    /// Whether a shot from `p` lands on target cell `cell` (centre `q`); None while that sector is unbuilt, which asks
    /// for it.
    pub(crate) fn answer(&self, key: i64, cell: i32, q: Vector2, p: Vector2) -> Option<bool> {
        self.stats[ST_ASKED].fetch_add(1, Relaxed);
        let a = bearing(q, p);
        let k = sector_of(a);
        if let Some(sec) = self.targets.read().unwrap().get(&(key, cell)).and_then(|t| t.sectors[k].get()) {
            self.stats[ST_ANSWERED].fetch_add(1, Relaxed);
            return Some(sec.answer(k, a, p.distance_to(q)));
        }
        self.request(key, cell, q, k, true);
        None
    }

    /// Whether `p` is within the gun's range of target cell `cell`; false while unknown.
    pub(crate) fn in_range(&self, key: i64, cell: i32, p: Vector2) -> bool {
        self.targets.read().unwrap().get(&(key, cell))
            .and_then(|t| t.sectors[sector_of(bearing(t.q, p))].get().map(|s| p.distance_to(t.q) <= s.r_cap))
            .unwrap_or(false)
    }

    /// Queues sector `k` of (key, cell): ahead of the rest when urgent.
    pub(crate) fn request(&self, key: i64, cell: i32, q: Vector2, k: usize, urgent: bool) {
        if self.target(key, cell, q).sectors[k].get().is_some() {
            return;
        }
        let item = (key, cell, k);
        let mut qu = self.queue.lock().unwrap();
        if !qu.queued.insert(item) {
            if urgent {
                if let Some(i) = qu.items.iter().position(|it| *it == item) {
                    let it = qu.items.remove(i).unwrap();
                    qu.items.push_front(it);
                }
            }
            return;
        }
        if urgent { qu.items.push_front(item) } else { qu.items.push_back(item) }
        while qu.items.len() > MAX_QUEUE {
            if let Some(old) = qu.items.pop_back() {
                qu.queued.remove(&old);
            }
        }
        drop(qu);
        self.cv.notify_one();
    }

    /// Queues the sectors of (key, cell) facing each of `shooters` within reach, and their neighbours.
    pub(crate) fn prefetch(&self, key: i64, cell: i32, q: Vector2, shooters: &[Vector2]) {
        let reach = self.guns.read().unwrap().get(&key).map_or(0.0, |g| g.0[5] as f32);
        for &p in shooters {
            if reach > 0.0 && p.distance_to(q) > reach + PREFETCH_SLACK_M {
                continue;
            }
            let k = sector_of(bearing(q, p));
            for d in [0, 1, SECTORS - 1] {
                self.request(key, cell, q, (k + d) % SECTORS, false);
            }
        }
    }

    pub(crate) fn pending(&self) -> usize {
        self.queue.lock().unwrap().items.len()
    }

    pub(crate) fn held(&self) -> usize {
        self.stats[ST_HELD].load(Relaxed) as usize
    }

    fn work(&self) {
        loop {
            let item = {
                let mut qu = self.queue.lock().unwrap();
                loop {
                    if self.stop.load(Relaxed) {
                        return;
                    }
                    if let Some(it) = qu.items.pop_front() {
                        break it;
                    }
                    qu = self.cv.wait(qu).unwrap();
                }
            };
            let (key, cell, k) = item;
            let slot = self.guns.read().unwrap().get(&key).cloned();
            let target = self.targets.read().unwrap().get(&(key, cell)).cloned();
            let (Some(r), Some(slot), Some(target)) = (self.raster.get(), slot, target) else {
                self.queue.lock().unwrap().queued.remove(&item);
                continue;
            };
            let g = slot.1.get_or_init(|| Gun::new(slot.0));
            if target.sectors[k].get().is_none() {
                let t0 = std::time::Instant::now();
                let sec = Sector::build(r, g, target.q, k);
                self.stats[ST_BUILD_NS].fetch_add(t0.elapsed().as_nanos() as u64, Relaxed);
                self.stats[ST_BUILT].fetch_add(1, Relaxed);
                self.stats[ST_BYTES].fetch_add(sec.size() as u64, Relaxed);
                if target.sectors[k].set(sec).is_ok() && self.stats[ST_HELD].fetch_add(1, Relaxed) as usize >= MAX_SECTORS {
                    let mut targets = self.targets.write().unwrap();
                    let drop: Vec<(i64, i32)> = targets.keys().take(targets.len() / 4).copied().collect();
                    for key in drop {
                        if let Some(t) = targets.remove(&key) {
                            let n = t.sectors.iter().filter(|s| s.get().is_some()).count();
                            self.stats[ST_HELD].fetch_sub(n as u64, Relaxed);
                        }
                    }
                }
            }
            self.queue.lock().unwrap().queued.remove(&item);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rule the far table rests on: past mono_d, the arc at a fixed distance short of the target rises with range.
    #[test]
    fn arc_rises_with_range_past_mono_d() {
        for &(v0, beta) in &[(762.0f64, 0.000_02f64), (850.0, 0.000_012), (900.0, 0.000_03), (600.0, 0.000_05)] {
            for &gun_h in &[8.0f64, 25.0] {
                let vt = (crate::ballistics::drag_v2::GRAVITY / beta).sqrt();
                let tau = vt / crate::ballistics::drag_v2::GRAVITY;
                let g = Gun::new([v0, beta, vt, tau, gun_h, 0.0]);
                let mut back = XS;
                while back < g.r_cap * 0.95 {
                    let mut prev = f64::NEG_INFINITY;
                    let mut r = back + g.mono_d;
                    while r < g.r_cap {
                        let Some(t) = g.theta(r) else { break };
                        let y = g.y(t, r - back);
                        assert!(y >= prev - 0.05, "v0 {v0} beta {beta} back {back} r {r}: {y} < {prev}");
                        prev = y;
                        r += 97.0;
                    }
                    back += 233.0;
                }
                eprintln!("v0 {v0} beta {beta} gun_h {gun_h}: r_cap {:.0} mono_d {:.0}", g.r_cap, g.mono_d);
            }
        }
    }
}
