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
    tof: f64,
    /// Spread of its fall of shot across and along its line of fire, metres.
    miss: (f64, f64),
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
            tof: get_f(d, "tof", 0.0),
            miss: (get_f(d, "miss_cross", 0.0), get_f(d, "miss_range", 0.0)),
        }
    }

    /// (landing time, damage, repairable part) of a salvo landing in [t, t + dt) on hull heading `hdg`.
    fn landing(&self, t: f64, dt: f64, hdg: f64, step_deg: f64) -> Option<(f64, f64, f64)> {
        let n = self.rows.len() / 2;
        let land = self.next + ((t - self.next) / self.reload).ceil().max(0.0) * self.reload;
        if n == 0 || land >= t + dt {
            return None;
        }
        let a = ((diff(hdg, self.bearing).abs().to_degrees() / step_deg).round() as usize).min(n - 1);
        let secs = self.weight * self.reload;
        Some((land, self.rows[a] as f64 * secs, self.rows[n + a] as f64 * secs))
    }

    /// Share of a salvo landing at `land` still on us, aimed a flight time
    /// earlier by leading our velocity then; `track` holds each step's start.
    fn on_target(&self, land: f64, dt: f64, track: &[[f64; 4]], hull: &Hull, half_len: f64) -> f64 {
        if self.tof <= 0.0 || track.is_empty() {
            return 1.0;
        }
        let k = (((land - self.tof) / dt).floor().max(0.0) as usize).min(track.len() - 1);
        let [x, z, vx, vz] = track[k];
        let lead = land - k as f64 * dt;
        let [px, pz, ..] = track[track.len() - 1];
        let f = ((land - (track.len() - 1) as f64 * dt) / dt).clamp(0.0, 1.0);
        let dx = px + (hull.x - px) * f - (x + vx * lead);
        let dz = pz + (hull.z - pz) * f - (z + vz * lead);
        let (bs, bc) = self.bearing.sin_cos();
        let (along, cross) = (dx * bs + dz * bc, dx * bc - dz * bs);
        let a = diff(hull.hdg, self.bearing);
        let sc = self.miss.0.hypot(half_len * a.sin().abs()).max(1.0);
        let sr = self.miss.1.hypot(half_len * a.cos().abs()).max(1.0);
        (-0.5 * ((cross / sc).powi(2) + (along / sr).powi(2))).exp()
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
    /// Share of the full turn rate, swinging at the rudder's rate.
    rudder: f64,
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
    rudder_s: f64,
    yaw0: f64,
    half_len: f64,
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
    then: (f64, f64),
    /// On station: where to stay, how far it may drift free, and the cost of drifting further.
    anchor: Option<(Vector2, f64, f64)>,
    en_route: bool,
    /// Per half turn of the plan's heading change, in shares of our HP.
    w_turn: f64,
    /// For a full horizon broadside to `axis` (the danger bearing), in shares of our HP.
    w_present: f64,
    axis: Option<f64>,
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
            rudder_s: get_f(o, "rudder_s", 0.0).max(0.01),
            yaw0: get_f(o, "yaw_rate", 0.0),
            half_len: get_f(o, "half_length", 0.0),
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
            then: (get_f(o, "then_heading", 0.0), get_f(o, "then_at", f64::INFINITY)),
            en_route: route.is_finite(),
            w_turn: get_f(o, "w_turn", 0.0),
            w_present: get_f(o, "w_present", 0.0),
            axis: o.get("axis").map(|v| v.to::<f64>()).filter(|a| a.is_finite()),
            anchor: get::<Vector2>(o, "anchor").map(|a| (a, get_f(o, "leash", 500.0).max(1.0), get_f(o, "w_leash", 0.2))),
        }
    }

    /// `throttle`: share of full ahead, negative for astern.
    fn step(&self, hull: &mut Hull, want: f64, throttle: f64) {
        let target_v = if throttle < 0.0 { -self.vmax * self.reverse } else { self.vmax * throttle };
        let dv = self.accel * self.dt;
        hull.v = if hull.v < target_v { (hull.v + dv).min(target_v) } else { (hull.v - dv).max(target_v) };
        let max_turn = self.omega(hull.v) * self.dt;
        let want_r = if max_turn > 1e-6 { (diff(hull.hdg, want) / max_turn).clamp(-1.0, 1.0) } else { 0.0 };
        let dr = self.dt / self.rudder_s;
        let r0 = hull.rudder;
        hull.rudder += (want_r - r0).clamp(-dr, dr);
        hull.hdg = wrapf(hull.hdg + 0.5 * (r0 + hull.rudder) * max_turn, -PI, PI);
        hull.x += hull.hdg.sin() * hull.v * self.dt;
        hull.z += hull.hdg.cos() * hull.v * self.dt;
    }

    fn omega(&self, v: f64) -> f64 {
        v.abs() / (self.radius * (self.tighten + (1.0 - self.tighten) * (v.abs() / self.vmax).clamp(0.0, 1.0)))
    }

    /// Progress toward the goal plus a third of HP dealt, less HP lost for good, in shares of our HP.
    fn score(&self, heading: f64, throttle: f64) -> f64 {
        let (h0, v0, p0) = self.hull0;
        let w = self.omega(v0);
        let rudder = if w > 1e-6 { (self.yaw0 / w).clamp(-1.0, 1.0) } else { 0.0 };
        let mut hull = Hull { v: v0, hdg: h0, rudder, x: p0.x as f64, z: p0.y as f64 };
        let mut states: Vec<(f64, f64)> = self.weapons.iter().map(|w| w.start).collect();
        let mut track: Vec<[f64; 4]> = Vec::with_capacity((self.horizon / self.dt) as usize + 1);
        let (mut taken, mut healable, mut dealt, mut gain, mut drift, mut shown) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        let mut t = 0.0;
        while t < self.horizon {
            track.push([hull.x, hull.z, hull.hdg.sin() * hull.v, hull.hdg.cos() * hull.v]);
            let tail = t >= self.then.1;
            let gear = if tail && throttle > 0.0 && self.en_route { 1.0 } else { throttle };
            self.step(&mut hull, if tail { self.then.0 } else { heading }, gear);
            for s in &self.shooters {
                if let Some((land, d, h)) = s.landing(t, self.dt, hull.hdg, self.step_deg) {
                    // Only the committed leg dodges: a later turn is a promise the next plan may not keep.
                    let f = if land <= self.then.1 { s.on_target(land, self.dt, &track, &hull, self.half_len) } else { 1.0 };
                    taken += d * f;
                    healable += h * f;
                }
            }
            for (w, st) in self.weapons.iter().zip(states.iter_mut()) {
                dealt += w.fire(st, t, self.dt, (hull.x, hull.z), diff(h0, hull.hdg));
            }
            gain += hull.v * diff(hull.hdg, self.goal).cos() * self.dt;
            if let Some(axis) = self.axis {
                let a = diff(hull.hdg, axis).abs();
                shown += a.min(PI - a).sin() * self.dt;
            }
            if let Some((a, leash, _)) = self.anchor {
                let d = (hull.x - a.x as f64).hypot(hull.z - a.y as f64);
                drift += (d - leash).max(0.0) / leash * self.dt;
            }
            t += self.dt;
        }
        // Repairable damage past the repair party's spare capacity is lost for good too.
        let lost = taken - healable + (healable - self.spare).max(0.0);
        let leash_cost = self.anchor.map_or(0.0, |(_, _, w)| w * drift / self.horizon);
        // Turning and showing the side cost something even unseen: being spotted is a moment away.
        let turn_cost = self.w_turn * diff(h0, heading).abs() / PI;
        let show_cost = self.w_present * shown / self.horizon;
        -turn_cost - show_cost + self.goal_w * gain / (self.vmax * self.horizon) + (self.w_deal * dealt - lost) / self.hp - leash_cost
    }
}

/// Headings, every half degree, at which every turret bears on `target` from where the
/// ship is; returned as the edges of each such arc (the narrowest all-guns angles).
fn all_guns_edges(guns: Option<AnyArray>, target: Vector2, heading: f64) -> Vec<f32> {
    let t3 = Vector3::new(target.x, 0.0, target.y);
    let turrets: Vec<(f64, Turret)> = guns.iter().flat_map(|a| a.iter_shared())
        .filter_map(|g| g.try_to::<Gd<Node3D>>().ok())
        .map(Turret::load)
        .filter(|t| !t.is_disabled())
        .map(|t| (t.rot_y() + t.angle_to_target(t3), t))
        .collect();
    if turrets.is_empty() {
        return Vec::new();
    }
    const N: usize = 720;
    let step = TAU_F / N as f64;
    let ok: Vec<bool> = (0..N).map(|k| {
        let turned = -PI + k as f64 * step;
        turrets.iter().all(|(want, t)| t.in_fire_arcs(wrapf(want - turned, -PI, PI)))
    }).collect();
    (0..N).filter(|&k| ok[k] && (!ok[(k + N - 1) % N] || !ok[(k + 1) % N]))
        .map(|k| wrapf(heading - PI + k as f64 * step, -PI, PI) as f32)
        .collect()
}

const TAU_F: f64 = 2.0 * PI;

/// SkillStance's look-ahead: sails each candidate (heading, throttle) for a
/// horizon at the hull's spool and turn rate, turning to then_heading at then_at
/// (full ahead, or still astern), with each enemy's salvos landing on its own
/// clock at the aspect shown then, scaled by how far we are from where it led
/// us, and our guns and loaded tubes firing when they bear and are ready.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct StanceSim {
    base: Base<RefCounted>,
}

#[godot_api]
impl StanceSim {
    /// opts: heading, v, yaw_rate, vmax, radius, tighten, spool, reverse, rudder_s, half_length, hp, spare, pos,
    /// anchor, leash, w_leash (on station), shooters ([{bearing, rows, weight, reload, next, tof, miss_cross, miss_range}], rows = dps then
    /// repairable dps per aspect_step degrees off the bow), route (INF none),
    /// horizon, dt, w_progress, w_closing, w_deal; then_heading, then_at; target, guns, gun_ready, reload_s, traverse, out_dps; tubes,
    /// tube_target, tube_value, w_turn, w_present, axis. Returns one score per (headings[i], throttles[i]),
    /// throttle < 0 astern, 0 stopped.
    #[func]
    fn evaluate(opts: VarDictionary, headings: PackedFloat32Array, throttles: PackedFloat32Array) -> PackedFloat32Array {
        let setup = Setup::read(&opts);
        headings.as_slice().iter().enumerate()
            .map(|(k, &h)| setup.score(h as f64, throttles.as_slice().get(k).copied().unwrap_or(1.0) as f64) as f32)
            .collect()
    }

    /// The narrowest headings, each side, at which every live turret in `guns` bears on `target`.
    #[func]
    fn all_guns_headings(guns: AnyArray, target: Vector2, heading: f32) -> PackedFloat32Array {
        all_guns_edges(Some(guns), target, heading as f64).into_iter().collect()
    }
}
