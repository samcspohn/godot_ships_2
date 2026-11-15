use godot::prelude::*;

use std::collections::HashSet;

use super::belief::Belief;
use super::flank::SeamGeom;
use super::params::{Aptitude, Style};
use super::snapshot::{ShipState, Snapshot};
use super::station::{Found, Req};

const HOLD_S: f64 = 20.0;
const ANCHOR_MOVE_M: f32 = 1200.0;
const TARGET_SWITCH: f32 = 1.25;
const TARGET_HOLD_S: f64 = 8.0;
const RETREAT_RECOVER_HP: f32 = 0.15;
const RETREAT_CLEAR_S: f64 = 20.0;
const FOCUS_BONUS: f32 = 0.3;
const HOLD_RADIUS_M: f32 = 400.0;
const BLOCKED_RELEASE_S: f32 = 3.0;
/// Guns blocked on the way are expected; only blocked at the station releases it.
const BLOCKED_AT_M: f32 = 1000.0;
const TORP_RUN_HP: f32 = 0.5;
const TORP_RUN_RANGE: f32 = 0.7;
const TORP_RUN_REACH: f32 = 0.8;
const TORP_RUN_LEAD: f32 = 0.7;
/// Shooting outside our flank is worth this share: taken when nothing of ours is in reach.
const OFF_FLANK_W: f32 = 0.4;
/// An expired station that still scores this share of what it did when set is held again without a search.
const HOLD_AGAIN: f32 = 0.75;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Posture {
    Engage,
    TorpRun,
    Retreat,
}

impl Posture {
    pub fn name(self) -> &'static str {
        match self {
            Posture::Engage => "engage",
            Posture::TorpRun => "torp_run",
            Posture::Retreat => "retreat",
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
    /// Where the scan wants us; `station` is a checkpoint on the way when they differ.
    pub goal: Vector2,
    pub anchor_id: Option<i64>,
}

#[derive(Clone, Copy, Debug)]
pub struct Assignment {
    pub target: Option<i64>,
    pub target_since: f64,
    pub last_threat: f64,
}

impl Default for Assignment {
    fn default() -> Self {
        Assignment { target: None, target_since: f64::NEG_INFINITY, last_threat: f64::NEG_INFINITY }
    }
}

/// The enemies this bot answers for: belief contacts of its flank(s), and the nearest such group's centre.
pub struct FlankView {
    pub ids: HashSet<i64>,
    pub centre: Option<Vector2>,
    pub seam: Option<SeamGeom>,
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
}

pub struct Committed {
    pub target: Option<i64>,
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

    let prev = m.plan.map(|p| p.posture);
    let posture = match prev {
        Some(Posture::Retreat) if me.hp_frac < m.style.retreat_hp + RETREAT_RECOVER_HP
            && now - assign.last_threat < RETREAT_CLEAR_S => Posture::Retreat,
        _ if me.hp_frac < m.style.retreat_hp && threatened => Posture::Retreat,
        _ => Posture::Engage,
    };

    let ours = |e: &ShipState, p: Vector2| m.flank.as_ref().is_none_or(|f| f.ids.contains(&e.id))
        || p.distance_to(my) < e.gun_range * 1.05;
    assign.target = pick_target(m, snap, committed, now, &mut assign, ev, &|e| ours(e, e.p2()));
    let (lo, hi) = (m.style.band.0 * me.gun_range, m.style.band.1 * me.gun_range);
    let run_target = assign.target.and_then(|id| snap.get(id)).filter(|t| t.alive && t.seen);
    let posture = match (posture, m.torp, run_target) {
        (Posture::Engage, Some((range, true)), Some(_)) if me.hp_frac >= TORP_RUN_HP
            && (lo + hi) * 0.5 > TORP_RUN_REACH * range => Posture::TorpRun,
        (p, _, _) => p,
    };

    let nearest = |it: &mut dyn Iterator<Item = (Option<i64>, Vector2)>| it.min_by(|a, b| a.1.distance_to(my).total_cmp(&b.1.distance_to(my)));
    let in_view = |id: i64| view.iter().find(|(e, p)| e.id == id && ours(e, *p)).map(|&(e, p)| (Some(e.id), p));
    let picked = assign.target.and_then(in_view)
        .or_else(|| m.plan.and_then(|p| p.anchor_id).and_then(in_view))
        .or_else(|| nearest(&mut view.iter().filter(|(e, p)| ours(e, *p)).map(|&(e, p)| (Some(e.id), p))))
        .or_else(|| m.flank.as_ref().and_then(|f| f.centre).map(|c| (None, c)))
        .or_else(|| nearest(&mut view.iter().map(|&(e, p)| (Some(e.id), p))));
    let contact = picked.map(|c| c.1);
    let anchor = contact.or(belief.enemy_spawn).unwrap_or(my);
    let lost_shot = |p: &Plan, shot: &mut dyn FnMut(Vector2, Vector2) -> bool|
        p.shot && contact.is_some() && !shot(p.station, anchor);

    let req = |keep: Option<Vector2>, avoid: Option<Vector2>, only: Option<Vector2>| Req {
        anchor, target: picked.and_then(|c| c.0), lo, hi, keep, avoid, seam: m.flank.as_ref().and_then(|f| f.seam), only,
    };
    let still_good = |p: &Plan, scan: &mut dyn FnMut(&Req) -> Option<Found>|
        scan(&req(None, None, Some(p.station))).is_some_and(|f| f.net >= 0.0 && f.net >= HOLD_AGAIN * p.score && f.dark == p.dark);
    let at_goal = |p: &Plan| p.station.distance_to(p.goal) < p.hold_radius;
    if let Some(p) = m.plan {
        let blocked = blocked(m, &p, my, assign.target);
        let arrived = p.posture == Posture::Engage && p.station.distance_to(my) < p.hold_radius;
        let fine = p.posture == posture && !blocked && p.anchor.distance_to(anchor) < ANCHOR_MOVE_M && !lost_shot(&p, shot)
            && !(arrived && !at_goal(&p));
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
        Some(p) if p.station.distance_to(my) < p.hold_radius && !at_goal(&p) => "checkpoint",
        Some(p) if p.station.distance_to(my) < p.hold_radius => "arrived",
        Some(p) if now < p.hold_until => "no_shot",
        Some(_) => "expired",
    };

    let plan = match posture {
        Posture::Engage => {
            let prev = m.plan.filter(|p| p.posture == Posture::Engage);
            let keep = prev.filter(|_| matches!(reason, "expired" | "anchor_moved" | "checkpoint")).map(|p| p.goal);
            let found = scan(&req(keep, prev.filter(|_| matches!(reason, "arrived" | "blocked")).map(|p| p.station), None));
            let fallback = || anchor + dir_or(my - anchor, Vector2::new(0.0, 1.0)) * ((lo + hi) * 0.5);
            let goal = found.map_or_else(fallback, |f| f.station);
            let (station, shot, score, dark) = match found {
                Some(Found { checkpoint: Some(c), .. }) => c,
                Some(f) => (f.station, f.shot, f.net, f.dark),
                None => (goal, false, 0.0, false),
            };
            Plan { posture, station, anchor, heading: broadside(my, anchor, me.heading()),
                heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0,
                shot, score, dark, goal, anchor_id: picked.and_then(|c| c.0) }
        }
        Posture::TorpRun => {
            let (t, range) = (run_target.unwrap(), m.torp.unwrap().0);
            let tp = t.p2();
            let away = dir_or(my - tp, Vector2::new(0.0, 1.0));
            let tf = dir_or(Vector2::new(t.vel.x, t.vel.z), Vector2::ZERO);
            let dir = dir_or(away + tf * TORP_RUN_LEAD, away);
            Plan { posture, station: tp + dir * (TORP_RUN_RANGE * range), anchor: tp, heading: broadside(my, tp, me.heading()),
                heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false,
                score: 0.0, dark: false, goal: tp + dir * (TORP_RUN_RANGE * range), anchor_id: Some(t.id) }
        }
        Posture::Retreat => {
            let threat = centroid(view.iter().map(|&(_, p)| p)).unwrap_or(anchor);
            let allies = centroid(snap.allies_of(me.team).filter(|a| a.id != me.id).map(|a| a.p2()));
            let mut dir = dir_or(my - threat, Vector2::new(0.0, 1.0));
            if let Some(a) = allies {
                dir = dir_or(dir + dir_or(a - my, Vector2::ZERO) * 0.5, dir);
            }
            Plan { posture, station: my + dir * (0.6 * me.gun_range), anchor, heading: 0.0, heading_weight: 0.0,
                hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false, score: 0.0, dark: false,
                goal: my + dir * (0.6 * me.gun_range), anchor_id: None }
        }
    };
    (Some(plan), assign, Some(reason))
}

fn blocked(m: &Member, p: &Plan, my: Vector2, target: Option<i64>) -> bool {
    m.blocked_s >= BLOCKED_RELEASE_S && target.is_some() && p.station.distance_to(my) < BLOCKED_AT_M
}

fn pick_target(m: &Member, snap: &Snapshot, committed: &[Committed], now: f64, assign: &mut Assignment,
        ev: &mut dyn FnMut(&ShipState) -> Option<f32>, ours: &dyn Fn(&ShipState) -> bool) -> Option<i64> {
    let me = m.me;
    let team_w = m.apt.team_weight();
    let mut score = |e: &ShipState| -> Option<f32> {
        if !e.seen || e.pos.distance_to(me.pos) > me.gun_range {
            return None;
        }
        let v = ev(e)?;
        let hp = (e.hp_frac * e.hp_max).max(1.0);
        let focus = committed.iter().filter(|c| c.target == Some(e.id)).count() as f32;
        let off = if ours(e) { 1.0 } else { OFF_FLANK_W };
        Some(off * v / hp * (1.0 + team_w * FOCUS_BONUS * focus))
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

fn centroid(it: impl Iterator<Item = Vector2>) -> Option<Vector2> {
    let (mut s, mut n) = (Vector2::ZERO, 0.0);
    for p in it {
        s += p;
        n += 1.0;
    }
    (n > 0.0).then(|| s / n)
}
