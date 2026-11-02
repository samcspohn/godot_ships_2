use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Node3D, PhysicsDirectSpaceState3D, Resource};
use std::collections::BTreeMap;

use super::util::armor_rays_for;
use super::ProjectileManager;
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::projectile::armor::mesh::{ArmorMesh, V3};
use crate::projectile::armor::walk::{walk_plates, ShellSpec, StepLog};
use crate::projectile::armor::{hit_result, NativeArmorInteraction, K_NOSE_APC, WATER_DRAG};
use crate::ballistics::drag_v2::GRAVITY;
use crate::projectile::data::ProjectileData;

pub const CELL_MISS: u8 = 0xFF;
pub const CELL_UNWALKED: u8 = 0xFE;
pub const CELL_TURRET: u8 = 0x10;
pub const CELL_CODE_MASK: u8 = 0x0F;
/// The ArmorPart.Type of the part that takes the damage, which is also the HP
/// section its pools are drawn from, so the payout can be saturation-aware.
pub const CELL_SECTION_SHIFT: u8 = 5;
pub const CELL_SECTION_MASK: u8 = 0xE0;
pub const SECTION_MAX: i32 = 5;
pub const FLAG_CITADEL: u8 = 0x01;
pub const FLAG_TURRET: u8 = 0x02;
/// The ray met the water before the hull: AP arrived through it, HE would not.
pub const FLAG_WATER: u8 = 0x04;

/// A baked bucket is one flat blob, not a dictionary of arrays: at ~9000
/// buckets a fleet the per-key Variant framing cost more than the payload.
///
/// ```text
///  0 u8  nx          20 f32x3 dir
///  1 u8  ny          32 f32[ny+1] v_edges: plane v of the row boundaries.
///  2 u16 np             Rows are not uniform: fine at the waterline so a
///  4 f32x4 rect         short citadel band is sampled, coarse above.
///                  E=32+4(ny+1)  cells (profile index): u8, or u16 when np > 255
///                  R=E+nx*ny*cw  u16 n_ref | u8 kx | u8 ky[ny] | u16 split cell[n_ref]
///                                | u8 n_anchor | f32x2 anchor[n_anchor]   (v16)
///                  S             sub-cells, kx*ky[row] per split cell, row-major
///                  A=S+n_sub*cw  u16[np] first_mm (MM_MISS = no hit)
///                    A+2np   u8[np]  first_flags
///                    A+3np   u8[np]  bp_cnt
///                    A+4np   u8[np]  bp_cnt_om
///                  B=A+5np   (u16 mm, u8 code)[sum bp_cnt]
///                  C=B+3*sum (u16 mm, u8 code)[sum bp_cnt_om]
///                  D         u8 n_cls | f32 auto_bounce[n_cls] (rad, ascending)        (v18)
///                            per class 1..n_cls: u16 n_over | (u16 profile, u8 cnt, u8 cnt_om)[n_over]
///                            | base runs | om runs: the profiles whose lists differ from the class below
/// ```
/// A–C are bounce class 0. An AP shell resolves with the highest class at or under its auto_bounce.
pub const BLOB_HDR: usize = 32;
pub const MM_MISS: u16 = 0xFFFF;
/// Breakpoint counts are u8; the sweep can emit at most `coarse + budget`.
const BP_MAX: usize = 255;

#[inline]
pub(super) fn rd_u16(b: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([b[off], b[off + 1]])
}

#[inline]
fn rd_f32(b: &[u8], off: usize) -> f32 {
    f32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}

pub struct BlobHdr {
    pub nx: usize,
    pub ny: usize,
    pub np: usize,
    pub rect: Vector4,
    pub dir: Vector3,
    /// Byte offsets of the v_edges, cells, sub-cells and profile sections.
    pub edges: usize,
    pub cells: usize,
    pub subs: usize,
    /// Bytes per cell index: 1, or 2 once a bucket has more than 255 profiles.
    pub cw: usize,
    pub prof: usize,
    pub refine: Refine,
}

impl BlobHdr {
    /// Grid cells first, then the sub-cells.
    pub fn cell(&self, b: &[u8], i: usize) -> usize {
        let g = self.nx * self.ny;
        let off = if i < g { self.cells + i * self.cw } else { self.subs + (i - g) * self.cw };
        if self.cw == 2 { rd_u16(b, off) as usize } else { b[off] as usize }
    }

    pub fn n_codes(&self) -> usize {
        self.nx * self.ny + self.refine.n_sub
    }
}

/// Grid cells around the feature points, split `kx` x `ky[row]`, and the points (plane u, v).
#[derive(Default, Clone)]
pub struct Refine {
    pub kx: usize,
    pub ky: Vec<usize>,
    /// Grid index of each split cell, ascending.
    pub cells: Vec<usize>,
    pub anchors: Vec<(f32, f32)>,
    pub n_sub: usize,
}

/// The refine section at `off` (layout above) and its length in bytes.
pub fn parse_refine(b: &[u8], off: usize, nx: usize, ny: usize) -> Option<(Refine, usize)> {
    let mut o = off;
    if b.len() < o + 3 + ny {
        return None;
    }
    let n_ref = rd_u16(b, o) as usize;
    let kx = (b[o + 2] as usize).max(1);
    o += 3;
    let ky: Vec<usize> = b[o..o + ny].iter().map(|&k| (k as usize).max(1)).collect();
    o += ny;
    if b.len() < o + 2 * n_ref + 1 {
        return None;
    }
    let cells: Vec<usize> = (0..n_ref).map(|i| rd_u16(b, o + 2 * i) as usize).collect();
    o += 2 * n_ref;
    let na = b[o] as usize;
    o += 1;
    if b.len() < o + 8 * na || cells.iter().any(|&c| c >= nx * ny) {
        return None;
    }
    let anchors = (0..na).map(|i| (rd_f32(b, o + 8 * i), rd_f32(b, o + 8 * i + 4))).collect();
    o += 8 * na;
    let n_sub = cells.iter().map(|&c| kx * ky[c / nx]).sum();
    Some((Refine { kx, ky, cells, anchors, n_sub }, o - off))
}

pub fn blob_header(b: &[u8]) -> Option<BlobHdr> {
    if b.len() < BLOB_HDR {
        return None;
    }
    let (nx, ny) = (b[0] as usize, b[1] as usize);
    let np = rd_u16(b, 2) as usize;
    let rect = Vector4::new(rd_f32(b, 4), rd_f32(b, 8), rd_f32(b, 12), rd_f32(b, 16));
    let dir = Vector3::new(rd_f32(b, 20), rd_f32(b, 24), rd_f32(b, 28));
    let edges = BLOB_HDR;
    let cells = edges + 4 * (ny + 1);
    let cw = if np > 255 { 2 } else { 1 };
    let (refine, len) = parse_refine(b, cells + nx * ny * cw, nx, ny)?;
    let subs = cells + nx * ny * cw + len;
    let prof = subs + refine.n_sub * cw;
    if b.len() < prof + 5 * np {
        return None;
    }
    Some(BlobHdr { nx, ny, np, rect, dir, edges, cells, subs, cw, prof, refine })
}

/// Kernel mass along one axis: per coarse cell, and per fine cell where cells are split.
pub(crate) struct AxisW {
    pub w: Vec<f64>,
    pub q: Vec<f64>,
    pub wf: Vec<f64>,
    pub qf: Vec<f64>,
}

impl AxisW {
    pub fn sums(&self) -> (f64, f64) {
        (self.w.iter().sum(), self.q.iter().sum())
    }
}

/// A lattice's cells as integrated: the grid, with split cells replaced by their sub-cells.
/// Code index: grid cells row-major, then each split cell's sub-cells row-major.
pub(crate) struct Leaves {
    pub nx: usize,
    pub ny: usize,
    pub kx: usize,
    uf: Vec<f64>,
    vf: Vec<f64>,
    vo: Vec<usize>,
    split: Vec<bool>,
    rows: Vec<Vec<(usize, usize)>>,
    pub n_codes: usize,
}

impl Leaves {
    pub fn new(nx: usize, ny: usize, u0: f64, u1: f64, ve: &[f64], r: Option<&Refine>) -> Self {
        let kx = r.map_or(1, |r| r.kx.max(1));
        let du = (u1 - u0) / (nx * kx).max(1) as f64;
        let uf: Vec<f64> = (0..=nx * kx).map(|i| u0 + du * i as f64).collect();
        let mut vo = vec![0usize; ny + 1];
        let mut vf = Vec::new();
        for iy in 0..ny {
            let k = r.and_then(|r| r.ky.get(iy).copied()).unwrap_or(1).max(1);
            for sy in 0..k {
                vf.push(ve[iy] + (ve[iy + 1] - ve[iy]) * sy as f64 / k as f64);
            }
            vo[iy + 1] = vo[iy] + k;
        }
        vf.push(ve[ny]);
        let mut split = vec![false; nx * ny];
        let mut rows = vec![Vec::new(); ny];
        let mut next = nx * ny;
        if let Some(r) = r {
            for &c in &r.cells {
                let iy = c / nx;
                split[c] = true;
                rows[iy].push((c % nx, next));
                next += kx * (vo[iy + 1] - vo[iy]);
            }
        }
        Self { nx, ny, kx, uf, vf, vo, split, rows, n_codes: next }
    }

    fn axis(edges: &[f64], groups: impl Fn(usize) -> (usize, usize), n: usize, aim: f64, hd: f64, s: f64,
            erf_bound: f64, guar: &dyn Fn(f64) -> f64) -> AxisW {
        let (wf, qf) = axis_weights(edges, aim, hd, s, erf_bound, guar);
        let (mut w, mut q) = (Vec::with_capacity(n), Vec::with_capacity(n));
        for i in 0..n {
            let (a, b) = groups(i);
            w.push(wf[a..b].iter().sum());
            q.push(qf[a..b].iter().sum());
        }
        AxisW { w, q, wf, qf }
    }

    pub fn u_weights(&self, aim: f64, hd: f64, s: f64, erf_bound: f64, guar: &dyn Fn(f64) -> f64) -> AxisW {
        let kx = self.kx;
        Self::axis(&self.uf, |i| (i * kx, i * kx + kx), self.nx, aim, hd, s, erf_bound, guar)
    }

    pub fn v_weights(&self, aim: f64, hd: f64, s: f64, erf_bound: f64, guar: &dyn Fn(f64) -> f64) -> AxisW {
        let vo = &self.vo;
        Self::axis(&self.vf, |i| (vo[i], vo[i + 1]), self.ny, aim, hd, s, erf_bound, guar)
    }

    /// `p` summed across each row under column weights `w` (unsplit cells, per row) and `wf`
    /// (split cells, per fine row).
    pub fn u_pass(&self, w: &[f64], wf: &[f64], p: &[f64], r: &mut Vec<f64>, sub: &mut Vec<f64>) {
        let (nx, kx) = (self.nx, self.kx);
        r.clear();
        sub.clear();
        sub.resize(self.vo[self.ny], 0.0);
        for iy in 0..self.ny {
            let row = &p[iy * nx..iy * nx + nx];
            let sp = &self.split[iy * nx..iy * nx + nx];
            let mut acc = 0.0;
            for ix in 0..nx {
                if !sp[ix] {
                    acc += w[ix] * row[ix];
                }
            }
            r.push(acc);
            for &(ix, s0) in &self.rows[iy] {
                let cw = &wf[ix * kx..ix * kx + kx];
                for sy in 0..self.vo[iy + 1] - self.vo[iy] {
                    let ps = &p[s0 + sy * kx..s0 + sy * kx + kx];
                    sub[self.vo[iy] + sy] += cw.iter().zip(ps).map(|(a, b)| a * b).sum::<f64>();
                }
            }
        }
    }

    pub fn v_pass(&self, w: &[f64], wf: &[f64], r: &[f64], sub: &[f64]) -> f64 {
        w.iter().zip(r).map(|(a, b)| a * b).sum::<f64>() + wf.iter().zip(sub).map(|(a, b)| a * b).sum::<f64>()
    }
}

pub fn blob_v_edges(b: &[u8], h: &BlobHdr) -> PackedFloat32Array {
    let mut out = PackedFloat32Array::new();
    out.resize(h.ny + 1);
    for i in 0..=h.ny {
        out[i] = rd_f32(b, h.edges + 4 * i);
    }
    out
}

const WALK_MARGIN_M: f32 = 15.0;
const WALK_ENTRY_MIN_M: f32 = 60.0;
const WALK_EXIT_MIN_M: f32 = 80.0;
const MAX_SWEEP_WALKS: usize = 240;

/// Distance back along `-ld` and forward along `ld` for a segment through `lp`
/// to cross the grown box from outside to outside (slab test, target frame).
fn walk_span(aabb: Aabb, lp: Vector3, ld: Vector3) -> (f32, f32) {
    if aabb.size == Vector3::ZERO {
        return (WALK_ENTRY_MIN_M, WALK_EXIT_MIN_M);
    }
    let lo = (aabb.position - Vector3::splat(WALK_MARGIN_M)).to_array();
    let hi = (aabb.position + aabb.size + Vector3::splat(WALK_MARGIN_M)).to_array();
    let ld = ld.to_array();
    let lp = lp.to_array();
    let mut t_enter = f32::NEG_INFINITY;
    let mut t_exit = f32::INFINITY;
    for axis in 0..3 {
        let d = ld[axis];
        if d.abs() < 0.0001 {
            continue;
        }
        let t0 = (lo[axis] - lp[axis]) / d;
        let t1 = (hi[axis] - lp[axis]) / d;
        t_enter = t_enter.max(t0.min(t1));
        t_exit = t_exit.min(t0.max(t1));
    }
    let cap = (aabb.size + Vector3::splat(2.0 * WALK_MARGIN_M)).length();
    (
        (-t_enter).min(cap).max(WALK_ENTRY_MIN_M),
        t_exit.min(cap).max(WALK_EXIT_MIN_M),
    )
}

pub(super) fn erf(x: f64) -> f64 {
    const P: f64 = 0.3275911;
    const A1: f64 = 0.254829592;
    const A2: f64 = -0.284496736;
    const A3: f64 = 1.421413741;
    const A4: f64 = -1.453152027;
    const A5: f64 = 1.061405429;
    let t = 1.0 / (1.0 + P * x.abs());
    let poly = t * (A1 + t * (A2 + t * (A3 + t * (A4 + t * A5))));
    x.signum() * (1.0 - poly * (-x * x).exp())
}

/// CDF of N(0, 1/s^2) truncated to [-1, 1], in normalised offset units.
pub(super) fn trunc_gauss_cdf(x: f64, s: f64, erf_bound: f64) -> f64 {
    if x <= -1.0 {
        return 0.0;
    }
    if x >= 1.0 {
        return 1.0;
    }
    0.5 + 0.5 * erf(x * s / std::f64::consts::SQRT_2) / erf_bound
}

/// Kernel mass per cell along one axis, cells bounded by `edges` (n+1 of them).
pub(super) fn axis_weights(
    edges: &[f64], aim: f64, half_disp: f64, s: f64, erf_bound: f64,
    guar_cdf: &dyn Fn(f64) -> f64,
) -> (Vec<f64>, Vec<f64>) {
    let n = edges.len().saturating_sub(1);
    let hd = half_disp.max(1e-3);
    let mut g = Vec::with_capacity(n);
    let mut q = Vec::with_capacity(n);
    if n == 0 {
        return (g, q);
    }
    let x0 = (edges[0] - aim) / hd;
    let mut prev_g = trunc_gauss_cdf(x0, s, erf_bound);
    let mut prev_q = guar_cdf(x0);
    for i in 0..n {
        let x = (edges[i + 1] - aim) / hd;
        let cg = trunc_gauss_cdf(x, s, erf_bound);
        let cq = guar_cdf(x);
        g.push(cg - prev_g);
        q.push(cq - prev_q);
        prev_g = cg;
        prev_q = cq;
    }
    (g, q)
}

/// The game's underwater run, as `process_travel` does it: the fuze arms at the
/// surface and the shell is projected `fuze_delay` seconds under WATER_DRAG,
/// ShellParams re-deriving vt/tau from the scaled drag. Returns the run's
/// length and the velocity `under` metres in, or None if the hull is beyond it.
/// Time is apportioned linearly by distance, as the live path does.
fn water_run(spec: &ShellSpec, dir: Vector3, speed: f64, under: f64) -> Option<(f64, Vector3)> {
    use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2 as P;
    let beta = spec.beta * WATER_DRAG;
    if beta <= 0.0 || spec.fuze_delay <= 0.0 {
        return None;
    }
    let vt = (GRAVITY / beta).sqrt();
    let tau = vt / GRAVITY;
    let (dx, dy, dz) = (dir.x as f64, dir.y as f64, dir.z as f64);
    let h = (dx * dx + dz * dz).sqrt();
    let (cos_t, sin_t) = (h, dy);
    let t = spec.fuze_delay;
    let x = P::horizontal_position(cos_t, t, speed, beta);
    let y = P::vertical_position(sin_t, t, speed, vt, tau);
    let run = (x * x + y * y).sqrt();
    if !(under <= run) || run <= 0.0 {
        return None;
    }
    let ti = t * under / run;
    let vh = P::horizontal_velocity(cos_t, ti, speed, beta);
    let vy = P::vertical_velocity(sin_t, ti, speed, vt, tau);
    let hs = if h > 1e-9 { vh / h } else { 0.0 };
    Some((ti, Vector3::new((dx * hs) as f32, vy as f32, (dz * hs) as f32)))
}

/// One shell through plane point `p` (ship-local) arriving along `dir` at
/// `speed`, straddling the hull: (result byte, first part, plates met, met
/// water first). A ray that meets the surface before the hull is walked on
/// through the water only as far as the game would carry it.
fn walk_cell(
    mesh: &ArmorMesh, aabb: Aabb, spec: &ShellSpec, p: Vector3, dir: Vector3, speed: f64, log: bool,
) -> (u8, usize, Vec<StepLog>, bool) {
    let (entry, exit) = walk_span(aabb, p, dir);
    let prev = p - dir * entry;
    let from = prev - dir * 10.0;
    let to = p + dir * exit;
    let Some(hit) = mesh.raycast(V3::from_godot(from), V3::from_godot(to)) else {
        return (CELL_MISS, 0, Vec::new(), false);
    };
    let mut vel = dir * (speed as f32);
    let mut fuze = -1.0;
    let mut hit_water = false;
    if dir.y < 0.0 {
        let s_w = -p.y / dir.y;
        let s_h = (hit.pos.to_godot() - p).dot(dir);
        if s_w < s_h {
            hit_water = true;
            let Some((ti, v)) = water_run(spec, dir, speed, (s_h - s_w) as f64) else {
                return (CELL_MISS, 0, Vec::new(), true);
            };
            vel = v;
            fuze = ti;
        }
    }
    let out = walk_plates(mesh, spec, &hit, vel, fuze, hit_water, log);
    let part = out.final_part.unwrap_or(out.first_part);
    let mut code = (out.damage_result.clamp(0, 15) as u8) & CELL_CODE_MASK;
    if mesh.is_dynamic(part) {
        code |= CELL_TURRET;
    }
    code |= (mesh.armor_type(part).clamp(0, SECTION_MAX) as u8) << CELL_SECTION_SHIFT;
    (code, out.first_part, out.steps, hit_water)
}

/// Breakpoints of the result over penetration at one point: coarse samples,
/// then bisection wherever neighbours differ.
#[allow(clippy::too_many_arguments)]
fn sweep(
    mesh: &ArmorMesh, aabb: Aabb, base: &ShellSpec, base_pen: f64, p: Vector3, dir: Vector3,
    speed: f64, pens: &[f64], bisect_mm: f64, overmatch: f64, bounce: f64,
) -> (Vec<(f32, u8)>, u64) {
    let mut walks: u64 = 0;
    let at = |pen: f64, walks: &mut u64| -> u8 {
        let mut s = *base;
        s.pen_mod = pen / base_pen;
        s.overmatch = overmatch;
        s.auto_bounce = bounce;
        *walks += 1;
        walk_cell(mesh, aabb, &s, p, dir, speed, false).0
    };
    let mut samples: Vec<(f64, u8)> = pens.iter().map(|&pen| (pen, at(pen, &mut walks))).collect();
    let mut budget = MAX_SWEEP_WALKS;
    loop {
        let mut split: Option<usize> = None;
        for k in 1..samples.len() {
            if samples[k].1 != samples[k - 1].1 && samples[k].0 - samples[k - 1].0 > bisect_mm {
                split = Some(k);
                break;
            }
        }
        let Some(k) = split else { break };
        if budget == 0 {
            break;
        }
        budget -= 1;
        let mid = 0.5 * (samples[k].0 + samples[k - 1].0);
        let c = at(mid, &mut walks);
        samples.insert(k, (mid, c));
    }
    let mut bps = vec![(0.0f32, samples[0].1)];
    for k in 1..samples.len() {
        if samples[k].1 != samples[k - 1].1 {
            bps.push((samples[k].0 as f32, samples[k].1));
        }
    }
    (bps, walks)
}

/// One lattice: parallel rays along ship-local `dir` at `v_ref` against the
/// hull's armour mesh. Cells are grouped into profiles by the plates they meet,
/// and each profile is swept in penetration to find where the result changes,
/// once with overmatch off and once with the first plate overmatched when any
/// fleet shell could.
#[allow(clippy::too_many_arguments)]
pub(crate) fn sweep_bucket(
    mesh: &ArmorMesh,
    aabb: Aabb,
    ref_spec: &ShellSpec,
    dir: Vector3,
    v_ref: f64,
    pts: &[Vector3],
    nx: i32,
    ny: i32,
    rect: Vector4,
    v_edges: &[f32],
    refine: &[u8],
    pens: &[f64],
    bisect_mm: f64,
    om_max: f64,
    merge_mm: f64,
    bounces: &[f64],
) -> Result<(Vec<u8>, i64), String> {
    if pens.is_empty() {
        return Err("no coarse pens".into());
    }
    let own = [ref_spec.auto_bounce];
    let bounces = if bounces.is_empty() { &own[..] } else { bounces };
    if bounces.len() > 255 {
        return Err("too many bounce classes".into());
    }
    let (ng, ny_u) = ((nx.max(0) * ny.max(0)) as usize, ny.max(0) as usize);
    let ref_in = if refine.is_empty() {
        Refine { kx: 1, ky: vec![1; ny_u], ..Default::default() }
    } else {
        let Some((r, len)) = parse_refine(refine, 0, nx.max(0) as usize, ny_u) else {
            return Err("malformed refine section".into());
        };
        if len != refine.len() {
            return Err(format!("refine section {} bytes, parsed {len}", refine.len()));
        }
        r
    };
    let n_sub = ref_in.n_sub;
    if pts.len() != ng + n_sub {
        return Err(format!("{} points for {ng} cells + {n_sub} sub-cells", pts.len()));
    }
    let dir = dir.normalized();
    let mut base = *ref_spec;
    base.overmatch = 0.0;
    base.is_he = false;
    base.auto_bounce = bounces[0];
    base.k_nose = K_NOSE_APC;
    let base_pen = NativeArmorInteraction::calculate_de_marre_penetration(base.mass, v_ref, base.caliber).max(1e-6);
    let mut spec_mid = base;
    spec_mid.pen_mod = pens[pens.len() / 2] / base_pen;

    let classified: Vec<(u8, String, f32, u8)> = pts
        .iter()
        .map(|&p| {
            let (code, first_part, steps, water) = walk_cell(mesh, aabb, &spec_mid, p, dir, v_ref, true);
            if code == CELL_MISS {
                return (code, String::from("miss"), -1.0, 0);
            }
            let mut sig = String::new();
            for st in &steps {
                sig.push_str(&format!("{}|{:.0}|{:.2}|{};", st.part, st.armor_mm, st.impact_angle, st.is_citadel));
            }
            // Water is part of the identity: a cell that arrived through the
            // surface must not share a profile (and its HE verdict) with a
            // dry one that happened to meet the same plates.
            sig.push_str(&format!("={}{}", code, if water { "~w" } else { "" }));
            let first_mm = steps.first().map(|s| s.armor_mm as f32).unwrap_or(-1.0);
            let mut flags = (mesh.armor_type(first_part).clamp(0, SECTION_MAX) as u8) << CELL_SECTION_SHIFT;
            if mesh.is_citadel(first_part) {
                flags |= FLAG_CITADEL;
            }
            if mesh.is_dynamic(first_part) {
                flags |= FLAG_TURRET;
            }
            if water {
                flags |= FLAG_WATER;
            }
            (code, sig, first_mm, flags)
        })
        .collect();

    struct Profile {
        rep: usize,
        first_mm: f32,
        flags: u8,
    }
    let mut profiles: Vec<Profile> = Vec::new();
    let mut sig_index: BTreeMap<String, usize> = BTreeMap::new();
    let mut cell_idx: Vec<usize> = vec![0; pts.len()];
    for (i, (_, sig, first_mm, flags)) in classified.iter().enumerate() {
        cell_idx[i] = *sig_index.entry(sig.clone()).or_insert_with(|| {
            profiles.push(Profile { rep: i, first_mm: *first_mm, flags: *flags });
            profiles.len() - 1
        });
    }
    // Per profile, per bounce class: (base, overmatched) breakpoints.
    type Lists = (Vec<(f32, u8)>, Vec<(f32, u8)>);
    let mut walks: i64 = pts.len() as i64;
    let sweeps: Vec<Vec<Lists>> = profiles
        .iter()
        .map(|prof| {
            if prof.first_mm < 0.0 {
                return vec![(vec![(0.0, CELL_MISS)], Vec::new()); bounces.len()];
            }
            let p = pts[prof.rep];
            bounces
                .iter()
                .map(|&bo| {
                    let (bps, w1) = sweep(mesh, aabb, &base, base_pen, p, dir, v_ref, &pens, bisect_mm, 0.0, bo);
                    let (bps_om, w2) = if prof.first_mm as f64 <= om_max {
                        sweep(mesh, aabb, &base, base_pen, p, dir, v_ref, &pens, bisect_mm, prof.first_mm as f64, bo)
                    } else {
                        (Vec::new(), 0)
                    };
                    walks += (w1 + w2) as i64;
                    (bps, bps_om)
                })
                .collect()
        })
        .collect();
    if v_edges.len() != ny.max(0) as usize + 1 {
        return Err(format!("{} v_edges for ny={ny}", v_edges.len()));
    }
    let enc = |buf: &mut Vec<u8>, bps: &[(f32, u8)]| -> u8 {
        let n = bps.len().min(BP_MAX);
        for (mm, code) in &bps[..n] {
            // 1 mm quantisation, under the bake's own BISECT_MM.
            buf.extend_from_slice(&(mm.round().clamp(0.0, 65535.0) as u16).to_le_bytes());
            buf.push(*code);
        }
        n as u8
    };
    // Profiles with the same results in the same order, breakpoints within `merge_mm`, are one:
    // neighbouring rays differ in plate angle and sweep to thresholds a few mm apart.
    // One bounce class's lists, encoded: (cnt, cnt_om, base runs, om runs).
    #[derive(PartialEq)]
    struct Cls {
        cnt: u8,
        cnt_om: u8,
        bps: Vec<u8>,
        bps_om: Vec<u8>,
    }
    struct Enc {
        mm: u16,
        flags: u8,
        cls: Vec<Cls>,
    }
    let mut kept: Vec<Enc> = Vec::new();
    let mut by_key: BTreeMap<Vec<u8>, Vec<usize>> = BTreeMap::new();
    let thresholds = |e: &Enc| -> Vec<u16> {
        e.cls.iter().flat_map(|c| c.bps.chunks(3).chain(c.bps_om.chunks(3)))
            .map(|c| u16::from_le_bytes([c[0], c[1]])).collect()
    };
    let mut remap: Vec<usize> = Vec::with_capacity(profiles.len());
    for (prof, lists) in profiles.iter().zip(sweeps.iter()) {
        let mm = if prof.first_mm < 0.0 { MM_MISS } else { (prof.first_mm.round().clamp(0.0, 65534.0)) as u16 };
        let cls: Vec<Cls> = lists.iter().map(|(bps, bps_om)| {
            let mut c = Cls { cnt: 0, cnt_om: 0, bps: Vec::new(), bps_om: Vec::new() };
            c.cnt = enc(&mut c.bps, bps);
            c.cnt_om = enc(&mut c.bps_om, bps_om);
            c
        }).collect();
        let e = Enc { mm, flags: prof.flags, cls };
        let mut key = mm.to_le_bytes().to_vec();
        key.push(e.flags);
        for c in &e.cls {
            key.extend_from_slice(&[c.cnt, c.cnt_om]);
            key.extend(c.bps.chunks(3).chain(c.bps_om.chunks(3)).map(|x| x[2]));
        }
        let t = thresholds(&e);
        let reps = by_key.entry(key).or_default();
        let near = reps.iter().copied().find(|&r| {
            thresholds(&kept[r]).iter().zip(&t).all(|(a, b)| (*a as f64 - *b as f64).abs() <= merge_mm)
        });
        let i = near.unwrap_or_else(|| {
            kept.push(e);
            reps.push(kept.len() - 1);
            kept.len() - 1
        });
        remap.push(i);
    }
    let idx: Vec<usize> = cell_idx.iter().map(|&i| remap[i]).collect();

    // A split cell whose sub-cells all resolve alike is unsplit, taking their profile.
    let nxu = nx.max(0) as usize;
    let mut idx = idx;
    let mut cells_kept: Vec<usize> = Vec::new();
    let mut subs: Vec<usize> = Vec::new();
    let mut at = ng;
    for &c in &ref_in.cells {
        let n = ref_in.kx * ref_in.ky[c / nxu];
        let run = idx[at..at + n].to_vec();
        if run.iter().all(|&i| i == run[0]) {
            idx[c] = run[0];
        } else {
            cells_kept.push(c);
            subs.extend_from_slice(&run);
        }
        at += n;
    }
    let mut refine_out = (cells_kept.len() as u16).to_le_bytes().to_vec();
    refine_out.push(ref_in.kx as u8);
    refine_out.extend(ref_in.ky.iter().map(|&k| k as u8));
    for &c in &cells_kept {
        refine_out.extend_from_slice(&(c as u16).to_le_bytes());
    }
    refine_out.push(ref_in.anchors.len() as u8);
    for a in &ref_in.anchors {
        refine_out.extend_from_slice(&a.0.to_le_bytes());
        refine_out.extend_from_slice(&a.1.to_le_bytes());
    }

    let np = kept.len();
    if np > u16::MAX as usize {
        return Err(format!("{np} profiles in one bucket"));
    }
    // A byte per cell unless this bucket needs more: bow-on rays run the
    // hull's length and nearly every one is its own profile.
    let put = |out: &mut Vec<u8>, i: usize| {
        if np > 255 { out.extend_from_slice(&(i as u16).to_le_bytes()) } else { out.push(i as u8) }
    };
    let mut blob: Vec<u8> = Vec::with_capacity(BLOB_HDR + 4 * v_edges.len() + 2 * (ng + subs.len()) + refine_out.len() + 5 * np);
    blob.push(nx.clamp(0, 255) as u8);
    blob.push(ny.clamp(0, 255) as u8);
    blob.extend_from_slice(&(np as u16).to_le_bytes());
    for v in [rect.x, rect.y, rect.z, rect.w, dir.x, dir.y, dir.z] {
        blob.extend_from_slice(&v.to_le_bytes());
    }
    for e in v_edges {
        blob.extend_from_slice(&e.to_le_bytes());
    }
    for &i in &idx[..ng] {
        put(&mut blob, i);
    }
    blob.extend_from_slice(&refine_out);
    for &i in &subs {
        put(&mut blob, i);
    }
    for e in &kept {
        blob.extend_from_slice(&e.mm.to_le_bytes());
    }
    blob.extend(kept.iter().map(|e| e.flags));
    blob.extend(kept.iter().map(|e| e.cls[0].cnt));
    blob.extend(kept.iter().map(|e| e.cls[0].cnt_om));
    for e in &kept {
        blob.extend_from_slice(&e.cls[0].bps);
    }
    for e in &kept {
        blob.extend_from_slice(&e.cls[0].bps_om);
    }
    blob.push(bounces.len() as u8);
    for &bo in bounces {
        blob.extend_from_slice(&(bo as f32).to_le_bytes());
    }
    for k in 1..bounces.len() {
        let over: Vec<usize> = (0..np).filter(|&i| kept[i].cls[k] != kept[i].cls[k - 1]).collect();
        blob.extend_from_slice(&(over.len() as u16).to_le_bytes());
        for &i in &over {
            blob.extend_from_slice(&(i as u16).to_le_bytes());
            blob.extend_from_slice(&[kept[i].cls[k].cnt, kept[i].cls[k].cnt_om]);
        }
        for &i in &over {
            blob.extend_from_slice(&kept[i].cls[k].bps);
        }
        for &i in &over {
            blob.extend_from_slice(&kept[i].cls[k].bps_om);
        }
    }
    Ok((blob, walks))
}

/// Result byte per cell for a shell with penetration `pen` (mm) and
/// `overmatch` (mm). HE resolves off the first plate alone, as the walk does.
/// AP reads the swept breakpoints, from the overmatched sweep when the shell
/// overmatches the first plate.
pub(crate) fn resolve_codes(b: &[u8], pen: f64, overmatch: f64, is_he: bool, bounce: f64) -> Option<Vec<u8>> {
    let h = blob_header(b)?;
    let (np, ncell) = (h.np, h.n_codes());
    let mut out = vec![CELL_MISS; ncell];
    if np == 0 {
        return Some(out);
    }
    let a = h.prof;
    let (fm_o, fl_o, cnt_o, cnt_om_o) = (a, a + 2 * np, a + 3 * np, a + 4 * np);
    // Per profile: (base run offset, count, om run offset, count), class 0 then each class's overrides.
    let mut runs: Vec<(usize, usize, usize, usize)> = Vec::with_capacity(np);
    let mut off = a + 5 * np;
    for pi in 0..np {
        let n = b[cnt_o + pi] as usize;
        runs.push((off, n, 0, b[cnt_om_o + pi] as usize));
        off += 3 * n;
    }
    for r in runs.iter_mut() {
        r.2 = off;
        off += 3 * r.3;
    }
    if !is_he {
        for (k, (start, n_over)) in bounce_overrides(b, off, np)?.into_iter().enumerate() {
            if bounce_angle(b, off, k + 1)? as f64 > bounce + 1e-4 {
                break;
            }
            let mut o = start + 4 * n_over;
            let mut entries = Vec::with_capacity(n_over);
            for e in 0..n_over {
                let q = start + 4 * e;
                entries.push((rd_u16(b, q) as usize, b[q + 2] as usize, b[q + 3] as usize));
            }
            for &(pi, n, _) in &entries {
                runs[pi].0 = o;
                runs[pi].1 = n;
                o += 3 * n;
            }
            for &(pi, _, n_om) in &entries {
                runs[pi].2 = o;
                runs[pi].3 = n_om;
                o += 3 * n_om;
            }
        }
    }

    let mut codes: Vec<u8> = Vec::with_capacity(np);
    for pi in 0..np {
        let raw = rd_u16(b, fm_o + 2 * pi);
        let (a_bp, n, a_om, n_om) = runs[pi];
        if raw == MM_MISS {
            codes.push(CELL_MISS);
            continue;
        }
        let fm = raw as f64;
        let flags = b[fl_o + pi];
        let turret = if flags & FLAG_TURRET != 0 { CELL_TURRET } else { 0 };
        // HE resolves against the first plate alone, so its section is that
        // plate's; an AP breakpoint already carries the section it ends in.
        let section = flags & CELL_SECTION_MASK;
        if is_he {
            if flags & FLAG_WATER != 0 {
                codes.push(CELL_MISS);
                continue;
            }
            let c = if overmatch >= fm {
                if flags & FLAG_CITADEL != 0 { hit_result::CITADEL } else { hit_result::PENETRATION }
            } else {
                hit_result::SHATTER
            };
            codes.push((c as u8) | turret | section);
            continue;
        }
        let om = overmatch >= fm && n_om > 0;
        let (start, count) = if om { (a_om, n_om) } else { (a_bp, n) };
        if count == 0 || start + 3 * count > b.len() {
            codes.push(CELL_MISS);
            continue;
        }
        let mut code = b[start + 2];
        for k in 0..count {
            let e = start + 3 * k;
            if rd_u16(b, e) as f64 <= pen {
                code = b[e + 2];
            } else {
                break;
            }
        }
        codes.push(code);
    }
    for (i, o) in out.iter_mut().enumerate() {
        let pi = h.cell(b, i);
        if pi < np {
            *o = codes[pi];
        }
    }
    Some(out)
}

/// Offset of the bounce section: after class 0's om runs.
pub(crate) fn bounce_section(b: &[u8]) -> Option<usize> {
    let h = blob_header(b)?;
    let np = h.np;
    let a = h.prof;
    let total: usize = b[a + 3 * np..a + 4 * np].iter().map(|&c| c as usize).sum();
    let total_om: usize = b[a + 4 * np..a + 5 * np].iter().map(|&c| c as usize).sum();
    let d = a + 5 * np + 3 * (total + total_om);
    (b.len() > d).then_some(d)
}

fn bounce_angle(b: &[u8], d: usize, k: usize) -> Option<f32> {
    let o = d + 1 + 4 * k;
    (k < *b.get(d)? as usize && b.len() >= o + 4).then(|| rd_f32(b, o))
}

/// (start, override count) of each class from 1, the section at `d`.
pub(crate) fn bounce_overrides(b: &[u8], d: usize, np: usize) -> Option<Vec<(usize, usize)>> {
    let n_cls = *b.get(d)? as usize;
    let mut o = d + 1 + 4 * n_cls;
    let mut out = Vec::with_capacity(n_cls.saturating_sub(1));
    for _ in 1..n_cls {
        if b.len() < o + 2 {
            return None;
        }
        let n = rd_u16(b, o) as usize;
        let start = o + 2;
        let mut runs = 0;
        for e in 0..n {
            let q = start + 4 * e;
            if b.len() < q + 4 || rd_u16(b, q) as usize >= np {
                return None;
            }
            runs += b[q + 2] as usize + b[q + 3] as usize;
        }
        out.push((start, n));
        o = start + 4 * n + 3 * runs;
    }
    Some(out)
}

/// Auto-bounce angle of each class and how many profiles it overrides.
pub(crate) fn bounce_classes(b: &[u8]) -> Vec<(f32, usize)> {
    let Some(h) = blob_header(b) else { return Vec::new() };
    let Some(d) = bounce_section(b) else { return Vec::new() };
    let Some(over) = bounce_overrides(b, d, h.np) else { return Vec::new() };
    let n_cls = b[d] as usize;
    (0..n_cls).map(|k| (bounce_angle(b, d, k).unwrap_or(0.0), if k == 0 { 0 } else { over[k - 1].1 })).collect()
}

impl ProjectileManager {
    /// The penetration the armour walk credits `shell` with at `velocity`:
    /// De Marre times `penetration_modifier`. Not `calculate_penetration_power`,
    /// which is a different formula the walk does not use.
    pub(crate) fn walk_penetration_impl(shell: &Gd<Resource>, velocity: f64) -> f64 {
        NativeArmorInteraction::calculate_de_marre_penetration(
            shell.get("mass").to_f64(), velocity, shell.get("caliber").to_f64(),
        ) * shell.get("penetration_modifier").to_f64()
    }

    /// Validation walk: one real shell of `shell` at each point, fired from
    /// `from` with the real ballistics through the live path. One result byte
    /// per point.
    pub(crate) fn survey_walk_impl(
        &mut self,
        target: Gd<Node3D>,
        owner: Gd<Object>,
        shell: Gd<Resource>,
        from: Vector3,
        points: PackedVector3Array,
        space_state: Option<Gd<PhysicsDirectSpaceState3D>>,
    ) -> PackedByteArray {
        let n = points.len();
        let mut out = PackedByteArray::new();
        out.resize(n);
        out.fill(CELL_MISS);
        let Some(mut space) = space_state else { return out };
        self.ensure_armor_autoloads();
        let ppw = self.precision_physics_world.clone();
        let nav_map = self.navigation_map.clone();
        let xf = target.get_global_transform();
        let basis_inv = xf.basis.inverse();
        let aabb: Aabb = target.get("aabb").try_to::<Aabb>().unwrap_or_default();
        let target_id = target.instance_id().to_i64();
        let target_obj = target.clone().upcast::<Object>();
        let mut proj = ProjectileData::new_gd();
        for i in 0..n {
            let p = points[i];
            let to = xf * p;
            let launch = ProjectilePhysicsWithDragV2::calculate_launch_vector_impl(from, to, &shell);
            let v0 = launch.at(0);
            if v0.is_nil() {
                continue;
            }
            let vel: Vector3 = v0.try_to::<Vector3>().unwrap_or_default();
            if vel == Vector3::ZERO {
                continue;
            }
            let tof = launch.at(1).to_f64();
            let impact = ProjectilePhysicsWithDragV2::calculate_velocity_at_time_impl(vel, tof, &shell);
            let dir = impact.normalized();
            let ld = (basis_inv * dir).normalized();
            let (entry, exit) = walk_span(aabb, p, ld);
            let mut prev = to - dir * entry;
            // Start above the surface: the survey space carries the water
            // plane, so process_travel simulates the crossing as a fired shell.
            if prev.y <= 1.0 && dir.y < 0.0 {
                prev -= dir * ((1.5 - prev.y) / -dir.y);
            }
            {
                let mut pd = proj.bind_mut();
                pd.initialize(to + dir * exit, vel, 0.0, shell.clone(), Some(owner.clone()), VarArray::new());
                pd.frame_count = 1;
            }
            let rays = armor_rays_for(&mut self.armor_ray_cache, ppw.as_ref(), &proj);
            let res = NativeArmorInteraction::process_travel(
                &proj, prev, tof, Some(&mut space), ppw.as_ref(), &mut self.armor, &nav_map, rays, false,
            );
            if !res.hit {
                continue;
            }
            match &res.ship {
                Some(s) if *s == target_obj => {}
                _ => continue,
            }
            // A shell the water took (HE at the surface) is not a hit to score.
            if res.result_type == hit_result::WATER {
                continue;
            }
            let mut code = (res.result_type.clamp(0, 15) as u8) & CELL_CODE_MASK;
            let (turret, section) = res.armor_part.as_ref().and_then(|part| {
                let sa = self.armor.get(target_id)?;
                let idx = sa.parts.iter().position(|p| p == part)?;
                Some((sa.mesh.is_dynamic(idx), sa.mesh.armor_type(idx)))
            }).unwrap_or((false, 0));
            if turret {
                code |= CELL_TURRET;
            }
            code |= (section.clamp(0, SECTION_MAX) as u8) << CELL_SECTION_SHIFT;
            out[i] = code;
        }
        out
    }

    /// Every (hull, bucket) lattice in one call, flattened: job `j` is hull
    /// `job_hull[j]`, its points `points[pt_off[j]..pt_off[j+1]]` and row edges
    /// `edges[edge_off[j]..edge_off[j+1]]`. `opts`: coarse_pens, bisect_mm, om_max,
    /// threads (0 = all), smt. Returns a blob and walk count per job.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn survey_bake_impl(
        &mut self,
        hulls: Array<Gd<Node3D>>,
        ref_shell: Gd<Resource>,
        job_hull: PackedInt32Array,
        job_dir: PackedVector3Array,
        job_vref: PackedFloat32Array,
        job_nxny: PackedInt32Array,
        job_rect: PackedVector4Array,
        points: PackedVector3Array,
        pt_off: PackedInt32Array,
        edges: PackedFloat32Array,
        edge_off: PackedInt32Array,
        opts: VarDictionary,
    ) -> VarDictionary {
        let mut out = VarDictionary::new();
        let opt = |k: &str| opts.get(k).unwrap_or_default();
        let coarse_pens: PackedFloat32Array = opt("coarse_pens").try_to().unwrap_or_default();
        let (bisect_mm, om_max) = (opt("bisect_mm").to_f64(), opt("om_max").to_f64());
        let merge_mm = opts.get("merge_mm").map_or(0.0, |v| v.to_f64());
        let bounces: Vec<f64> = opt("bounce_classes").try_to::<PackedFloat32Array>()
            .map(|a| a.as_slice().iter().map(|&x| x as f64).collect()).unwrap_or_default();
        let (threads, smt) = (opt("threads").to_i32(), opts.get("smt").is_none_or(|v| v.to_bool()));
        let n = job_hull.len();
        if job_dir.len() != n || job_vref.len() != n || job_nxny.len() != 2 * n || job_rect.len() != n
            || pt_off.len() != n + 1 || edge_off.len() != n + 1 {
            godot_error!("survey_bake: job arrays disagree on length");
            return out;
        }
        let ids: Vec<i64> = hulls.iter_shared().map(|h| h.instance_id().to_i64()).collect();
        let aabbs: Vec<Aabb> = hulls.iter_shared().map(|h| h.get("aabb").try_to::<Aabb>().unwrap_or_default()).collect();
        for &id in &ids {
            self.armor_sync(id);
        }
        let meshes: Vec<Option<&ArmorMesh>> = ids.iter().map(|&id| self.armor.get(id).map(|sa| &sa.mesh)).collect();
        let spec = ShellSpec::from_params(&ref_shell);
        let pens: Vec<f64> = coarse_pens.as_slice().iter().map(|&p| p as f64).collect();
        let (hull_of, pts, eds, po, eo) =
            (job_hull.as_slice(), points.as_slice(), edges.as_slice(), pt_off.as_slice(), edge_off.as_slice());
        let (dirs, vrefs, nxny, rects) = (job_dir.as_slice(), job_vref.as_slice(), job_nxny.as_slice(), job_rect.as_slice());

        let nodes = crate::sched::cpu_order(smt).iter().map(|c| c.node).max().map_or(1, |m| m + 1);
        // A copy of each mesh per NUMA node, cloned by the first worker there so
        // its pages are allocated locally.
        let copies: Vec<Vec<std::sync::OnceLock<ArmorMesh>>> =
            meshes.iter().map(|_| (0..nodes).map(|_| std::sync::OnceLock::new()).collect()).collect();
        let costs: Vec<f64> = (0..n).map(|j| (po[j + 1] - po[j]).max(0) as f64).collect();
        let ev_payouts: PackedFloat64Array = opt("ev_payouts").try_to().unwrap_or_default();
        let ellipse: Vector2 = opt("ev_ellipse").try_to().unwrap_or(Vector2::new(0.4, 0.1));
        let ev_jobs: PackedByteArray = opt("ev_jobs").try_to().unwrap_or_default();
        let ev_jobs = ev_jobs.as_slice();
        let refines: Vec<Vec<u8>> = opt("job_refine").try_to::<VarArray>().map(|a| {
            a.iter_shared().map(|v| v.try_to::<PackedByteArray>().map(|p| p.to_vec()).unwrap_or_default()).collect()
        }).unwrap_or_default();
        let kernel = (!ev_payouts.is_empty()).then(|| super::ev::EvKernel {
            guarantee: opt("ev_guarantee").to_f64(),
            ellipse: (ellipse.x as f64, ellipse.y as f64),
            payouts: ev_payouts.as_slice().to_vec(),
            turret_cap: opt("ev_turret_cap").to_f64(),
            om_max,
            levels: opt("ev_levels").try_to::<PackedByteArray>().map(|l| l.to_vec()).unwrap_or_default(),
            bounces: bounces.clone(),
        });

        let (results, stats) = crate::sched::run_balanced(&costs, threads.max(0) as usize, smt, |j, w| {
            let h = hull_of[j] as usize;
            let Some(src) = meshes.get(h).copied().flatten() else {
                return Err(format!("hull {h} has no armour"));
            };
            let mesh = copies[h][w.node.min(nodes - 1)].get_or_init(|| src.clone());
            let (blob, walks) = sweep_bucket(
                mesh, aabbs[h], &spec, dirs[j], vrefs[j] as f64,
                &pts[po[j] as usize..po[j + 1] as usize],
                nxny[2 * j], nxny[2 * j + 1], rects[j],
                &eds[eo[j] as usize..eo[j + 1] as usize],
                refines.get(j).map_or(&[][..], |r| r.as_slice()),
                &pens, bisect_mm, om_max, merge_mm, &bounces,
            )?;
            let ev = match &kernel {
                Some(k) if ev_jobs.get(j).is_some_and(|&f| f != 0) => super::ev::ev_bucket(&blob, k),
                _ => Vec::new(),
            };
            Ok((blob, ev, walks))
        });

        let mut blobs = VarArray::new();
        let mut evs = VarArray::new();
        let mut walks = PackedInt64Array::new();
        let mut errors = 0;
        for (j, r) in results.into_iter().enumerate() {
            match r {
                Ok((blob, ev, w)) => {
                    blobs.push(&PackedByteArray::from(blob.as_slice()).to_variant());
                    evs.push(&PackedByteArray::from(ev.as_slice()).to_variant());
                    walks.push(w);
                }
                Err(e) => {
                    if errors < 8 {
                        godot_error!("survey_bake: job {j}: {e}");
                    }
                    errors += 1;
                    blobs.push(&Variant::nil());
                    evs.push(&Variant::nil());
                    walks.push(0);
                }
            }
        }
        let busy = &stats.busy_ms;
        let mean = busy.iter().sum::<f64>() / busy.len().max(1) as f64;
        let mut st = VarDictionary::new();
        st.set("threads", stats.threads as i64);
        st.set("nodes", stats.nodes as i64);
        st.set("wall_ms", stats.wall_ms);
        st.set("busy_min_ms", busy.iter().cloned().fold(f64::INFINITY, f64::min));
        st.set("busy_mean_ms", mean);
        st.set("busy_max_ms", busy.iter().cloned().fold(0.0, f64::max));
        st.set("items_max", stats.items.iter().copied().max().unwrap_or(0) as i64);
        st.set("steals", stats.steals as i64);
        st.set("cross_node_steals", stats.cross_node_steals as i64);
        out.set("blobs", &blobs);
        out.set("evs", &evs);
        out.set("walks", &walks);
        out.set("errors", errors as i64);
        out.set("stats", &st);
        out
    }

    pub(crate) fn lattice_resolve_impl(
        blob: &PackedByteArray, pen: f64, overmatch: f64, is_he: bool, bounce: f64,
    ) -> PackedByteArray {
        resolve_codes(blob.as_slice(), pen, overmatch, is_he, bounce).map_or_else(PackedByteArray::new, |c| PackedByteArray::from(c.as_slice()))
    }

    /// Expected payout and arrival rate of one shell aimed at each of `aims`
    /// (lattice-plane coordinates), integrating `cells` under the gun's
    /// truncated-Gaussian kernel. `blob`, when given, supplies the split cells
    /// `cells` carries past the grid. Returns [value, landed] per aim; value is in
    /// payout-multiplier units, -1 where no walked cell carries any mass.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn lattice_score_impl(
        cells: &PackedByteArray,
        nx: i32,
        ny: i32,
        rect: Vector4,
        v_edges: &PackedFloat32Array,
        aims: &PackedVector2Array,
        half_disp: Vector2,
        sigma: f64,
        guarantee: f64,
        ellipse: Vector2,
        payouts: &PackedFloat64Array,
        turret_cap: f64,
        blob: &PackedByteArray,
    ) -> PackedFloat64Array {
        let na = aims.len();
        let mut out = PackedFloat64Array::new();
        out.resize(na * 2);
        let (nx, ny) = (nx.max(0) as usize, ny.max(0) as usize);
        let hdr = if blob.is_empty() { None } else { blob_header(blob.as_slice()) };
        let (u0, v0, u1, v1) = (rect.x as f64, rect.y as f64, rect.z as f64, rect.w as f64);
        let ve: Vec<f64> = if v_edges.len() == ny + 1 {
            (0..=ny).map(|i| v_edges[i] as f64).collect()
        } else {
            let dv = (v1 - v0) / ny.max(1) as f64;
            (0..=ny).map(|i| v0 + dv * i as f64).collect()
        };
        let leaves = Leaves::new(nx, ny, u0, u1, &ve, hdr.as_ref().map(|h| &h.refine));
        let cells = cells.as_slice();
        if nx == 0 || ny == 0 || cells.len() < leaves.n_codes {
            out.fill(-1.0);
            return out;
        }
        let s = sigma.max(0.01);
        let erf_bound = erf(s / std::f64::consts::SQRT_2);
        let ea = (ellipse.x as f64).max(0.01);
        let eb = (ellipse.y as f64).max(0.01) * 0.785;
        let guar_h = |x: f64| ((x + ea) / (2.0 * ea)).clamp(0.0, 1.0);
        let guar_v = |y: f64| 0.5 + 0.5 * y.signum() * (y.abs() / eb).min(1.0).powf(1.0 / 1.6);
        let p_in_h = trunc_gauss_cdf(ea, s, erf_bound) - trunc_gauss_cdf(-ea, s, erf_bound);
        let p_in_v = trunc_gauss_cdf(eb, s, erf_bound) - trunc_gauss_cdf(-eb, s, erf_bound);
        let g = if guarantee > 0.0 { guarantee * (1.0 - p_in_h * p_in_v).powi(3) } else { 0.0 };

        // `payouts` is section-major, 16 result codes per section: what one
        // shell of this type is worth where it lands, already carrying the
        // target's damage saturation (see BotGunnery._payouts).
        let payout = |c: u8| -> f64 {
            let idx = (((c & CELL_SECTION_MASK) >> CELL_SECTION_SHIFT) as usize) * 16
                + (c & CELL_CODE_MASK) as usize;
            let mut v = if idx < payouts.len() { payouts[idx] } else { 0.0 };
            if c & CELL_TURRET != 0 {
                v = v.min(turret_cap);
            }
            v
        };
        let codes = &cells[..leaves.n_codes];
        let walked: Vec<f64> = codes.iter().map(|&c| if c == CELL_UNWALKED { 0.0 } else { 1.0 }).collect();
        let hit: Vec<f64> = codes.iter().map(|&c| if c == CELL_UNWALKED || c == CELL_MISS { 0.0 } else { 1.0 }).collect();
        let pay: Vec<f64> = codes.iter().map(|&c| if c == CELL_UNWALKED || c == CELL_MISS { 0.0 } else { payout(c) }).collect();
        let arrays = [&walked, &hit, &pay];

        // Aims share columns, so the across-row pass is made once per distinct u.
        struct UPass {
            sums: (f64, f64),
            r: [Vec<f64>; 6],
            s: [Vec<f64>; 6],
        }
        let mut by_u: std::collections::HashMap<u32, UPass> = std::collections::HashMap::new();
        for ai in 0..na {
            let aim = aims[ai];
            let up = by_u.entry(aim.x.to_bits()).or_insert_with(|| {
                let uw = leaves.u_weights(aim.x as f64, half_disp.x as f64, s, erf_bound, &guar_h);
                let mut r: [Vec<f64>; 6] = Default::default();
                let mut sb: [Vec<f64>; 6] = Default::default();
                for (k, p) in arrays.iter().enumerate() {
                    leaves.u_pass(&uw.w, &uw.wf, p, &mut r[2 * k], &mut sb[2 * k]);
                    if g > 0.0 {
                        leaves.u_pass(&uw.q, &uw.qf, p, &mut r[2 * k + 1], &mut sb[2 * k + 1]);
                    }
                }
                UPass { sums: uw.sums(), r, s: sb }
            });
            let vw = leaves.v_weights(aim.y as f64, half_disp.y as f64, s, erf_bound, &guar_v);
            let (sv, sq) = vw.sums();
            let in_mass = (1.0 - g) * up.sums.0 * sv + g * up.sums.1 * sq;
            let mut res = [0.0f64; 3];
            for (k, r) in res.iter_mut().enumerate() {
                let a = leaves.v_pass(&vw.w, &vw.wf, &up.r[2 * k], &up.s[2 * k]);
                let b = if g > 0.0 { leaves.v_pass(&vw.q, &vw.qf, &up.r[2 * k + 1], &up.s[2 * k + 1]) } else { 0.0 };
                *r = (1.0 - g) * a + g * b;
            }
            let [walked_mass, landed, val] = res;
            if walked_mass <= 0.0 {
                out[ai * 2] = -1.0;
                out[ai * 2 + 1] = -1.0;
            } else {
                let scale = in_mass / walked_mass;
                out[ai * 2] = val * scale;
                out[ai * 2 + 1] = landed * scale;
            }
        }
        out
    }
}
