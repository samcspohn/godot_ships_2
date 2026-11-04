use std::f64::consts::{PI, TAU};

use godot::builtin::AnyArray;
use godot::classes::Node3D;
use godot::prelude::*;

use crate::combat::turret::{wrapf, Turret};
use crate::nav::navigator::hull::{rudder_to_heading, Hull, PHYSICS_DT};
use crate::nav::types::ShipParams;

/// A turret within this of its target's bearing counts as trained.
const TRAINED_RAD: f64 = 0.01;

/// Heading search resolution: half a degree.
const STEPS: usize = 720;

fn diff(from: f64, to: f64) -> f64 {
    wrapf(to - from, -PI, PI)
}

/// Per mount (None when disabled or not a turret): the rotation, relative to
/// the hull as it lies now, that bears it on `target`.
fn mounts(list: &AnyArray, target: Vector2) -> Vec<Option<(f64, Turret)>> {
    let t3 = Vector3::new(target.x, 0.0, target.y);
    list.iter_shared().map(|g| {
        let t = Turret::load(g.try_to::<Gd<Node3D>>().ok()?);
        (!t.is_disabled()).then(|| (t.rot_y() + t.angle_to_target(t3), t))
    }).collect()
}

fn bears(m: &(f64, Turret), turned: f64) -> bool {
    m.1.in_fire_arcs(wrapf(m.0 - turned, -PI, PI))
}

/// Hull-heading helpers for SkillStance: which mounts bear on a point at a
/// given heading, and the headings nearest a wanted one at which they do.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct StanceSim {
    base: Base<RefCounted>,
}

#[godot_api]
impl StanceSim {
    /// Nearest hull heading to `want`, turning each way ([one way, the other]),
    /// at which every live mount (`all`) or any live mount bears on `target`;
    /// empty when none does. `heading` is the hull's heading now.
    #[func]
    fn nearest_bearing(list: AnyArray, target: Vector2, heading: f32, want: f32, all: bool) -> PackedFloat32Array {
        let live: Vec<(f64, Turret)> = mounts(&list, target).into_iter().flatten().collect();
        if live.is_empty() {
            return PackedFloat32Array::new();
        }
        let (h0, w) = (heading as f64, want as f64);
        let ok = |h: f64| {
            let turned = diff(h0, h);
            if all { live.iter().all(|m| bears(m, turned)) } else { live.iter().any(|m| bears(m, turned)) }
        };
        let step = TAU / STEPS as f64;
        let first = |sign: f64| (0..=STEPS / 2).map(|k| wrapf(w + sign * k as f64 * step, -PI, PI)).find(|&h| ok(h));
        match (first(1.0), first(-1.0)) {
            (Some(a), Some(b)) => PackedFloat32Array::from(&[a as f32, b as f32][..]),
            _ => PackedFloat32Array::new(),
        }
    }

    /// Per step of a hull track (`pos`, `hdg`: 0 = +Z, π/2 = +X), with the hull now at `pos0`/`hdg0`: a
    /// bitmask of the live mounts trained on `target` (one point per step) and inside their fire arcs. Each
    /// mount slews from where it lies now at `traverse_deg_s` for `dt` a step, the long way round its rotation limits.
    #[func]
    fn track_bearing(list: AnyArray, pos0: Vector2, hdg0: f32, pos: PackedVector2Array, hdg: PackedFloat32Array,
            target: PackedVector2Array, traverse_deg_s: f32, dt: f32) -> PackedInt64Array {
        let n = pos.len().min(hdg.len()).min(target.len());
        let mut out = vec![0i64; n];
        let fwd = |h: f64| Vector2::new(h.sin() as f32, h.cos() as f32);
        let right = |h: f64| Vector2::new(h.cos() as f32, -h.sin() as f32);
        // Signed angle off `f` to `d`, as Turret::angle_to_target measures it.
        let off = |f: Vector2, d: Vector2| { let d = d.normalized_or_zero(); d.cross(f).atan2(d.dot(f)) as f64 };
        let max_step = (traverse_deg_s as f64).to_radians() * dt as f64;
        for (bit, g) in list.iter_shared().enumerate().take(63) {
            let Ok(node) = g.try_to::<Gd<Node3D>>() else { continue };
            let t = Turret::load(node.clone());
            if t.is_disabled() {
                continue;
            }
            let gp = node.get_global_position();
            let rel = Vector2::new(gp.x, gp.z) - pos0;
            let (along, across) = (rel.dot(fwd(hdg0 as f64)), rel.dot(right(hdg0 as f64)));
            let mount = |k: usize| { let h = hdg[k] as f64; pos[k] + fwd(h) * along + right(h) * across };
            let t0 = Vector3::new(target[0].x, 0.0, target[0].y);
            // Hull-relative bearing to turret rotation: fixed while the hull carries the mount.
            let c = t.rot_y() + t.angle_to_target(t0) - off(fwd(hdg0 as f64), Vector2::new(t0.x, t0.z) - Vector2::new(gp.x, gp.z));
            let mut y = t.rot_y();
            for k in 0..n {
                let want = wrapf(c + off(fwd(hdg[k] as f64), target[k] - mount(k)), -PI, PI);
                let step = t.apply_rotation_limits(y, wrapf(want - y, -PI, PI)).clamp(-max_step, max_step);
                y = wrapf(y + step, -PI, PI);
                if wrapf(want - y, -PI, PI).abs() <= TRAINED_RAD && t.in_fire_arcs(want) {
                    out[k] |= 1 << bit;
                }
            }
        }
        PackedInt64Array::from(out.as_slice())
    }

    /// SkillStance's dodge, sailed on the navigator's hull: per candidate [cost, heading at `horizon`]. A candidate is
    /// (rudder order, seconds held, power): the rudder held that long and then centred, the hull swinging on as it
    /// answers; a negative hold steers for heading x instead (the lie). The cost is the weight of the shells in the
    /// air that strike the hull, each its caliber over `ref_cal` cubed, citadel ones `cit_w` extra. `shells` is
    /// [landing x, z, fall vx, vz, seconds left, threat_half_len, caliber] each; `params` ShipNavigator's
    /// get_debug_arc_inputs; `state` [x, z, vx, vz, heading, yaw rate, rudder, power]. Boxes are (side, forward)
    /// metres in the hull frame; `top` how high above the water a falling shell still strikes.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn dodge_costs(shells: PackedFloat32Array, hull: Rect2, cit: Rect2, top: f32, ref_cal: f32, cit_w: f32,
            params: PackedFloat32Array, state: PackedFloat32Array, cands: PackedVector3Array, horizon: f32) -> PackedFloat32Array {
        let (Some(p), Some(h0)) = (ship_params(params.as_slice()), start_hull(state.as_slice())) else {
            return PackedFloat32Array::new();
        };
        let sh = shells.as_slice();
        let mut track = Vec::new();
        let mut out = Vec::with_capacity(cands.len() * 2);
        for c in cands.as_slice() {
            sail(&p, h0, *c, horizon, &mut track);
            out.push(shell_cost(sh, &track, hull, cit, top as f64, ref_cal as f64, cit_w as f64) as f32);
            out.push(track.last().map_or(h0.heading, |h| h.heading));
        }
        PackedFloat32Array::from(out.as_slice())
    }

    /// One dodge candidate's hull positions every `every` seconds over `horizon`, for SkillStance's land check.
    #[func]
    fn dodge_track(params: PackedFloat32Array, state: PackedFloat32Array, cand: Vector3, horizon: f32, every: f32) -> PackedVector2Array {
        let (Some(p), Some(h0)) = (ship_params(params.as_slice()), start_hull(state.as_slice())) else {
            return PackedVector2Array::new();
        };
        let mut track = Vec::new();
        sail(&p, h0, cand, horizon, &mut track);
        let k = ((every / PHYSICS_DT).round() as usize).max(1);
        track.iter().step_by(k).map(|h| h.pos).collect()
    }

    /// Per mount in `list`: 1 when live and bearing on `target` with the hull at `at`.
    #[func]
    fn bearing_mask(list: AnyArray, target: Vector2, heading: f32, at: f32) -> PackedByteArray {
        let turned = diff(heading as f64, at as f64);
        mounts(&list, target).iter().map(|m| m.as_ref().map_or(0, |m| bears(m, turned) as u8)).collect()
    }
}

fn ship_params(v: &[f32]) -> Option<ShipParams> {
    if v.len() < 19 {
        return None;
    }
    Some(ShipParams {
        turning_circle_radius: v[0], rudder_response_time: v[1], acceleration_time: v[2], max_speed: v[3],
        reverse_speed_ratio: v[4], ship_length: v[5], ship_beam: v[6], turn_speed_loss: v[7],
        turn_tightening: v[17], linear_drag: v[18], ..ShipParams::default()
    })
}

fn start_hull(s: &[f32]) -> Option<Hull> {
    (s.len() >= 8).then(|| Hull { pos: Vector2::new(s[0], s[1]), vel: Vector2::new(s[2], s[3]), heading: s[4], yaw: s[5],
        rudder: s[6], power: s[7] })
}

/// The hull every physics tick for `horizon` under candidate `c` (see dodge_costs).
fn sail(p: &ShipParams, h0: Hull, c: Vector3, horizon: f32, track: &mut Vec<Hull>) {
    let n = (horizon / PHYSICS_DT).ceil().max(0.0) as usize;
    let mut h = h0;
    track.clear();
    track.push(h);
    for k in 0..n {
        let t = k as f32 * PHYSICS_DT;
        let rudder = if c.y < 0.0 { rudder_to_heading(&h, p, c.x, c.z < 0.0) } else if t < c.y { c.x } else { 0.0 };
        h.step(p, rudder, c.z, PHYSICS_DT);
        track.push(h);
    }
}

#[allow(clippy::too_many_arguments)]
fn shell_cost(sh: &[f32], track: &[Hull], hull: Rect2, cit: Rect2, top: f64, ref_cal: f64, cit_w: f64) -> f64 {
    let mut cost = 0.0;
    for s in sh.chunks_exact(7) {
        let k = ((s[4] / PHYSICS_DT).round().max(0.0) as usize).min(track.len() - 1);
        let (ax, az, ah) = (track[k].pos.x as f64, track[k].pos.y as f64, track[k].heading as f64);
        let (fx, fz) = (ah.sin(), ah.cos());
        let (sx, sz) = (-ah.cos(), ah.sin());
        let (wx, wz) = (s[0] as f64 - ax, s[1] as f64 - az);
        let (vx, vz) = (s[2] as f64, s[3] as f64);
        let vl = (vx * vx + vz * vz).sqrt();
        let (dx, dz) = if vl > 1e-3 { (vx / vl, vz / vl) } else { (0.0, 0.0) };
        // threat_half_len encodes the sine of the fall's angle from vertical.
        let f = ((s[5] as f64 - 15.0) / 35.0).clamp(0.0, 0.99);
        let run = top * f / (1.0 - f * f).sqrt();
        let (ux, uz) = (wx - dx * run, wz - dz * run);
        let a = (ux * sx + uz * sz, ux * fx + uz * fz);
        let b = (wx * sx + wz * sz, wx * fx + wz * fz);
        if segment_in(a, b, hull) {
            cost += (s[6] as f64 / ref_cal).powi(3) * (1.0 + if segment_in(a, b, cit) { cit_w } else { 0.0 });
        }
    }
    cost
}

/// Whether segment a-b crosses `r` (Liang-Barsky).
fn segment_in(a: (f64, f64), b: (f64, f64), r: Rect2) -> bool {
    let (x0, y0) = (r.position.x as f64, r.position.y as f64);
    let (x1, y1) = (x0 + r.size.x as f64, y0 + r.size.y as f64);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    for (p, q) in [(-dx, a.0 - x0), (dx, x1 - a.0), (-dy, a.1 - y0), (dy, y1 - a.1)] {
        if p.abs() < 1e-9 {
            if q < 0.0 {
                return false;
            }
            continue;
        }
        let t = q / p;
        if p < 0.0 { t0 = t0.max(t) } else { t1 = t1.min(t) }
        if t0 > t1 {
            return false;
        }
    }
    true
}
