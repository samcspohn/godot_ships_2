//! Bot controller v5: team hive + per-bot controllers. See doc/BOT_V5_DESIGN.md.

pub mod belief;
pub mod dodge;
pub mod shell_read;
pub mod trade;
pub mod features;
mod field;
pub mod flank;
pub mod gunnery;
pub mod hive;
pub mod params;
pub mod shot;
pub mod snapshot;
pub mod stance;
pub mod station;
pub mod telemetry;
pub mod torpedo;

use godot::classes::{PhysicsDirectSpaceState3D, Resource};
use godot::prelude::*;
use std::collections::HashMap;
use std::sync::Arc;

use crate::nav::gun_matrix::GunMatrix;
use crate::nav::hpa::HpaGraph;
use crate::nav::map::NavigationMap;
use crate::nav::navigator::hull::Hull;
use crate::nav::navigator::ShipNavigator;
use crate::nav::reach::{ReachField, Shell};
use crate::nav::ships::ShipRegistry;
use crate::nav::visibility::VisibilityGrid;
use crate::projectile::manager::point_store::Store;
use crate::projectile::manager::ProjectileManager;
use crate::variant_cast::VariantCast;

use belief::Belief;
use field::{Layout, TeamField};
use flank::{Flanks, Role, Seat};
use gunnery::{Clear, Gunnery, PairTables, TargetLive};
use hive::{Assignment, Committed, Danger, FlankView, Member, Plan, Posture};
use params::{Aptitude, Kinematics, Playstyle};
use shot::{Gun, ShotMap};
use snapshot::{HullClass, ShipState, Snapshot};
use stance::{Rates, Stance};
use station::{Curves, Fire, Scan, Target, Threat};
use telemetry::Telemetry;
use torpedo::{TorpAim, TorpSpec, Tracks};

const HIVE_INTERVAL_S: f64 = 1.0;
const EVENT_MIN_GAP_S: f64 = 0.25;
const HP_EVENT_DROP: f32 = 0.15;
const NAV_STATE_EVERY: i64 = 2;
const NAV_PUSH_EVERY: i64 = 12;
/// New stations pushed to navigators per frame; a hive pass can move many bots at once.
const JUMP_PUSHES_PER_FRAME: u32 = 4;
/// Bots that re-plan per frame; a team pass resumes in its aptitude order on the next frame.
const REPLANS_PER_FRAME: u32 = 2;
/// A cruiser hiding inside this share of its gun range may hold fire to spot.
const DARK_CA_CONCEAL: f32 = 0.7;
const AIM_EVERY: i64 = 3;
const ALT_HOLD_S: f64 = 4.0;
const WALL_SHORT_M: f32 = 200.0;
/// Walls are re-sent to the navigator (a replan) only when one moves this much.
const WALL_MOVE_M: f32 = 500.0;
const STANCE_EVERY: i64 = 4;
const DODGE_EVERY: i64 = 3;
/// v4's torpedo_track_range and obstacle id namespace.
const TORP_TRACK_M: f32 = 3000.0;
const TORP_ID: i32 = -100000;
const TORP_RADIUS_M: f32 = 5.0;
/// A torpedo is tracked if it passes within a hull length plus this many seconds of our top speed.
const TORP_SLACK_S: f32 = 30.0;
/// Gear vetoes re-priced this often per bot.
const VETO_EVERY_S: f64 = 1.0;
/// Mount arcs are sampled toward a point this far off.
const ARC_PROBE_M: f32 = 20000.0;
const STATION_JUMP_M: f32 = 1000.0;
const BOT_INPUT_STRIDE: usize = 18;
const BLOCKED_DECAY_S: f32 = 10.0;
pub const CMD_STRIDE: usize = 19;
const TORP_EVERY: i64 = 8;
const TORP_CANDIDATES: usize = 3;
const TORP_MIN_CHANCE: [f32; 4] = [0.1, 0.2, 0.25, 0.3];
const TORP_FRESH_SALVO_S: f64 = 5.0;
const SPOT_MAX_AGE_S: f64 = 45.0;
const SPOT_DETECT_USE: f32 = 0.8;
const SPOT_ANCHOR_M: f32 = 1500.0;
const SPOT_ALLY_VALUE: f32 = 0.5;
const SPOT_KEEP: f32 = 1.0;
const LANE_CLEARANCE_M: f32 = 300.0;
/// Time to die under this share of the match left scores DISENGAGE_THREAT.
const DISENGAGE_TTD_SHARE: f32 = 0.2;

#[derive(Clone, Copy, Default)]
struct BotInputs {
    ready_guns: i32,
    max_lag_s: f32,
    healable: f32,
    heal_per_use: f32,
    fires: i32,
    floods: i32,
    repair_ready: bool,
    dc_ready: bool,
    rudder: f32,
    engine_power: f32,
    grounded: bool,
    torp_ready: i32,
    torp_live: i32,
    launch_from: Vector2,
    spot_ready: bool,
    spot_active: bool,
}

#[derive(Clone, Copy, Default)]
struct Command {
    throttle: i32,
    rudder: f32,
    aim: Option<Vector3>,
    ammo: i32,
    fire: bool,
    use_repair: bool,
    use_dc: bool,
    torp_aim: Option<Vector2>,
    torp_fire: bool,
    spot: Option<Vector2>,
}

struct Bot {
    ship_id: i64,
    name: String,
    team: i32,
    style: Playstyle,
    /// Last pass: pushing as a brawler, the enemy spotted for the flank, the trade band on the target.
    brawl: bool,
    spot_for: Option<i64>,
    trade_band: Option<(f32, f32)>,
    apt: Aptitude,
    nav: Gd<ShipNavigator>,
    plan: Option<Plan>,
    assign: Assignment,
    pushed: Option<(u32, Vector2)>,
    gun: Gunnery,
    gun_range: f32,
    /// Terrain clearance table for station search; built by prepare().
    shot_gun: Option<Gun>,
    inputs: BotInputs,
    cmd: Command,
    hp_at_pass: f32,
    serial: u32,
    blocked_s: f32,
    blocked_serial: u32,
    last_release: Option<(&'static str, f64)>,
    last_gate: &'static str,
    gates: std::collections::BTreeMap<&'static str, u32>,
    torp: Option<TorpSpec>,
    torp_aim: Option<TorpAim>,
    torp_idx: usize,
    torp_last_fire: f64,
    torp_gate: &'static str,
    /// Spotter tether; 0 = no spotter plane.
    spot_reach: f32,
    spot_target: Option<i64>,
    spot_point: Option<Vector2>,
    role: Option<Role>,
    role_since: f64,
    /// Point-table keys of each enemy's AP/HE against our hull.
    threats: HashMap<i64, [Option<String>; 2]>,
    dmg: Option<DmgSample>,
    hull: crate::nav::types::ShipParams,
    /// Per main-battery mount: bit b set when it bears on a point b stance bins off the bow.
    mounts: Vec<u128>,
    gun_nodes: Vec<Gd<Node3D>>,
    stance: Stance,
    /// Kiting: the quarter (+1/-1) the guns on us sit on, and this tick's heading and point.
    kite_side: f32,
    kite: Option<(f32, Vector2)>,
    /// Enemy shells aimed near us are in the air until then.
    fired_on_until: f64,
    kite_fired: bool,
    veto_at: f64,
    dodge: dodge::Dodge,
    citadel: Rect2,
    reads: shell_read::ShellReads,
    /// Threat rings as route walls, each pulled in short of the station.
    walls: Vec<(Vector2, f32)>,
    walls_new: bool,
    /// Shooting this instead of the assigned target until then.
    alt: Option<(i64, f64)>,
}

/// Last damage sample: cumulative main-battery damage, and the raw predicted rates (per minute) booked until the next.
struct DmgSample {
    at: f64,
    dealt: f32,
    taken: f32,
    rate_in: f32,
    rate_out: f32,
    key_out: Option<String>,
}

struct Pass {
    order: Vec<usize>,
    next: usize,
    committed: Vec<Committed>,
    spot: HashMap<i64, SpotNeed>,
    /// Bot index -> the enemy it spots for its flank; None with none in the field.
    spotters: HashMap<usize, Option<i64>>,
}

/// Who lights an enemy, and each ally's fire on it (HP share per minute) that depends on it being lit.
#[derive(Default)]
struct SpotNeed {
    lit_by: Vec<i64>,
    fire: Vec<(i64, f32)>,
}

#[derive(Default)]
struct TeamHive {
    belief: Belief,
    flanks: Option<Flanks>,
    field: TeamField,
    /// A pass still resolving, spread over frames.
    pass: Option<Pass>,
    next_pass: f64,
    last_pass: f64,
    event: bool,
    alive: usize,
}

#[derive(Default)]
pub struct World {
    map: Option<Gd<NavigationMap>>,
    hpa: Option<Gd<HpaGraph>>,
    space: Option<Gd<PhysicsDirectSpaceState3D>>,
    registry: Option<Gd<ShipRegistry>>,
    pm: Option<Gd<ProjectileManager>>,
    /// Enemy torpedoes the hub saw this frame: [owner team, x, z, vx, vz].
    torps_in: Vec<[f32; 5]>,
    vis: Option<Gd<VisibilityGrid>>,
    reach: Option<Gd<ReachField>>,
    layout: Option<Layout>,
    features: Option<features::Features>,
    matrices: HashMap<i64, Arc<GunMatrix>>,
    curves: Curves,
    store: Option<Store>,
    snap: Snapshot,
    bots: Vec<Bot>,
    teams: HashMap<i32, TeamHive>,
    live: HashMap<i64, TargetLive>,
    tel: Telemetry,
    allies: Vec<ShipState>,
    tracks: Tracks,
    shots: ShotMap,
    frame: i64,
    time_mult: f64,
    time_us: [u64; 4],
    jump_pushes: u32,
    /// Station scan: [cells and scoring, exact rays, curve refresh], µs.
    scan_us: [u64; 4],
    /// This frame's µs per Phase, and every frame's.
    ph: [u32; PHASES],
    phases: Vec<[u32; PHASES]>,
    calib_in: HashMap<String, f32>,
    calib_out: HashMap<String, f32>,
    time_left: f32,
}

/// `gun`'s fire on `id`, posed as `id` lies.
fn fire_of<'a>(snap: &'a Snapshot, curves: &'a Curves, gun: i64, id: i64, keys: Option<&[Option<String>; 2]>) -> Option<Fire<'a>> {
    let (gun, ship) = (snap.get(gun)?, snap.get(id)?);
    let k = keys?;
    let c = [0, 1].map(|a| k[a].as_deref().and_then(|k| curves.get(k)));
    c.iter().any(|c| c.is_some()).then(|| Fire::new(c, gun, ship))
}

/// The threat this far off the stern while kiting; opened to KITE_ANGLE_FIRED while its shells are in the air, which
/// angles the belt further and throws its lead off the stern citadel.
const KITE_ANGLE: f32 = 30.0 * std::f32::consts::PI / 180.0;
const KITE_ANGLE_FIRED: f32 = 35.0 * std::f32::consts::PI / 180.0;
const KITE_EVERY: i64 = 3;
/// Summed sine of the turrets' swing off the centreline below which no beam is trained.
const TRAINED_MIN: f32 = 0.5;
/// Stance's window about the kite heading.
const KITE_TOL: f32 = 0.0;
const KITE_REACH_M: f32 = 3000.0;
const KITE_REACH_TURNS: f32 = 8.0;
const KITE_SWING: f32 = 15.0 * std::f32::consts::PI / 180.0;
const KITE_SWING_MAX: f32 = 150.0 * std::f32::consts::PI / 180.0;
const KITE_SAMPLES: usize = 12;
/// Open legs priced for a shot, nearest the wanted heading first.
const KITE_LEGS: usize = 4;

/// Short of the trade range a station may sit, and past it.
const BAND_OUT_M: f32 = 1500.0;
/// v4 _brawl: push to this, while the guns on us lie within BRAWL_CROSSFIRE.
const BRAWL_CROSSFIRE: f32 = std::f32::consts::FRAC_PI_2;
/// Kite out while in this share of the band nearest the target: a station across the bow lets an equal-speed chaser in.
const KITE_BAND: f32 = 0.5;
/// The ring sits this far inside the band.
const RING_IN_M: f32 = 500.0;
/// Spotting short of the target's detection by this much.
const SPOT_INSET_M: f32 = 500.0;

struct Hold {
    trade: trade::Trade,
    /// Our secondaries out-gun our mains on this enemy, crossfire aside.
    brawler: bool,
    band: (f32, f32),
    ring: f32,
    brawl: bool,
}

/// Inside the target's detection, past our own when it sees farther than we hide; at its detection when it hides better.
fn spot_band(me: &snapshot::ShipState, e: &snapshot::ShipState) -> (f32, f32) {
    let hi = (e.conceal - SPOT_INSET_M).max(0.0);
    if e.conceal <= me.conceal { ((hi - BAND_OUT_M).max(0.0), hi) } else { (me.conceal.min(hi), hi) }
}

/// Each field source once, with its fire on `bot` and its gun-matrix row from its cell.
fn threats_of<'a>(field: &'a TeamField, bot: &Bot, snap: &'a Snapshot, curves: &'a Curves,
        matrices: &'a HashMap<i64, Arc<GunMatrix>>, tel: &mut Vec<&'static str>, ahead: bool) -> Vec<Threat<'a>> {
    let mut out = Vec::new();
    for (_, now_i, ahead_i) in sources_by_id(field) {
        let s = &field.sources[if ahead { ahead_i } else { now_i }];
        let Some(f) = fire_of(snap, curves, s.id, s.id, bot.threats.get(&s.id)) else {
            tel.push("threat_no_table");
            continue;
        };
        let f = if shell_read_on() { f.read(bot.reads.read(s.id)) } else { f };
        let row = matrices.get(&s.id).and_then(|m| m.row(s.cell));
        out.push(Threat { at: s.at, range: f.ship.gun_range, row, fire: f, aim: 1.0, ring: 0.0 });
    }
    out
}

/// Per enemy id its source now, and its source ahead (the same one when not forecast).
fn sources_by_id(field: &TeamField) -> Vec<(i64, usize, usize)> {
    let mut out: Vec<(i64, usize, usize)> = Vec::new();
    for (i, s) in field.sources.iter().enumerate() {
        match out.iter_mut().find(|o| o.0 == s.id) {
            Some(o) if s.ahead => o.2 = i,
            Some(_) => {}
            None => out.push((s.id, i, i)),
        }
    }
    out
}

/// (heading, weight, prefer reverse, forbid reverse) for the navigator; off leaves it its own gear.
fn helm(s: &Stance) -> (f32, f32, bool, bool) {
    if s.active { (s.heading, 1.0, s.astern, !s.astern) } else { (s.heading, 0.0, false, false) }
}

/// The beam (+1/-1, as `stance::best_in` signs it off `hdg`) the live main turrets point to now, each weighted by how far
/// it is swung off the centreline; None when they sit fore and aft.
fn trained_beam(guns: &[Gd<Node3D>], hdg: f32) -> Option<f32> {
    let s: f32 = guns.iter().filter(|g| g.is_instance_valid()).filter(|g| !crate::combat::turret::Turret::load((*g).clone()).is_disabled())
        .map(|g| {
            let f = -g.get_global_transform().basis.col_c();
            stance::wrap(f.x.atan2(f.z) - hdg).sin()
        }).sum();
    (s.abs() >= TRAINED_MIN).then(|| s.signum())
}

fn mount_masks(cfg: &VarDictionary) -> Vec<u128> {
    let (Some(guns), Some(hull)) = (cfg.get("guns").and_then(|v| v.try_to::<AnyArray>().ok()),
        cfg.get("hull").and_then(|v| v.try_to::<Gd<Node3D>>().ok())) else { return Vec::new() };
    let xf = hull.get_global_transform();
    let f = -xf.basis.col_c();
    let h0 = f.x.atan2(f.z);
    guns.iter_shared().filter_map(|g| g.try_to::<Gd<Node3D>>().ok()).map(|g| {
        let t = crate::combat::turret::Turret::load(g);
        (0..stance::BINS).filter(|&b| {
            let a = h0 + stance::heading_of(b);
            let at = xf.origin + Vector3::new(a.sin(), 0.0, a.cos()) * ARC_PROBE_M;
            t.in_fire_arcs(stance::wrap((t.rot_y() + t.angle_to_target(at)) as f32) as f64)
        }).fold(0u128, |m, b| m | 1 << b)
    }).filter(|&m| m != 0).collect()
}

/// Per shell, dodge::ASPECTS weights: its shooter's damage per hit on us by the aspect it arrives at (AP or HE as the
/// shell is), over that row's mean; 1 where no shooter lies within SOURCE_MATCH of where it came from or no table.
fn shell_aspects(snap: &Snapshot, curves: &Curves, threats: &HashMap<i64, [Option<String>; 2]>, team: i32,
        shells: &[(crate::projectile::manager::ShellLandingEntry, f32)]) -> Vec<f32> {
    let step = 180.0 / (dodge::ASPECTS - 1) as f32;
    let mut out = Vec::with_capacity(shells.len() * dodge::ASPECTS);
    for (e, _) in shells {
        let land = Vector2::new(e.landing_x, e.landing_z);
        let src = shell_source(snap, team, e);
        let curve = src.and_then(|s| threats.get(&s.id)?[e.is_he as usize].as_deref().and_then(|k| curves.get(k)));
        let row: Vec<f32> = match (src, curve) {
            (Some(s), Some(c)) => {
                let r = s.p2().distance_to(land);
                (0..dodge::ASPECTS).map(|a| c.hit_at(r, a as f32 * step)).collect()
            }
            _ => Vec::new(),
        };
        let mean = row.iter().sum::<f32>() / dodge::ASPECTS as f32;
        if mean > 0.0 {
            out.extend(row.iter().map(|v| v / mean));
        } else {
            out.extend(std::iter::repeat_n(1.0, dodge::ASPECTS));
        }
    }
    out
}

/// The enemy of `team` within SOURCE_MATCH of the bearing a shell arrives from (its landing velocity), in gun range.
fn shell_source<'a>(snap: &'a Snapshot, team: i32, e: &crate::projectile::manager::ShellLandingEntry) -> Option<&'a ShipState> {
    const SOURCE_MATCH: f32 = 10.0 * std::f32::consts::PI / 180.0;
    let land = Vector2::new(e.landing_x, e.landing_z);
    let from = (-e.landing_vx).atan2(-e.landing_vz);
    snap.ships.iter().filter(|s| s.alive && s.team != team && s.p2().distance_to(land) <= s.gun_range * 1.1)
        .map(|s| (stance::wrap(stance::bearing(land, s.p2()) - from).abs(), s))
        .filter(|(d, _)| *d <= SOURCE_MATCH)
        .min_by(|a, b| a.0.total_cmp(&b.0))
        .map(|(_, s)| s)
}

/// Whether a torpedo at `at` running `v` passes within `reach` of us at any point ahead, our course held.
fn torp_closes(my: Vector2, my_v: Vector2, at: Vector2, v: Vector2, reach: f32) -> bool {
    let (d, rv) = (at - my, v - my_v);
    let t = (-d.dot(rv) / rv.length_squared().max(1e-3)).max(0.0);
    (d + rv * t).length() <= reach
}

fn shell_read_on() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var("SHIPS_BOT5_SHELL_READ").map_or(true, |v| v != "0"))
}

fn dodge_aspect() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var("SHIPS_BOT5_DODGE_ASPECT").map_or(true, |v| v != "0"))
}

fn dodge_trace() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SHIPS_BOT5_DODGE_TRACE").is_some())
}

fn stance_trace() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SHIPS_BOT5_STANCE_TRACE").is_some())
}

/// Share of an enemy's aim (at `at`, reaching `range`) we draw against our lit allies it reaches, nearer pulling as 1/d².
fn aim_share(snap: &Snapshot, team: i32, me: &ShipState, at: Vector2, range: f32) -> f32 {
    let w = |p: Vector2| 1.0 / p.distance_squared_to(at).max(1.0);
    let mine = w(me.p2());
    let rest: f32 = snap.allies_of(team).filter(|a| a.alive && a.seen && a.id != me.id && a.p2().distance_to(at) <= range).map(|a| w(a.p2())).sum();
    mine / (mine + rest)
}

fn class_key(c: HullClass) -> String {
    format!("{c:?}")
}

impl World {
    /// Books the raw predicted rates since the last sample against what landed, then predicts from here.
    fn damage_sample(&mut self, i: usize, now: f64, dealt: f32, taken: f32) {
        let Some(bot) = self.bots.get(i) else { return };
        let (Some(me), Some(vis), Some(h)) = (self.snap.get(bot.ship_id), &self.vis, self.teams.get(&bot.team)) else { return };
        if let Some(d) = &bot.dmg {
            let dt = (now - d.at) as f32 / 60.0;
            self.tel.calib(format!("in|{:?}", me.class), d.rate_in * dt, taken - d.taken, dt);
            if let Some(k) = &d.key_out {
                self.tel.calib(k.clone(), d.rate_out * dt, dealt - d.dealt, dt);
            }
        }
        let vis = vis.bind();
        let mut tel = Vec::new();
        let mut threats = threats_of(&h.field, bot, &self.snap, &self.curves, &self.matrices, &mut tel, false);
        for t in threats.iter_mut() {
            t.fire.sec_on = false;
        }
        let p = me.p2();
        let rate_in = vis.cell_of(p).map_or(0.0, |k| station::exposure_at(&threats, h.field.seen_at(&vis, k, me.conceal.max(me.gun_range)), k, p));
        let tgt = bot.assign.target.and_then(|id| self.snap.get(id)).filter(|t| t.alive && t.seen && t.p2().distance_to(p) <= me.gun_range);
        let out = tgt.and_then(|t| fire_of(&self.snap, &self.curves, me.id, t.id, bot.gun.pairs.get(&t.id).map(|q| &q.keys))
            .map(|f| (Target { ship: t, at: t.p2(), fire: f.mains() }.value_at(p), format!("out|{:?}>{:?}", me.class, t.class))));
        let s = DmgSample { at: now, dealt, taken, rate_in, rate_out: out.as_ref().map_or(0.0, |o| o.0), key_out: out.map(|o| o.1) };
        self.bots[i].dmg = Some(s);
    }
}

/// beliefs, tracks, flanks, field, curves, spot_needs, resolve, scans, spotters, drive, guns, torps, consumables, tel, valid_station, stance
const PHASES: usize = 16;

fn us(t: std::time::Instant) -> u32 {
    t.elapsed().as_micros() as u32
}

/// Unset or anything but "0" is on.
fn env_on(k: &str) -> bool {
    std::env::var(k).map_or(true, |v| v != "0")
}

fn scan_trace() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SHIPS_BOT5_SCAN_TRACE").is_some())
}

impl World {
    fn add_bot(&mut self, cfg: &VarDictionary) -> i32 {
        let g = |k: &str| cfg.get(k).map_or(0.0, |v| v.to_f32());
        let ship_id = cfg.get("ship_id").map_or(0, |v| v.to_i64());
        let name = cfg.get("name").map_or_else(String::new, |v| v.to_string());
        let team = g("team") as i32;
        let class = HullClass::from_i32(g("hull_class") as i32);
        let kin = Kinematics {
            turning_circle_radius: g("turning_circle_radius"),
            rudder_response_time: g("rudder_response_time"),
            acceleration_time: g("acceleration_time"),
            deceleration_time: g("deceleration_time"),
            max_speed: g("max_speed"),
            reverse_speed_ratio: g("reverse_speed_ratio"),
            length: g("length"),
            beam: g("beam"),
            turn_speed_loss: g("turn_speed_loss"),
            linear_drag: g("linear_drag"),
            turn_tightening: g("turn_tightening"),
        };
        let mut nav = ShipNavigator::new_gd();
        let hull;
        {
            let mut n = nav.bind_mut();
            n.map = self.map.clone();
            n.hpa_graph = self.hpa.clone();
            n.set_ship_params_impl(kin.turning_circle_radius, kin.rudder_response_time, kin.acceleration_time,
                kin.deceleration_time, kin.max_speed, kin.reverse_speed_ratio, kin.length, kin.beam,
                kin.turn_speed_loss, kin.linear_drag, kin.turn_tightening);
            if let Some(r) = &self.registry {
                n.ship_source = Some(r.bind().ships.clone());
                n.own_ship_id = ship_id;
                n.own_team = team;
            }
            n.bot_id = self.bots.len() as i32;
            hull = n.params;
            if let Some(h) = &self.hpa {
                let h = h.bind();
                if h.is_built() {
                    h.region_labels(n.get_ship_clearance());
                }
            }
        }
        let shell = |k: &str| cfg.get(k).and_then(|v| v.try_to::<Gd<Resource>>().ok());
        let gun = Gunnery::new([shell("shell_ap"), shell("shell_he")], [g("damage_ap"), g("damage_he")], g("reload").max(0.1), g("gun_h"));
        let torp = (g("torp_range") > 0.0).then(|| TorpSpec {
            speed: g("torp_speed"),
            range: g("torp_range"),
            tubes: g("torp_tubes").max(1.0) as i32,
            detect: g("torp_detect"),
        });
        self.teams.entry(team).or_default();
        self.bots.push(Bot {
            ship_id,
            name,
            team,
            style: Playstyle::from_i32(cfg.get("playstyle").map_or(-1, |v| v.to_i32()), class),
            brawl: false,
            spot_for: None,
            trade_band: None,
            apt: Aptitude { level: g("aptitude") as i32 },
            nav,
            plan: None,
            assign: Assignment::default(),
            pushed: None,
            gun,
            gun_range: g("gun_range"),
            shot_gun: None,
            inputs: BotInputs::default(),
            cmd: Command::default(),
            hp_at_pass: 1.0,
            serial: 0,
            blocked_s: 0.0,
            blocked_serial: 0,
            last_release: None,
            last_gate: "",
            gates: Default::default(),
            torp,
            torp_aim: None,
            torp_idx: 0,
            torp_last_fire: f64::NEG_INFINITY,
            torp_gate: "",
            spot_reach: g("spot_reach"),
            spot_target: None,
            spot_point: None,
            role: None,
            role_since: 0.0,
            threats: HashMap::new(),
            dmg: None,
            hull,
            mounts: mount_masks(cfg),
            gun_nodes: cfg.get("guns").and_then(|v| v.try_to::<AnyArray>().ok())
                .map_or_else(Vec::new, |a| a.iter_shared().filter_map(|g| g.try_to::<Gd<Node3D>>().ok()).collect()),
            stance: Stance::default(),
            kite_side: 0.0,
            kite: None,
            fired_on_until: f64::NEG_INFINITY,
            kite_fired: false,
            veto_at: f64::NEG_INFINITY,
            dodge: dodge::Dodge::default(),
            reads: shell_read::ShellReads::default(),
            citadel: cfg.get("citadel").and_then(|v| v.try_to::<Rect2>().ok()).unwrap_or_default(),
            walls: Vec::new(),
            walls_new: false,
            alt: None,
        });
        (self.bots.len() - 1) as i32
    }

    /// Terrain copy and per-bot clearance tables, at match setup rather than on the first hive pass.
    fn prepare(&mut self) -> bool {
        if !self.shots.ready(&self.map) {
            return false;
        }
        if self.layout.is_none() {
            let Some(v) = &self.vis else { return false };
            let v = v.bind();
            if !v.is_ready() {
                return false;
            }
            let lay = Layout::new(&v);
            let t = std::time::Instant::now();
            self.features = Some(features::Features::build(&v, &lay));
            let f = self.features.as_ref().unwrap();
            godot_print!("bot5 features: {} islands, {} berths, {} gaps, {} lattice in {} ms", f.islands.len(),
                f.islands.iter().map(|i| i.berths.len()).sum::<usize>(), f.gaps.len(), f.lattice.len(), t.elapsed().as_millis());
            self.layout = Some(lay);
        }
        for b in self.bots.iter_mut().filter(|b| b.shot_gun.is_none()) {
            b.shot_gun = b.gun.spec(b.gun_range).and_then(|g| self.shots.gun(g));
        }
        true
    }

    fn tick(&mut self, now: f64, dt: f32, time_mult: f64) {
        self.frame += 1;
        self.time_mult = time_mult;
        self.ph = [0; PHASES];
        let t0 = std::time::Instant::now();
        self.update_beliefs(now);
        self.ph[0] = us(t0);
        let t = std::time::Instant::now();
        self.tracks.update(now, &self.snap.ships);
        self.ph[1] = us(t);
        self.hive(now);
        let t = std::time::Instant::now();
        for i in 0..self.bots.len() {
            if self.frame % STANCE_EVERY == i as i64 % STANCE_EVERY {
                self.stance(i, now);
            }
        }
        for i in 0..self.bots.len() {
            if self.frame % DODGE_EVERY == i as i64 % DODGE_EVERY {
                self.dodge(i, now);
            }
        }
        self.ph[15] = us(t);
        let t1 = std::time::Instant::now();
        self.jump_pushes = 0;
        for i in 0..self.bots.len() {
            self.drive(i, dt, now);
        }
        if scan_trace() && self.frame % 36 == 0 {
            for b in &self.bots {
                let Some(me) = self.snap.get(b.ship_id).filter(|s| s.alive) else { continue };
                let Some(e) = self.snap.enemies_of(b.team).filter(|e| e.alive).min_by(|x, y| x.pos.distance_to(me.pos).total_cmp(&y.pos.distance_to(me.pos))) else { continue };
                let away = me.p2() - e.p2();
                let off = stance::wrap(me.heading() - away.x.atan2(away.y)).to_degrees();
                let st = b.plan.map(|p| p.station - me.p2()).map_or(f32::NAN, |d| stance::wrap(d.x.atan2(d.y) - away.x.atan2(away.y)).to_degrees());
                godot_print!("move5 t={:.0} {} pos=({:.0},{:.0}) eseen={} gr={} st=({:.0},{:.0}) d={:.0} v={:.1} hdg_off_away={:.0} station_off_away={:.0} st_d={:.0} posture={:?} dodge={} thr={}",
                    now, b.name, me.pos.x, me.pos.z, e.seen, b.inputs.grounded, b.plan.map_or(0.0, |p| p.station.x), b.plan.map_or(0.0, |p| p.station.y), away.length(), me.speed(), off, st, b.plan.map_or(0.0, |p| p.station.distance_to(me.p2())),
                    b.plan.map(|p| p.posture), b.dodge.active(now).map_or("-", |p| p.kind), b.cmd.throttle);
                let n = b.nav.bind();
                godot_print!("nav5 t={:.0} {} state={} fail={} reason={} path={} wp=({:.0},{:.0}) walls={}", now, b.name, n.get_nav_state(), n.get_path_failure_count(),
                    n.get_last_path_failure_reason_name(), n.get_current_path().len(), n.get_current_waypoint().x, n.get_current_waypoint().z, b.walls.len());
            }
        }
        let t2 = std::time::Instant::now();
        self.ph[9] = (t2 - t1).as_micros() as u32;
        for i in 0..self.bots.len() {
            let t = std::time::Instant::now();
            self.guns(i, now, dt, time_mult);
            if self.guns_dark(i) {
                self.bots[i].cmd.fire = false;
            }
            let g = std::time::Instant::now();
            self.torps(i, now);
            let c = std::time::Instant::now();
            self.consumables(i);
            self.spot_cmd(i);
            self.ph[10] += (g - t).as_micros() as u32;
            self.ph[11] += (c - g).as_micros() as u32;
            self.ph[12] += us(c);
        }
        let t = std::time::Instant::now();
        self.tel.resolve(now, &self.snap);
        self.ph[13] = us(t);
        let t3 = std::time::Instant::now();
        self.time_us[0] += (t1 - t0).as_micros() as u64;
        self.time_us[1] += (t2 - t1).as_micros() as u64;
        self.time_us[2] += (t3 - t2).as_micros() as u64;
        self.phases.push(self.ph);
    }

    fn update_beliefs(&mut self, now: f64) {
        let map = self.map.as_ref().map(|m| m.bind());
        let water = |p: Vector2| map.as_ref().is_none_or(|m| m.is_navigable_impl(p.x, p.y, LANE_CLEARANCE_M));
        for (&team, h) in self.teams.iter_mut() {
            if h.belief.update(now, &self.snap, team, &water) > 0 {
                h.event = true;
            }
            let alive = self.snap.allies_of(team).count();
            if alive < h.alive {
                h.event = true;
            }
            h.alive = alive;
        }
        for b in &self.bots {
            let Some(me) = self.snap.get(b.ship_id) else { continue };
            if me.alive && b.hp_at_pass - me.hp_frac >= HP_EVENT_DROP {
                if let Some(h) = self.teams.get_mut(&b.team) {
                    h.event = true;
                }
            }
        }
    }

    fn hive(&mut self, now: f64) {
        if let Some(team) = self.teams.iter().find(|(_, h)| h.pass.is_some()).map(|(&t, _)| t) {
            self.run_pass(team, now);
            return;
        }
        let mut teams: Vec<i32> = self.teams.keys().copied().collect();
        // One pass per frame, most overdue first: two teams' passes in one frame stack their cost.
        teams.sort_by(|a, b| self.teams[a].next_pass.total_cmp(&self.teams[b].next_pass));
        for team in teams {
            let h = self.teams.get_mut(&team).unwrap();
            if h.last_pass == 0.0 && h.next_pass == 0.0 {
                // Teams half an interval apart, so their passes never share a frame on the clock.
                h.next_pass = now + HIVE_INTERVAL_S * 0.5 * team.rem_euclid(2) as f64;
            }
            let due = now >= h.next_pass || (h.event && now - h.last_pass >= EVENT_MIN_GAP_S);
            if !due {
                continue;
            }
            if h.event {
                self.tel.count("hive_event_pass");
            }
            h.event = false;
            h.last_pass = now;
            h.next_pass = now + HIVE_INTERVAL_S;
            self.tel.count("hive_pass");
            self.solve_team(team, now);
            break;
        }
    }

    fn update_flanks(&mut self, team: i32, now: f64) {
        let h = self.teams.get_mut(&team).unwrap();
        if h.flanks.is_none() {
            if let (Some(o), Some(e)) = (h.belief.own_spawn, h.belief.enemy_spawn) {
                h.flanks = Some(Flanks::new(o, e, h.belief.presumed.len() + h.belief.contacts.len()));
            }
        }
        let Some(f) = h.flanks.as_mut() else { return };
        f.update(&h.belief, now);
        let mut seats: Vec<Seat> = self.bots.iter().enumerate()
            .filter(|(_, b)| b.team == team)
            .filter_map(|(i, b)| self.snap.get(b.ship_id).filter(|s| s.alive).map(|s| Seat {
                idx: i, pos: s.p2(), hp: s.hp_frac, apt: b.apt.level, style: b.style, role: b.role, since: b.role_since,
            }))
            .collect();
        for w in f.assign(&mut seats, now) {
            self.tel.count(w);
        }
        let p: Vec<f32> = f.groups.iter().filter(|g| g.live()).map(|g| g.pressure()).collect();
        if p.len() > 1 && p.iter().copied().fold(0.0, f32::max) > flank::IMBALANCED * p.iter().copied().fold(f32::INFINITY, f32::min) {
            self.tel.count("flank_imbalanced_pass");
        }
        for s in seats {
            self.bots[s.idx].role = s.role;
            self.bots[s.idx].role_since = s.since;
        }
    }

    fn update_field(&mut self, team: i32, now: f64) {
        let (Some(lay), Some(vis)) = (&self.layout, &self.vis) else { return };
        let vis = vis.bind();
        let reach = self.reach.as_ref().map(|r| r.bind());
        let (snap, matrices) = (&self.snap, &mut self.matrices);
        let mut matrix = |id: i64| -> Option<Arc<GunMatrix>> {
            if let Some(m) = matrices.get(&id) {
                return Some(m.clone());
            }
            let s = snap.get(id)?;
            let m = reach.as_ref()?.ensure_matrix(Shell { speed: s.shell_speed, drag: s.shell_drag, range: s.gun_range, gun_h: s.gun_h })?;
            matrices.insert(id, m.clone());
            Some(m)
        };
        let ghost_range = snap.enemies_of(team).filter(|s| s.alive).map(|s| s.gun_range).fold(0.0, f32::max);
        let h = self.teams.get_mut(&team).unwrap();
        h.field.build(lay, &vis, &h.belief, snap, now, ghost_range, &mut matrix);
        // Enemy cells: their own gun's rows (fire on us) and our guns' columns (our fire on them).
        type Want = (Arc<GunMatrix>, Vec<u32>, Vec<u32>, Vec<Vector2>);
        let mut want: HashMap<*const GunMatrix, Want> = HashMap::new();
        fn entry(want: &mut HashMap<*const GunMatrix, Want>, m: Arc<GunMatrix>) -> &mut Want {
            want.entry(Arc::as_ptr(&m)).or_insert_with(|| (m, Vec::new(), Vec::new(), Vec::new()))
        }
        let own: Vec<Arc<GunMatrix>> = snap.allies_of(team).filter(|s| s.alive).filter_map(|s| matrix(s.id)).collect();
        let aim_cells: Vec<usize> = h.field.ghosts.iter().filter(|g| !g.ahead).map(|g| g.cell)
            .chain(h.flanks.iter().flat_map(|f| f.groups.iter()).filter_map(|g| vis.cell_of(g.centre))).collect();
        for &c in &aim_cells {
            for m in &own {
                entry(&mut want, m.clone()).2.push(c as u32);
            }
        }
        for s in &h.field.sources {
            if let Some(m) = matrix(s.id) {
                let w = entry(&mut want, m);
                w.1.push(s.cell as u32);
                w.3.push(s.at);
            }
            for m in &own {
                entry(&mut want, m.clone()).2.push(s.cell as u32);
            }
        }
        let slot = team.clamp(0, 1) as usize;
        for (m, mut rows, mut cols, at) in want.into_values() {
            rows.dedup();
            cols.sort_unstable();
            cols.dedup();
            m.demand(slot, rows, cols);
            m.set_sites(slot, at);
        }
        for _ in 0..h.field.missing_rows {
            self.tel.count("field_row_missing");
        }
    }

    /// Ascending aptitude: weaker bots commit first; stronger ones plan around them.
    fn solve_team(&mut self, team: i32, now: f64) {
        let t = std::time::Instant::now();
        self.update_flanks(team, now);
        self.ph[2] += us(t);
        let t0 = std::time::Instant::now();
        self.update_field(team, now);
        self.time_us[3] += t0.elapsed().as_micros() as u64;
        self.ph[3] += us(t0);
        let mut order: Vec<usize> = (0..self.bots.len())
            .filter(|&i| self.bots[i].team == team && self.snap.get(self.bots[i].ship_id).is_some_and(|s| s.alive))
            .collect();
        order.sort_by_key(|&i| (self.bots[i].apt.level, self.bots[i].ship_id));
        let store = self.store.clone();
        let tc = std::time::Instant::now();
        if let Some(s) = &store {
            let mut budget = station::REBUILDS_PER_PASS;
            'keys: for &i in &order {
                let b = &self.bots[i];
                for k in b.gun.pairs.values().flat_map(|p| p.keys.iter()).chain(b.threats.values().flat_map(|t| t.iter())).flatten() {
                    if self.curves.refresh(s, k, now) {
                        budget -= 1;
                        if budget == 0 {
                            break 'keys;
                        }
                    }
                }
            }
        }
        self.scan_us[2] += tc.elapsed().as_micros() as u64;
        self.ph[4] += us(tc);
        let n = order.len();
        let ts = std::time::Instant::now();
        let spot = self.spot_needs(team);
        let spotters = if env_on("SHIPS_BOT5_SPOTTERS") { self.assign_spotters(team, &order) } else { HashMap::new() };
        for _ in &spotters {
            self.tel.count("spotter_role");
        }
        self.ph[5] += us(ts);
        self.teams.get_mut(&team).unwrap().pass = Some(Pass { order, next: 0, committed: Vec::with_capacity(n), spot, spotters });
        self.run_pass(team, now);
    }

    /// Per enemy in the field, the band v4's trade holds bot `i` to, and whether its secondaries win it up close.
    fn holds(&self, i: usize, team: i32, me: &snapshot::ShipState) -> HashMap<i64, Hold> {
        let bot = &self.bots[i];
        let field = &self.teams[&team].field;
        let theirs = threats_of(field, bot, &self.snap, &self.curves, &self.matrices, &mut Vec::new(), false);
        let k_in = *self.calib_in.get(&class_key(me.class)).unwrap_or(&1.0);
        let my_hp = (me.hp_frac * me.hp_max).max(1.0);
        let budget = trade::TTK_BUDGET_SHARE * self.time_left.max(60.0);
        let mut bearings: Vec<f32> = field.sources.iter().filter(|s| !s.ahead)
            .filter(|s| self.snap.get(s.id).is_some_and(|e| s.at.distance_to(me.p2()) <= e.gun_range * 1.05))
            .map(|s| (s.at.x - me.pos.x).atan2(s.at.y - me.pos.z)).collect();
        let crossfire = station::arc_of(&mut bearings);
        // Gun ships' torpedoes are for close quarters they fall into, not a range to seek.
        let me = &if me.torp_boat() { *me } else { snapshot::ShipState { torp_range: 0.0, ..*me } };
        let mut out = HashMap::new();
        for (id, _, _) in sources_by_id(field) {
            let Some(e) = self.snap.get(id) else { continue };
            let ours = fire_of(&self.snap, &self.curves, me.id, id, bot.gun.pairs.get(&id).map(|q| &q.keys));
            let k_out = *self.calib_out.get(&format!("{:?}>{:?}", me.class, e.class)).unwrap_or(&1.0);
            let us = trade::Side { ship: me, fire: ours.as_ref(), k: k_out, hp: my_hp };
            let them = trade::Side { ship: e, fire: theirs.iter().find(|t| t.fire.ship.id == id).map(|t| &t.fire), k: k_in,
                hp: (e.hp_frac * e.hp_max).max(1.0) };
            let t = trade::desired(&us, &them, me.hp_frac, bot.style.style().aggression, budget);
            let brawler = ours.as_ref().is_some_and(|f| trade::brawler(f, me, me.guns_bear));
            let brawl = brawler && crossfire <= BRAWL_CROSSFIRE;
            let (lo, hi) = if brawl { (0.0, trade::BRAWL_RANGE_M.min(t.range)) } else { t.band };
            out.insert(id, Hold { trade: t, brawler, band: (lo, hi), ring: if brawl { 0.0 } else { (lo - RING_IN_M).max(0.0) }, brawl });
        }
        out
    }

    /// One spotter per flank (a lone ship spots for itself): torpedo DD, gunboat DD, BB, then CA. It spots the flank's
    /// enemy nearest it.
    fn assign_spotters(&self, team: i32, order: &[usize]) -> HashMap<usize, Option<i64>> {
        let rank = |s: &snapshot::ShipState| match s.class {
            HullClass::Dd if s.torp_range > 0.0 => 0,
            HullClass::Dd => 1,
            HullClass::Bb => 2,
            HullClass::Ca => 3,
            HullClass::Cv => 9,
        };
        let hive = &self.teams[&team];
        let mut roles: Vec<Option<Role>> = Vec::new();
        for &i in order {
            if !roles.contains(&self.bots[i].role) {
                roles.push(self.bots[i].role);
            }
        }
        let mut out = HashMap::new();
        for r in roles {
            let pick = order.iter().copied().filter(|&i| self.bots[i].role == r)
                .filter_map(|i| self.snap.get(self.bots[i].ship_id).map(|s| (i, s)))
                .filter(|(_, s)| rank(s) < 9)
                .min_by_key(|(i, s)| (rank(s), self.bots[*i].ship_id));
            let Some((i, me)) = pick else { continue };
            let ids = r.zip(hive.flanks.as_ref()).map(|(r, f)| f.view(r, me.p2()).0);
            let near = hive.field.sources.iter().filter(|s| !s.ahead && ids.as_ref().is_none_or(|ids| ids.contains(&s.id)))
                .min_by(|a, b| a.at.distance_to(me.p2()).total_cmp(&b.at.distance_to(me.p2())));
            out.insert(i, near.map(|s| s.id));
        }
        out
    }

    /// Per enemy in the field: allies lighting it now (eyes with line of sight, or radar/hydro), and bots' fire on it.
    fn spot_needs(&self, team: i32) -> HashMap<i64, SpotNeed> {
        let mut out: HashMap<i64, SpotNeed> = HashMap::new();
        let Some(vis) = &self.vis else { return out };
        let vis = vis.bind();
        let field = &self.teams[&team].field;
        for s in field.sources.iter().filter(|s| !s.ahead) {
            let Some(e) = self.snap.get(s.id) else { continue };
            let n = out.entry(s.id).or_default();
            let hp = (e.hp_frac * e.hp_max).max(1.0);
            for a in self.snap.allies_of(team).filter(|a| a.alive) {
                let d = a.p2().distance_to(s.at);
                let eyes = d <= e.conceal && vis.cell_of(a.p2()).is_some_and(|k| vis.visible_idx(k, s.cell));
                if eyes || d <= a.force_spot {
                    n.lit_by.push(a.id);
                }
                if d > a.gun_range {
                    continue;
                }
                let Some(b) = self.bots.iter().find(|b| b.ship_id == a.id).filter(|b| b.assign.target.is_none_or(|t| t == s.id)) else { continue };
                if let Some(f) = fire_of(&self.snap, &self.curves, a.id, s.id, b.gun.pairs.get(&s.id).map(|q| &q.keys)) {
                    let k = *self.calib_out.get(&format!("{:?}>{:?}", a.class, e.class)).unwrap_or(&1.0);
                    n.fire.push((a.id, f.mean_at(d) * k / hp));
                }
            }
        }
        out
    }

    /// Resolves the pass's bots in order until REPLANS_PER_FRAME of them re-planned; the rest wait for the next frame.
    fn run_pass(&mut self, team: i32, now: f64) {
        let Some(mut p) = self.teams.get_mut(&team).and_then(|h| h.pass.take()) else { return };
        let t_pass = std::time::Instant::now();
        let (mut scan_sum, mut valid_sum) = (0u32, 0u32);
        let store = self.store.clone();
        let mut scan_t = [0u64; 3];
        let time_mult = self.time_mult;
        let mut replans = 0u32;
        while p.next < p.order.len() && replans < REPLANS_PER_FRAME {
            let i = p.order[p.next];
            p.next += 1;
            let snap = &self.snap;
            let Some(me) = snap.get(self.bots[i].ship_id).filter(|s| s.alive) else { continue };
            let belief = &self.teams[&team].belief;
            let bot = &self.bots[i];
            let flank = bot.role.zip(self.teams[&team].flanks.as_ref()).map(|(r, f)| {
                let (ids, centre) = f.view(r, me.p2());
                FlankView { ids, centre }
            });
            let (danger, dtel) = self.danger(i, team, &p.spot);
            for w in dtel {
                self.tel.count(w);
            }
            if let Some(pl) = self.bots[i].plan {
                self.tel.count(match pl.posture { Posture::Engage => "posture_engage", Posture::TorpRun => "posture_torp", Posture::Disengage => "posture_disengage" });
            }
            if danger.cover_first {
                self.tel.count("cover_first");
            }
            if danger.threat >= hive::DISENGAGE_THREAT {
                self.tel.count("threat_high");
            }
            let spot_on = p.spotters.get(&i).copied().flatten();
            let hunt = p.spotters.get(&i).is_some_and(|s| s.is_none());
            let mut holds = self.holds(i, team, me);
            if let Some(e) = spot_on.and_then(|id| snap.get(id)) {
                let (s, h) = (spot_band(me, e), holds.get_mut(&e.id));
                if let Some(h) = h {
                    h.band = if h.band.0 <= s.1 { (h.band.0, h.band.1.min(s.1)) } else { s };
                    h.ring = h.ring.min((h.band.0 - RING_IN_M).max(0.0));
                }
            }
            if scan_trace() {
                for (id, h) in &holds {
                    godot_print!("trade5 t={:.0} {} vs {} {:?} r={:.0} band={:.0}-{:.0} ring={:.0} brawl={} spot={}", now, self.bots[i].name,
                        snap.get(*id).map_or(0.0, |e| e.conceal), h.trade.desire, h.trade.range, h.band.0, h.band.1, h.ring, h.brawl, spot_on == Some(*id));
                }
            }
            let bands: HashMap<i64, (f32, f32)> = holds.iter().map(|(&id, h)| (id, h.band)).collect();
            if self.bots[i].style != Playstyle::Brawler && holds.values().any(|h| h.brawler) {
                self.bots[i].style = Playstyle::Brawler;
                self.tel.count("style_brawler");
            }
            let bot = &self.bots[i];
            let brawl = bot.assign.target.and_then(|t| holds.get(&t)).is_some_and(|h| h.brawl);
            let tgt_band = bot.assign.target.and_then(|t| holds.get(&t)).map(|h| h.band);
            let b = &mut self.bots[i];
            (b.brawl, b.spot_for, b.trade_band) = (brawl, spot_on, tgt_band);
            let away: Vector2 = self.teams[&team].field.sources.iter().filter(|s| !s.ahead)
                .filter(|s| holds.get(&s.id).is_some_and(|h| !h.brawl && s.at.distance_to(me.p2()) < KITE_BAND * h.band.1 + (1.0 - KITE_BAND) * h.band.0))
                .map(|s| (me.p2() - s.at).normalized()).sum();
            let kite_axis = (away.length() > 1e-3).then(|| away.x.atan2(away.y));
            if kite_axis.is_some() {
                self.tel.count("ring_in");
            }
            if brawl {
                self.tel.count("brawl");
            }
            let bot = &self.bots[i];
            let m = Member { me, style: bot.style.style(), apt: bot.apt, plan: bot.plan, assign: bot.assign, blocked_s: bot.blocked_s,
                torp: bot.torp.map(|t| (t.range, bot.inputs.torp_ready > 0)), flank, danger, bands: bands.clone(), brawl, kite_axis, hunt,
                under_fire: now < bot.fired_on_until, cover_ok: me.class != HullClass::Dd && !brawl && spot_on.is_none() && !hunt };
            let live = &self.live;
            let gun = &bot.gun;
            let mut no_table = 0u32;
            let mut ev = |t: &snapshot::ShipState| -> Option<f32> {
                let s = store.as_ref()?;
                let l = live.get(&t.id).cloned().unwrap_or_default();
                let tof = gun.flight_time(me.pos, t.pos, time_mult).unwrap_or(0.0);
                let r = (0..2).filter_map(|a| gun.best(s, me, t, &l, a, tof)).map(|b| b.value).fold(None, |m: Option<f32>, v| Some(m.map_or(v, |m| m.max(v))));
                if r.is_none() {
                    no_table += 1;
                }
                r
            };
            let shots = &self.shots;
            let nav = bot.nav.bind();
            let clearance = nav.get_ship_clearance();
            let map = self.map.as_ref().map(|m| m.bind());
            let shot = |st: Vector2, aim: Vector2| -> bool {
                let (Some(g), Some(m)) = (&bot.shot_gun, &map) else { return false };
                m.is_navigable_impl(st.x, st.y, clearance) && shots.clear(g, st, aim)
            };
            let field = &self.teams[&team].field;
            let (curves, matrices) = (&self.curves, &self.matrices);
            let (calib_in, calib_out) = (&self.calib_in, &self.calib_out);
            let vis = self.vis.as_ref().map(|v| v.bind());
            let mut scan_tel: Vec<&'static str> = Vec::new();
            let mates: Vec<Vector2> = self.bots.iter()
                .filter(|o| o.team == team && o.ship_id != me.id && o.role.is_some() && o.role == bot.role
                    && snap.get(o.ship_id).is_some_and(|s| s.alive))
                .filter_map(|o| o.plan.filter(|p| p.posture == Posture::Engage).map(|p| p.station)).collect();
            let front = self.teams[&team].flanks.as_ref().map(|f| f.axis());
            let my_hp = (me.hp_frac * me.hp_max).max(1.0);
            let k_in = *calib_in.get(&class_key(me.class)).unwrap_or(&1.0);
            let mut rings: Vec<(Vector2, f32)> = Vec::new();
            let mut scan = |req: &station::Req| -> Option<station::Found> {
                let ts = std::time::Instant::now();
                let (Some(lay), Some(vis), Some(feats)) = (&self.layout, &vis, &self.features) else { return None };
                let mut threats = [threats_of(field, bot, snap, curves, matrices, &mut scan_tel, false),
                    threats_of(field, bot, snap, curves, matrices, &mut Vec::new(), true)];
                for t in threats.iter_mut().flatten() {
                    t.aim = aim_share(snap, team, me, t.at, t.range);
                    t.ring = holds.get(&t.fire.ship.id).map_or(0.0, |h| h.ring);
                }
                rings = threats[0].iter().map(|t| (t.at, t.ring)).collect();
                let own = matrices.get(&me.id);
                let mut foes: Vec<station::Foe> = Vec::new();
                for (id, now_i, ahead_i) in sources_by_id(field) {
                    let theirs = m.flank.as_ref().is_some_and(|f| !f.ids.contains(&id)) && req.target != Some(id) && spot_on != Some(id)
                        && snap.get(id).is_none_or(|e| field.sources[now_i].at.distance_to(me.p2()) > e.gun_range * 1.05);
                    if theirs {
                        continue;
                    }
                    let Some(fire) = fire_of(snap, curves, me.id, id, bot.gun.pairs.get(&id).map(|q| &q.keys)) else {
                        if req.target == Some(id) {
                            scan_tel.push("station_no_value");
                        }
                        continue;
                    };
                    let pos = |i: usize| {
                        let s = &field.sources[i];
                        station::Pos { at: if req.target == Some(id) && !s.ahead { req.anchor } else { s.at }, cell: s.cell, col: own.and_then(|m| m.col(s.cell)) }
                    };
                    if req.target == Some(id) && own.and_then(|m| m.col(field.sources[now_i].cell)).is_none() {
                        scan_tel.push("station_no_column");
                    }
                    let spot = p.spot.get(&id).filter(|n| !n.lit_by.iter().any(|&l| l != me.id))
                        .map_or(0.0, |n| n.fire.iter().filter(|f| f.0 != me.id).map(|f| f.1).sum());
                    let k_out = *calib_out.get(&format!("{:?}>{:?}", me.class, fire.ship.class)).unwrap_or(&1.0);
                    let hp = (fire.ship.hp_frac * fire.ship.hp_max).max(1.0);
                    let band = bands.get(&id).copied().unwrap_or((req.lo, req.hi));
                    let must = spot_on == Some(id) && !req.escape;
                    foes.push(station::Foe { hp, k_out, primary: req.target == Some(id), spot, band, must, at: [pos(now_i), pos(ahead_i)], fire });
                }
                let bloom = me.conceal.max(me.gun_range);
                let seen = [false, true].map(|later| [bloom, me.conceal].map(|r| field.seen_by(lay, vis, r, |s| later || !s.ahead)));
                let aims: Vec<(Vector2, Arc<[u64]>)> = field.ghosts.iter().filter(|g| !g.ahead).map(|g| g.at)
                    .chain(m.flank.as_ref().and_then(|f| f.centre))
                    .filter_map(|q| Some((q, own?.col(vis.cell_of(q)?)?))).collect();
                let sc = Scan { lay, vis, feats, foes, threats, seen, shot: &field.shot, field, aims, route: Default::default(), my: me.p2(), speed: me.max_speed,
                    clearance, turn_radius: me.turn_radius, risk: m.style.risk, reach: me.gun_range, my_hp, k_in, mates: mates.clone(), front,
                    dark_ok: me.class == HullClass::Dd || me.class == HullClass::Ca && me.conceal < DARK_CA_CONCEAL * me.gun_range,
                    allies: {
                        let a: Vec<Vector2> = snap.allies_of(team).filter(|a| a.alive && a.id != me.id).map(|a| a.p2()).collect();
                        (!a.is_empty()).then(|| a.iter().copied().sum::<Vector2>() / a.len() as f32)
                    } };
                let tcell = vis.cell_of(req.anchor);
                let t0 = std::time::Instant::now();
                scan_t[2] += (t0 - ts).as_micros() as u64;
                let mut exact_us = 0u64;
                let centre = tcell.map(|c| vis.centres[c]);
                let mut diag = scan_trace().then(station::Diag::default);
                let f = sc.run(req, &mut |p| {
                    let t = std::time::Instant::now();
                    let r = shot(p, req.anchor);
                    if !r {
                        if let (Some(g), Some(mp)) = (&bot.shot_gun, &map) {
                            scan_tel.push(if !mp.is_navigable_impl(p.x, p.y, clearance) { "exact_nav_fail" }
                                else if centre.is_some_and(|c| shots.clear(g, p, c)) { "exact_ray_fail_centre_ok" }
                                else { "exact_ray_fail" });
                        }
                    }
                    exact_us += t.elapsed().as_micros() as u64;
                    r
                }, diag.as_mut());
                if let Some(d) = diag.as_ref().filter(|_| req.only.is_none()) {
                    let c = |c: &station::DiagCell| format!("r={:.0} v={:.4} x={:.4} t={:.0}s s={:.4} at=({:.0},{:.0})",
                        c.range, c.value, c.exposure, c.transit_s, c.score, c.p.x, c.p.y);
                    let tgt = req.target.and_then(|id| snap.get(id));
                    godot_print!("scan5 t={:.0} {} {:?}/{} hp={:.2}/{:.0} conceal={:.0} gun={:.0} tgt={} band={:.0}-{:.0} my_r={:.0} foes={} cands berth={} gap={} other={} passing={} hidden={} shielded={} us={} | pick {} dark={} neg={} | cover {}",
                        now, bot.name, me.class, bot.style.name(), me.hp_frac, me.hp_max, me.conceal, me.gun_range,
                        tgt.map_or("-".to_string(), |t| format!("{:?}", t.class)), req.lo, req.hi, me.p2().distance_to(req.anchor),
                        sc.foes.len(), d.kinds[0], d.kinds[1], d.kinds[2], d.passing, d.hidden, d.shielded, d.us,
                        d.pick.map_or("none".to_string(), |(p, shot)| format!("{} shot={}", c(&p), shot)),
                        f.is_some_and(|f| f.dark), f.is_some_and(|f| f.negative),
                        d.cover.map_or("none".to_string(), |(p, why)| format!("{} why={}", c(&p), why)));
                }
                scan_t[0] += t0.elapsed().as_micros() as u64 - exact_us;
                scan_t[1] += exact_us;
                if req.only.is_some() {
                    scan_tel.push(if f.is_some() { "station_hold_ok" } else { "station_hold_check" });
                    return f;
                }
                scan_tel.push(if f.is_some() { "station_scan" } else { "station_scan_empty" });
                if f.is_some_and(|f| f.negative) {
                    scan_tel.push("station_negative");
                }
                if f.is_some_and(|f| f.dark) {
                    scan_tel.push("station_dark");
                }
                if f.is_some_and(|f| f.hop) {
                    scan_tel.push("station_hop");
                }
                if req.target.is_some() && f.is_some_and(|f| !f.shot) {
                    scan_tel.push("station_no_shot");
                }
                f
            };
            let old = m.plan;
            let (kite_axis, n_src, n_holds) = (m.kite_axis, field.sources.len(), holds.len());
            let (plan, assign, reason) = hive::resolve(&m, snap, belief, &p.committed, now, &mut ev, &mut |a, b| shot(a, b), &mut scan);
            if scan_trace() {
                godot_print!("pass5 t={:.0} {} id={} my=({:.0},{:.0}) fc={:?} cover={} pkite={} st={:?} kite={:?} src={} holds={} tgt={:?} reason={:?} posture={:?}", now, self.bots[i].name,
                    m.me.id, m.me.pos.x, m.me.pos.z, m.flank.as_ref().and_then(|f| f.centre).map(|c| (c.x as i32, c.y as i32)),
                    plan.is_some_and(|p| p.cover), plan.is_some_and(|p| p.kite), plan.map(|p| (p.station.x as i32, p.station.y as i32)), kite_axis.map(|a| a.to_degrees() as i32),
                    n_src, n_holds, assign.target, reason, plan.map(|p| p.posture));
            }
            drop(scan);
            drop(vis);
            for w in scan_tel {
                self.tel.count(w);
            }
            scan_sum += (scan_t[0] + scan_t[1] + scan_t[2]) as u32;
            self.scan_us[0] += scan_t[0];
            self.scan_us[1] += scan_t[1];
            self.scan_us[3] += scan_t[2];
            scan_t = [0; 3];
            drop(map);
            drop(nav);
            let hp = me.hp_frac;
            for _ in 0..no_table {
                self.tel.count("target_no_table");
            }
            if plan.is_some_and(|p| p.posture == Posture::Engage && assign.target.is_some() && !p.shot) {
                self.tel.count("engage_no_shot");
            }
            if let Some(r) = reason {
                self.tel.release(r);
                if let (Some(o), Some(n)) = (old, plan) {
                    self.tel.shift(r, o.station.distance_to(n.station), o.anchor.distance_to(n.anchor), o.station.distance_to(me.p2()));
                }
            }
            let bot = &mut self.bots[i];
            if let Some(r) = reason {
                bot.last_release = Some((r, now));
            }
            bot.hp_at_pass = hp;
            bot.assign = assign;
            if let Some(st) = plan.map(|p| p.station) {
                let walls: Vec<(Vector2, f32)> = rings.iter().map(|&(at, r)| (at, r.min(at.distance_to(st) - WALL_SHORT_M).max(0.0)))
                    .filter(|w| w.1 > 0.0).collect();
                if walls.len() != bot.walls.len() || walls.iter().zip(&bot.walls).any(|(a, b)| a.0.distance_to(b.0) > WALL_MOVE_M || (a.1 - b.1).abs() > WALL_MOVE_M) {
                    bot.walls = walls;
                    bot.walls_new = true;
                }
            }
            if let Some(mut p) = plan {
                if reason.is_some() {
                    bot.serial += 1;
                    if !p.shot {
                        let tv = std::time::Instant::now();
                        p.station = self.valid_station(i, me.p2(), p.station);
                        valid_sum += us(tv);
                    }
                }
                p.serial = self.bots[i].serial;
                self.bots[i].plan = Some(p);
            }
            p.committed.push(Committed { target: assign.target, clear: assign.clear });
            replans += reason.is_some() as u32;
        }
        let rest = us(t_pass);
        self.ph[7] += scan_sum;
        self.ph[14] += valid_sum;
        self.ph[6] += rest.saturating_sub(scan_sum + valid_sum);
        if p.next < p.order.len() {
            self.tel.count("hive_pass_resumed");
            self.teams.get_mut(&team).unwrap().pass = Some(p);
            return;
        }
        let t = std::time::Instant::now();
        self.spotters(team, now);
        self.ph[8] += us(t);
    }

    /// Ascending aptitude like the plan pass; team-aware bots skip contacts an earlier spotter took.
    fn spotters(&mut self, team: i32, now: f64) {
        let mut order: Vec<usize> = (0..self.bots.len())
            .filter(|&i| self.bots[i].team == team && self.bots[i].spot_reach > 0.0)
            .collect();
        order.sort_by_key(|&i| (self.bots[i].apt.level, self.bots[i].ship_id));
        let mut claimed: Vec<i64> = Vec::new();
        for i in order {
            let b = &self.bots[i];
            let Some(me) = self.snap.get(b.ship_id).filter(|s| s.alive) else { continue };
            let belief = &self.teams[&team].belief;
            let tw = b.apt.team_weight();
            let my = me.p2();
            let mut best: Option<(i64, Vector2, f32)> = None;
            for (&id, c) in &belief.contacts {
                let Some(e) = self.snap.get(id).filter(|e| e.alive) else { continue };
                let current = b.spot_target == Some(id);
                if (c.seen_now && !current) || (!c.seen_now && now - c.last_seen > SPOT_MAX_AGE_S)
                    || (tw > 0.0 && claimed.contains(&id)) {
                    continue;
                }
                let Some(p) = belief.pos_at(id, now, if current { 0.0 } else { b.apt.view_delay_s() }) else { continue };
                if p.distance_to(my) > b.spot_reach + SPOT_DETECT_USE * e.air_radius {
                    continue;
                }
                let mut v = 0.0;
                if p.distance_to(my) <= me.gun_range {
                    v += 1.0;
                    if b.plan.is_some_and(|pl| pl.anchor.distance_to(p) < SPOT_ANCHOR_M) {
                        v += 1.0;
                    }
                }
                let shooters = self.snap.allies_of(team).filter(|a| a.id != me.id && a.p2().distance_to(p) <= a.gun_range).count();
                v += tw * SPOT_ALLY_VALUE * shooters as f32;
                if current {
                    v += SPOT_KEEP;
                }
                if v > 0.0 && best.is_none_or(|(_, _, bv)| v > bv) {
                    best = Some((id, p, v));
                }
            }
            if let Some((id, _, _)) = best {
                claimed.push(id);
                if self.bots[i].spot_target != Some(id) {
                    self.tel.count("spot_task");
                }
            }
            let reach = self.bots[i].spot_reach;
            let b = &mut self.bots[i];
            b.spot_target = best.map(|x| x.0);
            b.spot_point = best.map(|(_, p, _)| {
                let off = p - my;
                my + off * (reach / off.length().max(1.0)).min(1.0)
            });
        }
    }

    fn spot_cmd(&mut self, i: usize) {
        let b = &mut self.bots[i];
        let up = b.inputs.spot_active;
        b.cmd.spot = b.spot_point.filter(|_| up || b.inputs.spot_ready);
        if b.cmd.spot.is_some() && !up {
            self.tel.count("spot_launch");
        }
    }

    fn torps(&mut self, i: usize, now: f64) {
        let frame = self.frame;
        let Some(spec) = self.bots[i].torp else { return };
        let Some(me) = self.snap.get(self.bots[i].ship_id).copied().filter(|s| s.alive) else {
            self.bots[i].cmd.torp_aim = None;
            return;
        };
        let b = &mut self.bots[i];
        b.cmd.torp_fire = false;
        let inp = b.inputs;
        if inp.torp_ready == 0 {
            b.torp_aim = None;
            b.torp_idx = 0;
            b.torp_gate = "torp_reloading";
            b.cmd.torp_aim = None;
            return;
        }
        if inp.torp_ready == inp.torp_live && now - b.torp_last_fire > TORP_FRESH_SALVO_S {
            b.torp_idx = 0;
        }
        if b.torp_aim.is_none() || frame % TORP_EVERY == i as i64 % TORP_EVERY {
            let Some(map) = self.map.clone() else { return };
            let map = map.bind();
            self.allies.clear();
            self.allies.extend(self.snap.allies_of(me.team).copied());
            let b = &mut self.bots[i];
            let from = inp.launch_from;
            let mut cands: Vec<&ShipState> = self.snap.enemies_of(me.team)
                .filter(|e| e.seen && e.p2().distance_to(from) <= spec.range)
                .collect();
            cands.sort_by(|x, y| ((Some(y.id) == b.assign.target) as i32).cmp(&((Some(x.id) == b.assign.target) as i32))
                .then(x.p2().distance_to(from).total_cmp(&y.p2().distance_to(from))));
            let gate = TORP_MIN_CHANCE[b.apt.level.clamp(0, 3) as usize];
            let mut best: Option<TorpAim> = None;
            let mut why = "torp_no_target";
            for t in cands.iter().take(TORP_CANDIDATES) {
                let Some(tr) = self.tracks.get(t.id) else { continue };
                match torpedo::solve(&spec, inp.torp_ready, from, t, tr, &self.allies, me.id, &map) {
                    Ok(a) => {
                        if best.is_none_or(|x| a.chance > x.chance) {
                            best = Some(a);
                        }
                        if a.chance >= gate {
                            break;
                        }
                    }
                    Err(e) => why = e,
                }
            }
            if best.map(|a| a.target) != b.torp_aim.map(|a| a.target) {
                b.torp_idx = 0;
            }
            b.torp_aim = best;
            b.torp_gate = match best {
                Some(a) if a.chance >= gate => "torp_fire",
                Some(_) => "torp_low_chance",
                None => why,
            };
            self.tel.count(b.torp_gate);
        }
        let b = &mut self.bots[i];
        b.cmd.torp_aim = b.torp_aim.map(|a| a.point(b.torp_idx));
        b.cmd.torp_fire = b.torp_aim.is_some() && b.torp_gate == "torp_fire";
    }

    fn stance(&mut self, i: usize, now: f64) {
        let (st, vetoed) = self.stance_for(i, now);
        if let Some(astern) = vetoed {
            self.bots[i].veto_at = now;
            self.tel.count(if astern { "stance_veto_astern" } else { "stance_veto_turn" });
        }
        if st.active {
            self.tel.count(st.why);
        }
        self.set_stance(i, st);
    }

    /// v4's threat on bot i: each enemy whose shells land on us while we are seen (firing), at our aspect to it, now or
    /// FORECAST_S ahead, times the share of its aim we draw against lit allies in its range (nearer pulls harder).
    fn danger(&self, i: usize, team: i32, spot: &HashMap<i64, SpotNeed>) -> (Danger, Vec<&'static str>) {
        let b = &self.bots[i];
        let (Some(me), Some(vis)) = (self.snap.get(b.ship_id), &self.vis) else { return Default::default() };
        let vis = vis.bind();
        let Some(k) = vis.cell_of(me.p2()) else { return Default::default() };
        let field = &self.teams[&team].field;
        let my = me.p2();
        let hp = (me.hp_frac * me.hp_max).max(1.0);
        let k_in = *self.calib_in.get(&class_key(me.class)).unwrap_or(&1.0);
        let horizon = -(1.0 - hive::DISENGAGE_THREAT).ln() * DISENGAGE_TTD_SHARE * self.time_left.max(0.0);
        // Disengage reads the threat we would draw firing from here: only hidden cover lets it end.
        let bloom = if b.plan.is_some_and(|p| p.dark && p.posture != Posture::Disengage) { me.conceal } else { me.conceal.max(me.gun_range) };
        let seen = field.seen_at(&vis, k, bloom);
        let mut tel = Vec::new();
        let now_t = threats_of(field, b, &self.snap, &self.curves, &self.matrices, &mut tel, false);
        let ahead_t = threats_of(field, b, &self.snap, &self.curves, &self.matrices, &mut tel, true);
        let aim = |at: Vector2, range: f32| aim_share(&self.snap, team, me, at, range);
        let lands = |t: &Threat| t.row.is_none_or(|r| r[k / 64].load(std::sync::atomic::Ordering::Relaxed) >> (k % 64) & 1 != 0);
        let share = |t: &Threat| {
            let d = t.at.distance_to(my);
            if !seen || d > t.range || !lands(t) {
                return 0.0;
            }
            let aspect = stance::wrap(stance::bearing(my, t.at) - me.heading()).abs().to_degrees();
            t.fire.at(d, aspect) * k_in / hp / 60.0 * aim(t.at, t.range)
        };
        let rate: f32 = now_t.iter().zip(&ahead_t).map(|(a, f)| share(a).max(share(f))).sum();
        let threat = 1.0 - (-horizon * rate).exp();
        let ttd = if rate > 0.0 { 1.0 / rate } else { f32::INFINITY };
        let kill = |t: &ShipState, d: f32| fire_of(&self.snap, &self.curves, me.id, t.id, b.gun.pairs.get(&t.id).map(|q| &q.keys)).map(|f| {
            f.mean_at(d) * *self.calib_out.get(&format!("{:?}>{:?}", me.class, t.class)).unwrap_or(&1.0) / (t.hp_frac * t.hp_max).max(1.0) / 60.0
        });
        let tgt = b.assign.target.and_then(|id| self.snap.get(id)).filter(|t| t.alive);
        let band = b.style.style().band;
        let ttw = tgt.and_then(|t| {
            let want = 0.5 * (band.0 + band.1) * me.gun_range;
            let r = kill(t, want).filter(|&r| r > 0.0)?;
            let close = (my.distance_to(t.p2()) - me.gun_range.max(want)).max(0.0);
            Some(close / me.max_speed.max(1.0) + 1.0 / r)
        });
        let d = Danger { threat, ttd, ttw, cover_first: false, safe_x: -(1.0 - hive::REENGAGE_THREAT).ln() / horizon.max(1.0) * 60.0 };
        let alone_spotting = tgt.and_then(|t| spot.get(&t.id)).is_some_and(|n| !n.lit_by.is_empty() && n.lit_by.iter().all(|&l| l == me.id));
        let out_traded = now_t.iter().any(|t| {
            let dist = t.at.distance_to(my);
            seen && dist <= t.range && lands(t) && self.snap.get(t.fire.ship.id).and_then(|e| kill(e, dist))
                .is_some_and(|ours| t.fire.mean_at(dist) * k_in / hp / 60.0 > ours)
        });
        let losing = threat >= hive::REENGAGE_THREAT && !d.winning(hive::STAY_MARGIN, b.style.style().aggression);
        let mut tel = Vec::new();
        if !alone_spotting && losing {
            tel.push("cover_first_losing");
        }
        if !alone_spotting && out_traded {
            tel.push("cover_first_out_traded");
        }
        (Danger { cover_first: !alone_spotting && (losing || out_traded), ..d }, tel)
    }

    /// Heading and gear for bot i: damage in minus out by hull heading, within the progress cone; stance alone
    /// decides whether a station behind is reached by turning or backing. Some(gear) when the veto was priced.
    fn stance_for(&self, i: usize, now: f64) -> (Stance, Option<bool>) {
        use std::f32::consts::{FRAC_PI_2, PI};
        let b = &self.bots[i];
        let me = self.snap.get(b.ship_id).copied().filter(|s| s.alive);
        let (Some(me), Some(p), Some(vis), Some(h)) = (me, b.plan, &self.vis, self.teams.get(&b.team)) else {
            return (Stance::default(), None);
        };
        let vis = vis.bind();
        let my = me.p2();
        let mut tel = Vec::new();
        let threats = threats_of(&h.field, b, &self.snap, &self.curves, &self.matrices, &mut tel, false);
        let tgt = b.assign.target.and_then(|id| self.snap.get(id))
            .filter(|t| t.alive && t.seen && !p.dark && t.p2().distance_to(my) <= me.gun_range);
        let bloom = if tgt.is_some() { me.conceal.max(me.gun_range) } else { me.conceal };
        let mut rates = Rates::default();
        if let Some(k) = vis.cell_of(my).filter(|&k| h.field.seen_at(&vis, k, bloom)) {
            let w = b.style.style().risk * *self.calib_in.get(&class_key(me.class)).unwrap_or(&1.0) / (me.hp_frac * me.hp_max).max(1.0);
            for t in &threats {
                let d = t.at.distance_to(my);
                let lands = t.row.is_none_or(|row| row[k / 64].load(std::sync::atomic::Ordering::Relaxed) >> (k % 64) & 1 != 0);
                if d <= t.range && lands {
                    rates.add_threat(stance::bearing(my, t.at), |a| t.fire.at(d, a) * w);
                }
            }
        }
        if let Some(t) = tgt {
            if let Some(f) = fire_of(&self.snap, &self.curves, me.id, t.id, b.gun.pairs.get(&t.id).map(|q| &q.keys)) {
                let k_out = *self.calib_out.get(&format!("{:?}>{:?}", me.class, t.class)).unwrap_or(&1.0);
                let v = Target { ship: t, at: t.p2(), fire: f }.value_at(my) * k_out / (t.hp_frac * t.hp_max).max(1.0);
                rates.add_target(stance::bearing(my, t.p2()), v, &b.mounts);
            }
        }
        rates.finish();
        if rates.idle() {
            return (Stance::default(), None);
        }
        let wp = b.nav.bind().get_current_waypoint_impl();
        let wp = Vector2::new(wp.x, wp.z);
        let to = if wp.distance_to(my) > 1.0 { wp } else { p.station };
        let route = b.kite.map_or_else(|| stance::bearing(my, to), |k| k.0);
        let half = if b.kite.is_some() { KITE_TOL } else { stance::CONE };
        let side_ref = tgt.map(|t| stance::bearing(my, t.p2()))
            .or_else(|| threats.iter().min_by(|a, b| a.at.distance_to(my).total_cmp(&b.at.distance_to(my))).map(|t| stance::bearing(my, t.at)));
        let (hdg, speed) = (me.heading(), me.speed());
        let omega = stance::swing_rate(&b.hull, speed);
        let lag = b.hull.rudder_response_time * 0.5;
        let prev = b.stance;
        let holding = p.station.distance_to(my) < p.hold_radius;
        let mut st = Stance { active: true, holding, gear_at: prev.gear_at, turn_loss: prev.turn_loss,
            ..Stance::default() };
        let mut vetoed = None;
        let trained = trained_beam(&b.gun_nodes, hdg);
        let best = |c: f32, half: f32, keep: Option<f32>| stance::best_in(&rates, c, half, hdg, omega, lag, keep, side_ref, trained).0;
        if holding {
            st.heading = best(hdg, PI, prev.active.then_some(prev.heading));
            st.why = "stance_hold";
        } else {
            let behind = stance::wrap(route - hdg).abs() > FRAC_PI_2;
            let back_c = stance::wrap(route + PI);
            st.astern = prev.active && prev.astern && behind;
            if behind && now - b.veto_at >= VETO_EVERY_S && (!prev.active || now - prev.gear_at >= stance::GEAR_HOLD_S) {
                let hull0 = crate::nav::navigator::hull::Hull { pos: my, vel: Vector2::new(me.vel.x, me.vel.z), heading: hdg,
                    yaw: me.yaw_rate, rudder: b.inputs.rudder, power: b.inputs.engine_power };
                let (astern, loss) = stance::veto(&b.hull, hull0, &rates, best(route, half, None), b.style.style().risk);
                st.turn_loss = loss;
                if astern != st.astern || !prev.active {
                    st.gear_at = now;
                }
                st.astern = astern;
                vetoed = Some(astern);
            }
            let keep = prev.active.then_some(prev.heading).filter(|_| prev.astern == st.astern);
            st.heading = best(if st.astern { back_c } else { route }, half, keep);
            st.why = if st.astern { "stance_astern" } else if behind { "stance_turn" } else { "stance_ahead" };
        }
        if stance_trace() {
            godot_print!("stance5 {} m={} t={:.0} {} trained={:?} beam={:?} kite={} hdg={:.0} want={:.0} route={:.0} v={:.1} turn_loss={:.3} in={:.4} out={:.4}",
                b.name, b.mounts.len(), now, st.why, trained, side_ref.map(|s| stance::wrap(s - hdg).signum()), b.kite.is_some(), hdg.to_degrees(), st.heading.to_degrees(), route.to_degrees(), speed, st.turn_loss,
                rates.inc[stance::bin(st.heading)], rates.out[stance::bin(st.heading)]);
        }
        (st, vetoed)
    }

    fn set_stance(&mut self, i: usize, st: Stance) {
        let b = &mut self.bots[i];
        b.stance = st;
        let (h, w, back, ahead) = helm(&st);
        b.nav.bind_mut().set_helm_impl(h, w, back, ahead);
    }

    fn valid_station(&self, i: usize, from: Vector2, p: Vector2) -> Vector2 {
        let Some(map) = &self.map else { return p };
        let nav = self.bots[i].nav.bind();
        let clearance = nav.get_ship_clearance();
        let turn = nav.params.turning_circle_radius;
        let m = map.bind();
        if m.is_navigable_impl(p.x, p.y, clearance) {
            return p;
        }
        m.safe_nav_point_internal(from, p, clearance, turn)
    }

    /// v4's kite, recomputed every tick relative to us: away from the guns on us, the threat held KITE_ANGLE off the
    /// stern on the quarter it already sits on; swung toward open water (a shot preferred) when land is ahead.
    fn kite_now(&mut self, i: usize, now: f64) {
        let b = &self.bots[i];
        let (Some(me), Some(true)) = (self.snap.get(b.ship_id).filter(|s| s.alive), b.plan.map(|p| p.kite)) else {
            let b = &mut self.bots[i];
            (b.kite, b.kite_side) = (None, 0.0);
            return;
        };
        let fired = now < b.fired_on_until;
        if b.kite.is_some() && (self.frame + i as i64) % KITE_EVERY != 0 && fired == b.kite_fired {
            return;
        }
        let my = me.p2();
        let field = &self.teams[&b.team].field;
        let near: Vec<&field::Source> = field.sources.iter().filter(|s| !s.ahead)
            .filter(|s| self.snap.get(s.id).is_some_and(|e| s.at.distance_to(my) <= e.gun_range * 1.05)).collect();
        let away: Vector2 = near.iter().map(|s| (my - s.at).normalized_or_zero()).sum();
        if away.length() < 1e-3 {
            self.bots[i].kite = None;
            return;
        }
        let tb = stance::wrap(away.x.atan2(away.y) + std::f32::consts::PI);
        let side = if b.kite_side != 0.0 { b.kite_side } else {
            trained_beam(&b.gun_nodes, me.heading()).unwrap_or(if stance::wrap(tb - me.heading()) >= 0.0 { 1.0 } else { -1.0 })
        };
        let want = stance::wrap(tb - side * (std::f32::consts::PI - if fired { KITE_ANGLE_FIRED } else { KITE_ANGLE }));
        let reach = KITE_REACH_M.max(KITE_REACH_TURNS * me.turn_radius);
        let clearance = b.nav.bind().get_ship_clearance();
        let aim = b.assign.target.and_then(|t| self.snap.get(t)).map(|t| t.p2()).or_else(|| near.first().map(|s| s.at));
        let open = |p: Vector2| self.map.as_ref().is_some_and(|m| {
            let m = m.bind();
            (1..=KITE_SAMPLES).all(|k| { let q = my + (p - my) * (k as f32 / KITE_SAMPLES as f32); m.get_distance_impl(q.x, q.y) >= clearance })
        });
        let shot = |p: Vector2| match (&b.shot_gun, aim) { (Some(g), Some(a)) => self.shots.clear(g, p, a), _ => true };
        let n = (KITE_SWING_MAX / KITE_SWING).round() as i32;
        let legs: Vec<(f32, Vector2)> = (0..=n).flat_map(|k| [k, -k]).map(|k| stance::wrap(want + k as f32 * KITE_SWING))
            .map(|h| (h, my + Vector2::new(h.sin(), h.cos()) * reach)).filter(|&(_, p)| open(p)).take(KITE_LEGS).collect();
        let pick = legs.iter().copied().find(|&(_, p)| shot(p)).or_else(|| legs.first().copied());
        let b = &mut self.bots[i];
        b.kite_side = side;
        b.kite = pick;
        b.kite_fired = fired;
    }

    fn drive(&mut self, i: usize, dt: f32, now: f64) {
        self.kite_now(i, now);
        let frame = self.frame;
        let b = &mut self.bots[i];
        let Some(me) = self.snap.get(b.ship_id).copied().filter(|s| s.alive) else {
            b.cmd = Command::default();
            return;
        };
        let slot = i as i64;
        let mut nav = b.nav.bind_mut();
        if frame % NAV_STATE_EVERY == slot % NAV_STATE_EVERY {
            nav.clear_obstacles_impl();
            for (k, t) in self.torps_in.iter().enumerate() {
                let at = Vector2::new(t[1], t[2]);
                if t[0] as i32 != b.team && at.distance_to(me.p2()) <= TORP_TRACK_M
                    && torp_closes(me.p2(), Vector2::new(me.vel.x, me.vel.z), at, Vector2::new(t[3], t[4]), me.length + me.max_speed * TORP_SLACK_S) {
                    nav.register_obstacle_impl(TORP_ID - k as i32, at, Vector2::new(t[3], t[4]), TORP_RADIUS_M, 0.0);
                }
            }
            nav.set_state_impl(me.pos, me.vel, me.heading(), me.yaw_rate, b.inputs.rudder, me.speed(),
                b.inputs.engine_power, dt * NAV_STATE_EVERY as f32);
            nav.grounded = b.inputs.grounded;
            nav.set_health_fraction_impl(me.hp_frac);
        }
        if let Some(p) = b.plan {
            let jumped = b.pushed.is_none_or(|(s, at)| s != p.serial && at.distance_to(p.station) >= STATION_JUMP_M)
                && self.jump_pushes < JUMP_PUSHES_PER_FRAME;
            self.jump_pushes += jumped as u32;
            if jumped || frame % NAV_PUSH_EVERY == slot % NAV_PUSH_EVERY {
                let (h, w, back, ahead) = helm(&b.stance);
                if std::mem::take(&mut b.walls_new) {
                    nav.set_threat_circles_impl(&b.walls);
                }
                let to = b.kite.map_or(p.station, |k| k.1);
                nav.navigate_to_impl(Vector3::new(to.x, 0.0, to.y), h, p.hold_radius, 0.2618, w, back, ahead);
                b.pushed = Some((p.serial, p.station));
            }
        }
        b.cmd.rudder = nav.out_rudder;
        b.cmd.throttle = nav.out_throttle;
        if b.stance.active && b.stance.holding && !nav.torpedo_override_active && b.cmd.throttle > 0 {
            b.cmd.throttle = b.cmd.throttle.min((stance::HOLD_POWER * 4.0) as i32);
        }
        if nav.torpedo_override_active {
            self.tel.count("torp_override_frames");
        } else if let Some(d) = b.dodge.active(now) {
            let h = Hull { pos: me.p2(), vel: Vector2::new(me.vel.x, me.vel.z), heading: me.heading(), yaw: me.yaw_rate,
                rudder: b.inputs.rudder, power: b.inputs.engine_power };
            let lie = if b.stance.active { b.stance.heading } else { b.kite.map_or(me.heading(), |k| k.0) };
            b.cmd.rudder = d.rudder(&h, &b.hull, lie, now);
            b.cmd.throttle = d.level;
            self.tel.count("dodge_frames");
        }
        if now < b.fired_on_until && frame % 3 == 0 && std::env::var("SHIPS_BOT5_RUDDER_TRACE").is_ok() {
            godot_print!("rud5 {} t={:.1} land_in={:.1} cmd={:.2} rudder={:.2} yaw={:.2}deg/s hdg={:.1} thr={} dodge={} kite={}",
                b.name, now, b.fired_on_until - now, b.cmd.rudder, b.inputs.rudder, me.yaw_rate.to_degrees(), me.heading().to_degrees(),
                b.cmd.throttle, b.dodge.active(now).map_or("-", |d| d.kind), b.kite.is_some());
        }
    }

    /// Re-plans bot i's dodge when enemy shells it has not planned against are in the air near it.
    fn dodge(&mut self, i: usize, now: f64) {
        let Some(pm) = &self.pm else { return };
        let b = &mut self.bots[i];
        let Some(me) = self.snap.get(b.ship_id).copied().filter(|s| s.alive) else { return };
        let shells = pm.bind().shells_near(me.p2(), dodge::QUERY_M, b.team);
        if let Some(t) = shells.iter().map(|(_, tr)| *tr).reduce(f32::max) {
            b.fired_on_until = b.fired_on_until.max(now + t as f64);
        }
        for (e, tr) in &shells {
            if let Some(src) = shell_source(&self.snap, b.team, e) {
                b.reads.note(src.id, now + *tr as f64, e.is_he);
            }
        }
        if let Some((e, _)) = shells.iter().max_by(|a, b| a.0.caliber.total_cmp(&b.0.caliber)) {
            let from = (-e.landing_vx).atan2(-e.landing_vz);
            self.tel.angling(&b.name, e.is_he, stance::wrap(from - me.heading()).abs().to_degrees());
        }
        let dodge::Check::Replan(shells) = b.dodge.check(shells, now) else { return };
        let nav = b.nav.bind();
        let route = b.plan.filter(|p| p.station.distance_to(me.p2()) >= p.hold_radius).map(|p| {
            let wp = nav.get_current_waypoint_impl();
            let wp = Vector2::new(wp.x, wp.z);
            stance::bearing(me.p2(), if wp.distance_to(me.p2()) > 1.0 { wp } else { p.station })
        });
        let map = self.map.as_ref().map(|m| m.bind());
        let aspect_w = if dodge_aspect() { shell_aspects(&self.snap, &self.curves, &b.threats, b.team, &shells) } else { Vec::new() };
        let size = Vector2::new(me.beam, me.length);
        let hull = Rect2::new(-size * 0.5, size);
        let c = dodge::Ctx {
            p: &b.hull,
            h0: Hull { pos: me.p2(), vel: Vector2::new(me.vel.x, me.vel.z), heading: me.heading(), yaw: me.yaw_rate,
                rudder: b.inputs.rudder, power: b.inputs.engine_power },
            hull,
            cit: if b.citadel.has_area() { b.citadel } else { Rect2::new(-size * Vector2::new(0.3, 0.25), size * Vector2::new(0.6, 0.5)) },
            top: me.top,
            lie_h: if b.stance.active { b.stance.heading } else { b.kite.map_or(me.heading(), |k| k.0) },
            lie_level: if b.stance.active && b.stance.astern { -1 } else { b.cmd.throttle },
            route,
            map: map.as_deref(),
            clearance: nav.get_ship_clearance(),
            aspect_w: &aspect_w,
        };
        let (pick, cost0, cost) = dodge::plan(&c, &shells);
        drop(nav);
        let until = now + shells.iter().map(|(_, tr)| *tr as f64).fold(0.0, f64::max);
        b.dodge.plan = pick.map(|(side, hold, level, kind)| dodge::Plan { side, turn_until: now + hold as f64, level, until, kind });
        self.tel.count(pick.map_or("dodge_lie", |p| p.3));
        for row in aspect_w.chunks_exact(dodge::ASPECTS) {
            self.tel.count(if row.iter().all(|&v| v == 1.0) { "dodge_shell_unmatched" } else { "dodge_shell_matched" });
        }
        if dodge_trace() {
            godot_print!("dodge5 {} t={:.1} n={} cost0={:.2} cost={:.2} {:?}", b.name, now, shells.len(), cost0, cost, b.dodge.plan);
        }
    }

    /// The assigned target, or while it cannot be shot (unseen, out of range, terrain), the nearest seen enemy in range
    /// with a clear shot from here, held ALT_HOLD_S.
    /// Unlit: torpedo boats and disengaging ships hold fire; cover-bound ships fire only where firing keeps them hidden.
    fn guns_dark(&self, i: usize) -> bool {
        let b = &self.bots[i];
        let (Some(p), Some(me)) = (b.plan, self.snap.get(b.ship_id)) else { return false };
        if me.seen {
            return false;
        }
        match p.posture {
            Posture::TorpRun | Posture::Disengage => true,
            Posture::Engage if p.cover => {
                let (Some(vis), Some(h)) = (&self.vis, self.teams.get(&b.team)) else { return false };
                let vis = vis.bind();
                vis.cell_of(me.p2()).is_none_or(|k| h.field.seen_at_all(&vis, k, me.conceal.max(me.gun_range)) && !h.field.shielded(&vis, k))
            }
            Posture::Engage => false,
        }
    }

    fn guns(&mut self, i: usize, now: f64, dt: f32, time_mult: f64) {
        let frame = self.frame;
        let b = &mut self.bots[i];
        let Some(me) = self.snap.get(b.ship_id).copied().filter(|s| s.alive) else { return };
        if b.serial != b.blocked_serial {
            b.blocked_serial = b.serial;
            b.blocked_s = 0.0;
        }
        b.blocked_s *= (-dt / BLOCKED_DECAY_S).exp();
        let shootable = |t: &ShipState| t.alive && t.seen && me.pos.distance_to(t.pos) <= me.gun_range;
        b.alt = b.alt.filter(|&(id, until)| now < until && self.snap.get(id).is_some_and(shootable));
        let primary = b.assign.target.and_then(|id| self.snap.get(id)).copied().filter(|t| t.alive && t.seen);
        if let Some((id, _)) = b.alt {
            let t = *self.snap.get(id).unwrap();
            let gate = self.fire_on(i, t, now, dt, time_mult);
            if gate == "arc_blocked" || gate == "out_of_range" {
                self.bots[i].alt = None;
            } else {
                *self.bots[i].gates.entry("alt_target").or_default() += 1;
                return;
            }
        }
        let gate = match primary {
            Some(t) => {
                let g = self.fire_on(i, t, now, dt, time_mult);
                let b = &self.bots[i];
                if g == "arc_blocked" && b.plan.is_some_and(|p| p.station.distance_to(me.p2()) < p.hold_radius) {
                    self.tel.count(if b.plan.is_some_and(|p| p.shot) { "blocked_at_station_shot" } else { "blocked_at_station_unchecked" });
                }
                g
            }
            None => {
                let b = &mut self.bots[i];
                b.gun.aim = None;
                b.cmd.fire = false;
                b.cmd.aim = b.plan.map(|p| Vector3::new(p.anchor.x, 0.0, p.anchor.y));
                b.last_gate = if b.assign.target.is_none() { "no_target" } else { "target_unseen" };
                *b.gates.entry(b.last_gate).or_default() += 1;
                b.last_gate
            }
        };
        let stuck = matches!(gate, "no_target" | "target_unseen" | "out_of_range" | "arc_blocked" | "no_solution");
        if !stuck || frame % AIM_EVERY != i as i64 % AIM_EVERY {
            return;
        }
        let b = &self.bots[i];
        let Some(g) = &b.shot_gun else { return };
        let my = me.p2();
        let alt = self.snap.enemies_of(me.team).filter(|t| shootable(t) && Some(t.id) != b.assign.target && self.shots.clear(g, my, t.p2()))
            .min_by(|a, c| a.pos.distance_to(me.pos).total_cmp(&c.pos.distance_to(me.pos))).copied();
        if let Some(t) = alt {
            self.bots[i].alt = Some((t.id, now + ALT_HOLD_S));
            self.tel.count("alt_target");
            self.fire_on(i, t, now, dt, time_mult);
        }
    }

    /// Aims and fires on `t`; the gun gate it ended on.
    fn fire_on(&mut self, i: usize, t: ShipState, now: f64, dt: f32, time_mult: f64) -> &'static str {
        let frame = self.frame;
        let Some(store) = self.store.clone() else { return "no_store" };
        let b = &mut self.bots[i];
        let Some(me) = self.snap.get(b.ship_id).copied() else { return "no_ship" };
        let stale = b.gun.aim.is_none_or(|a| a.target != t.id);
        if stale || frame % AIM_EVERY == i as i64 % AIM_EVERY {
            let live = self.live.get(&t.id).cloned().unwrap_or_default();
            match b.gun.solve(&store, &me, &t, &live, now, time_mult, b.apt.reads_turns()) {
                Ok(a) => b.gun.aim = Some(a),
                Err(e) => {
                    b.gun.aim = None;
                    self.tel.count(e);
                    *b.gates.entry(e).or_default() += 1;
                    b.last_gate = e;
                }
            }
        }
        let Some(a) = b.gun.aim else {
            b.cmd.fire = false;
            b.cmd.aim = Some(t.pos);
            return if me.pos.distance_to(t.pos) > me.gun_range { "out_of_range" } else { "no_solution" };
        };
        b.cmd.aim = Some(a.world);
        b.cmd.ammo = a.ammo as i32;
        let in_range = me.pos.distance_to(t.pos) <= me.gun_range;
        let clear = if in_range {
            self.allies.clear();
            self.allies.extend(self.snap.allies_of(me.team).copied());
            b.gun.clearance(&me, a.world, now, time_mult, &self.allies, &self.map, &self.space)
        } else {
            Clear::Ok
        };
        let blocked = match clear {
            Clear::Ok => None,
            Clear::Terrain => Some("arc_blocked"),
            Clear::Friendly(_) => Some("friendly_in_path"),
        };
        if let Some(k) = blocked {
            if Some(t.id) == b.assign.target {
                b.blocked_s += dt;
            }
            self.tel.count(k);
        }
        let hold = in_range && blocked.is_none() && b.gun.sync_hold(now, b.inputs.ready_guns, b.inputs.max_lag_s);
        let dark = b.plan.is_some_and(|p| p.dark);
        b.cmd.fire = in_range && blocked.is_none() && !hold && !dark;
        b.last_gate = if !in_range { "out_of_range" } else if let Some(k) = blocked { k } else if hold { "sync_hold" } else if dark { "dark" } else { "fire" };
        *b.gates.entry(b.last_gate).or_default() += 1;
        b.last_gate
    }

    fn consumables(&mut self, i: usize) {
        let b = &mut self.bots[i];
        let Some(me) = self.snap.get(b.ship_id) else { return };
        let inp = b.inputs;
        b.cmd.use_repair = inp.repair_ready && (inp.healable > inp.heal_per_use || me.hp_frac < 0.25) && inp.healable > 0.0;
        let bad = |n: i32| (me.hp_frac < 0.5 && n >= 1) || n >= 2;
        b.cmd.use_dc = inp.dc_ready && (bad(inp.fires) || bad(inp.floods));
    }
}

/// One per match. GDScript feeds a ship snapshot each physics frame and reads one command per bot.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct BotWorld {
    base: Base<RefCounted>,
    w: World,
}

#[godot_api]
impl BotWorld {
    #[func]
    fn setup(&mut self, map: Option<Gd<NavigationMap>>, hpa: Option<Gd<HpaGraph>>, registry: Option<Gd<ShipRegistry>>,
            pm: Option<Gd<ProjectileManager>>, space: Option<Gd<PhysicsDirectSpaceState3D>>,
            vis: Option<Gd<VisibilityGrid>>, reach: Option<Gd<ReachField>>) {
        self.w.vis = vis;
        self.w.reach = reach;
        self.w.map = map;
        self.w.space = space;
        self.w.hpa = hpa;
        self.w.registry = registry;
        self.w.store = pm.as_ref().map(|p| p.bind().point_store.clone());
        self.w.pm = pm;
    }

    /// False until the navigation map is built.
    #[func]
    fn prepare(&mut self) -> bool {
        self.w.prepare()
    }

    #[func]
    fn add_bot(&mut self, cfg: VarDictionary) -> i32 {
        self.w.add_bot(&cfg)
    }

    #[func]
    fn bot_count(&self) -> i32 {
        self.w.bots.len() as i32
    }

    #[func]
    fn bot_ship_id(&self, slot: i32) -> i64 {
        self.w.bots.get(slot as usize).map_or(0, |b| b.ship_id)
    }

    /// Point-table keys of `slot`'s AP/HE shells against `target_id`'s hull; "" = no table for that shell.
    /// Point-table keys of enemy `enemy_id`'s AP/HE against `slot`'s hull; "" = no table for that shell.
    #[func]
    fn set_threat(&mut self, slot: i32, enemy_id: i64, key_ap: GString, key_he: GString) {
        let Some(b) = self.w.bots.get_mut(slot as usize) else { return };
        let k = |s: GString| { let s = s.to_string(); (!s.is_empty()).then_some(s) };
        b.threats.insert(enemy_id, [k(key_ap), k(key_he)]);
    }

    #[func]
    fn has_threat(&self, slot: i32, enemy_id: i64) -> bool {
        self.w.bots.get(slot as usize).is_some_and(|b| b.threats.contains_key(&enemy_id))
    }

    #[func]
    fn set_pair(&mut self, slot: i32, target_id: i64, key_ap: GString, key_he: GString, raw_fire_he: f32) {
        let Some(b) = self.w.bots.get_mut(slot as usize) else { return };
        let k = |s: GString| { let s = s.to_string(); (!s.is_empty()).then_some(s) };
        b.gun.pairs.insert(target_id, PairTables { keys: [k(key_ap), k(key_he)], raw_fire: [0.0, raw_fire_he] });
    }

    #[func]
    fn has_pair(&self, slot: i32, target_id: i64) -> bool {
        self.w.bots.get(slot as usize).is_some_and(|b| b.gun.pairs.contains_key(&target_id))
    }

    /// `fires`: target-local [x, y, z, burning] per fire zone.
    /// Cumulative main-battery damage dealt and taken by the slot's ship.
    #[func]
    fn set_damage(&mut self, slot: i32, now: f64, dealt: f32, taken: f32) {
        self.w.damage_sample(slot as usize, now, dealt, taken);
    }

    /// {"in": {class: k}, "out": {"class>class": k}}: real over predicted main-battery damage.
    #[func]
    fn set_time_left(&mut self, s: f32) {
        self.w.time_left = s;
    }

    #[func]
    fn set_calib(&mut self, d: VarDictionary) {
        let read = |k: &str| d.get(k).and_then(|v| v.try_to::<VarDictionary>().ok()).map(|m| m.iter_shared()
            .map(|(k, v)| (k.to_string(), v.to_f32())).collect::<HashMap<_, _>>()).unwrap_or_default();
        self.w.calib_in = read("in");
        self.w.calib_out = read("out");
    }

    #[func]
    fn set_target_live(&mut self, id: i64, sat: i64, fires: PackedFloat32Array, fire_k: f32) {
        let fires = fires.as_slice().chunks_exact(4).map(|c| (Vector3::new(c[0], c[1], c[2]), c[3] > 0.5)).collect();
        self.w.live.insert(id, TargetLive { sat, fires, fire_k });
    }

    /// [owner team, x, z, vx, vz] per armed enemy torpedo the other team has seen.
    #[func]
    fn set_torpedoes(&mut self, data: PackedFloat32Array) {
        self.w.torps_in = data.as_slice().chunks_exact(5).map(|c| [c[0], c[1], c[2], c[3], c[4]]).collect();
    }

    #[func]
    fn set_ships(&mut self, ids: PackedInt64Array, data: PackedFloat32Array) {
        self.w.snap.load(ids.as_slice(), data.as_slice());
    }

    #[func]
    fn set_bot_inputs(&mut self, slot: i32, v: PackedFloat32Array) {
        let Some(b) = self.w.bots.get_mut(slot as usize) else { return };
        let v = v.as_slice();
        if v.len() < BOT_INPUT_STRIDE {
            return;
        }
        b.inputs = BotInputs {
            ready_guns: v[0] as i32,
            max_lag_s: v[2],
            healable: v[3],
            heal_per_use: v[4],
            fires: v[5] as i32,
            floods: v[6] as i32,
            repair_ready: v[7] > 0.5,
            dc_ready: v[8] > 0.5,
            rudder: v[9],
            engine_power: v[10],
            grounded: v[11] > 0.5,
            torp_ready: v[12] as i32,
            torp_live: v[13] as i32,
            launch_from: Vector2::new(v[14], v[15]),
            spot_ready: v[16] > 0.5,
            spot_active: v[17] > 0.5,
        };
    }

    #[func]
    fn tick(&mut self, now: f64, dt: f32, time_mult: f64) {
        self.w.tick(now, dt, time_mult);
    }

    /// [throttle, rudder, has_aim, aim x, y, z, ammo, fire, use_repair, use_dc, has_target, plan serial,
    /// has_torp_aim, torp x, z, torp_fire, spot, spot x, z] per bot.
    #[func]
    fn commands(&self) -> PackedFloat64Array {
        let mut v = Vec::with_capacity(self.w.bots.len() * CMD_STRIDE);
        for b in &self.w.bots {
            let c = b.cmd;
            let a = c.aim.unwrap_or(Vector3::ZERO);
            v.extend_from_slice(&[c.throttle as f64, c.rudder as f64, c.aim.is_some() as i32 as f64, a.x as f64, a.y as f64,
                a.z as f64, c.ammo as f64, c.fire as i32 as f64, c.use_repair as i32 as f64, c.use_dc as i32 as f64,
                b.assign.target.is_some() as i32 as f64, b.serial as f64]);
            let t = c.torp_aim.unwrap_or(Vector2::ZERO);
            let sp = c.spot.unwrap_or(Vector2::ZERO);
            v.extend_from_slice(&[c.torp_aim.is_some() as i32 as f64, t.x as f64, t.y as f64, c.torp_fire as i32 as f64,
                c.spot.is_some() as i32 as f64, sp.x as f64, sp.y as f64]);
        }
        PackedFloat64Array::from(v.as_slice())
    }

    #[func]
    fn target_of(&self, slot: i32) -> i64 {
        self.w.bots.get(slot as usize).and_then(|b| b.assign.target).unwrap_or(0)
    }

    /// The adapter fired `guns` guns of `slot` on its current aim.
    #[func]
    fn note_fired(&mut self, slot: i32, guns: i32, now: f64) {
        let w = &mut self.w;
        let Some(b) = w.bots.get(slot as usize) else { return };
        let Some(a) = b.gun.aim else { return };
        let (Some(me), Some(t)) = (w.snap.get(b.ship_id), w.snap.get(a.target)) else { return };
        w.tel.salvo(now, me, t, a, guns);
    }

    #[func]
    fn note_torp_fired(&mut self, slot: i32, now: f64) {
        let Some(b) = self.w.bots.get_mut(slot as usize) else { return };
        b.torp_idx += 1;
        b.torp_last_fire = now;
        self.w.tel.count("torp_launch");
    }

    #[func]
    fn note(&mut self, counter: GString) {
        let k: &'static str = match counter.to_string().as_str() {
            "not_aimed" => "not_aimed",
            "ammo_switch" => "ammo_switch",
            _ => "other",
        };
        self.w.tel.count(k);
    }

    #[func]
    fn telemetry(&self) -> VarDictionary {
        let mut d = self.w.tel.to_dict();
        let mut t = VarDictionary::new();
        t.set("hive_us", self.w.time_us[0] as i64);
        t.set("drive_us", self.w.time_us[1] as i64);
        t.set("guns_us", self.w.time_us[2] as i64);
        t.set("field_us", self.w.time_us[3] as i64);
        t.set("scan_cells_us", self.w.scan_us[0] as i64);
        t.set("scan_exact_us", self.w.scan_us[1] as i64);
        t.set("curves_us", self.w.scan_us[2] as i64);
        t.set("scan_setup_us", self.w.scan_us[3] as i64);
        t.set("frames", self.w.frame);
        d.set("timing", &t);
        d
    }

    /// The slot's team belief: true vs believed vs this bot's delayed view per contact, and every bot's target.
    #[func]
    fn debug_team(&self, slot: i32, now: f64) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(b) = self.w.bots.get(slot as usize) else { return d };
        let Some(h) = self.w.teams.get(&b.team) else { return d };
        let delay = b.apt.view_delay_s();
        let v3 = |p: Vector2| Vector3::new(p.x, 0.0, p.y);
        let mut contacts = VarArray::new();
        for (id, c) in &h.belief.contacts {
            let mut e = VarDictionary::new();
            e.set("id", *id);
            e.set("seen", c.seen_now);
            e.set("age", now - c.last_seen);
            e.set("belief", v3(c.last_pos));
            if let Some(p) = h.belief.pos_at(*id, now, delay) {
                e.set("view", v3(p));
            }
            if let Some(s) = self.w.snap.get(*id) {
                e.set("pos", s.pos);
            }
            contacts.push(&e.to_variant());
        }
        d.set("contacts", &contacts);
        let mut targets = VarArray::new();
        for o in self.w.bots.iter().filter(|o| o.team == b.team) {
            let (Some(t), Some(me)) = (o.assign.target, self.w.snap.get(o.ship_id).filter(|s| s.alive)) else { continue };
            let mut e = VarDictionary::new();
            e.set("ship", o.ship_id);
            e.set("pos", me.pos);
            e.set("target", t);
            targets.push(&e.to_variant());
        }
        d.set("targets", &targets);
        if let Some(sp) = h.belief.enemy_spawn {
            d.set("enemy_spawn", v3(sp));
        }
        let pres: Vec<Vector3> = h.belief.presumed.iter().map(|r| v3(r.pos)).collect();
        d.set("presumed", &PackedVector3Array::from(pres.as_slice()));
        let mut flanks = VarArray::new();
        for g in h.flanks.iter().flat_map(|f| f.groups.iter()) {
            let mut e = VarDictionary::new();
            e.set("centre", v3(g.centre));
            e.set("enemy", g.enemy);
            e.set("own", g.own);
            e.set("pressure", g.pressure());
            e.set("live", g.live());
            flanks.push(&e.to_variant());
        }
        d.set("flanks", &flanks);
        let mut roles = VarArray::new();
        for o in self.w.bots.iter().filter(|o| o.team == b.team) {
            let (Some(r), Some(me)) = (o.role, self.w.snap.get(o.ship_id).filter(|s| s.alive)) else { continue };
            let mut e = VarDictionary::new();
            e.set("pos", me.pos);
            e.set("role", r.label());
            let Role::Flank(f) = r;
            e.set("flank", f as i64);
            roles.push(&e.to_variant());
        }
        d.set("roles", &roles);
        d.set("view_delay", delay);
        d
    }

    /// Debug overlay, one byte per VisibilityGrid cell (row-major, land 0): 1 berth, 2 gap, 3 lattice, 4 other water.
    /// PHASES µs per tick, flattened.
    #[func]
    fn frame_phases(&self) -> PackedInt32Array {
        PackedInt32Array::from(self.w.phases.iter().flat_map(|p| p.iter().map(|&v| v as i32)).collect::<Vec<_>>().as_slice())
    }

    #[func]
    fn feature_bytes(&self) -> PackedByteArray {
        let (Some(f), Some(vis)) = (&self.w.features, &self.w.vis) else { return PackedByteArray::new() };
        PackedByteArray::from(f.bytes(&vis.bind()).as_slice())
    }

    /// Debug overlay, one byte per VisibilityGrid cell (row-major, land 0): 1 seen not shot, 2 shot not seen, 3 both.
    /// `dark`: seen at the slot's concealment, else at its firing bloom (gun range).
    #[func]
    fn field_bytes(&self, slot: i32, dark: bool) -> PackedByteArray {
        let (Some(b), Some(lay), Some(vis)) = (self.w.bots.get(slot as usize), &self.w.layout, &self.w.vis) else { return PackedByteArray::new() };
        let (Some(h), Some(me)) = (self.w.teams.get(&b.team), self.w.snap.get(b.ship_id)) else { return PackedByteArray::new() };
        let vis = vis.bind();
        let seen = h.field.seen(lay, &vis, if dark { me.conceal } else { me.conceal.max(me.gun_range) });
        let out: Vec<u8> = vis.index.iter().map(|&k| if k < 0 { 0 } else {
            let k = k as usize;
            field::has(&seen, k) as u8 | (field::has(&h.field.shot, k) as u8) << 1
        }).collect();
        PackedByteArray::from(out.as_slice())
    }

    #[func]
    fn debug_bot(&self, slot: i32) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(b) = self.w.bots.get(slot as usize) else { return d };
        d.set("ship_id", b.ship_id);
        d.set("playstyle", b.style.name());
        d.set("aptitude", b.apt.level);
        d.set("clear", b.gun.last_clear().map_or("none", |c| c.name()));
        d.set("target", b.assign.target.unwrap_or(0));
        if let Some(r) = b.role {
            d.set("role", r.label());
        }
        if let Some(p) = b.plan {
            d.set("posture", p.posture.name());
            d.set("station", Vector3::new(p.station.x, 0.0, p.station.y));
            d.set("anchor", Vector3::new(p.anchor.x, 0.0, p.anchor.y));
            d.set("heading", p.heading);
            d.set("hold_left", p.hold_until);
            d.set("disengage", p.posture == Posture::Disengage);
        }
        if let Some(a) = b.gun.aim {
            d.set("aim", a.world);
            d.set("aim_offset", a.offset_local);
            d.set("ammo", a.ammo as i64);
            d.set("ev", a.value);
        }
        d.set("path", &b.nav.bind().get_current_path_impl());
        d.set("trajectory", &b.nav.bind().get_predicted_trajectory_impl());
        d.set("gate", b.last_gate);
        d.set("mounts", b.mounts.len() as i64);
        if b.stance.active {
            d.set("stance", b.stance.why);
            d.set("stance_heading", b.stance.heading);
            d.set("stance_astern", b.stance.astern);
        }
        d.set("blocked_s", b.blocked_s);
        d.set("walls", &b.walls.iter().map(|w| Vector3::new(w.0.x, w.1, w.0.y)).collect::<PackedVector3Array>());
        if let Some((r, t)) = b.last_release {
            d.set("release", r);
            d.set("release_at", t);
        }
        if let Some(a) = b.torp_aim {
            let pts: Vec<Vector3> = (0..a.n).map(|k| Vector3::new(a.points[k].x, 0.0, a.points[k].y)).collect();
            d.set("torp_points", &PackedVector3Array::from(pts.as_slice()));
            d.set("torp_next", (b.torp_idx % a.n.max(1)) as i64);
            d.set("torp_chance", a.chance);
            d.set("torp_target", a.target);
            d.set("torp_intercept", Vector3::new(a.intercept.x, 0.0, a.intercept.y));
            d.set("torp_from", Vector3::new(b.inputs.launch_from.x, 0.0, b.inputs.launch_from.y));
        }
        if b.torp.is_some() {
            d.set("torp_gate", b.torp_gate);
        }
        if let Some(p) = b.spot_point {
            d.set("spot_point", Vector3::new(p.x, 0.0, p.y));
            d.set("spot_target", b.spot_target.unwrap_or(0));
        }
        if b.spot_reach > 0.0 {
            d.set("spot_reach", b.spot_reach);
            d.set("spot_up", b.inputs.spot_active);
        }
        if let Some(gunnery::Clear::Friendly(id)) = b.gun.last_clear() {
            d.set("blocked_by", id);
        }
        let mut g = VarDictionary::new();
        for (k, v) in &b.gates {
            g.set(*k, *v as i64);
        }
        d.set("gates", &g);
        if let Some(me) = self.w.snap.get(b.ship_id) {
            d.set("pos", me.pos);
            d.set("hp", me.hp_frac);
            d.set("gun_range", me.gun_range);
            let band = b.trade_band.unwrap_or((b.style.style().band.0 * me.gun_range, b.style.style().band.1 * me.gun_range));
            d.set("band_lo", band.0);
            d.set("band_hi", band.1);
            d.set("brawl", b.brawl);
            if let Some(id) = b.spot_for {
                d.set("spot_for", id);
            }
            if let Some(p) = b.plan {
                d.set("hold_radius", p.hold_radius);
                d.set("station_shot", p.shot);
            }
            if let Some(t) = b.assign.target.and_then(|id| self.w.snap.get(id)) {
                d.set("target_dist", me.pos.distance_to(t.pos));
                if let Some(a) = b.gun.aim.filter(|a| a.target == t.id) {
                    d.set("impact_pos", t.pos + t.vel * a.tof_game);
                }
            }
        }
        d
    }
}
