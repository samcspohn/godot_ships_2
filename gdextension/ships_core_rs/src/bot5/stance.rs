//! Hull heading and gear under fire. See doc/BOT_V5_DESIGN.md "Stance".

use godot::prelude::*;
use std::f32::consts::{PI, TAU};

use crate::nav::navigator::hull::{rudder_to_heading, Hull};
use crate::nav::types::ShipParams;

pub const BINS: usize = 72;
const BIN: f32 = TAU / BINS as f32;
/// Off the route bearing a heading may lie and still make way.
pub const CONE: f32 = PI / 4.0;
/// Seconds a chosen heading is priced over, its swing included.
const HOLD_S: f32 = 30.0;
/// A new heading or gear must beat the held one by this share of its cost.
const SWITCH: f32 = 0.1;
/// HP share; below it the difference is noise.
const SWITCH_ABS: f32 = 0.002;
pub const GEAR_HOLD_S: f64 = 8.0;
const ROLL_DT: f32 = 0.5;
/// The turn is over once the bow is this close to the heading ahead.
const TURN_DONE: f32 = 2.0 * BIN;
const TURN_MAX_S: f32 = 300.0;
pub const HOLD_POWER: f32 = 0.25;
/// Turn rate floor as a share of top speed: a stopped hull still gathers way while it swings.
const SWING_SPEED_FLOOR: f32 = 0.3;

pub fn wrap(a: f32) -> f32 {
    (a + PI).rem_euclid(TAU) - PI
}

pub fn bin(h: f32) -> usize {
    (h.rem_euclid(TAU) / BIN).round() as usize % BINS
}

pub fn heading_of(b: usize) -> f32 {
    wrap(b as f32 * BIN)
}

/// Navigator convention: 0 = +Z, π/2 = +X.
pub fn bearing(from: Vector2, to: Vector2) -> f32 {
    (to.x - from.x).atan2(to.y - from.y)
}

/// Per hull heading bin: HP share per minute coming in, going out, and in minus out.
#[derive(Clone)]
pub struct Rates {
    pub inc: [f32; BINS],
    pub out: [f32; BINS],
    pub net: [f32; BINS],
}

impl Default for Rates {
    fn default() -> Self {
        Rates { inc: [0.0; BINS], out: [0.0; BINS], net: [0.0; BINS] }
    }
}

impl Rates {
    /// A shooter at `bearing` whose rate depends on our aspect to it (degrees off the bow).
    pub fn add_threat(&mut self, bearing: f32, at_aspect: impl Fn(f32) -> f32) {
        let by: Vec<f32> = (0..=BINS / 2).map(|a| at_aspect(a as f32 * BIN.to_degrees())).collect();
        for b in 0..BINS {
            let rel = wrap(bearing - heading_of(b)).abs() / BIN;
            let (i, f) = (rel.floor() as usize, rel.fract());
            self.inc[b] += by[i.min(BINS / 2)] * (1.0 - f) + by[(i + 1).min(BINS / 2)] * f;
        }
    }

    /// Our fire on a target at `bearing`, by the share of mounts that bear at each heading.
    pub fn add_target(&mut self, bearing: f32, value: f32, mounts: &[u128]) {
        if mounts.is_empty() {
            return;
        }
        for b in 0..BINS {
            let rel = bin(bearing - heading_of(b));
            let n = mounts.iter().filter(|&&m| m >> rel & 1 != 0).count();
            self.out[b] += value * n as f32 / mounts.len() as f32;
        }
    }

    pub fn finish(&mut self) {
        for b in 0..BINS {
            self.net[b] = self.inc[b] - self.out[b];
        }
    }

    pub fn idle(&self) -> bool {
        self.inc.iter().chain(&self.out).all(|&v| v <= 0.0)
    }
}

/// Swing rate of the hull at its speed now, rad/s.
pub fn swing_rate(p: &ShipParams, speed: f32) -> f32 {
    speed.abs().max(SWING_SPEED_FLOOR * p.max_speed) / p.turning_circle_radius.max(1.0)
}

/// Best heading within `half` of `centre`, swinging from `from` at `omega`, priced over HOLD_S (HP share);
/// `keep` stays unless beaten by SWITCH.
pub fn best_in(r: &Rates, centre: f32, half: f32, from: f32, omega: f32, lag_s: f32, keep: Option<f32>) -> (f32, f32) {
    let cost = |h: f32| {
        let d = wrap(h - from);
        let steps = (d.abs() / BIN).round() as usize;
        let dt = BIN / omega.max(1e-3);
        let mut c = r.net[bin(from)] * lag_s;
        let mut t = lag_s;
        for s in 1..=steps {
            c += r.net[bin(from + d.signum() * s as f32 * BIN)] * dt;
            t += dt;
        }
        (c + r.net[bin(h)] * (HOLD_S - t).max(0.0)) / 60.0
    };
    let n = (half / BIN).round() as i32;
    let mut best = (centre, f32::INFINITY);
    for k in -n..=n {
        let h = wrap(centre + k as f32 * BIN);
        let c = cost(h);
        if c < best.1 {
            best = (h, c);
        }
    }
    if let Some(h) = keep.filter(|&h| wrap(h - centre).abs() <= half + 1e-3) {
        let c = cost(h);
        if best.1 > c - SWITCH * c.abs() - SWITCH_ABS {
            return (h, c);
        }
    }
    best
}

/// HP share of what we have now lost while the hull turns onto `ahead` at full power from `h0`, until the bow
/// is within TURN_DONE of it or TURN_MAX_S; `risk` taken back out of the rates.
pub fn turn_loss(p: &ShipParams, h0: Hull, r: &Rates, ahead: f32, risk: f32) -> f32 {
    let mut h = h0;
    let (mut loss, mut t) = (0.0, 0.0);
    while t < TURN_MAX_S && wrap(ahead - h.heading).abs() > TURN_DONE {
        h.step(p, rudder_to_heading(&h, p, ahead, false), 1.0, ROLL_DT);
        loss += r.inc[bin(h.heading)] * ROLL_DT / 60.0;
        t += ROLL_DT;
    }
    loss / risk.max(1e-3)
}

/// Back toward a station behind only when the turn would sink us.
pub fn veto(p: &ShipParams, h0: Hull, r: &Rates, ahead: f32, risk: f32) -> (bool, f32) {
    let loss = turn_loss(p, h0, r, ahead, risk);
    (loss >= 1.0, loss)
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Stance {
    pub active: bool,
    pub heading: f32,
    pub astern: bool,
    pub gear_at: f64,
    /// HP share the last priced turn would cost.
    pub turn_loss: f32,
    pub holding: bool,
    pub why: &'static str,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> ShipParams {
        ShipParams {
            turning_circle_radius: 800.0,
            rudder_response_time: 10.0,
            acceleration_time: 40.0,
            max_speed: 30.0,
            turn_speed_loss: 0.4,
            linear_drag: 0.1,
            ship_length: 250.0,
            ship_beam: 35.0,
            ..ShipParams::default()
        }
    }

    /// Bow-on is cheap, broadside dear: the curve shape every hull shares.
    fn bow_cheap(a: f32) -> f32 {
        0.1 + 0.9 * a.to_radians().sin()
    }

    #[test]
    fn bins_round_trip() {
        for b in 0..BINS {
            assert_eq!(bin(heading_of(b)), b);
        }
        assert_eq!(bin(-BIN), BINS - 1);
        assert!((bearing(Vector2::ZERO, Vector2::new(1.0, 0.0)) - PI / 2.0).abs() < 1e-6);
    }

    #[test]
    fn threat_aspect_is_relative_to_bow() {
        let mut r = Rates::default();
        r.add_threat(PI / 2.0, bow_cheap);
        assert!((r.inc[bin(PI / 2.0)] - 0.1).abs() < 1e-4);
        assert!((r.inc[bin(-PI / 2.0)] - 0.1).abs() < 1e-3);
        assert!((r.inc[bin(0.0)] - 1.0).abs() < 1e-4);
    }

    #[test]
    fn target_share_counts_bearing_mounts() {
        let arc = |lo: f32, hi: f32| (0..BINS).filter(|&b| (lo..=hi).contains(&heading_of(b).abs().to_degrees())).fold(0u128, |m, b| m | 1 << b);
        let mut r = Rates::default();
        r.add_target(0.0, 1.0, &[arc(0.0, 150.0), arc(30.0, 180.0)]);
        assert!((r.out[bin(0.0)] - 0.5).abs() < 1e-6);
        assert!((r.out[bin(PI / 2.0)] - 1.0).abs() < 1e-6);
        assert!((r.out[bin(PI)] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn cone_picks_angle_toward_threat() {
        let mut r = Rates::default();
        r.add_threat(0.0, |a| bow_cheap(a) + 0.2 * a / 180.0);
        r.finish();
        let (h, _) = best_in(&r, PI / 2.0, CONE, PI / 2.0, 1.0, 0.0, None);
        assert!((h - PI / 4.0).abs() < 1e-3, "{h}");
    }

    #[test]
    fn keep_holds_against_small_gains() {
        let mut r = Rates::default();
        r.add_threat(0.0, |a| 1.0 + 0.001 * a);
        r.finish();
        let keep = PI / 2.0 - 2.0 * BIN;
        let (h, _) = best_in(&r, PI / 2.0, CONE, keep, 0.02, 0.0, Some(keep));
        assert!((h - keep).abs() < 1e-6);
    }

    fn hull(heading: f32, speed: f32, power: f32) -> Hull {
        Hull { pos: Vector2::ZERO, vel: Vector2::new(heading.sin(), heading.cos()) * speed, heading, yaw: 0.0, rudder: 0.0, power }
    }

    #[test]
    fn turns_unless_the_turn_sinks_us() {
        let p = params();
        let mut light = Rates::default();
        light.add_threat(0.0, |a| 0.2 * bow_cheap(a));
        light.finish();
        let (astern, loss) = veto(&p, hull(0.0, 0.0, 0.0), &light, PI, 1.0);
        assert!(!astern && loss > 0.0 && loss < 1.0, "{loss}");
        let mut heavy = Rates::default();
        heavy.add_threat(0.0, |a| 5.0 * bow_cheap(a));
        heavy.finish();
        assert!(veto(&p, hull(0.0, 0.0, 0.0), &heavy, PI, 1.0).0);
    }

    #[test]
    fn slower_swing_costs_more() {
        let p = params();
        let slow = ShipParams { turning_circle_radius: 2.0 * p.turning_circle_radius, ..p };
        let mut r = Rates::default();
        r.add_threat(0.0, bow_cheap);
        r.finish();
        let h0 = hull(0.0, 0.0, 0.0);
        let (a, b) = (turn_loss(&slow, h0, &r, PI, 1.0), turn_loss(&p, h0, &r, PI, 1.0));
        assert!(a > b, "slow {a} fast {b}");
    }

    #[test]
    fn risk_is_taken_out_of_the_loss() {
        let p = params();
        let mut r = Rates::default();
        r.add_threat(0.0, bow_cheap);
        r.finish();
        let one = turn_loss(&p, hull(0.0, 0.0, 0.0), &r, PI, 1.0);
        let two = turn_loss(&p, hull(0.0, 0.0, 0.0), &r, PI, 2.0);
        assert!((one - 2.0 * two).abs() < 1e-5);
    }
}
