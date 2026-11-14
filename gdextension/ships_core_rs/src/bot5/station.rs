use godot::prelude::*;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

use crate::nav::visibility::VisibilityGrid;
use crate::projectile::manager::point_store::{PtTable, Store};

use super::field::{has, Layout};
use super::flank::SeamGeom;
use super::snapshot::{rot_y, ShipState};

/// An incomplete curve is re-read from its table at most this often, and only once the table has grown.
const CURVE_RETRY_S: f64 = 5.0;
/// Holding this long is what a station is worth; transit to it earns nothing.
const HORIZON_S: f32 = 90.0;
const KEEP_MARGIN: f32 = 0.1;
const MOVE_ON_M: f32 = 1500.0;
const VERIFY: usize = 6;
const SEAM_HALF_M: f32 = 2500.0;
const COARSE: i32 = 2;
const REFINE: usize = 8;
/// Curves are resampled on this range step, so a lookup is an index.
const LUT_M: f32 = 100.0;
/// Curve rebuilds per hive pass while the point-table worker is still filling tables.
pub const REBUILDS_PER_PASS: usize = 4;

/// A point table flattened at damage 1, no fire, no saturation: per shot value by (range, aspect).
pub struct Curve {
    ranges: Vec<f32>,
    aspects: Vec<f32>,
    v: Vec<f32>,
    mean: Vec<f32>,
    /// Per LUT_M step: per aspect value, and the aspect mean.
    lut: Vec<f32>,
    lut_mean: Vec<f32>,
    done: bool,
    at: f64,
    buckets: usize,
}

impl Curve {
    fn build(t: &PtTable, now: f64) -> Curve {
        let (nr, na) = (t.ranges.len(), t.aspects.len());
        let mut v = vec![0.0; nr * na];
        // At a bucket's own node `best` blends that bucket alone: its best role's unsaturated value per shot.
        for (&key, slots) in &t.slots {
            if key < v.len() {
                v[key] = slots.iter().filter(|s| s.point != u32::MAX).map(|s| s.v[0]).fold(0.0, f32::max);
            }
        }
        let done = t.slots.len() >= nr * na;
        let mean = (0..nr).map(|ri| v[ri * na..(ri + 1) * na].iter().sum::<f32>() / na.max(1) as f32).collect();
        let mut c = Curve { ranges: t.ranges.iter().map(|&r| r as f32).collect(), aspects: t.aspects.iter().map(|&a| a as f32).collect(),
            v, mean, lut: Vec::new(), lut_mean: Vec::new(), done, at: now, buckets: t.slots.len() };
        c.resample();
        c
    }

    fn resample(&mut self) {
        let n = (self.ranges.last().copied().unwrap_or(0.0) / LUT_M) as usize + 2;
        let na = self.aspects.len();
        self.lut = (0..n).flat_map(|i| (0..na).map(move |ai| (i as f32 * LUT_M, ai))).map(|(r, ai)| self.exact_at(r, ai)).collect();
        self.lut_mean = (0..n).map(|i| self.exact_mean(i as f32 * LUT_M)).collect();
    }

    fn exact_at(&self, range: f32, ai: usize) -> f32 {
        let (na, nr) = (self.aspects.len(), self.ranges.len());
        let (ri, rf) = Self::frac(&self.ranges, range);
        self.v[ri * na + ai] * (1.0 - rf) + self.v[(ri + 1).min(nr - 1) * na + ai] * rf
    }

    fn exact_mean(&self, range: f32) -> f32 {
        let (ri, rf) = Self::frac(&self.ranges, range);
        let n = self.mean.len();
        self.mean[ri] * (1.0 - rf) + self.mean[(ri + 1).min(n - 1)] * rf
    }

    fn step(&self, range: f32) -> usize {
        ((range / LUT_M).round().max(0.0) as usize).min(self.lut_mean.len() - 1)
    }

    fn frac(xs: &[f32], x: f32) -> (usize, f32) {
        if xs.len() < 2 || x <= xs[0] {
            return (0, 0.0);
        }
        if x >= xs[xs.len() - 1] {
            return (xs.len() - 1, 0.0);
        }
        let i = xs.partition_point(|&e| e < x) - 1;
        (i, (x - xs[i]) / (xs[i + 1] - xs[i]))
    }

    pub fn at(&self, range: f32, aspect: f32) -> f32 {
        let na = self.aspects.len();
        let row = &self.lut[self.step(range) * na..][..na];
        let (ai, af) = Self::frac(&self.aspects, aspect);
        row[ai] * (1.0 - af) + row[(ai + 1).min(na - 1)] * af
    }

    /// Averaged over aspect: the shooter does not know how we will lie.
    pub fn mean_at(&self, range: f32) -> f32 {
        self.lut_mean[self.step(range)]
    }
}

/// Curves by table key: pairs sharing a table share one curve.
#[derive(Default)]
pub struct Curves {
    map: HashMap<String, Curve>,
}

impl Curves {
    /// True when it rebuilt the curve.
    pub(crate) fn refresh(&mut self, store: &Store, key: &str, now: f64) -> bool {
        if self.map.get(key).is_some_and(|c| c.done || now - c.at < CURVE_RETRY_S) {
            return false;
        }
        let Some(t) = store.read().ok().and_then(|s| s.get(key).cloned()) else { return false };
        let Ok(t) = t.read() else { return false };
        if t.ranges.is_empty() || t.aspects.is_empty() {
            return false;
        }
        let all = t.ranges.len() * t.aspects.len();
        if let Some(c) = self.map.get_mut(key) {
            if t.slots.len() < all && t.slots.len() < c.buckets + (all / 10).max(1) {
                c.at = now;
                return false;
            }
        }
        self.map.insert(key.to_string(), Curve::build(&t, now));
        true
    }

    pub fn get(&self, key: &str) -> Option<&Curve> {
        self.map.get(key)
    }
}

/// Damage per minute from a shooter's AP/HE curves: the better shell at each range.
pub struct Fire<'a> {
    curves: [Option<&'a Curve>; 2],
    pub ship: &'a ShipState,
    /// Per LUT_M step, aspect mean, already in damage per minute.
    mean: Vec<f32>,
}

impl<'a> Fire<'a> {
    pub fn new(curves: [Option<&'a Curve>; 2], ship: &'a ShipState) -> Self {
        let n = curves.iter().flatten().map(|c| c.lut_mean.len()).max().unwrap_or(1);
        let mut f = Fire { curves, ship, mean: Vec::new() };
        let pm = f.per_min();
        f.mean = (0..n).map(|i| {
            let r = i as f32 * LUT_M;
            (0..2).filter_map(|a| f.curves[a].map(|c| c.mean_at(r) * ship.damage[a])).fold(0.0, f32::max) * pm
        }).collect();
        f
    }

    fn per_min(&self) -> f32 {
        if self.ship.reload <= 0.0 { 0.0 } else { self.ship.barrels * 60.0 / self.ship.reload }
    }

    fn mean_at(&self, d: f32) -> f32 {
        self.mean[((d / LUT_M).round().max(0.0) as usize).min(self.mean.len() - 1)]
    }

    fn at(&self, d: f32, aspect: f32) -> f32 {
        let v = (0..2).filter_map(|a| self.curves[a].map(|c| c.at(d, aspect) * self.ship.damage[a])).fold(0.0, f32::max);
        v * self.per_min()
    }
}

pub struct Threat<'a> {
    pub at: Vector2,
    pub range: f32,
    pub row: Option<&'a [AtomicU64]>,
    pub fire: Fire<'a>,
}

pub struct Target<'a> {
    pub ship: &'a ShipState,
    pub at: Vector2,
    pub fire: Fire<'a>,
}

pub struct Req {
    pub anchor: Vector2,
    /// Set when the anchor is this target's believed position.
    pub target: Option<i64>,
    pub lo: f32,
    pub hi: f32,
    pub keep: Option<Vector2>,
    /// Arrived or blocked: the next station lies at least MOVE_ON_M from here.
    pub avoid: Option<Vector2>,
    pub seam: Option<SeamGeom>,
}

pub struct Scan<'a> {
    pub lay: &'a Layout,
    pub vis: &'a VisibilityGrid,
    /// Cells some enemy sees us in while we fire.
    pub seen: &'a [u64],
    pub threats: Vec<Threat<'a>>,
    pub target: Option<Target<'a>>,
    /// Our gun matrix row per cell, for the shot at the target's cell.
    pub own: &'a dyn Fn(usize) -> Option<bool>,
    pub my: Vector2,
    pub speed: f32,
    pub clearance: f32,
    pub risk: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct Found {
    pub station: Vector2,
    pub shot: bool,
    pub value: f32,
    pub exposure: f32,
    pub candidates: usize,
}

struct Cand {
    k: usize,
    p: Vector2,
    value: f32,
    exposure: f32,
    score: f32,
}

impl Scan<'_> {
    fn exposure(&self, k: usize, p: Vector2) -> f32 {
        if !has(self.seen, k) {
            return 0.0;
        }
        self.threats.iter().filter_map(|t| {
            let d = t.at.distance_to(p);
            let hit = d <= t.range && t.row.is_none_or(|r| r[k / 64].load(Relaxed) >> (k % 64) & 1 != 0);
            hit.then(|| t.fire.mean_at(d))
        }).sum()
    }

    fn value(&self, k: usize, p: Vector2) -> Option<f32> {
        let Some(t) = &self.target else { return Some(1.0) };
        if (self.own)(k) == Some(false) {
            return None;
        }
        let d = p.distance_to(t.at);
        if !t.ship.seen {
            return Some(t.fire.mean_at(d));
        }
        let rel = rot_y(Vector3::new(p.x - t.at.x, 0.0, p.y - t.at.y), -t.ship.rot);
        Some(t.fire.at(d, rel.x.abs().atan2(-rel.z).to_degrees()))
    }

    /// Best cell in the band by damage dealt less risk x damage taken, over HORIZON_S with the transit earning nothing;
    /// the top few checked by `exact` (navigable, exact shot) when there is a target.
    pub fn run(&self, req: &Req, exact: &mut dyn FnMut(Vector2) -> bool) -> Option<Found> {
        let (lo2, hi) = (req.lo * req.lo, req.hi);
        let v = self.vis;
        let grid = |p: Vector2| (((p.x - v.min_x) / v.cell) as i32, ((p.y - v.min_z) / v.cell) as i32);
        let eval = |k: usize| -> Option<Cand> {
            let p = v.centres[k];
            if p.distance_squared_to(req.anchor) < lo2 || p.distance_squared_to(req.anchor) > hi * hi || v.sdf_c[k] < self.clearance
                || req.avoid.is_some_and(|q| q.distance_to(p) < MOVE_ON_M)
                || req.seam.is_some_and(|s| s.lateral(p).abs() > SEAM_HALF_M) {
                return None;
            }
            let value = self.value(k, p)?;
            Some(Cand { k, p, value, exposure: self.exposure(k, p), score: 0.0 })
        };
        // Every other cell each way, then the full grid around the best few: a quarter of the cells for the same pick.
        let mut cands: Vec<Cand> = Vec::new();
        self.lay.spans(req.anchor, hi, |a, b| for k in a..b {
            let (ix, iz) = grid(v.centres[k]);
            if ix % COARSE == 0 && iz % COARSE == 0 {
                cands.extend(eval(k));
            }
        });
        let net = |c: &Cand| c.value - self.risk * c.exposure;
        cands.sort_unstable_by(|a, b| net(b).total_cmp(&net(a)));
        let mut have: std::collections::HashSet<usize> = cands.iter().map(|c| c.k).collect();
        let seeds: Vec<(i32, i32)> = cands.iter().take(REFINE).map(|c| grid(c.p)).collect();
        let keep_k = req.keep.and_then(|q| v.cell_of(q));
        let near = seeds.iter().flat_map(|&(x, z)| (-1..=1).flat_map(move |dz| (-1..=1).map(move |dx| (x + dx, z + dz))))
            .filter(|&(x, z)| x >= 0 && z >= 0 && x < v.w && z < v.h)
            .filter_map(|(x, z)| usize::try_from(v.index[(z * v.w + x) as usize]).ok())
            .chain(keep_k);
        for k in near {
            if have.insert(k) {
                cands.extend(eval(k));
            }
        }
        let n = cands.len();
        let vmax = cands.iter().map(|c| c.value).fold(0.0, f32::max);
        for c in &mut cands {
            c.score = c.value - self.risk * c.exposure;
        }
        // Transit only lowers a score: route lengths are needed only while the next net value can still beat the kept ones.
        cands.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));
        let keep_p = req.keep.and_then(|q| v.cell_of(q)).map(|k| v.centres[k]);
        let mut routed: Vec<Cand> = Vec::new();
        for mut c in cands {
            let worst_kept = (routed.len() >= VERIFY).then(|| routed[VERIFY - 1].score);
            if worst_kept.is_some_and(|w| c.score <= w) && keep_p != Some(c.p) {
                continue;
            }
            let t = v.sail_route(self.my, c.p).unwrap_or_else(|| self.my.distance_to(c.p)) / self.speed.max(1.0);
            c.score -= vmax * t / HORIZON_S;
            let at = routed.partition_point(|r| r.score >= c.score);
            routed.insert(at, c);
        }
        let cands = routed;
        let found = |c: &Cand, shot: bool| Found { station: c.p, shot, value: c.value, exposure: c.exposure, candidates: n };
        if self.target.is_none() {
            return cands.first().map(|c| found(c, false));
        }
        let mut best: Option<(usize, Found)> = None;
        for (i, c) in cands.iter().take(VERIFY).enumerate() {
            if exact(c.p) {
                best = Some((i, found(c, true)));
                break;
            }
        }
        let Some((i, b)) = best else { return cands.first().map(|c| found(c, false)) };
        if let Some(q) = keep_p {
            if let Some(c) = cands.iter().find(|c| c.p == q) {
                if c.score >= cands[i].score - KEEP_MARGIN * cands[i].score.abs() && exact(c.p) {
                    return Some(found(c, true));
                }
            }
        }
        Some(b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curve_blends_range_and_aspect() {
        let mut c = Curve { ranges: vec![1000.0, 2000.0], aspects: vec![0.0, 90.0], v: vec![1.0, 3.0, 5.0, 7.0],
            mean: vec![2.0, 6.0], lut: Vec::new(), lut_mean: Vec::new(), done: true, at: 0.0, buckets: 4 };
        c.resample();
        assert_eq!(c.at(1500.0, 45.0), 4.0);
        assert_eq!(c.at(500.0, 0.0), 1.0);
        assert_eq!(c.at(9000.0, 90.0), 7.0);
        assert_eq!(c.mean_at(1500.0), 4.0);
    }
}
