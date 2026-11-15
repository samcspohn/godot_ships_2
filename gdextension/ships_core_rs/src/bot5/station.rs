use godot::prelude::*;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;

use crate::nav::visibility::VisibilityGrid;
use crate::projectile::manager::point_store::{PtTable, Store};

use super::features::Features;
use super::field::{has, Layout};
use super::flank::SeamGeom;
use super::hive::wrap;
use super::snapshot::{rot_y, ShipState};

/// An incomplete curve is re-read from its table at most this often, and only once the table has grown.
const CURVE_RETRY_S: f64 = 5.0;
/// A station is scored over the sail there plus this long held.
const DWELL_S: f32 = 120.0;
/// Targets after the best count this much each: a station with options outlasts one with a single target.
const OPTION_W: [f32; 3] = [0.5, 0.25, 0.125];
/// Enemies in gun range a station needs, fewer only when fewer are in view.
const MIN_IN_RANGE: usize = 2;
/// Berths searched on an island's side away from the enemy, each way.
const LEE_HALF: f32 = std::f32::consts::FRAC_PI_3;
/// Fallback water around a station that is also covered makes it defensible.
const DEF_R: f32 = 900.0;
const DEF_W: f32 = 0.25;
/// A goal farther than this by sail is approached through a checkpoint: a fightable station on the way.
const CHECK_MAX_S: f32 = 90.0;
/// A checkpoint is at least this much nearer the goal than we are.
const CHECK_PROGRESS_M: f32 = 1000.0;
/// Near candidates scored in full as checkpoints, beside the top REFINE.
const CHECK_REFINE: usize = 8;
/// Candidates scored in full (both moments, dark, defensibility) after a now-only pass over all.
const REFINE: usize = 24;
const KEEP_MARGIN: f32 = 0.1;
const MOVE_ON_M: f32 = 1500.0;
const VERIFY: usize = 6;
const SEAM_HALF_M: f32 = 2500.0;
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

    pub fn mean_at(&self, d: f32) -> f32 {
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

impl Target<'_> {
    pub fn value_at(&self, p: Vector2) -> f32 {
        value_from(&self.fire, self.at, p)
    }
}

/// Per minute from `p` on the ship at `at`: at its aspect from there when seen, else its aspect mean.
fn value_from(fire: &Fire, at: Vector2, p: Vector2) -> f32 {
    let d = p.distance_to(at);
    if !fire.ship.seen {
        return fire.mean_at(d);
    }
    let rel = rot_y(Vector3::new(p.x - at.x, 0.0, p.y - at.y), -fire.ship.rot);
    fire.at(d, rel.x.abs().atan2(-rel.z).to_degrees())
}

/// Per minute in cell k: every threat whose shells land there, while some enemy sees the cell.
pub fn exposure_at(threats: &[Threat], seen: bool, k: usize, p: Vector2) -> f32 {
    if !seen {
        return 0.0;
    }
    threats.iter().filter_map(|t| {
        let d = t.at.distance_to(p);
        let hit = d <= t.range && t.row.is_none_or(|r| r[k / 64].load(Relaxed) >> (k % 64) & 1 != 0);
        hit.then(|| t.fire.mean_at(d))
    }).sum()
}

pub struct Req {
    pub anchor: Vector2,
    /// The hive's target: a station must have it in gun range with a shot.
    pub target: Option<i64>,
    pub lo: f32,
    pub hi: f32,
    pub keep: Option<Vector2>,
    /// Arrived or blocked: the next station lies at least MOVE_ON_M from here.
    pub avoid: Option<Vector2>,
    pub seam: Option<SeamGeom>,
    /// Score only this station, no search.
    pub only: Option<Vector2>,
}

/// A believed enemy position at one moment.
pub struct Pos {
    pub at: Vector2,
    pub cell: usize,
    /// Our gun-matrix column at its cell; None while unbuilt.
    pub col: Option<Arc<[u64]>>,
}

pub struct Foe<'a> {
    pub fire: Fire<'a>,
    pub hp: f32,
    pub k_out: f32,
    pub primary: bool,
    /// Allies' fire on it (HP share per minute) that waits on us lighting it: 0 when another ally lights it.
    pub spot: f32,
    /// Now, and FORECAST_S ahead.
    pub at: [Pos; 2],
}

pub struct Scan<'a> {
    pub lay: &'a Layout,
    pub vis: &'a VisibilityGrid,
    pub feats: &'a Features,
    pub foes: Vec<Foe<'a>>,
    /// Now, and ahead.
    pub threats: [Vec<Threat<'a>>; 2],
    /// [moment][firing, dark]: cells some enemy sees us in.
    pub seen: [[Vec<u64>; 2]; 2],
    /// Team field: some enemy's shells land here.
    pub shot: &'a [u64],
    pub my: Vector2,
    pub speed: f32,
    pub clearance: f32,
    pub risk: f32,
    pub reach: f32,
    pub my_hp: f32,
    pub k_in: f32,
    /// May hold fire to spot unseen: destroyers, and cruisers that hide well inside their gun range.
    pub dark_ok: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct Found {
    pub station: Vector2,
    pub shot: bool,
    pub value: f32,
    pub exposure: f32,
    /// Worse of now and ahead, HP share per minute, before transit.
    pub net: f32,
    pub dark: bool,
    /// Nothing passed net >= 0: the best of the rest.
    pub negative: bool,
    pub candidates: usize,
    /// On the way to a far station: (station, shot checked, net, dark).
    pub checkpoint: Option<(Vector2, bool, f32, bool)>,
}

#[derive(Clone, Copy, Debug)]
struct Eval {
    value: f32,
    spot: f32,
    exposure: f32,
    net: f32,
    dark: bool,
}

#[derive(Clone, Copy)]
struct Cand {
    k: usize,
    p: Vector2,
    e: Eval,
    score: f32,
    transit_s: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct DiagCell {
    pub p: Vector2,
    pub range: f32,
    pub value: f32,
    pub exposure: f32,
    pub transit_s: f32,
    pub score: f32,
}

/// SHIPS_BOT5_SCAN_TRACE: what the scan looked at, its pick, and the best zero-exposure station against it.
#[derive(Default, Debug)]
pub struct Diag {
    /// Candidates from berths, gaps, lattice.
    pub kinds: [usize; 3],
    pub evaluated: usize,
    pub passing: usize,
    pub hidden: usize,
    pub shielded: usize,
    pub us: u64,
    pub pick: Option<(DiagCell, bool)>,
    pub cover: Option<(DiagCell, &'static str)>,
}

impl Scan<'_> {
    /// Gun value over our targets at moment m (best full, the rest as options), the spot value, and the gate counts.
    fn offence(&self, k: usize, p: Vector2, m: usize, req: &Req, dark: bool) -> (f32, f32, usize, usize, bool) {
        let (mut primary, mut rest, mut spot, mut n_range, mut n_band) = (None, [0.0f32; 4], 0.0, 0, 0);
        for f in &self.foes {
            let pos = &f.at[m];
            let d = p.distance_to(pos.at);
            if f.spot > 0.0 && d <= f.fire.ship.conceal && self.vis.visible_idx(k, pos.cell) {
                spot += f.spot;
            }
            if dark || d > self.reach || pos.col.as_ref().is_some_and(|c| !has(c, k)) {
                continue;
            }
            n_range += 1;
            n_band += (d >= req.lo && d <= req.hi) as usize;
            let v = value_from(&f.fire, pos.at, p) * f.k_out / f.hp;
            if f.primary {
                primary = Some(v);
            } else if v > rest[3] {
                rest[3] = v;
                rest.sort_unstable_by(|a, b| b.total_cmp(a));
            }
        }
        let value = match primary {
            Some(v) => v + rest.iter().zip(OPTION_W).map(|(r, w)| r * w).sum::<f32>(),
            None => rest[0] + rest[1..].iter().zip(OPTION_W).map(|(r, w)| r * w).sum::<f32>(),
        };
        (value, spot, n_range, n_band, req.target.is_none() || primary.is_some())
    }

    /// Best of firing and staying dark at cell k: each scored at the worse of now and ahead. None when neither passes its gate.
    /// `full` false: now only, no defensibility; a cheap estimate for ranking.
    fn eval(&self, k: usize, req: &Req, need: usize, full: bool) -> Option<Eval> {
        let p = self.vis.centres[k];
        if self.foes.is_empty() {
            // Nothing believed in reach: approach the anchor's band, out of the field's sight and fire.
            let d = p.distance_to(req.anchor);
            let x = if has(&self.seen[0][0], k) && has(self.shot, k) { 1.0 } else { 0.0 };
            return (d >= req.lo && d <= req.hi).then_some(Eval { value: 0.0, spot: 0.0, exposure: x, net: -x, dark: false });
        }
        let mut best: Option<Eval> = None;
        for dark in [false, true] {
            if dark && !self.dark_ok {
                continue;
            }
            let mut e = Eval { value: 0.0, spot: 0.0, exposure: 0.0, net: f32::INFINITY, dark };
            for m in 0..1 + full as usize {
                let (value, spot, n_range, n_band, primary) = self.offence(k, p, m, req, dark);
                if m == 0 && !(if dark { spot > 0.0 } else { primary && n_range >= need && n_band >= 1 }) {
                    e.net = f32::NEG_INFINITY;
                    break;
                }
                let x = exposure_at(&self.threats[m], has(&self.seen[m][dark as usize], k), k, p) * self.k_in / self.my_hp;
                if m == 0 {
                    (e.value, e.spot, e.exposure) = (value, spot, x);
                }
                e.net = e.net.min(value + spot - self.risk * x);
            }
            if e.net.is_finite() {
                if full {
                    e.net += DEF_W * self.defensible(p, dark) * (e.value + e.spot);
                }
                if best.is_none_or(|b| e.net > b.net) {
                    best = Some(e);
                }
            }
        }
        best
    }

    /// Share of the water within DEF_R that no enemy sees, or no enemy's shells reach.
    fn defensible(&self, p: Vector2, dark: bool) -> f32 {
        let seen = &self.seen[0][dark as usize];
        let (mut n, mut ok) = (0u32, 0u32);
        self.lay.spans(p, DEF_R, |a, b| for j in a..b {
            n += 1;
            ok += (!has(seen, j) || !has(self.shot, j)) as u32;
        });
        if n == 0 { 0.0 } else { ok as f32 / n as f32 }
    }

    fn usable(&self, k: usize, req: &Req) -> bool {
        let p = self.vis.centres[k];
        let near = |f: &Foe| {
            let d = p.distance_to(f.at[0].at);
            d >= req.lo && d <= req.hi || self.dark_ok && f.spot > 0.0 && d <= f.fire.ship.conceal
        };
        let placed = if self.foes.is_empty() { (req.lo..=req.hi).contains(&p.distance_to(req.anchor)) } else { self.foes.iter().any(near) };
        placed && self.vis.sdf_c[k] >= self.clearance
            && !req.avoid.is_some_and(|q| q.distance_to(p) < MOVE_ON_M)
            && !req.seam.is_some_and(|s| s.lateral(p).abs() > SEAM_HALF_M)
    }

    /// Lee berths of islands in reach of the anchor, gaps in reach, our own cell and the kept station; kind 0 berth, 1 gap, 2 other.
    fn gather(&self, req: &Req) -> Vec<(usize, u8)> {
        let v = self.vis;
        let now = &self.threats[0];
        let centre = if now.is_empty() { req.anchor } else { now.iter().map(|t| t.at).sum::<Vector2>() / now.len() as f32 };
        let mut out: Vec<(usize, u8)> = Vec::new();
        for is in &self.feats.islands {
            if is.centre.distance_to(req.anchor) > self.reach + is.radius {
                continue;
            }
            let away = is.centre - centre;
            let lee = away.x.atan2(away.y);
            let all = away.length() < 1.0;
            out.extend(is.berths.iter().filter(|b| all || wrap(b.0 - lee).abs() <= LEE_HALF).map(|b| (b.1 as usize, 0)));
        }
        out.extend(self.feats.gaps.iter().filter(|&&k| v.centres[k as usize].distance_to(req.anchor) <= self.reach).map(|&k| (k as usize, 1)));
        out.extend(v.cell_of(self.my).into_iter().chain(req.keep.and_then(|q| v.cell_of(q))).map(|k| (k, 2)));
        out.retain(|&(k, _)| self.usable(k, req));
        out.sort_unstable_by_key(|c| c.0);
        out.dedup_by_key(|c| c.0);
        out
    }

    fn rank(&self, req: &Req, cells: &[(usize, u8)], here: f32, need: usize, d: &mut Diag) -> Vec<Cand> {
        let score = |p: Vector2, net: f32, sail: bool| {
            let m = if sail { self.vis.sail_route(self.my, p) } else { None };
            let t = m.unwrap_or_else(|| self.my.distance_to(p)) / self.speed.max(1.0);
            // The sail there earns about the mean of where we are and where we go.
            ((t * 0.5 * (here + net) + DWELL_S * net) / (t + DWELL_S), t)
        };
        let mut quick: Vec<Cand> = Vec::with_capacity(cells.len());
        for &(k, kind) in cells {
            d.kinds[kind.min(2) as usize] += 1;
            d.evaluated += 1;
            let Some(e) = self.eval(k, req, need, false) else { continue };
            let p = self.vis.centres[k];
            let (s, t) = score(p, e.net, false);
            quick.push(Cand { k, p, e, score: s, transit_s: t });
        }
        let keep = req.keep.and_then(|q| self.vis.cell_of(q));
        quick.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));
        let mut near: Vec<(usize, f32)> = quick.iter().enumerate().skip(REFINE)
            .filter(|(_, c)| c.transit_s <= CHECK_MAX_S && c.e.net >= 0.0).map(|(i, c)| (i, c.e.net)).collect();
        near.sort_unstable_by(|a, b| b.1.total_cmp(&a.1));
        near.truncate(CHECK_REFINE);
        let mut out: Vec<Cand> = Vec::with_capacity(REFINE + CHECK_REFINE + 1);
        for (i, c) in quick.iter().enumerate() {
            if i >= REFINE && Some(c.k) != keep && !near.iter().any(|n| n.0 == i) {
                continue;
            }
            let Some(e) = self.eval(c.k, req, need, true) else { continue };
            let (s, t) = score(c.p, e.net, true);
            out.push(Cand { k: c.k, p: c.p, e, score: s, transit_s: t });
        }
        out
    }

    /// Station by average net rate (HP share per minute) over the sail there and DWELL_S held; the top few
    /// checked by `exact` (navigable, exact shot) when firing on a target.
    pub fn run(&self, req: &Req, exact: &mut dyn FnMut(Vector2) -> bool, diag: Option<&mut Diag>) -> Option<Found> {
        let t0 = std::time::Instant::now();
        let v = self.vis;
        let found = |c: &Cand, shot: bool, negative: bool, n: usize| Found { station: c.p, shot, value: c.e.value, exposure: c.e.exposure,
            net: c.e.net, dark: c.e.dark, negative, candidates: n, checkpoint: None };
        if let Some(q) = req.only {
            let k = v.cell_of(q)?;
            let e = self.eval(k, req, MIN_IN_RANGE.min(self.foes.len()), true).or_else(|| self.eval(k, req, 1, true))?;
            let shot = e.dark || req.target.is_none() || exact(q);
            return shot.then(|| found(&Cand { k, p: q, e, score: e.net, transit_s: 0.0 }, !e.dark && req.target.is_some(), e.net < 0.0, 1));
        }
        let mut d = Diag::default();
        let here = v.cell_of(self.my).and_then(|k| self.eval(k, req, 1, true)).map_or_else(
            || -self.risk * v.cell_of(self.my).map_or(0.0, |k| exposure_at(&self.threats[0], has(&self.seen[0][0], k), k, self.my)) * self.k_in / self.my_hp,
            |e| e.net);
        let cells = self.gather(req);
        let lattice = || -> Vec<(usize, u8)> { self.feats.lattice.iter().map(|&k| (k as usize, 2u8)).filter(|&(k, _)| self.usable(k, req)).collect() };
        // Fewer targets in range only when no station has the full count.
        let mut cands = Vec::new();
        for need in [MIN_IN_RANGE.min(self.foes.len()), 1] {
            cands = self.rank(req, &cells, here, need, &mut d);
            if !cands.iter().any(|c| c.e.net >= 0.0) {
                cands.extend(self.rank(req, &lattice(), here, need, &mut d));
            }
            if !cands.is_empty() {
                break;
            }
        }
        let negative = !cands.iter().any(|c| c.e.net >= 0.0);
        if !negative {
            cands.retain(|c| c.e.net >= 0.0);
        }
        cands.sort_unstable_by(|a, b| b.score.total_cmp(&a.score).then(a.transit_s.total_cmp(&b.transit_s)));
        let n = cands.len();
        let needs_shot = |c: &Cand| !c.e.dark && req.target.is_some();
        let keep_p = req.keep.and_then(|q| v.cell_of(q)).map(|k| v.centres[k]);
        let chosen: Option<(usize, bool)> = match cands.iter().take(VERIFY).position(|c| !needs_shot(c) || exact(c.p)) {
            _ if cands.is_empty() => None,
            None => Some((0, false)),
            Some(i) => {
                let floor = cands[i].score - KEEP_MARGIN * cands[i].score.abs();
                let kept = keep_p.and_then(|q| cands.iter().position(|c| c.p == q))
                    .filter(|&j| j != i && cands[j].score >= floor && (!needs_shot(&cands[j]) || exact(cands[j].p)));
                let j = kept.unwrap_or(i);
                Some((j, needs_shot(&cands[j])))
            }
        };
        if let Some(out) = diag {
            d.passing = cands.iter().filter(|c| c.e.net >= 0.0).count();
            let cell = |c: &Cand| DiagCell { p: c.p, range: c.p.distance_to(req.anchor), value: c.e.value, exposure: c.e.exposure,
                transit_s: c.transit_s, score: c.score };
            for c in cands.iter().filter(|c| c.e.exposure <= 0.0) {
                if has(&self.seen[0][c.e.dark as usize], c.k) { d.shielded += 1 } else { d.hidden += 1 }
            }
            d.pick = chosen.map(|(i, shot)| (cell(&cands[i]), shot));
            let best = cands.iter().enumerate().filter(|(_, c)| c.e.exposure <= 0.0).max_by(|a, b| a.1.e.net.total_cmp(&b.1.e.net));
            d.cover = best.map(|(j, c)| (cell(c), match chosen {
                Some((i, _)) if j == i => "picked",
                Some((i, true)) if j < i => "exact_fail",
                Some((i, _)) if c.e.net > cands[i].e.net => "transit",
                _ => "net",
            }));
            d.us = t0.elapsed().as_micros() as u64;
            *out = d;
        }
        let mut f = chosen.map(|(i, shot)| found(&cands[i], shot, negative, n))?;
        let goal = chosen.map(|(i, _)| cands[i])?;
        if goal.transit_s > CHECK_MAX_S {
            let to_goal = self.my.distance_to(goal.p) - CHECK_PROGRESS_M;
            let mut on_way: Vec<&Cand> = cands.iter().filter(|c| c.transit_s <= CHECK_MAX_S && c.e.net >= 0.0 && c.p.distance_to(goal.p) <= to_goal).collect();
            on_way.sort_unstable_by(|a, b| b.e.net.total_cmp(&a.e.net));
            f.checkpoint = on_way.into_iter().take(VERIFY).find(|c| !needs_shot(c) || exact(c.p)).map(|c| (c.p, needs_shot(c), c.e.net, c.e.dark));
        }
        Some(f)
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
