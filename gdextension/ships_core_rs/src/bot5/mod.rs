//! Bot controller v5: team hive + per-bot controllers. See doc/BOT_V5_DESIGN.md.

pub mod belief;
pub mod gunnery;
pub mod hive;
pub mod params;
pub mod snapshot;
pub mod telemetry;
pub mod torpedo;

use godot::classes::{PhysicsDirectSpaceState3D, Resource};
use godot::prelude::*;
use std::collections::HashMap;

use crate::nav::hpa::HpaGraph;
use crate::nav::map::NavigationMap;
use crate::nav::navigator::ShipNavigator;
use crate::nav::ships::ShipRegistry;
use crate::projectile::manager::point_store::Store;
use crate::projectile::manager::ProjectileManager;
use crate::variant_cast::VariantCast;

use belief::Belief;
use gunnery::{Clear, Gunnery, PairTables, TargetLive};
use hive::{Assignment, Committed, Member, Plan, Posture};
use params::{Aptitude, Kinematics, Playstyle};
use snapshot::{HullClass, ShipState, Snapshot};
use telemetry::Telemetry;
use torpedo::{TorpAim, TorpSpec, Tracks};

const HIVE_INTERVAL_S: f64 = 1.0;
const EVENT_MIN_GAP_S: f64 = 0.25;
const HP_EVENT_DROP: f32 = 0.15;
const NAV_STATE_EVERY: i64 = 2;
const NAV_PUSH_EVERY: i64 = 12;
const AIM_EVERY: i64 = 3;
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
    team: i32,
    style: Playstyle,
    apt: Aptitude,
    nav: Gd<ShipNavigator>,
    plan: Option<Plan>,
    assign: Assignment,
    pushed: Option<(u32, Vector2)>,
    gun: Gunnery,
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
}

#[derive(Default)]
struct TeamHive {
    belief: Belief,
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
    store: Option<Store>,
    snap: Snapshot,
    bots: Vec<Bot>,
    teams: HashMap<i32, TeamHive>,
    live: HashMap<i64, TargetLive>,
    tel: Telemetry,
    allies: Vec<ShipState>,
    tracks: Tracks,
    frame: i64,
    time_mult: f64,
    time_us: [u64; 3],
}

impl World {
    fn add_bot(&mut self, cfg: &VarDictionary) -> i32 {
        let g = |k: &str| cfg.get(k).map_or(0.0, |v| v.to_f32());
        let ship_id = cfg.get("ship_id").map_or(0, |v| v.to_i64());
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
            team,
            style: Playstyle::from_i32(cfg.get("playstyle").map_or(-1, |v| v.to_i32()), class),
            apt: Aptitude { level: g("aptitude") as i32 },
            nav,
            plan: None,
            assign: Assignment::default(),
            pushed: None,
            gun,
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
        });
        (self.bots.len() - 1) as i32
    }

    fn tick(&mut self, now: f64, dt: f32, time_mult: f64) {
        self.frame += 1;
        self.time_mult = time_mult;
        let t0 = std::time::Instant::now();
        self.update_beliefs(now);
        self.tracks.update(now, &self.snap.ships);
        self.hive(now);
        let t1 = std::time::Instant::now();
        for i in 0..self.bots.len() {
            self.drive(i, dt);
        }
        let t2 = std::time::Instant::now();
        for i in 0..self.bots.len() {
            self.guns(i, now, dt, time_mult);
            self.torps(i, now);
            self.consumables(i);
            self.spot_cmd(i);
        }
        self.tel.resolve(now, &self.snap);
        let t3 = std::time::Instant::now();
        self.time_us[0] += (t1 - t0).as_micros() as u64;
        self.time_us[1] += (t2 - t1).as_micros() as u64;
        self.time_us[2] += (t3 - t2).as_micros() as u64;
    }

    fn update_beliefs(&mut self, now: f64) {
        for (&team, h) in self.teams.iter_mut() {
            if h.belief.update(now, &self.snap, team) > 0 {
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
        let teams: Vec<i32> = self.teams.keys().copied().collect();
        for team in teams {
            let h = self.teams.get_mut(&team).unwrap();
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
        }
    }

    /// Ascending aptitude: weaker bots commit first; stronger ones plan around them.
    fn solve_team(&mut self, team: i32, now: f64) {
        let mut order: Vec<usize> = (0..self.bots.len())
            .filter(|&i| self.bots[i].team == team && self.snap.get(self.bots[i].ship_id).is_some_and(|s| s.alive))
            .collect();
        order.sort_by_key(|&i| (self.bots[i].apt.level, self.bots[i].ship_id));
        let mut committed: Vec<Committed> = Vec::with_capacity(order.len());
        let store = self.store.clone();
        let time_mult = self.time_mult;
        for i in order {
            let snap = &self.snap;
            let me = snap.get(self.bots[i].ship_id).unwrap();
            let belief = &self.teams[&team].belief;
            let bot = &self.bots[i];
            let m = Member { me, style: bot.style.style(), apt: bot.apt, plan: bot.plan, assign: bot.assign, blocked_s: bot.blocked_s,
                torp: bot.torp.map(|t| (t.range, bot.inputs.torp_ready > 0)) };
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
            let (plan, assign, reason) = hive::resolve(&m, snap, belief, &committed, now, &mut ev);
            let hp = me.hp_frac;
            for _ in 0..no_table {
                self.tel.count("target_no_table");
            }
            if let Some(r) = reason {
                self.tel.release(r);
            }
            let bot = &mut self.bots[i];
            if let Some(r) = reason {
                bot.last_release = Some((r, now));
            }
            bot.hp_at_pass = hp;
            bot.assign = assign;
            if let Some(mut p) = plan {
                if reason.is_some() {
                    bot.serial += 1;
                    p.station = self.valid_station(i, me.p2(), p.station);
                }
                p.serial = self.bots[i].serial;
                self.bots[i].plan = Some(p);
            }
            committed.push(Committed { target: assign.target });
        }
        self.spotters(team, now);
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

    fn drive(&mut self, i: usize, dt: f32) {
        let frame = self.frame;
        let b = &mut self.bots[i];
        let Some(me) = self.snap.get(b.ship_id).copied().filter(|s| s.alive) else {
            b.cmd = Command::default();
            return;
        };
        let slot = i as i64;
        let mut nav = b.nav.bind_mut();
        if frame % NAV_STATE_EVERY == slot % NAV_STATE_EVERY {
            nav.set_state_impl(me.pos, me.vel, me.heading(), me.yaw_rate, b.inputs.rudder, me.speed(),
                b.inputs.engine_power, dt * NAV_STATE_EVERY as f32);
            nav.grounded = b.inputs.grounded;
            nav.set_health_fraction_impl(me.hp_frac);
        }
        if let Some(p) = b.plan {
            let jumped = b.pushed.is_none_or(|(s, at)| s != p.serial && at.distance_to(p.station) >= STATION_JUMP_M);
            if jumped || frame % NAV_PUSH_EVERY == slot % NAV_PUSH_EVERY {
                nav.navigate_to_impl(Vector3::new(p.station.x, 0.0, p.station.y), p.heading, p.hold_radius, 0.2618,
                    p.heading_weight, false, false);
                b.pushed = Some((p.serial, p.station));
            }
        }
        b.cmd.rudder = nav.out_rudder;
        b.cmd.throttle = nav.out_throttle;
    }

    fn guns(&mut self, i: usize, now: f64, dt: f32, time_mult: f64) {
        let frame = self.frame;
        let Some(store) = self.store.clone() else { return };
        let b = &mut self.bots[i];
        let Some(me) = self.snap.get(b.ship_id).copied().filter(|s| s.alive) else { return };
        if b.serial != b.blocked_serial {
            b.blocked_serial = b.serial;
            b.blocked_s = 0.0;
        }
        b.blocked_s *= (-dt / BLOCKED_DECAY_S).exp();
        let target = b.assign.target.and_then(|id| self.snap.get(id)).copied().filter(|t| t.alive && t.seen);
        b.last_gate = if b.assign.target.is_none() { "no_target" } else if target.is_none() { "target_unseen" } else { "has_target" };
        *b.gates.entry(b.last_gate).or_default() += 1;
        let Some(t) = target else {
            b.gun.aim = None;
            b.cmd.fire = false;
            b.cmd.aim = b.plan.map(|p| Vector3::new(p.anchor.x, 0.0, p.anchor.y));
            return;
        };
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
            return;
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
            b.blocked_s += dt;
            self.tel.count(k);
        }
        let hold = in_range && blocked.is_none() && b.gun.sync_hold(now, b.inputs.ready_guns, b.inputs.max_lag_s);
        b.cmd.fire = in_range && blocked.is_none() && !hold;
        b.last_gate = if !in_range { "out_of_range" } else if let Some(k) = blocked { k } else if hold { "sync_hold" } else { "fire" };
        *b.gates.entry(b.last_gate).or_default() += 1;
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
            pm: Option<Gd<ProjectileManager>>, space: Option<Gd<PhysicsDirectSpaceState3D>>) {
        self.w.map = map;
        self.w.space = space;
        self.w.hpa = hpa;
        self.w.registry = registry;
        self.w.store = pm.map(|p| p.bind().point_store.clone());
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
    #[func]
    fn set_target_live(&mut self, id: i64, sat: i64, fires: PackedFloat32Array, fire_k: f32) {
        let fires = fires.as_slice().chunks_exact(4).map(|c| (Vector3::new(c[0], c[1], c[2]), c[3] > 0.5)).collect();
        self.w.live.insert(id, TargetLive { sat, fires, fire_k });
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
        d.set("view_delay", delay);
        d
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
        if let Some(p) = b.plan {
            d.set("posture", p.posture.name());
            d.set("station", Vector3::new(p.station.x, 0.0, p.station.y));
            d.set("anchor", Vector3::new(p.anchor.x, 0.0, p.anchor.y));
            d.set("heading", p.heading);
            d.set("hold_left", p.hold_until);
            d.set("retreat", p.posture == Posture::Retreat);
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
        d.set("blocked_s", b.blocked_s);
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
            let band = b.style.style().band;
            d.set("band_lo", band.0 * me.gun_range);
            d.set("band_hi", band.1 * me.gun_range);
            if let Some(p) = b.plan {
                d.set("hold_radius", p.hold_radius);
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
