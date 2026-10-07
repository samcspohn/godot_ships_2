use std::f64::consts::{PI, TAU};

use godot::builtin::AnyArray;
use godot::classes::Node3D;
use godot::prelude::*;

use crate::combat::turret::{wrapf, Turret};

/// A turret is firing once it points within this of the target.
const ON_TARGET: f64 = 2.0 * PI / 180.0;

fn diff(from: f64, to: f64) -> f64 {
    wrapf(to - from, -PI, PI)
}

/// HP gone for good: what no repair can restore, plus repairable damage past
/// the repair party's spare capacity.
fn kept(total: f64, healable: f64, spare: f64) -> f64 {
    total - healable + (healable - spare).max(0.0)
}

fn get_f(o: &VarDictionary, k: &str, d: f64) -> f64 {
    o.get(k).map_or(d, |v| v.to::<f64>())
}

struct Gun {
    turret: Turret,
    aim: f64,
    target0: f64,
}

/// SkillStance's look-ahead: sails each candidate (heading, gear) for a
/// horizon at the hull's spool and turn rate, with the turrets slewing to keep
/// the target, and scores damage dealt against damage taken and progress.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct StanceSim {
    base: Base<RefCounted>,
}

#[godot_api]
impl StanceSim {
    /// opts: heading, v, vmax, radius, tighten, spool, reverse, hp, spare, pos,
    /// in_dps, in_heal and toward (per heading step, from -PI), route (INF none),
    /// horizon, dt, w_progress, w_closing; with target (Vector2), guns, traverse
    /// (deg/s), out_dps and w_deal the turrets' damage counts too, w_deal HP of
    /// ours per HP dealt. Damage taken is scored as HP lost for good.
    /// Returns one score per (headings[i], astern[i]).
    #[func]
    fn evaluate(opts: VarDictionary, headings: PackedFloat32Array, astern: PackedByteArray) -> PackedFloat32Array {
        let in_dps = opts.get("in_dps").and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default().to_vec();
        let in_heal = opts.get("in_heal").and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default().to_vec();
        let toward = opts.get("toward").and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default().to_vec();
        let n = in_dps.len().max(1);
        let step = TAU / n as f64;
        let index = |h: f64| (((h + PI) / step).round() as i64).rem_euclid(n as i64) as usize;
        let (h0, v0, vmax) = (get_f(&opts, "heading", 0.0), get_f(&opts, "v", 0.0), get_f(&opts, "vmax", 1.0).max(1.0));
        let (radius, tighten) = (get_f(&opts, "radius", 500.0).max(1.0), get_f(&opts, "tighten", 1.0));
        let accel = vmax / get_f(&opts, "spool", 10.0).max(0.1);
        let reverse = get_f(&opts, "reverse", 0.5);
        let hp = get_f(&opts, "hp", 1.0).max(1.0);
        let pos0 = opts.get("pos").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::ZERO);
        let route = get_f(&opts, "route", f64::INFINITY);
        let horizon = get_f(&opts, "horizon", 60.0);
        let dt = get_f(&opts, "dt", 3.0).max(0.1);
        let (w_progress, w_closing) = (get_f(&opts, "w_progress", 0.1), get_f(&opts, "w_closing", 0.05));
        let target = opts.get("target").and_then(|v| v.try_to::<Vector2>().ok());
        let traverse = get_f(&opts, "traverse", 0.0).to_radians();
        let spare = get_f(&opts, "spare", 0.0);
        let w_deal = get_f(&opts, "w_deal", 1.0 / 3.0);
        let mut guns: Vec<Gun> = Vec::new();
        if let Some(t) = target {
            let t3 = Vector3::new(t.x, 0.0, t.y);
            let list = opts.get("guns").and_then(|v| v.try_to::<AnyArray>().ok());
            for g in list.iter().flat_map(|a| a.iter_shared()) {
                let Ok(node) = g.try_to::<Gd<Node3D>>() else { continue };
                let turret = Turret::load(node);
                if turret.is_disabled() {
                    continue;
                }
                let aim = turret.rot_y();
                let target0 = aim + turret.angle_to_target(t3);
                guns.push(Gun { turret, aim, target0 });
            }
        }
        let per_gun = if guns.is_empty() { 0.0 } else { get_f(&opts, "out_dps", 0.0) / guns.len() as f64 };
        let bearing0 = target.map_or(0.0, |t| ((t.x - pos0.x) as f64).atan2((t.y - pos0.y) as f64));

        let mut out = PackedFloat32Array::new();
        for (k, &h) in headings.as_slice().iter().enumerate() {
            let h = h as f64;
            let back = astern.as_slice().get(k).is_some_and(|&b| b != 0);
            let target_v = if back { -vmax * reverse } else { vmax };
            let (mut v, mut hdg) = (v0, h0);
            let (mut px, mut pz) = (pos0.x as f64, pos0.y as f64);
            let mut aims: Vec<f64> = guns.iter().map(|g| g.aim).collect();
            let (mut taken, mut healable, mut dealt, mut gain) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
            let mut t = 0.0;
            while t < horizon {
                v = if v < target_v { (v + accel * dt).min(target_v) } else { (v - accel * dt).max(target_v) };
                let speed = v.abs();
                let r = radius * (tighten + (1.0 - tighten) * (speed / vmax).clamp(0.0, 1.0));
                let max_turn = speed / r * dt;
                hdg = wrapf(hdg + diff(hdg, h).clamp(-max_turn, max_turn), -PI, PI);
                px += hdg.sin() * v * dt;
                pz += hdg.cos() * v * dt;
                let i = index(hdg);
                taken += in_dps.get(i).copied().unwrap_or(0.0) as f64 * dt;
                healable += in_heal.get(i).copied().unwrap_or(0.0) as f64 * dt;
                if route.is_finite() {
                    gain += v * diff(hdg, route).cos() * dt;
                } else {
                    gain -= v * toward.get(i).copied().unwrap_or(0.0) as f64 * dt * w_closing / w_progress.max(1e-6);
                }
                if let Some(tg) = target {
                    let b = ((tg.x as f64) - px).atan2((tg.y as f64) - pz);
                    for (g, aim) in guns.iter().zip(aims.iter_mut()) {
                        let want = wrapf(g.target0 + diff(bearing0, b) - diff(h0, hdg), -PI, PI);
                        let step = g.turret.apply_rotation_limits(*aim, diff(*aim, want));
                        *aim = wrapf(*aim + step.clamp(-traverse * dt, traverse * dt), -PI, PI);
                        if g.turret.in_fire_arcs(want) && diff(*aim, want).abs() <= ON_TARGET {
                            dealt += per_gun * dt;
                        }
                    }
                }
                t += dt;
            }
            let lost = kept(taken, healable, spare);
            out.push((w_progress * gain / (vmax * horizon) + (w_deal * dealt - lost) / hp) as f32);
        }
        out
    }
}
