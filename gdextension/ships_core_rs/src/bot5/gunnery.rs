use godot::classes::{PhysicsDirectSpaceState3D, Resource};
use godot::prelude::*;
use std::collections::HashMap;

use super::snapshot::{rot_y, ShipState};
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::nav::map::NavigationMap;
use crate::projectile::manager::point_store::Store;
use crate::variant_cast::VariantCast;

const AMMO_SWITCH_MARGIN: f32 = 1.15;
const AMMO_HOLD_S: f64 = 6.0;
const SALVO_SYNC_SHARE: f32 = 0.3;
const IMPACT_TURN_FADE_S: f32 = 10.0;
const ARC_CACHE_S: f64 = 0.5;
const ARC_CACHE_M: f32 = 50.0;
const ALLY_TOP_MARGIN_M: f32 = 10.0;
const ALLY_SIDE_MARGIN_M: f32 = 10.0;

#[derive(Default, Clone)]
pub struct PairTables {
    pub keys: [Option<String>; 2],
    pub raw_fire: [f32; 2],
}

#[derive(Default, Clone)]
pub struct TargetLive {
    pub sat: i64,
    pub fires: Vec<(Vector3, bool)>,
    pub fire_k: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct Aim {
    pub target: i64,
    pub world: Vector3,
    pub offset_local: Vector3,
    pub tof_game: f32,
    pub ammo: usize,
    pub value: f32,
    pub range: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Clear {
    Ok,
    Terrain,
    Friendly(i64),
}

impl Clear {
    pub fn name(self) -> &'static str {
        match self {
            Clear::Ok => "ok",
            Clear::Terrain => "terrain",
            Clear::Friendly(_) => "friendly",
        }
    }
}

#[derive(Clone, Copy, Default)]
pub struct Best {
    pub value: f32,
    pub offset: Vector3,
}

pub struct Gunnery {
    pub shells: [Option<Gd<Resource>>; 2],
    pub damage: [f32; 2],
    pub reload: f32,
    pub pairs: HashMap<i64, PairTables>,
    pub ammo: usize,
    ammo_since: f64,
    pub aim: Option<Aim>,
    sync_since: f64,
    pub gun_h: f32,
    arc: Option<(f64, Vector3, Clear)>,
}

impl Gunnery {
    pub fn new(shells: [Option<Gd<Resource>>; 2], damage: [f32; 2], reload: f32, gun_h: f32) -> Self {
        let ammo = if shells[0].is_some() { 0 } else { 1 };
        Gunnery { shells, damage, reload, pairs: HashMap::new(), ammo, ammo_since: f64::NEG_INFINITY, aim: None, sync_since: f64::INFINITY, gun_h, arc: None }
    }

    pub fn shell(&self, ammo: usize) -> Option<&Gd<Resource>> {
        self.shells[ammo].as_ref()
    }

    /// Main battery flight time in game seconds to `to`, ignoring lead.
    pub fn flight_time(&self, from: Vector3, to: Vector3, time_mult: f64) -> Option<f32> {
        let shell = self.shell(self.ammo)?;
        let r = ProjectilePhysicsWithDragV2::calculate_leading_launch_vector_impl(from, to, Vector3::ZERO, shell);
        let t = r.get(1)?.to_f64();
        (t > 0.0).then(|| (t / time_mult.max(1e-6)) as f32)
    }

    /// Table lookup in the target's predicted frame at impact; None = no table or bucket yet.
    pub(crate) fn best(&self, store: &Store, me: &ShipState, t: &ShipState, live: &TargetLive, ammo: usize, tof_game: f32) -> Option<Best> {
        let pair = self.pairs.get(&t.id)?;
        let key = pair.keys[ammo].as_ref()?;
        let table = store.read().ok()?.get(key).cloned()?;
        let turn = t.yaw_rate * IMPACT_TURN_FADE_S * (1.0 - (-tof_game / IMPACT_TURN_FADE_S).exp());
        let pos = t.pos + t.vel * tof_game;
        let g = rot_y(me.pos - pos, -(t.rot + turn));
        let range = Vector2::new(g.x, g.z).length() as f64;
        let aspect = (g.x.abs() as f64).atan2(-g.z as f64).to_degrees();
        let raw = pair.raw_fire[ammo] as f64;
        let fire_k = if raw > 0.0 { live.fire_k as f64 } else { 0.0 };
        let g2 = table.read().ok()?;
        let b = g2.best(range, aspect, live.sat, self.damage[ammo] as f64, raw, fire_k, &live.fires)?;
        let mut off = g2.points[b.point];
        off.x *= if g.x < 0.0 { -1.0 } else { 1.0 };
        Some(Best { value: b.value as f32, offset: off })
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn solve(&mut self, store: &Store, me: &ShipState, t: &ShipState, live: &TargetLive, now: f64, time_mult: f64,
            reads_turns: bool) -> Result<Aim, &'static str> {
        let tof0 = self.flight_time(me.pos, t.pos, time_mult).ok_or("no_solution")?;
        let mut opts: [Option<Best>; 2] = [None, None];
        for (ammo, o) in opts.iter_mut().enumerate() {
            if self.shells[ammo].is_some() {
                *o = self.best(store, me, t, live, ammo, tof0);
            }
        }
        let pick = match (opts[0], opts[1]) {
            (None, None) => return Err("no_table"),
            (Some(_), None) => 0,
            (None, Some(_)) => 1,
            (Some(a), Some(b)) => {
                let cur = self.ammo;
                let (vc, vo) = if cur == 0 { (a.value, b.value) } else { (b.value, a.value) };
                if vo > vc * AMMO_SWITCH_MARGIN && now - self.ammo_since >= AMMO_HOLD_S { 1 - cur } else { cur }
            }
        };
        if pick != self.ammo {
            self.ammo = pick;
            self.ammo_since = now;
        }
        let best = opts[pick].ok_or("no_table")?;
        let shell = self.shell(pick).ok_or("no_shell")?;
        let fwd = t.fwd();
        let yaw = if reads_turns { t.yaw_rate as f64 } else { 0.0 };
        let speeds = Vector2::new(-t.max_speed * t.reverse_ratio, t.max_speed);
        let off_world = t.to_world_dir(best.offset);
        let r = ProjectilePhysicsWithDragV2::calculate_leading_launch_vector_motion_impl(
            me.pos, t.pos, off_world, fwd, t.speed() as f64, yaw, Vector3::new(0.0, 0.0, f32::INFINITY), speeds, time_mult, shell);
        let world = r.get(2).and_then(|v| v.try_to::<Vector3>().ok()).ok_or("no_solution")?;
        let tof = r.get(1).map_or(-1.0, |v| v.to_f64());
        Ok(Aim {
            target: t.id,
            world,
            offset_local: best.offset,
            tof_game: (tof / time_mult.max(1e-6)) as f32,
            ammo: pick,
            value: best.value,
            range: me.pos.distance_to(t.pos),
        })
    }

    /// Terrain via the native shell sim (stopped at the aim point), then allies predicted along the arc.
    #[allow(clippy::too_many_arguments)]
    pub fn clearance(&mut self, me: &ShipState, to: Vector3, now: f64, time_mult: f64, allies: &[ShipState],
            map: &Option<Gd<NavigationMap>>, space: &Option<Gd<PhysicsDirectSpaceState3D>>) -> Clear {
        if let Some((t, p, c)) = self.arc {
            if now - t < ARC_CACHE_S && p.distance_to(to) < ARC_CACHE_M {
                return c;
            }
        }
        let from = Vector3::new(me.pos.x, self.gun_h, me.pos.z);
        let c = match self.shell(self.ammo) {
            None => Clear::Terrain,
            Some(shell) => {
                let sol = ProjectilePhysicsWithDragV2::calculate_launch_vector_impl(from, to, shell);
                match (sol.get(0).and_then(|v| v.try_to::<Vector3>().ok()), sol.get(1).and_then(|v| v.try_to::<f64>().ok())) {
                    (Some(launch), Some(t)) if t > 0.0 => {
                        if ProjectilePhysicsWithDragV2::sim_can_shoot_over_terrain_impl(from, launch, t, shell,
                                map.clone(), space.clone(), VarArray::new(), None, false)
                                .get("terrain_blocked").is_some_and(|v| v.to::<bool>()) {
                            Clear::Terrain
                        } else {
                            let d = drag_of(shell);
                            allies.iter().find(|a| a.id != me.id && crosses(d, from, launch, t, time_mult, a))
                                .map_or(Clear::Ok, |a| Clear::Friendly(a.id))
                        }
                    }
                    _ => Clear::Terrain,
                }
            }
        };
        self.arc = Some((now, to, c));
        c
    }

    pub fn last_clear(&self) -> Option<Clear> {
        self.arc.map(|a| a.2)
    }

    /// Loaded guns wait up to SALVO_SYNC_SHARE of a reload for the rest, so turrets fire together.
    pub fn sync_hold(&mut self, now: f64, ready: i32, max_lag_s: f32) -> bool {
        if ready <= 0 || max_lag_s <= 0.0 || max_lag_s > SALVO_SYNC_SHARE * self.reload {
            self.sync_since = f64::INFINITY;
            return false;
        }
        self.sync_since = self.sync_since.min(now);
        now - self.sync_since < (SALVO_SYNC_SHARE * self.reload) as f64
    }
}

/// Whether the arc passes through ally `a`'s hull box where the ally will be when the shell gets there.
/// Arc height is concave, so its minimum over the hull's along-track extent is at an end.
fn crosses((beta, vt, tau): (f64, f64, f64), from: Vector3, launch: Vector3, tof: f64, time_mult: f64, a: &ShipState) -> bool {
    type P = ProjectilePhysicsWithDragV2;
    let (vx, vy, vz) = (launch.x as f64, launch.y as f64, launch.z as f64);
    let vh = (vx * vx + vz * vz).sqrt();
    let speed = (vh * vh + vy * vy).sqrt();
    if vh < 1e-6 {
        return false;
    }
    let (cos_t, sin_t, theta) = (vh / speed, vy / speed, vy.atan2(vh));
    let dir = Vector2::new((vx / vh) as f32, (vz / vh) as f32);
    let lat = Vector2::new(-dir.y, dir.x);
    let end = P::horizontal_position(cos_t, tof, speed, beta) as f32;
    let o = Vector2::new(from.x, from.z);
    let game_s = |d: f32| (P::time_from_x(d.max(0.0) as f64, theta, speed, beta) / time_mult.max(1e-6)) as f32;
    let mut c = a.p2();
    for _ in 0..2 {
        let d = (c - o).dot(dir).clamp(0.0, end);
        let v = Vector2::new(a.vel.x, a.vel.z);
        c = a.p2() + v * game_s(d);
    }
    let f = Vector2::new(a.fwd().x, a.fwd().z);
    let (sa, ca) = (f.dot(lat).abs(), f.dot(dir).abs());
    let half_w = 0.5 * (a.length * sa + a.beam * ca) + ALLY_SIDE_MARGIN_M;
    let half_d = 0.5 * (a.length * ca + a.beam * sa);
    if (c - o).dot(lat).abs() > half_w {
        return false;
    }
    let d = (c - o).dot(dir);
    let (d0, d1) = ((d - half_d).max(0.0), (d + half_d).min(end));
    if d0 >= d1 {
        return false;
    }
    let top = a.pos.y + a.top + ALLY_TOP_MARGIN_M - from.y;
    [d0, d1].iter().any(|&x| {
        let t = P::time_from_x(x as f64, theta, speed, beta);
        (P::vertical_position(sin_t, t, speed, vt, tau) as f32) < top
    })
}

fn drag_of(shell: &Gd<Resource>) -> (f64, f64, f64) {
    ProjectilePhysicsWithDragV2::extract_params(shell).map_or((0.0, 0.0, 0.0), |(_, b, vt, tau)| (b, vt, tau))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bot5::snapshot::HullClass;

    const BETA: f64 = 2e-5;

    fn drag() -> (f64, f64, f64) {
        let vt = (9.81 / BETA).sqrt();
        (BETA, vt, vt / 9.81)
    }

    /// 805 m/s at `deg` elevation along +Z from the origin; returns (launch, tof to sea level).
    fn shot(deg: f64) -> (Vector3, f64) {
        let (_, vt, tau) = drag();
        let th = deg.to_radians();
        let mut t = 1.0;
        while ProjectilePhysicsWithDragV2::vertical_position(th.sin(), t, 805.0, vt, tau) > -5.0 {
            t += 0.01;
        }
        (Vector3::new(0.0, (805.0 * th.sin()) as f32, (805.0 * th.cos()) as f32), t)
    }

    fn ship(x: f32, z: f32, rot: f32, vel: Vector3) -> ShipState {
        ShipState { id: 2, team: 0, alive: true, pos: Vector3::new(x, 0.0, z), vel, rot, yaw_rate: 0.0, hp_frac: 1.0,
            hp_max: 1.0, seen: true, max_speed: 15.0, reverse_ratio: 0.5, length: 200.0, beam: 30.0, class: HullClass::Ca,
            gun_range: 15000.0, top: 15.0 }
    }

    fn range(launch: Vector3, tof: f64) -> f32 {
        let s = launch.length() as f64;
        ProjectilePhysicsWithDragV2::horizontal_position(launch.z as f64 / s, tof, s, BETA) as f32
    }

    #[test]
    fn ally_in_line_near_muzzle_blocks() {
        let (l, t) = shot(2.0);
        let from = Vector3::new(0.0, 5.0, 0.0);
        assert!(crosses(drag(), from, l, t, 1.0, &ship(0.0, 400.0, 0.0, Vector3::ZERO)));
        assert!(crosses(drag(), from, l, t, 1.0, &ship(0.0, 400.0, 1.57, Vector3::ZERO)));
        let (l8, t8) = shot(8.0);
        assert!(!crosses(drag(), from, l8, t8, 1.0, &ship(0.0, 600.0, 1.57, Vector3::ZERO)));
    }

    #[test]
    fn ally_near_impact_blocks_and_mid_arc_does_not() {
        let (l, t) = shot(8.0);
        let r = range(l, t);
        let from = Vector3::new(0.0, 5.0, 0.0);
        assert!(crosses(drag(), from, l, t, 1.0, &ship(0.0, r - 150.0, 1.57, Vector3::ZERO)), "r {r}");
        assert!(!crosses(drag(), from, l, t, 1.0, &ship(0.0, r * 0.5, 1.57, Vector3::ZERO)));
    }

    #[test]
    fn ally_off_line_or_past_aim_is_clear() {
        let (l, t) = shot(8.0);
        let r = range(l, t);
        let from = Vector3::new(0.0, 5.0, 0.0);
        assert!(!crosses(drag(), from, l, t, 1.0, &ship(150.0, 400.0, 0.0, Vector3::ZERO)));
        assert!(!crosses(drag(), from, l, t, 1.0, &ship(0.0, r + 300.0, 1.57, Vector3::ZERO)));
    }

    #[test]
    fn moving_ally_predicted_into_the_line() {
        let (l, t) = shot(8.0);
        let r = range(l, t);
        let from = Vector3::new(0.0, 5.0, 0.0);
        let d = r - 150.0;
        let s = l.length() as f64;
        let arrive = ProjectilePhysicsWithDragV2::time_from_x(d as f64, (l.y as f64).atan2(l.z as f64), s, BETA) as f32;
        let x0 = 15.0 * arrive;
        assert!(crosses(drag(), from, l, t, 1.0, &ship(x0, d, 1.57, Vector3::new(-15.0, 0.0, 0.0))), "x0 {x0}");
        assert!(!crosses(drag(), from, l, t, 1.0, &ship(x0, d, 1.57, Vector3::ZERO)));
    }
}
