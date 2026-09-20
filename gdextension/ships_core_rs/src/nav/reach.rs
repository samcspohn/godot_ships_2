use godot::prelude::*;
use rayon::prelude::*;
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};
use std::sync::Arc;
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
struct Terrain {
    w: i32,
    h: i32,
    cell: f32,
    min_x: f32,
    min_z: f32,
    sdf: Vec<f32>,
    height: Vec<f32>,
}

impl Terrain {
    fn from_map(m: &NavigationMap) -> Self {
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

    fn in_bounds(&self, x: f32, z: f32) -> bool {
        let gx = (x - self.min_x) / self.cell;
        let gz = (z - self.min_z) / self.cell;
        gx >= 0.0 && gz >= 0.0 && gx < self.w as f32 && gz < self.h as f32
    }

    fn bilinear(&self, grid: &[f32], x: f32, z: f32) -> f32 {
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
    /// None sweeps plain line of sight: the first land sample ends the ray.
    table: Option<Arc<RBlockTable>>,
}

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

    fn walk(&mut self, ang: f32, st: &mut RayState, s_end: f32) {
        let (dx, dz) = (ang.sin(), ang.cos());
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
    }
}

/// Rays start MIN_RAYS wide and double every time their spacing would exceed
/// RAY_SPACING_MULT field cells; a child inherits its parent's running block.
fn sweep_one(t: &Terrain, f: &Field, inp: &SweepInput) -> SweepOutput {
    let range = match &inp.table {
        Some(t) => inp.range.min(t.cap),
        None => inp.range,
    };
    let mut sw = Sweep {
        t,
        f,
        inp,
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

struct ShipReach {
    bits: Vec<u64>,
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
    fire: Vec<u64>,
    /// Cells with terrain line of sight to this enemy, out to the team's
    /// largest concealment radius.
    los: Vec<u64>,
    /// Per friendly hull key: cells a hull of that kind can hit THIS enemy
    /// from (the hull's mirrored table, swept outward from the enemy).
    reach: HashMap<i64, Vec<u64>>,
}

#[derive(Default)]
struct TeamLayers {
    hulls: HashMap<i64, Shell>,
    enemies: HashMap<i64, EnemyState>,
    /// Sorted enemy ids; position = bit index in the masks handed out.
    order: Vec<i64>,
    los_range: f32,
    /// Bumped whenever any plane changes; consumers cache off it.
    version: u64,
    /// Min effective distance per cell, INFINITY where no enemy has LOS.
    detect: Vec<f32>,
    detect_version: u64,
    /// Half-width of the narrowest bearing cone holding every enemy that can
    /// hit the cell (-1 where none can) and that cone's centre bearing.
    cone_half: Vec<f32>,
    cone_dir: Vec<f32>,
    cone_version: u64,
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
    price: Vec<f32>,
    pass: Vec<bool>,
    walls_muted: bool,
    max_safe: f32,
    max_escape: f32,
    us: f32,
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
fn dijkstra(f: &Field, bx: BoxR, pass: &[bool], price: &[f32], gain: f32, sources: &[usize], out: &mut [f32]) {
    let mut heap = BinaryHeap::new();
    for &s in sources {
        out[s] = 0.0;
        heap.push(QItem { cost: 0.0, idx: s as u32 });
    }
    let w = f.w;
    let diag = f.cell * std::f32::consts::SQRT_2;
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
                let c = cost + len * (1.0 + gain * 0.5 * (price[idx] + price[n]));
                if c < out[n] {
                    out[n] = c;
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

/// Per-ship "where can my shells land" field over a coarse grid, one bit per
/// cell, built by radial sweeps that leap across open water on the SDF.
#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct ReachField {
    base: Base<RefCounted>,
    terrain: Option<Arc<Terrain>>,
    field: Option<Arc<Field>>,
    tables: HashMap<TableKey, Arc<RBlockTable>>,
    ships: HashMap<i64, ShipReach>,
    teams: HashMap<i32, TeamLayers>,
    /// (team, radius / EXPOSURE_RADIUS_Q, node cells, ncx, ncz) -> (version,
    /// max, mean). Every navigator on a team with the same concealment reads
    /// the same vectors instead of rebuilding them from 123k cells each.
    exposure_cache: HashMap<(i32, i32, i32, i32, i32), (u64, Arc<Vec<f32>>, Arc<Vec<f32>>)>,
    plans: HashMap<i64, ShipPlan>,
    last: Stats,
}

const EXPOSURE_RADIUS_Q: f32 = 250.0;
/// Exposure is 1 at effective distance zero and keeps rising inside a
/// force-spot disc (negative distance); capped so a radar centre prices at
/// most this many times the concealment edge.
const EXPOSURE_MAX: f32 = 3.0;

#[godot_api]
impl IRefCounted for ReachField {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            terrain: None,
            field: None,
            tables: HashMap::new(),
            ships: HashMap::new(),
            teams: HashMap::new(),
            exposure_cache: HashMap::new(),
            plans: HashMap::new(),
            last: Stats::default(),
        }
    }
}

impl ReachField {
    fn table(&mut self, v0: f32, beta: f32, gun_h: f32, tgt_h: f32, cap: f32, mirrored: bool) -> Arc<RBlockTable> {
        let key = TableKey::new(v0, beta, gun_h, tgt_h, cap, mirrored);
        if let Some(t) = self.tables.get(&key) {
            return t.clone();
        }
        let t0 = Instant::now();
        let t = Arc::new(RBlockTable::build(
            v0 as f64, beta as f64, gun_h as f64, tgt_h as f64, cap as f64, mirrored,
        ));
        self.last.table_builds += 1;
        self.last.table_build_us += t0.elapsed().as_secs_f32() * 1e6;
        self.tables.insert(key, t.clone());
        t
    }

    fn run_jobs(&mut self, inputs: &[SweepInput]) -> Vec<SweepOutput> {
        let (Some(terrain), Some(field)) = (self.terrain.clone(), self.field.clone()) else {
            return Vec::new();
        };
        let t0 = Instant::now();
        let outs: Vec<SweepOutput> = inputs
            .par_iter()
            .map(|inp| sweep_one(&terrain, &field, inp))
            .collect();
        for o in &outs {
            self.last.rays += o.rays;
            self.last.samples += o.samples;
            self.last.marks += o.marks;
        }
        self.last.ships += inputs.len() as u32;
        self.last.total_us += t0.elapsed().as_secs_f32() * 1e6;
        outs
    }

    fn run(&mut self, inputs: Vec<SweepInput>) {
        for o in self.run_jobs(&inputs) {
            self.ships.insert(o.id, ShipReach { bits: o.bits });
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
        let cells = (f.w * f.h) as usize;
        let mut grid = vec![f32::INFINITY; cells];
        for e in tl.enemies.values() {
            let inv_w = 1.0 / e.weight.max(WEIGHT_FLOOR);
            for (w, &word) in e.los.iter().enumerate() {
                let mut bits = word;
                while bits != 0 {
                    let b = bits.trailing_zeros() as usize;
                    let idx = w * 64 + b;
                    bits &= bits - 1;
                    if idx >= cells {
                        continue;
                    }
                    let cx = f.min_x + ((idx as i32 % f.w) as f32 + 0.5) * f.cell;
                    let cz = f.min_z + ((idx as i32 / f.w) as f32 + 0.5) * f.cell;
                    let d = Vector2::new(cx, cz).distance_to(e.origin);
                    // Inside a radar/hydro reach the value runs NEGATIVE toward
                    // the emitter, so a ship already inside still sees which
                    // way is out; outside it is distance over certainty.
                    let eff = if d < e.force_spot { d - e.force_spot } else { d * inv_w };
                    if eff < grid[idx] {
                        grid[idx] = eff;
                    }
                }
            }
        }
        tl.detect = grid;
        tl.detect_version = tl.version;
    }

    pub(crate) fn cluster_exposure_vec(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> Vec<f32> {
        self.cluster_exposure_stats(team, radius, cluster_cells, ncx, ncz).0.as_ref().clone()
    }

    /// Per node of `cluster_cells` SDF cells: (max, mean over water cells) of
    /// exposure, 0 outside detection to 1 at effective distance zero. Cached
    /// per (team, quantised radius, node size) against the team version.
    pub(crate) fn cluster_exposure_stats(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> (Arc<Vec<f32>>, Arc<Vec<f32>>) {
        let radius = (radius / EXPOSURE_RADIUS_Q).ceil() * EXPOSURE_RADIUS_Q;
        let key = (team, (radius / EXPOSURE_RADIUS_Q) as i32, cluster_cells, ncx, ncz);
        let version = self.teams.get(&team).map_or(0, |tl| tl.version);
        if let Some((v, max, mean)) = self.exposure_cache.get(&key) {
            if *v == version {
                return (max.clone(), mean.clone());
            }
        }
        let (max, mean) = self.build_exposure_stats(team, radius, cluster_cells, ncx, ncz);
        let out = (Arc::new(max), Arc::new(mean));
        self.exposure_cache.insert(key, (version, out.0.clone(), out.1.clone()));
        out
    }

    fn build_exposure_stats(&mut self, team: i32, radius: f32, cluster_cells: i32, ncx: i32, ncz: i32) -> (Vec<f32>, Vec<f32>) {
        let n = (ncx.max(0) * ncz.max(0)) as usize;
        let mut max = vec![0.0f32; n];
        let mut mean = vec![0.0f32; n];
        let Some(f) = self.field.clone() else { return (max, mean) };
        if radius <= 0.0 || cluster_cells <= 0 {
            return (max, mean);
        }
        self.ensure_detect(team);
        let Some(tl) = self.teams.get(&team) else { return (max, mean) };
        let mut count = vec![0u32; n];
        for (idx, &d) in tl.detect.iter().enumerate() {
            if f.water[idx] == 0 {
                continue;
            }
            let ix = idx as i32 % f.w;
            let iz = idx as i32 / f.w;
            let cx = ix * f.mult / cluster_cells;
            let cz = iz * f.mult / cluster_cells;
            if cx < 0 || cz < 0 || cx >= ncx || cz >= ncz {
                continue;
            }
            let c = (cz * ncx + cx) as usize;
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
        let mult = cell_mult.max(1);
        let terrain = Terrain::from_map(&m);
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
        self.field = Some(Arc::new(Field {
            w: fw,
            h: fh,
            cell: fcell,
            min_x: m.min_x,
            min_z: m.min_z,
            mult,
            water,
            sdf,
        }));
        self.terrain = Some(Arc::new(terrain));
        self.tables.clear();
        self.ships.clear();
        self.teams.clear();
        self.exposure_cache.clear();
        self.plans.clear();
    }

    #[func]
    fn is_built(&self) -> bool {
        self.field.is_some()
    }

    /// Sweep one ship. Returns microseconds spent.
    #[func]
    fn sweep(
        &mut self,
        id: i64,
        origin: Vector2,
        gun_h: f32,
        target_h: f32,
        speed: f32,
        drag: f32,
        range: f32,
    ) -> f32 {
        self.last = Stats::default();
        if self.field.is_none() || speed <= 0.0 || drag <= 0.0 || range <= 0.0 {
            return 0.0;
        }
        let table = Some(self.table(speed, drag, gun_h, target_h, range, false));
        self.run(vec![SweepInput { id, origin, gun_h, range, table }]);
        self.last.total_us
    }

    /// Sweep every ship in the parallel arrays at once, rayon across ships.
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
        self.last = Stats::default();
        let n = ids.len().min(origins.len()).min(gun_heights.len()).min(speeds.len()).min(drags.len()).min(ranges.len());
        let mut inputs = Vec::with_capacity(n);
        if self.field.is_some() {
            for i in 0..n {
                let (speed, drag, range) = (speeds[i], drags[i], ranges[i]);
                if speed <= 0.0 || drag <= 0.0 || range <= 0.0 {
                    continue;
                }
                let table = Some(self.table(speed, drag, gun_heights[i], target_h, range, false));
                inputs.push(SweepInput { id: ids[i], origin: origins[i], gun_h: gun_heights[i], range, table });
            }
            self.run(inputs);
        }
        self.get_last_stats()
    }

    #[func]
    fn get_last_stats(&self) -> VarDictionary {
        let s = self.last;
        let mut d = VarDictionary::new();
        d.set("total_us", s.total_us);
        d.set("ships", s.ships as i64);
        d.set("rays", s.rays as i64);
        d.set("land_samples", s.samples as i64);
        d.set("marks", s.marks as i64);
        d.set("table_builds", s.table_builds as i64);
        d.set("table_build_us", s.table_build_us);
        d.set("tables_cached", self.tables.len() as i64);
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

    /// One byte per field cell, row-major by z; 255 where the ship's shells
    /// can land. Empty when the ship has never been swept.
    #[func]
    fn get_reach_bytes(&self, id: i64) -> PackedByteArray {
        let (Some(f), Some(r)) = (&self.field, self.ships.get(&id)) else {
            return PackedByteArray::new();
        };
        let n = (f.w * f.h) as usize;
        let mut out = vec![0u8; n];
        for (i, b) in out.iter_mut().enumerate() {
            if r.bits[i / 64] & (1u64 << (i % 64)) != 0 {
                *b = 255;
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    #[func]
    fn can_reach(&self, id: i64, point: Vector2) -> bool {
        let (Some(f), Some(r)) = (&self.field, self.ships.get(&id)) else {
            return false;
        };
        match f.index(point.x, point.y) {
            Some(i) => r.bits[i / 64] & (1u64 << (i % 64)) != 0,
            None => false,
        }
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
        let tl = self.teams.entry(team).or_default();
        let n = keys.len().min(speeds.len()).min(drags.len()).min(ranges.len()).min(gun_heights.len());
        let mut hulls = HashMap::new();
        for i in 0..n {
            hulls.insert(keys[i], Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] });
        }
        for e in tl.enemies.values_mut() {
            e.reach.retain(|k, _| hulls.get(k) == tl.hulls.get(k) && hulls.contains_key(k));
        }
        tl.hulls = hulls;
    }

    /// Enemies as `team` believes them: position, shell, lateral `spread`,
    /// certainty `weight`, radar/hydro `force_spot`. `los_range` is the
    /// furthest any ship on the team can be seen from. An enemy is re-swept
    /// only when new, moved more than `move_threshold`, or changed shell or
    /// spread; a hull added since is swept for every enemy lacking it.
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
        self.last = Stats::default();
        let cells = self.cell_count();
        let words = (cells + 63) / 64;
        let n = [ids.len(), origins.len(), speeds.len(), drags.len(), ranges.len(),
            gun_heights.len(), spreads.len(), weights.len(), force_spots.len()]
            .into_iter().min().unwrap();
        // One entry per (enemy, layer, origin); planes are zeroed per (enemy,
        // layer) and the origins ORed in.
        let mut plan: Vec<(i64, Layer, Shell, Vector2)> = Vec::new();
        let mut resweeps = 0u32;
        {
            let tl = self.teams.entry(team).or_default();
            let los_changed = (tl.los_range - los_range).abs() > 1.0;
            tl.los_range = los_range;
            let live: std::collections::HashSet<i64> = (0..n).map(|i| ids[i]).collect();
            let before = tl.enemies.len();
            tl.enemies.retain(|id, _| live.contains(id));
            if tl.enemies.len() != before {
                tl.version += 1;
            }
            for i in 0..n {
                let (id, origin) = (ids[i], origins[i]);
                let shell = Shell { speed: speeds[i], drag: drags[i], range: ranges[i], gun_h: gun_heights[i] };
                let spread = spreads[i].max(0.0);
                let full = match tl.enemies.get_mut(&id) {
                    Some(e) => {
                        let moved = e.origin.distance_to(origin) > move_threshold;
                        let changed = e.shell != shell || (e.spread - spread).abs() > move_threshold;
                        e.origin = origin;
                        e.shell = shell;
                        e.spread = spread;
                        e.weight = weights[i];
                        e.force_spot = force_spots[i];
                        moved || changed
                    }
                    None => {
                        tl.enemies.insert(id, EnemyState {
                            origin,
                            shell,
                            spread,
                            weight: weights[i],
                            force_spot: force_spots[i],
                            fire: vec![0u64; words],
                            los: vec![0u64; words],
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
                if full || los_changed {
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
                    for (&hk, hull) in &tl.hulls {
                        if full || !e.reach.contains_key(&hk) {
                            for &o in &origins {
                                plan.push((id, Layer::Reach(hk), *hull, o));
                            }
                        }
                    }
                }
            }
            tl.order = tl.enemies.keys().copied().collect();
            tl.order.sort_unstable();
            // Detection depends on weight and force_spot even when nothing is
            // re-swept.
            tl.detect_version = u64::MAX;
        }
        let mut inputs = Vec::with_capacity(plan.len());
        for (j, (_, layer, shell, origin)) in plan.iter().enumerate() {
            let (table, range) = match layer {
                Layer::Fire => (Some(self.table(shell.speed, shell.drag, shell.gun_h, target_h, shell.range, false)), shell.range),
                Layer::Reach(_) => (Some(self.table(shell.speed, shell.drag, shell.gun_h, target_h, shell.range, true)), shell.range),
                Layer::Los => (None, los_range),
            };
            inputs.push(SweepInput { id: j as i64, origin: *origin, gun_h: shell.gun_h, range, table });
        }
        let outs = self.run_jobs(&inputs);
        let tl = self.teams.get_mut(&team).unwrap();
        let mut zeroed: std::collections::HashSet<(i64, Layer)> = std::collections::HashSet::new();
        for o in outs {
            let (id, layer, _, _) = plan[o.id as usize];
            let Some(e) = tl.enemies.get_mut(&id) else { continue };
            let plane = match layer {
                Layer::Fire => &mut e.fire,
                Layer::Los => &mut e.los,
                Layer::Reach(hk) => e.reach.entry(hk).or_insert_with(|| vec![0u64; words]),
            };
            if zeroed.insert((id, layer)) {
                plane.iter_mut().for_each(|w| *w = 0);
            }
            for (d, s) in plane.iter_mut().zip(o.bits.iter()) {
                *d |= s;
            }
        }
        if !plan.is_empty() {
            tl.version += 1;
        }
        self.exposure_cache.retain(|k, _| k.0 != team);
        let (n_enemies, n_hulls) = (tl.order.len(), tl.hulls.len());
        let mut d = self.get_last_stats();
        d.set("resweeps", resweeps as i64);
        d.set("jobs", plan.len() as i64);
        d.set("enemies", n_enemies as i64);
        d.set("hulls", n_hulls as i64);
        d
    }

    /// Enemy ids in mask bit order for `team`.
    #[func]
    fn get_team_enemy_ids(&self, team: i32) -> PackedInt64Array {
        match self.teams.get(&team) {
            Some(tl) => PackedInt64Array::from(tl.order.as_slice()),
            None => PackedInt64Array::new(),
        }
    }

    #[func]
    pub(crate) fn get_team_version(&self, team: i32) -> i64 {
        self.teams.get(&team).map_or(0, |tl| tl.version as i64)
    }

    /// Per cell, how many enemies can land shells there.
    #[func]
    fn get_exposure_count_bytes(&self, team: i32) -> PackedByteArray {
        let mut counts = vec![0u8; self.cell_count()];
        if let Some(tl) = self.teams.get(&team) {
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
        if let Some(tl) = self.teams.get(&team) {
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
        let (Some(f), Some(tl)) = (&self.field, self.teams.get(&team)) else { return 0 };
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
        let (Some(f), Some(tl)) = (&self.field, self.teams.get(&team)) else { return 0 };
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
    fn detect_dist_at(&mut self, team: i32, point: Vector2) -> f32 {
        let Some(idx) = self.field.as_ref().and_then(|f| f.index(point.x, point.y)) else {
            return f32::INFINITY;
        };
        self.ensure_detect(team);
        self.teams.get(&team).map_or(f32::INFINITY, |tl| tl.detect[idx])
    }

    #[func]
    fn get_detect_grid(&mut self, team: i32) -> PackedFloat32Array {
        self.ensure_detect(team);
        match self.teams.get(&team) {
            Some(tl) => PackedFloat32Array::from(tl.detect.as_slice()),
            None => PackedFloat32Array::new(),
        }
    }

    /// Per cell for a ship of concealment `radius`: 0 unseen, else 1..255
    /// rising as the effective distance closes to zero.
    #[func]
    fn get_detect_bytes(&mut self, team: i32, radius: f32) -> PackedByteArray {
        self.ensure_detect(team);
        let mut out = vec![0u8; self.cell_count()];
        if let Some(tl) = self.teams.get(&team) {
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
        self.ships.remove(&id);
        self.plans.remove(&id);
    }

    #[func]
    fn clear(&mut self) {
        self.ships.clear();
        self.teams.clear();
        self.plans.clear();
    }

    /// Certainty-weighted mean of where `team` believes its enemies are.
    #[func]
    fn get_team_danger_centre(&self, team: i32) -> Vector2 {
        let Some(tl) = self.teams.get(&team) else { return Vector2::ZERO };
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
    fn get_cone_bytes(&mut self, team: i32) -> PackedByteArray {
        self.ensure_cone(team);
        let mut out = vec![0u8; self.cell_count()];
        if let Some(tl) = self.teams.get(&team) {
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
    fn cone_at(&mut self, team: i32, point: Vector2) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("half", -1.0f32);
        d.set("heading", 0.0f32);
        d.set("count", 0i64);
        let Some(idx) = self.field.as_ref().and_then(|f| f.index(point.x, point.y)) else { return d };
        self.ensure_cone(team);
        let Some(tl) = self.teams.get(&team) else { return d };
        if tl.cone_half.len() <= idx {
            return d;
        }
        d.set("half", tl.cone_half[idx]);
        d.set("heading", tl.cone_dir[idx]);
        d.set("count", tl.enemies.values().filter(|e| bit_at(&e.fire, idx)).count() as i64);
        d
    }

    /// Build (or reuse) the safe-cost and escape layers for ship `id` of
    /// concealment `radius` standing at `pos`, priced like its router:
    /// `price_mode` 0 = detection exposure, 1 = number of enemies that can
    /// land shells; `gain` 0/INF makes any price a wall. Layers cover a box
    /// of `box_radius` around the ship. Returns stats plus `marker`: the
    /// unpriced cell reachable at finite cost that lies nearest `toward`.
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
        let mut d = VarDictionary::new();
        let Some(f) = self.field.clone() else { return d };
        let Some(cell) = f.index(pos.x, pos.y) else { return d };
        self.ensure_detect(team);
        let version = self.teams.get(&team).map_or(0, |t| t.version);
        let key = PlanKey {
            team,
            cell,
            radius_q: radius.round() as i32,
            gain_bits: gain.to_bits(),
            clearance_q: clearance.round() as i32,
            box_cells: (box_radius / f.cell).ceil().max(1.0) as i32,
            mode: price_mode,
            version,
        };
        let cached = self.plans.get(&id).is_some_and(|p| p.key == key);
        if !cached {
            let plan = self.build_plan(&f, key, radius, gain, clearance);
            self.plans.insert(id, plan);
        }
        let p = &self.plans[&id];
        let mut best: Option<(f32, usize)> = None;
        for iz in p.bx.z0..=p.bx.z1 {
            for ix in p.bx.x0..=p.bx.x1 {
                let i = (iz * f.w + ix) as usize;
                if !p.pass[i] || p.price[i] > 0.0 || !p.safe[i].is_finite() {
                    continue;
                }
                let c = f.centre(i);
                let dist = c.distance_squared_to(toward);
                if best.is_none_or(|(b, _)| dist < b) {
                    best = Some((dist, i));
                }
            }
        }
        d.set("cached", cached);
        d.set("us", p.us);
        d.set("walls_muted", p.walls_muted);
        d.set("escape_here", p.escape[cell]);
        d.set("max_safe", p.max_safe);
        d.set("max_escape", p.max_escape);
        d.set("has_marker", best.is_some());
        d.set("marker", best.map_or(Vector2::ZERO, |(_, i)| f.centre(i)));
        d.set("marker_cost", best.map_or(f32::INFINITY, |(_, i)| p.safe[i]));
        d
    }

    /// 0 outside the plan or unreachable, else 1..255 by cost over the
    /// costliest reachable cell.
    #[func]
    fn get_safe_cost_bytes(&self, id: i64) -> PackedByteArray {
        let mut out = vec![0u8; self.cell_count()];
        if let Some(p) = self.plans.get(&id) {
            let scale = p.max_safe.max(1.0);
            for (o, &c) in out.iter_mut().zip(p.safe.iter()) {
                if c.is_finite() {
                    *o = 1 + (254.0 * (c / scale).clamp(0.0, 1.0)).round() as u8;
                }
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    /// 0 outside the plan, 1 where nobody prices the cell, else 2..255 by
    /// distance to the nearest such cell.
    #[func]
    fn get_escape_bytes(&self, id: i64) -> PackedByteArray {
        let mut out = vec![0u8; self.cell_count()];
        if let Some(p) = self.plans.get(&id) {
            let scale = p.max_escape.max(1.0);
            for (o, &c) in out.iter_mut().zip(p.escape.iter()) {
                if c.is_finite() {
                    *o = if c <= 0.0 { 1 } else { 2 + (253.0 * (c / scale).clamp(0.0, 1.0)).round() as u8 };
                }
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    /// Argmax of the station score over the cells of ship `id`'s plan (see
    /// plan_ship). `opts`: weights [reach, exposed, cone, detect, travel,
    /// range, escape], gun_range, pref_range, radius, toward, held (scored
    /// too, for hysteresis), avoid + avoid_radius (team-mates' claims, cells
    /// inside are skipped), axis_from + w_detour (penalty for cells off the
    /// line from axis_from through toward).
    #[func]
    fn score_station(&mut self, team: i32, id: i64, hull_key: i64, opts: VarDictionary) -> VarDictionary {
        let t0 = Instant::now();
        let mut d = VarDictionary::new();
        d.set("has_best", false);
        d.set("held_score", f32::NEG_INFINITY);
        self.ensure_cone(team);
        let (Some(f), Some(tl), Some(p)) = (self.field.as_ref(), self.teams.get(&team), self.plans.get(&id)) else {
            return d;
        };
        let a = StationArgs::from_dict(hull_key, &opts);
        let mut best: Option<(usize, StationTerms)> = None;
        let mut cells = 0u32;
        for iz in p.bx.z0..=p.bx.z1 {
            for ix in p.bx.x0..=p.bx.x1 {
                let idx = (iz * f.w + ix) as usize;
                let Some(t) = station_terms(f, tl, p, &a, idx) else { continue };
                cells += 1;
                if best.is_none_or(|(_, b)| t.score > b.score) {
                    best = Some((idx, t));
                }
            }
        }
        if let Some((idx, t)) = best {
            d.set("has_best", true);
            d.set("best", f.centre(idx));
            d.set("best_score", t.score);
            d.set("best_terms", &t.to_dict());
        }
        if let Some(t) = f.index(a.held.x, a.held.y).and_then(|i| station_terms(f, tl, p, &a, i)) {
            d.set("held_score", t.score);
            d.set("held_terms", &t.to_dict());
        }
        d.set("cells", cells as i64);
        d.set("us", t0.elapsed().as_secs_f32() * 1e6);
        d
    }

    /// The station score of one point under the same `opts`, or an empty
    /// dictionary when it is outside the plan, unreachable or claimed.
    #[func]
    fn station_score_at(&mut self, team: i32, id: i64, hull_key: i64, opts: VarDictionary, point: Vector2) -> VarDictionary {
        self.ensure_cone(team);
        let (Some(f), Some(tl), Some(p)) = (self.field.as_ref(), self.teams.get(&team), self.plans.get(&id)) else {
            return VarDictionary::new();
        };
        let a = StationArgs::from_dict(hull_key, &opts);
        match f.index(point.x, point.y).and_then(|i| station_terms(f, tl, p, &a, i)) {
            Some(t) => t.to_dict(),
            None => VarDictionary::new(),
        }
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
    /// Distance-to-`toward` band a candidate must lie in: a kite opens range
    /// with min_range above where the ship stands, a push closes with
    /// max_range below it.
    min_range: f32,
    max_range: f32,
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
            min_range: opt(d, "min_range", 0.0f32),
            max_range: opt(d, "max_range", f32::INFINITY),
        }
    }
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
        d.set("score", self.score);
        d
    }
}

/// Every term is normalised to about 0..1 before its weight. Enemy counts
/// are summed over belief certainty, so a presumed contact counts for a
/// fraction of a live one: reach over STATION_COUNT_CAP (a ship shoots one
/// target at a time), exposure as the fraction of the armed enemy team, cone
/// half-width over pi, distances over gun range or the concealment radius.
fn station_terms(f: &Field, tl: &TeamLayers, p: &ShipPlan, a: &StationArgs, idx: usize) -> Option<StationTerms> {
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
    let mut armed = 0.0f32;
    for (id, e) in &tl.enemies {
        let w = e.weight.max(WEIGHT_FLOOR);
        if e.reach.get(&a.hull_key).is_some_and(|pl| bit_at(pl, idx)) {
            t.reach += w;
        }
        let cw = w * a.enemy_weights.get(id).copied().unwrap_or(1.0);
        if e.shell.has_guns() {
            armed += cw;
        }
        if bit_at(&e.fire, idx) {
            t.exposed += cw;
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
    let w = a.w;
    t.score = w[0] * (t.reach.min(STATION_COUNT_CAP) / STATION_COUNT_CAP)
        - w[1] * exposed_frac
        - w[2] * t.cone
        - w[3] * t.detect.min(1.0)
        - w[4] * t.travel
        - w[5] * t.range_err
        + w[6] * t.escape
        - a.w_detour * t.detour;
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

impl ReachField {
    fn plan_value(&self, id: i64, point: Vector2, safe: bool) -> f32 {
        let (Some(f), Some(p)) = (&self.field, self.plans.get(&id)) else { return f32::INFINITY };
        match f.index(point.x, point.y) {
            Some(i) => if safe { p.safe[i] } else { p.escape[i] },
            None => f32::INFINITY,
        }
    }

    fn ensure_cone(&mut self, team: i32) {
        let Some(f) = self.field.clone() else { return };
        let cells = (f.w * f.h) as usize;
        let Some(tl) = self.teams.get(&team) else { return };
        if tl.cone_version == tl.version && tl.cone_half.len() == cells {
            return;
        }
        let enemies: Vec<(Vector2, &[u64])> =
            tl.order.iter().map(|id| (tl.enemies[id].origin, tl.enemies[id].fire.as_slice())).collect();
        let mut half = vec![-1.0f32; cells];
        let mut dir = vec![0.0f32; cells];
        let w = f.w as usize;
        half.par_chunks_mut(w).zip(dir.par_chunks_mut(w)).enumerate().for_each(|(iz, (hrow, drow))| {
            let mut b: Vec<f32> = Vec::with_capacity(enemies.len());
            for ix in 0..w {
                let idx = iz * w + ix;
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
                hrow[ix] = 0.5 * cone;
                let mut mid = start + 0.5 * cone;
                if mid > std::f32::consts::PI {
                    mid -= std::f32::consts::TAU;
                }
                drow[ix] = mid;
            }
        });
        let tl = self.teams.get_mut(&team).unwrap();
        tl.cone_half = half;
        tl.cone_dir = dir;
        tl.cone_version = tl.version;
    }

    fn build_plan(&mut self, f: &Arc<Field>, key: PlanKey, radius: f32, gain: f32, clearance: f32) -> ShipPlan {
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
        let mut terrain_ok = vec![false; cells];
        if let Some(tl) = self.teams.get(&key.team) {
            let fire: Vec<&[u64]> = tl.enemies.values().map(|e| e.fire.as_slice()).collect();
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
                        _ => fire.iter().filter(|p| bit_at(p, i)).count() as f32,
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
        let g = if cost_mode { gain } else { 0.0 };
        if pass[key.cell] {
            dijkstra(f, bx, &pass, &price, g, &[key.cell], &mut safe);
        }
        let dark: Vec<usize> = (0..cells).filter(|&i| terrain_ok[i] && price[i] <= 0.0).collect();
        let mut escape = vec![f32::INFINITY; cells];
        dijkstra(f, bx, &terrain_ok, &price, 0.0, &dark, &mut escape);
        let max_of = |v: &[f32]| v.iter().copied().filter(|c| c.is_finite()).fold(0.0f32, f32::max);
        ShipPlan {
            key,
            bx,
            max_safe: max_of(&safe),
            max_escape: max_of(&escape),
            safe,
            escape,
            price,
            pass,
            walls_muted,
            us: t0.elapsed().as_secs_f32() * 1e6,
        }
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
