use godot::prelude::*;

use super::belief::Belief;
use super::params::{Aptitude, Style};
use super::snapshot::{ShipState, Snapshot};

const HOLD_S: f64 = 20.0;
const ANCHOR_MOVE_M: f32 = 1200.0;
const TARGET_SWITCH: f32 = 1.25;
const TARGET_HOLD_S: f64 = 8.0;
const RETREAT_RECOVER_HP: f32 = 0.15;
const RETREAT_CLEAR_S: f64 = 20.0;
const FOCUS_BONUS: f32 = 0.3;
const HOLD_RADIUS_M: f32 = 400.0;
const ORBIT_STEP: f32 = 0.45;
const BLOCKED_SWING: f32 = 0.6;
const BLOCKED_RELEASE_S: f32 = 3.0;
const TORP_RUN_HP: f32 = 0.5;
const TORP_RUN_RANGE: f32 = 0.7;
const TORP_RUN_REACH: f32 = 0.8;
const TORP_RUN_LEAD: f32 = 0.7;

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
}

pub struct Committed {
    pub target: Option<i64>,
}

/// One bot's decision against the team's view and what earlier bots committed to.
/// `ev(target)`: point-table value per shot now, None without a table.
pub fn resolve(m: &Member, snap: &Snapshot, belief: &Belief, committed: &[Committed], now: f64,
        ev: &mut dyn FnMut(&ShipState) -> Option<f32>) -> (Option<Plan>, Assignment, Option<&'static str>) {
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

    assign.target = pick_target(m, snap, committed, now, &mut assign, ev);
    let (lo, hi) = (m.style.band.0 * me.gun_range, m.style.band.1 * me.gun_range);
    let run_target = assign.target.and_then(|id| snap.get(id)).filter(|t| t.alive && t.seen);
    let posture = match (posture, m.torp, run_target) {
        (Posture::Engage, Some((range, true)), Some(_)) if me.hp_frac >= TORP_RUN_HP
            && (lo + hi) * 0.5 > TORP_RUN_REACH * range => Posture::TorpRun,
        (p, _, _) => p,
    };

    let anchor = assign.target.and_then(|id| view.iter().find(|(e, _)| e.id == id).map(|&(_, p)| p))
        .or_else(|| view.iter().map(|&(_, p)| p).min_by(|a, b| a.distance_to(my).total_cmp(&b.distance_to(my))))
        .or(belief.enemy_spawn)
        .unwrap_or(my);

    if let Some(p) = m.plan {
        let blocked = m.blocked_s >= BLOCKED_RELEASE_S && assign.target.is_some();
        let arrived = p.posture == Posture::Engage && p.station.distance_to(my) < p.hold_radius;
        let keep = p.posture == posture && now < p.hold_until && !arrived && !blocked
            && p.anchor.distance_to(anchor) < ANCHOR_MOVE_M;
        if keep {
            let mut p = p;
            p.heading = broadside(my, anchor, me.heading());
            return (Some(p), assign, None);
        }
    }
    let blocked = m.blocked_s >= BLOCKED_RELEASE_S && assign.target.is_some();
    let reason = match m.plan {
        None => "first",
        Some(p) if p.posture != posture => "posture",
        Some(_) if blocked => "blocked",
        Some(p) if p.anchor.distance_to(anchor) >= ANCHOR_MOVE_M => "anchor_moved",
        Some(p) if p.station.distance_to(my) < p.hold_radius => "arrived",
        Some(_) => "expired",
    };

    let plan = match posture {
        Posture::Engage => {
            let d = my.distance_to(anchor);
            let away = dir_or(my - anchor, -dir_or(anchor - my, Vector2::new(0.0, 1.0)));
            let r = d.clamp(lo, hi);
            let fwd = Vector2::new(me.fwd().x, me.fwd().z);
            let swing = if blocked { BLOCKED_SWING } else if d >= lo && d <= hi { ORBIT_STEP } else { 0.0 };
            let side = if (rotate(away, swing) - away).dot(fwd) >= 0.0 { 1.0 } else { -1.0 };
            let station = anchor + rotate(away, swing * side) * if swing > 0.0 { r } else { (lo + hi) * 0.5 };
            Plan { posture, station, anchor, heading: broadside(my, anchor, me.heading()), heading_weight: 0.0,
                hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0 }
        }
        Posture::TorpRun => {
            let (t, range) = (run_target.unwrap(), m.torp.unwrap().0);
            let tp = t.p2();
            let away = dir_or(my - tp, Vector2::new(0.0, 1.0));
            let tf = dir_or(Vector2::new(t.vel.x, t.vel.z), Vector2::ZERO);
            let dir = dir_or(away + tf * TORP_RUN_LEAD, away);
            Plan { posture, station: tp + dir * (TORP_RUN_RANGE * range), anchor: tp, heading: broadside(my, tp, me.heading()),
                heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0 }
        }
        Posture::Retreat => {
            let threat = centroid(view.iter().map(|&(_, p)| p)).unwrap_or(anchor);
            let allies = centroid(snap.allies_of(me.team).filter(|a| a.id != me.id).map(|a| a.p2()));
            let mut dir = dir_or(my - threat, Vector2::new(0.0, 1.0));
            if let Some(a) = allies {
                dir = dir_or(dir + dir_or(a - my, Vector2::ZERO) * 0.5, dir);
            }
            Plan { posture, station: my + dir * (0.6 * me.gun_range), anchor, heading: 0.0, heading_weight: 0.0,
                hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0 }
        }
    };
    (Some(plan), assign, Some(reason))
}

fn pick_target(m: &Member, snap: &Snapshot, committed: &[Committed], now: f64, assign: &mut Assignment,
        ev: &mut dyn FnMut(&ShipState) -> Option<f32>) -> Option<i64> {
    let me = m.me;
    let team_w = m.apt.team_weight();
    let mut score = |e: &ShipState| -> Option<f32> {
        if !e.seen || e.pos.distance_to(me.pos) > me.gun_range {
            return None;
        }
        let v = ev(e)?;
        let hp = (e.hp_frac * e.hp_max).max(1.0);
        let focus = committed.iter().filter(|c| c.target == Some(e.id)).count() as f32;
        Some(v / hp * (1.0 + team_w * FOCUS_BONUS * focus))
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

fn rotate(v: Vector2, a: f32) -> Vector2 {
    let (sn, cs) = a.sin_cos();
    Vector2::new(v.x * cs - v.y * sn, v.x * sn + v.y * cs)
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
