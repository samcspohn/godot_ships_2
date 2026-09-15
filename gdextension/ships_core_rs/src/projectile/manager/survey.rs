use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Node, Node3D, PhysicsDirectSpaceState3D, Resource};
use std::collections::BTreeMap;

use super::ProjectileManager;
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::projectile::armor::{hit_result, NativeArmorInteraction};
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

struct WalkCtx {
    xf: Transform3D,
    basis_inv: Basis,
    aabb: Aabb,
    target_obj: Gd<Object>,
    owner: Gd<Object>,
    ppw: Option<Gd<Node>>,
    turret_cache: BTreeMap<i64, bool>,
}

struct WalkOut {
    code: u8,
    steps: VarArray,
    part: Option<Gd<Object>>,
}

impl WalkCtx {
    fn new(target: &Gd<Node3D>, owner: Gd<Object>, ppw: Option<Gd<Node>>) -> Self {
        let xf = target.get_global_transform();
        Self {
            xf,
            basis_inv: xf.basis.inverse(),
            aabb: target.get("aabb").try_to::<Aabb>().unwrap_or_default(),
            target_obj: target.clone().upcast::<Object>(),
            owner,
            ppw,
            turret_cache: BTreeMap::new(),
        }
    }

    fn is_turret(&mut self, part: &Option<Gd<Object>>) -> bool {
        let (Some(part), Some(world)) = (part, self.ppw.as_mut()) else { return false };
        let id = part.instance_id().to_i64();
        *self.turret_cache.entry(id).or_insert_with(|| {
            world.call("is_turret_part", &[part.to_variant()]).to_bool()
        })
    }
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

    /// One shell through the plane point `p` (target-local) arriving along
    /// world `dir` at world velocity `vel`, straddling the hull.
    fn walk_one(
        &mut self,
        ctx: &mut WalkCtx,
        proj: &mut Gd<ProjectileData>,
        shell: &Gd<Resource>,
        p: Vector3,
        dir: Vector3,
        vel: Vector3,
        tof: f64,
        space: &mut Gd<PhysicsDirectSpaceState3D>,
        log: bool,
    ) -> WalkOut {
        let miss = WalkOut { code: CELL_MISS, steps: VarArray::new(), part: None };
        let to = ctx.xf * p;
        let ld = (ctx.basis_inv * dir).normalized();
        let (entry, exit) = walk_span(ctx.aabb, p, ld);
        let prev = to - dir * entry;
        if prev.y <= 1.0 {
            return miss;
        }
        {
            let mut pd = proj.bind_mut();
            pd.initialize(to + dir * exit, vel, 0.0, shell.clone(), Some(ctx.owner.clone()), VarArray::new());
            pd.frame_count = 1;
        }
        let ppw = ctx.ppw.clone();
        let nav_map = self.navigation_map.clone();
        let rays = self.get_armor_ray_cache(proj);
        let res = NativeArmorInteraction::process_travel(
            proj, prev, tof, Some(space), ppw.as_ref(), &nav_map, rays, log,
        );
        if !res.hit {
            return miss;
        }
        match &res.ship {
            Some(s) if *s == ctx.target_obj => {}
            _ => return miss,
        }
        let mut code = (res.result_type.clamp(0, 15) as u8) & CELL_CODE_MASK;
        if ctx.is_turret(&res.armor_part) {
            code |= CELL_TURRET;
        }
        WalkOut { code, steps: res.log_steps, part: res.armor_part }
    }

    /// Validation walk: one real shell of `shell` at each point, fired from
    /// `from` with the real ballistics. One result byte per point.
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
        let mut ctx = WalkCtx::new(&target, owner, self.precision_physics_world.clone());
        let mut proj = ProjectileData::new_gd();
        for i in 0..n {
            let p = points[i];
            let to = ctx.xf * p;
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
            out[i] = self.walk_one(&mut ctx, &mut proj, &shell, p, dir, vel, tof, &mut space, false).code;
        }
        out
    }

    /// Bake one lattice: parallel rays along world `dir` at speed `v_ref`.
    /// Cells are grouped into profiles by the plates they meet, and each profile
    /// is swept in penetration (via `penetration_modifier` on a copy of
    /// `ref_shell`, overmatch off) to find where the result changes.
    ///
    /// Returns cells -> profile index, per-profile breakpoint lists (mm, code),
    /// and the first plate's thickness and citadel/turret flags for HE and
    /// overmatch resolution at runtime.
    pub(crate) fn survey_sweep_impl(
        &mut self,
        target: Gd<Node3D>,
        owner: Gd<Object>,
        ref_shell: Gd<Resource>,
        dir: Vector3,
        v_ref: f64,
        points: PackedVector3Array,
        space_state: Option<Gd<PhysicsDirectSpaceState3D>>,
        coarse_pens: PackedFloat32Array,
        bisect_mm: f64,
        om_max: f64,
    ) -> VarDictionary {
        let n = points.len();
        let mut out = VarDictionary::new();
        let Some(mut space) = space_state else { return out };
        if coarse_pens.is_empty() {
            return out;
        }
        self.ensure_armor_autoloads();
        let mut ctx = WalkCtx::new(&target, owner, self.precision_physics_world.clone());
        let mut proj = ProjectileData::new_gd();
        let dir = dir.normalized();
        let vel = dir * (v_ref as f32);

        let Some(mut ap) = ref_shell.duplicate_ex().deep(true).done() else { return out };
        ap.set("overmatch", &0i64.to_variant());
        ap.set("type", &1i64.to_variant());
        let Some(mut he) = ref_shell.duplicate_ex().deep(true).done() else { return out };
        he.set("overmatch", &0i64.to_variant());
        he.set("type", &0i64.to_variant());
        let base_pen = NativeArmorInteraction::calculate_de_marre_penetration(
            ap.get("mass").to_f64(), v_ref, ap.get("caliber").to_f64(),
        ).max(1e-6);
        let set_pen = |ap: &mut Gd<Resource>, pen: f64| {
            ap.set("penetration_modifier", &(pen / base_pen).to_variant());
        };
        let mut walks: i64 = 0;

        struct Profile {
            rep: usize,
            first_mm: f32,
            flags: u8,
            bps: Vec<(f32, u8)>,
            /// Same sweep with the first plate (and anything thinner) overmatched.
            bps_om: Vec<(f32, u8)>,
        }
        let mut profiles: Vec<Profile> = Vec::new();
        let mut sig_index: BTreeMap<String, usize> = BTreeMap::new();
        let mut cells = PackedInt32Array::new();
        cells.resize(n);

        let mid_pen = coarse_pens[coarse_pens.len() / 2] as f64;
        set_pen(&mut ap, mid_pen);
        for i in 0..n {
            let w = self.walk_one(&mut ctx, &mut proj, &ap, points[i], dir, vel, 0.0, &mut space, true);
            walks += 1;
            let sig = if w.code == CELL_MISS {
                String::from("miss")
            } else {
                let mut s = String::new();
                for k in 0..w.steps.len() {
                    let st: VarDictionary = w.steps.at(k).try_to().unwrap_or_default();
                    s.push_str(&format!(
                        "{}|{:.0}|{:.2}|{};",
                        st.get("armor_path").map(|v| v.to_string()).unwrap_or_default(),
                        st.get("armor_mm").map(|v| v.to_f64()).unwrap_or(0.0),
                        st.get("impact_angle").map(|v| v.to_f64()).unwrap_or(0.0),
                        st.get("is_citadel").map(|v| v.to_bool()).unwrap_or(false),
                    ));
                }
                s.push_str(&format!("={}", w.code));
                s
            };
            let idx = *sig_index.entry(sig).or_insert_with(|| {
                let first_mm = if w.code == CELL_MISS || w.steps.is_empty() {
                    -1.0
                } else {
                    let st: VarDictionary = w.steps.at(0).try_to().unwrap_or_default();
                    st.get("armor_mm").map(|v| v.to_f64()).unwrap_or(0.0) as f32
                };
                profiles.push(Profile { rep: i, first_mm, flags: 0, bps: Vec::new(), bps_om: Vec::new() });
                profiles.len() - 1
            });
            cells[i] = idx as i32;
        }

        for prof in profiles.iter_mut() {
            if prof.first_mm < 0.0 {
                prof.bps.push((0.0, CELL_MISS));
                continue;
            }
            let p = points[prof.rep];
            // First plate identity from an HE probe, which stops at the plate it meets.
            let hw = self.walk_one(&mut ctx, &mut proj, &he, p, dir, vel, 0.0, &mut space, false);
            walks += 1;
            if NativeArmorInteraction::is_citadel(&hw.part) {
                prof.flags |= FLAG_CITADEL;
            }
            if hw.code != CELL_MISS && (hw.code & CELL_TURRET) != 0 {
                prof.flags |= FLAG_TURRET;
            }

            for om_pass in 0..2 {
                if om_pass == 1 {
                    if prof.first_mm as f64 > om_max {
                        break;
                    }
                    ap.set("overmatch", &(prof.first_mm as f64).to_variant());
                } else {
                    ap.set("overmatch", &0i64.to_variant());
                }
                let mut samples: Vec<(f64, u8)> = Vec::new();
                for k in 0..coarse_pens.len() {
                    let pen = coarse_pens[k] as f64;
                    set_pen(&mut ap, pen);
                    let c = self.walk_one(&mut ctx, &mut proj, &ap, p, dir, vel, 0.0, &mut space, false).code;
                    walks += 1;
                    samples.push((pen, c));
                }
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
                    set_pen(&mut ap, mid);
                    let c = self.walk_one(&mut ctx, &mut proj, &ap, p, dir, vel, 0.0, &mut space, false).code;
                    walks += 1;
                    samples.insert(k, (mid, c));
                }
                let bps = if om_pass == 0 { &mut prof.bps } else { &mut prof.bps_om };
                bps.push((0.0, samples[0].1));
                for k in 1..samples.len() {
                    if samples[k].1 != samples[k - 1].1 {
                        bps.push((samples[k].0 as f32, samples[k].1));
                    }
                }
            }
        }

        let mut prof_off = PackedInt32Array::new();
        let mut bp_mm = PackedFloat32Array::new();
        let mut bp_code = PackedByteArray::new();
        let mut prof_off_om = PackedInt32Array::new();
        let mut bp_mm_om = PackedFloat32Array::new();
        let mut bp_code_om = PackedByteArray::new();
        let mut first_mm = PackedFloat32Array::new();
        let mut first_flags = PackedByteArray::new();
        for prof in &profiles {
            prof_off.push(bp_mm.len() as i32);
            for (mm, code) in &prof.bps {
                bp_mm.push(*mm);
                bp_code.push(*code);
            }
            prof_off_om.push(bp_mm_om.len() as i32);
            for (mm, code) in &prof.bps_om {
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
            // A shell that overmatches the first plate reads the sweep that had
            // that plate overmatched, when one was baked.
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
