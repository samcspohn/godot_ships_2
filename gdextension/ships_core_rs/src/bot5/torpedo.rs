use godot::prelude::*;
use std::collections::HashMap;
use std::f32::consts::FRAC_PI_2;

use crate::nav::map::NavigationMap;

use super::hive::wrap;
use super::snapshot::ShipState;

const SPEED_TAU_S: f32 = 5.0;
const YAW_TAU_S: f32 = 3.0;
const WIGGLE_TAU_S: f32 = 20.0;
const TURN_FADE_S: f32 = 30.0;
const PREDICT_DT: f32 = 0.5;
const TRACK_RESET_S: f64 = 2.0;
const SPREAD_MAX: f32 = 0.06;
const SPEED_DOUBT: f32 = 0.15;
const ROOM_STEPS: i32 = 4;
const PATH_PAST: f32 = 1.25;
pub const TUBE_STEP: f32 = 0.012;
const RANGE_USE: f32 = 0.95;
const ALLY_MARGIN_M: f32 = 500.0;
const ALLY_STEPS: i32 = 10;
const OFFSETS: [f32; 5] = [0.0, -1.0, 1.0, -2.0, 2.0];

/// `speed` is the in-world speed (TorpedoManager multiplier applied).
#[derive(Clone, Copy, Debug, Default)]
pub struct TorpSpec {
    pub speed: f32,
    pub range: f32,
    pub tubes: i32,
    pub detect: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct Track {
    speed: f32,
    heading: f32,
    yaw_rate: f32,
    wiggle: f32,
    at: f64,
}

/// Smoothed course over ground per spotted ship; a gap in sightings restarts it.
#[derive(Default)]
pub struct Tracks {
    map: HashMap<i64, Track>,
}

impl Tracks {
    pub fn update(&mut self, now: f64, ships: &[ShipState]) {
        self.map.retain(|id, _| ships.iter().any(|s| s.id == *id && s.alive));
        for s in ships.iter().filter(|s| s.alive && s.seen) {
            let v = Vector2::new(s.vel.x, s.vel.z);
            let speed = v.length();
            let h = if speed > 1.0 { v.x.atan2(v.y) } else { s.heading() };
            match self.map.get_mut(&s.id) {
                Some(t) if now - t.at <= TRACK_RESET_S => {
                    let dt = (now - t.at) as f32;
                    if dt > 0.0 {
                        let yaw = wrap(h - t.heading) / dt;
                        t.speed += (speed - t.speed) * (1.0 - (-dt / SPEED_TAU_S).exp());
                        t.yaw_rate += (yaw - t.yaw_rate) * (1.0 - (-dt / YAW_TAU_S).exp());
                        t.wiggle += (yaw.abs() - t.wiggle) * (1.0 - (-dt / WIGGLE_TAU_S).exp());
                    }
                    t.heading = h;
                    t.at = now;
                }
                _ => {
                    self.map.insert(s.id, Track { speed, heading: h, yaw_rate: 0.0, wiggle: s.yaw_rate.abs(), at: now });
                }
            }
        }
    }

    pub fn get(&self, id: i64) -> Option<&Track> {
        self.map.get(&id)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct TorpAim {
    pub target: i64,
    pub points: [Vector2; 5],
    pub n: usize,
    pub chance: f32,
    pub intercept: Vector2,
}

impl TorpAim {
    pub fn point(&self, idx: usize) -> Vector2 {
        self.points[idx % self.n.max(1)]
    }
}

/// Predicted (position, course) every PREDICT_DT: smoothed speed, turn rate fading by TURN_FADE_S.
struct Path {
    p: Vec<(Vector2, f32)>,
}

impl Path {
    fn new(p0: Vector2, tr: &Track, max_s: f32) -> Self {
        let n = (max_s / PREDICT_DT).ceil() as usize + 1;
        let mut p = Vec::with_capacity(n + 1);
        p.push((p0, tr.heading));
        for k in 0..n {
            let (q, h) = p[k];
            let hn = h + tr.yaw_rate * (-(k as f32) * PREDICT_DT / TURN_FADE_S).exp() * PREDICT_DT;
            p.push((q + Vector2::new(hn.sin(), hn.cos()) * tr.speed * PREDICT_DT, hn));
        }
        Path { p }
    }

    fn at(&self, s: f32) -> (Vector2, f32) {
        let f = (s / PREDICT_DT).max(0.0);
        let k = (f as usize).min(self.p.len() - 2);
        let (a, ha) = self.p[k];
        let (b, _) = self.p[k + 1];
        (a + (b - a) * (f - k as f32).min(1.0), ha)
    }
}

fn intercept(path: &Path, from: Vector2, speed: f32, max_s: f32) -> Option<f32> {
    let gap = |s: f32| path.at(s).0.distance_to(from) - speed * s;
    let (mut lo, mut hi) = (0.0f32, PREDICT_DT);
    while gap(hi) > 0.0 {
        lo = hi;
        hi *= 2.0;
        if hi > max_s * 2.0 {
            return None;
        }
    }
    for _ in 0..20 {
        let mid = (lo + hi) * 0.5;
        if gap(mid) > 0.0 { lo = mid } else { hi = mid }
    }
    (hi <= max_s).then_some(hi)
}

/// How far `t` can be from the prediction when the spread arrives: full-rudder turn once it can see the
/// torpedoes, its weaving before that, a throttle change over the run; at least a hull length.
fn envelope(t: &ShipState, tr: &Track, run_s: f32, spec: &TorpSpec) -> f32 {
    let r = t.turn_radius.max(1.0);
    let v = tr.speed.max(1.0);
    let seen_m = (spec.detect * t.torp_detect_mult).max(t.torp_detect_floor);
    let dodge_s = run_s.min(seen_m / spec.speed.max(1.0));
    let arc = |s: f32| r * (1.0 - (v * s / r).min(FRAC_PI_2).cos());
    let pre = (run_s - dodge_s).max(0.0);
    let turn = arc(dodge_s) + (0.25 * tr.wiggle * v * pre * pre).min(arc(pre));
    let throttle = SPEED_DOUBT * v * run_s;
    t.length.max(turn.hypot(throttle))
}

/// Room each way across the lane before land: (-lane, +lane), each at most `env`.
fn room(map: &NavigationMap, at: Vector2, lane: Vector2, env: f32, beam: f32) -> (f32, f32) {
    let mut out = [env, env];
    if map.get_distance_impl(at.x, at.y) < beam {
        return (env, env);
    }
    for (side, dir) in [(0usize, -1.0f32), (1, 1.0)] {
        for i in 1..=ROOM_STEPS {
            let p = at + lane * dir * env * i as f32 / ROOM_STEPS as f32;
            if map.get_distance_impl(p.x, p.y) < beam {
                out[side] = env * (i - 1) as f32 / ROOM_STEPS as f32;
                break;
            }
        }
    }
    (out[0], out[1])
}

/// One launch's chance on a ship spread over `width` across the lane: the fan widened by the hull's profile.
fn launch_chance(t: &ShipState, heading: f32, lane_angle: f32, dist: f32, width: f32, tubes: i32) -> f32 {
    let cross = wrap(heading - lane_angle).sin().abs();
    let profile = t.length * cross + t.beam * (1.0 - cross);
    let cover = (tubes - 1).max(0) as f32 * (TUBE_STEP * dist).min(profile) + profile;
    (cover / (width + profile)).min(1.0)
}

fn fan_blocked(map: &NavigationMap, from: Vector2, angle: f32, dist: f32, tubes: i32) -> bool {
    let half = TUBE_STEP * (tubes - 1).max(0) as f32 * 0.5;
    [angle - half, angle, angle + half].iter().any(|&a| {
        map.raycast_internal(from, from + Vector2::new(a.sin(), a.cos()) * dist, 0.0).hit
    })
}

fn hits_ally(from: Vector2, dir: Vector2, speed: f32, run_s: f32, allies: &[ShipState], me: i64) -> bool {
    allies.iter().filter(|a| a.id != me && a.alive).any(|a| {
        let av = Vector2::new(a.vel.x, a.vel.z);
        (0..=ALLY_STEPS).any(|i| {
            let s = run_s * PATH_PAST * i as f32 / ALLY_STEPS as f32;
            (from + dir * speed * s).distance_to(a.p2() + av * s) < ALLY_MARGIN_M
        })
    })
}

/// Spread of up to five aim points across where `t` can be at the intercept, centre first, land cut off.
/// `ready`: launchers loaded now, each taking one point.
pub fn solve(spec: &TorpSpec, ready: i32, from: Vector2, t: &ShipState, tr: &Track, allies: &[ShipState], me: i64,
        map: &NavigationMap) -> Result<TorpAim, &'static str> {
    let max_s = spec.range * RANGE_USE / spec.speed.max(1.0);
    let path = Path::new(t.p2(), tr, max_s);
    let s = intercept(&path, from, spec.speed, max_s).ok_or("torp_no_intercept")?;
    let (at, heading) = path.at(s);
    let to = at - from;
    let dist = to.length();
    if dist > spec.range * RANGE_USE {
        return Err("torp_out_of_range");
    }
    let lane = Vector2::new(to.y, -to.x) / dist.max(1.0);
    let env = envelope(t, tr, s, spec);
    let (lo, hi) = room(map, at, lane, env, t.beam);
    let base = to.x.atan2(to.y) + ((hi - lo) * 0.5).atan2(dist);
    let step = ((lo + hi) * 0.25).atan2(dist).min(SPREAD_MAX);
    let chance = (ready.max(0) as f32 * launch_chance(t, heading, base, dist, lo + hi, spec.tubes)).min(1.0);
    let mut aim = TorpAim { target: t.id, points: [Vector2::ZERO; 5], n: 0, chance, intercept: at };
    let mut why = "torp_land";
    for o in OFFSETS {
        let a = base + o * step;
        let dir = Vector2::new(a.sin(), a.cos());
        if fan_blocked(map, from, a, dist * PATH_PAST, spec.tubes) {
            continue;
        }
        if hits_ally(from, dir, spec.speed, s, allies, me) {
            why = "torp_friendly";
            continue;
        }
        aim.points[aim.n] = from + dir * dist;
        aim.n += 1;
    }
    if aim.n == 0 {
        return Err(why);
    }
    Ok(aim)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bot5::snapshot::HullClass;

    fn ship(id: i64, x: f32, z: f32, vel: Vector2) -> ShipState {
        ShipState { id, team: 1, alive: true, pos: Vector3::new(x, 0.0, z), vel: Vector3::new(vel.x, 0.0, vel.y), rot: 0.0,
            yaw_rate: 0.0, hp_frac: 1.0, hp_max: 1.0, seen: true, max_speed: 15.0, reverse_ratio: 0.5, length: 200.0,
            beam: 30.0, class: HullClass::Ca, gun_range: 15000.0, top: 15.0, turn_radius: 700.0, air_radius: 2500.0,
            torp_detect_mult: 1.0, torp_detect_floor: -1.0 }
    }

    #[test]
    fn intercept_on_straight_course() {
        let tr = Track { speed: 15.0, heading: FRAC_PI_2, yaw_rate: 0.0, wiggle: 0.0, at: 0.0 };
        let path = Path::new(Vector2::new(0.0, 6000.0), &tr, 200.0);
        let s = intercept(&path, Vector2::ZERO, 100.0, 200.0).unwrap();
        let (p, _) = path.at(s);
        assert!((p.length() - 100.0 * s).abs() < 2.0);
        assert!(p.x > 0.0);
    }

    #[test]
    fn ally_in_lane_blocks() {
        let ally = ship(7, 0.0, 2000.0, Vector2::ZERO);
        assert!(hits_ally(Vector2::ZERO, Vector2::new(0.0, 1.0), 100.0, 60.0, &[ally], 1));
        let off = ship(7, 3000.0, 2000.0, Vector2::ZERO);
        assert!(!hits_ally(Vector2::ZERO, Vector2::new(0.0, 1.0), 100.0, 60.0, &[off], 1));
    }

    #[test]
    fn envelope_grows_with_run() {
        let t = ship(2, 0.0, 0.0, Vector2::new(15.0, 0.0));
        let tr = Track { speed: 15.0, heading: 0.0, yaw_rate: 0.0, wiggle: 0.0, at: 0.0 };
        let spec = TorpSpec { speed: 100.0, range: 10000.0, tubes: 4, detect: 1000.0 };
        assert!(envelope(&t, &tr, 200.0, &spec) > envelope(&t, &tr, 30.0, &spec));
        assert!(envelope(&t, &tr, 1.0, &spec) >= t.length);
    }
}
