use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Node3D, PhysicsDirectSpaceState3D, Resource};
use rayon::prelude::*;
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
///                  A=E+nx*ny*cw  u16[np] first_mm (MM_MISS = no hit)
///                    A+2np   u8[np]  first_flags
///                    A+3np   u8[np]  bp_cnt
///                    A+4np   u8[np]  bp_cnt_om
///                  B=A+5np   (u16 mm, u8 code)[sum bp_cnt]
///                  C=B+3*sum (u16 mm, u8 code)[sum bp_cnt_om]
/// ```
pub const BLOB_HDR: usize = 32;
pub const MM_MISS: u16 = 0xFFFF;
/// Breakpoint counts are u8; the sweep can emit at most `coarse + budget`.
const BP_MAX: usize = 255;

#[inline]
fn rd_u16(b: &[u8], off: usize) -> u16 {
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
    /// Byte offsets of the v_edges, cells and profile sections.
    pub edges: usize,
    pub cells: usize,
    /// Bytes per cell index: 1, or 2 once a bucket has more than 255 profiles.
    pub cw: usize,
    pub prof: usize,
}

impl BlobHdr {
    pub fn cell(&self, b: &[u8], i: usize) -> usize {
        if self.cw == 2 { rd_u16(b, self.cells + 2 * i) as usize } else { b[self.cells + i] as usize }
    }
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
    let prof = cells + nx * ny * cw;
    if b.len() < prof + 5 * np {
        return None;
    }
    Some(BlobHdr { nx, ny, np, rect, dir, edges, cells, cw, prof })
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

fn erf(x: f64) -> f64 {
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
fn trunc_gauss_cdf(x: f64, s: f64, erf_bound: f64) -> f64 {
    if x <= -1.0 {
        return 0.0;
    }
    if x >= 1.0 {
        return 1.0;
    }
    0.5 + 0.5 * erf(x * s / std::f64::consts::SQRT_2) / erf_bound
}

/// Kernel mass per cell along one axis, cells bounded by `edges` (n+1 of them).
fn axis_weights(
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
    speed: f64, pens: &[f64], bisect_mm: f64, overmatch: f64,
) -> (Vec<(f32, u8)>, u64) {
    let mut walks: u64 = 0;
    let at = |pen: f64, walks: &mut u64| -> u8 {
        let mut s = *base;
        s.pen_mod = pen / base_pen;
        s.overmatch = overmatch;
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

    /// Bake one lattice: parallel rays along ship-local `dir` at `v_ref`,
    /// walked on worker threads against the target's armour mesh. Cells are
    /// grouped into profiles by the plates they meet, and each profile is
    /// swept in penetration to find where the result changes, once with
    /// overmatch off and once with the first plate overmatched when any fleet
    /// shell could.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn survey_sweep_impl(
        &mut self,
        target: Gd<Node3D>,
        ref_shell: Gd<Resource>,
        dir: Vector3,
        v_ref: f64,
        points: PackedVector3Array,
        nx: i32,
        ny: i32,
        rect: Vector4,
        v_edges: PackedFloat32Array,
        coarse_pens: PackedFloat32Array,
        bisect_mm: f64,
        om_max: f64,
    ) -> VarDictionary {
        let mut out = VarDictionary::new();
        if coarse_pens.is_empty() {
            return out;
        }
        let id = target.instance_id().to_i64();
        self.armor_sync(id);
        let Some(sa) = self.armor.get(id) else { return out };
        let mesh = &sa.mesh;
        let aabb: Aabb = target.get("aabb").try_to::<Aabb>().unwrap_or_default();
        let dir = dir.normalized();

        let mut base = ShellSpec::from_params(&ref_shell);
        base.overmatch = 0.0;
        base.is_he = false;
        base.k_nose = K_NOSE_APC;
        let base_pen = NativeArmorInteraction::calculate_de_marre_penetration(base.mass, v_ref, base.caliber).max(1e-6);
        let pts: Vec<Vector3> = (0..points.len()).map(|i| points[i]).collect();
        let pens: Vec<f64> = (0..coarse_pens.len()).map(|k| coarse_pens[k] as f64).collect();
        let mut spec_mid = base;
        spec_mid.pen_mod = pens[pens.len() / 2] / base_pen;

        let classified: Vec<(u8, String, f32, u8)> = pts
            .par_iter()
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
        // A byte per cell unless this bucket needs more: bow-on rays run the
        // hull's length and nearly every one is its own profile.
        let cells: Vec<u8> = if profiles.len() > 255 {
            cell_idx.iter().flat_map(|&i| (i as u16).to_le_bytes()).collect()
        } else {
            cell_idx.iter().map(|&i| i as u8).collect()
        };

        let sweeps: Vec<(Vec<(f32, u8)>, Vec<(f32, u8)>, u64)> = profiles
            .par_iter()
            .map(|prof| {
                if prof.first_mm < 0.0 {
                    return (vec![(0.0, CELL_MISS)], Vec::new(), 0);
                }
                let p = pts[prof.rep];
                let (bps, w1) = sweep(mesh, aabb, &base, base_pen, p, dir, v_ref, &pens, bisect_mm, 0.0);
                let (bps_om, w2) = if prof.first_mm as f64 <= om_max {
                    sweep(mesh, aabb, &base, base_pen, p, dir, v_ref, &pens, bisect_mm, prof.first_mm as f64)
                } else {
                    (Vec::new(), 0)
                };
                (bps, bps_om, w1 + w2)
            })
            .collect();

        let mut walks: i64 = pts.len() as i64;
        let np = profiles.len();
        if np > u16::MAX as usize {
            godot_error!("survey_sweep: {} profiles in one bucket", np);
            return out;
        }
        if v_edges.len() != ny.max(0) as usize + 1 {
            godot_error!("survey_sweep: {} v_edges for ny={}", v_edges.len(), ny);
            return out;
        }
        let mut fm: Vec<u8> = Vec::with_capacity(2 * np);
        let mut flags: Vec<u8> = Vec::with_capacity(np);
        let mut cnt: Vec<u8> = Vec::with_capacity(np);
        let mut cnt_om: Vec<u8> = Vec::with_capacity(np);
        let mut bps_buf: Vec<u8> = Vec::new();
        let mut bps_om_buf: Vec<u8> = Vec::new();
        let enc = |buf: &mut Vec<u8>, bps: &[(f32, u8)]| -> u8 {
            let n = bps.len().min(BP_MAX);
            for (mm, code) in &bps[..n] {
                // 1 mm quantisation, under the bake's own BISECT_MM.
                buf.extend_from_slice(&(mm.round().clamp(0.0, 65535.0) as u16).to_le_bytes());
                buf.push(*code);
            }
            n as u8
        };
        for (prof, (bps, bps_om, w)) in profiles.iter().zip(sweeps.iter()) {
            walks += *w as i64;
            let mm = if prof.first_mm < 0.0 {
                MM_MISS
            } else {
                (prof.first_mm.round().clamp(0.0, 65534.0)) as u16
            };
            fm.extend_from_slice(&mm.to_le_bytes());
            flags.push(prof.flags);
            cnt.push(enc(&mut bps_buf, bps));
            cnt_om.push(enc(&mut bps_om_buf, bps_om));
        }

        let mut blob: Vec<u8> = Vec::with_capacity(
            BLOB_HDR + 4 * v_edges.len() + cells.len() + 5 * np + bps_buf.len() + bps_om_buf.len());
        blob.push(nx.clamp(0, 255) as u8);
        blob.push(ny.clamp(0, 255) as u8);
        blob.extend_from_slice(&(np.min(u16::MAX as usize) as u16).to_le_bytes());
        for v in [rect.x, rect.y, rect.z, rect.w, dir.x, dir.y, dir.z] {
            blob.extend_from_slice(&v.to_le_bytes());
        }
        for i in 0..v_edges.len() {
            blob.extend_from_slice(&v_edges[i].to_le_bytes());
        }
        blob.extend_from_slice(&cells);
        blob.extend_from_slice(&fm);
        blob.extend_from_slice(&flags);
        blob.extend_from_slice(&cnt);
        blob.extend_from_slice(&cnt_om);
        blob.extend_from_slice(&bps_buf);
        blob.extend_from_slice(&bps_om_buf);

        out.set("blob", &PackedByteArray::from(blob.as_slice()));
        out.set("walks", walks);
        out
    }

    /// Result byte per cell for a shell with penetration `pen` (mm) and
    /// `overmatch` (mm). HE resolves off the first plate alone, as the walk does.
    /// AP reads the swept breakpoints, from the overmatched sweep when the shell
    /// overmatches the first plate.
    pub(crate) fn lattice_resolve_impl(
        blob: &PackedByteArray, pen: f64, overmatch: f64, is_he: bool,
    ) -> PackedByteArray {
        let b = blob.as_slice();
        let mut out = PackedByteArray::new();
        let Some(h) = blob_header(b) else { return out };
        let (np, ncell) = (h.np, h.nx * h.ny);
        out.resize(ncell);
        out.fill(CELL_MISS);
        if np == 0 {
            return out;
        }
        let a = h.prof;
        let (fm_o, fl_o, cnt_o, cnt_om_o) = (a, a + 2 * np, a + 3 * np, a + 4 * np);
        let bp_o = a + 5 * np;
        let total: usize = b[cnt_o..cnt_o + np].iter().map(|&c| c as usize).sum();
        let bp_om_o = bp_o + 3 * total;

        // Per-profile breakpoint runs are stored as counts, so the offsets are a
        // running sum taken alongside the resolve.
        let mut off = bp_o;
        let mut off_om = bp_om_o;
        let mut codes: Vec<u8> = Vec::with_capacity(np);
        for pi in 0..np {
            let raw = rd_u16(b, fm_o + 2 * pi);
            let n = b[cnt_o + pi] as usize;
            let n_om = b[cnt_om_o + pi] as usize;
            let (a_bp, a_om) = (off, off_om);
            off += 3 * n;
            off_om += 3 * n_om;
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
        for i in 0..ncell {
            let pi = h.cell(b, i);
            if pi < np {
                out[i] = codes[pi];
            }
        }
        out
    }

    /// Expected payout and arrival rate of one shell aimed at each of `aims`
    /// (lattice-plane coordinates), integrating `cells` under the gun's
    /// truncated-Gaussian kernel. Returns [value, landed] per aim; value is in
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
    ) -> PackedFloat64Array {
        let na = aims.len();
        let mut out = PackedFloat64Array::new();
        out.resize(na * 2);
        let (nx, ny) = (nx.max(0) as usize, ny.max(0) as usize);
        if nx == 0 || ny == 0 || cells.len() < nx * ny {
            out.fill(-1.0);
            return out;
        }
        let s = sigma.max(0.01);
        let erf_bound = erf(s / std::f64::consts::SQRT_2);
        let (u0, v0, u1, v1) = (rect.x as f64, rect.y as f64, rect.z as f64, rect.w as f64);
        let du = (u1 - u0) / nx as f64;
        let ue: Vec<f64> = (0..=nx).map(|i| u0 + du * i as f64).collect();
        let ve: Vec<f64> = if v_edges.len() == ny + 1 {
            (0..=ny).map(|i| v_edges[i] as f64).collect()
        } else {
            let dv = (v1 - v0) / ny as f64;
            (0..=ny).map(|i| v0 + dv * i as f64).collect()
        };
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

        for ai in 0..na {
            let aim = aims[ai];
            let (wh, qh) = axis_weights(&ue, aim.x as f64, half_disp.x as f64, s, erf_bound, &guar_h);
            let (wv, qv) = axis_weights(&ve, aim.y as f64, half_disp.y as f64, s, erf_bound, &guar_v);
            let mut in_mass = 0.0;
            let mut walked_mass = 0.0;
            let mut val = 0.0;
            let mut landed = 0.0;
            for iy in 0..ny {
                let row = iy * nx;
                for ix in 0..nx {
                    let w = (1.0 - g) * wh[ix] * wv[iy] + g * qh[ix] * qv[iy];
                    if w <= 0.0 {
                        continue;
                    }
                    in_mass += w;
                    let c = cells[row + ix];
                    if c == CELL_UNWALKED {
                        continue;
                    }
                    walked_mass += w;
                    if c == CELL_MISS {
                        continue;
                    }
                    landed += w;
                    val += w * payout(c);
                }
            }
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
