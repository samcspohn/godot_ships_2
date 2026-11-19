use godot::prelude::*;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;

use crate::nav::gun_matrix::GunMatrix;
use crate::nav::visibility::VisibilityGrid;

use super::belief::{certainty, radius, spread, Belief, FORGET_S};
use super::snapshot::Snapshot;

pub const FORECAST_S: f32 = 60.0;
const FORECAST_MIN_M: f32 = 300.0;
/// Just past an enemy's range is not shelter: it closes.
const SHIELD_EDGE_M: f32 = 2000.0;

/// Water cells are numbered row-major, so a disc covers one index run per grid row.
pub struct Layout {
    w: i32,
    h: i32,
    cell: f32,
    min_x: f32,
    min_z: f32,
    pre: Vec<u32>,
    pub words: usize,
    /// Per water cell its water neighbours, four straight then four diagonal.
    pub adj: Vec<[u32; 8]>,
}

impl Layout {
    pub fn new(v: &VisibilityGrid) -> Self {
        let mut pre = Vec::with_capacity(v.index.len() + 1);
        let mut n = 0u32;
        for &k in &v.index {
            pre.push(n);
            n += (k >= 0) as u32;
        }
        pre.push(n);
        Layout { w: v.w, h: v.h, cell: v.cell, min_x: v.min_x, min_z: v.min_z, pre, words: v.stride, adj: crate::nav::sail_table::adjacency(v) }
    }

    /// Index runs [a, b) of the water cells whose centres lie within `r` of `c`.
    pub fn spans(&self, c: Vector2, r: f32, mut f: impl FnMut(usize, usize)) {
        if r <= 0.0 {
            return;
        }
        let z0 = (((c.y - r - self.min_z) / self.cell - 0.5).ceil() as i32).max(0);
        let z1 = (((c.y + r - self.min_z) / self.cell - 0.5).floor() as i32).min(self.h - 1);
        for iz in z0..=z1 {
            let dz = self.min_z + (iz as f32 + 0.5) * self.cell - c.y;
            let half = (r * r - dz * dz).max(0.0).sqrt();
            let x0 = (((c.x - half - self.min_x) / self.cell - 0.5).ceil() as i32).max(0);
            let x1 = (((c.x + half - self.min_x) / self.cell - 0.5).floor() as i32).min(self.w - 1);
            if x0 > x1 {
                continue;
            }
            let row = (iz * self.w) as usize;
            let (a, b) = (self.pre[row + x0 as usize] as usize, self.pre[row + x1 as usize + 1] as usize);
            if a < b {
                f(a, b);
            }
        }
    }
}

fn or_span(dst: &mut [u64], a: usize, b: usize, src: impl Fn(usize) -> u64) {
    let (wa, wb) = (a / 64, (b - 1) / 64);
    for w in wa..=wb {
        let lo = if w == wa { a % 64 } else { 0 };
        let hi = if w == wb { (b - 1) % 64 + 1 } else { 64 };
        let m = if hi - lo == 64 { !0 } else { ((1u64 << (hi - lo)) - 1) << lo };
        dst[w] |= src(w) & m;
    }
}

pub fn has(bits: &[u64], k: usize) -> bool {
    bits[k / 64] >> (k % 64) & 1 != 0
}

/// One believed enemy position: now, or where a seen ship's course takes it.
pub struct Source {
    pub id: i64,
    pub at: Vector2,
    pub cell: usize,
    /// FORECAST_S ahead along its course.
    pub ahead: bool,
    range: f32,
    pub force: f32,
    matrix: Option<Arc<GunMatrix>>,
    /// Never seen: a spawn-march guess.
    pub presumed: bool,
    /// v4 guess_spread and certainty; 0 and 1 while seen.
    pub spread: f32,
    pub certainty: f32,
    pub seen: bool,
}

/// A team's picture of enemy sight and fire over the VisibilityGrid's water cells, from belief only.
#[derive(Default)]
pub struct TeamField {
    pub sources: Vec<Source>,
    /// Never-seen enemies where presumed and contacts lost past FORGET_S: they see and shoot, but are no one's target.
    pub ghosts: Vec<Source>,
    /// Some enemy's shells land here.
    pub shot: Vec<u64>,
    pub missing_rows: u32,
}

impl TeamField {
    pub(crate) fn build(&mut self, lay: &Layout, vis: &VisibilityGrid, belief: &Belief, snap: &Snapshot, now: f64,
            matrix: &mut dyn FnMut(i64) -> Option<Arc<GunMatrix>>) {
        self.sources.clear();
        self.ghosts.clear();
        let age = (now - belief.start) as f32;
        for (id, at, ahead) in belief.presumed_now_ahead(FORECAST_S) {
            let Some(s) = snap.get(id) else { continue };
            let m = matrix(id);
            let r = radius(age, s.max_speed);
            let fc = (ahead.distance_to(at) > FORECAST_MIN_M).then_some(ahead);
            for (p, later) in std::iter::once((at, false)).chain(fc.map(|f| (f, true))) {
                if let Some(cell) = vis.cell_of(p) {
                    self.ghosts.push(Source { id, at: p, cell, ahead: later, range: s.gun_range, force: s.force_spot, matrix: m.clone(),
                        presumed: true, spread: spread(r), certainty: certainty(r), seen: false });
                }
            }
        }
        for (&id, c) in &belief.contacts {
            if !c.seen_now && now - c.last_seen > FORGET_S {
                if let Some(s) = snap.get(id).filter(|s| s.alive) {
                    let at = belief.lost_at(c, s.max_speed, now);
                    let r = radius((now - c.last_seen) as f32, s.max_speed);
                    if let Some(cell) = vis.cell_of(at) {
                        self.ghosts.push(Source { id, at, cell, ahead: false, range: s.gun_range, force: s.force_spot, matrix: matrix(id),
                            presumed: false, spread: spread(r), certainty: certainty(r), seen: false });
                    }
                }
            }
        }
        self.missing_rows = 0;
        for (&id, c) in &belief.contacts {
            let Some(s) = snap.get(id).filter(|s| s.alive) else { continue };
            if now - c.last_seen > FORGET_S {
                continue;
            }
            let ahead = c.last_pos + Vector2::new(s.vel.x, s.vel.z) * FORECAST_S;
            let fc = (c.seen_now && ahead.distance_to(c.last_pos) > FORECAST_MIN_M).then_some(ahead);
            let m = matrix(id);
            let (sp, ce) = if c.seen_now { (0.0, 1.0) } else {
                let r = radius((now - c.last_seen) as f32, s.max_speed);
                (spread(r), certainty(r))
            };
            for (at, ahead) in std::iter::once((c.last_pos, false)).chain(fc.map(|f| (f, true))) {
                let Some(cell) = vis.cell_of(at) else { continue };
                self.sources.push(Source { id, at, cell, ahead, range: s.gun_range, force: s.force_spot, matrix: m.clone(),
                    presumed: false, spread: sp, certainty: ce, seen: c.seen_now });
            }
        }
        self.shot.clear();
        self.shot.resize(lay.words, 0);
        for (i, s) in self.sources.iter().chain(&self.ghosts).enumerate() {
            let row: Option<&[AtomicU64]> = s.matrix.as_ref().and_then(|m| m.row(s.cell));
            if row.is_none() && i < self.sources.len() {
                self.missing_rows += 1;
            }
            let shot = &mut self.shot;
            // A presumed enemy's guns are unknown: it hits what it sees.
            let los = &vis.bits[s.cell * vis.stride..(s.cell + 1) * vis.stride];
            let ghost = i >= self.sources.len();
            lay.spans(s.at, s.range, |a, b| match row {
                Some(r) => or_span(shot, a, b, |w| r[w].load(Relaxed)),
                None if ghost => or_span(shot, a, b, |w| los[w]),
                None => or_span(shot, a, b, |_| !0),
            });
        }
    }

    /// Seen or not, no enemy's shells land here and none sits just out of range of it.
    pub fn shielded(&self, vis: &VisibilityGrid, k: usize) -> bool {
        let c = vis.centres[k];
        !has(&self.shot, k) && self.sources.iter().chain(&self.ghosts).all(|s| { let d = s.at.distance_to(c); d < s.range || d >= s.range + SHIELD_EDGE_M })
    }

    /// Cells some enemy would detect a ship of detection radius `radius` in: its eyes need line of sight, radar and hydro do not.
    pub fn seen(&self, lay: &Layout, vis: &VisibilityGrid, radius: f32) -> Vec<u64> {
        self.seen_by(lay, vis, radius, |_| true)
    }

    pub fn seen_by(&self, lay: &Layout, vis: &VisibilityGrid, radius: f32, by: impl Fn(&Source) -> bool) -> Vec<u64> {
        let mut out = vec![0u64; lay.words];
        for s in self.sources.iter().chain(&self.ghosts).filter(|s| by(s)) {
            let los = &vis.bits[s.cell * vis.stride..(s.cell + 1) * vis.stride];
            lay.spans(s.at, radius, |a, b| or_span(&mut out, a, b, |w| los[w]));
            lay.spans(s.at, s.force, |a, b| or_span(&mut out, a, b, |_| !0));
        }
        out
    }

    /// seen_at counting ghosts too.
    pub fn seen_at_all(&self, vis: &VisibilityGrid, k: usize, radius: f32) -> bool {
        let c = vis.centres[k];
        self.seen_at(vis, k, radius) || self.ghosts.iter().any(|s| s.at.distance_to(c) <= radius && vis.visible_idx(s.cell, k))
    }

    /// One cell of `seen`.
    pub fn seen_at(&self, vis: &VisibilityGrid, k: usize, radius: f32) -> bool {
        let c = vis.centres[k];
        self.sources.iter().any(|s| { let d = s.at.distance_to(c); d <= s.force || d <= radius && vis.visible_idx(s.cell, k) })
    }

}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_cover_disc_skipping_land() {
        // 4x3 grid, 100 m cells, land at (1,1).
        let index = [0, 1, 2, 3, 4, -1, 5, 6, 7, 8, 9, 10];
        let mut pre = Vec::new();
        let mut n = 0;
        for &k in &index {
            pre.push(n);
            n += (k >= 0) as u32;
        }
        pre.push(n);
        let lay = Layout { w: 4, h: 3, cell: 100.0, min_x: 0.0, min_z: 0.0, pre, words: 1, adj: Vec::new() };
        let mut got = Vec::new();
        lay.spans(Vector2::new(150.0, 150.0), 110.0, |a, b| got.extend(a..b));
        assert_eq!(got, vec![1, 4, 5, 8]);
    }

    #[test]
    fn or_span_masks_partial_words() {
        let mut d = vec![0u64; 3];
        or_span(&mut d, 60, 130, |_| !0);
        assert_eq!(d[0], 0xF << 60);
        assert_eq!(d[1], !0);
        assert_eq!(d[2], 0b11);
        let mut e = vec![0u64; 1];
        or_span(&mut e, 3, 4, |_| !0);
        assert_eq!(e[0], 1 << 3);
    }
}
