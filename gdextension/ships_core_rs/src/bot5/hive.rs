use godot::prelude::*;

use std::collections::{HashMap, HashSet};

use super::belief::Belief;
use super::params::{Aptitude, Style};
use super::snapshot::{HullClass, ShipState, Snapshot};
use super::cover::{self, CoverArgs};
use super::station::{Found, Req, WINDOW_M};

const HOLD_S: f64 = 20.0;
/// v4 COVER_IDLE_S: idle in cover this long, over aggression, ratchets the cap CHECKPOINT_STEP_M nearer the anchor.
const CHECKPOINT_IDLE_S: f64 = 5.0;
const CHECKPOINT_STEP_M: f32 = 1000.0;
/// v4 SkillCover: search with no station every RESEARCH_S, holding edge cover every DEEP_RESEARCH_S for deep.
const RESEARCH_S: f64 = 1.0;
const DEEP_RESEARCH_S: f64 = 5.0;
const COVER_BLIND_S: f64 = 10.0;
const ARRIVED_M: f32 = 200.0;
/// A held cover station gives way only to one cheaper by this much, in route metres (or SWITCH_FRAC of its cost).
const SWITCH_M: f32 = 500.0;
const SWITCH_FRAC: f32 = 0.25;
/// Route metres a station is charged for being on the edge (not deep), or failing a soft test (seen ahead, no target).
const EDGE_PEN_M: f32 = 1000.0;
const SOFT_PEN_M: f32 = 2000.0;
const BLOCKED_S: f64 = 5.0;
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
/// v4 BotDoctrine: the close arm's reach (ra), wider with a battleship on us, wider still hurt (BB, CA); CA push_threat.
const RA_BASE_M: f32 = 8000.0;
const RA_BB_M: f32 = 10000.0;
const RA_BB_HURT_M: f32 = 13000.0;
const RA_CA_HURT_M: f32 = 11000.0;
const RA_HURT_HP: f32 = 0.5;
const PUSH_THREAT: f32 = 0.5;
/// v4 SkillFight: an open-water station judged too exposed is not tried again for this long unless threat falls.
const SHELTER_S: f64 = 20.0;
/// v4 _brawl: past this crossfire a brawler tucks instead of pushing.
const BRAWL_CROSSFIRE: f32 = std::f32::consts::FRAC_PI_2;
/// v4 SkillDisengage.kite_dir: the leg's end is kept this far inside the map, the leg turned off straight away
/// in KITE_OFF_STEP steps up to KITE_OFF_MAX, our moving side first.
const KITE_EDGE_M: f32 = 500.0;
const KITE_OFF_STEP: f32 = 15.0 * std::f32::consts::PI / 180.0;
const KITE_OFF_MAX: f32 = 150.0 * std::f32::consts::PI / 180.0;
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
    /// Heading to or holding hidden cover.
    pub cover: bool,
    /// Cover whose every neighbour is cover too.
    pub deep: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct Assignment {
    /// Why a torpedo run was declined (torp_station).
    pub run_decline: Option<&'static str>,
    pub target: Option<i64>,
    pub target_since: f64,
    pub last_threat: f64,
    pub dis_since: f64,
    pub dis_left: f64,
    /// Our shells clear terrain to the target from where we are.
    pub clear: bool,
    pub cover: CoverState,
    /// v4 _dark_hold: left a disengage that was hiding us; guns stay quiet until firing from here is safe or we are pinned.
    pub dark_latch: bool,
    /// The disengage's cone: turned onto the station we could not reach alive, ahead only (a brawler's tuck).
    pub dis_toward: Vector2,
    pub dis_ahead: bool,
    pub shelter_until: f64,
    pub spot: super::spot::SpotState,
}

impl Default for Assignment {
    fn default() -> Self {
        Assignment { run_decline: None, target: None, target_since: f64::NEG_INFINITY, last_threat: f64::NEG_INFINITY, dis_since: f64::NEG_INFINITY,
            dis_left: f64::NEG_INFINITY, clear: false, cover: CoverState::default(), dark_latch: false, dis_toward: Vector2::INF, dis_ahead: false, shelter_until: f64::NEG_INFINITY,
            spot: Default::default() }
    }
}

/// v4 SkillCover's and SkillFight._checkpoint's memory.
#[derive(Clone, Copy, Debug)]
pub struct CoverState {
    pub searched: f64,
    /// A station lost to its own test: the next search starts there.
    pub resume: Vector2,
    pub blocked_since: f64,
    pub target_at: f64,
    pub idle_since: f64,
    pub cp_d: f32,
    pub cp_at: Vector2,
    /// Held but never shot from: the bot keeps it out of searches a while.
    pub block: Option<Vector2>,
}

impl Default for CoverState {
    fn default() -> Self {
        CoverState { searched: f64::NEG_INFINITY, resume: Vector2::INF, blocked_since: f64::INFINITY, target_at: f64::NEG_INFINITY,
            idle_since: f64::INFINITY, cp_d: f32::INFINITY, cp_at: Vector2::INF, block: None }
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
    /// v4 SkillDisengage._threat_axis toward the guns; None: the priority's bearing.
    pub threat_axis: Option<f32>,
    /// A gun is on us: its shells landed within ON_US_RELOADS, or shells aimed near us are in the air.
    pub fired_on: bool,
    /// Enemy shells aimed near us are in the air.
    pub under_fire: bool,
    /// Not a destroyer, brawler or its flank's spotter: may fight from, and fall back to, hidden cover.
    pub cover_ok: bool,
    /// Lit and seen at concealment by a known enemy: dark water is out and the guns stay on.
    pub pinned: bool,
    pub brawler: bool,
    /// v4 crossfire_arc: the arc holding the bearings of every lit enemy in range of us.
    pub crossfire: f32,
    /// Map min and max corners.
    pub bounds: Option<(Vector2, Vector2)>,
    /// A destroyer holding its flank's spot role: v4 DDBehavior's Spot ladder.
    pub spot_dd: bool,
    /// v4 spot_holding's test: we light an enemy a friend has in gun range.
    pub spot_lights: bool,
    /// The torpedo rule's target (torp_pick); the torpedo run sails at it.
    pub torp_target: Option<i64>,
    /// Our smoke is still up: hold Disengage until it fades.
    pub smoke_hold: bool,
    /// Offensive smoke: hold in the cloud at this point, fighting this target.
    pub smoke_fight: Option<(Vector2, i64)>,
}

/// The fire on one bot, v4's threat: 1 - exp(-horizon / time to die).
#[derive(Clone, Copy, Debug, Default)]
pub struct Danger {
    pub threat: f32,
    /// Seconds to die under the fire on us, and to sink our target alone; None with nothing to beat.
    pub ttd: f32,
    pub ttw: Option<f32>,
    /// Seconds to sink our target from where we sit, guns and tubes.
    pub ttw_hold: Option<f32>,
    /// Someone besides us lights our target.
    pub target_lit_by_other: bool,
    /// Island cover leads: open water is a fight we lose here.
    pub cover_first: bool,
    /// Alone in lighting our target: v4 needs_spot, never cover first.
    pub spotting: bool,
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
/// v4 SkillSpot: (station sailed for, bow-out heading, new or moved station) from the held state and a seed.
pub type SpotFn<'a> = dyn FnMut(&mut super::spot::SpotState, Vector2) -> Option<(Vector2, f32, bool)> + 'a;

#[allow(clippy::too_many_arguments)]
pub fn resolve(m: &Member, snap: &Snapshot, belief: &Belief, committed: &[Committed], now: f64,
        ev: &mut dyn FnMut(&ShipState) -> Option<f32>, shot: &mut dyn FnMut(Vector2, Vector2) -> bool,
        scan: &mut dyn FnMut(&Req) -> Option<Found>, spot: &mut SpotFn, lane: &mut dyn FnMut(Vector2, &ShipState) -> bool)
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
    if let Some((at, id)) = m.smoke_fight {
        assign.target = Some(id);
        let tp = snap.get(id).map_or(at, |t| t.p2());
        let p = Plan { posture: Posture::Engage, station: at, anchor: tp, heading: broadside(my, tp, me.heading()), heading_weight: 0.0,
            hold_radius: super::SMOKE_HOLD_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: true, score: 0.0, dark: false,
            anchor_id: Some(id), kite: false, cover: false, deep: false };
        let fresh = m.plan.is_none_or(|q| q.station != at);
        return (Some(p), assign, fresh.then_some("smoke_fight"));
    }
    // v4 _may_disengage, for the doomed station and the brawler's tuck.
    let may_disengage = me.seen && d.threat >= DISENGAGE_THREAT
        && (now - assign.dis_left >= DISENGAGE_COOLDOWN_S || d.threat >= DISENGAGE_FORCE_THREAT);
    // v4: Disengage runs only while we are lit.
    let posture = if m.smoke_hold {
        if !m.plan.is_some_and(|p| p.posture == Posture::Disengage) {
            assign.dis_since = now;
            (assign.dis_toward, assign.dis_ahead) = (Vector2::INF, false);
        }
        Posture::Disengage
    } else if m.plan.is_some_and(|p| p.posture == Posture::Disengage) {
        let held = me.seen && now - assign.dis_since < DISENGAGE_MIN_S;
        if !me.seen {
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
        (assign.dis_toward, assign.dis_ahead) = (Vector2::INF, false);
        Posture::Disengage
    } else {
        Posture::Engage
    };
    match m.plan {
        _ if posture == Posture::Disengage => assign.dark_latch = false,
        Some(p) if p.posture == Posture::Disengage => assign.dark_latch = p.dark,
        _ => {}
    }
    if assign.dark_latch && (me.seen && m.pinned || d.threat < DISENGAGE_THREAT) {
        assign.dark_latch = false;
    }
    let dis = (assign.dis_toward, assign.dis_ahead);

    let ours = |e: &ShipState, p: Vector2| m.flank.as_ref().is_none_or(|f| f.ids.contains(&e.id))
        || p.distance_to(my) < e.gun_range * 1.05;
    assign.target = pick_target(m, snap, committed, now, &mut assign, ev, &mut |p| shot(my, p), &|e| ours(e, e.p2()));
    let (lo, hi) = (m.style.band.0 * me.gun_range, m.style.band.1 * me.gun_range);
    let run_target = m.torp_target.and_then(|id| snap.get(id)).filter(|t| t.alive && t.seen);
    let run = match (posture, m.torp, run_target) {
        (Posture::Engage, Some((range, loaded)), Some(t)) if me.torp_boat() => Some(torp_station(t, range, loaded, me, my, snap, lane)),
        _ => None,
    };
    assign.run_decline = run.and_then(|r| r.err());
    let run_station = run.and_then(|r| r.ok());
    let posture = if run_station.is_some() { Posture::TorpRun } else { posture };

    let nearest = |it: &mut dyn Iterator<Item = (Option<i64>, Vector2)>| it.min_by(|a, b| a.1.distance_to(my).total_cmp(&b.1.distance_to(my)));
    let in_view = |id: i64| view.iter().find(|(e, p)| e.id == id && ours(e, *p)).map(|&(e, p)| (Some(e.id), p));
    let picked = assign.target.and_then(in_view)
        .or_else(|| m.plan.and_then(|p| p.anchor_id).and_then(in_view))
        .or_else(|| nearest(&mut view.iter().filter(|(e, p)| ours(e, *p)).map(|&(e, p)| (Some(e.id), p))))
        .or_else(|| m.flank.as_ref().and_then(|f| f.centre).map(|c| (None, c)))
        .or_else(|| belief.presumed_end(my).is_none().then(|| nearest(&mut view.iter().map(|&(e, p)| (Some(e.id), p)))).flatten());
    let hunting = m.hunt && view.is_empty();
    let picked = if hunting { None } else { picked };
    let contact = picked.map(|c| c.1);
    let anchor = if hunting { belief.last_known().filter(|p| p.distance_to(my) > HUNT_M).or(belief.enemy_spawn).unwrap_or(my) }
        else { contact.or_else(|| belief.presumed_end(my)).or(belief.enemy_spawn).unwrap_or(my) };
    let lost_shot = |p: &Plan, shot: &mut dyn FnMut(Vector2, Vector2) -> bool|
        !p.kite && p.shot && picked.and_then(|c| c.0).is_some() && !shot(p.station, anchor);

    let (lo, hi) = if hunting { (0.0, HUNT_M) } else { picked.and_then(|c| c.0).and_then(|id| m.bands.get(&id).copied()).unwrap_or((lo, hi)) };
    let cover = (d.cover_first && !m.brawl).then_some(d.safe_x);
    let threat_axis = m.threat_axis.or_else(|| contact.filter(|c| c.distance_to(my) > 1.0).map(|c| (c - my).x.atan2((c - my).y)));
    let cones = match threat_axis {
        Some(a) => vec![(wrap(a + std::f32::consts::PI), 1.0)],
        None => m.kite_axis.map(|a| (a, 1.0)).into_iter().collect(),
    };
    let kite = m.kite_axis.filter(|_| !m.brawl);
    // Under fire and seen, stations lie on the threat axis, toward or away: no broadside run across the guns.
    let fire_cones = threat_axis.filter(|_| me.seen && m.fired_on && super::env_on("SHIPS_BOT5_FIRE_CONES")).map(|a| vec![a, wrap(a + std::f32::consts::PI)]);
    let req = |keep: Option<Vector2>, avoid: Option<Vector2>, only: Option<Vector2>| Req {
        anchor, target: picked.and_then(|c| c.0), lo, hi, keep, avoid, only,
        cover, escape: false, cones: kite.filter(|_| only.is_none()).map(|a| (a, 1.0)).into_iter().collect(), hide: None, presumed: false,
        fire_cones: fire_cones.clone().filter(|_| only.is_none()).unwrap_or_default(),
    };
    let clip: Vec<Vector2> = if me.seen { view.iter().map(|&(_, p)| p).filter(|p| p.distance_to(my) <= me.conceal.max(me.gun_range)).collect() } else { Vec::new() };
    let in_clip = |p: Vector2| clip.iter().all(|&c| {
        let (u, v) = (my - c, p - c);
        v.length() < 1.0 || wrap(u.x.atan2(u.y) - v.x.atan2(v.y)).abs() <= cover::CLIP_HALF
    });
    // v4 _axis: toward the anchor, turned to whichever end of it is nearer the bow; the far cone costs AWAY_RATIO.
    let offense = |from: Vector2, deep_only: bool, near: Option<(Vector2, f32)>| {
        let t = anchor - from;
        let a = t.x.atan2(t.y);
        let axis = if t.length() < 1.0 { f32::INFINITY } else if wrap(me.heading() - a).abs() > std::f32::consts::FRAC_PI_2 { wrap(a + std::f32::consts::PI) } else { a };
        CoverArgs { offense: true, axis, cone_half: cover::CONE_HALF, away_ratio: cover::AWAY_RATIO, near, clip: clip.clone(), exclude: Vec::new(),
            shield_ok: false, from, deep_only, allow_dark: false }
    };
    // v4 SkillDisengage.execute: CONE on the threat axis toward the guns, the away end at AWAY_RATIO; once the bow points
    // off the threat only the away cone (ahead_only: only toward); the cone turned at most CONE onto `toward`.
    let defense = |(toward, ahead): (Vector2, bool)| {
        let half = super::station::CONE_HALF;
        let axis0 = threat_axis.unwrap_or(f32::INFINITY);
        let (mut axis, mut ratio) = (axis0, cover::AWAY_RATIO);
        if ahead {
            ratio = f32::INFINITY;
        } else if axis0.is_finite() && wrap(me.heading() - axis0).abs() > std::f32::consts::FRAC_PI_2 {
            axis = wrap(axis0 + std::f32::consts::PI);
            ratio = f32::INFINITY;
        }
        if toward.is_finite() && axis.is_finite() {
            let off = wrap((toward - my).x.atan2((toward - my).y) - axis);
            if off.abs() <= std::f32::consts::FRAC_PI_2 + half {
                axis = wrap(axis + off.clamp(-half, half));
            }
        }
        CoverArgs { offense: false, axis, cone_half: half, away_ratio: ratio, near: None, clip: clip.clone(), exclude: Vec::new(),
            shield_ok: true, from: my, deep_only: false, allow_dark: !m.pinned }
    };
    let off_cone = |p: &Plan| !p.kite && !p.cover && kite.is_some_and(|a| {
        let d = p.station - my;
        d.length() < p.hold_radius || wrap(d.x.atan2(d.y) - a).abs() > super::station::CONE_HALF
    });
    let kite_leg = |axis: f32| {
        let leg = |a: f32| my + Vector2::new(a.sin(), a.cos()) * KITE_LEG_M;
        let Some((lo, hi)) = m.bounds else { return leg(axis) };
        let inside = |q: Vector2| q.x >= lo.x + KITE_EDGE_M && q.x <= hi.x - KITE_EDGE_M && q.y >= lo.y + KITE_EDGE_M && q.y <= hi.y - KITE_EDGE_M;
        let v = Vector2::new(me.vel.x, me.vel.z);
        let moving = if v.length() > 2.0 { v.x.atan2(v.y) } else { me.heading() };
        let side = if wrap(moving - axis) >= 0.0 { 1.0 } else { -1.0 };
        let mut off = 0.0;
        while off <= KITE_OFF_MAX {
            if let Some(q) = [side, -side].into_iter().map(|s| leg(axis + s * off)).find(|&q| inside(q)) {
                return q;
            }
            off += KITE_OFF_STEP;
        }
        leg(axis)
    };
    let escape = |scan: &mut dyn FnMut(&Req) -> Option<Found>, keep: Option<Vector2>, dis: (Vector2, bool)| {
        let hid = scan(&Req { anchor: my, target: None, lo: 0.0, hi: me.gun_range, keep, avoid: None, only: None,
            cover: None, escape: true, cones: cones.clone(), hide: Some(defense(dis)), presumed: false, fire_cones: Vec::new() });
        if let Some(f) = hid {
            return Plan { posture: Posture::Disengage, station: f.station, anchor, heading: 0.0, heading_weight: 0.0,
                hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false, score: f.net, dark: f.dark,
                anchor_id: None, kite: false, cover: true, deep: false };
        }
        if let Some(&(axis, _)) = cones.first().filter(|_| me.seen) {
            return Plan { posture: Posture::Disengage, station: kite_leg(axis), anchor, heading: 0.0, heading_weight: 0.0,
                hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false, score: 0.0, dark: false,
                anchor_id: None, kite: true, cover: false, deep: false };
        }
        let f = scan(&Req { anchor: my, target: None, lo: 0.0, hi: me.gun_range, keep, avoid: None, only: None,
            cover: None, escape: true, cones: if me.seen { cones.clone() } else { Vec::new() }, hide: None, presumed: false, fire_cones: Vec::new() });
        let (station, dark) = f.map_or((my, false), |f| (f.station, f.dark));
        Plan { posture: Posture::Disengage, station, anchor, heading: 0.0, heading_weight: 0.0, hold_radius: HOLD_RADIUS_M,
            set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false, score: f.map_or(0.0, |f| f.net), dark, anchor_id: None,
            kite: f.is_some_and(|f| f.kite), cover: false, deep: false }
    };
    let went_dark = |p: &Plan| p.posture == Posture::Disengage && p.kite && m.cover_ok && !me.seen;
    let still_good = |p: &Plan, scan: &mut dyn FnMut(&Req) -> Option<Found>| if p.cover {
        scan(&Req { anchor: my, target: None, only: Some(p.station), escape: true, hide: Some(defense(dis)), ..req(None, None, None) }).is_some()
    } else {
        scan(&req(None, None, Some(p.station))).is_some_and(|f| f.net >= 0.0 && f.net >= HOLD_AGAIN * p.score && f.dark == p.dark)
    };
    let shot_target = picked.and_then(|c| c.0).filter(|&id| assign.target == Some(id));
    let engage_cover = |p: &Plan| p.cover && p.posture == Posture::Engage;

    // v4 DDBehavior: a held spot station that lights a friend's target stands; else the torpedo boat pushes on its
    // run and the gunboat fights a shootable contact; else Spot. A torpedo boat Spot declines, lit with enemies seen,
    // disengages (dd_no_spot).
    if m.spot_dd && posture != Posture::Disengage {
        let was = assign.spot.on();
        let holding = was && m.spot_lights && d.threat < DISENGAGE_THREAT;
        let fights = if me.torp_boat() { posture == Posture::TorpRun } else { assign.target.is_some() };
        if holding || !fights {
            let seed = m.plan.filter(|_| !was).map_or(Vector2::INF, |p| p.station);
            let mut st = assign.spot;
            if let Some((station, heading, moved)) = spot(&mut st, seed) {
                assign.spot = st;
                let p = Plan { posture: Posture::Engage, station, anchor, heading, heading_weight: 0.0, hold_radius: me.length * 0.5,
                    set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false, score: 0.0, dark: true, anchor_id: picked.and_then(|c| c.0),
                    kite: false, cover: false, deep: false };
                let reason = if !was { Some(if holding { "spot_hold" } else { "spot" }) } else if moved { Some("spot_moved") } else { None };
                return (Some(p), assign, reason);
            }
            assign.spot = Default::default();
            if me.torp_boat() && me.seen && view.iter().any(|(e, _)| e.seen) {
                assign.dis_since = now;
                (assign.dis_toward, assign.dis_ahead) = (Vector2::INF, false);
                return (Some(escape(scan, None, (Vector2::INF, false))), assign, Some("dd_no_spot"));
            }
        }
    }
    assign.spot = Default::default();

    // v4 _select_nav_skill: lit with a threat inside ra the close arm fights without preferring cover; a cruiser
    // under PUSH_THREAT takes the low-threat arm first. v4 _cover_first adds DANGEROUS_SHOOTERS losing trades.
    let nearest = view.iter().map(|(_, p)| p.distance_to(my)).fold(f32::INFINITY, f32::min);
    let bb_on_us = me.seen && view.iter().any(|(e, p)| e.class == HullClass::Bb && p.distance_to(my) <= e.gun_range);
    let ra = match (bb_on_us, me.hp_frac < RA_HURT_HP) {
        (false, _) => RA_BASE_M,
        (true, false) => RA_BB_M,
        (true, true) if me.class == HullClass::Bb => RA_BB_HURT_M,
        (true, true) => RA_CA_HURT_M,
    };
    let close_arm = !(me.class == HullClass::Ca && d.threat < PUSH_THREAT) && me.seen && nearest < ra;
    let prefer = m.cover_ok && d.cover_first && !close_arm;
    // v4 CA _opening: before any contact, advancing cover alone.
    let opening = m.cover_ok && me.class == HullClass::Ca && belief.contacts.is_empty();
    let cover_plan = |f: &Found, why: &'static str, assign: &Assignment| (Some(Plan { posture, station: f.station, anchor,
        heading: broadside(my, anchor, me.heading()), heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: f64::INFINITY,
        serial: 0, shot: f.shot, score: 0.0, dark: false, anchor_id: picked.and_then(|c| c.0), kite: false, cover: true, deep: f.deep }), *assign, Some(why));
    // v4 SkillCover's search, every RESEARCH_S (DEEP_RESEARCH_S for a deep upgrade) whoever asks; `cap` the ratchet.
    let cover_search = |cs: &mut CoverState, cap: f32, upgrade: bool, scan: &mut dyn FnMut(&Req) -> Option<Found>| -> Option<Found> {
        if now - cs.searched < if upgrade { DEEP_RESEARCH_S } else { RESEARCH_S } {
            return None;
        }
        cs.searched = now;
        let from = if cs.resume.is_finite() { cs.resume } else { my };
        cs.resume = Vector2::INF;
        let want = my.distance_to(anchor).max(if picked.and_then(|c| c.0).is_some() { hi } else { 0.0 }).min(cap);
        scan(&Req { hide: Some(offense(from, upgrade, Some((anchor, want)))), ..req(None, None, None) })
    };

    // v4 SkillFight._keep_mode COVER, with _checkpoint's ratchet only when cover is preferred.
    let mut cover_lost: Option<&'static str> = None;
    let mut cs = assign.cover;
    cs.block = None;
    let engaging = posture == Posture::Engage && m.cover_ok;
    let idle = !(assign.target.is_some() && assign.clear);
    if engaging && prefer {
        if !idle || !cs.cp_at.is_finite() || cs.cp_at.distance_to(anchor) > CHECKPOINT_STEP_M {
            cs.cp_d = f32::INFINITY;
            cs.idle_since = f64::INFINITY;
        }
        cs.cp_at = anchor;
    }
    let mut held = m.plan.filter(engage_cover).filter(|_| engaging);
    if let Some(p) = held.filter(|p| prefer && idle && p.station.distance_to(my) <= CHECKPOINT_STEP_M) {
        cs.idle_since = cs.idle_since.min(now);
        if now - cs.idle_since >= CHECKPOINT_IDLE_S / m.style.aggression.max(0.1) as f64 {
            cs.idle_since = f64::INFINITY;
            cs.cp_d = cs.cp_d.min(p.station.distance_to(anchor) - CHECKPOINT_STEP_M);
            cs.searched = f64::NEG_INFINITY;
            held = None;
            cover_lost = Some("checkpoint");
        }
    }
    let cap = if prefer { cs.cp_d } else { f32::INFINITY };
    let switch_cost = |route: f32, deep: bool, soft: bool| route + if deep { 0.0 } else { EDGE_PEN_M } + if soft { SOFT_PEN_M } else { 0.0 };
    let (mut held_cost, mut soft) = (f32::INFINITY, false);
    if let Some(p) = held {
        let lost = if !in_clip(p.station) {
            Some("clip")
        } else {
            match scan(&Req { only: Some(p.station), hide: Some(offense(my, false, None)), ..req(None, None, None) }) {
                None => {
                    cs.resume = p.station;
                    Some("not_covered")
                }
                Some(f) => {
                    let mut lost = None;
                    if p.station.distance_to(my) > ARRIVED_M || f.shot {
                        cs.blocked_since = f64::INFINITY;
                    } else {
                        cs.blocked_since = cs.blocked_since.min(now);
                        if now - cs.blocked_since >= BLOCKED_S {
                            cs.block = Some(p.station);
                            lost = Some("no_shot_here");
                        }
                    }
                    if f.targets > 0 {
                        cs.target_at = now;
                    } else if now - cs.target_at >= COVER_BLIND_S {
                        lost = lost.or(Some("blind"));
                    }
                    soft = f.soft.is_some();
                    held_cost = switch_cost(f.route, f.deep, soft);
                    held = Some(Plan { deep: f.deep && !soft, ..p });
                    lost
                }
            }
        };
        if lost.is_some() {
            held = None;
            cover_lost = lost;
        }
    }
    if let Some(p) = held {
        let upgrade = !p.deep && !soft;
        let found = (upgrade || soft).then(|| cover_search(&mut cs, cap, upgrade, scan)).flatten().filter(|f| !held_cost.is_finite()
            || switch_cost(f.route, f.deep, false) < held_cost - SWITCH_M.max(SWITCH_FRAC * held_cost));
        assign.cover = cs;
        if let Some(f) = found {
            cs.target_at = now;
            cs.blocked_since = f64::INFINITY;
            assign.cover = cs;
            return cover_plan(&f, if upgrade { "cover_deep" } else { "cover_better" }, &assign);
        }
        return (Some(Plan { heading: broadside(my, anchor, me.heading()), anchor, ..p }), assign, None);
    }
    assign.cover = cs;

    // v4 _keep_mode STATION, checked every pass while cover is preferred.
    if let Some(p) = m.plan.filter(|p| !engage_cover(p)) {
        let blocked = blocked(m, &p, my, assign.target);
        let arrived = p.posture == Posture::Engage && p.station.distance_to(my) < p.hold_radius;
        let moved = p.anchor.distance_to(anchor) >= ANCHOR_MOVE_M;
        let recheck = moved || p.cover && p.posture == Posture::Disengage || prefer && p.posture == Posture::Engage && !p.kite;
        let fine = p.posture == posture && !blocked && (!recheck || still_good(&p, scan)) && !lost_shot(&p, shot) && !off_cone(&p) && (p.posture != Posture::Engage || p.kite == kite.is_some())
            && !went_dark(&p)
            && (p.shot || p.posture != Posture::Engage || shot_target.is_none());
        // A disengage cover still hidden is kept: searched again from a turned bow, it flips to the other end.
        let again = fine && (now >= p.hold_until || arrived) && (posture == Posture::Engage || p.cover && posture == Posture::Disengage)
            && still_good(&p, scan);
        if fine && ((now < p.hold_until && !arrived) || again) {
            let mut p = p;
            if again {
                p.hold_until = now + HOLD_S;
            }
            p.heading = broadside(my, anchor, me.heading());
            p.anchor = anchor;
            return (Some(p), assign, None);
        }
    }
    let blocked = m.plan.is_some_and(|p| blocked(m, &p, my, assign.target));
    let reason = match m.plan {
        None => "first",
        Some(p) if p.posture != posture => "posture",
        Some(p) if engage_cover(&p) => cover_lost.unwrap_or(if m.cover_ok { "cover_none" } else { "cover_off" }),
        Some(_) if blocked => "blocked",
        Some(p) if p.cover && p.posture == Posture::Disengage => "dis_cover_lost",
        Some(p) if p.anchor.distance_to(anchor) >= ANCHOR_MOVE_M => "anchor_moved",
        Some(p) if off_cone(&p) => "ring_kite",
        Some(p) if went_dark(&p) => "went_dark",
        Some(p) if p.posture == Posture::Engage && !p.cover && p.kite != kite.is_some() => "kite_end",
        Some(p) if p.posture == Posture::Engage && !p.shot && shot_target.is_some() => "unshot",
        Some(p) if p.station.distance_to(my) < p.hold_radius => "arrived",
        Some(p) if now < p.hold_until => if prefer { "station_not_ok" } else { "no_shot" },
        Some(_) => "expired",
    };

    let plan = match posture {
        Posture::Engage => {
            // v4 _choose: preferred cover (ratcheted), CA opening cover.
            if engaging && (prefer || opening) {
                if let Some(f) = cover_search(&mut cs, cap, false, scan) {
                    cs.target_at = now;
                    cs.blocked_since = f64::INFINITY;
                    assign.cover = cs;
                    return cover_plan(&f, cover_lost.unwrap_or(if opening { "cover_opening" } else { "cover" }), &assign);
                }
                assign.cover = cs;
            }
            let prev = m.plan.filter(|p| p.posture == Posture::Engage && !p.cover);
            let keep = prev.filter(|_| matches!(reason, "expired" | "anchor_moved")).map(|p| p.station);
            let avoid = prev.filter(|_| matches!(reason, "arrived" | "blocked")).map(|p| p.station);
            let station_plan = |f: &Found| Plan { posture, station: f.station, anchor, heading: broadside(my, anchor, me.heading()),
                heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0,
                shot: f.shot, score: f.net, dark: f.dark, anchor_id: picked.and_then(|c| c.0), kite: false, cover: false, deep: false };
            if let Some(a) = kite {
                return (Some(Plan { posture, station: kite_leg(a), anchor, heading: broadside(my, anchor, me.heading()),
                    heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: true, score: 0.0,
                    dark: false, anchor_id: picked.and_then(|c| c.0), kite: true, cover: false, deep: false }), assign, Some(reason));
            }
            // Open water, unless one was too exposed within SHELTER_S and threat has not fallen.
            let found = (now >= assign.shelter_until || d.threat < REENGAGE_THREAT).then(|| {
                scan(&req(keep, avoid, None)).or_else(|| cover.and(scan(&Req { cover: None, ..req(None, None, None) })))
            }).flatten();
            // v4 _fight's doomed station and _brawl's tuck: disengage toward it, or into cover ahead while the guns on a
            // brawler lie wider than a push survives; a brawler whose tuck finds no cover pushes on.
            let doomed = found.as_ref().is_some_and(|f| f.negative);
            if may_disengage && (doomed || m.brawler && m.crossfire > BRAWL_CROSSFIRE) {
                let to = (if doomed { found.as_ref().unwrap().station } else { Vector2::INF }, m.brawler);
                let p = escape(scan, None, to);
                if !(m.brawler && p.kite) {
                    assign.dis_since = now;
                    (assign.dis_toward, assign.dis_ahead) = to;
                    return (Some(p), assign, Some(if m.brawler { "brawl_tuck" } else { "doomed" }));
                }
            }
            if let Some(f) = found.as_ref().filter(|f| !f.negative) {
                assign.shelter_until = f64::NEG_INFINITY;
                return (Some(station_plan(f)), assign, Some(reason));
            }
            if found.is_some() {
                assign.shelter_until = now + SHELTER_S;
            }
            // Calm with nothing in reach: close in rather than hide.
            let lit_in_range = view.iter().any(|(e, p)| e.seen && p.distance_to(my) <= me.gun_range);
            let calm = d.threat < DISENGAGE_THREAT && assign.target.is_none() && !lit_in_range;
            if !calm && engaging {
                if let Some(f) = cover_search(&mut cs, f32::INFINITY, false, scan) {
                    cs.target_at = now;
                    cs.blocked_since = f64::INFINITY;
                    assign.cover = cs;
                    return cover_plan(&f, "cover_fallback", &assign);
                }
                assign.cover = cs;
            }
            if let Some(f) = found.as_ref().filter(|_| !calm) {
                return (Some(station_plan(f)), assign, Some(reason));
            }
            if picked.and_then(|c| c.0).is_some() {
                if let Some(p) = prev.filter(|p| p.shot && !p.kite && !lost_shot(p, shot)) {
                    return (Some(Plan { hold_until: now + HOLD_S, ..p }), assign, Some("no_shot_station"));
                }
            }
            // v4 _close_in: the presumed enemy's station, else _advance up to a window toward the anchor.
            let presumed = belief.presumed_end(my).and_then(|q| scan(&Req { anchor: q, target: None, presumed: true, ..req(None, None, None) }));
            match presumed {
                Some(f) => station_plan(&f),
                None => {
                    let band = anchor + dir_or(my - anchor, Vector2::new(0.0, 1.0)) * ((lo + hi) * 0.5);
                    Plan { posture, station: my + (band - my).limit_length(Some(WINDOW_M)), anchor, heading: broadside(my, anchor, me.heading()),
                        heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0,
                        shot: false, score: 0.0, dark: false, anchor_id: picked.and_then(|c| c.0), kite: false, cover: false, deep: false }
                }
            }
        }
        Posture::TorpRun => {
            let (t, station) = (run_target.unwrap(), run_station.unwrap());
            let tp = t.p2();
            Plan { posture, station, anchor: tp, heading: broadside(my, tp, me.heading()),
                heading_weight: 0.0, hold_radius: HOLD_RADIUS_M, set_at: now, hold_until: now + HOLD_S, serial: 0, shot: false,
                score: 0.0, dark: true, anchor_id: Some(t.id), kite: false, cover: false, deep: false }
        }
        Posture::Disengage => {
            let keep = m.plan.filter(|p| p.posture == Posture::Disengage && reason == "expired").map(|p| p.station);
            escape(scan, keep, dis)
        }
    };
    (Some(plan), assign, Some(reason))
}

const TORP_LANE_BEARINGS: usize = 16;

/// Ahead of the target's bow on our side; else the nearest bearing on our side with a clear lane (v4 torp_mask)
/// outside every seen enemy's sight of us or its sensor.
fn torp_station(t: &ShipState, range: f32, loaded: bool, me: &ShipState, my: Vector2, snap: &Snapshot,
        lane: &mut dyn FnMut(Vector2, &ShipState) -> bool) -> Result<Vector2, &'static str> {
    let range = (if loaded { TORP_RUN_RANGE } else { TORP_WAIT_RANGE } * range).max(me.conceal * crate::bot5::snapshot::SPOT_SAFE);
    let tp = t.p2();
    let away = dir_or(my - tp, Vector2::new(0.0, 1.0));
    let tf = dir_or(Vector2::new(t.vel.x, t.vel.z), Vector2::ZERO);
    let base = dir_or(away + tf * TORP_RUN_LEAD, away);
    let step = std::f32::consts::TAU / TORP_LANE_BEARINGS as f32;
    let sight = me.conceal * crate::bot5::snapshot::SPOT_SAFE;
    let dark = |st: Vector2| snap.enemies_of(me.team).filter(|e| e.seen).all(|e| e.p2().distance_to(st) > sight.max(e.force_spot));
    let (mut lit, mut blocked) = (false, false);
    for k in 0..=TORP_LANE_BEARINGS / 4 {
        for a in if k == 0 { vec![0.0] } else { vec![k as f32 * step, -(k as f32) * step] } {
            let st = tp + base.rotated(a) * range;
            if !dark(st) {
                lit = true;
            } else if !lane(st, t) {
                blocked = true;
            } else {
                return Ok(st);
            }
        }
    }
    Err(if blocked { "torp_run_no_lane" } else if lit { "torp_run_lit" } else { "torp_run_none" })
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
