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
const SIDE_SWITCH: f32 = 0.3;
pub const GEAR_HOLD_S: f64 = 8.0;
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
/// `keep` stays unless beaten by SWITCH. With `side_ref` (bearing to the target, else the nearest threat), headings
/// putting it off the `trained` beam (where the turrets point; else its beam now) must beat that beam's best by SIDE_SWITCH.
pub fn best_in(r: &Rates, centre: f32, half: f32, from: f32, omega: f32, lag_s: f32, keep: Option<f32>, side_ref: Option<f32>,
        trained: Option<f32>) -> (f32, f32) {
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
    let beam = |h: f32| side_ref.map_or(0.0, |s| wrap(s - h).signum());
    let now_side = if side_ref.is_some() { trained.unwrap_or_else(|| beam(from)) } else { 0.0 };
    let (mut best, mut other) = ((centre, f32::INFINITY), (centre, f32::INFINITY));
    for k in -n..=n {
        let h = wrap(centre + k as f32 * BIN);
        let c = cost(h);
        let slot = if now_side == 0.0 || beam(h) == now_side { &mut best } else { &mut other };
        if c < slot.1 {
            *slot = (h, c);
        }
    }
    if !best.1.is_finite() || other.1 < best.1 - SIDE_SWITCH * best.1.abs() - SWITCH_ABS {
        best = other;
    }
    if let Some(h) = keep.filter(|&h| wrap(h - centre).abs() <= half + 1e-3) {
        let c = cost(h);
        if best.1 > c - SWITCH * c.abs() - SWITCH_ABS {
            return (h, c);
        }
    }
    best
}

const ROLL_DT: f32 = 0.5;
const TURN_DONE: f32 = 2.0 * BIN;
const TURN_MAX_S: f32 = 300.0;

/// The committed rule: HP share lost while the hull turns onto `ahead`, over risk.
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

/// One enemy's fire on us, by where we are: `alpha` HP per main salvo at (range, degrees off our bow), `sec`
/// secondary HP/s at range, `lands` its shells reach a point; on its salvo clock; one torpedo spread arriving at
/// `torp.0` (HP bow-on, HP broadside). Weighted by the share of its aim we draw, uncalibrated; `on`: its shells are
/// landing on us.
pub struct Shooter<'a> {
    pub at: Vector2,
    pub on: bool,
    pub alpha: Box<dyn Fn(f32, f32) -> f32 + 'a>,
    pub sec: Box<dyn Fn(f32) -> f32 + 'a>,
    pub lands: Box<dyn Fn(Vector2) -> bool + 'a>,
    /// Seconds to its next landing; <= 0 loaded.
    pub next: f32,
    pub reload: f32,
    pub torp: Option<(f32, f32, f32)>,
}

/// Learned parts of `damage`: guns of ships on us, guns of the rest, secondaries, torpedoes.
pub const PARTS: usize = 4;
pub type Parts = [f32; PARTS];

pub fn dot(a: &Parts, b: &Parts) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

const PATH_DT: f32 = 1.0;
/// v4 ESCAPE_M: how far toward the goal both gears are sailed to compare.
const LEG_M: f32 = 3000.0;
const LEG_MAX_S: f32 = 300.0;
/// Backing must undercut the turn by this share: it costs what the price does not see.
const ASTERN_MARGIN: f32 = 0.3;

/// A plan sailed kinematically, a point per PATH_DT: (s, position, heading). Until `swing_end` the gear change and
/// the swing, then the leg toward the goal.
pub struct Path {
    pub pts: Vec<(f32, Vector2, f32)>,
    pub swing_end: f32,
}

impl Path {
    fn at(&self, t: f32) -> &(f32, Vector2, f32) {
        &self.pts[((t / PATH_DT).round() as usize).min(self.pts.len() - 1)]
    }

    pub fn end(&self) -> f32 {
        self.pts.last().map_or(0.0, |p| p.0)
    }
}

/// Speed `v0` to `v1` over `gear_s` on the heading held, a swing of `arc` over `swing_s` at `swing_v`, then
/// `leg_v` on `leg_h` until `want` is made along `goal` (both signed: negative is astern).
#[allow(clippy::too_many_arguments)]
fn sail(h0: &Hull, gear_s: f32, v1: f32, arc: f32, swing_s: f32, swing_v: f32, leg_h: f32, leg_v: f32, goal: Vector2, want: f32) -> Path {
    let fwd = |h: f32| Vector2::new(h.sin(), h.cos());
    let (mut t, mut pos, mut h) = (0.0, h0.pos, h0.heading);
    let v0 = h0.speed();
    let mut pts = vec![(0.0, pos, h)];
    let step = |t: &mut f32, pos: &mut Vector2, h: f32, v: f32, pts: &mut Vec<_>| {
        *pos += fwd(h) * v * PATH_DT;
        *t += PATH_DT;
        pts.push((*t, *pos, h));
    };
    while t < gear_s {
        let v = v0 + (v1 - v0) * (t / gear_s.max(1e-3));
        step(&mut t, &mut pos, h, v, &mut pts);
    }
    let start = t;
    while t < start + swing_s {
        h = wrap(h0.heading + arc * ((t - start + PATH_DT) / swing_s.max(1e-3)).min(1.0));
        step(&mut t, &mut pos, h, swing_v, &mut pts);
    }
    let swing_end = t;
    h = leg_h;
    while t < swing_end + LEG_MAX_S && (pos - h0.pos).dot(goal) < want {
        step(&mut t, &mut pos, h, leg_v, &mut pts);
    }
    Path { pts, swing_end }
}

/// HP landing along `path` by part, each enemy at our range and aspect to it there and only where its shells land:
/// through the swing, salvos on its clock (a loaded gun its best alpha of the points shown, a reloading one where it
/// lands, then each reload); on the leg its alpha per reload as a rate; secondaries throughout; a spread arriving
/// within the path. Second: the same through the swing alone.
pub fn damage(shooters: &[Shooter], path: &Path) -> (Parts, Parts) {
    let (mut all, mut swing) = ([0.0; PARTS], [0.0; PARTS]);
    let end = path.end();
    for g in shooters {
        let hit = |pt: &(f32, Vector2, f32)| -> Option<(f32, f32)> {
            (g.lands)(pt.1).then(|| (pt.1.distance_to(g.at), wrap(bearing(pt.1, g.at) - pt.2).abs().to_degrees()))
        };
        let alpha = |pt: &(f32, Vector2, f32)| hit(pt).map_or(0.0, |(d, a)| (g.alpha)(d, a));
        let gun = if g.on { 0 } else { 1 };
        if g.reload > 0.0 {
            let mut t = g.next.max(0.0);
            let mut sum = 0.0;
            if g.next <= 0.0 {
                sum += path.pts.iter().filter(|p| p.0 <= path.swing_end).map(&alpha).fold(0.0, f32::max);
                t += g.reload;
            }
            while t < path.swing_end {
                sum += alpha(path.at(t));
                t += g.reload;
            }
            swing[gun] += sum;
            all[gun] += sum + path.pts.iter().filter(|p| p.0 > path.swing_end).map(|p| alpha(p) / g.reload * PATH_DT).sum::<f32>();
        }
        for p in &path.pts {
            let s = hit(p).map_or(0.0, |(d, _)| (g.sec)(d)) * PATH_DT;
            all[2] += s;
            if p.0 <= path.swing_end {
                swing[2] += s;
            }
        }
        if let Some((at, bow, side)) = g.torp.filter(|t| t.0 < end) {
            let k = wrap(bearing(path.at(at).1, g.at) - path.at(at).2).sin().abs();
            all[3] += bow + (side - bow) * k;
            if at <= path.swing_end {
                swing[3] += bow + (side - bow) * k;
            }
        }
    }
    (all, swing)
}

pub struct Decision {
    /// Why it backs; None: it turns.
    pub why: Option<&'static str>,
    /// The turn's swing HP over hp.
    pub loss: f32,
    pub way: f32,
    /// The chosen plan's raw parts over `w`, for the stance probe.
    pub parts: Parts,
    pub w: f32,
}

fn swing_s(p: &ShipParams, arc: f32, speed: f32) -> f32 {
    arc.abs() / swing_rate(p, speed)
}

/// Turning onto `ahead` (either way) against backing onto `back`, each sailed until min(dist, LEG_M) is made toward
/// the goal: the gear change on the heading held (astern to SWING_SPEED_FLOOR ahead for a turn, to full astern for
/// backing), the swing, then full ahead or full astern. Priced by `damage` with the learned `k_turn` / `k_back`.
/// A turn whose swing alone sinks us, or a goal inside the turning circle a turn would orbit, backs.
#[allow(clippy::too_many_arguments)]
pub fn turn_or_astern(p: &ShipParams, h0: Hull, shooters: &[Shooter], ahead: f32, back: f32, goal_at: Vector2, hp: f32,
        k_turn: &Parts, k_back: &Parts) -> Decision {
    let vmax = p.max_speed.max(1.0);
    let v_rev = vmax * p.reverse_speed_ratio;
    let v = h0.speed();
    let gear_s = |dv: f32| dv.abs() / vmax * p.acceleration_time;
    let to = goal_at - h0.pos;
    let (goal, want) = (to.normalized_or_zero(), to.length().min(LEG_M));
    let arc = |to: f32, way: f32| {
        let d = wrap(to - h0.heading);
        if way == 0.0 || d.signum() == way { d } else { d + way * TAU }
    };
    let turn = |way: f32| {
        let (g, v1) = if v < 0.0 { (gear_s(SWING_SPEED_FLOOR * vmax - v), SWING_SPEED_FLOOR * vmax) } else { (0.0, v) };
        let a = arc(ahead, way);
        sail(&h0, g, v1, a, swing_s(p, a, v1), v1.max(SWING_SPEED_FLOOR * vmax), ahead, vmax, goal, want)
    };
    let a = arc(back, 0.0);
    let back_p = sail(&h0, gear_s(v + v_rev), -v_rev, a, swing_s(p, a, v_rev), -v_rev, back, -v_rev, goal, want);
    let (up, down) = (turn(1.0), turn(-1.0));
    let ((pu, su), (pd, sd), (pa, _)) = (damage(shooters, &up), damage(shooters, &down), damage(shooters, &back_p));
    let (du, dd, da) = (dot(&pu, k_turn), dot(&pd, k_turn), dot(&pa, k_back));
    let (way, dt, pt, st, tp) = if du <= dd { (1.0, du, pu, su, &up) } else { (-1.0, dd, pd, sd, &down) };
    let loss = dot(&st, k_turn) / hp.max(1.0);
    let r = p.turning_circle_radius;
    let f = Vector2::new(h0.heading.sin(), h0.heading.cos());
    let side = Vector2::new(f.y, -f.x) * r;
    let orbit = goal_at.distance_to(h0.pos + side) < r || goal_at.distance_to(h0.pos - side) < r;
    let why = if orbit { Some("astern_orbit") } else if loss >= 1.0 { Some("astern_swing") } else if da < dt * (1.0 - ASTERN_MARGIN) { Some("astern_cheaper") } else { None };
    let (parts, w) = if why.is_some() { (pa, back_p.end()) } else { (pt, tp.end()) };
    Decision { why, loss, way, parts, w }
}

/// v4 TURN_LEAD: the navigator swings the short way to a heading, so a turn priced the long way is led round.
pub const TURN_LEAD: f32 = PI / 2.0;

#[derive(Clone, Copy, Debug, Default)]
pub struct Stance {
    pub active: bool,
    pub heading: f32,
    pub astern: bool,
    pub gear_at: f64,
    /// HP share the last priced turn would cost.
    pub turn_loss: f32,
    pub turn_way: f32,
    pub why_astern: Option<&'static str>,
    /// A decision just priced: (raw parts, window s, astern), for the stance probe.
    pub probe: Option<(Parts, f32, bool)>,
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
        let (h, _) = best_in(&r, PI / 2.0, CONE, PI / 2.0, 1.0, 0.0, None, None, None);
        assert!((h - PI / 4.0).abs() < 1e-3, "{h}");
    }

    #[test]
    fn keep_holds_against_small_gains() {
        let mut r = Rates::default();
        r.add_threat(0.0, |a| 1.0 + 0.001 * a);
        r.finish();
        let keep = PI / 2.0 - 2.0 * BIN;
        let (h, _) = best_in(&r, PI / 2.0, CONE, keep, 0.02, 0.0, Some(keep), None, None);
        assert!((h - keep).abs() < 1e-6);
    }

    fn hull(heading: f32, speed: f32, power: f32) -> Hull {
        Hull { pos: Vector2::ZERO, vel: Vector2::new(heading.sin(), heading.cos()) * speed, heading, yaw: 0.0, rudder: 0.0, power }
    }

    fn gun<'a>(at: Vector2, next: f32) -> Shooter<'a> {
        Shooter { at, on: true, alpha: Box::new(|_, a| 1000.0 + 9000.0 * a.to_radians().sin()), sec: Box::new(|_| 0.0),
            lands: Box::new(|_| true), next, reload: 30.0, torp: None }
    }

    #[test]
    fn loaded_gun_takes_the_broadside_a_turn_shows() {
        let h0 = hull(0.0, 0.0, 0.0);
        let held = Path { pts: (0..=20).map(|t| (t as f32, Vector2::ZERO, 0.0)).collect(), swing_end: 20.0 };
        let turn = sail(&h0, 0.0, 0.0, PI, 20.0, 0.0, PI, 0.0, Vector2::ZERO, 0.0);
        let g = [gun(Vector2::new(0.0, 10000.0), 0.0)];
        assert!(damage(&g, &held).0[0] < 2000.0);
        assert!(damage(&g, &turn).0[0] > 9000.0);
        let reloading = [gun(Vector2::new(0.0, 10000.0), 19.0)];
        assert!(damage(&reloading, &turn).0[0] < 3000.0, "lands near stern-on at 19 s");
    }

    #[test]
    fn backing_is_charged_its_slower_leg() {
        let p = params();
        let h0 = hull(0.0, 0.0, 0.0);
        let g = [gun(Vector2::new(0.0, 10000.0), 0.0)];
        let far = Vector2::new(0.0, -3000.0);
        let d = turn_or_astern(&p, h0, &g, PI, 0.0, far, 1e7, &[1.0; 4], &[1.0; 4]);
        assert!(d.w > 0.0);
        assert_eq!(turn_or_astern(&p, hull(0.0, 20.0, 1.0), &g, PI, 0.0, Vector2::new(800.0, -200.0), 1e7, &[1.0; 4], &[1.0; 4]).why,
            Some("astern_orbit"));
        let none: [Shooter; 0] = [];
        assert!(turn_or_astern(&p, h0, &none, PI, 0.0, far, 1e7, &[1.0; 4], &[1.0; 4]).why.is_none());
    }

}
