use godot::prelude::*;

use std::collections::{HashMap, HashSet};

use super::belief::Belief;
use super::params::{Aptitude, Style};
use super::snapshot::{ShipState, Snapshot};
use super::station::{Found, Req, WINDOW_M};

const HOLD_S: f64 = 20.0;
const ANCHOR_MOVE_M: f32 = 1200.0;
const TARGET_SWITCH: f32 = 1.25;
const TARGET_HOLD_S: f64 = 8.0;
/// Threat (v4's scale): disengage at or above, re-engage at or below; past FORCE the cooldown is waived.
pub const DISENGAGE_THREAT: f32 = 0.4;
/// Threat that starts a disengage regardless of the race (DISENGAGE_THREAT only calibrates the horizon).
const DISENGAGE_AT: f32 = 0.5;
pub const REENGAGE_THREAT: f32 = 0.35;
const DISENGAGE_FORCE_THREAT: f32 = 0.6;
const DISENGAGE_MIN_S: f64 = 20.0;
const DISENGAGE_COOLDOWN_S: f64 = 15.0;
/// Staying out, we must outlive the time to win by this.
pub const STAY_MARGIN: f32 = 1.25;
/// Full aggression shrinks the time to win a ship must outlive by e^this.
const AGGRESSION_STAY: f32 = 0.7;
const FOCUS_BONUS: f32 = 0.3;
/// A target our shells cannot clear terrain to from here keeps this share of its score.
const NO_SHOT_W: f32 = 0.2;
const HOLD_RADIUS_M: f32 = 400.0;
const HUNT_M: f32 = 3000.0;
/// Where a kite plan points until drive's per-tick kite takes over.
const KITE_LEG_M: f32 = 3000.0;
const BLOCKED_RELEASE_S: f32 = 3.0;
/// Guns blocked on the way are expected; only blocked at the station releases it.
const BLOCKED_AT_M: f32 = 1000.0;
const TORP_RUN_RANGE: f32 = 0.7;
/// Reloading, a torpedo boat waits this share of its torpedo range out.
const TORP_WAIT_RANGE: f32 = 0.9;
const TORP_RUN_LEAD: f32 = 0.7;
/// Shooting outside our flank is worth this share: taken when nothing of ours is in reach.
const OFF_FLANK_W: f32 = 0.4;
/// An expired station that still scores this share of what it did when set is held again without a search.
const HOLD_AGAIN: f32 = 0.75;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Posture {
    Engage,
    TorpRun,
    Disengage,
}

impl Posture {
    pub fn name(self) -> &'static str {
        match self {
            Posture::Engage => "engage",
            Posture::TorpRun => "torp_run",
            Posture::Disengage => "disengage",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Plan {
    pub posture: Posture,
    pub station: Vector2,
    pub anchor: Vector2,
    pub heading: f32,
    pub heading_weight: f32,
    pub hold_radius: f32,
    pub set_at: f64,
    pub hold_until: f64,
    pub serial: u32,
    /// Station checked navigable with a clear shot at the anchor.
    pub shot: bool,
    /// Station net when set (HP share per minute), to judge it again on expiry.
    pub score: f32,
    /// Hold fire: the station spots unseen.
    pub dark: bool,
    pub anchor_id: Option<i64>,
    /// Kiting: drive steers straight away from the guns on us each tick instead of to `station`.
    pub kite: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct Assignment {
    pub target: Option<i64>,
    pub target_since: f64,
    pub last_threat: f64,
    pub dis_since: f64,
    pub dis_left: f64,
    /// Our shells clear terrain to the target from where we are.
    pub clear: bool,
}

impl Default for Assignment {
    fn default() -> Self {
        Assignment { target: None, target_since: f64::NEG_INFINITY, last_threat: f64::NEG_INFINITY, dis_since: f64::NEG_INFINITY,
            dis_left: f64::NEG_INFINITY, clear: false }
    }
}

/// The enemies this bot answers for: belief contacts of its flank(s), and the nearest such group's centre.
pub struct FlankView {
    pub ids: HashSet<i64>,
    pub centre: Option<Vector2>,
}

/// What the hive knows about one bot when it resolves it.
pub struct Member<'a> {
    pub me: &'a ShipState,
    pub style: Style,
    pub apt: Aptitude,
    pub plan: Option<Plan>,
    pub assign: Assignment,
    /// Seconds the guns recently could not clear terrain to the target.
    pub blocked_s: f32,
    /// Torpedo range and whether any launcher is loaded.
    pub torp: Option<(f32, bool)>,
    pub flank: Option<FlankView>,
    pub danger: Danger,
    /// Per enemy, the range band its trade (or our spot role) holds us to.
    pub bands: HashMap<i64, (f32, f32)>,
    /// Secondaries win this fight up close: push, never kite.
    pub brawl: bool,
    /// A spotter with nothing in the field: sail to where an enemy was last seen, then to its spawn.
    pub hunt: bool,
    /// Bearing straight away from the enemies we are too close to by their trade; stations only within its cone.
    pub kite_axis: Option<f32>,
    /// Enemy shells aimed near us are in the air.
    pub under_fire: bool,
}

/// The fire on one bot, v4's threat: 1 - exp(-horizon / time to die).
#[derive(Clone, Copy, Debug, Default)]
pub struct Danger {
    pub threat: f32,
    /// Seconds to die under the fire on us, and to sink our target alone; None with nothing to beat.
    pub ttd: f32,
    pub ttw: Option<f32>,
    /// Island cover leads: open water is a fight we lose here.
    pub cover_first: bool,
    /// Exposure (HP share per minute) a station may carry and still score under REENGAGE_THREAT.
    pub safe_x: f32,
}

impl Danger {
    /// We outlive the time to win by `margin`, aggression shrinking it.
    pub fn winning(&self, margin: f32, aggression: f32) -> bool {
        self.ttw.is_some_and(|w| self.ttd >= w * margin * (-AGGRESSION_STAY * aggression).exp())
    }
}

pub struct Committed {
    pub target: Option<i64>,
    pub clear: bool,
}

/// One bot's decision against the team's view and what earlier bots committed to.
/// `ev(target)`: point-table value per shot now, None without a table.
/// `shot(station, aim)`: station is navigable and our shells clear terrain to `aim`.
pub fn resolve(m: &Member, snap: &Snapshot, belief: &Belief, committed: &[Committed], now: f64,
        ev: &mut dyn FnMut(&ShipState) -> Option<f32>, shot: &mut dyn FnMut(Vector2, Vector2) -> bool,
        scan: &mut dyn FnMut(&Req) -> Option<Found>)
        -> (Option<Plan>, Assignment, Option<&'static str>) {
    let me = m.me;
    let my = me.p2();
    let delay = m.apt.view_delay_s();
    let view: Vec<(&ShipState, Vector2)> = snap.enemies_of(me.team)
        .filter_map(|e| belief.pos_at(e.id, now, delay).map(|p| (e, p)))
        .collect();

    let mut assign = m.assign;
    let threatened = view.iter().any(|(e, p)| p.distance_to(my) < e.gun_range * 1.05);
    if threatened {
        assign.last_threat = now;
    }

    let d = &m.danger;
    let posture = if m.plan.is_some_and(|p| p.posture == Posture::Disengage) {
        let held = me.seen && now - assign.dis_since < DISENGAGE_MIN_S;
        if !me.seen && !m.under_fire {
            assign.dis_left = now;
            Posture::Engage
        } else if held || d.ttw.is_some_and(|w| d.ttd < w * STAY_MARGIN) || d.threat > REENGAGE_THREAT {
            Posture::Disengage
        } else {
            assign.dis_left = now;
            Posture::Engage
        }
    } else if me.seen && (d.ttw.is_some_and(|w| d.ttd < w) || d.threat > DISENGAGE_AT)
            && (now - assign.dis_left >= DISENGAGE_COOLDOWN_S || d.threat >= DISENGAGE_FORCE_THREAT) {
        assign.dis_since = now;
        Posture::Disengage
    } else {
        Posture::Engage
    };

    let ours = |e: &ShipState, p: Vector2| m.flank.as_ref().is_none_or(|f| f.ids.contains(&e.id))
        || p.distance_to(my) < e.gun_range * 1.05;
    assign.target = pick_target(m, snap, committed, now, &mut assign, ev, &mut |p| shot(my, p), &|e| ours(e, e.p2()));
    let (lo, hi) = (m.style.band.0 * me.gun_range, m.style.band.1 * me.gun_range);
    let run_target = assign.target.and_then(|id| snap.get(id)).filter(|t| t.alive && t.seen);
    let posture = match (posture, m.torp, run_target) {
        (Posture::Engage, Some(_), Some(_)) if me.torp_boat() => Posture::TorpRun,
        (p, _, _) => p,
    };

    let nearest = |it: &mut dyn Iterator<Item = (Option<i64>, Vector2)>| it.min_by(|a, b| a.1.distance_to(my).total_cmp(&b.1.distance_to(my)));
    let in_view = |id: i64| view.iter().find(|(e, p)| e.id == id && ours(e, *p)).map(|&(e, p)| (Some(e.id), p));
    let picked = assign.target.and_then(in_view)
        .or_else(|| m.plan.and_then(|p| p.anchor_id).and_then(in_view))
        .or_else(|| nearest(&mut view.iter().filter(|(e, p)| ours(e, *p)).map(|&(e, p)| (Some(e.id), p))))
        .or_else(|| m.flank.as_ref().and_then(|f| f.centre).map(|c| (None, c)))
        .or_else(|| nearest(&mut view.iter().map(|&(e, p)| (Some(e.id), p))));
    let hunting = m.hunt && view.is_empty();
    let picked = if hunting { None } else { picked };
    let contact = picked.map(|c| c.1);
    let anchor = if hunting { belief.last_known().filter(|p| p.distance_to(my) > HUNT_M).or(belief.enemy_spawn).unwrap_or(my) }
        else { contact.or(belief.enemy_spawn).unwrap_or(my) };
    let lost_shot = |p: &Plan, shot: &mut dyn FnMut(Vector2, Vector2) -> bool|
        !p.kite && p.shot && contact.is_some() && !shot(p.station, anchor);

    let (lo, hi) = if hunting { (0.0, HUNT_M) } else { picked.and_then(|c| c.0).and_then(|id| m.bands.get(&id).copied()).unwrap_or((lo, hi)) };
    let cover = (d.cover_first && !m.brawl).then_some(d.safe_x);
    let away: Vector2 = view.iter().filter(|(e, p)| p.distance_to(my) < e.gun_range * 1.05).map(|(_, p)| dir_or(my - *p, Vector2::ZERO)).sum();
    let cones = if away.length() > 1e-3 { vec![(away.x.atan2(away.y), 1.0)] } else { m.kite_axis.map(|a| (a, 1.0)).into_iter().collect() };
    let kite = m.kite_axis.filter(|_| !m.brawl);
    let req = |keep: Option<Vector2>, avoid: Option<Vector2>, only: Option<Vector2>| Req {
        anchor, target: picked.and_then(|c| c.0), lo, hi, keep, avoid, only,
        cover, escape: false, cones: kite.filter(|_| only.is_none()).map(|a| (a, 1.0)).into_iter().collect(),
    };
    let off_cone = |p: &Plan| !p.kite && kite.is_some_and(|a| {
        let d = p.station - my;
        d.length() < p.hold_radius || wrap(d.x.atan2(d.y) - a).abs() > super::station::CONE_HALF
    });
    let kite_leg = |axis: f32| my + Vector2::new(axis.sin(), axis.cos()) * KITE_LEG_M;
    let escape = |scan: &mut dyn FnMut(&Req) -> Option<Found>, keep: Option<Vector2>| {
        if let Some(&(axis, _)) = cones.first() {
            return Plan { posture: Posture::Disengage, station: kite_leg(axis), anchor, heading: 0.0, heading_weight: 0.0,
                hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false, score: 0.0, dark: false,
                anchor_id: None, kite: true };
        }
        let f = scan(&Req { anchor: my, target: None, lo: 0.0, hi: me.gun_range, keep, avoid: None, only: None,
            cover: None, escape: true, cones: cones.clone() });
        let (station, dark) = f.map_or((my, false), |f| (f.station, f.dark));
        Plan { posture: Posture::Disengage, station, anchor, heading: 0.0, heading_weight: 0.0, hold_radius: HOLD_RADIUS_M,
            set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false, score: f.map_or(0.0, |f| f.net), dark, anchor_id: None,
            kite: f.is_some_and(|f| f.kite) }
    };
    let still_good = |p: &Plan, scan: &mut dyn FnMut(&Req) -> Option<Found>|
        scan(&req(None, None, Some(p.station))).is_some_and(|f| f.net >= 0.0 && f.net >= HOLD_AGAIN * p.score && f.dark == p.dark);
    if let Some(p) = m.plan {
        let blocked = blocked(m, &p, my, assign.target);
        let arrived = p.posture == Posture::Engage && p.station.distance_to(my) < p.hold_radius;
        let fine = p.posture == posture && !blocked && p.anchor.distance_to(anchor) < ANCHOR_MOVE_M && !lost_shot(&p, shot) && !off_cone(&p) && (p.posture != Posture::Engage || p.kite == kite.is_some())
            && (p.shot || p.posture != Posture::Engage || assign.target.is_none());
        let again = fine && (now >= p.hold_until || arrived) && posture == Posture::Engage && still_good(&p, scan);
        if fine && ((now < p.hold_until && !arrived) || again) {
            let mut p = p;
            if again {
                p.hold_until = now + HOLD_S;
            }
            p.heading = broadside(my, anchor, me.heading());
            return (Some(p), assign, None);
        }
    }
    let blocked = m.plan.is_some_and(|p| blocked(m, &p, my, assign.target));
    let reason = match m.plan {
        None => "first",
        Some(p) if p.posture != posture => "posture",
        Some(_) if blocked => "blocked",
        Some(p) if p.anchor.distance_to(anchor) >= ANCHOR_MOVE_M => "anchor_moved",
        Some(p) if off_cone(&p) => "ring_kite",
        Some(p) if p.posture == Posture::Engage && p.kite != kite.is_some() => "kite_end",
        Some(p) if p.posture == Posture::Engage && !p.shot && assign.target.is_some() => "unshot",
        Some(p) if p.station.distance_to(my) < p.hold_radius => "arrived",
        Some(p) if now < p.hold_until => "no_shot",
        Some(_) => "expired",
    };

    let plan = match posture {
        Posture::Engage if kite.is_some() => Plan { posture, station: kite_leg(kite.unwrap()), anchor, heading: broadside(my, anchor, me.heading()),
            heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: true, score: 0.0,
            dark: false, anchor_id: picked.and_then(|c| c.0), kite: true },
        Posture::Engage => {
            let prev = m.plan.filter(|p| p.posture == Posture::Engage);
            let keep = prev.filter(|_| matches!(reason, "expired" | "anchor_moved")).map(|p| p.station);
            let found = scan(&req(keep, prev.filter(|_| matches!(reason, "arrived" | "blocked")).map(|p| p.station), None));
            let target = picked.and_then(|c| c.0).is_some();
            let found = found.or_else(|| cover.and(scan(&Req { cover: None, ..req(None, None, None) })));
            if found.is_none() && target {
                if let Some(p) = prev.filter(|p| p.shot && !lost_shot(p, shot)) {
                    return (Some(Plan { hold_until: now + HOLD_S, ..p }), assign, Some("no_shot_station"));
                }
            }
            let fallback = || {
                let band = anchor + dir_or(my - anchor, Vector2::new(0.0, 1.0)) * ((lo + hi) * 0.5);
                my + (band - my).limit_length(Some(WINDOW_M))
            };
            let (station, shot, score, dark) = found.map_or_else(|| (fallback(), false, 0.0, false), |f| (f.station, f.shot, f.net, f.dark));
            Plan { posture, station, anchor, heading: broadside(my, anchor, me.heading()),
                heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0,
                shot, score, dark, anchor_id: picked.and_then(|c| c.0), kite: kite.is_some() }
        }
        Posture::TorpRun => {
            let (t, (range, loaded)) = (run_target.unwrap(), m.torp.unwrap());
            let range = (if loaded { TORP_RUN_RANGE } else { TORP_WAIT_RANGE } * range).max(me.conceal * crate::bot5::snapshot::SPOT_SAFE);
            let tp = t.p2();
            let away = dir_or(my - tp, Vector2::new(0.0, 1.0));
            let tf = dir_or(Vector2::new(t.vel.x, t.vel.z), Vector2::ZERO);
            let dir = dir_or(away + tf * TORP_RUN_LEAD, away);
            Plan { posture, station: tp + dir * range, anchor: tp, heading: broadside(my, tp, me.heading()),
                heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false,
                score: 0.0, dark: true, anchor_id: Some(t.id), kite: false }
        }
        Posture::Disengage => {
            let keep = m.plan.filter(|p| p.posture == Posture::Disengage && reason == "expired").map(|p| p.station);
            escape(scan, keep)
        }
    };
    (Some(plan), assign, Some(reason))
}

fn blocked(m: &Member, p: &Plan, my: Vector2, target: Option<i64>) -> bool {
    m.blocked_s >= BLOCKED_RELEASE_S && target.is_some() && p.station.distance_to(my) < BLOCKED_AT_M
}

fn pick_target(m: &Member, snap: &Snapshot, committed: &[Committed], now: f64, assign: &mut Assignment,
        ev: &mut dyn FnMut(&ShipState) -> Option<f32>, clear: &mut dyn FnMut(Vector2) -> bool, ours: &dyn Fn(&ShipState) -> bool)
        -> Option<i64> {
    let me = m.me;
    let team_w = m.apt.team_weight();
    let mut clear_of: Vec<(i64, bool)> = Vec::new();
    let mut score = |e: &ShipState| -> Option<f32> {
        if !e.seen || e.pos.distance_to(me.pos) > me.gun_range {
            return None;
        }
        let v = ev(e)?;
        let hp = (e.hp_frac * e.hp_max).max(1.0);
        let c = clear(e.p2());
        clear_of.push((e.id, c));
        let focus = committed.iter().filter(|c| c.clear && c.target == Some(e.id)).count() as f32;
        let off = if ours(e) { 1.0 } else { OFF_FLANK_W };
        Some(off * v / hp * if c { 1.0 } else { NO_SHOT_W } * (1.0 + team_w * FOCUS_BONUS * focus))
    };
    let cur = assign.target.and_then(|id| snap.get(id)).filter(|t| t.alive);
    let cur_score = cur.and_then(&mut score);
    let mut best: Option<(i64, f32)> = None;
    for e in snap.enemies_of(me.team) {
        if let Some(s) = score(e) {
            if best.is_none_or(|(_, b)| s > b) {
                best = Some((e.id, s));
            }
        }
    }
    let pick = match (cur_score, best) {
        (Some(c), Some((id, b))) if id != assign.target.unwrap_or(-1)
            && b > c * TARGET_SWITCH && now - assign.target_since >= TARGET_HOLD_S => Some(id),
        (Some(_), _) => assign.target,
        (None, Some((id, _))) => Some(id),
        (None, None) => None,
    };
    if pick != assign.target {
        assign.target_since = now;
    }
    drop(score);
    assign.clear = pick.is_some_and(|id| clear_of.iter().any(|&(e, c)| e == id && c));
    pick
}

fn broadside(my: Vector2, anchor: Vector2, heading: f32) -> f32 {
    let d = anchor - my;
    let bearing = d.x.atan2(d.y);
    let a = wrap(bearing + std::f32::consts::FRAC_PI_2);
    let b = wrap(bearing - std::f32::consts::FRAC_PI_2);
    if wrap(a - heading).abs() <= wrap(b - heading).abs() { a } else { b }
}

pub fn wrap(a: f32) -> f32 {
    let t = std::f32::consts::TAU;
    let mut a = (a + std::f32::consts::PI) % t;
    if a < 0.0 {
        a += t;
    }
    a - std::f32::consts::PI
}

fn dir_or(v: Vector2, fallback: Vector2) -> Vector2 {
    let l = v.length();
    if l > 1e-3 { v / l } else { fallback }
}
