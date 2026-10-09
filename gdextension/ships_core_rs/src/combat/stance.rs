use std::f64::consts::PI;

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
    ready: f64,
}

struct Shooter {
    bearing: f64,
    rows: Vec<f32>,
    weight: f64,
    reload: f64,
    next: f64,
}

impl Shooter {
    fn read(d: &VarDictionary) -> Self {
        Shooter {
            bearing: get_f(d, "bearing", 0.0),
            rows: d.get("rows").and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default().to_vec(),
            weight: get_f(d, "weight", 1.0),
            reload: get_f(d, "reload", 0.0),
            next: get_f(d, "next", f64::INFINITY),
        }
    }

    /// (dps, repairable dps) at hull heading `hdg`.
    fn at(&self, hdg: f64, step_deg: f64) -> (f64, f64) {
        let n = self.rows.len() / 2;
        if n == 0 {
            return (0.0, 0.0);
        }
        let a = ((diff(hdg, self.bearing).abs().to_degrees() / step_deg).round() as usize).min(n - 1);
        (self.rows[a] as f64, self.rows[n + a] as f64)
    }

    /// Seconds of fire landing in [t, t + dt): a whole reload per salvo, else dt.
    fn exposure(&self, t: f64, dt: f64) -> f64 {
        if self.reload <= 0.0 || !self.next.is_finite() {
            return dt;
        }
        let first = ((t - self.next) / self.reload).ceil().max(0.0);
        let land = self.next + first * self.reload;
        if land < t + dt { self.reload } else { 0.0 }
    }
}

fn load_turrets(list: Option<AnyArray>, target: Vector3, ready: &[f32]) -> Vec<Gun> {
    let mut out = Vec::new();
    for (i, g) in list.iter().flat_map(|a| a.iter_shared()).enumerate() {
        let Ok(node) = g.try_to::<Gd<Node3D>>() else { continue };
        let turret = Turret::load(node);
        if turret.is_disabled() {
            continue;
        }
        let aim = turret.rot_y();
        let target0 = aim + turret.angle_to_target(target);
        out.push(Gun { turret, aim, target0, ready: ready.get(i).copied().unwrap_or(0.0) as f64 });
    }
    out
}

/// SkillStance's look-ahead: sails each candidate (heading, gear) for a
/// horizon at the hull's spool and turn rate, optionally switching to a second
/// heading part way, with each enemy's salvos landing on their own clock at the
/// aspect we show then, our turrets slewing and firing on their reloads and
/// loaded tubes launching once they bear; scores damage dealt against damage
/// taken and progress.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct StanceSim {
    base: Base<RefCounted>,
}

#[godot_api]
impl StanceSim {
    /// opts: heading, v, vmax, radius, tighten, spool, reverse, hp, spare, pos,
    /// shooters ([{bearing, rows, weight, reload, next}], rows = dps then
    /// repairable dps per aspect_step degrees off the bow), route (INF none),
    /// horizon, dt, w_progress, w_closing; then_heading / then_astern from
    /// then_at (INF never); with target (Vector2), guns, gun_ready (s), reload_s,
    /// traverse (deg/s), out_dps and w_deal the turrets count, w_deal HP of ours
    /// per HP dealt; tubes, tube_target and tube_value add loaded tubes.
    /// Returns one score per (headings[i], astern[i]).
    #[func]
    fn evaluate(opts: VarDictionary, headings: PackedFloat32Array, astern: PackedByteArray) -> PackedFloat32Array {
        let shooters: Vec<Shooter> = opts.get("shooters").and_then(|v| v.try_to::<AnyArray>().ok())
            .iter().flat_map(|a| a.iter_shared())
            .filter_map(|v| v.try_to::<VarDictionary>().ok()).map(|d| Shooter::read(&d)).collect();
        let step_deg = get_f(&opts, "aspect_step", 5.0).max(0.1);
        let total_w: f64 = shooters.iter().map(|s| s.weight).sum::<f64>().max(1e-6);
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
        let (then_h, then_at) = (get_f(&opts, "then_heading", 0.0), get_f(&opts, "then_at", f64::INFINITY));
        let then_back = get_f(&opts, "then_astern", 0.0) != 0.0;
        let target = opts.get("target").and_then(|v| v.try_to::<Vector2>().ok());
        let traverse = get_f(&opts, "traverse", 0.0).to_radians();
        let spare = get_f(&opts, "spare", 0.0);
        let w_deal = get_f(&opts, "w_deal", 1.0 / 3.0);
        let reload_s = get_f(&opts, "reload_s", 0.0);
        let mut guns: Vec<Gun> = Vec::new();
        if let Some(t) = target {
            let ready = opts.get("gun_ready").and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default();
            guns = load_turrets(opts.get("guns").and_then(|v| v.try_to::<AnyArray>().ok()), Vector3::new(t.x, 0.0, t.y), ready.as_slice());
        }
        let tube_target = opts.get("tube_target").and_then(|v| v.try_to::<Vector2>().ok());
        let tubes: Vec<Gun> = tube_target.map_or_else(Vec::new, |t| {
            load_turrets(opts.get("tubes").and_then(|v| v.try_to::<AnyArray>().ok()), Vector3::new(t.x, 0.0, t.y), &[])
        });
        let tube_value = get_f(&opts, "tube_value", 0.0);
        let out_dps = get_f(&opts, "out_dps", 0.0);
        let per_gun = if guns.is_empty() { 0.0 } else { out_dps / guns.len() as f64 };
        let bearing_to = |t: Option<Vector2>, x: f64, z: f64| t.map_or(0.0, |t| ((t.x as f64) - x).atan2((t.y as f64) - z));
        let bearing0 = bearing_to(target, pos0.x as f64, pos0.y as f64);
        let tube_bearing0 = bearing_to(tube_target, pos0.x as f64, pos0.y as f64);

        let mut out = PackedFloat32Array::new();
        for (k, &h) in headings.as_slice().iter().enumerate() {
            let back0 = astern.as_slice().get(k).is_some_and(|&b| b != 0);
            let (mut v, mut hdg) = (v0, h0);
            let (mut px, mut pz) = (pos0.x as f64, pos0.y as f64);
            let mut aims: Vec<f64> = guns.iter().map(|g| g.aim).collect();
            let mut ready: Vec<f64> = guns.iter().map(|g| g.ready).collect();
            let mut launched = vec![false; tubes.len()];
            let (mut taken, mut healable, mut dealt, mut gain) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
            let mut t = 0.0;
            while t < horizon {
                let (want_h, back) = if t >= then_at { (then_h, then_back) } else { (h as f64, back0) };
                let target_v = if back { -vmax * reverse } else { vmax };
                v = if v < target_v { (v + accel * dt).min(target_v) } else { (v - accel * dt).max(target_v) };
                let speed = v.abs();
                let r = radius * (tighten + (1.0 - tighten) * (speed / vmax).clamp(0.0, 1.0));
                let max_turn = speed / r * dt;
                hdg = wrapf(hdg + diff(hdg, want_h).clamp(-max_turn, max_turn), -PI, PI);
                px += hdg.sin() * v * dt;
                pz += hdg.cos() * v * dt;
                let mut toward = 0.0;
                for s in &shooters {
                    let (dps, heal) = s.at(hdg, step_deg);
                    let secs = s.weight * s.exposure(t, dt);
                    taken += dps * secs;
                    healable += heal * secs;
                    toward += s.weight * diff(hdg, s.bearing).cos();
                }
                if route.is_finite() {
                    gain += v * diff(hdg, route).cos() * dt;
                } else {
                    gain -= v * toward / total_w * dt * w_closing / w_progress.max(1e-6);
                }
                if target.is_some() {
                    let b = bearing_to(target, px, pz);
                    for ((g, aim), rd) in guns.iter().zip(aims.iter_mut()).zip(ready.iter_mut()) {
                        let want = wrapf(g.target0 + diff(bearing0, b) - diff(h0, hdg), -PI, PI);
                        let step = g.turret.apply_rotation_limits(*aim, diff(*aim, want));
                        *aim = wrapf(*aim + step.clamp(-traverse * dt, traverse * dt), -PI, PI);
                        if !(g.turret.in_fire_arcs(want) && diff(*aim, want).abs() <= ON_TARGET) {
                            continue;
                        }
                        if reload_s <= 0.0 {
                            dealt += per_gun * dt;
                        } else if t >= *rd {
                            dealt += per_gun * reload_s;
                            *rd = t + reload_s;
                        }
                    }
                }
                if tube_target.is_some() {
                    let b = bearing_to(tube_target, px, pz);
                    for (tb, done) in tubes.iter().zip(launched.iter_mut()) {
                        let want = wrapf(tb.target0 + diff(tube_bearing0, b) - diff(h0, hdg), -PI, PI);
                        if !*done && tb.turret.in_fire_arcs(want) {
                            *done = true;
                            dealt += tube_value * (1.0 - t / horizon);
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
