use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Node3D, PhysicsDirectSpaceState3D, Resource};

use super::ProjectileManager;
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::projectile::armor::NativeArmorInteraction;
use crate::projectile::data::ProjectileData;

pub const CELL_MISS: u8 = 0xFF;
pub const CELL_UNWALKED: u8 = 0xFE;
pub const CELL_TURRET: u8 = 0x10;
pub const CELL_CODE_MASK: u8 = 0x0F;

const WALK_MARGIN_M: f32 = 15.0;
const WALK_ENTRY_MIN_M: f32 = 60.0;
const WALK_EXIT_MIN_M: f32 = 80.0;

/// Distance back along `-ld` and forward along `ld` for a segment through `lp`
/// to cross the grown box from outside to outside (slab test, target frame).
fn walk_span(aabb: Aabb, lp: Vector3, ld: Vector3) -> (f32, f32) {
    if aabb.size == Vector3::ZERO {
        return (WALK_ENTRY_MIN_M, WALK_EXIT_MIN_M);
    }
    let lo = aabb.position - Vector3::splat(WALK_MARGIN_M);
    let hi = aabb.position + aabb.size + Vector3::splat(WALK_MARGIN_M);
    let mut t_enter = f32::NEG_INFINITY;
    let mut t_exit = f32::INFINITY;
    let ld = ld.to_array();
    let lp = lp.to_array();
    let lo = lo.to_array();
    let hi = hi.to_array();
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

/// Per-axis cell masses of the kernel centred on `aim`: (gaussian, guarantee).
fn axis_weights(
    n: usize, lo: f64, step: f64, aim: f64, half_disp: f64, s: f64, erf_bound: f64,
    guar_cdf: &dyn Fn(f64) -> f64,
) -> (Vec<f64>, Vec<f64>) {
    let hd = half_disp.max(1e-3);
    let mut g = Vec::with_capacity(n);
    let mut q = Vec::with_capacity(n);
    let mut prev_x = (lo - aim) / hd;
    let mut prev_g = trunc_gauss_cdf(prev_x, s, erf_bound);
    let mut prev_q = guar_cdf(prev_x);
    for i in 0..n {
        let x = (lo + step * (i as f64 + 1.0) - aim) / hd;
        let cg = trunc_gauss_cdf(x, s, erf_bound);
        let cq = guar_cdf(x);
        g.push(cg - prev_g);
        q.push(cq - prev_q);
        prev_x = x;
        prev_g = cg;
        prev_q = cq;
    }
    let _ = prev_x;
    (g, q)
}

impl ProjectileManager {
    /// Walk one shell of `shell` at each of `points` (target-local, on the
    /// survey plane) from `from` and report one result byte per point:
    /// CELL_MISS, or the NativeArmorInteraction code with CELL_TURRET set when
    /// the plate met was on a turret.
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
        let Some(mut space_state) = space_state else {
            out.fill(CELL_MISS);
            return out;
        };
        self.ensure_armor_autoloads();
        let ppw = self.precision_physics_world.clone();
        let mut ppw_call = ppw.clone();
        let nav_map = self.navigation_map.clone();
        let xf = target.get_global_transform();
        let basis_inv = xf.basis.inverse();
        let aabb: Aabb = target.get("aabb").try_to::<Aabb>().unwrap_or_default();
        let target_obj = target.clone().upcast::<Object>();
        let mut proj = ProjectileData::new_gd();
        let mut turret_cache: std::collections::BTreeMap<i64, bool> = std::collections::BTreeMap::new();

        for i in 0..n {
            let p = points[i];
            let to = xf * p;
            let launch = ProjectilePhysicsWithDragV2::calculate_launch_vector_impl(from, to, &shell);
            let v0 = launch.at(0);
            if v0.is_nil() {
                out[i] = CELL_MISS;
                continue;
            }
            let vel: Vector3 = v0.try_to::<Vector3>().unwrap_or_default();
            if vel == Vector3::ZERO {
                out[i] = CELL_MISS;
                continue;
            }
            let tof = launch.at(1).to_f64();
            let impact = ProjectilePhysicsWithDragV2::calculate_velocity_at_time_impl(vel, tof, &shell);
            let dir = impact.normalized();
            let ld = (basis_inv * dir).normalized();
            let (entry, exit) = walk_span(aabb, p, ld);
            let prev = to - dir * entry;
            if prev.y <= 1.0 {
                out[i] = CELL_MISS;
                continue;
            }
            {
                let mut pd = proj.bind_mut();
                pd.initialize(to + dir * exit, vel, 0.0, shell.clone(), Some(owner.clone()), VarArray::new());
                pd.frame_count = 1;
            }
            let rays = self.get_armor_ray_cache(&proj);
            let res = NativeArmorInteraction::process_travel(
                &proj, prev, tof, Some(&mut space_state), ppw.as_ref(), &nav_map, rays, false,
            );
            if !res.hit {
                out[i] = CELL_MISS;
                continue;
            }
            match &res.ship {
                Some(s) if *s == target_obj => {}
                _ => {
                    out[i] = CELL_MISS;
                    continue;
                }
            }
            let mut code = (res.result_type.clamp(0, 15) as u8) & CELL_CODE_MASK;
            if let (Some(part), Some(world)) = (&res.armor_part, ppw_call.as_mut()) {
                let id = part.instance_id().to_i64();
                let turret = *turret_cache.entry(id).or_insert_with(|| {
                    world.call("is_turret_part", &[part.to_variant()]).to_bool()
                });
                if turret {
                    code |= CELL_TURRET;
                }
            }
            out[i] = code;
        }
        out
    }

    /// Expected payout and arrival rate of one shell aimed at each of `aims`
    /// (lattice-plane coordinates), integrating `cells` under the gun's
    /// truncated-Gaussian kernel. Returns [value, landed] per aim; value is in
    /// payout-multiplier units, -1 where no walked cell carries any mass.
    ///
    /// `guarantee` is the fraction of shells the citadel guarantee may move and
    /// `ellipse` the guarantee ellipse in normalised units; unwalked cells are
    /// renormalised out so a partial survey still answers.
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
