use godot::prelude::*;
use std::collections::{HashMap, HashSet, VecDeque};

use super::snapshot::Snapshot;

const SAMPLE_S: f64 = 1.0;
const HISTORY_S: f64 = 20.0;
pub const FORGET_S: f64 = 90.0;
/// EnemyPresumption ADVANCE_SPEED and RADIUS_GROWTH: half flank. v4's class multipliers (DD 1.3, CA 1.0, BB 0.85
/// over a nominal 30 kn) were flank speed ratios; max_speed is game speed (SHIP_SPEED_MODIFIER in), so none here.
const ADVANCE_SHARE: f32 = 0.5;
const GROWTH_SHARE: f32 = 0.5;
/// EnemyPresumption.ENGAGEMENT_GAP: the march stops half of what the spawn gap leaves beyond this.
const ENGAGEMENT_GAP_M: f32 = 16000.0;
pub const RADIUS_MIN_M: f32 = 1500.0;
const RADIUS_MAX_M: f32 = 9000.0;
const SPREAD_MAX_M: f32 = 2500.0;
const REF_STEP_M: f32 = 250.0;
/// A shot this recent places an unseen shooter where it is now (v4 note_gunfire).
const GUNFIRE_FIX_S: f64 = 1.0;
/// Water this near one of our ships with nothing spotted is presumed empty of the unseen.
const SEARCH_M: f32 = 8000.0;

/// An enemy never seen, presumed marching from its spawn slot down its lane.
pub struct Presumed {
    pub id: i64,
    pub spawn: Vector2,
    pub pos: Vector2,
    dir: Vector2,
    stop: f32,
    /// Pushed out of searched water: stays where it was pushed instead of marching.
    held: bool,
    speed: f32,
}

pub struct Contact {
    hist: VecDeque<(f64, Vector2)>,
    pub last_seen: f64,
    pub last_pos: Vector2,
    pub last_hp: f32,
    pub seen_now: bool,
}

/// Team knowledge built only from what the team has spotted.
#[derive(Default)]
pub struct Belief {
    pub contacts: HashMap<i64, Contact>,
    pub enemy_spawn: Option<Vector2>,
    pub own_spawn: Option<Vector2>,
    pub presumed: Vec<Presumed>,
    identified: HashSet<i64>,
    pub start: f64,
    /// Enemy spawn toward ours, and how far along it a march stops.
    axis: Vector2,
    max_advance: f32,
    pub seen_count: usize,
}

impl Contact {
    /// Over its last two sightings.
    pub fn vel(&self) -> Vector2 {
        let mut it = self.hist.iter().rev();
        match (it.next(), it.next()) {
            (Some(&(t1, p1)), Some(&(t0, p0))) if t1 > t0 => (p1 - p0) / (t1 - t0) as f32,
            _ => Vector2::ZERO,
        }
    }
}

impl Belief {
    /// Returns how many enemies became spotted this update. `water(p)`: open water a fleet can sail.
    pub fn update(&mut self, now: f64, snap: &Snapshot, team: i32, water: &dyn Fn(Vector2) -> bool) -> usize {
        if self.enemy_spawn.is_none() {
            self.enemy_spawn = centroid(snap.enemies_of(team).map(|e| e.p2()));
            self.own_spawn = centroid(snap.allies_of(team).map(|e| e.p2()));
            if let (Some(es), Some(os)) = (self.enemy_spawn, self.own_spawn) {
                self.start = now;
                let dir = (os - es).normalized_or_zero();
                self.axis = dir;
                self.max_advance = ((es.distance_to(os) - ENGAGEMENT_GAP_M) * 0.5).max(0.0);
                for e in snap.enemies_of(team) {
                    let spawn = e.p2();
                    let mut stop = self.max_advance;
                    let mut d = 0.0;
                    while d < stop {
                        if !water(spawn + dir * (d + REF_STEP_M)) {
                            stop = d;
                        }
                        d += REF_STEP_M;
                    }
                    self.presumed.push(Presumed { id: e.id, spawn, pos: spawn, dir, stop, held: false, speed: e.max_speed * ADVANCE_SHARE });
                }
            }
        }
        self.contacts.retain(|id, _| snap.get(*id).is_some_and(|s| s.alive));
        let mut fresh = 0;
        let mut seen = 0;
        for e in snap.enemies_of(team) {
            let fired = !e.seen && e.alive && now - e.fired_at as f64 <= GUNFIRE_FIX_S;
            if !e.seen && !fired {
                if let Some(c) = self.contacts.get_mut(&e.id) {
                    c.seen_now = false;
                }
                continue;
            }
            if self.identified.insert(e.id) {
                self.presumed.retain(|r| r.id != e.id);
            }
            if fired {
                let c = self.contacts.entry(e.id).or_insert_with(|| Contact {
                    hist: VecDeque::new(), last_seen: now, last_pos: e.p2(), last_hp: e.hp_frac, seen_now: false });
                c.seen_now = false;
                c.last_seen = now;
                c.last_pos = e.p2();
                if c.hist.back().is_none_or(|&(t, _)| now - t >= SAMPLE_S) {
                    c.hist.push_back((now, e.p2()));
                }
                continue;
            }
            let c = self.contacts.entry(e.id).or_insert_with(|| Contact {
                hist: VecDeque::new(),
                last_seen: now,
                last_pos: e.p2(),
                last_hp: e.hp_frac,
                seen_now: false,
            });
            let was = c.seen_now;
            c.seen_now = true;
            seen += 1;
            if !was {
                fresh += 1;
            }
            c.last_seen = now;
            c.last_pos = e.p2();
            c.last_hp = e.hp_frac;
            if c.hist.back().is_none_or(|&(t, _)| now - t >= SAMPLE_S) {
                c.hist.push_back((now, e.p2()));
            }
            while c.hist.front().is_some_and(|&(t, _)| now - t > HISTORY_S) {
                c.hist.pop_front();
            }
        }
        self.seen_count = seen;
        self.march(now, snap, team);
        fresh
    }

    fn march(&mut self, now: f64, snap: &Snapshot, team: i32) {
        let t = ((now - self.start) as f32).max(0.0);
        for r in self.presumed.iter_mut() {
            if !r.held {
                r.pos = r.spawn + r.dir * (t * r.speed).min(r.stop);
            }
            for a in snap.allies_of(team) {
                let off = r.pos - a.p2();
                let d = off.length();
                if d < SEARCH_M {
                    let out = if d > 1.0 { off / d } else { -r.dir };
                    r.pos = a.p2() + out * SEARCH_M;
                    r.held = true;
                }
            }
        }
    }

    /// Each presumed enemy now, and `secs` further along its march.
    pub fn presumed_now_ahead(&self, secs: f32) -> impl Iterator<Item = (i64, Vector2, Vector2)> + '_ {
        self.presumed.iter().map(move |r| (r.id, r.pos, if r.held { r.pos } else {
            r.spawn + r.dir * ((r.pos - r.spawn).length() + r.speed * secs).min(r.stop)
        }))
    }

    /// v4 EnemyPresumption._advance from a lost contact's last position: on along the spawn axis at half flank, never
    /// past the march's stop line.
    pub fn lost_at(&self, c: &Contact, max_speed: f32, now: f64) -> Vector2 {
        let (Some(es), dir) = (self.enemy_spawn, self.axis) else { return c.last_pos };
        let left = (self.max_advance - (c.last_pos - es).dot(dir)).max(0.0);
        c.last_pos + dir * ((now - c.last_seen) as f32 * max_speed * ADVANCE_SHARE).min(left)
    }
}

/// v4 EnemyPresumption radius over `unseen_s`, from the ship's own flank speed.
pub fn radius(unseen_s: f32, max_speed: f32) -> f32 {
    (RADIUS_MIN_M + unseen_s.max(0.0) * max_speed * GROWTH_SHARE).clamp(RADIUS_MIN_M, RADIUS_MAX_M)
}

/// v4 EnemyPresumption.certainty.
pub fn certainty(r: f32) -> f32 {
    (1.0 - (r - RADIUS_MIN_M) / (RADIUS_MAX_M - RADIUS_MIN_M)).clamp(0.0, 1.0)
}

/// v4 EnemyPresumption.guess_spread.
pub fn spread(r: f32) -> f32 {
    (r * 0.5).min(SPREAD_MAX_M)
}

impl Belief {

    /// Where the presumed enemy nearest `p` ends its march: a stable opening reference.
    pub fn presumed_end(&self, p: Vector2) -> Option<Vector2> {
        self.presumed.iter().map(|r| if r.held { r.pos } else { r.spawn + r.dir * r.stop })
            .min_by(|a, b| a.distance_to(p).total_cmp(&b.distance_to(p)))
    }

    /// Where the latest-seen enemy was last seen, however long ago.
    pub fn last_known(&self) -> Option<Vector2> {
        self.contacts.values().max_by(|a, b| a.last_seen.total_cmp(&b.last_seen)).map(|c| c.last_pos)
    }

    /// Where the team believed `id` was `delay` seconds ago; None if not known by then.
    pub fn pos_at(&self, id: i64, now: f64, delay: f64) -> Option<Vector2> {
        let c = self.contacts.get(&id)?;
        if now - c.last_seen > FORGET_S {
            return None;
        }
        if delay <= 0.0 {
            return Some(c.last_pos);
        }
        let at = now - delay;
        if c.last_seen <= at {
            return Some(c.last_pos);
        }
        c.hist.iter().rev().find(|&&(t, _)| t <= at).map(|&(_, p)| p)
    }
}

fn centroid(it: impl Iterator<Item = Vector2>) -> Option<Vector2> {
    let (mut s, mut n) = (Vector2::ZERO, 0.0);
    for p in it {
        s += p;
        n += 1.0;
    }
    (n > 0.0).then(|| s / n)
}
