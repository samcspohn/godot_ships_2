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
use crate::projectile::armor::{hit_result, NativeArmorInteraction, K_NOSE_APC};
use crate::projectile::data::ProjectileData;

pub const CELL_MISS: u8 = 0xFF;
pub const CELL_UNWALKED: u8 = 0xFE;
pub const CELL_TURRET: u8 = 0x10;
pub const CELL_CODE_MASK: u8 = 0x0F;
pub const FLAG_CITADEL: u8 = 0x01;
pub const FLAG_TURRET: u8 = 0x02;

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

fn axis_weights(
    n: usize, lo: f64, step: f64, aim: f64, half_disp: f64, s: f64, erf_bound: f64,
    guar_cdf: &dyn Fn(f64) -> f64,
) -> (Vec<f64>, Vec<f64>) {
    let hd = half_disp.max(1e-3);
    let mut g = Vec::with_capacity(n);
    let mut q = Vec::with_capacity(n);
    let x0 = (lo - aim) / hd;
    let mut prev_g = trunc_gauss_cdf(x0, s, erf_bound);
    let mut prev_q = guar_cdf(x0);
    for i in 0..n {
        let x = (lo + step * (i as f64 + 1.0) - aim) / hd;
        let cg = trunc_gauss_cdf(x, s, erf_bound);
        let cq = guar_cdf(x);
        g.push(cg - prev_g);
        q.push(cq - prev_q);
        prev_g = cg;
        prev_q = cq;
    }
    (g, q)
}

/// One shell through plane point `p` (ship-local) arriving along `dir` at
/// `speed`, straddling the hull: (result byte, first part, plates met).
fn walk_cell(
    mesh: &ArmorMesh, aabb: Aabb, spec: &ShellSpec, p: Vector3, dir: Vector3, speed: f64, log: bool,
) -> (u8, usize, Vec<StepLog>) {
    let (entry, exit) = walk_span(aabb, p, dir);
    let prev = p - dir * entry;
    if prev.y <= 1.0 {
        return (CELL_MISS, 0, Vec::new());
    }
    let from = prev - dir * 10.0;
    let to = p + dir * exit;
    let Some(hit) = mesh.raycast(V3::from_godot(from), V3::from_godot(to)) else {
        return (CELL_MISS, 0, Vec::new());
    };
    let out = walk_plates(mesh, spec, &hit, dir * (speed as f32), -1.0, false, log);
    let part = out.final_part.unwrap_or(out.first_part);
    let mut code = (out.damage_result.clamp(0, 15) as u8) & CELL_CODE_MASK;
    if mesh.is_dynamic(part) {
        code |= CELL_TURRET;
    }
    (code, out.first_part, out.steps)
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
            let prev = to - dir * entry;
            if prev.y <= 1.0 {
                continue;
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
            let mut code = (res.result_type.clamp(0, 15) as u8) & CELL_CODE_MASK;
            let turret = res.armor_part.as_ref().and_then(|part| {
                let sa = self.armor.get(target_id)?;
                let idx = sa.parts.iter().position(|p| p == part)?;
                Some(sa.mesh.is_dynamic(idx))
            }).unwrap_or(false);
            if turret {
                code |= CELL_TURRET;
            }
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
                let (code, first_part, steps) = walk_cell(mesh, aabb, &spec_mid, p, dir, v_ref, true);
                if code == CELL_MISS {
                    return (code, String::from("miss"), -1.0, 0);
                }
                let mut sig = String::new();
                for st in &steps {
                    sig.push_str(&format!("{}|{:.0}|{:.2}|{};", st.part, st.armor_mm, st.impact_angle, st.is_citadel));
                }
                sig.push_str(&format!("={}", code));
                let first_mm = steps.first().map(|s| s.armor_mm as f32).unwrap_or(-1.0);
                let mut flags = 0u8;
                if mesh.is_citadel(first_part) {
                    flags |= FLAG_CITADEL;
                }
                if mesh.is_dynamic(first_part) {
                    flags |= FLAG_TURRET;
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
        let mut cells = PackedInt32Array::new();
        cells.resize(pts.len());
        for (i, (_, sig, first_mm, flags)) in classified.iter().enumerate() {
            let idx = *sig_index.entry(sig.clone()).or_insert_with(|| {
                profiles.push(Profile { rep: i, first_mm: *first_mm, flags: *flags });
                profiles.len() - 1
            });
            cells[i] = idx as i32;
        }

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
        let mut prof_off = PackedInt32Array::new();
        let mut bp_mm = PackedFloat32Array::new();
        let mut bp_code = PackedByteArray::new();
        let mut prof_off_om = PackedInt32Array::new();
        let mut bp_mm_om = PackedFloat32Array::new();
        let mut bp_code_om = PackedByteArray::new();
        let mut first_mm = PackedFloat32Array::new();
        let mut first_flags = PackedByteArray::new();
        for (prof, (bps, bps_om, w)) in profiles.iter().zip(sweeps.iter()) {
            walks += *w as i64;
            prof_off.push(bp_mm.len() as i32);
            for (mm, code) in bps {
                bp_mm.push(*mm);
                bp_code.push(*code);
            }
            prof_off_om.push(bp_mm_om.len() as i32);
            for (mm, code) in bps_om {
                bp_mm_om.push(*mm);
                bp_code_om.push(*code);
            }
            first_mm.push(prof.first_mm);
            first_flags.push(prof.flags);
        }
        prof_off.push(bp_mm.len() as i32);
        prof_off_om.push(bp_mm_om.len() as i32);
        out.set("cells", &cells);
        out.set("prof_off", &prof_off);
        out.set("bp_mm", &bp_mm);
        out.set("bp_code", &bp_code);
        out.set("prof_off_om", &prof_off_om);
        out.set("bp_mm_om", &bp_mm_om);
        out.set("bp_code_om", &bp_code_om);
        out.set("first_mm", &first_mm);
        out.set("first_flags", &first_flags);
        out.set("walks", walks);
        out
    }

    /// Result byte per cell for a shell with penetration `pen` (mm) and
    /// `overmatch` (mm). HE resolves off the first plate alone, as the walk does.
    /// AP reads the swept breakpoints, from the overmatched sweep when the shell
    /// overmatches the first plate.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn lattice_resolve_impl(
        cells: &PackedInt32Array,
        prof_off: &PackedInt32Array,
        bp_mm: &PackedFloat32Array,
        bp_code: &PackedByteArray,
        prof_off_om: &PackedInt32Array,
        bp_mm_om: &PackedFloat32Array,
        bp_code_om: &PackedByteArray,
        first_mm: &PackedFloat32Array,
        first_flags: &PackedByteArray,
        pen: f64,
        overmatch: f64,
        is_he: bool,
    ) -> PackedByteArray {
        let np = first_mm.len();
        let mut out = PackedByteArray::new();
        out.resize(cells.len());
        out.fill(CELL_MISS);
        if np == 0 || prof_off.len() != np + 1 {
            return out;
        }
        let mut codes: Vec<u8> = Vec::with_capacity(np);
        for pi in 0..np {
            let fm = first_mm[pi] as f64;
            if fm < 0.0 {
                codes.push(CELL_MISS);
                continue;
            }
            let flags = first_flags[pi];
            let turret = if flags & FLAG_TURRET != 0 { CELL_TURRET } else { 0 };
            if is_he {
                let c = if overmatch >= fm {
                    if flags & FLAG_CITADEL != 0 { hit_result::CITADEL } else { hit_result::PENETRATION }
                } else {
                    hit_result::SHATTER
                };
                codes.push((c as u8) | turret);
                continue;
            }
            let om = overmatch >= fm && prof_off_om.len() == np + 1
                && prof_off_om[pi + 1] > prof_off_om[pi];
            let (offs, mms, cds) = if om {
                (prof_off_om, bp_mm_om, bp_code_om)
            } else {
                (prof_off, bp_mm, bp_code)
            };
            let (a, b) = (offs[pi] as usize, offs[pi + 1] as usize);
            if a >= b {
                codes.push(CELL_MISS);
                continue;
            }
            let mut code = cds[a];
            for k in a..b {
                if mms[k] as f64 <= pen {
                    code = cds[k];
                } else {
                    break;
                }
            }
            codes.push(code);
        }
        for i in 0..cells.len() {
            let pi = cells[i];
            if pi >= 0 && (pi as usize) < np {
                out[i] = codes[pi as usize];
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
        let dv = (v1 - v0) / ny as f64;
        let ea = (ellipse.x as f64).max(0.01);
        let eb = (ellipse.y as f64).max(0.01) * 0.785;
        let guar_h = |x: f64| ((x + ea) / (2.0 * ea)).clamp(0.0, 1.0);
        let guar_v = |y: f64| 0.5 + 0.5 * y.signum() * (y.abs() / eb).min(1.0).powf(1.0 / 1.6);
        let p_in_h = trunc_gauss_cdf(ea, s, erf_bound) - trunc_gauss_cdf(-ea, s, erf_bound);
        let p_in_v = trunc_gauss_cdf(eb, s, erf_bound) - trunc_gauss_cdf(-eb, s, erf_bound);
        let g = if guarantee > 0.0 { guarantee * (1.0 - p_in_h * p_in_v).powi(3) } else { 0.0 };

        let payout = |c: u8| -> f64 {
            let code = (c & CELL_CODE_MASK) as usize;
            let mut v = if code < payouts.len() { payouts[code] } else { 0.0 };
            if c & CELL_TURRET != 0 {
                v = v.min(turret_cap);
            }
            v
        };

        for ai in 0..na {
            let aim = aims[ai];
            let (wh, qh) = axis_weights(nx, u0, du, aim.x as f64, half_disp.x as f64, s, erf_bound, &guar_h);
            let (wv, qv) = axis_weights(ny, v0, dv, aim.y as f64, half_disp.y as f64, s, erf_bound, &guar_v);
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
