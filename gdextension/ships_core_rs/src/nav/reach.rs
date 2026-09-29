use godot::prelude::*;
use rayon::prelude::*;
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, BinaryHeap, HashMap};
use std::sync::{mpsc, Arc, OnceLock};
use std::time::Instant;

use crate::ballistics::drag_v2::{ProjectilePhysicsWithDragV2 as P, GRAVITY};
use crate::nav::map::NavigationMap;

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
const SWEEP_STEP_MULT: f32 = 0.5;
const RAY_SPACING_MULT: f32 = 0.7;
const MIN_RAYS: usize = 64;
/// Calls here are a few ms; on a 2-socket box the global pool spends longer
/// waking threads across NUMA nodes than working, with 20 ms tails.
const NAV_THREADS: usize = 16;

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
        Self { x_centres, h_edges, r, nx, nh1, x_idx, h_idx, cap: cap as f32 }
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
}

/// Plain copy of the grids the sweep reads, so rayon workers never touch a Gd.
pub(crate) struct Terrain {
    pub(crate) w: i32,
    pub(crate) h: i32,
    pub(crate) cell: f32,
    pub(crate) min_x: f32,
    pub(crate) min_z: f32,
    pub(crate) sdf: Vec<f32>,
    pub(crate) height: Vec<f32>,
}

impl Terrain {
    pub(crate) fn from_map(m: &NavigationMap) -> Self {
        Self {
            w: m.grid_width,
            h: m.grid_height,
            cell: m.cell_size,
            min_x: m.min_x,
            min_z: m.min_z,
            sdf: m.sdf_grid.clone(),
            height: if m.height_mid_grid.len() == m.height_grid.len() {
                m.height_mid_grid.clone()
            } else {
                m.height_grid.clone()
            },
        }
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

struct Field {
    w: i32,
    h: i32,
    cell: f32,
    min_x: f32,
    min_z: f32,
    mult: i32,
    /// 1 where the cell centre is water; averages ignore land cells.
    water: Vec<u8>,
    /// SDF at the cell centre; passable for a hull when >= its clearance.
    sdf: Vec<f32>,
}

impl Field {
    fn index(&self, x: f32, z: f32) -> Option<usize> {
        let ix = ((x - self.min_x) / self.cell).floor() as i32;
        let iz = ((z - self.min_z) / self.cell).floor() as i32;
        if ix < 0 || iz < 0 || ix >= self.w || iz >= self.h {
            return None;
        }
        Some((iz * self.w + ix) as usize)
    }
}

struct SweepInput {
    id: i64,
    origin: Vector2,
    gun_h: f32,
    range: f32,
    /// None sweeps plain line of sight: the first land sample or smoke disc ends the ray.
    table: Option<Arc<RBlockTable>>,
}

type Disc = (Vector2, f32);

struct SweepOutput {
    id: i64,
    bits: Vec<u64>,
    rays: u32,
    samples: u32,
    marks: u32,
}

#[derive(Clone, Copy)]
struct RayState {
    s: f32,
    block_until: f32,
    dead: bool,
}

struct Sweep<'a> {
    t: &'a Terrain,
    f: &'a Field,
    inp: &'a SweepInput,
    smoke: Vec<Disc>,
    bits: Vec<u64>,
    samples: u32,
    marks: u32,
}

impl Sweep<'_> {
    #[inline]
    fn set(&mut self, ix: i32, iz: i32) {
        if ix >= 0 && iz >= 0 && ix < self.f.w && iz < self.f.h {
            let idx = (iz * self.f.w + ix) as usize;
            self.bits[idx / 64] |= 1u64 << (idx % 64);
            self.marks += 1;
        }
    }

    /// Amanatides-Woo walk over field cells from s0 to s1 along the ray.
    fn mark_segment(&mut self, dx: f32, dz: f32, s0: f32, s1: f32) {
        let f = self.f;
        let inv = 1.0 / f.cell;
        let x0 = (self.inp.origin.x + dx * s0 - f.min_x) * inv;
        let z0 = (self.inp.origin.y + dz * s0 - f.min_z) * inv;
        let mut ix = x0.floor() as i32;
        let mut iz = z0.floor() as i32;
        let len = s1 - s0;
        self.set(ix, iz);
        if len <= 0.0 {
            return;
        }
        let (step_x, mut t_max_x, t_delta_x) = if dx > 1e-6 {
            (1, (ix as f32 + 1.0 - x0) * f.cell / dx, f.cell / dx)
        } else if dx < -1e-6 {
            (-1, (x0 - ix as f32) * f.cell / -dx, f.cell / -dx)
        } else {
            (0, f32::INFINITY, f32::INFINITY)
        };
        let (step_z, mut t_max_z, t_delta_z) = if dz > 1e-6 {
            (1, (iz as f32 + 1.0 - z0) * f.cell / dz, f.cell / dz)
        } else if dz < -1e-6 {
            (-1, (z0 - iz as f32) * f.cell / -dz, f.cell / -dz)
        } else {
            (0, f32::INFINITY, f32::INFINITY)
        };
        loop {
            if t_max_x < t_max_z {
                if t_max_x > len {
                    break;
                }
                ix += step_x;
                t_max_x += t_delta_x;
            } else {
                if t_max_z > len {
                    break;
                }
                iz += step_z;
                t_max_z += t_delta_z;
            }
            self.set(ix, iz);
        }
    }

    fn smoke_stop(&self, dx: f32, dz: f32) -> f32 {
        let mut stop = f32::INFINITY;
        for &(c, r) in &self.smoke {
            let (mx, mz) = (self.inp.origin.x - c.x, self.inp.origin.y - c.y);
            let b = mx * dx + mz * dz;
            let cc = mx * mx + mz * mz - r * r;
            if cc <= 0.0 {
                return 0.0;
            }
            let disc = b * b - cc;
            if b < 0.0 && disc >= 0.0 {
                stop = stop.min(-b - disc.sqrt());
            }
        }
        stop
    }

    fn walk(&mut self, ang: f32, st: &mut RayState, s_end: f32) {
        let (dx, dz) = (ang.sin(), ang.cos());
        let stop = self.smoke_stop(dx, dz);
        let s_end = s_end.min(stop);
        let t = self.t;
        let step = t.cell * SWEEP_STEP_MULT;
        let leap_margin = t.cell;
        let (ox, oz) = (self.inp.origin.x, self.inp.origin.y);
        while st.s < s_end && !st.dead {
            let px = ox + dx * st.s;
            let pz = oz + dz * st.s;
            if !t.in_bounds(px, pz) {
                st.dead = true;
                break;
            }
            let d = t.bilinear(&t.sdf, px, pz);
            if d > leap_margin {
                let leap_end = (st.s + d - leap_margin * 0.5).min(s_end);
                let s0 = st.s.max(st.block_until);
                if s0 <= leap_end {
                    self.mark_segment(dx, dz, s0, leap_end);
                }
                st.s = leap_end;
                continue;
            }
            if d <= 0.0 {
                self.samples += 1;
                let Some(table) = &self.inp.table else {
                    st.dead = true;
                    break;
                };
                let h = t.bilinear(&t.height, px, pz) - self.inp.gun_h;
                let rb = table.lookup(st.s, h);
                if rb == f32::INFINITY {
                    st.dead = true;
                    break;
                }
                if rb > st.block_until {
                    st.block_until = rb;
                }
            } else if st.s >= st.block_until {
                self.mark_segment(dx, dz, st.s, st.s);
            }
            st.s += step;
        }
        if st.s >= stop {
            st.dead = true;
        }
    }
}

/// Single-ray version of `Sweep::walk`: true when a shell from `origin` can land
/// `dist` along (dx, dz).
fn segment_clear(t: &Terrain, table: &RBlockTable, origin: Vector2, dx: f32, dz: f32, dist: f32, gun_h: f32) -> bool {
    if dist > table.cap {
        return false;
    }
    let step = t.cell * SWEEP_STEP_MULT;
    let leap_margin = t.cell;
    let mut s = 0.0f32;
    let mut block_until = 0.0f32;
    while s < dist {
        let px = origin.x + dx * s;
        let pz = origin.y + dz * s;
        if !t.in_bounds(px, pz) {
            return false;
        }
        let d = t.bilinear(&t.sdf, px, pz);
        if d > leap_margin {
            s += d - leap_margin * 0.5;
            continue;
        }
        if d <= 0.0 {
            let rb = table.lookup(s, t.bilinear(&t.height, px, pz) - gun_h);
            if rb > dist {
                return false;
            }
            block_until = block_until.max(rb);
        }
        s += step;
    }
    dist >= block_until
}

/// Rays start MIN_RAYS wide and double every time their spacing would exceed
/// RAY_SPACING_MULT field cells; a child inherits its parent's running block.
fn sweep_one(t: &Terrain, f: &Field, inp: &SweepInput, smoke: &[Disc]) -> SweepOutput {
    let range = match &inp.table {
        Some(t) => inp.range.min(t.cap),
        None => inp.range,
    };
    let smoke = match inp.table {
        Some(_) => Vec::new(),
        None => smoke.iter().copied().filter(|&(c, r)| c.distance_to(inp.origin) <= range + r).collect(),
    };
    let mut sw = Sweep {
        t,
        f,
        inp,
        smoke,
        bits: vec![0u64; ((f.w * f.h) as usize + 63) / 64],
        samples: 0,
        marks: 0,
    };
    let r_of = |n: usize| n as f32 * RAY_SPACING_MULT * f.cell / std::f32::consts::TAU;
    let mut n = MIN_RAYS;
    let mut states = vec![RayState { s: 0.0, block_until: 0.0, dead: false }; n];
    let mut rays = 0u32;
    loop {
        let r_end = r_of(n).min(range);
        for k in 0..n {
            if states[k].dead {
                continue;
            }
            let ang = k as f32 * std::f32::consts::TAU / n as f32;
            sw.walk(ang, &mut states[k], r_end);
            rays += 1;
        }
        if r_end >= range {
            break;
        }
        let mut next = Vec::with_capacity(n * 2);
        for st in &states {
            next.push(*st);
            next.push(*st);
        }
        states = next;
        n *= 2;
    }
    SweepOutput { id: inp.id, bits: sw.bits, rays, samples: sw.samples, marks: sw.marks }
}

#[derive(Clone, Copy, PartialEq)]
struct Shell {
    speed: f32,
    drag: f32,
    range: f32,
    gun_h: f32,
}

impl Shell {
    fn has_guns(&self) -> bool {
        self.speed > 0.0 && self.drag > 0.0 && self.range > 0.0
    }
}

#[derive(Clone)]
struct EnemyState {
    origin: Vector2,
    shell: Shell,
    /// Lateral error bar of the believed position; wide ones sweep 3 origins.
    spread: f32,
    /// Certainty 0..1: 1 in sight, decaying for a last-known position, low
    /// for a presumption. Divides distance in the detection field.
    weight: f32,
    force_spot: f32,
    /// Cells this enemy can land shells on (its own forward table).
    fire: Arc<Vec<u64>>,
    /// Cells with line of sight past terrain and smoke to this enemy, out to
    /// the team's largest concealment radius.
    los: Arc<Vec<u64>>,
    /// Per friendly hull key: cells a hull of that kind can hit THIS enemy
    /// from (the hull's mirrored table, swept outward from the enemy).
    reach: HashMap<i64, Arc<Vec<u64>>>,
}

#[derive(Default, Clone)]
struct TeamLayers {
    hulls: HashMap<i64, Shell>,
    enemies: BTreeMap<i64, EnemyState>,
    /// Sorted enemy ids; position = bit index in the masks handed out.
    order: Vec<i64>,
    los_range: f32,
    /// Smoke discs added or removed since this team's last update_team.
    smoke_pending: Vec<Disc>,
    /// Bumped whenever any plane changes; consumers cache off it.
    version: u64,
    /// Min effective distance per cell, INFINITY where no enemy sees it.
    detect: Arc<Vec<f32>>,
    detect_version: u64,
    /// Half-width of the narrowest bearing cone holding every enemy that can
    /// hit the cell (-1 where none can) and that cone's centre bearing.
    cone_half: Arc<Vec<f32>>,
    cone_dir: Arc<Vec<f32>>,
    cone_version: u64,
    /// fire_at per cell: shooter count and presentation-weighted count per heading.
    fire_cells: Arc<Vec<(f32, [f32; 4])>>,
    fire_cells_version: u64,
}

#[derive(Clone)]
pub(crate) struct FireStats {
    pub(crate) max: Arc<Vec<f32>>,
    pub(crate) mean: Arc<Vec<f32>>,
    pub(crate) dir: Arc<Vec<[f32; 4]>>,
}

#[derive(Clone, Copy, PartialEq)]
struct PlanKey {
    team: i32,
    cell: usize,
    radius_q: i32,
    gain_bits: u32,
    clearance_q: i32,
    box_cells: i32,
    mode: i32,
    version: u64,
}

/// One ship's two Dijkstra layers over the field: priced cost to reach each
/// cell from where it stands, and plain distance from each cell to the
/// nearest cell nobody prices.
struct ShipPlan {
    key: PlanKey,
    bx: BoxR,
    safe: Vec<f32>,
    escape: Vec<f32>,
    /// Price integrated along the safe path to each cell (metres x price).
    risk: Vec<f32>,
    price: Vec<f32>,
    pass: Vec<bool>,
    walls_muted: bool,
    max_safe: f32,
    max_escape: f32,
    max_risk: f32,
    us: f32,
}

/// NaN where the cell was rejected.
struct UtilityLayer {
    threat: Vec<f32>,
    utility: Vec<f32>,
    range: (f32, f32),
}

#[derive(Clone, Copy)]
struct BoxR {
    x0: i32,
    z0: i32,
    x1: i32,
    z1: i32,
}

#[derive(PartialEq)]
struct QItem {
    cost: f32,
    idx: u32,
}
impl Eq for QItem {}
impl PartialOrd for QItem {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for QItem {
    fn cmp(&self, o: &Self) -> Ordering {
        o.cost.total_cmp(&self.cost).then_with(|| o.idx.cmp(&self.idx))
    }
}

/// 8-connected Dijkstra inside `bx`; a step costs its length times
/// 1 + gain * mean price of its two ends. Diagonals need both orthogonal
/// neighbours open so no corner is cut through land.
/// Headings the fire price is tabulated for (atan2(x, z) degrees, mod 180:
/// bow-on and stern-on read the same).
pub(crate) const FIRE_HEADINGS: [f32; 4] = [0.0, 45.0, 90.0, 135.0];
/// Share of a shooter's price a hull still pays steaming straight at or
/// away from it; the rest scales with sin^2 of the presentation angle.
const FIRE_BOW_FACTOR: f32 = 0.35;

pub(crate) fn fire_heading_bucket(dx: f32, dz: f32) -> usize {
    let deg = dx.atan2(dz).to_degrees().rem_euclid(180.0);
    ((deg / 45.0).round() as usize) % 4
}

/// (shooter count, presentation-weighted count per FIRE_HEADINGS) at cell `idx`.
/// (sin, cos) of each FIRE_HEADINGS entry, so a shooter's presentation on
/// every heading is a cross product against its bearing unit vector.
fn fire_heading_units() -> [(f32, f32); 4] {
    FIRE_HEADINGS.map(|h| h.to_radians().sin_cos())
}

fn fire_at(f: &Field, shooters: &[(&[u64], Vector2)], units: &[(f32, f32); 4], idx: usize) -> (f32, [f32; 4]) {
    let c = f.centre(idx);
    let mut n = 0.0f32;
    let mut d = [0.0f32; 4];
    for (plane, origin) in shooters {
        if !bit_at(plane, idx) {
            continue;
        }
        n += 1.0;
        let (dx, dz) = (origin.x - c.x, origin.y - c.y);
        let inv = 1.0 / (dx * dx + dz * dz).sqrt().max(1e-3);
        let (bx, bz) = (dx * inv, dz * inv);
        for (k, (sh, ch)) in units.iter().enumerate() {
            let s = sh * bz - ch * bx;
            d[k] += FIRE_BOW_FACTOR + (1.0 - FIRE_BOW_FACTOR) * s * s;
        }
    }
    (n, d)
}

fn dijkstra(
    f: &Field,
    bx: BoxR,
    pass: &[bool],
    price: &[f32],
    dir_price: Option<&[[f32; 4]]>,
    gain: f32,
    sources: &[usize],
    out: &mut [f32],
    mut risk: Option<&mut [f32]>,
) {
    let mut heap = BinaryHeap::new();
    for &s in sources {
        out[s] = 0.0;
        if let Some(r) = risk.as_deref_mut() {
            r[s] = 0.0;
        }
        heap.push(QItem { cost: 0.0, idx: s as u32 });
    }
    let w = f.w;
    let diag = f.cell * std::f32::consts::SQRT_2;
    let bucket: [usize; 9] = std::array::from_fn(|k| fire_heading_bucket((k % 3) as f32 - 1.0, (k / 3) as f32 - 1.0));
    while let Some(QItem { cost, idx }) = heap.pop() {
        let idx = idx as usize;
        if cost > out[idx] {
            continue;
        }
        let (ix, iz) = (idx as i32 % w, idx as i32 / w);
        for dz in -1..=1 {
            for dx in -1..=1 {
                if dx == 0 && dz == 0 {
                    continue;
                }
                let (nx, nz) = (ix + dx, iz + dz);
                if nx < bx.x0 || nx > bx.x1 || nz < bx.z0 || nz > bx.z1 {
                    continue;
                }
                let n = (nz * w + nx) as usize;
                if !pass[n] {
                    continue;
                }
                let len = if dx != 0 && dz != 0 {
                    if !pass[(iz * w + nx) as usize] || !pass[(nz * w + ix) as usize] {
                        continue;
                    }
                    diag
                } else {
                    f.cell
                };
                let (pa, pb) = match dir_price {
                    Some(dp) => {
                        let k = bucket[((dz + 1) * 3 + dx + 1) as usize];
                        (dp[idx][k], dp[n][k])
                    }
                    None => (price[idx], price[n]),
                };
                let step_risk = len * 0.5 * (pa + pb);
                let c = cost + len + gain * step_risk;
                if c < out[n] {
                    out[n] = c;
                    if let Some(r) = risk.as_deref_mut() {
                        r[n] = r[idx] + step_risk;
                    }
                    heap.push(QItem { cost: c, idx: n as u32 });
                }
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Layer {
    Fire,
    Los,
    Reach(i64),
}

const SPREAD_MIN: f32 = 150.0;
const WEIGHT_FLOOR: f32 = 0.05;

fn origins_for(origin: Vector2, spread: f32) -> Vec<Vector2> {
    if spread < SPREAD_MIN {
        return vec![origin];
    }
    (0..3)
        .map(|k| {
            let a = k as f32 * std::f32::consts::TAU / 3.0;
            origin + Vector2::new(a.sin(), a.cos()) * spread
        })
        .collect()
}

fn count_plane(plane: &[u64], counts: &mut [u8]) {
    for (w, &word) in plane.iter().enumerate() {
        let mut bits = word;
        while bits != 0 {
            let b = bits.trailing_zeros() as usize;
            let idx = w * 64 + b;
            if idx < counts.len() {
                counts[idx] = counts[idx].saturating_add(1);
            }
            bits &= bits - 1;
        }
    }
}

fn bit_at(plane: &[u64], idx: usize) -> bool {
    plane[idx / 64] & (1u64 << (idx % 64)) != 0
}

#[derive(Default, Clone, Copy)]
struct Stats {
    total_us: f32,
    ships: u32,
    rays: u32,
    samples: u32,
    marks: u32,
    table_builds: u32,
    table_build_us: f32,
}

impl Stats {
    fn add(&mut self, o: &Stats) {
        self.total_us += o.total_us;
        self.ships += o.ships;
        self.rays += o.rays;
        self.samples += o.samples;
        self.marks += o.marks;
        self.table_builds += o.table_builds;
        self.table_build_us += o.table_build_us;
    }

    fn to_dict(self, tables_cached: usize) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("total_us", self.total_us);
        d.set("ships", self.ships as i64);
        d.set("rays", self.rays as i64);
        d.set("land_samples", self.samples as i64);
        d.set("marks", self.marks as i64);
        d.set("table_builds", self.table_builds as i64);
        d.set("table_build_us", self.table_build_us);
        d.set("tables_cached", tables_cached as i64);
        d
    }
}

#[derive(Clone, Copy, Default)]
struct UpdateStats {
    stats: Stats,
    resweeps: u32,
    jobs: u32,
    enemies: u32,
    hulls: u32,
}

#[derive(Clone, Copy)]
struct PlanStats {
    cached: bool,
    us: f32,
    walls_muted: bool,
    escape_here: f32,
    max_safe: f32,
    max_escape: f32,
    max_risk: f32,
    marker: Option<(Vector2, f32)>,
}

impl PlanStats {
    fn to_dict(self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("cached", self.cached);
        d.set("us", self.us);
        d.set("walls_muted", self.walls_muted);
        d.set("escape_here", self.escape_here);
        d.set("max_safe", self.max_safe);
        d.set("max_escape", self.max_escape);
        d.set("max_risk", self.max_risk);
        d.set("has_marker", self.marker.is_some());
        d.set("marker", self.marker.map_or(Vector2::ZERO, |m| m.0));
        d.set("marker_cost", self.marker.map_or(f32::INFINITY, |m| m.1));
        d
    }
}

#[derive(Clone, Copy)]
enum Terms {
    Utility(UtilityTerms),
    Station(StationTerms),
}

impl Terms {
    fn score(&self) -> f32 {
        match self {
            Terms::Utility(t) => t.utility,
            Terms::Station(t) => t.score,
        }
    }

    fn to_dict(&self) -> VarDictionary {
        match self {
            Terms::Utility(t) => t.to_dict(),
            Terms::Station(t) => t.to_dict(),
        }
    }
}

const KIND_STATION: u8 = 0;
const KIND_UTILITY: u8 = 1;

#[derive(Clone)]
struct ScoreResult {
    token: i64,
    best: Option<(Vector2, Terms)>,
    here: Option<Terms>,
    held: Option<Terms>,
    cells: u32,
    us: f32,
}

impl ScoreResult {
    fn new(token: i64) -> Self {
        Self { token, best: None, here: None, held: None, cells: 0, us: 0.0 }
    }

    fn to_dict(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("token", self.token);
        d.set("has_best", self.best.is_some());
        if let Some((p, t)) = &self.best {
            d.set("best", *p);
            d.set("best_score", t.score());
            d.set("best_terms", &t.to_dict());
        }
        if let Some(t) = &self.here {
            d.set("here_terms", &t.to_dict());
        }
        d.set("held_score", self.held.map_or(f32::NEG_INFINITY, |t| t.score()));
        if let Some(t) = &self.held {
            d.set("held_terms", &t.to_dict());
        }
        d.set("cells", self.cells as i64);
        d.set("us", self.us);
        d
    }
}

type ExposureKey = (i32, i32, i32, i32, i32);
type FireKey = (i32, i32, i32, i32);
type ExposureStats = (u64, Arc<Vec<f32>>, Arc<Vec<f32>>);

struct UpdateReq {
    team: i32,
    rows: Vec<(i64, Vector2, Shell, f32, f32, f32)>,
    los_range: f32,
    target_h: f32,
    move_threshold: f32,
}

struct PlanReq {
    team: i32,
    pos: Vector2,
    radius: f32,
    gain: f32,
    clearance: f32,
    box_radius: f32,
    mode: i32,
    toward: Vector2,
}

enum Op {
    Smoke(Vec<Disc>),
    Hulls(i32, HashMap<i64, Shell>),
    Update(UpdateReq),
    /// id, origin, gun_h, target_h, speed, drag, range
    Sweep(Vec<(i64, Vector2, f32, f32, f32, f32, f32)>),
    Forget(i64),
    Clear,
    WatchExposure(ExposureKey),
    WatchFire(FireKey),
    /// speed, drag, gun_h, target_h, range: forward and mirrored tables.
    Prebuild(Vec<(f32, f32, f32, f32, f32)>),
}

#[derive(Default)]
struct ShipReqs {
    plan: Option<PlanReq>,
    utility: Option<(i64, i32, i64, UtilityArgs)>,
    station: Option<(i64, i32, i64, StationArgs)>,
}

/// Ships run plan before scores, so a score sees the plan queued with it.
#[derive(Default)]
struct Batch {
    ops: Vec<Op>,
    ships: Vec<(i64, ShipReqs)>,
}

impl Batch {
    fn is_empty(&self) -> bool {
        self.ops.is_empty() && self.ships.is_empty()
    }
}

#[derive(Default, Clone)]
struct Snapshot {
    terrain: Option<Arc<Terrain>>,
    field: Option<Arc<Field>>,
    teams: HashMap<i32, Arc<TeamLayers>>,
    ships: HashMap<i64, Arc<Vec<u64>>>,
    plans: HashMap<i64, Arc<ShipPlan>>,
    plan_stats: HashMap<i64, PlanStats>,
    utility: HashMap<i64, Arc<UtilityLayer>>,
    exposure: HashMap<ExposureKey, ExposureStats>,
    fire: HashMap<FireKey, (u64, FireStats)>,
    last: Stats,
    tables_cached: usize,
    backlog: usize,
}

struct Delivery {
    snap: Snapshot,
    team_stats: Vec<(i32, UpdateStats)>,
    scores: Vec<(i64, u8, ScoreResult)>,
    busy_us: f32,
}

struct SweepJob {
    id: i64,
    layer: Layer,
    shell: Shell,
    origin: Vector2,
    /// First origin of its (enemy, layer): clears the plane before ORing in.
    zero: bool,
    target_h: f32,
    los_range: f32,
}

/// [fire and line of sight, reach]: threat planes drain first.
type Backlog = [std::collections::VecDeque<SweepJob>; 2];

#[derive(Default)]
struct FieldCore {
    backlog: BTreeMap<i32, Backlog>,
    job_budget: Option<usize>,
    terrain: Option<Arc<Terrain>>,
    field: Option<Arc<Field>>,
    tables: HashMap<TableKey, Arc<RBlockTable>>,
    ships: HashMap<i64, Arc<Vec<u64>>>,
    teams: BTreeMap<i32, TeamLayers>,
    smoke: Arc<Vec<Disc>>,
    /// (team, radius / EXPOSURE_RADIUS_Q, node cells, ncx, ncz) -> (version,
    /// max, mean). Every navigator on a team with the same concealment reads
    /// the same vectors instead of rebuilding them from 123k cells each.
    exposure_cache: HashMap<ExposureKey, ExposureStats>,
    /// (team, node cells, ncx, ncz) -> (version, max, mean, per-heading mean).
    fire_cache: HashMap<FireKey, (u64, FireStats)>,
    exposure_watch: BTreeSet<ExposureKey>,
    fire_watch: BTreeSet<FireKey>,
    plans: HashMap<i64, Arc<ShipPlan>>,
    plan_stats: HashMap<i64, PlanStats>,
    utility: HashMap<i64, Arc<UtilityLayer>>,
    last: Stats,
}

const EXPOSURE_RADIUS_Q: f32 = 250.0;
/// Exposure is 1 at effective distance zero and keeps rising inside a
/// force-spot disc (negative distance); capped so a radar centre prices at
/// most this many times the concealment edge.
const EXPOSURE_MAX: f32 = 3.0;

fn exposure_key(team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> (ExposureKey, f32) {
    let radius = (radius / EXPOSURE_RADIUS_Q).ceil() * EXPOSURE_RADIUS_Q;
    ((team, (radius / EXPOSURE_RADIUS_Q) as i32, cluster_cells, ncx, ncz), radius)
}

fn cluster_of(f: &Field, idx: usize, cluster_cells: i32, ncx: i32, ncz: i32) -> Option<usize> {
    let cx = (idx as i32 % f.w) * f.mult / cluster_cells;
    let cz = (idx as i32 / f.w) * f.mult / cluster_cells;
    (cx >= 0 && cz >= 0 && cx < ncx && cz < ncz).then(|| (cz * ncx + cx) as usize)
}

/// Per node: max and mean shooter count over water cells, and the mean
/// presentation-weighted count for a hull steaming on each of the four
/// FIRE_HEADINGS. The router's fire price; never a wall.
fn build_fire_stats(f: &Field, tl: &TeamLayers, cluster_cells: i32, ncx: i32, ncz: i32) -> FireStats {
    let n = (ncx.max(0) * ncz.max(0)) as usize;
    let mut max = vec![0.0f32; n];
    let mut mean = vec![0.0f32; n];
    let mut dir = vec![[0.0f32; 4]; n];
    if cluster_cells > 0 && tl.fire_cells.len() == f.water.len() {
        let mut count = vec![0u32; n];
        for idx in 0..f.water.len() {
            if f.water[idx] == 0 {
                continue;
            }
            let Some(c) = cluster_of(f, idx, cluster_cells, ncx, ncz) else { continue };
            count[c] += 1;
            let (e, d) = tl.fire_cells[idx];
            mean[c] += e;
            for k in 0..4 {
                dir[c][k] += d[k];
            }
            if e > max[c] {
                max[c] = e;
            }
        }
        for c in 0..n {
            if count[c] > 0 {
                let inv = 1.0 / count[c] as f32;
                mean[c] *= inv;
                for k in 0..4 {
                    dir[c][k] *= inv;
                }
            }
        }
    }
    FireStats { max: Arc::new(max), mean: Arc::new(mean), dir: Arc::new(dir) }
}

/// Per node of `cluster_cells` SDF cells: (max, mean over water cells) of
/// exposure, 0 outside detection to 1 at effective distance zero.
fn build_exposure_stats(f: &Field, tl: &TeamLayers, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> (Vec<f32>, Vec<f32>) {
    let n = (ncx.max(0) * ncz.max(0)) as usize;
    let mut max = vec![0.0f32; n];
    let mut mean = vec![0.0f32; n];
    if radius <= 0.0 || cluster_cells <= 0 {
        return (max, mean);
    }
    let mut count = vec![0u32; n];
    for (idx, &d) in tl.detect.iter().enumerate() {
        if f.water[idx] == 0 {
            continue;
        }
        let Some(c) = cluster_of(f, idx, cluster_cells, ncx, ncz) else { continue };
        count[c] += 1;
        if d >= radius {
            continue;
        }
        let e = ((radius - d) / radius).clamp(0.0, EXPOSURE_MAX);
        mean[c] += e;
        if e > max[c] {
            max[c] = e;
        }
    }
    for c in 0..n {
        if count[c] > 0 {
            mean[c] /= count[c] as f32;
        }
    }
    (max, mean)
}

fn new_table(v0: f32, beta: f32, gun_h: f32, tgt_h: f32, cap: f32, mirrored: bool) -> Arc<RBlockTable> {
    Arc::new(RBlockTable::build(v0 as f64, beta as f64, gun_h as f64, tgt_h as f64, cap as f64, mirrored))
}

impl FieldCore {
    fn build(m: &NavigationMap, cell_mult: i32) -> Self {
        let mult = cell_mult.max(1);
        let terrain = Terrain::from_map(m);
        let (fw, fh) = ((m.grid_width + mult - 1) / mult, (m.grid_height + mult - 1) / mult);
        let fcell = m.cell_size * mult as f32;
        let mut water = vec![0u8; (fw * fh) as usize];
        let mut sdf = vec![f32::NEG_INFINITY; (fw * fh) as usize];
        for iz in 0..fh {
            for ix in 0..fw {
                let x = m.min_x + (ix as f32 + 0.5) * fcell;
                let z = m.min_z + (iz as f32 + 0.5) * fcell;
                if !terrain.in_bounds(x, z) {
                    continue;
                }
                let d = terrain.bilinear(&terrain.sdf, x, z);
                sdf[(iz * fw + ix) as usize] = d;
                if d > 0.0 {
                    water[(iz * fw + ix) as usize] = 1;
                }
            }
        }
        Self {
            field: Some(Arc::new(Field { w: fw, h: fh, cell: fcell, min_x: m.min_x, min_z: m.min_z, mult, water, sdf })),
            terrain: Some(Arc::new(terrain)),
            ..Default::default()
        }
    }

    fn table(&mut self, v0: f32, beta: f32, gun_h: f32, tgt_h: f32, cap: f32, mirrored: bool) -> Arc<RBlockTable> {
        let key = TableKey::new(v0, beta, gun_h, tgt_h, cap, mirrored);
        if let Some(t) = self.tables.get(&key) {
            return t.clone();
        }
        let t0 = Instant::now();
        let t = new_table(v0, beta, gun_h, tgt_h, cap, mirrored);
        self.last.table_builds += 1;
        self.last.table_build_us += t0.elapsed().as_secs_f32() * 1e6;
        self.tables.insert(key, t.clone());
        t
    }

    fn prebuild_tables(&mut self, guns: &[(f32, f32, f32, f32, f32)]) {
        let mut todo: Vec<(TableKey, (f32, f32, f32, f32, f32, bool))> = Vec::new();
        for &(v0, beta, gun_h, tgt_h, cap) in guns {
            if v0 <= 0.0 || beta <= 0.0 || cap <= 0.0 {
                continue;
            }
            for mirrored in [false, true] {
                let key = TableKey::new(v0, beta, gun_h, tgt_h, cap, mirrored);
                if !self.tables.contains_key(&key) && !todo.iter().any(|(k, _)| *k == key) {
                    todo.push((key, (v0, beta, gun_h, tgt_h, cap, mirrored)));
                }
            }
        }
        let t0 = Instant::now();
        let built: Vec<(TableKey, Arc<RBlockTable>)> = nav_pool().install(|| {
            todo.par_iter().map(|&(k, (v0, beta, gun_h, tgt_h, cap, m))| (k, new_table(v0, beta, gun_h, tgt_h, cap, m))).collect()
        });
        self.last.table_builds += built.len() as u32;
        self.last.table_build_us += t0.elapsed().as_secs_f32() * 1e6;
        self.tables.extend(built);
    }

    fn run_jobs(&mut self, inputs: &[SweepInput]) -> Vec<SweepOutput> {
        let (Some(terrain), Some(field)) = (self.terrain.clone(), self.field.clone()) else {
            return Vec::new();
        };
        let t0 = Instant::now();
        let outs: Vec<SweepOutput> = inputs.iter().map(|inp| sweep_one(&terrain, &field, inp, &self.smoke)).collect();
        for o in &outs {
            self.last.rays += o.rays;
            self.last.samples += o.samples;
            self.last.marks += o.marks;
        }
        self.last.ships += inputs.len() as u32;
        self.last.total_us += t0.elapsed().as_secs_f32() * 1e6;
        outs
    }

    fn sweep_ships(&mut self, rows: Vec<(i64, Vector2, f32, f32, f32, f32, f32)>) {
        self.last = Stats::default();
        if self.field.is_none() {
            return;
        }
        let mut inputs = Vec::with_capacity(rows.len());
        for (id, origin, gun_h, target_h, speed, drag, range) in rows {
            if speed <= 0.0 || drag <= 0.0 || range <= 0.0 {
                continue;
            }
            let table = Some(self.table(speed, drag, gun_h, target_h, range, false));
            inputs.push(SweepInput { id, origin, gun_h, range, table });
        }
        for o in self.run_jobs(&inputs) {
            self.ships.insert(o.id, Arc::new(o.bits));
        }
    }

    fn cell_count(&self) -> usize {
        self.field.as_ref().map_or(0, |f| (f.w * f.h) as usize)
    }

    fn ensure_detect(&mut self, team: i32) {
        let Some(f) = self.field.clone() else { return };
        let Some(tl) = self.teams.get_mut(&team) else { return };
        if tl.detect_version == tl.version && tl.detect.len() == (f.w * f.h) as usize {
            return;
        }
        let mut grid = vec![f32::INFINITY; (f.w * f.h) as usize];
        let eyes: Vec<(&[u64], Vector2, f32, f32)> = tl.enemies.values()
            .map(|e| (e.los.as_slice(), e.origin, 1.0 / e.weight.max(WEIGHT_FLOOR), e.force_spot))
            .collect();
        for (idx, g) in grid.iter_mut().enumerate() {
            let c = f.centre(idx);
            for &(los, origin, inv_w, force_spot) in &eyes {
                let d = c.distance_to(origin);
                // Inside a radar/hydro reach the value runs NEGATIVE toward
                // the emitter, so a ship already inside still sees which
                // way is out; outside it is distance over certainty.
                let eff = if d < force_spot {
                    d - force_spot
                } else if bit_at(los, idx) {
                    d * inv_w
                } else {
                    continue;
                };
                if eff < *g {
                    *g = eff;
                }
            }
        }
        tl.detect = Arc::new(grid);
        tl.detect_version = tl.version;
    }

    fn ensure_fire_cells(&mut self, team: i32) {
        let Some(f) = self.field.clone() else { return };
        let Some(tl) = self.teams.get_mut(&team) else { return };
        if tl.fire_cells_version == tl.version && tl.fire_cells.len() == f.water.len() {
            return;
        }
        let shooters: Vec<(&[u64], Vector2)> = tl.enemies.values().map(|e| (e.fire.as_slice(), e.origin)).collect();
        let units = fire_heading_units();
        let cells: Vec<(f32, [f32; 4])> = (0..f.water.len())
            .map(|idx| if f.water[idx] == 0 { (0.0, [0.0; 4]) } else { fire_at(&f, &shooters, &units, idx) })
            .collect();
        tl.fire_cells = Arc::new(cells);
        tl.fire_cells_version = tl.version;
    }

    fn ensure_cone(&mut self, team: i32) {
        let Some(f) = self.field.clone() else { return };
        let cells = (f.w * f.h) as usize;
        let Some(tl) = self.teams.get_mut(&team) else { return };
        if tl.cone_version == tl.version && tl.cone_half.len() == cells {
            return;
        }
        let enemies: Vec<(Vector2, &[u64])> =
            tl.order.iter().map(|id| (tl.enemies[id].origin, tl.enemies[id].fire.as_slice())).collect();
        let mut half = vec![-1.0f32; cells];
        let mut dir = vec![0.0f32; cells];
        let mut b: Vec<f32> = Vec::with_capacity(enemies.len());
        for idx in 0..cells {
            if f.water[idx] == 0 {
                continue;
            }
            b.clear();
            let c = f.centre(idx);
            for (o, plane) in &enemies {
                if bit_at(plane, idx) {
                    b.push((o.x - c.x).atan2(o.y - c.y));
                }
            }
            if b.is_empty() {
                continue;
            }
            b.sort_by(|p, q| p.total_cmp(q));
            let n = b.len();
            let mut gap = b[0] + std::f32::consts::TAU - b[n - 1];
            let mut start = b[0];
            for i in 0..n - 1 {
                if b[i + 1] - b[i] > gap {
                    gap = b[i + 1] - b[i];
                    start = b[i + 1];
                }
            }
            let cone = std::f32::consts::TAU - gap;
            half[idx] = 0.5 * cone;
            let mut mid = start + 0.5 * cone;
            if mid > std::f32::consts::PI {
                mid -= std::f32::consts::TAU;
            }
            dir[idx] = mid;
        }
        tl.cone_half = Arc::new(half);
        tl.cone_dir = Arc::new(dir);
        tl.cone_version = tl.version;
    }

    fn cluster_exposure_stats(&mut self, key: ExposureKey) {
        let version = self.teams.get(&key.0).map_or(0, |tl| tl.version);
        if self.exposure_cache.get(&key).is_some_and(|c| c.0 == version) {
            return;
        }
        self.ensure_detect(key.0);
        let (Some(f), Some(tl)) = (self.field.as_ref(), self.teams.get(&key.0)) else { return };
        let radius = key.1 as f32 * EXPOSURE_RADIUS_Q;
        let (max, mean) = build_exposure_stats(f, tl, radius, key.2, key.3, key.4);
        self.exposure_cache.insert(key, (version, Arc::new(max), Arc::new(mean)));
    }

    fn cluster_fire_stats(&mut self, key: FireKey) {
        let version = self.teams.get(&key.0).map_or(0, |tl| tl.version);
        if self.fire_cache.get(&key).is_some_and(|c| c.0 == version) {
            return;
        }
        self.ensure_fire_cells(key.0);
        let (Some(f), Some(tl)) = (self.field.as_ref(), self.teams.get(&key.0)) else { return };
        let st = build_fire_stats(f, tl, key.1, key.2, key.3);
        self.fire_cache.insert(key, (version, st));
    }

    fn set_smoke(&mut self, next: Vec<Disc>) {
        let key = |&(c, r): &Disc| (c.x.to_bits(), c.y.to_bits(), r.to_bits());
        let old: std::collections::HashSet<_> = self.smoke.iter().map(key).collect();
        let new: std::collections::HashSet<_> = next.iter().map(key).collect();
        let changed: Vec<Disc> = self.smoke.iter().filter(|d| !new.contains(&key(d)))
            .chain(next.iter().filter(|d| !old.contains(&key(d))))
            .copied()
            .collect();
        if changed.is_empty() {
            return;
        }
        for tl in self.teams.values_mut() {
            tl.smoke_pending.extend_from_slice(&changed);
        }
        self.smoke = Arc::new(next);
    }

    fn set_team_hulls(&mut self, team: i32, hulls: HashMap<i64, Shell>) {
        let tl = self.teams.entry(team).or_default();
        for e in tl.enemies.values_mut() {
            e.reach.retain(|k, _| hulls.get(k) == tl.hulls.get(k) && hulls.contains_key(k));
        }
        tl.hulls = hulls;
    }

    fn update_team(&mut self, r: UpdateReq) -> UpdateStats {
        self.last = Stats::default();
        let (team, los_range, target_h, move_threshold) = (r.team, r.los_range, r.target_h, r.move_threshold);
        let words = (self.cell_count() + 63) / 64;
        // One entry per (enemy, layer, origin); planes are zeroed per (enemy,
        // layer) and the origins ORed in.
        let mut plan: Vec<(i64, Layer, Shell, Vector2)> = Vec::new();
        let mut resweeps = 0u32;
        let mut detect_stale = false;
        {
            let tl = self.teams.entry(team).or_default();
            let los_changed = (tl.los_range - los_range).abs() > 1.0;
            tl.los_range = los_range;
            let smoke_pending = std::mem::take(&mut tl.smoke_pending);
            let live: std::collections::HashSet<i64> = r.rows.iter().map(|row| row.0).collect();
            let before = tl.enemies.len();
            tl.enemies.retain(|id, _| live.contains(id));
            if tl.enemies.len() != before {
                tl.version += 1;
            }
            for &(id, origin, shell, spread, weight, force_spot) in &r.rows {
                let spread = spread.max(0.0);
                let full = match tl.enemies.get_mut(&id) {
                    Some(e) => {
                        let moved = e.origin.distance_to(origin) > move_threshold;
                        let changed = e.shell != shell || (e.spread - spread).abs() > move_threshold;
                        detect_stale |= e.weight != weight || e.force_spot != force_spot;
                        e.origin = origin;
                        e.shell = shell;
                        e.spread = spread;
                        e.weight = weight;
                        e.force_spot = force_spot;
                        moved || changed
                    }
                    None => {
                        tl.enemies.insert(id, EnemyState {
                            origin,
                            shell,
                            spread,
                            weight,
                            force_spot,
                            fire: Arc::new(vec![0u64; words]),
                            los: Arc::new(vec![0u64; words]),
                            reach: HashMap::new(),
                        });
                        true
                    }
                };
                let e = &tl.enemies[&id];
                let origins = origins_for(origin, spread);
                if full {
                    resweeps += 1;
                }
                let smoked = smoke_pending.iter().any(|&(c, r)| c.distance_to(origin) <= los_range + spread + r);
                if full || los_changed || smoked {
                    for &o in &origins {
                        plan.push((id, Layer::Los, shell, o));
                    }
                }
                if shell.has_guns() {
                    if full {
                        for &o in &origins {
                            plan.push((id, Layer::Fire, shell, o));
                        }
                    }
                    let mut keys: Vec<(&i64, &Shell)> = tl.hulls.iter().collect();
                    keys.sort_by_key(|(k, _)| **k);
                    for (&hk, hull) in keys {
                        if full || !e.reach.contains_key(&hk) {
                            for &o in &origins {
                                plan.push((id, Layer::Reach(hk), *hull, o));
                            }
                        }
                    }
                }
            }
            tl.order = tl.enemies.keys().copied().collect();
            // Detection depends on weight and force_spot even when nothing is
            // re-swept.
            if detect_stale {
                tl.detect_version = u64::MAX;
            }
        }
        let tl = &self.teams[&team];
        let live: std::collections::HashSet<i64> = tl.order.iter().copied().collect();
        let (enemies, hulls) = (tl.order.len() as u32, tl.hulls.len() as u32);
        let fresh: std::collections::HashSet<(i64, Layer)> = plan.iter().map(|p| (p.0, p.1)).collect();
        let q = self.backlog.entry(team).or_default();
        for tier in q.iter_mut() {
            tier.retain(|j| live.contains(&j.id) && !fresh.contains(&(j.id, j.layer)));
        }
        let mut seen: std::collections::HashSet<(i64, Layer)> = std::collections::HashSet::new();
        for (id, layer, shell, origin) in plan.iter().copied() {
            let tier = usize::from(matches!(layer, Layer::Reach(_)));
            q[tier].push_back(SweepJob { id, layer, shell, origin, zero: seen.insert((id, layer)), target_h, los_range });
        }
        UpdateStats { stats: Stats::default(), resweeps, jobs: plan.len() as u32, enemies, hulls }
    }

    fn drain(&mut self) -> Vec<(i32, Stats)> {
        let mut left = self.job_budget.unwrap_or(usize::MAX);
        let words = (self.cell_count() + 63) / 64;
        let mut out: Vec<(i32, Stats)> = Vec::new();
        let teams: Vec<i32> = self.backlog.keys().copied().collect();
        for tier in 0..2 {
            for &team in &teams {
                if left == 0 {
                    break;
                }
                let q = &mut self.backlog.get_mut(&team).unwrap()[tier];
                let n = left.min(q.len());
                if n == 0 {
                    continue;
                }
                left -= n;
                let jobs: Vec<SweepJob> = q.drain(..n).collect();
                let saved = std::mem::take(&mut self.last);
                let mut inputs = Vec::with_capacity(jobs.len());
                for (j, job) in jobs.iter().enumerate() {
                    let sh = job.shell;
                    let (table, range) = match job.layer {
                        Layer::Fire => (Some(self.table(sh.speed, sh.drag, sh.gun_h, job.target_h, sh.range, false)), sh.range),
                        Layer::Reach(_) => (Some(self.table(sh.speed, sh.drag, sh.gun_h, job.target_h, sh.range, true)), sh.range),
                        Layer::Los => (None, job.los_range),
                    };
                    inputs.push(SweepInput { id: j as i64, origin: job.origin, gun_h: sh.gun_h, range, table });
                }
                let outs = self.run_jobs(&inputs);
                let Some(tl) = self.teams.get_mut(&team) else { continue };
                for o in outs {
                    let job = &jobs[o.id as usize];
                    let Some(e) = tl.enemies.get_mut(&job.id) else { continue };
                    let arc = match job.layer {
                        Layer::Fire => &mut e.fire,
                        Layer::Los => &mut e.los,
                        Layer::Reach(hk) => e.reach.entry(hk).or_insert_with(|| Arc::new(vec![0u64; words])),
                    };
                    let plane = Arc::make_mut(arc);
                    if job.zero {
                        plane.iter_mut().for_each(|w| *w = 0);
                    }
                    for (d, s) in plane.iter_mut().zip(o.bits.iter()) {
                        *d |= s;
                    }
                }
                tl.version += 1;
                let st = std::mem::replace(&mut self.last, saved);
                match out.iter_mut().find(|(t, _)| *t == team) {
                    Some((_, acc)) => acc.add(&st),
                    None => out.push((team, st)),
                }
            }
        }
        out
    }

    fn forget(&mut self, id: i64) {
        self.ships.remove(&id);
        self.plans.remove(&id);
        self.plan_stats.remove(&id);
        self.utility.remove(&id);
    }

    fn clear(&mut self) {
        self.ships.clear();
        self.teams.clear();
        self.backlog.clear();
        self.plans.clear();
        self.plan_stats.clear();
        self.utility.clear();
        self.exposure_cache.clear();
        self.fire_cache.clear();
    }

    fn plan_ship(&mut self, id: i64, r: PlanReq) {
        let Some(f) = self.field.clone() else { return };
        let Some(cell) = f.index(r.pos.x, r.pos.y) else { return };
        if r.mode == 0 {
            self.ensure_detect(r.team);
        } else {
            self.ensure_fire_cells(r.team);
        }
        let version = self.teams.get(&r.team).map_or(0, |t| t.version);
        let key = PlanKey {
            team: r.team,
            cell,
            radius_q: r.radius.round() as i32,
            gain_bits: r.gain.to_bits(),
            clearance_q: r.clearance.round() as i32,
            box_cells: (r.box_radius / f.cell).ceil().max(1.0) as i32,
            mode: r.mode,
            version,
        };
        let cached = self.plans.get(&id).is_some_and(|p| p.key == key);
        if !cached {
            let plan = self.build_plan(&f, key, r.radius, r.gain, r.clearance);
            self.plans.insert(id, Arc::new(plan));
            self.utility.remove(&id);
        }
        let p = &self.plans[&id];
        let mut best: Option<(f32, usize)> = None;
        for iz in p.bx.z0..=p.bx.z1 {
            for ix in p.bx.x0..=p.bx.x1 {
                let i = (iz * f.w + ix) as usize;
                if !p.pass[i] || p.price[i] > 0.0 || !p.safe[i].is_finite() {
                    continue;
                }
                let dist = f.centre(i).distance_squared_to(r.toward);
                if best.is_none_or(|(b, _)| dist < b) {
                    best = Some((dist, i));
                }
            }
        }
        let st = PlanStats {
            cached,
            us: p.us,
            walls_muted: p.walls_muted,
            escape_here: p.escape[cell],
            max_safe: p.max_safe,
            max_escape: p.max_escape,
            max_risk: p.max_risk,
            marker: best.map(|(_, i)| (f.centre(i), p.safe[i])),
        };
        self.plan_stats.insert(id, st);
    }

    fn score_utility(&mut self, id: i64, token: i64, team: i32, hull_key: i64, a: &UtilityArgs) -> ScoreResult {
        let t0 = Instant::now();
        let mut r = ScoreResult::new(token);
        self.ensure_cone(team);
        let (Some(f), Some(tl), Some(p)) = (self.field.clone(), self.teams.get(&team), self.plans.get(&id).cloned()) else {
            return r;
        };
        let (ev, norm) = enemy_evals(&f, tl, hull_key, a, f.centre(p.key.cell));
        let cells = p.pass.len();
        let mut threat = vec![f32::NAN; cells];
        let mut utility = vec![f32::NAN; cells];
        let mut best: Option<(usize, UtilityTerms)> = None;
        let mut range = (f32::INFINITY, f32::NEG_INFINITY);
        for iz in p.bx.z0..=p.bx.z1 {
            for ix in p.bx.x0..=p.bx.x1 {
                let idx = (iz * f.w + ix) as usize;
                let Some(t) = utility_terms(&f, tl, &p, a, &ev, norm, idx) else { continue };
                r.cells += 1;
                threat[idx] = t.threat;
                utility[idx] = t.utility;
                range.0 = range.0.min(t.utility);
                range.1 = range.1.max(t.utility);
                if best.is_none_or(|(_, b)| t.utility > b.utility) {
                    best = Some((idx, t));
                }
            }
        }
        r.best = best.map(|(idx, t)| (f.centre(idx), Terms::Utility(t)));
        r.here = utility_terms(&f, tl, &p, a, &ev, norm, p.key.cell).map(Terms::Utility);
        r.held = f.index(a.held.x, a.held.y).and_then(|i| utility_terms(&f, tl, &p, a, &ev, norm, i)).map(Terms::Utility);
        r.us = t0.elapsed().as_secs_f32() * 1e6;
        self.utility.insert(id, Arc::new(UtilityLayer { threat, utility, range }));
        r
    }

    fn score_station(&mut self, id: i64, token: i64, team: i32, a: &StationArgs) -> ScoreResult {
        let t0 = Instant::now();
        let mut r = ScoreResult::new(token);
        self.ensure_cone(team);
        self.ensure_detect(team);
        let (Some(f), Some(tl), Some(p)) = (self.field.as_ref(), self.teams.get(&team), self.plans.get(&id)) else {
            return r;
        };
        let (se, armed) = station_enemies(tl, a);
        let mut best: Option<(usize, StationTerms)> = None;
        for iz in p.bx.z0..=p.bx.z1 {
            for ix in p.bx.x0..=p.bx.x1 {
                let idx = (iz * f.w + ix) as usize;
                let Some(t) = station_terms(f, tl, p, a, &se, armed, idx) else { continue };
                r.cells += 1;
                if best.is_none_or(|(_, b)| t.score > b.score) {
                    best = Some((idx, t));
                }
            }
        }
        r.best = best.map(|(idx, t)| (f.centre(idx), Terms::Station(t)));
        r.held = f.index(a.held.x, a.held.y).and_then(|i| station_terms(f, tl, p, a, &se, armed, i)).map(Terms::Station);
        r.us = t0.elapsed().as_secs_f32() * 1e6;
        r
    }

    fn build_plan(&self, f: &Arc<Field>, key: PlanKey, radius: f32, gain: f32, clearance: f32) -> ShipPlan {
        let t0 = Instant::now();
        let cells = (f.w * f.h) as usize;
        let (ix0, iz0) = (key.cell as i32 % f.w, key.cell as i32 / f.w);
        let b = key.box_cells;
        let bx = BoxR {
            x0: (ix0 - b).max(0),
            z0: (iz0 - b).max(0),
            x1: (ix0 + b).min(f.w - 1),
            z1: (iz0 + b).min(f.h - 1),
        };
        let cost_mode = gain.is_finite() && gain > 0.0;
        let wall_at = if cost_mode { crate::nav::hpa::threats::COST_MODE_WALL_EXPOSURE } else { 0.0 };
        let mut price = vec![0.0f32; cells];
        let mut price_dir: Vec<[f32; 4]> = if key.mode == 0 { Vec::new() } else { vec![[0.0; 4]; cells] };
        let mut terrain_ok = vec![false; cells];
        if let Some(tl) = self.teams.get(&key.team) {
            for iz in bx.z0..=bx.z1 {
                for ix in bx.x0..=bx.x1 {
                    let i = (iz * f.w + ix) as usize;
                    if f.water[i] == 0 || f.sdf[i] < clearance {
                        continue;
                    }
                    terrain_ok[i] = true;
                    price[i] = match key.mode {
                        0 => {
                            let d = tl.detect.get(i).copied().unwrap_or(f32::INFINITY);
                            if radius > 0.0 && d < radius { ((radius - d) / radius).clamp(0.0, EXPOSURE_MAX) } else { 0.0 }
                        }
                        _ => {
                            let (e, d) = tl.fire_cells.get(i).copied().unwrap_or((0.0, [0.0; 4]));
                            price_dir[i] = d;
                            e
                        }
                    };
                }
            }
        }
        // Fire counts have no wall threshold in cost mode: three shooters
        // is a price, not a barrier.
        let wall = |i: usize| -> bool {
            if !cost_mode { price[i] > 0.0 } else if key.mode == 0 { price[i] > wall_at } else { false }
        };
        let walls_muted = wall(key.cell);
        let pass: Vec<bool> = (0..cells).map(|i| terrain_ok[i] && (walls_muted || !wall(i))).collect();
        let mut safe = vec![f32::INFINITY; cells];
        let mut risk = vec![f32::INFINITY; cells];
        let g = if cost_mode { gain } else { 0.0 };
        let dir_price = if price_dir.is_empty() { None } else { Some(price_dir.as_slice()) };
        let dark: Vec<usize> = (0..cells).filter(|&i| terrain_ok[i] && price[i] <= 0.0).collect();
        let mut escape = vec![f32::INFINITY; cells];
        if pass[key.cell] {
            dijkstra(f, bx, &pass, &price, dir_price, g, &[key.cell], &mut safe, Some(&mut risk));
        }
        dijkstra(f, bx, &terrain_ok, &price, None, 0.0, &dark, &mut escape, None);
        let max_of = |v: &[f32]| v.iter().copied().filter(|c| c.is_finite()).fold(0.0f32, f32::max);
        ShipPlan {
            key,
            bx,
            max_safe: max_of(&safe),
            max_escape: max_of(&escape),
            max_risk: max_of(&risk),
            safe,
            escape,
            risk,
            price,
            pass,
            walls_muted,
            us: t0.elapsed().as_secs_f32() * 1e6,
        }
    }

    fn finalize(&mut self) {
        let teams: Vec<i32> = self.teams.keys().copied().collect();
        for team in teams {
            self.ensure_detect(team);
            self.ensure_fire_cells(team);
            self.ensure_cone(team);
        }
        for key in self.exposure_watch.clone() {
            self.cluster_exposure_stats(key);
        }
        for key in self.fire_watch.clone() {
            self.cluster_fire_stats(key);
        }
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            terrain: self.terrain.clone(),
            field: self.field.clone(),
            teams: self.teams.iter().map(|(&k, tl)| (k, Arc::new(tl.clone()))).collect(),
            ships: self.ships.clone(),
            plans: self.plans.clone(),
            plan_stats: self.plan_stats.clone(),
            utility: self.utility.clone(),
            exposure: self.exposure_cache.clone(),
            fire: self.fire_cache.clone(),
            last: self.last,
            tables_cached: self.tables.len(),
            backlog: self.backlog.values().map(|b| b[0].len() + b[1].len()).sum(),
        }
    }

    fn apply(&mut self, batch: Batch) -> Delivery {
        let t0 = Instant::now();
        let mut team_stats = Vec::new();
        let mut scores = Vec::new();
        for op in batch.ops {
            match op {
                Op::Smoke(discs) => self.set_smoke(discs),
                Op::Hulls(team, hulls) => self.set_team_hulls(team, hulls),
                Op::Update(r) => {
                    let team = r.team;
                    team_stats.push((team, self.update_team(r)));
                }
                Op::Sweep(rows) => self.sweep_ships(rows),
                Op::Forget(id) => self.forget(id),
                Op::Clear => self.clear(),
                Op::WatchExposure(k) => {
                    self.exposure_watch.insert(k);
                }
                Op::WatchFire(k) => {
                    self.fire_watch.insert(k);
                }
                Op::Prebuild(guns) => self.prebuild_tables(&guns),
            }
        }
        for (id, rq) in batch.ships {
            if let Some(p) = rq.plan {
                self.plan_ship(id, p);
            }
            if let Some((token, team, hull_key, a)) = rq.utility {
                scores.push((id, KIND_UTILITY, self.score_utility(id, token, team, hull_key, &a)));
            }
            if let Some((token, team, _, a)) = rq.station {
                scores.push((id, KIND_STATION, self.score_station(id, token, team, &a)));
            }
        }
        for (team, st) in self.drain() {
            match team_stats.iter_mut().find(|(t, _)| *t == team) {
                Some((_, u)) => u.stats.add(&st),
                None => team_stats.push((team, UpdateStats { stats: st, ..Default::default() })),
            }
        }
        self.finalize();
        Delivery { snap: self.snapshot(), team_stats, scores, busy_us: t0.elapsed().as_secs_f32() * 1e6 }
    }
}

/// One hull's reach planes against a list of enemies, detached from the field.
pub(crate) struct ReachLookup {
    field: Arc<Field>,
    planes: Vec<Option<Arc<Vec<u64>>>>,
}

impl ReachLookup {
    /// Whether the hull at `p` can land shells on enemy `i` of the list.
    pub(crate) fn hits(&self, i: usize, p: Vector2) -> bool {
        match (self.planes.get(i), self.field.index(p.x, p.y)) {
            (Some(Some(pl)), Some(idx)) => bit_at(pl, idx),
            _ => false,
        }
    }
}

struct FieldWorker {
    tx: mpsc::Sender<Batch>,
    rx: mpsc::Receiver<Delivery>,
    handle: std::thread::JoinHandle<Box<FieldCore>>,
}

/// Per-ship "where can my shells land" field over a coarse grid, one bit per
/// cell, built by radial sweeps that leap across open water on the SDF.
/// With a worker, a batch sent at tick N is adopted at exactly N + lag (the
/// main thread blocks if it is late) so results never depend on thread timing.
#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct ReachField {
    base: Base<RefCounted>,
    core: Option<Box<FieldCore>>,
    worker: Option<FieldWorker>,
    snap: Snapshot,
    pending: Batch,
    pending_ships: HashMap<i64, usize>,
    ticks: u64,
    lag: u64,
    job_budget: usize,
    due: Option<u64>,
    next_token: i64,
    scores: HashMap<(i64, u8), ScoreResult>,
    team_stats: HashMap<i32, UpdateStats>,
    exposure_local: HashMap<ExposureKey, ExposureStats>,
    fire_local: HashMap<FireKey, (u64, FireStats)>,
    exposure_watched: std::collections::HashSet<ExposureKey>,
    fire_watched: std::collections::HashSet<FireKey>,
    main_tables: HashMap<TableKey, Arc<RBlockTable>>,
    worker_us: f64,
    blocked_us: f64,
    batches: u32,
}

#[godot_api]
impl IRefCounted for ReachField {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            core: Some(Box::default()),
            worker: None,
            snap: Snapshot::default(),
            pending: Batch::default(),
            pending_ships: HashMap::new(),
            ticks: 0,
            lag: 1,
            job_budget: 12,
            due: None,
            next_token: 0,
            scores: HashMap::new(),
            team_stats: HashMap::new(),
            exposure_local: HashMap::new(),
            fire_local: HashMap::new(),
            exposure_watched: std::collections::HashSet::new(),
            fire_watched: std::collections::HashSet::new(),
            main_tables: HashMap::new(),
            worker_us: 0.0,
            blocked_us: 0.0,
            batches: 0,
        }
    }
}

impl Drop for ReachField {
    fn drop(&mut self) {
        if let Some(w) = self.worker.take() {
            drop(w.tx);
            let _ = w.handle.join();
        }
    }
}

impl ReachField {
    fn push_op(&mut self, op: Op) {
        self.pending.ops.push(op);
        self.flush_sync();
    }

    fn ship_reqs(&mut self, id: i64) -> &mut ShipReqs {
        let i = *self.pending_ships.entry(id).or_insert_with(|| {
            self.pending.ships.push((id, ShipReqs::default()));
            self.pending.ships.len() - 1
        });
        &mut self.pending.ships[i].1
    }

    fn take_pending(&mut self) -> Batch {
        self.pending_ships.clear();
        std::mem::take(&mut self.pending)
    }

    fn flush_sync(&mut self) {
        if self.worker.is_some() {
            return;
        }
        let batch = self.take_pending();
        let Some(core) = self.core.as_mut() else { return };
        let d = core.apply(batch);
        self.adopt(d);
    }

    fn adopt(&mut self, d: Delivery) {
        self.snap = d.snap;
        for (team, st) in d.team_stats {
            let acc = self.team_stats.entry(team).or_default();
            acc.stats.add(&st.stats);
            acc.resweeps += st.resweeps;
            acc.jobs += st.jobs;
            if st.jobs > 0 {
                acc.enemies = st.enemies;
                acc.hulls = st.hulls;
            }
        }
        for (id, kind, r) in d.scores {
            self.scores.insert((id, kind), r);
        }
        self.exposure_local.clear();
        self.fire_local.clear();
        self.worker_us += d.busy_us as f64;
        self.batches += 1;
    }

    fn receive(&mut self) {
        let Some(w) = self.worker.as_ref() else { return };
        let t0 = Instant::now();
        let got = w.rx.recv();
        self.blocked_us += t0.elapsed().as_secs_f64() * 1e6;
        self.due = None;
        match got {
            Ok(d) => self.adopt(d),
            Err(_) => {
                godot_error!("ReachField: worker thread died; field is frozen");
                self.worker = None;
            }
        }
    }

    fn team(&self, team: i32) -> Option<&Arc<TeamLayers>> {
        self.snap.teams.get(&team)
    }

    fn cell_count(&self) -> usize {
        self.snap.field.as_ref().map_or(0, |f| (f.w * f.h) as usize)
    }

    fn team_version(&self, team: i32) -> u64 {
        self.team(team).map_or(0, |tl| tl.version)
    }

    pub(crate) fn cluster_exposure_stats(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> (Arc<Vec<f32>>, Arc<Vec<f32>>) {
        let (key, radius) = exposure_key(team, radius, cluster_cells, ncx, ncz);
        let version = self.team_version(team);
        for cache in [&self.snap.exposure, &self.exposure_local] {
            if let Some((v, max, mean)) = cache.get(&key) {
                if *v == version {
                    return (max.clone(), mean.clone());
                }
            }
        }
        let (max, mean) = match (self.snap.field.as_ref(), self.team(team)) {
            (Some(f), Some(tl)) => build_exposure_stats(f, tl, radius, cluster_cells, ncx, ncz),
            _ => {
                let n = (ncx.max(0) * ncz.max(0)) as usize;
                (vec![0.0; n], vec![0.0; n])
            }
        };
        let out = (Arc::new(max), Arc::new(mean));
        self.exposure_local.insert(key, (version, out.0.clone(), out.1.clone()));
        if self.exposure_watched.insert(key) {
            self.pending.ops.push(Op::WatchExposure(key));
        }
        out
    }

    pub(crate) fn cluster_fire_stats(&mut self, team: i32, cluster_cells: i32, ncx: i32, ncz: i32) -> FireStats {
        let key = (team, cluster_cells, ncx, ncz);
        let version = self.team_version(team);
        for cache in [&self.snap.fire, &self.fire_local] {
            if let Some((v, st)) = cache.get(&key) {
                if *v == version {
                    return st.clone();
                }
            }
        }
        let st = match (self.snap.field.as_ref(), self.team(team)) {
            (Some(f), Some(tl)) => build_fire_stats(f, tl, cluster_cells, ncx, ncz),
            _ => {
                let n = (ncx.max(0) * ncz.max(0)) as usize;
                FireStats { max: Arc::new(vec![0.0; n]), mean: Arc::new(vec![0.0; n]), dir: Arc::new(vec![[0.0; 4]; n]) }
            }
        };
        self.fire_local.insert(key, (version, st.clone()));
        if self.fire_watched.insert(key) {
            self.pending.ops.push(Op::WatchFire(key));
        }
        st
    }

    pub(crate) fn cluster_exposure_vec(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> Vec<f32> {
        self.cluster_exposure_stats(team, radius, cluster_cells, ncx, ncz).0.as_ref().clone()
    }

    pub(crate) fn reach_lookup(&self, team: i32, hull_key: i64, ids: &[i64]) -> Option<ReachLookup> {
        let (field, tl) = (self.snap.field.clone()?, self.team(team)?);
        let planes = ids.iter().map(|id| tl.enemies.get(id).and_then(|e| e.reach.get(&hull_key).cloned())).collect();
        Some(ReachLookup { field, planes })
    }

    /// Where each listed enemy can land shells.
    pub(crate) fn fire_lookup(&self, team: i32, ids: &[i64]) -> Option<ReachLookup> {
        let (field, tl) = (self.snap.field.clone()?, self.team(team)?);
        let planes = ids.iter().map(|id| tl.enemies.get(id).map(|e| e.fire.clone())).collect();
        Some(ReachLookup { field, planes })
    }

    fn plan_value(&self, id: i64, point: Vector2, safe: bool) -> f32 {
        let (Some(f), Some(p)) = (&self.snap.field, self.snap.plans.get(&id)) else { return f32::INFINITY };
        match f.index(point.x, point.y) {
            Some(i) => if safe { p.safe[i] } else { p.escape[i] },
            None => f32::INFINITY,
        }
    }

    fn plan_bytes(&self, id: i64, pick: impl Fn(&ShipPlan) -> (&[f32], f32), zero_is_one: bool) -> PackedByteArray {
        let mut out = vec![0u8; self.cell_count()];
        if let Some(p) = self.snap.plans.get(&id) {
            let (vals, max) = pick(p);
            let scale = max.max(1.0);
            for (o, &c) in out.iter_mut().zip(vals.iter()) {
                if c.is_finite() {
                    *o = if zero_is_one && c <= 0.0 {
                        1
                    } else if zero_is_one {
                        2 + (253.0 * (c / scale).clamp(0.0, 1.0)).round() as u8
                    } else {
                        1 + (254.0 * (c / scale).clamp(0.0, 1.0)).round() as u8
                    };
                }
            }
        }
        PackedByteArray::from(out.as_slice())
    }
}

#[godot_api]
impl ReachField {
    /// `cell_mult` field cells per SDF cell along each axis. Stops and
    /// restarts the worker around the rebuild.
    #[func]
    fn build(&mut self, nav_map: Option<Gd<NavigationMap>>, #[opt(default = 2)] cell_mult: i32) {
        let Some(map) = nav_map else { return };
        let core = {
            let m = map.bind();
            if !m.built {
                return;
            }
            FieldCore::build(&m, cell_mult)
        };
        let restart = self.worker.is_some().then_some(self.lag);
        let budget = self.worker.as_ref().map_or(12, |_| self.job_budget);
        self.stop_worker();
        self.core = Some(Box::new(core));
        self.pending = Batch::default();
        self.pending_ships.clear();
        self.scores.clear();
        self.team_stats.clear();
        self.exposure_watched.clear();
        self.fire_watched.clear();
        self.flush_sync();
        if let Some(lag) = restart {
            self.start_worker(lag as i32, budget as i32);
        }
    }

    #[func]
    fn is_built(&self) -> bool {
        self.snap.field.is_some()
    }

    /// `job_budget` caps sweep jobs per batch so a burst of resweeps spreads out.
    #[func]
    fn start_worker(&mut self, #[opt(default = 2)] lag: i32, #[opt(default = 12)] job_budget: i32) {
        self.lag = lag.max(1) as u64;
        if self.worker.is_some() {
            return;
        }
        let Some(mut core) = self.core.take() else { return };
        self.job_budget = job_budget.max(1) as usize;
        core.job_budget = Some(self.job_budget);
        let (tx, worker_rx) = mpsc::channel::<Batch>();
        let (worker_tx, rx) = mpsc::channel::<Delivery>();
        let handle = std::thread::Builder::new()
            .name("reach-field".into())
            .spawn(move || {
                while let Ok(b) = worker_rx.recv() {
                    if worker_tx.send(core.apply(b)).is_err() {
                        break;
                    }
                }
                core
            })
            .expect("reach-field thread");
        self.worker = Some(FieldWorker { tx, rx, handle });
        self.due = None;
    }

    #[func]
    fn stop_worker(&mut self) {
        if self.due.is_some() {
            self.receive();
        }
        let Some(w) = self.worker.take() else { return };
        drop(w.tx);
        match w.handle.join() {
            Ok(mut core) => {
                core.job_budget = None;
                self.core = Some(core);
            }
            Err(_) => godot_error!("ReachField: worker thread panicked"),
        }
        self.flush_sync();
    }

    #[func]
    fn has_worker(&self) -> bool {
        self.worker.is_some()
    }

    #[func]
    fn tick(&mut self) {
        self.ticks += 1;
        if self.worker.is_none() {
            return;
        }
        if self.due.is_some_and(|due| self.ticks >= due) {
            self.receive();
        }
        if self.due.is_none() && (!self.pending.is_empty() || self.snap.backlog > 0) {
            let batch = self.take_pending();
            if let Some(w) = self.worker.as_ref() {
                if w.tx.send(batch).is_ok() {
                    self.due = Some(self.ticks + self.lag);
                }
            }
        }
    }

    /// {worker_us, blocked_us, batches} since the last call.
    #[func]
    fn take_worker_stats(&mut self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("worker_us", self.worker_us);
        d.set("blocked_us", self.blocked_us);
        d.set("batches", self.batches as i64);
        self.worker_us = 0.0;
        self.blocked_us = 0.0;
        self.batches = 0;
        d
    }

    /// Sweep one ship. Returns microseconds spent (the last batch's, with a worker).
    #[func]
    fn sweep(&mut self, id: i64, origin: Vector2, gun_h: f32, target_h: f32, speed: f32, drag: f32, range: f32) -> f32 {
        self.push_op(Op::Sweep(vec![(id, origin, gun_h, target_h, speed, drag, range)]));
        self.snap.last.total_us
    }

    #[func]
    fn sweep_all(
        &mut self,
        ids: PackedInt64Array,
        origins: PackedVector2Array,
        gun_heights: PackedFloat32Array,
        speeds: PackedFloat32Array,
        drags: PackedFloat32Array,
        ranges: PackedFloat32Array,
        target_h: f32,
    ) -> VarDictionary {
        let n = ids.len().min(origins.len()).min(gun_heights.len()).min(speeds.len()).min(drags.len()).min(ranges.len());
        let rows = (0..n).map(|i| (ids[i], origins[i], gun_heights[i], target_h, speeds[i], drags[i], ranges[i])).collect();
        self.push_op(Op::Sweep(rows));
        self.get_last_stats()
    }

    #[func]
    fn get_last_stats(&self) -> VarDictionary {
        self.snap.last.to_dict(self.snap.tables_cached)
    }

    #[func]
    fn get_field_info(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(f) = &self.snap.field {
            d.set("w", f.w as i64);
            d.set("h", f.h as i64);
            d.set("cell", f.cell);
            d.set("min_x", f.min_x);
            d.set("min_z", f.min_z);
        }
        d
    }

    /// One byte per field cell, row-major by z; 255 where the ship's shells
    /// can land. Empty when the ship has never been swept.
    #[func]
    fn get_reach_bytes(&self, id: i64) -> PackedByteArray {
        let (Some(f), Some(bits)) = (&self.snap.field, self.snap.ships.get(&id)) else {
            return PackedByteArray::new();
        };
        let out: Vec<u8> = (0..(f.w * f.h) as usize).map(|i| if bit_at(bits, i) { 255 } else { 0 }).collect();
        PackedByteArray::from(out.as_slice())
    }

    #[func]
    fn can_reach(&self, id: i64, point: Vector2) -> bool {
        let (Some(f), Some(bits)) = (&self.snap.field, self.snap.ships.get(&id)) else {
            return false;
        };
        f.index(point.x, point.y).is_some_and(|i| bit_at(bits, i))
    }

    #[func]
    fn segment_clear(&mut self, start: Vector2, end: Vector2, gun_h: f32, target_h: f32, speed: f32, drag: f32, range: f32) -> bool {
        let Some(terrain) = self.snap.terrain.clone() else {
            return false;
        };
        let delta = end - start;
        let dist = delta.length();
        if dist < 1e-3 {
            return true;
        }
        let key = TableKey::new(speed, drag, gun_h, target_h, range, false);
        let table = self.main_tables.entry(key)
            .or_insert_with(|| new_table(speed, drag, gun_h, target_h, range, false))
            .clone();
        segment_clear(&terrain, &table, start, delta.x / dist, delta.y / dist, dist, gun_h)
    }

    #[func]
    fn prebuild_tables(&mut self, speeds: PackedFloat32Array, drags: PackedFloat32Array, gun_heights: PackedFloat32Array,
            ranges: PackedFloat32Array, target_h: f32) {
        let n = speeds.len().min(drags.len()).min(gun_heights.len()).min(ranges.len());
        self.push_op(Op::Prebuild((0..n).map(|i| (speeds[i], drags[i], gun_heights[i], target_h, ranges[i])).collect()));
    }

    /// Smoke discs (world XZ centre, radius) that end line of sight. Only
    /// enemies near a disc that appeared or vanished get their LOS re-swept.
    #[func]
    fn set_smoke(&mut self, centres: PackedVector2Array, radii: PackedFloat32Array) {
        let n = centres.len().min(radii.len());
        self.push_op(Op::Smoke((0..n).map(|i| (centres[i], radii[i])).collect()));
    }

    /// The friendly hull kinds a team wants reach planes for. Replaces the set;
    /// planes for hulls no longer listed are dropped.
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
        let hulls = (0..n)
            .map(|i| (keys[i], Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] }))
            .collect();
        self.push_op(Op::Hulls(team, hulls));
    }

    /// Enemies as `team` believes them: position, shell, lateral `spread`,
    /// certainty `weight`, radar/hydro `force_spot`. `los_range` is the
    /// furthest any ship on the team can be seen from. An enemy is re-swept
    /// only when new, moved more than `move_threshold`, or changed shell or
    /// spread; a hull added since is swept for every enemy lacking it.
    /// Returns the stats of this team's last applied update, once.
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
    ) -> VarDictionary {
        let n = [ids.len(), origins.len(), speeds.len(), drags.len(), ranges.len(),
            gun_heights.len(), spreads.len(), weights.len(), force_spots.len()]
            .into_iter().min().unwrap();
        let rows = (0..n)
            .map(|i| {
                let shell = Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] };
                (ids[i], origins[i], shell, spreads[i], weights[i], force_spots[i])
            })
            .collect();
        self.push_op(Op::Update(UpdateReq { team, rows, los_range, target_h, move_threshold }));
        let Some(st) = self.team_stats.remove(&team) else { return VarDictionary::new() };
        let mut d = st.stats.to_dict(self.snap.tables_cached);
        d.set("resweeps", st.resweeps as i64);
        d.set("jobs", st.jobs as i64);
        d.set("enemies", st.enemies as i64);
        d.set("hulls", st.hulls as i64);
        d
    }

    /// Enemy ids in mask bit order for `team`.
    #[func]
    fn get_team_enemy_ids(&self, team: i32) -> PackedInt64Array {
        match self.team(team) {
            Some(tl) => PackedInt64Array::from(tl.order.as_slice()),
            None => PackedInt64Array::new(),
        }
    }

    #[func]
    pub(crate) fn get_team_version(&self, team: i32) -> i64 {
        self.team_version(team) as i64
    }

    /// Per cell, how many enemies can land shells there.
    #[func]
    fn get_exposure_count_bytes(&self, team: i32) -> PackedByteArray {
        let mut counts = vec![0u8; self.cell_count()];
        if let Some(tl) = self.team(team) {
            for e in tl.enemies.values() {
                count_plane(&e.fire, &mut counts);
            }
        }
        PackedByteArray::from(counts.as_slice())
    }

    /// Per cell, how many enemies a hull of `hull_key` could hit from there.
    #[func]
    fn get_reach_count_bytes(&self, team: i32, hull_key: i64) -> PackedByteArray {
        let mut counts = vec![0u8; self.cell_count()];
        if let Some(tl) = self.team(team) {
            for e in tl.enemies.values() {
                if let Some(p) = e.reach.get(&hull_key) {
                    count_plane(p, &mut counts);
                }
            }
        }
        PackedByteArray::from(counts.as_slice())
    }

    /// Bit i set when enemy `get_team_enemy_ids(team)[i]` can hit `point`.
    #[func]
    fn exposure_mask(&self, team: i32, point: Vector2) -> i64 {
        let (Some(f), Some(tl)) = (&self.snap.field, self.team(team)) else { return 0 };
        let Some(idx) = f.index(point.x, point.y) else { return 0 };
        let mut m = 0i64;
        for (i, id) in tl.order.iter().enumerate().take(63) {
            if bit_at(&tl.enemies[id].fire, idx) {
                m |= 1i64 << i;
            }
        }
        m
    }

    /// Bit i set when a `hull_key` hull at `point` can hit enemy i.
    #[func]
    fn reach_mask(&self, team: i32, hull_key: i64, point: Vector2) -> i64 {
        let (Some(f), Some(tl)) = (&self.snap.field, self.team(team)) else { return 0 };
        let Some(idx) = f.index(point.x, point.y) else { return 0 };
        let mut m = 0i64;
        for (i, id) in tl.order.iter().enumerate().take(63) {
            if tl.enemies[id].reach.get(&hull_key).is_some_and(|p| bit_at(p, idx)) {
                m |= 1i64 << i;
            }
        }
        m
    }

    /// Effective distance to the nearest enemy with line of sight to `point`:
    /// zero inside a radar or hydro reach, distance over certainty otherwise,
    /// INFINITY when nobody can see it. Spotted here iff below the ship's
    /// own concealment radius.
    #[func]
    fn detect_dist_at(&self, team: i32, point: Vector2) -> f32 {
        let (Some(f), Some(tl)) = (&self.snap.field, self.team(team)) else { return f32::INFINITY };
        f.index(point.x, point.y).and_then(|i| tl.detect.get(i).copied()).unwrap_or(f32::INFINITY)
    }

    #[func]
    fn get_detect_grid(&self, team: i32) -> PackedFloat32Array {
        match self.team(team) {
            Some(tl) => PackedFloat32Array::from(tl.detect.as_slice()),
            None => PackedFloat32Array::new(),
        }
    }

    /// Per cell for a ship of concealment `radius`: 0 unseen, else 1..255
    /// rising as the effective distance closes to zero.
    #[func]
    fn get_detect_bytes(&self, team: i32, radius: f32) -> PackedByteArray {
        let mut out = vec![0u8; self.cell_count()];
        if let Some(tl) = self.team(team) {
            if radius > 0.0 {
                for (o, &d) in out.iter_mut().zip(tl.detect.iter()) {
                    if d < radius {
                        *o = 1 + (254.0 * (1.0 - d / radius).clamp(0.0, 1.0)).round() as u8;
                    }
                }
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    /// Per HPA cluster (`cluster_cells` SDF cells wide, `ncx` by `ncz`): the
    /// deepest exposure of any field cell in it, 0 outside detection to 1 at
    /// effective distance zero, for a ship of concealment `radius`.
    #[func]
    fn get_cluster_exposure(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> PackedFloat32Array {
        PackedFloat32Array::from(self.cluster_exposure_vec(team, radius, cluster_cells, ncx, ncz).as_slice())
    }

    #[func]
    fn forget(&mut self, id: i64) {
        self.scores.retain(|k, _| k.0 != id);
        self.push_op(Op::Forget(id));
    }

    #[func]
    fn clear(&mut self) {
        self.scores.clear();
        self.push_op(Op::Clear);
    }

    /// Certainty-weighted mean of where `team` believes its enemies are.
    #[func]
    fn get_team_danger_centre(&self, team: i32) -> Vector2 {
        let Some(tl) = self.team(team) else { return Vector2::ZERO };
        let (mut sum, mut wsum) = (Vector2::ZERO, 0.0f32);
        for e in tl.enemies.values() {
            let w = e.weight.max(WEIGHT_FLOOR);
            sum += e.origin * w;
            wsum += w;
        }
        if wsum > 0.0 { sum / wsum } else { Vector2::ZERO }
    }

    /// Per cell: 0 where no enemy can hit it, else 1..255 rising with the
    /// half-width of the bearing cone all shooters fit in (255 = they
    /// surround the cell).
    #[func]
    fn get_cone_bytes(&self, team: i32) -> PackedByteArray {
        let mut out = vec![0u8; self.cell_count()];
        if let Some(tl) = self.team(team) {
            for (o, &h) in out.iter_mut().zip(tl.cone_half.iter()) {
                if h >= 0.0 {
                    *o = 1 + (254.0 * (h / std::f32::consts::PI).clamp(0.0, 1.0)).round() as u8;
                }
            }
        }
        PackedByteArray::from(out.as_slice())
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
        let Some(idx) = self.snap.field.as_ref().and_then(|f| f.index(point.x, point.y)) else { return d };
        let Some(tl) = self.team(team) else { return d };
        if tl.cone_half.len() <= idx {
            return d;
        }
        d.set("half", tl.cone_half[idx]);
        d.set("heading", tl.cone_dir[idx]);
        d.set("count", tl.enemies.values().filter(|e| bit_at(&e.fire, idx)).count() as i64);
        d
    }

    /// Queues (re)building the safe-cost and escape layers for ship `id` of
    /// concealment `radius` standing at `pos`, priced like its router:
    /// `price_mode` 0 = detection exposure, 1 = number of enemies that can
    /// land shells; `gain` 0/INF makes any price a wall. Layers cover a box
    /// of `box_radius` around the ship. Returns the stats of the ship's last
    /// applied plan (empty before the first), with `marker`: the unpriced
    /// cell reachable at finite cost that lies nearest `toward`.
    #[func]
    fn plan_ship(
        &mut self,
        team: i32,
        id: i64,
        pos: Vector2,
        radius: f32,
        gain: f32,
        clearance: f32,
        box_radius: f32,
        price_mode: i32,
        toward: Vector2,
    ) -> VarDictionary {
        self.ship_reqs(id).plan = Some(PlanReq { team, pos, radius, gain, clearance, box_radius, mode: price_mode, toward });
        self.flush_sync();
        self.snap.plan_stats.get(&id).map_or_else(VarDictionary::new, |s| s.to_dict())
    }

    /// Queues the single positioning objective over ship `id`'s plan: per
    /// cell, the ladder's threat score as it would read standing there
    /// (shooters whose fire plane covers the cell, by range pressure and
    /// presentation against the cone heading, halved where nobody could see
    /// the hull), value from reach and reveal, and the transit's risk
    /// integral. utility = value - w_threat x pressure - w_path x risk /
    /// gun_range, maximised over every reachable cell. Returns a token;
    /// `get_score(id, 1)` answers it once its `token` is at least this one.
    #[func]
    fn score_utility(&mut self, team: i32, id: i64, hull_key: i64, opts: VarDictionary) -> i64 {
        self.next_token += 1;
        let token = self.next_token;
        self.ship_reqs(id).utility = Some((token, team, hull_key, UtilityArgs::from_dict(&opts)));
        self.flush_sync();
        token
    }

    /// Queues the argmax of the station score over the cells of ship `id`'s
    /// plan (see plan_ship). `opts`: weights [reach, exposed, cone, detect,
    /// travel, range, escape], gun_range, pref_range, radius, toward, held
    /// (scored too, for hysteresis), avoid + avoid_radius (team-mates'
    /// claims, cells inside are skipped), axis_from + w_detour (penalty for
    /// cells off the line from axis_from through toward). Returns a token for
    /// `get_score(id, 0)`.
    #[func]
    fn score_station(&mut self, team: i32, id: i64, hull_key: i64, opts: VarDictionary) -> i64 {
        self.next_token += 1;
        let token = self.next_token;
        self.ship_reqs(id).station = Some((token, team, hull_key, StationArgs::from_dict(hull_key, &opts)));
        self.flush_sync();
        token
    }

    /// Latest applied score for ship `id`, `kind` 0 station or 1 utility:
    /// has_best, best, best_score, best_terms, here_terms, held_score,
    /// held_terms, cells, us, token. Empty before the first.
    #[func]
    fn get_score(&self, id: i64, kind: i32) -> VarDictionary {
        self.scores.get(&(id, kind as u8)).map_or_else(VarDictionary::new, |r| r.to_dict())
    }

    /// One point under the same `opts`, or an empty dictionary when it is
    /// outside the plan, unreachable or claimed.
    #[func]
    fn utility_score_at(&self, team: i32, id: i64, hull_key: i64, opts: VarDictionary, point: Vector2) -> VarDictionary {
        let (Some(f), Some(tl), Some(p)) = (self.snap.field.as_ref(), self.team(team), self.snap.plans.get(&id)) else {
            return VarDictionary::new();
        };
        let a = UtilityArgs::from_dict(&opts);
        let (ev, norm) = enemy_evals(f, tl, hull_key, &a, f.centre(p.key.cell));
        match f.index(point.x, point.y).and_then(|i| utility_terms(f, tl, p, &a, &ev, norm, i)) {
            Some(t) => t.to_dict(),
            None => VarDictionary::new(),
        }
    }

    /// 0 outside the plan, else 1..255 by threat 0..1.
    #[func]
    fn get_threat_bytes(&self, id: i64) -> PackedByteArray {
        let mut out = vec![0u8; self.cell_count()];
        if let Some(u) = self.snap.utility.get(&id) {
            for (o, &t) in out.iter_mut().zip(u.threat.iter()) {
                if t.is_finite() {
                    *o = 1 + (254.0 * t.clamp(0.0, 1.0)).round() as u8;
                }
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    /// 0 outside the plan, else 2..255 from the worst to the best utility
    /// scored.
    #[func]
    fn get_utility_bytes(&self, id: i64) -> PackedByteArray {
        let mut out = vec![0u8; self.cell_count()];
        if let Some(u) = self.snap.utility.get(&id) {
            let (lo, hi) = u.range;
            let span = (hi - lo).max(1e-6);
            for (i, o) in out.iter_mut().enumerate() {
                let t = u.threat.get(i).copied().unwrap_or(f32::NAN);
                if !t.is_finite() {
                    continue;
                }
                let v = u.utility.get(i).copied().unwrap_or(f32::NAN);
                *o = if v.is_finite() { 2 + (253.0 * ((v - lo) / span).clamp(0.0, 1.0)).round() as u8 } else { 1 };
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    /// 0 outside the plan, else 1..255 by the risk integral of the safe path.
    #[func]
    fn get_path_risk_bytes(&self, id: i64) -> PackedByteArray {
        self.plan_bytes(id, |p| (p.risk.as_slice(), p.max_risk), false)
    }

    /// 0 outside the plan or unreachable, else 1..255 by cost over the
    /// costliest reachable cell.
    #[func]
    fn get_safe_cost_bytes(&self, id: i64) -> PackedByteArray {
        self.plan_bytes(id, |p| (p.safe.as_slice(), p.max_safe), false)
    }

    /// 0 outside the plan, 1 where nobody prices the cell, else 2..255 by
    /// distance to the nearest such cell.
    #[func]
    fn get_escape_bytes(&self, id: i64) -> PackedByteArray {
        self.plan_bytes(id, |p| (p.escape.as_slice(), p.max_escape), true)
    }

    /// The station score of one point under the same `opts`, or an empty
    /// dictionary when it is outside the plan, unreachable or claimed.
    #[func]
    fn station_score_at(&self, team: i32, id: i64, hull_key: i64, opts: VarDictionary, point: Vector2) -> VarDictionary {
        let (Some(f), Some(tl), Some(p)) = (self.snap.field.as_ref(), self.team(team), self.snap.plans.get(&id)) else {
            return VarDictionary::new();
        };
        let a = StationArgs::from_dict(hull_key, &opts);
        let (se, armed) = station_enemies(tl, &a);
        match f.index(point.x, point.y).and_then(|i| station_terms(f, tl, p, &a, &se, armed, i)) {
            Some(t) => t.to_dict(),
            None => VarDictionary::new(),
        }
    }

    /// Mean station score along each ray from `origin` (bearing = atan2(x, z),
    /// `length` metres) under `opts`, over ship `id`'s plan. A ray that runs
    /// into land or out of the plan is padded with the worst score for the
    /// samples it lost, so a short ray never beats a long clean one. `ends`
    /// is each ray's last open sample.
    #[func]
    fn score_rays(&self, team: i32, id: i64, hull_key: i64, opts: VarDictionary, origin: Vector2, bearings: PackedFloat32Array, length: f32) -> VarDictionary {
        let mut d = VarDictionary::new();
        let mut scores = PackedFloat32Array::new();
        let mut ends = PackedVector2Array::new();
        if let (Some(f), Some(tl), Some(p)) = (self.snap.field.as_ref(), self.team(team), self.snap.plans.get(&id)) {
            let a = StationArgs::from_dict(hull_key, &opts);
            let (se, armed) = station_enemies(tl, &a);
            let steps = (length / f.cell).ceil().max(1.0) as i32;
            for &b in bearings.as_slice() {
                let dir = Vector2::new(b.sin(), b.cos());
                let (mut sum, mut n, mut end) = (0.0f32, 0i32, origin);
                for k in 1..=steps {
                    let pt = origin + dir * (k as f32 * f.cell);
                    let Some(t) = f.index(pt.x, pt.y).and_then(|i| station_terms(f, tl, p, &a, &se, armed, i)) else { break };
                    sum += t.score;
                    n += 1;
                    end = pt;
                }
                scores.push(if n == 0 { f32::NEG_INFINITY } else { (sum - (steps - n) as f32) / steps as f32 });
                ends.push(end);
            }
        }
        d.set("scores", &scores);
        d.set("ends", &ends);
        d
    }

    #[func]
    fn safe_cost_at(&self, id: i64, point: Vector2) -> f32 {
        self.plan_value(id, point, true)
    }

    #[func]
    fn escape_dist_at(&self, id: i64, point: Vector2) -> f32 {
        self.plan_value(id, point, false)
    }
}

struct StationArgs {
    hull_key: i64,
    w: [f32; 7],
    gun_range: f32,
    pref_range: f32,
    radius: f32,
    /// Detection radius once the guns fire (bloom): judged at any cell with
    /// something in reach, since the ship will shoot from there.
    fire_radius: f32,
    toward: Vector2,
    held: Vector2,
    avoid: Vec<Vector2>,
    avoid_r2: f32,
    axis_from: Vector2,
    w_detour: f32,
    /// Per enemy id, how dangerous its class is to this hull (1 default).
    enemy_weights: HashMap<i64, f32>,
    /// Hard gates: cells whose class-and-certainty weighted exposure exceeds
    /// max_exposed, or that are seen when require_unseen, are not candidates.
    max_exposed: f32,
    require_unseen: bool,
    /// Covered means nobody can land shells on the cell OR nobody can see
    /// it; a cell that is both seen and under fire is not a candidate.
    covered_only: bool,
    /// Distance-to-`toward` band a candidate must lie in: a kite opens range
    /// with min_range above where the ship stands, a push closes with
    /// max_range below it.
    min_range: f32,
    max_range: f32,
    /// Flank: penalise cells on the friendly side of `toward`, along the
    /// axis from `toward` to `flank_from`.
    flank_from: Vector2,
    w_flank: f32,
}

fn opt<T: FromGodot>(d: &VarDictionary, key: &str, default: T) -> T {
    d.get(key).and_then(|v| v.try_to::<T>().ok()).unwrap_or(default)
}

impl StationArgs {
    fn from_dict(hull_key: i64, d: &VarDictionary) -> Self {
        let weights = opt(d, "weights", PackedFloat32Array::new());
        let mut w = [0.0f32; 7];
        for (i, v) in w.iter_mut().enumerate() {
            if i < weights.len() {
                *v = weights[i];
            }
        }
        let avoid_radius = opt(d, "avoid_radius", 0.0f32);
        let radius = opt(d, "radius", 0.0f32);
        Self {
            hull_key,
            w,
            gun_range: opt(d, "gun_range", 1.0f32),
            pref_range: opt(d, "pref_range", 0.0f32),
            radius,
            fire_radius: opt(d, "fire_radius", radius).max(radius),
            toward: opt(d, "toward", Vector2::ZERO),
            held: opt(d, "held", Vector2::new(f32::INFINITY, f32::INFINITY)),
            avoid: opt(d, "avoid", PackedVector2Array::new()).to_vec(),
            avoid_r2: avoid_radius * avoid_radius,
            axis_from: opt(d, "axis_from", Vector2::ZERO),
            w_detour: opt(d, "w_detour", 0.0f32),
            enemy_weights: opt(d, "enemy_weights", VarDictionary::new())
                .iter_shared()
                .filter_map(|(k, v)| Some((k.try_to::<i64>().ok()?, v.try_to::<f32>().ok()?)))
                .collect(),
            max_exposed: opt(d, "max_exposed", f32::INFINITY),
            require_unseen: opt(d, "require_unseen", false),
            covered_only: opt(d, "covered_only", false),
            min_range: opt(d, "min_range", 0.0f32),
            max_range: opt(d, "max_range", f32::INFINITY),
            flank_from: opt(d, "flank_from", Vector2::ZERO),
            w_flank: opt(d, "w_flank", 0.0f32),
        }
    }
}

/// A shooter's threat share when it would see the hull only once the guns
/// bloom, and when it could not see it at all (planes, radar, belief error).
const UNSEEN_FIRING_FACTOR: f32 = 0.5;
const UNSEEN_FACTOR: f32 = 0.15;

struct UtilityArgs {
    /// Per enemy id: matchup x condition x class weight, as get_threat_score
    /// computes them for the hull asking.
    danger: HashMap<i64, f32>,
    /// Per enemy id: its concealment radius, for the reveal term.
    spot: HashMap<i64, f32>,
    /// Per enemy id: how much it matters to the team (damage it is doing,
    /// how hurt it is), and a reveal multiplier (more when nobody has it lit).
    value: HashMap<i64, f32>,
    reveal: HashMap<i64, f32>,
    target_near: f32,
    target_alone: f32,
    /// Team-mates' positions: an enemy that can already shoot `n` of them
    /// splits its fire, so its danger reads 1 / (1 + focus_split x n).
    friends: Vec<Vector2>,
    focus_split: f32,
    /// Team-mates' claimed stations and their hull keys: an enemy already
    /// reached (or lit) from `n` of them is worth 1 / (1 + cover_split x n).
    claims: Vec<Vector2>,
    claim_keys: Vec<i64>,
    cover_split: f32,
    threat_sat: f32,
    gun_range: f32,
    /// Where the close term saturates: gun_range unless the caller wants a
    /// launch band or a preferred fighting range instead.
    close_range: f32,
    /// Own concealment radius, and the radius the guns bloom it to.
    radius: f32,
    fire_radius: f32,
    w_reach: f32,
    w_reveal: f32,
    w_close: f32,
    w_threat: f32,
    /// Multiplies the threat cost: 1 at full health, rising with damage.
    aversion: f32,
    w_path: f32,
    held: Vector2,
    avoid: Vec<Vector2>,
    avoid_r2: f32,
}

impl UtilityArgs {
    fn from_dict(d: &VarDictionary) -> Self {
        let gun_range = opt(d, "gun_range", 1.0f32).max(1.0);
        let map = |key: &str| -> HashMap<i64, f32> {
            opt(d, key, VarDictionary::new())
                .iter_shared()
                .filter_map(|(k, v)| Some((k.try_to::<i64>().ok()?, v.try_to::<f32>().ok()?)))
                .collect()
        };
        Self {
            danger: map("enemy_danger"),
            spot: map("enemy_spot"),
            value: map("enemy_value"),
            reveal: map("enemy_reveal"),
            target_near: opt(d, "target_near", 0.0f32),
            target_alone: opt(d, "target_alone", 0.0f32),
            friends: opt(d, "friends", PackedVector2Array::new()).to_vec(),
            focus_split: opt(d, "focus_split", 0.0f32),
            claims: opt(d, "claims", PackedVector2Array::new()).to_vec(),
            claim_keys: opt(d, "claim_keys", PackedInt64Array::new()).to_vec(),
            cover_split: opt(d, "cover_split", 0.0f32),
            threat_sat: opt(d, "threat_sat", std::f32::consts::LN_2),
            gun_range,
            close_range: opt(d, "close_range", gun_range).max(1.0),
            radius: opt(d, "radius", 0.0f32),
            fire_radius: opt(d, "fire_radius", 0.0f32),
            w_reach: opt(d, "w_reach", 1.0f32),
            w_reveal: opt(d, "w_reveal", 0.5f32),
            w_close: opt(d, "w_close", 0.0f32),
            w_threat: opt(d, "w_threat", 1.0f32),
            aversion: opt(d, "aversion", 1.0f32),
            w_path: opt(d, "w_path", 0.5f32),
            held: opt(d, "held", Vector2::new(f32::INFINITY, f32::INFINITY)),
            avoid: opt(d, "avoid", PackedVector2Array::new()).to_vec(),
            avoid_r2: opt(d, "avoid_radius", 0.0f32).powi(2),
        }
    }
}

#[derive(Clone, Copy, Default)]
struct UtilityTerms {
    threat: f32,
    /// Threat as units of pressure (-log2(1 - threat)): linear in what is
    /// pointed at the cell where threat itself saturates, so the cost of a
    /// bad cell keeps growing past anything the value column can pay.
    pressure: f32,
    shooters: f32,
    reach: f32,
    reveal: f32,
    close: f32,
    value: f32,
    risk: f32,
    utility: f32,
}

impl UtilityTerms {
    fn to_dict(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("threat", self.threat);
        d.set("pressure", self.pressure);
        d.set("shooters", self.shooters);
        d.set("reach", self.reach);
        d.set("reveal", self.reveal);
        d.set("close", self.close);
        d.set("value", self.value);
        d.set("risk", self.risk);
        d.set("utility", self.utility);
        d.set("score", self.utility);
        d
    }
}

/// One enemy as the value column sees it for this call: its worth `w`
/// (belief certainty x value x nearness x isolation), the reveal weight,
/// and the threat inputs looked up once instead of per cell.
struct EnemyEval<'a> {
    e: &'a EnemyState,
    reach: Option<&'a [u64]>,
    w: f32,
    reach_w: f32,
    reveal: f32,
    danger: f32,
    spot: f32,
}

/// Evaluates every believed enemy from `here`, and the value normaliser:
/// the three heaviest worths, so covering the targets that matter most
/// scores 1 whatever the team size.
fn enemy_evals<'a>(f: &Field, tl: &'a TeamLayers, hull_key: i64, a: &UtilityArgs, here: Vector2) -> (Vec<EnemyEval<'a>>, f32) {
    let mut out = Vec::with_capacity(tl.enemies.len());
    let friend_cells: Vec<usize> = a.friends.iter().filter_map(|q| f.index(q.x, q.y)).collect();
    let claim_cells: Vec<(usize, i64)> = a.claims.iter().zip(&a.claim_keys)
        .filter_map(|(q, &k)| f.index(q.x, q.y).map(|i| (i, k)))
        .collect();
    for (id, e) in &tl.enemies {
        let near = 1.0 - (here.distance_to(e.origin) / (2.0 * a.gun_range)).clamp(0.0, 1.0);
        let alone = !tl.enemies.iter().any(|(j, o)| j != id && o.origin.distance_to(e.origin) <= a.gun_range);
        let w = e.weight.max(WEIGHT_FLOOR)
            * a.value.get(id).copied().unwrap_or(1.0)
            * (1.0 + a.target_near * near)
            * (1.0 + if alone { a.target_alone } else { 0.0 });
        let spot = a.spot.get(id).copied().unwrap_or(0.0);
        let focused = friend_cells.iter().filter(|&&i| bit_at(&e.fire, i)).count() as f32;
        let reached = claim_cells.iter()
            .filter(|(i, k)| e.reach.get(k).is_some_and(|pl| bit_at(pl, *i)))
            .count() as f32;
        let lit = claim_cells.iter()
            .filter(|(i, _)| bit_at(&e.los, *i) && f.centre(*i).distance_to(e.origin) <= spot)
            .count() as f32;
        out.push(EnemyEval {
            e,
            reach: e.reach.get(&hull_key).map(|pl| pl.as_slice()),
            w,
            reach_w: w / (1.0 + a.cover_split * reached),
            reveal: w * a.reveal.get(id).copied().unwrap_or(1.0) / (1.0 + a.cover_split * lit),
            danger: a.danger.get(id).copied().unwrap_or(1.0) / (1.0 + a.focus_split * focused),
            spot,
        });
    }
    let mut ws: Vec<f32> = out.iter().map(|v| v.w).collect();
    ws.sort_by(|x, y| y.total_cmp(x));
    let norm = ws.iter().take(STATION_COUNT_CAP as usize).sum::<f32>().max(1e-3);
    (out, norm)
}

fn utility_terms(f: &Field, tl: &TeamLayers, p: &ShipPlan, a: &UtilityArgs, ev: &[EnemyEval], norm: f32, idx: usize) -> Option<UtilityTerms> {
    if idx >= p.pass.len() || !p.pass[idx] || !p.safe[idx].is_finite() {
        return None;
    }
    let c = f.centre(idx);
    if a.avoid_r2 > 0.0 && a.avoid.iter().any(|q| q.distance_squared_to(c) < a.avoid_r2) {
        return None;
    }
    let (sh, ch) = tl.cone_dir.get(idx).copied().unwrap_or(0.0).sin_cos();
    let mut t = UtilityTerms::default();
    let mut safe = 1.0f32;
    for v in ev {
        let e = v.e;
        let w = e.weight.max(WEIGHT_FLOOR);
        if v.reach.is_some_and(|pl| bit_at(pl, idx)) {
            t.reach += v.reach_w;
        }
        let (dx, dz) = (e.origin.x - c.x, e.origin.y - c.y);
        let dist = (dx * dx + dz * dz).sqrt();
        if bit_at(&e.los, idx) && dist <= v.spot {
            t.reveal += v.reveal;
        }
        // Progress toward gun range on this one: full inside it, nothing
        // past twice it, so nothing pulls a hull past where it can shoot.
        t.close += v.reach_w * (1.0 - ((dist - a.close_range) / a.close_range).clamp(0.0, 1.0));
        if !bit_at(&e.fire, idx) || e.shell.range <= 0.0 {
            continue;
        }
        t.shooters += 1.0;
        let pressure = (1.0 - (dist / e.shell.range).powi(3)).clamp(0.0, 1.0);
        // sin(heading - bearing) as a cross product with the bearing unit.
        let s = (sh * dz - ch * dx) / dist.max(1e-3);
        // Normalised to a mean of 1 over headings, so a cell reads the
        // ladder's threat on average: bow-on about half, beam-on 1.5x.
        let presentation = (FIRE_BOW_FACTOR + (1.0 - FIRE_BOW_FACTOR) * s * s) / (FIRE_BOW_FACTOR + (1.0 - FIRE_BOW_FACTOR) * 0.5);
        // Shells need eyes: this shooter's own line of sight and true
        // distance, not the team grid, whose certainty division inflates a
        // vague contact's bubble.
        let eyes = bit_at(&e.los, idx) || dist <= e.force_spot;
        let seen = if eyes && dist <= a.radius.max(e.force_spot) {
            1.0
        } else if eyes && dist <= a.fire_radius {
            UNSEEN_FIRING_FACTOR
        } else {
            UNSEEN_FACTOR
        };
        let raw = v.danger * pressure * presentation * seen;
        let this = (1.0 - (-a.threat_sat * raw).exp()) * w;
        safe *= 1.0 - this;
    }
    t.threat = (1.0 - safe).clamp(0.0, 1.0);
    t.pressure = -(1.0 - t.threat).max(1e-3).ln() / a.threat_sat;
    t.value = (a.w_reach * t.reach + a.w_reveal * t.reveal + a.w_close * t.close) / norm;
    t.risk = p.risk.get(idx).copied().unwrap_or(f32::INFINITY);
    if !t.risk.is_finite() {
        return None;
    }
    t.utility = t.value - a.w_threat * a.aversion * t.pressure - a.w_path * t.risk / a.gun_range;
    Some(t)
}

const STATION_COUNT_CAP: f32 = 3.0;

#[derive(Clone, Copy, Default)]
struct StationTerms {
    reach: f32,
    exposed: f32,
    cone: f32,
    detect: f32,
    travel: f32,
    range_err: f32,
    escape: f32,
    detour: f32,
    flank: f32,
    score: f32,
}

impl StationTerms {
    fn to_dict(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("reach", self.reach);
        d.set("exposed", self.exposed);
        d.set("cone_deg", self.cone * 180.0);
        d.set("detect", self.detect);
        d.set("travel", self.travel);
        d.set("range_err", self.range_err);
        d.set("escape", self.escape);
        d.set("detour", self.detour);
        d.set("flank", self.flank);
        d.set("score", self.score);
        d
    }
}

/// Every term is normalised to about 0..1 before its weight. Enemy counts
/// are summed over belief certainty, so a presumed contact counts for a
/// fraction of a live one: reach over STATION_COUNT_CAP (a ship shoots one
/// target at a time), exposure as the fraction of the armed enemy team, cone
/// half-width over pi, distances over gun range or the concealment radius.
/// Per enemy for one station call: this hull's reach plane, fire plane,
/// certainty and class-weighted certainty.
struct StationEnemy<'a> {
    reach: Option<&'a [u64]>,
    fire: &'a [u64],
    w: f32,
    cw: f32,
}

/// The enemies and the class-weighted armed total.
fn station_enemies<'a>(tl: &'a TeamLayers, a: &StationArgs) -> (Vec<StationEnemy<'a>>, f32) {
    let mut armed = 0.0f32;
    let se = tl.enemies.iter().map(|(id, e)| {
        let w = e.weight.max(WEIGHT_FLOOR);
        let cw = w * a.enemy_weights.get(id).copied().unwrap_or(1.0);
        if e.shell.has_guns() {
            armed += cw;
        }
        StationEnemy { reach: e.reach.get(&a.hull_key).map(|pl| pl.as_slice()), fire: &e.fire, w, cw }
    }).collect();
    (se, armed)
}

fn station_terms(f: &Field, tl: &TeamLayers, p: &ShipPlan, a: &StationArgs, se: &[StationEnemy], armed: f32, idx: usize) -> Option<StationTerms> {
    if idx >= p.pass.len() || !p.pass[idx] || !p.safe[idx].is_finite() {
        return None;
    }
    let c = f.centre(idx);
    if a.avoid_r2 > 0.0 && a.avoid.iter().any(|q| q.distance_squared_to(c) < a.avoid_r2) {
        return None;
    }
    let range = c.distance_to(a.toward);
    if range < a.min_range || range > a.max_range {
        return None;
    }
    let mut t = StationTerms::default();
    for e in se {
        if e.reach.is_some_and(|pl| bit_at(pl, idx)) {
            t.reach += e.w;
        }
        if bit_at(e.fire, idx) {
            t.exposed += e.cw;
        }
    }
    if t.exposed > a.max_exposed {
        return None;
    }
    let exposed_frac = if armed > 0.0 { t.exposed / armed } else { 0.0 };
    t.cone = tl.cone_half.get(idx).copied().unwrap_or(-1.0).max(0.0) / std::f32::consts::PI;
    // Once the guns bloom, seen is seen: no distance ramp for a firing cell.
    let d = tl.detect.get(idx).copied().unwrap_or(f32::INFINITY);
    t.detect = if t.reach > 0.0 {
        if d < a.fire_radius { 1.0 } else { 0.0 }
    } else if a.radius > 0.0 && d < a.radius {
        ((a.radius - d) / a.radius).clamp(0.0, EXPOSURE_MAX)
    } else {
        0.0
    };
    if a.require_unseen && t.detect > 0.0 {
        return None;
    }
    if a.covered_only && t.exposed > 0.0 && t.detect > 0.0 {
        return None;
    }
    let gr = a.gun_range.max(1.0);
    t.travel = p.safe[idx] / gr;
    t.range_err = (range - a.pref_range).abs() / gr;
    let esc = p.escape[idx];
    t.escape = if a.radius > 0.0 && esc.is_finite() { 1.0 - (esc / a.radius).min(1.0) } else { 0.0 };
    if a.w_detour > 0.0 {
        let axis = a.toward - a.axis_from;
        let to_cell = c - a.axis_from;
        if axis.length_squared() > 1.0 && to_cell.length_squared() > 1.0 {
            t.detour = 1.0 - axis.normalized().dot(to_cell.normalized()).abs();
        }
    }
    if a.w_flank > 0.0 {
        let axis = a.flank_from - a.toward;
        let to_cell = c - a.toward;
        if axis.length_squared() > 1.0 && to_cell.length_squared() > 1.0 {
            // Angle, not cosine: cosine is flat near the axis, where the slide starts.
            let dot = axis.normalized().dot(to_cell.normalized()).clamp(-1.0, 1.0);
            t.flank = (1.0 - dot.acos() / std::f32::consts::FRAC_PI_2).max(0.0);
        }
    }
    let w = a.w;
    t.score = w[0] * (t.reach.min(STATION_COUNT_CAP) / STATION_COUNT_CAP)
        - w[1] * exposed_frac
        - w[2] * t.cone
        - w[3] * t.detect.min(1.0)
        - w[4] * t.travel
        - w[5] * t.range_err
        + w[6] * t.escape
        - a.w_detour * t.detour
        - a.w_flank * t.flank;
    Some(t)
}

impl Field {
    fn centre(&self, idx: usize) -> Vector2 {
        Vector2::new(
            self.min_x + ((idx as i32 % self.w) as f32 + 0.5) * self.cell,
            self.min_z + ((idx as i32 / self.w) as f32 + 0.5) * self.cell,
        )
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
