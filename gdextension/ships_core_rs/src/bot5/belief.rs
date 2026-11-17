use godot::prelude::*;
use std::collections::{HashMap, HashSet, VecDeque};

use super::snapshot::Snapshot;

const SAMPLE_S: f64 = 1.0;
const HISTORY_S: f64 = 20.0;
pub const FORGET_S: f64 = 90.0;
/// EnemyPresumption.ADVANCE_SPEED: half of 30 kn at ShipMovementV4's speed scale.
const ADVANCE_MPS: f32 = 30.0 * 0.514444 * 2.6 * 0.5;
const REF_STOP_SHORT_M: f32 = 6000.0;
const REF_STEP_M: f32 = 250.0;
/// Water this near one of our ships with nothing spotted is presumed empty of the unseen.
const SEARCH_M: f32 = 8000.0;

/// An enemy never seen, presumed marching from its spawn slot down its lane.
pub struct Presumed {
    pub spawn: Vector2,
    pub pos: Vector2,
    dir: Vector2,
    stop: f32,
    /// Pushed out of searched water: stays where it was pushed instead of marching.
    held: bool,
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
    start: f64,
    pub seen_count: usize,
}

impl Belief {
    /// Returns how many enemies became spotted this update. `water(p)`: open water a fleet can sail.
    pub fn update(&mut self, now: f64, snap: &Snapshot, team: i32, water: &dyn Fn(Vector2) -> bool) -> usize {
        if self.enemy_spawn.is_none() {
            self.enemy_spawn = centroid(snap.enemies_of(team).map(|e| e.p2()));
            self.own_spawn = centroid(snap.allies_of(team).map(|e| e.p2()));
            if let (Some(es), Some(os)) = (self.enemy_spawn, self.own_spawn) {
                self.start = now;
                let mid = (es + os) * 0.5;
                let dir = (mid - es).normalized_or_zero();
                for e in snap.enemies_of(team) {
                    let spawn = e.p2();
                    let mut stop = ((mid - spawn).dot(dir) - REF_STOP_SHORT_M).max(0.0);
                    let mut d = 0.0;
                    while d < stop {
                        if !water(spawn + dir * (d + REF_STEP_M)) {
                            stop = d;
                        }
                        d += REF_STEP_M;
                    }
                    self.presumed.push(Presumed { spawn, pos: spawn, dir, stop, held: false });
                }
            }
        }
        self.contacts.retain(|id, _| snap.get(*id).is_some_and(|s| s.alive));
        let mut fresh = 0;
        let mut seen = 0;
        for e in snap.enemies_of(team) {
            if !e.seen {
                if let Some(c) = self.contacts.get_mut(&e.id) {
                    c.seen_now = false;
                }
                continue;
            }
            if self.identified.insert(e.id) {
                self.retire_nearest(e.p2());
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

    fn retire_nearest(&mut self, at: Vector2) {
        let best = self.presumed.iter().enumerate()
            .min_by(|a, b| a.1.pos.distance_squared_to(at).total_cmp(&b.1.pos.distance_squared_to(at)))
            .map(|(i, _)| i);
        if let Some(i) = best {
            self.presumed.swap_remove(i);
        }
    }

    fn march(&mut self, now: f64, snap: &Snapshot, team: i32) {
        let lane = ((now - self.start) as f32 * ADVANCE_MPS).max(0.0);
        for r in self.presumed.iter_mut() {
            if !r.held {
                r.pos = r.spawn + r.dir * lane.min(r.stop);
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
