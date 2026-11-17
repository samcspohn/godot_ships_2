//! Shell dodge: enemy shells in the air sailed against rudder/throttle candidates on the navigator's hull model.

use std::collections::HashSet;
use std::f32::consts::PI;

use godot::prelude::*;

use super::stance::{wrap, CONE};
use crate::combat::stance::shell_hit;
use crate::nav::map::NavigationMap;
use crate::nav::navigator::hull::{rudder_to_heading, Hull};
use crate::nav::types::ShipParams;
use crate::projectile::manager::ShellLandingEntry;

pub const QUERY_M: f32 = 1500.0;
/// Aspect rows run 0..180° in this many steps.
pub const ASPECTS: usize = 37;
const DT: f32 = 0.25;
const LAND_EVERY: usize = 4;
const HORIZON_MAX_S: f32 = 20.0;
const HOLDS: [f32; 7] = [0.0, 1.0, 2.0, 3.0, 4.0, 6.0, 99.0];
const LEVELS: [i32; 5] = [4, 3, 2, 0, -1];
const REF_CAL: f64 = 300.0;
const CIT_W: f64 = 3.0;
const TOP_K: f32 = 2.0;
/// Per radian off the lie and per unit of engine power changed, in caliber³ shell weights.
const OFF_W: f64 = 0.3;
const GEAR_W: f64 = 0.2;
const MIN_GAIN: f64 = 0.5;

pub fn power(level: i32) -> f32 {
    [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0][(level.clamp(-1, 4) + 1) as usize]
}

/// Full rudder to `side` until `turn_until`, then steered back to the lie; `level` throughout, until `until`.
#[derive(Clone, Copy, Debug)]
pub struct Plan {
    pub side: f32,
    pub turn_until: f64,
    pub level: i32,
    pub until: f64,
    pub kind: &'static str,
}

impl Plan {
    pub fn rudder(&self, h: &Hull, p: &ShipParams, lie_h: f32, now: f64) -> f32 {
        if now < self.turn_until { self.side } else { rudder_to_heading(h, p, lie_h, self.level < 0) }
    }
}

#[derive(Default)]
pub struct Dodge {
    seen: HashSet<(i32, i64)>,
    until: f64,
    pub plan: Option<Plan>,
}

pub struct Ctx<'a> {
    pub p: &'a ShipParams,
    pub h0: Hull,
    pub hull: Rect2,
    pub cit: Rect2,
    pub top: f32,
    pub lie_h: f32,
    pub lie_level: i32,
    /// Bearing the ship must make way toward; None: free.
    pub route: Option<f32>,
    pub map: Option<&'a NavigationMap>,
    pub clearance: f32,
    /// Per shell, ASPECTS weights by degrees off our bow it arrives at; empty: all 1.
    pub aspect_w: &'a [f32],
}

fn key(e: &ShellLandingEntry, tr: f32, now: f64) -> (i32, i64) {
    (e.shell_id, ((now + tr as f64) * 2.0).round() as i64)
}

pub enum Check {
    Idle,
    Hold,
    Replan(Vec<(ShellLandingEntry, f32)>),
}

impl Dodge {
    pub fn check(&mut self, shells: Vec<(ShellLandingEntry, f32)>, now: f64) -> Check {
        let seen: HashSet<_> = shells.iter().map(|(e, tr)| key(e, *tr, now)).collect();
        let fresh = seen.iter().any(|k| !self.seen.contains(k));
        if !fresh && now < self.until {
            return Check::Hold;
        }
        self.seen = seen;
        if shells.is_empty() {
            self.until = f64::NEG_INFINITY;
            self.plan = None;
            return Check::Idle;
        }
        self.until = now + shells.iter().map(|(_, tr)| *tr as f64).fold(0.0, f64::max);
        Check::Replan(shells)
    }

    pub fn active(&self, now: f64) -> Option<Plan> {
        self.plan.filter(|p| now < p.until)
    }
}

struct Cand {
    hold: f32,
    side: f32,
    level: i32,
}

/// Best (side, hold, level) against `shells`, None when the lie does as well; plus (lie cost, pick cost).
pub fn plan(c: &Ctx, shells: &[(ShellLandingEntry, f32)]) -> (Option<(f32, f32, i32, &'static str)>, f64, f64) {
    let horizon = shells.iter().map(|(_, tr)| *tr).fold(0.0, f32::max).min(HORIZON_MAX_S);
    let n_h = (horizon / DT).ceil() as usize;
    let pack: Vec<f32> = shells.iter().flat_map(|(e, tr)| [e.landing_x, e.landing_z, e.landing_vx, e.landing_vz, *tr,
        e.threat_half_len, e.caliber]).collect();
    let n = shells.len();
    let mut at_step: Vec<Vec<usize>> = vec![Vec::new(); n_h + 1];
    for (j, (_, tr)) in shells.iter().enumerate() {
        if *tr <= horizon {
            at_step[((tr / DT).round() as usize).min(n_h)].push(j);
        }
    }
    let top = (c.top * TOP_K) as f64;
    let sail = |cand: Option<&Cand>| -> Option<(f64, f32)> {
        let mut h = c.h0;
        let mut cost = 0.0;
        let pw = power(cand.map_or(c.lie_level, |k| k.level));
        for s in 0..=n_h {
            for &j in &at_step[s] {
                cost += shell_hit(&pack[7 * j..7 * j + 7], j, &h, c.hull, c.cit, top, REF_CAL, CIT_W, c.aspect_w, n);
            }
            if s % LAND_EVERY == 0 {
                if let Some(m) = c.map {
                    if m.get_distance_impl(h.pos.x, h.pos.y) < c.clearance {
                        return None;
                    }
                }
            }
            if s == n_h {
                break;
            }
            let t = s as f32 * DT;
            let rudder = match cand {
                None => rudder_to_heading(&h, c.p, c.lie_h, pw < 0.0),
                Some(k) if t < k.hold => k.side,
                Some(_) => rudder_to_heading(&h, c.p, c.lie_h, pw < 0.0),
            };
            h.step(c.p, rudder, pw, DT);
        }
        Some((cost, h.heading))
    };
    let lie = sail(None);
    let cost0 = lie.map_or(f64::INFINITY, |l| l.0);
    let in_cone = |h: f32, level: i32| match c.route {
        None => true,
        Some(_) if level == 0 => false,
        Some(r) => wrap(r - if level < 0 { wrap(h + PI) } else { h }).abs() <= CONE + 1e-4,
    };
    let lie_pw = power(c.lie_level) as f64;
    let mut best: Option<(f64, f64, f32, f32, i32, &'static str)> = None;
    for hold in HOLDS {
        let sides: &[f32] = if hold == 0.0 { &[0.0] } else { &[-1.0, 1.0] };
        for &side in sides {
            for level in LEVELS {
                let k = Cand { hold, side, level };
                let Some((cost, out_h)) = sail(Some(&k)) else { continue };
                if !in_cone(out_h, level) {
                    continue;
                }
                let score = cost + OFF_W * wrap(out_h - c.lie_h).abs() as f64 + GEAR_W * (power(level) as f64 - lie_pw).abs();
                if best.is_none_or(|b| score < b.0) {
                    let kind = if level < 0 { "dodge_astern" } else if hold > 0.0 { "dodge_turn" } else if level > 0 { "dodge_forward" } else { "dodge_stop" };
                    best = Some((score, cost, side, hold, level, kind));
                }
            }
        }
    }
    match best {
        Some((score, cost, side, hold, level, kind)) if lie.is_none() || score <= cost0 - MIN_GAIN => (Some((side, hold, level, kind)), cost0, cost),
        _ => (None, cost0, cost0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> ShipParams {
        ShipParams { turning_circle_radius: 600.0, rudder_response_time: 6.0, acceleration_time: 30.0, max_speed: 16.0,
            turn_speed_loss: 0.3, linear_drag: 0.1, ship_length: 200.0, ship_beam: 25.0, reverse_speed_ratio: 0.5,
            ..ShipParams::default() }
    }

    fn shell(x: f32, z: f32, tr: f32, id: i32) -> (ShellLandingEntry, f32) {
        let e = ShellLandingEntry { shell_id: id, landing_x: x, landing_z: z, landing_vx: -400.0, landing_vz: 0.0,
            threat_half_len: 30.0, caliber: 406.0, ..Default::default() };
        (e, tr)
    }

    #[test]
    fn dodges_a_salvo_aimed_ahead() {
        let p = params();
        let h0 = Hull { pos: Vector2::ZERO, vel: Vector2::new(0.0, 15.0), heading: 0.0, yaw: 0.0, rudder: 0.0, power: 1.0 };
        let shells: Vec<_> = (0..6).map(|i| shell(0.0, 15.0 * 10.0 + (i as f32 - 2.5) * 15.0, 10.0, i)).collect();
        let c = Ctx { p: &p, h0, hull: Rect2::new(Vector2::new(-12.5, -100.0), Vector2::new(25.0, 200.0)),
            cit: Rect2::new(Vector2::new(-7.5, -50.0), Vector2::new(15.0, 100.0)), top: 10.0, lie_h: 0.0, lie_level: 4,
            route: None, map: None, clearance: 0.0, aspect_w: &[] };
        let (pick, cost0, cost) = plan(&c, &shells);
        assert!(cost0 > 1.0, "lie should be hit: {cost0}");
        assert!(pick.is_some() && cost < cost0, "{pick:?} {cost0} {cost}");
    }

    #[test]
    fn keeps_the_lie_when_shells_miss() {
        let p = params();
        let h0 = Hull { pos: Vector2::ZERO, vel: Vector2::new(0.0, 15.0), heading: 0.0, yaw: 0.0, rudder: 0.0, power: 1.0 };
        let shells = vec![shell(800.0, 0.0, 8.0, 1)];
        let c = Ctx { p: &p, h0, hull: Rect2::new(Vector2::new(-12.5, -100.0), Vector2::new(25.0, 200.0)),
            cit: Rect2::new(Vector2::new(-7.5, -50.0), Vector2::new(15.0, 100.0)), top: 10.0, lie_h: 0.0, lie_level: 4,
            route: None, map: None, clearance: 0.0, aspect_w: &[] };
        assert!(plan(&c, &shells).0.is_none());
    }
}
