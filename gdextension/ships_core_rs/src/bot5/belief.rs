use godot::prelude::*;
use std::collections::{HashMap, VecDeque};

use super::snapshot::Snapshot;

const SAMPLE_S: f64 = 1.0;
const HISTORY_S: f64 = 20.0;
pub const FORGET_S: f64 = 90.0;

pub struct Contact {
    hist: VecDeque<(f64, Vector2)>,
    pub last_seen: f64,
    pub last_pos: Vector2,
    pub seen_now: bool,
}

/// Team knowledge built only from what the team has spotted.
#[derive(Default)]
pub struct Belief {
    pub contacts: HashMap<i64, Contact>,
    pub enemy_spawn: Option<Vector2>,
    pub seen_count: usize,
}

impl Belief {
    /// Returns how many enemies became spotted this update.
    pub fn update(&mut self, now: f64, snap: &Snapshot, team: i32) -> usize {
        if self.enemy_spawn.is_none() {
            let (mut sum, mut n) = (Vector2::ZERO, 0.0);
            for e in snap.enemies_of(team) {
                sum += e.p2();
                n += 1.0;
            }
            if n > 0.0 {
                self.enemy_spawn = Some(sum / n);
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
            let c = self.contacts.entry(e.id).or_insert_with(|| Contact {
                hist: VecDeque::new(),
                last_seen: now,
                last_pos: e.p2(),
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
            if c.hist.back().is_none_or(|&(t, _)| now - t >= SAMPLE_S) {
                c.hist.push_back((now, e.p2()));
            }
            while c.hist.front().is_some_and(|&(t, _)| now - t > HISTORY_S) {
                c.hist.pop_front();
            }
        }
        self.seen_count = seen;
        fresh
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
