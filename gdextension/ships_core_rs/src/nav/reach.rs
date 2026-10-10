use godot::prelude::*;
use rayon::prelude::*;
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering::Relaxed};
use std::sync::{Arc, Mutex, OnceLock};

use crate::ballistics::drag_v2::{ProjectilePhysicsWithDragV2 as P, GRAVITY};
use crate::nav::map::NavigationMap;
use crate::nav::gun_matrix::{Cells, GunMatrix, MatrixWorker};
use crate::nav::visibility::VisibilityGrid;

// R_block(x, h): the shortest target range whose low-arc trajectory clears an
// obstacle `h` above the muzzle at `x` downrange. Height at fixed x rises
// monotonically with range on the low arc (checked numerically for every
// shell in the fleet), so an obstacle blocks exactly the ranges below this
// one number, on the ascent leg and the descent leg alike.

const X_FLOOR: f32 = 50.0;
const X_RATIO: f32 = 1.12;
const H_FLOOR: f32 = 1.0;
const H_RATIO: f32 = 1.15;
const H_MAX: f32 = 800.0;
const R_STEP: f64 = 50.0;
/// Max-height pyramid levels over the 50 m squares: the top blocks (2^9 = 25.6 km)
/// are about half the map, so a clear ray skips water and low land whole.
const PYRAMID_MAX: usize = 9;
/// Calls here are a few ms; on a 2-socket box the global pool spends longer
/// waking threads across NUMA nodes than working, with 20 ms tails.
const NAV_THREADS: usize = 16;
/// Ray answers are reused until their enemy has really moved this far.
const ORIGIN_QUANTUM_M: f32 = 500.0;
/// Answer planes held (a quarter byte per field cell each): enough for every
/// enemy's fire plus its reach per friendly gun kind, both teams, without churn.
const MAX_PLANES: usize = 1024;
const SPREAD_MIN: f32 = 150.0;
const WEIGHT_FLOOR: f32 = 0.05;
/// update_team calls between detection grid rebuilds: the router plans on it, it need not be live.
const DETECT_EVERY: u32 = 3;
const WEIGHT_STEP: f32 = 0.1;
const EXPOSURE_RADIUS_Q: f32 = 250.0;
/// Exposure is 1 at effective distance zero and keeps rising inside a
/// force-spot disc (negative distance); capped so a radar centre prices at
/// most this many times the concealment edge.
const EXPOSURE_MAX: f32 = 3.0;
/// The debug overlays evaluate every DEBUG_STRIDE-th cell and fill the block.
const DEBUG_STRIDE: i32 = 3;

static STAT_MISSES: AtomicU64 = AtomicU64::new(0);
static STAT_LOS: AtomicU64 = AtomicU64::new(0);
static STAT_RAYS: AtomicU64 = AtomicU64::new(0);
static STAT_DETECT: AtomicU64 = AtomicU64::new(0);
static PIN_IDS: AtomicU64 = AtomicU64::new(0);
static STAT_PLANES_MADE: AtomicU64 = AtomicU64::new(0);
static STAT_EVICTIONS: AtomicU64 = AtomicU64::new(0);

/// Per-query counters for diagnosing slow walks; `probe_take` returns and resets them.
#[derive(Clone, Copy, Default)]
pub(crate) struct Probe {
    pub masks: u32,
    pub misses: u32,
    pub out_of_range: u32,
    pub los: u32,
    pub rays: u32,
    pub ray_dist: f64,
    pub ray_dist_max: f32,
    pub steps: u32,
    pub land: u32,
    pub ray_ns: u64,
    pub planes_new: u32,
    pub planes_ns: u64,
    pub matrix: u32,
}

thread_local! {
    static PROBE: std::cell::Cell<Probe> = std::cell::Cell::new(Probe::default());
}

fn probe(f: impl FnOnce(&mut Probe)) {
    PROBE.with(|c| {
        let mut p = c.get();
        f(&mut p);
        c.set(p);
    });
}

pub(crate) fn probe_take() -> Probe {
    PROBE.with(|c| c.replace(Probe::default()))
}

pub(crate) fn nav_pool() -> &'static rayon::ThreadPool {
    static POOL: OnceLock<rayon::ThreadPool> = OnceLock::new();
    POOL.get_or_init(|| {
        let n = std::thread::available_parallelism().map_or(4, |n| n.get()).min(NAV_THREADS);
        rayon::ThreadPoolBuilder::new().num_threads(n).thread_name(|i| format!("nav-{i}")).build().unwrap()
    })
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct TableKey {
    v0_cm: i32,
    beta_e8: i32,
    gun_dm: i32,
    tgt_dm: i32,
    cap_m: i32,
    mirrored: bool,
}

impl TableKey {
    fn new(v0: f32, beta: f32, gun_h: f32, tgt_h: f32, cap: f32, mirrored: bool) -> Self {
        Self {
            v0_cm: (v0 * 100.0).round() as i32,
            beta_e8: (beta * 1e8).round() as i32,
            gun_dm: (gun_h * 10.0).round() as i32,
            tgt_dm: (tgt_h * 10.0).round() as i32,
            cap_m: cap.round() as i32,
            mirrored,
        }
    }
}

pub struct RBlockTable {
    x_centres: Vec<f32>,
    h_edges: Vec<f32>,
    /// x-major, `nx * (nh + 1)`; INFINITY when the cap never clears.
    r: Vec<f32>,
    nx: usize,
    nh1: usize,
    /// Lower bucket per X_IDX_M / H_IDX_M of x and h, so lookup is O(1).
    x_idx: Vec<u16>,
    h_idx: Vec<u16>,
    pub cap: f32,
    /// `arc_row(j * R_STEP)` per j, nx each: the arc profiles segment_clear reads.
    arcs: Vec<f32>,
}

const X_IDX_M: f32 = 25.0;
const H_IDX_M: f32 = 1.0;

fn dense_index(edges: &[f32], quantum: f32, top: f32) -> Vec<u16> {
    let n = (top / quantum).ceil() as usize + 1;
    (0..=n)
        .map(|q| {
            let v = q as f32 * quantum;
            (edges.partition_point(|&e| e <= v).saturating_sub(1)).min(edges.len() - 2) as u16
        })
        .collect()
}

fn geometric(floor: f32, ratio: f32, top: f32) -> Vec<f32> {
    let mut v = vec![0.0f32, floor];
    while *v.last().unwrap() < top {
        let next = v.last().unwrap() * ratio;
        v.push(next.min(top));
    }
    v
}

impl RBlockTable {
    fn build(v0: f64, beta: f64, gun_h: f64, tgt_h: f64, cap: f64, mirrored: bool) -> Self {
        let vt = (GRAVITY / beta).sqrt();
        let tau = vt / GRAVITY;
        let drop = tgt_h - gun_h;
        let y_at = |theta: f64, x: f64| -> f64 {
            let t = P::time_from_x(x, theta, v0, beta);
            P::vertical_position(theta.sin(), t, v0, vt, tau)
        };
        let range_of = |theta: f64| -> f64 {
            let mut lo = 0.0f64;
            let mut hi = 1000.0f64;
            while y_at(theta, hi) > drop && hi < 200000.0 {
                hi *= 2.0;
            }
            for _ in 0..40 {
                let mid = 0.5 * (lo + hi);
                if y_at(theta, mid) > drop {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            lo
        };
        let mut theta_max = 0.0f64;
        let mut r_max = 0.0f64;
        let mut deg = 0.5f64;
        while deg <= 70.0 {
            let r = range_of(deg.to_radians());
            if r > r_max {
                r_max = r;
                theta_max = deg.to_radians();
            }
            deg += 0.5;
        }
        let cap = cap.min(r_max * 0.995).max(X_FLOOR as f64 * 2.0);
        // Low-arc launch angle for range R: least theta whose height at R
        // reaches the target, monotone in theta below theta_max.
        let theta_for = |r: f64| -> f64 {
            let mut lo = 0.0f64;
            let mut hi = theta_max;
            for _ in 0..40 {
                let mid = 0.5 * (lo + hi);
                if y_at(mid, r) < drop {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            hi
        };
        let n_r = (cap / R_STEP).ceil() as usize;
        let r_grid: Vec<f64> = (1..=n_r).map(|j| (j as f64 * R_STEP).min(cap)).collect();
        let thetas: Vec<f64> = r_grid.iter().map(|&r| theta_for(r)).collect();

        let x_edges = geometric(X_FLOOR, X_RATIO, cap as f32);
        let x_centres: Vec<f32> = x_edges.windows(2).map(|w| 0.5 * (w[0] + w[1])).collect();
        let mut h_edges = geometric(H_FLOOR, H_RATIO, H_MAX);
        h_edges[0] = drop as f32;
        let nx = x_centres.len();
        let nh1 = h_edges.len();
        let mut r = vec![f32::INFINITY; nx * nh1];
        for (i, &xc) in x_centres.iter().enumerate() {
            let mut k = 0usize;
            for (j, &rj) in r_grid.iter().enumerate() {
                if rj <= xc as f64 {
                    continue;
                }
                let x = if mirrored { rj - xc as f64 } else { xc as f64 };
                let y = y_at(thetas[j], x);
                while k < nh1 && (h_edges[k] as f64) <= y {
                    r[i * nh1 + k] = rj as f32;
                    k += 1;
                }
                if k >= nh1 {
                    break;
                }
            }
        }
        let x_idx = dense_index(&x_centres, X_IDX_M, cap as f32);
        let h_idx = dense_index(&h_edges, H_IDX_M, H_MAX);
        let mut t = Self { x_centres, h_edges, r, nx, nh1, x_idx, h_idx, cap: cap as f32, arcs: Vec::new() };
        t.arcs = (0..=n_r).flat_map(|j| t.arc_row(j as f32 * R_STEP as f32)).collect();
        t
    }

    /// Bilinear in (x, h); any INFINITY corner is INFINITY.
    fn lookup(&self, x: f32, h: f32) -> f32 {
        if h <= self.h_edges[0] {
            return 0.0;
        }
        let h = h.min(*self.h_edges.last().unwrap());
        let x = x.clamp(self.x_centres[0], *self.x_centres.last().unwrap());
        let i0 = self.x_idx[((x / X_IDX_M) as usize).min(self.x_idx.len() - 1)] as usize;
        let i1 = (i0 + 1).min(self.nx - 1);
        let k0 = self.h_idx[((h.max(0.0) / H_IDX_M) as usize).min(self.h_idx.len() - 1)] as usize;
        let k1 = (k0 + 1).min(self.nh1 - 1);
        let fx = if i1 == i0 {
            0.0
        } else {
            (x - self.x_centres[i0]) / (self.x_centres[i1] - self.x_centres[i0])
        };
        let fh = if k1 == k0 {
            0.0
        } else {
            (h - self.h_edges[k0]) / (self.h_edges[k1] - self.h_edges[k0])
        };
        // An INFINITY corner is "past the cap", not "unreachable at any h":
        // ramp toward it so the blind boundary lands inside the bucket instead
        // of at its lower edge.
        let over = self.cap * 1.5;
        let g = |i: usize, k: usize| {
            let v = self.r[i * self.nh1 + k];
            if v.is_finite() { v } else { over }
        };
        let (a, b, c, d) = (g(i0, k0), g(i1, k0), g(i0, k1), g(i1, k1));
        let lo = a + (b - a) * fx;
        let hi = c + (d - c) * fx;
        let r = lo + (hi - lo) * fh;
        if r > self.cap { f32::INFINITY } else { r }
    }

    /// Height above the muzzle the low arc to `range` clears at each x centre:
    /// lookup's own h interpolation inverted per column, so h <= arc_at(x)
    /// implies lookup(x, h) <= range.
    fn arc_row(&self, range: f32) -> Vec<f32> {
        let over = self.cap * 1.5;
        (0..self.nx).map(|i| {
            let row = &self.r[i * self.nh1..(i + 1) * self.nh1];
            let g = |k: usize| if row[k].is_finite() { row[k] } else { over };
            let k = (0..self.nh1).take_while(|&k| g(k) <= range).count();
            if k == 0 {
                return self.h_edges[0];
            }
            if k >= self.nh1 {
                return self.h_edges[self.nh1 - 1];
            }
            let (r0, r1) = (g(k - 1), g(k));
            let f = if r1 > r0 { ((range - r0) / (r1 - r0)).clamp(0.0, 1.0) } else { 0.0 };
            self.h_edges[k - 1] + f * (self.h_edges[k] - self.h_edges[k - 1])
        }).collect()
    }

    /// The precomputed arc for the longest tabulated range not past `range`:
    /// arcs only rise with range, so it is never above the true one.
    fn arc(&self, range: f32) -> &[f32] {
        let j = ((range / R_STEP as f32) as usize).min(self.arcs.len() / self.nx - 1);
        &self.arcs[j * self.nx..(j + 1) * self.nx]
    }

    /// `arc` at downrange `x`: the lower of the two columns lookup blends there.
    fn arc_at(&self, arc: &[f32], x: f32) -> f32 {
        let x = x.clamp(self.x_centres[0], *self.x_centres.last().unwrap());
        let i0 = self.x_idx[((x / X_IDX_M) as usize).min(self.x_idx.len() - 1)] as usize;
        arc[i0].min(arc[(i0 + 1).min(self.nx - 1)])
    }
}

/// Plain copy of the grids the rays read, so rayon workers never touch a Gd.
pub(crate) struct Terrain {
    pub(crate) w: i32,
    pub(crate) h: i32,
    pub(crate) cell: f32,
    pub(crate) min_x: f32,
    pub(crate) min_z: f32,
    pub(crate) sdf: Vec<f32>,
    pub(crate) height: Vec<f32>,
    /// Per grid square, the least SDF and the greatest height of its four
    /// corners: bounds on the bilinear surface for one nearest read.
    sdf_min: Vec<f32>,
    h_max: Vec<f32>,
    /// h_max pooled over 2^k squares, k = 1..=PYRAMID_MAX: (width, maxima).
    pyramid: Vec<(i32, Vec<f32>)>,
}

impl Terrain {
    pub(crate) fn from_map(m: &NavigationMap) -> Self {
        let height = if m.height_mid_grid.len() == m.height_grid.len() { m.height_mid_grid.clone() } else { m.height_grid.clone() };
        Self::from_grids(m.grid_width, m.grid_height, m.cell_size, m.min_x, m.min_z, m.sdf_grid.clone(), height)
    }

    fn from_grids(w: i32, h: i32, cell: f32, min_x: f32, min_z: f32, sdf: Vec<f32>, height: Vec<f32>) -> Self {
        let mut t = Self {
            w,
            h,
            cell,
            min_x,
            min_z,
            sdf,
            height,
            sdf_min: Vec::new(),
            h_max: Vec::new(),
            pyramid: Vec::new(),
        };
        let corners = |grid: &[f32], ix: i32, iz: i32, f: fn(f32, f32) -> f32| {
            let (x1, z1) = ((ix + 1).min(t.w - 1), (iz + 1).min(t.h - 1));
            let at = |x: i32, z: i32| grid[(z * t.w + x) as usize];
            f(f(at(ix, iz), at(x1, iz)), f(at(ix, z1), at(x1, z1)))
        };
        let n = (t.w * t.h) as usize;
        let (mut lo, mut hi) = (vec![0.0f32; n], vec![0.0f32; n]);
        if t.sdf.len() == n && t.height.len() == n {
            for iz in 0..t.h {
                for ix in 0..t.w {
                    lo[(iz * t.w + ix) as usize] = corners(&t.sdf, ix, iz, f32::min);
                    hi[(iz * t.w + ix) as usize] = corners(&t.height, ix, iz, f32::max);
                }
            }
        }
        (t.sdf_min, t.h_max) = (lo, hi);
        let (mut pw, mut ph) = (t.w, t.h);
        let mut below = t.h_max.clone();
        for _ in 0..PYRAMID_MAX {
            let (nw, nh) = ((pw + 1) / 2, (ph + 1) / 2);
            let mut up = vec![f32::NEG_INFINITY; (nw * nh) as usize];
            if !below.is_empty() {
                for z in 0..ph {
                    for x in 0..pw {
                        let i = ((z / 2) * nw + x / 2) as usize;
                        up[i] = up[i].max(below[(z * pw + x) as usize]);
                    }
                }
            }
            t.pyramid.push((nw, up.clone()));
            (pw, ph, below) = (nw, nh, up);
        }
        t
    }

    /// (max height, distance along the ray to its exit) of the level-k block
    /// (2^k squares, k = 0 one square) holding (px, pz), heading (dx, dz).
    fn block(&self, k: usize, px: f32, pz: f32, dx: f32, dz: f32) -> (f32, f32) {
        let size = self.cell * (1u32 << k) as f32;
        let bx = ((px - self.min_x) / size).floor();
        let bz = ((pz - self.min_z) / size).floor();
        let h = if k == 0 {
            self.h_max[self.square(px, pz)]
        } else {
            let (w, grid) = &self.pyramid[k - 1];
            grid[(bz as i32 * w + bx as i32) as usize]
        };
        let exit = |p: f32, d: f32, lo: f32| -> f32 {
            if d > 1e-6 {
                (lo + size - p) / d
            } else if d < -1e-6 {
                (lo - p) / d
            } else {
                f32::INFINITY
            }
        };
        let t = exit(px, dx, self.min_x + bx * size).min(exit(pz, dz, self.min_z + bz * size));
        (h, t.max(0.0))
    }

    /// Grid square under (x, z); the caller has checked in_bounds.
    fn square(&self, x: f32, z: f32) -> usize {
        let gx = ((x - self.min_x) / self.cell) as i32;
        let gz = ((z - self.min_z) / self.cell) as i32;
        (gz.min(self.h - 1) * self.w + gx.min(self.w - 1)) as usize
    }

    pub(crate) fn in_bounds(&self, x: f32, z: f32) -> bool {
        let gx = (x - self.min_x) / self.cell;
        let gz = (z - self.min_z) / self.cell;
        gx >= 0.0 && gz >= 0.0 && gx < self.w as f32 && gz < self.h as f32
    }

    pub(crate) fn bilinear(&self, grid: &[f32], x: f32, z: f32) -> f32 {
        let gx = ((x - self.min_x) / self.cell).clamp(0.0, self.w as f32 - 1.0);
        let gz = ((z - self.min_z) / self.cell).clamp(0.0, self.h as f32 - 1.0);
        let x0 = gx.floor() as i32;
        let z0 = gz.floor() as i32;
        let x1 = (x0 + 1).min(self.w - 1);
        let z1 = (z0 + 1).min(self.h - 1);
        let fx = gx - x0 as f32;
        let fz = gz - z0 as f32;
        let at = |ix: i32, iz: i32| grid[(iz * self.w + ix) as usize];
        let v0 = at(x0, z0) * (1.0 - fx) + at(x1, z0) * fx;
        let v1 = at(x0, z1) * (1.0 - fx) + at(x1, z1) * fx;
        v0 * (1.0 - fz) + v1 * fz
    }
}

/// True when a shell from `origin` can land `dist` along (dx, dz).
pub(crate) fn segment_clear(t: &Terrain, table: &RBlockTable, origin: Vector2, dx: f32, dz: f32, dist: f32, gun_h: f32) -> bool {
    segment_clear_counted(t, table, origin, dx, dz, dist, gun_h).0
}

/// segment_clear plus (march steps, land samples).
/// Clear when no terrain rises above the low arc to this target. Open water
/// leaps on the SDF; elsewhere a pyramid block lying wholly under the arc is
/// skipped (the arc is concave, so a stretch's lowest point is an end), else a
/// single square is sampled every half square against its tallest corner.
fn segment_clear_counted(t: &Terrain, table: &RBlockTable, origin: Vector2, dx: f32, dz: f32, dist: f32, gun_h: f32) -> (bool, u32, u32) {
    march(t, table, origin, dx, dz, dist, gun_h, PYRAMID_MAX, true)
}

/// `top`: highest pyramid level tried; `leap`: SDF leaps over open water.
/// A skip climbs one level for the next block, a failure descends one.
#[allow(clippy::too_many_arguments)]
fn march(t: &Terrain, table: &RBlockTable, origin: Vector2, dx: f32, dz: f32, dist: f32, gun_h: f32,
        top: usize, leap: bool) -> (bool, u32, u32) {
    let (mut steps, mut land) = (0u32, 0u32);
    if dist > table.cap {
        return (false, steps, land);
    }
    let arc = table.arc(dist);
    let leap_margin = t.cell;
    let mut s = 0.0f32;
    let mut k = top;
    'march: while s < dist {
        steps += 1;
        let px = origin.x + dx * s;
        let pz = origin.y + dz * s;
        if !t.in_bounds(px, pz) {
            return (false, steps, land);
        }
        if leap {
            let d = t.sdf_min[t.square(px, pz)];
            if d > leap_margin {
                s += d - leap_margin * 0.5;
                continue;
            }
        }
        let low_here = table.arc_at(arc, s);
        loop {
            let (h, exit) = t.block(k, px, pz, dx, dz);
            let end = (s + exit).min(dist);
            if h - gun_h <= low_here.min(table.arc_at(arc, end)) {
                s = end.max(s + 0.01);
                k = (k + 1).min(top);
                continue 'march;
            }
            if k == 0 {
                // A square the arc does not clear end to end: sample it with lookup, as the half-square march did.
                land += 1;
                let mut x = s;
                while x < end {
                    if table.lookup(x, h - gun_h) > dist {
                        return (false, steps, land);
                    }
                    x += t.cell * 0.5;
                }
                s = end.max(s + 0.01);
                k = 1.min(top);
                continue 'march;
            }
            k -= 1;
        }
    }
    (true, steps, land)
}

pub(crate) fn new_table(v0: f32, beta: f32, gun_h: f32, tgt_h: f32, cap: f32) -> Arc<RBlockTable> {
    Arc::new(RBlockTable::build(v0 as f64, beta as f64, gun_h as f64, tgt_h as f64, cap as f64, false))
}

struct Field {
    w: i32,
    h: i32,
    cell: f32,
    min_x: f32,
    min_z: f32,
    mult: i32,
    /// 1 where the cell centre is water; averages ignore land cells.
    water: Vec<u8>,
}

impl Field {
    fn build(t: &Terrain, mult: i32) -> Self {
        let (w, h) = ((t.w + mult - 1) / mult, (t.h + mult - 1) / mult);
        let cell = t.cell * mult as f32;
        let mut f = Field { w, h, cell, min_x: t.min_x, min_z: t.min_z, mult, water: vec![0u8; (w * h) as usize] };
        for idx in 0..f.water.len() {
            let c = f.centre(idx);
            if t.in_bounds(c.x, c.y) && t.bilinear(&t.sdf, c.x, c.y) > 0.0 {
                f.water[idx] = 1;
            }
        }
        f
    }

    fn index(&self, x: f32, z: f32) -> Option<usize> {
        let ix = ((x - self.min_x) / self.cell).floor() as i32;
        let iz = ((z - self.min_z) / self.cell).floor() as i32;
        if ix < 0 || iz < 0 || ix >= self.w || iz >= self.h {
            return None;
        }
        Some((iz * self.w + ix) as usize)
    }

    fn centre(&self, idx: usize) -> Vector2 {
        Vector2::new(
            self.min_x + ((idx as i32 % self.w) as f32 + 0.5) * self.cell,
            self.min_z + ((idx as i32 / self.w) as f32 + 0.5) * self.cell,
        )
    }

    /// Water cells within `r` of `c`.
    fn around(&self, c: Vector2, r: f32, mut g: impl FnMut(usize, f32)) {
        let ix0 = (((c.x - r - self.min_x) / self.cell).floor() as i32).max(0);
        let ix1 = (((c.x + r - self.min_x) / self.cell).floor() as i32).min(self.w - 1);
        let iz0 = (((c.y - r - self.min_z) / self.cell).floor() as i32).max(0);
        let iz1 = (((c.y + r - self.min_z) / self.cell).floor() as i32).min(self.h - 1);
        for iz in iz0..=iz1 {
            for ix in ix0..=ix1 {
                let idx = (iz * self.w + ix) as usize;
                let d = self.centre(idx).distance_to(c);
                if self.water[idx] != 0 && d <= r {
                    g(idx, d);
                }
            }
        }
    }
}

type Disc = (Vector2, f32);

fn disc_blocks(a: Vector2, b: Vector2, (c, r): Disc) -> bool {
    let d = b - a;
    let t = ((c - a).dot(d) / d.length_squared().max(1e-6)).clamp(0.0, 1.0);
    (a + d * t).distance_squared_to(c) < r * r
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) struct Shell {
    pub speed: f32,
    pub drag: f32,
    pub range: f32,
    pub gun_h: f32,
}

impl Shell {
    fn has_guns(&self) -> bool {
        self.speed > 0.0 && self.drag > 0.0 && self.range > 0.0
    }
}

/// One gun kind against one enemy's believed position(s).
struct Ray {
    origins: Vec<Vector2>,
    /// VisibilityGrid cell per origin, -1 none.
    cells: Vec<i32>,
    /// This gun's precomputed cell-to-cell answers, where its rows are built.
    matrix: Option<Arc<GunMatrix>>,
    table: Arc<RBlockTable>,
    gun_h: f32,
    range: f32,
}

impl Ray {
    /// Outbound: a shell from an origin lands on `p`. Otherwise one from `p` lands on an origin.
    /// `seen(j)`: terrain line of sight between `p` and origin j, which the arc clears too.
    fn hits(&self, t: &Terrain, p: Vector2, outbound: bool, seen: impl Fn(usize) -> bool) -> bool {
        self.origins.iter().enumerate().any(|(j, &o)| {
            let (from, to) = if outbound { (o, p) } else { (p, o) };
            let d = to - from;
            let dist = d.length();
            if dist > self.range || dist < 1.0 {
                probe(|p| p.out_of_range += 1);
                return dist < 1.0;
            }
            if seen(j) {
                STAT_LOS.fetch_add(1, Relaxed);
                probe(|p| p.los += 1);
                return true;
            }
            STAT_RAYS.fetch_add(1, Relaxed);
            let t0 = std::time::Instant::now();
            let (clear, steps, land) = segment_clear_counted(t, &self.table, from, d.x / dist, d.y / dist, dist, self.gun_h);
            let ns = t0.elapsed().as_nanos() as u64;
            probe(|p| {
                p.rays += 1;
                p.ray_dist += dist as f64;
                p.ray_dist_max = p.ray_dist_max.max(dist);
                p.steps += steps;
                p.land += land;
                p.ray_ns += ns;
            });
            clear
        })
    }
}

/// (kind, enemy id, hull key, pin id)
type PlaneKey = (u8, i64, i64, i64);

/// Ray answers for one PlaneKey, 2 bits per field cell: 0 not asked, 1 no, 2 yes.
type Plane = Arc<[AtomicU8]>;

fn plane_get(p: &[AtomicU8], idx: usize) -> u8 {
    p[idx / 4].load(Relaxed) >> (2 * (idx % 4)) & 3
}

/// A cell goes from 0 to its answer once, so OR-ing the bits in is enough.
fn plane_set(p: &[AtomicU8], idx: usize, v: u8) {
    p[idx / 4].fetch_or(v << (2 * (idx % 4)), Relaxed);
}

/// Per-enemy ray answers for one query, computed when a cell is first asked
/// about and kept in the field's answer planes across queries.
pub(crate) struct ReachLookup {
    terrain: Arc<Terrain>,
    field: Arc<Field>,
    rays: Vec<Option<(Ray, Plane)>>,
    outbound: bool,
    vis: Option<Gd<VisibilityGrid>>,
    vis_cell: Arc<Vec<i32>>,
}

impl ReachLookup {
    /// Bit i set when enemy i's ray answers yes at `p`.
    pub(crate) fn mask(&self, p: Vector2) -> u64 {
        let Some(idx) = self.field.index(p.x, p.y) else { return 0 };
        probe(|p| p.masks += 1);
        let mut vis = None;
        let mut m = 0u64;
        let k = self.vis_cell.get(idx).copied().unwrap_or(-1);
        for (i, r) in self.rays.iter().enumerate().take(64) {
            let Some((ray, plane)) = r else { continue };
            if let Some(hit) = ray.matrix.as_ref().and_then(|g| g.answer(&ray.origins, &ray.cells, k, p, ray.range, self.outbound)) {
                probe(|q| q.matrix += 1);
                m |= (hit as u64) << i;
                continue;
            }
            let mut v = plane_get(plane, idx);
            if v == 0 {
                STAT_MISSES.fetch_add(1, Relaxed);
                probe(|p| p.misses += 1);
                let vis = vis.get_or_insert_with(|| self.vis.as_ref().filter(|_| k >= 0).map(|v| v.bind()));
                let seen = |j: usize| vis.as_ref().is_some_and(|v| ray.cells[j] >= 0 && v.visible_idx(k as usize, ray.cells[j] as usize));
                v = 1 + ray.hits(&self.terrain, self.field.centre(idx), self.outbound, seen) as u8;
                plane_set(plane, idx, v);
            }
            m |= ((v == 2) as u64) << i;
        }
        m
    }

    pub(crate) fn hits(&self, i: usize, p: Vector2) -> bool {
        i < 64 && self.mask(p) & (1 << i) != 0
    }

    /// Bit i set when enemy i has guns to answer for.
    pub(crate) fn known_mask(&self) -> u64 {
        self.rays.iter().enumerate().take(64).fold(0, |m, (i, r)| m | ((r.is_some() as u64) << i))
    }

    pub(crate) fn known(&self, i: usize) -> bool {
        self.rays.get(i).is_some_and(|r| r.is_some())
    }
}

struct Enemy {
    origin: Vector2,
    /// Lateral error bar of the believed position; wide ones fire from 3 origins.
    spread: f32,
    shell: Shell,
    /// Certainty 0..1; divides distance in the detection grid.
    weight: f32,
    force_spot: f32,
    /// Origin at the last detection version bump.
    marked: Vector2,
    /// (from, los_range, field cells it sees with their distance): terrain only, redone when `marked` moves.
    seen: Option<(Vector2, f32, Arc<Vec<(u32, f32)>>)>,
    /// Position and spread rays are cast from, moved only after ORIGIN_QUANTUM_M
    /// of real change so a jittering belief keeps its answers; `pin_id` keys them.
    pin: Vector2,
    pin_spread: f32,
    pin_id: i64,
}

impl Enemy {
    fn origins(&self) -> Vec<Vector2> {
        if self.pin_spread < SPREAD_MIN {
            return vec![self.pin];
        }
        (0..3)
            .map(|k| {
                let a = k as f32 * std::f32::consts::TAU / 3.0;
                self.pin + Vector2::new(a.sin(), a.cos()) * self.pin_spread
            })
            .collect()
    }

    fn repin(&mut self) {
        if self.pin_id == 0 || self.pin.distance_to(self.origin) > ORIGIN_QUANTUM_M
            || (self.pin_spread - self.spread).abs() > ORIGIN_QUANTUM_M {
            (self.pin, self.pin_spread) = (self.origin, self.spread);
            self.pin_id = PIN_IDS.fetch_add(1, Relaxed) as i64 + 1;
        }
    }
}

#[derive(Default)]
struct Team {
    hulls: HashMap<i64, Shell>,
    enemies: BTreeMap<i64, Enemy>,
    /// Enemy ids; position = bit index in the masks handed out.
    order: Vec<i64>,
    target_h: f32,
    los_range: f32,
    /// Bumped when what the detection grid shows changes, at most every DETECT_EVERY updates.
    detect_version: u64,
    detect_dirty: bool,
    updates_since_bump: u32,
    detect: Arc<Vec<f32>>,
    detect_built: u64,
}

type ExposureKey = (i32, i32, i32, i32, i32);
type LayoutKey = (i32, i32, i32, i32);
const HIST_BUCKETS: usize = 80;

/// One team's detection grid folded onto a node layout: per node the nearest
/// effective distance and a histogram of them, so any radius reads off it.
struct Layout {
    version: u64,
    min_d: Vec<f32>,
    hist: Vec<u16>,
    water: Vec<u32>,
}

/// Gunnery and detection queries against terrain, answered on demand from
/// what each team believes about the enemy.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct ReachField {
    base: Base<RefCounted>,
    terrain: Option<Arc<Terrain>>,
    field: Option<Arc<Field>>,
    vis: Option<Gd<VisibilityGrid>>,
    /// VisibilityGrid water cell per field cell, -1 none.
    vis_cell: Arc<Vec<i32>>,
    tables: RefCell<HashMap<TableKey, Arc<RBlockTable>>>,
    smoke: Vec<Disc>,
    teams: HashMap<i32, Team>,
    planes: Mutex<(u64, HashMap<PlaneKey, (u64, Plane)>)>,
    exposure: HashMap<ExposureKey, (u64, Arc<Vec<f32>>, Arc<Vec<f32>>)>,
    layouts: HashMap<LayoutKey, Layout>,
    vis_cell_count: usize,
    /// Per gun kind tables and the thread filling them; started with the visibility grid.
    matrix: Option<MatrixWorker>,
}

/// Muzzle heights share a table per this band, taken at its floor: a lower gun
/// only blocks more, and the live muzzle height wanders with roll and losses.
const MATRIX_GUN_H_M: f32 = 5.0;

fn matrix_gun_h(h: f32) -> f32 {
    ((h / MATRIX_GUN_H_M).floor() * MATRIX_GUN_H_M).max(1.0)
}

/// `s` with its muzzle height banded, as every table is built.
fn banded(s: Shell) -> Shell {
    Shell { gun_h: matrix_gun_h(s.gun_h), ..s }
}

/// Gun kinds sharing a table: range only caps the answer, so it is left out.
fn matrix_key(s: Shell) -> i64 {
    let k = TableKey::new(s.speed, s.drag, matrix_gun_h(s.gun_h), 0.0, 0.0, false);
    (k.v0_cm as i64) << 40 ^ (k.beta_e8 as i64) << 16 ^ k.gun_dm as i64
}

impl ReachField {
    fn matrix_of(&self, s: Shell) -> Option<Arc<GunMatrix>> {
        let key = matrix_key(s);
        self.matrix.as_ref()?.matrices.read().unwrap().iter().find(|g| g.key == key).cloned()
    }

    /// The table for `s`'s gun kind, registered with the worker on first sight.
    fn ensure_matrix(&self, s: Shell) -> Option<Arc<GunMatrix>> {
        if !s.has_guns() {
            return None;
        }
        if let Some(g) = self.matrix_of(s) {
            return Some(g);
        }
        let w = self.matrix.as_ref()?;
        let n = self.vis_cell_count;
        let shell = banded(s);
        let g = Arc::new(GunMatrix::new(matrix_key(s), shell, n));
        w.matrices.write().unwrap().push(g.clone());
        Some(g)
    }

    /// Callers pass shells through `banded` first, so the set of tables stays the prebuilt one.
    fn table(&self, s: Shell, target_h: f32) -> Arc<RBlockTable> {
        let key = TableKey::new(s.speed, s.drag, s.gun_h, target_h, s.range, false);
        self.tables.borrow_mut().entry(key).or_insert_with(|| new_table(s.speed, s.drag, s.gun_h, target_h, s.range)).clone()
    }

    /// The answer plane for `key`; the least recently asked half goes once MAX_PLANES are held.
    fn plane(&self, key: PlaneKey, cells: usize) -> Plane {
        let mut g = self.planes.lock().unwrap();
        g.0 += 1;
        let now = g.0;
        if let Some(e) = g.1.get_mut(&key) {
            e.0 = now;
            return e.1.clone();
        }
        if g.1.len() >= MAX_PLANES {
            let mut ages: Vec<u64> = g.1.values().map(|e| e.0).collect();
            ages.sort_unstable();
            let cut = ages[ages.len() / 2];
            g.1.retain(|_, e| e.0 > cut);
            STAT_EVICTIONS.fetch_add(1, Relaxed);
        }
        STAT_PLANES_MADE.fetch_add(1, Relaxed);
        let t0 = std::time::Instant::now();
        let p: Plane = (0..cells.div_ceil(4)).map(|_| AtomicU8::new(0)).collect();
        g.1.insert(key, (now, p.clone()));
        let ns = t0.elapsed().as_nanos() as u64;
        probe(|q| {
            q.planes_new += 1;
            q.planes_ns += ns;
        });
        p
    }

    fn lookup(&self, team: i32, ids: &[i64], hull_key: Option<i64>) -> Option<ReachLookup> {
        let (terrain, field, tm) = (self.terrain.clone()?, self.field.clone()?, self.teams.get(&team)?);
        let hull = match hull_key {
            Some(k) => Some(*tm.hulls.get(&k)?),
            None => None,
        };
        let vis = self.vis.as_ref().map(|v| v.bind());
        let rays = ids.iter().map(|id| {
            let e = tm.enemies.get(id)?;
            let (shell, kind) = match hull {
                Some(h) => (h, 1u8),
                None => (e.shell, 0u8),
            };
            if !shell.has_guns() {
                return None;
            }
            let shell = banded(shell);
            let origins = e.origins();
            let cells = origins.iter().map(|&o| vis.as_ref().and_then(|v| v.cell_of(o)).map_or(-1, |c| c as i32)).collect();
            let ray = Ray { origins, cells, matrix: self.matrix_of(shell), table: self.table(shell, tm.target_h),
                gun_h: shell.gun_h, range: shell.range };
            Some((ray, self.plane((kind, *id, hull_key.unwrap_or(0), e.pin_id), field.water.len())))
        }).collect();
        drop(vis);
        Some(ReachLookup { terrain, field, rays, outbound: hull.is_none(), vis: self.vis.clone(), vis_cell: self.vis_cell.clone() })
    }

    /// Where the listed enemies can land shells.
    pub(crate) fn fire_lookup(&self, team: i32, ids: &[i64]) -> Option<ReachLookup> {
        self.lookup(team, ids, None)
    }

    /// Where a `hull_key` hull can hit each listed enemy from.
    pub(crate) fn reach_lookup(&self, team: i32, hull_key: i64, ids: &[i64]) -> Option<ReachLookup> {
        self.lookup(team, ids, Some(hull_key))
    }

    pub(crate) fn detect_version(&self, team: i32) -> u64 {
        self.teams.get(&team).map_or(0, |t| t.detect_version)
    }

    /// Re-lists the cells each enemy of `team` sees, for those that moved.
    fn refresh_seen(&mut self, team: i32) {
        let (Some(f), Some(t)) = (self.field.clone(), self.teams.get_mut(&team)) else { return };
        let vis = self.vis.as_ref().map(|v| v.bind());
        let los_range = t.los_range;
        for e in t.enemies.values_mut() {
            if e.seen.as_ref().is_some_and(|(from, r, _)| *from == e.marked && *r == los_range) {
                continue;
            }
            let from = e.marked;
            let ec = vis.as_ref().and_then(|v| v.cell_of(from));
            let mut cells = Vec::new();
            f.around(from, los_range, |idx, d| {
                let seen = match (&vis, ec, self.vis_cell.get(idx)) {
                    (Some(v), Some(ec), Some(&k)) => k >= 0 && v.visible_idx(k as usize, ec),
                    _ => true,
                };
                if seen {
                    cells.push((idx as u32, d));
                }
            });
            e.seen = Some((from, los_range, Arc::new(cells)));
        }
    }

    /// Min effective distance per field cell over enemies that see it,
    /// distance over certainty, INFINITY where none does. Inside a radar or
    /// hydro reach it runs NEGATIVE toward the emitter, so a ship already
    /// inside still sees which way is out.
    fn detect_grid(&self, tm: &Team) -> Vec<f32> {
        let Some(f) = self.field.as_ref() else { return Vec::new() };
        let mut grid = vec![f32::INFINITY; f.water.len()];
        for e in tm.enemies.values() {
            let (inv_w, fs) = (1.0 / e.weight.max(WEIGHT_FLOOR), e.force_spot);
            f.around(e.origin, fs, |idx, d| grid[idx] = grid[idx].min(d - fs));
            let Some((from, los_range, cells)) = &e.seen else { continue };
            // (disc, its distance from us) for discs within reach; inside one we see nothing.
            let discs: Vec<(Disc, f32)> = self.smoke.iter()
                .map(|&(c, r)| ((c, r), c.distance_to(*from)))
                .filter(|&((_, r), dc)| dc < los_range + r)
                .collect();
            if discs.iter().any(|&((_, r), dc)| dc < r) {
                continue;
            }
            for &(idx, d) in cells.iter() {
                let idx = idx as usize;
                if d < fs || d * inv_w >= grid[idx] {
                    continue;
                }
                let c = f.centre(idx);
                if !discs.iter().any(|&(disc, dc)| d > dc - disc.1 && disc_blocks(*from, c, disc)) {
                    grid[idx] = d * inv_w;
                }
            }
        }
        grid
    }

    /// `hist`: also bucket the distances, for the mean.
    fn layout(&mut self, team: i32, cluster_cells: i32, ncx: i32, ncz: i32, hist: bool) -> Option<&Layout> {
        let version = self.detect_version(team);
        let key = (team, cluster_cells, ncx, ncz);
        if self.layouts.get(&key).is_some_and(|l| l.version == version && (!hist || !l.hist.is_empty())) {
            return self.layouts.get(&key);
        }
        if self.teams.get(&team)?.detect_built != version || self.teams[&team].detect.is_empty() {
            STAT_DETECT.fetch_add(1, Relaxed);
            self.refresh_seen(team);
            let grid = Arc::new(self.detect_grid(&self.teams[&team]));
            let t = self.teams.get_mut(&team).unwrap();
            t.detect = grid;
            t.detect_built = version;
        }
        let (f, detect) = (self.field.as_ref()?, &self.teams[&team].detect);
        let n = (ncx.max(0) * ncz.max(0)) as usize;
        let mut l = Layout { version, min_d: vec![f32::INFINITY; n], hist: vec![0; if hist { n * HIST_BUCKETS } else { 0 }], water: vec![0; n] };
        if cluster_cells > 0 && detect.len() == f.water.len() {
            let cx: Vec<i32> = (0..f.w).map(|ix| ix * f.mult / cluster_cells).collect();
            for iz in 0..f.h {
                let cz = iz * f.mult / cluster_cells;
                if cz >= ncz {
                    break;
                }
                for ix in 0..f.w {
                    let (idx, c) = ((iz * f.w + ix) as usize, cx[ix as usize]);
                    if c >= ncx || f.water[idx] == 0 {
                        continue;
                    }
                    let node = (cz * ncx + c) as usize;
                    l.water[node] += 1;
                    let d = detect[idx];
                    l.min_d[node] = l.min_d[node].min(d);
                    let b = (d.max(0.0) / EXPOSURE_RADIUS_Q) as usize;
                    if hist && b < HIST_BUCKETS {
                        l.hist[node * HIST_BUCKETS + b] += 1;
                    }
                }
            }
        }
        self.layouts.insert(key, l);
        self.layouts.get(&key)
    }

    /// Per node of `cluster_cells` SDF cells: (max, mean over water cells) of
    /// exposure, 0 outside detection to 1 at effective distance zero. Without
    /// `with_mean` the mean is left empty.
    pub(crate) fn cluster_exposure_stats(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32,
            with_mean: bool) -> (Arc<Vec<f32>>, Arc<Vec<f32>>) {
        let radius = (radius / EXPOSURE_RADIUS_Q).ceil() * EXPOSURE_RADIUS_Q;
        let key = (team, (radius / EXPOSURE_RADIUS_Q) as i32, cluster_cells, ncx, ncz);
        let n = (ncx.max(0) * ncz.max(0)) as usize;
        let version = self.detect_version(team);
        if let Some((v, max, mean)) = self.exposure.get(&key) {
            if *v == version && (!with_mean || !mean.is_empty()) {
                return (max.clone(), mean.clone());
            }
        }
        let (mut max, mut mean) = (vec![0.0f32; n], vec![0.0f32; if with_mean { n } else { 0 }]);
        if radius > 0.0 {
            if let Some(l) = self.layout(team, cluster_cells, ncx, ncz, with_mean) {
                let e = |d: f32| ((radius - d) / radius).clamp(0.0, EXPOSURE_MAX);
                for node in 0..n.min(l.water.len()) {
                    if l.water[node] == 0 || l.min_d[node] >= radius {
                        continue;
                    }
                    max[node] = e(l.min_d[node]);
                    if with_mean {
                        let h = &l.hist[node * HIST_BUCKETS..(node + 1) * HIST_BUCKETS];
                        let sum: f32 = h.iter().enumerate().map(|(b, &c)| c as f32 * e((b as f32 + 0.5) * EXPOSURE_RADIUS_Q)).sum();
                        mean[node] = sum / l.water[node] as f32;
                    }
                }
            }
        }
        let out = (Arc::new(max), Arc::new(mean));
        self.exposure.insert(key, (version, out.0.clone(), out.1.clone()));
        out
    }

    /// One byte per field cell, row-major by z, from `value` at every
    /// DEBUG_STRIDE-th cell; for the overlays only.
    fn debug_bytes(&self, value: impl Fn(Vector2) -> u8 + Sync) -> PackedByteArray {
        let Some(f) = self.field.as_ref() else { return PackedByteArray::new() };
        let s = DEBUG_STRIDE;
        let (bw, bh) = ((f.w + s - 1) / s, (f.h + s - 1) / s);
        let blocks: Vec<u8> = nav_pool().install(|| (0..bw * bh).into_par_iter().map(|b| {
            let (ix, iz) = ((b % bw) * s + s / 2, (b / bw) * s + s / 2);
            let idx = (iz.min(f.h - 1) * f.w + ix.min(f.w - 1)) as usize;
            if f.water[idx] == 0 { 0 } else { value(f.centre(idx)) }
        }).collect());
        let out: Vec<u8> = (0..f.w * f.h).map(|i| blocks[((i / f.w / s) * bw + (i % f.w) / s) as usize]).collect();
        PackedByteArray::from(out.as_slice())
    }

    fn count_bytes(&self, lookup: Option<ReachLookup>, n: usize) -> PackedByteArray {
        let Some(l) = lookup else { return PackedByteArray::new() };
        let (rays, terrain, outbound) = (&l.rays, &l.terrain, l.outbound);
        self.debug_bytes(|c| (0..n).filter(|&i| rays[i].as_ref().is_some_and(|(r, _)| r.hits(terrain, c, outbound, |_| false))).count().min(255) as u8)
    }

    fn mask(lookup: Option<ReachLookup>, n: usize, point: Vector2) -> i64 {
        let Some(l) = lookup else { return 0 };
        (0..n.min(63)).filter(|&i| l.hits(i, point)).fold(0i64, |m, i| m | 1i64 << i)
    }
}

#[godot_api]
impl ReachField {
    /// `cell_mult` field cells per SDF cell along each axis.
    #[func]
    fn build(&mut self, nav_map: Option<Gd<NavigationMap>>, #[opt(default = 2)] cell_mult: i32) {
        let Some(map) = nav_map else { return };
        let m = map.bind();
        if !m.built {
            return;
        }
        let terrain = Terrain::from_map(&m);
        self.field = Some(Arc::new(Field::build(&terrain, cell_mult.max(1))));
        self.terrain = Some(Arc::new(terrain));
        self.planes.lock().unwrap().1.clear();
        self.exposure.clear();
        self.layouts.clear();
        self.matrix = None;
    }

    /// Island line of sight for the detection grid; without it every cell in range is seen.
    #[func]
    fn set_visibility(&mut self, vis: Option<Gd<VisibilityGrid>>) {
        self.vis_cell = Arc::new(match (&vis, &self.field) {
            (Some(v), Some(f)) => {
                let v = v.bind();
                (0..f.water.len()).map(|i| v.cell_of(f.centre(i)).map_or(-1, |k| k as i32)).collect()
            }
            _ => Vec::new(),
        });
        self.matrix = None;
        if let (Some(v), Some(terrain)) = (&vis, &self.terrain) {
            let v = v.bind();
            self.vis_cell_count = v.centres.len();
            let cells = Cells { centres: v.centres.clone(), los: v.bits.clone(), los_stride: v.stride };
            self.matrix = Some(MatrixWorker::start(terrain.clone(), Arc::new(cells)));
        }
        self.vis = vis;
        for t in self.teams.values_mut() {
            t.detect_version += 1;
            for e in t.enemies.values_mut() {
                e.seen = None;
            }
        }
    }

    #[func]
    fn is_built(&self) -> bool {
        self.field.is_some()
    }

    #[func]
    fn get_last_stats(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("tables_cached", self.tables.borrow().len() as i64);
        d.set("planes", self.planes.lock().unwrap().1.len() as i64);
        for (k, a) in [("misses", &STAT_MISSES), ("los", &STAT_LOS), ("rays", &STAT_RAYS), ("exposure_builds", &STAT_DETECT), ("planes_made", &STAT_PLANES_MADE), ("evictions", &STAT_EVICTIONS)] {
            d.set(k, a.load(Relaxed) as i64);
        }
        d
    }

    #[func]
    fn get_field_info(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(f) = &self.field {
            d.set("w", f.w as i64);
            d.set("h", f.h as i64);
            d.set("cell", f.cell);
            d.set("min_x", f.min_x);
            d.set("min_z", f.min_z);
        }
        d
    }

    #[func]
    fn segment_clear(&mut self, start: Vector2, end: Vector2, gun_h: f32, target_h: f32, speed: f32, drag: f32, range: f32) -> bool {
        let Some(terrain) = self.terrain.clone() else { return false };
        let delta = end - start;
        let dist = delta.length();
        if dist < 1e-3 {
            return true;
        }
        let s = banded(Shell { speed, drag, range, gun_h });
        let table = self.table(s, target_h);
        segment_clear(&terrain, &table, start, delta.x / dist, delta.y / dist, dist, s.gun_h)
    }

    #[func]
    fn prebuild_tables(&mut self, speeds: PackedFloat32Array, drags: PackedFloat32Array, gun_heights: PackedFloat32Array,
            ranges: PackedFloat32Array, target_h: f32) {
        let n = speeds.len().min(drags.len()).min(gun_heights.len()).min(ranges.len());
        let mut todo: Vec<(TableKey, Shell)> = Vec::new();
        for i in 0..n {
            let s = banded(Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] });
            let key = TableKey::new(s.speed, s.drag, s.gun_h, target_h, s.range, false);
            if s.has_guns() && !self.tables.borrow().contains_key(&key) && !todo.iter().any(|(k, _)| *k == key) {
                todo.push((key, s));
            }
        }
        let built: Vec<(TableKey, Arc<RBlockTable>)> = nav_pool().install(|| {
            todo.par_iter().map(|&(k, s)| (k, new_table(s.speed, s.drag, s.gun_h, target_h, s.range))).collect()
        });
        self.tables.borrow_mut().extend(built);
    }

    /// Smoke discs (world XZ centre, radius) that end line of sight.
    #[func]
    fn set_smoke(&mut self, centres: PackedVector2Array, radii: PackedFloat32Array) {
        let n = centres.len().min(radii.len());
        let next: Vec<Disc> = (0..n).map(|i| (centres[i], radii[i])).collect();
        if next != self.smoke {
            self.smoke = next;
            for t in self.teams.values_mut() {
                t.detect_dirty = true;
            }
        }
    }

    /// The friendly hull kinds a team asks reach for.
    #[func]
    fn set_team_hulls(
        &mut self,
        team: i32,
        keys: PackedInt64Array,
        speeds: PackedFloat32Array,
        drags: PackedFloat32Array,
        ranges: PackedFloat32Array,
        gun_heights: PackedFloat32Array,
    ) {
        let n = keys.len().min(speeds.len()).min(drags.len()).min(ranges.len()).min(gun_heights.len());
        let hulls: HashMap<i64, Shell> = (0..n)
            .map(|i| (keys[i], Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] }))
            .collect();
        for s in hulls.values() {
            self.ensure_matrix(*s);
        }
        self.teams.entry(team).or_default().hulls = hulls;
    }

    /// Enemies as `team` believes them: position, shell, lateral `spread`,
    /// certainty `weight`, radar/hydro `force_spot`. `los_range` is the
    /// furthest any ship on the team can be seen from. The detection grid is
    /// redone once an enemy moves `move_threshold` or its certainty steps.
    #[func]
    fn update_team(
        &mut self,
        team: i32,
        ids: PackedInt64Array,
        origins: PackedVector2Array,
        speeds: PackedFloat32Array,
        drags: PackedFloat32Array,
        ranges: PackedFloat32Array,
        gun_heights: PackedFloat32Array,
        spreads: PackedFloat32Array,
        weights: PackedFloat32Array,
        force_spots: PackedFloat32Array,
        los_range: f32,
        target_h: f32,
        move_threshold: f32,
    ) {
        let n = [ids.len(), origins.len(), speeds.len(), drags.len(), ranges.len(),
            gun_heights.len(), spreads.len(), weights.len(), force_spots.len()]
            .into_iter().min().unwrap();
        let t = self.teams.entry(team).or_default();
        let mut moved = (t.los_range - los_range).abs() > 1.0 || t.target_h != target_h;
        t.los_range = los_range;
        t.target_h = target_h;
        let before = t.enemies.len();
        t.enemies.retain(|id, _| ids.as_slice()[..n].contains(id));
        moved |= t.enemies.len() != before;
        for i in 0..n {
            let shell = Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] };
            let (origin, spread, weight, force_spot) = (origins[i], spreads[i].max(0.0), weights[i], force_spots[i]);
            match t.enemies.get_mut(&ids[i]) {
                Some(e) => {
                    let step = |a: f32, b: f32| (a / WEIGHT_STEP).floor() != (b / WEIGHT_STEP).floor();
                    if e.marked.distance_to(origin) > move_threshold || step(e.weight, weight) || e.force_spot != force_spot {
                        moved = true;
                        e.marked = origin;
                    }
                    (e.origin, e.spread, e.shell, e.weight, e.force_spot) = (origin, spread, shell, weight, force_spot);
                    e.repin();
                }
                None => {
                    moved = true;
                    let mut e = Enemy { origin, spread, shell, weight, force_spot, marked: origin, seen: None,
                        pin: origin, pin_spread: spread, pin_id: 0 };
                    e.repin();
                    t.enemies.insert(ids[i], e);
                }
            }
        }
        t.order = t.enemies.keys().copied().collect();
        t.detect_dirty |= moved;
        t.updates_since_bump += 1;
        if t.detect_dirty && t.updates_since_bump >= DETECT_EVERY {
            t.detect_version += 1;
            t.detect_dirty = false;
            t.updates_since_bump = 0;
        }
        // Each enemy is a site its own gun's table fills outward from.
        let mut sites: HashMap<i64, (Shell, Vec<Vector2>)> = HashMap::new();
        for i in 0..n {
            let shell = Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] };
            if shell.has_guns() {
                sites.entry(matrix_key(shell)).or_insert((shell, Vec::new())).1.push(origins[i]);
            }
        }
        for (shell, at) in sites.into_values() {
            if let Some(g) = self.ensure_matrix(shell) {
                g.set_sites(team.clamp(0, 1) as usize, at);
            }
        }
    }

    /// {key, done, rows, file} per gun table; file is 0 untried, 1 loaded, 2 none, 3 saved.
    #[func]
    fn gun_matrix_status(&self) -> Array<VarDictionary> {
        let mut out = Array::new();
        for g in self.matrix.as_ref().map(|w| w.matrices.read().unwrap().clone()).unwrap_or_default() {
            let mut d = VarDictionary::new();
            d.set("key", g.key);
            d.set("done", g.done.load(std::sync::atomic::Ordering::Acquire) as i64);
            d.set("rows", g.rows() as i64);
            d.set("file", g.file.load(std::sync::atomic::Ordering::Acquire) as i64);
            out.push(&d);
        }
        out
    }

    /// Cache gun tables in `dir` (an OS path) for map `map`: always read, written only with `save`.
    #[func]
    fn set_gun_matrix_cache(&self, dir: GString, map: i64, save: bool) {
        if let Some(w) = &self.matrix {
            *w.cache.lock().unwrap() = Some(crate::nav::gun_matrix::CacheCfg { dir: dir.to_string().into(), map, save });
        }
    }

    /// Enemy ids in mask bit order for `team`.
    #[func]
    fn get_team_enemy_ids(&self, team: i32) -> PackedInt64Array {
        self.teams.get(&team).map_or_else(PackedInt64Array::new, |t| PackedInt64Array::from(t.order.as_slice()))
    }

    /// Bit i set when enemy `get_team_enemy_ids(team)[i]` can hit `point`.
    #[func]
    fn exposure_mask(&self, team: i32, point: Vector2) -> i64 {
        let ids = self.get_team_enemy_ids(team);
        Self::mask(self.fire_lookup(team, ids.as_slice()), ids.len(), point)
    }

    /// Bit i set when a `hull_key` hull at `point` can hit enemy i.
    #[func]
    fn reach_mask(&self, team: i32, hull_key: i64, point: Vector2) -> i64 {
        let ids = self.get_team_enemy_ids(team);
        Self::mask(self.reach_lookup(team, hull_key, ids.as_slice()), ids.len(), point)
    }

    /// Per cell, how many enemies can land shells there (debug overlay).
    #[func]
    fn get_exposure_count_bytes(&self, team: i32) -> PackedByteArray {
        let ids = self.get_team_enemy_ids(team);
        self.count_bytes(self.fire_lookup(team, ids.as_slice()), ids.len())
    }

    /// Per cell, how many enemies a `hull_key` hull could hit from there (debug overlay).
    #[func]
    fn get_reach_count_bytes(&self, team: i32, hull_key: i64) -> PackedByteArray {
        let ids = self.get_team_enemy_ids(team);
        self.count_bytes(self.reach_lookup(team, hull_key, ids.as_slice()), ids.len())
    }

    /// 255 where a gun at `origin` can land shells (debug overlay).
    #[func]
    fn get_reach_bytes_from(&self, origin: Vector2, gun_h: f32, speed: f32, drag: f32, range: f32) -> PackedByteArray {
        let Some(terrain) = self.terrain.clone() else { return PackedByteArray::new() };
        let shell = banded(Shell { speed, drag, range, gun_h });
        let ray = Ray { origins: vec![origin], cells: vec![-1], matrix: None, table: self.table(shell, 0.0), gun_h: shell.gun_h, range };
        self.debug_bytes(|c| if ray.hits(&terrain, c, true, |_| false) { 255 } else { 0 })
    }

    /// Per HPA cluster (`cluster_cells` SDF cells wide, `ncx` by `ncz`): the
    /// deepest exposure of any field cell in it, for a ship of concealment `radius`.
    #[func]
    fn get_cluster_exposure(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> PackedFloat32Array {
        PackedFloat32Array::from(self.cluster_exposure_stats(team, radius, cluster_cells, ncx, ncz, false).0.as_slice())
    }

    /// {half, heading, count} at `point`: the bearing that keeps every
    /// shooter within `half` radians of the bow or stern. half = -1 when
    /// nobody can hit the point.
    #[func]
    fn cone_at(&self, team: i32, point: Vector2) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("half", -1.0f32);
        d.set("heading", 0.0f32);
        d.set("count", 0i64);
        let (Some(t), ids) = (self.teams.get(&team), self.get_team_enemy_ids(team)) else { return d };
        let Some(l) = self.fire_lookup(team, ids.as_slice()) else { return d };
        let mut b: Vec<f32> = (0..ids.len())
            .filter(|&i| l.hits(i, point))
            .map(|i| {
                let o = t.enemies[&ids[i]].origin;
                (o.x - point.x).atan2(o.y - point.y)
            })
            .collect();
        d.set("count", b.len() as i64);
        if b.is_empty() {
            return d;
        }
        b.sort_by(|p, q| p.total_cmp(q));
        let n = b.len();
        let (mut gap, mut start) = (b[0] + std::f32::consts::TAU - b[n - 1], b[0]);
        for i in 0..n - 1 {
            if b[i + 1] - b[i] > gap {
                gap = b[i + 1] - b[i];
                start = b[i + 1];
            }
        }
        let cone = std::f32::consts::TAU - gap;
        let mut mid = start + 0.5 * cone;
        if mid > std::f32::consts::PI {
            mid -= std::f32::consts::TAU;
        }
        d.set("half", 0.5 * cone);
        d.set("heading", mid);
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn yamato(mirrored: bool) -> RBlockTable {
        RBlockTable::build(805.0, 2e-5, 5.0, 0.0, 30000.0, mirrored)
    }

    #[test]
    fn near_obstacle_blinds_to_twelve_km() {
        let t = yamato(false);
        let r = t.lookup(300.0, 30.0);
        assert!((11500.0..12500.0).contains(&r), "got {r}");
        let r = t.lookup(300.0, 80.0);
        assert!((24000.0..26000.0).contains(&r), "got {r}");
        let r = t.lookup(8000.0, 150.0);
        assert!((9500.0..10500.0).contains(&r), "got {r}");
    }

    /// The old march: half-square steps, each land sample blocking by its square's tallest corner.
    fn reference_clear(t: &Terrain, table: &RBlockTable, o: Vector2, dx: f32, dz: f32, dist: f32, gun_h: f32) -> bool {
        if dist > table.cap {
            return false;
        }
        let (mut s, mut block_until) = (0.0f32, 0.0f32);
        while s < dist {
            let (px, pz) = (o.x + dx * s, o.y + dz * s);
            if !t.in_bounds(px, pz) {
                return false;
            }
            let sq = t.square(px, pz);
            if t.sdf_min[sq] <= 0.0 {
                let rb = table.lookup(s, t.h_max[sq] - gun_h);
                if rb > dist {
                    return false;
                }
                block_until = block_until.max(rb);
            }
            s += t.cell * 0.5;
        }
        dist >= block_until
    }

    /// 400 x 400 squares of 50 m with a dozen hills; SDF by brute force to the nearest land square.
    fn islands() -> Terrain {
        let (w, h, cell) = (400i32, 400i32, 50.0f32);
        let hills = [(60.0, 80.0, 40.0, 120.0), (200.0, 150.0, 25.0, 60.0), (300.0, 300.0, 60.0, 250.0), (120.0, 320.0, 15.0, 30.0),
            (250.0, 60.0, 30.0, 90.0), (350.0, 180.0, 20.0, 200.0), (160.0, 220.0, 45.0, 40.0), (80.0, 250.0, 10.0, 15.0)];
        let mut height = vec![-5.0f32; (w * h) as usize];
        for z in 0..h {
            for x in 0..w {
                for &(cx, cz, r, peak) in &hills {
                    let d = ((x as f32 - cx).powi(2) + (z as f32 - cz).powi(2)).sqrt();
                    if d < r {
                        let v = peak * (1.0 - d / r) - 5.0;
                        let i = (z * w + x) as usize;
                        height[i] = height[i].max(v);
                    }
                }
            }
        }
        let land: Vec<(i32, i32)> = (0..w * h).filter(|&i| height[i as usize] > 0.0).map(|i| (i % w, i / w)).collect();
        let mut sdf = vec![0.0f32; (w * h) as usize];
        for z in 0..h {
            for x in 0..w {
                let i = (z * w + x) as usize;
                let near = land.iter().map(|&(lx, lz)| (((lx - x).pow(2) + (lz - z).pow(2)) as f32).sqrt()).fold(f32::INFINITY, f32::min);
                sdf[i] = if height[i] > 0.0 { -cell } else { near * cell - cell * 0.5 };
            }
        }
        Terrain::from_grids(w, h, cell, 0.0, 0.0, sdf, height)
    }

    /// The pyramid march may only block more than the half-square march, and rarely does.
    #[test]
    fn pyramid_march_is_conservative_and_close() {
        let t = islands();
        let table = RBlockTable::build(805.0, 2e-5, 12.0, 0.0, 25000.0, false);
        let (mut n, mut differ, mut steps_new, mut steps_old) = (0u32, 0u32, 0u64, 0u64);
        let mut seed = 12345u64;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as f32 / (1u64 << 31) as f32
        };
        for _ in 0..4000 {
            let o = Vector2::new(rnd() * 20000.0, rnd() * 20000.0);
            let p = Vector2::new(rnd() * 20000.0, rnd() * 20000.0);
            let d = p - o;
            let dist = d.length();
            if dist < 100.0 {
                continue;
            }
            let (dx, dz) = (d.x / dist, d.y / dist);
            let (new, s_new, _) = segment_clear_counted(&t, &table, o, dx, dz, dist, 12.0);
            let old = reference_clear(&t, &table, o, dx, dz, dist, 12.0);
            steps_new += s_new as u64;
            steps_old += (dist / (t.cell * 0.5)) as u64;
            assert!(!new || old, "pyramid clear where the reference blocks: {o:?} -> {p:?}");
            n += 1;
            differ += (new != old) as u32;
        }
        assert!(differ * 50 <= n, "{differ} of {n} rays disagree");
        println!("{differ} of {n} rays disagree; steps {steps_new} vs {steps_old}");
    }

    /// Rays per configuration over the synthetic islands; run with --nocapture.
    #[test]
    fn pyramid_depth_bench() {
        let t = islands();
        let table = RBlockTable::build(805.0, 2e-5, 12.0, 0.0, 25000.0, false);
        let mut seed = 99u64;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as f32 / (1u64 << 31) as f32
        };
        let rays: Vec<(Vector2, f32, f32, f32)> = (0..20000).filter_map(|_| {
            let o = Vector2::new(rnd() * 20000.0, rnd() * 20000.0);
            let p = Vector2::new(rnd() * 20000.0, rnd() * 20000.0);
            let d = p - o;
            let dist = d.length();
            (dist > 100.0).then(|| (o, d.x / dist, d.y / dist, dist))
        }).collect();
        let base: Vec<bool> = rays.iter().map(|&(o, dx, dz, dist)| march(&t, &table, o, dx, dz, dist, 12.0, 4, true).0).collect();
        for (top, leap) in [(4, true), (6, true), (9, true), (4, false), (6, false), (9, false)] {
            let t0 = std::time::Instant::now();
            let (mut steps, mut differ) = (0u64, 0u32);
            for (i, &(o, dx, dz, dist)) in rays.iter().enumerate() {
                let (clear, st, _) = march(&t, &table, o, dx, dz, dist, 12.0, top, leap);
                steps += st as u64;
                differ += (clear != base[i]) as u32;
            }
            println!("top {top} leap {leap}: {:.2} us/ray, {:.1} steps/ray, {differ} differ",
                t0.elapsed().as_secs_f64() * 1e6 / rays.len() as f64, steps as f64 / rays.len() as f64);
        }
    }

    /// The pyramid skip reads a block's worst case off its two ends.
    #[test]
    fn r_block_max_is_at_interval_ends() {
        for (v0, beta, gun_h) in [(805.0, 2e-5, 5.0), (762.0, 3e-5, 20.0), (915.0, 1.5e-5, 12.0), (1000.0, 5e-5, 8.0)] {
            let t = RBlockTable::build(v0, beta, gun_h, 0.0, 30000.0, false);
            for h in [2.0f32, 10.0, 30.0, 80.0, 150.0, 300.0] {
                let xs: Vec<f32> = (1..600).map(|i| i as f32 * 50.0).collect();
                let rs: Vec<f32> = xs.iter().map(|&x| t.lookup(x, h)).collect();
                // Quasi-convex: never rises then falls.
                let mut rose = false;
                for w in rs.windows(2) {
                    if w[1] > w[0] + 1.0 {
                        rose = true;
                    } else if rose && w[1] < w[0] - 1.0 && w[0].is_finite() {
                        panic!("v0 {v0} h {h}: falls after rising at {} -> {}", w[0], w[1]);
                    }
                }
            }
        }
    }

    #[test]
    fn mirrored_is_shorter_near_target() {
        let f = yamato(false);
        let m = yamato(true);
        assert!(m.lookup(300.0, 80.0) < f.lookup(300.0, 80.0) - 2000.0);
    }

    #[test]
    fn monotone_in_height_and_cap_is_infinite() {
        let t = yamato(false);
        let mut prev = 0.0;
        for h in [1.0, 5.0, 20.0, 60.0, 120.0, 300.0] {
            let r = t.lookup(1000.0, h);
            assert!(r >= prev, "h={h} r={r} prev={prev}");
            prev = r;
        }
        assert_eq!(t.lookup(1000.0, -10.0), 0.0);
        assert_eq!(t.lookup(200.0, 700.0), f32::INFINITY);
    }
}
