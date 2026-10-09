use std::f64::consts::PI;

use godot::builtin::AnyArray;
use godot::classes::Node3D;
use godot::prelude::*;

use crate::combat::turret::{wrapf, Turret};

/// A turret is firing once it points within this of its aim.
const ON_TARGET: f64 = 2.0 * PI / 180.0;

fn diff(from: f64, to: f64) -> f64 {
    wrapf(to - from, -PI, PI)
}

fn bearing(from: (f64, f64), to: Vector2) -> f64 {
    (to.x as f64 - from.0).atan2(to.y as f64 - from.1)
}

fn get_f(o: &VarDictionary, k: &str, d: f64) -> f64 {
    o.get(k).map_or(d, |v| v.to::<f64>())
}

fn get<T: FromGodot>(o: &VarDictionary, k: &str) -> Option<T> {
    o.get(k).and_then(|v| v.try_to::<T>().ok())
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
        let reload = get_f(d, "reload", 10.0).max(0.1);
        let next = get_f(d, "next", f64::INFINITY);
        Shooter {
            bearing: get_f(d, "bearing", 0.0),
            rows: get::<PackedFloat32Array>(d, "rows").unwrap_or_default().to_vec(),
            weight: get_f(d, "weight", 1.0),
            reload,
            next: if next.is_finite() { next } else { reload * 0.5 },
        }
    }

    /// (damage, repairable part) of the salvos landing in [t, t + dt) on hull heading `hdg`.
    fn landing(&self, t: f64, dt: f64, hdg: f64, step_deg: f64) -> (f64, f64) {
        let n = self.rows.len() / 2;
        let land = self.next + ((t - self.next) / self.reload).ceil().max(0.0) * self.reload;
        if n == 0 || land >= t + dt {
            return (0.0, 0.0);
        }
        let a = ((diff(hdg, self.bearing).abs().to_degrees() / step_deg).round() as usize).min(n - 1);
        let secs = self.weight * self.reload;
        (self.rows[a] as f64 * secs, self.rows[n + a] as f64 * secs)
    }
}

/// A gun or a loaded tube: fires `salvo` when on its aim and ready, again a reload later.
struct Weapon {
    turret: Turret,
    aim_at: Vector2,
    bearing0: f64,
    target0: f64,
    /// Mount rotation and seconds until loaded at t = 0; each plan sails from a copy.
    start: (f64, f64),
    salvo: f64,
    reload: f64,
    traverse: f64,
}

fn load_weapons(list: Option<AnyArray>, aim_at: Vector2, pos: Vector2, ready: &[f32], salvo: f64, reload: f64, traverse: f64) -> Vec<Weapon> {
    let at3 = Vector3::new(aim_at.x, 0.0, aim_at.y);
    list.iter().flat_map(|a| a.iter_shared()).enumerate().filter_map(|(i, g)| {
        let turret = Turret::load(g.try_to::<Gd<Node3D>>().ok()?);
        if turret.is_disabled() {
            return None;
        }
        let aim = turret.rot_y();
        Some(Weapon {
            target0: aim + turret.angle_to_target(at3),
            bearing0: bearing((pos.x as f64, pos.y as f64), aim_at),
            start: (aim, ready.get(i).copied().unwrap_or(0.0) as f64),
            turret, aim_at, salvo, reload, traverse,
        })
    }).collect()
}

impl Weapon {
    fn fire(&self, state: &mut (f64, f64), t: f64, dt: f64, at: (f64, f64), hdg_turned: f64) -> f64 {
        let (aim, ready) = state;
        let want = wrapf(self.target0 + diff(self.bearing0, bearing(at, self.aim_at)) - hdg_turned, -PI, PI);
        let step = self.turret.apply_rotation_limits(*aim, diff(*aim, want));
        *aim = wrapf(*aim + step.clamp(-self.traverse * dt, self.traverse * dt), -PI, PI);
        if t < *ready || !self.turret.in_fire_arcs(want) || diff(*aim, want).abs() > ON_TARGET {
            return 0.0;
        }
        *ready = t + self.reload;
        self.salvo
    }
}

struct Hull {
    v: f64,
    hdg: f64,
    x: f64,
    z: f64,
}

struct Setup {
    hull0: (f64, f64, Vector2),
    vmax: f64,
    radius: f64,
    tighten: f64,
    accel: f64,
    reverse: f64,
    hp: f64,
    spare: f64,
    horizon: f64,
    dt: f64,
    step_deg: f64,
    shooters: Vec<Shooter>,
    weapons: Vec<Weapon>,
    goal: f64,
    goal_w: f64,
    w_deal: f64,
    then: (f64, bool, f64),
}

impl Setup {
    fn read(o: &VarDictionary) -> Self {
        let pos = get::<Vector2>(o, "pos").unwrap_or(Vector2::ZERO);
        let vmax = get_f(o, "vmax", 1.0).max(1.0);
        let shooters: Vec<Shooter> = get::<AnyArray>(o, "shooters").iter().flat_map(|a| a.iter_shared())
            .filter_map(|v| v.try_to::<VarDictionary>().ok()).map(|d| Shooter::read(&d)).collect();
        let mut weapons = Vec::new();
        if let Some(target) = get::<Vector2>(o, "target") {
            let reload = get_f(o, "reload_s", 10.0).max(0.1);
            let ready = get::<PackedFloat32Array>(o, "gun_ready").unwrap_or_default();
            weapons = load_weapons(get(o, "guns"), target, pos, ready.as_slice(), 0.0, reload, get_f(o, "traverse", 0.0).to_radians());
            let salvo = get_f(o, "out_dps", 0.0) * reload / weapons.len().max(1) as f64;
            weapons.iter_mut().for_each(|w| w.salvo = salvo);
        }
        if let Some(tube_at) = get::<Vector2>(o, "tube_target") {
            weapons.extend(load_weapons(get(o, "tubes"), tube_at, pos, &[], get_f(o, "tube_value", 0.0), f64::INFINITY, f64::INFINITY));
        }
        // Underway, the goal is the route; on station, away from the guns on us.
        let route = get_f(o, "route", f64::INFINITY);
        let (goal, goal_w) = if route.is_finite() {
            (route, get_f(o, "w_progress", 0.1))
        } else {
            let total: f64 = shooters.iter().map(|s| s.weight).sum::<f64>().max(1e-6);
            let (sx, sz) = shooters.iter().fold((0.0, 0.0), |(x, z), s| (x + s.weight * s.bearing.sin(), z + s.weight * s.bearing.cos()));
            ((-sx).atan2(-sz), get_f(o, "w_closing", 0.05) * (sx * sx + sz * sz).sqrt() / total)
        };
        Setup {
            hull0: (get_f(o, "heading", 0.0), get_f(o, "v", 0.0), pos),
            vmax,
            radius: get_f(o, "radius", 500.0).max(1.0),
            tighten: get_f(o, "tighten", 1.0),
            accel: vmax / get_f(o, "spool", 10.0).max(0.1),
            reverse: get_f(o, "reverse", 0.5),
            hp: get_f(o, "hp", 1.0).max(1.0),
            spare: get_f(o, "spare", 0.0),
            horizon: get_f(o, "horizon", 60.0),
            dt: get_f(o, "dt", 3.0).max(0.1),
            step_deg: get_f(o, "aspect_step", 5.0).max(0.1),
            shooters,
            weapons,
            goal,
            goal_w,
            w_deal: get_f(o, "w_deal", 1.0 / 3.0),
            then: (get_f(o, "then_heading", 0.0), get_f(o, "then_astern", 0.0) != 0.0, get_f(o, "then_at", f64::INFINITY)),
        }
    }

    fn step(&self, hull: &mut Hull, want: f64, astern: bool) {
        let target_v = if astern { -self.vmax * self.reverse } else { self.vmax };
        let dv = self.accel * self.dt;
        hull.v = if hull.v < target_v { (hull.v + dv).min(target_v) } else { (hull.v - dv).max(target_v) };
        let r = self.radius * (self.tighten + (1.0 - self.tighten) * (hull.v.abs() / self.vmax).clamp(0.0, 1.0));
        let max_turn = hull.v.abs() / r * self.dt;
        hull.hdg = wrapf(hull.hdg + diff(hull.hdg, want).clamp(-max_turn, max_turn), -PI, PI);
        hull.x += hull.hdg.sin() * hull.v * self.dt;
        hull.z += hull.hdg.cos() * hull.v * self.dt;
    }

    /// Progress toward the goal plus a third of HP dealt, less HP lost for good, in shares of our HP.
    fn score(&self, heading: f64, astern: bool) -> f64 {
        let (h0, v0, p0) = self.hull0;
        let mut hull = Hull { v: v0, hdg: h0, x: p0.x as f64, z: p0.y as f64 };
        let mut states: Vec<(f64, f64)> = self.weapons.iter().map(|w| w.start).collect();
        let (mut taken, mut healable, mut dealt, mut gain) = (0.0, 0.0, 0.0, 0.0);
        let mut t = 0.0;
        while t < self.horizon {
            let (want, back) = if t >= self.then.2 { (self.then.0, self.then.1) } else { (heading, astern) };
            self.step(&mut hull, want, back);
            for s in &self.shooters {
                let (d, h) = s.landing(t, self.dt, hull.hdg, self.step_deg);
                taken += d;
                healable += h;
            }
            for (w, st) in self.weapons.iter().zip(states.iter_mut()) {
                dealt += w.fire(st, t, self.dt, (hull.x, hull.z), diff(h0, hull.hdg));
            }
            gain += hull.v * diff(hull.hdg, self.goal).cos() * self.dt;
            t += self.dt;
        }
        // Repairable damage past the repair party's spare capacity is lost for good too.
        let lost = taken - healable + (healable - self.spare).max(0.0);
        self.goal_w * gain / (self.vmax * self.horizon) + (self.w_deal * dealt - lost) / self.hp
    }
}

/// SkillStance's look-ahead: sails each candidate (heading, gear) for a
/// horizon at the hull's spool and turn rate, switching to then_heading at
/// then_at, with each enemy's salvos landing on its own clock at the aspect
/// shown then, and our guns and loaded tubes firing when they bear and are ready.
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
    /// horizon, dt, w_progress, w_closing, w_deal; then_heading, then_astern,
    /// then_at; target, guns, gun_ready, reload_s, traverse, out_dps; tubes,
    /// tube_target, tube_value. Returns one score per (headings[i], astern[i]).
    #[func]
    fn evaluate(opts: VarDictionary, headings: PackedFloat32Array, astern: PackedByteArray) -> PackedFloat32Array {
        let setup = Setup::read(&opts);
        headings.as_slice().iter().enumerate()
            .map(|(k, &h)| setup.score(h as f64, astern.as_slice().get(k).is_some_and(|&b| b != 0)) as f32)
            .collect()
    }
}
