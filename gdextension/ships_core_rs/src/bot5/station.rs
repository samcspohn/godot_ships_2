use godot::prelude::*;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;

use crate::nav::visibility::VisibilityGrid;
use crate::projectile::manager::point_store::{PtTable, Store};

use super::features::Features;
use super::field::{has, Layout, TeamField};
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
/// v4's window: every station lies within this of us.
pub const WINDOW_M: f32 = 8000.0;
pub const MATE_SEP_M: f32 = 1000.0;
/// v4 Disengage: cells within this of the threat axis (toward or away) only.
pub const CONE_HALF: f32 = 35.0 * std::f32::consts::PI / 180.0;
/// v4 kite leg: straight away, swung in KITE_SWING steps up to KITE_SWING_MAX while the point is off the water.
const KITE_REACH_M: f32 = 3000.0;
const KITE_REACH_TURNS: f32 = 8.0;
const KITE_SWING: f32 = 15.0 * std::f32::consts::PI / 180.0;
const KITE_SWING_MAX: f32 = 150.0 * std::f32::consts::PI / 180.0;
/// Value gained for standing off from the nearest flank-mate's bearing round the anchor, full at SPREAD_FULL.
const SPREAD_W: f32 = 0.5;
const SPREAD_FULL: f32 = std::f32::consts::FRAC_PI_3;
/// Candidates scored in full (both moments, dark, defensibility) after a now-only pass over all.
const REFINE: usize = 24;
const KEEP_MARGIN: f32 = 0.1;
const MOVE_ON_M: f32 = 1500.0;
/// Candidates exact-checked for a shot, best first, before the scan gives up on fighting from here.
const VERIFY: usize = 32;
const RING_BEARINGS: usize = 36;
/// Guns that reach a station from bearings spread wider than this crossfire it (v4's brawl limit).
const CROSSFIRE: f32 = std::f32::consts::FRAC_PI_2;
/// No contact yet: HP share per minute a station is worth for being hidden from the anchor, and for flanking it.
const OPEN_COVER_W: f32 = 0.05;
const OPEN_FLANK_W: f32 = 0.05;
/// Off our team's line to the anchor by this much is a full flank.
const OPEN_FLANK_RAD: f32 = std::f32::consts::FRAC_PI_4;
/// Curves are resampled on this range step, so a lookup is an index.
const LUT_M: f32 = 100.0;
/// Curve rebuilds per hive pass while the point-table worker is still filling tables.
pub const REBUILDS_PER_PASS: usize = 4;

/// A point table flattened at damage 1, no fire, no saturation: per shot value by (range, aspect).
pub struct Curve {
    ranges: Vec<f32>,
    aspects: Vec<f32>,
    v: Vec<f32>,
    /// Per (range, aspect) node: the best aim's damage per hit, share of alpha.
    hit: Vec<f32>,
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
        let mut hit = vec![0.0; nr * na];
        // At a bucket's own node `best` blends that bucket alone: its best role's unsaturated value per shot.
        for (&key, slots) in &t.slots {
            if key < v.len() {
                let best = slots.iter().filter(|s| s.point != u32::MAX).max_by(|a, b| a.v[0].total_cmp(&b.v[0]));
                v[key] = best.map_or(0.0, |s| s.v[0].max(0.0));
                hit[key] = best.filter(|s| s.landed > 1e-3).map_or(0.0, |s| s.v[0].max(0.0) / s.landed);
            }
        }
        let done = t.slots.len() >= nr * na;
        let mean = (0..nr).map(|ri| v[ri * na..(ri + 1) * na].iter().sum::<f32>() / na.max(1) as f32).collect();
        let mut c = Curve { ranges: t.ranges.iter().map(|&r| r as f32).collect(), aspects: t.aspects.iter().map(|&a| a as f32).collect(),
            v, hit, mean, lut: Vec::new(), lut_mean: Vec::new(), done, at: now, buckets: t.slots.len() };
        c.resample();
        c
    }

    /// Damage per hit (share of alpha) at `range`, `aspect` degrees off our bow.
    pub fn hit_at(&self, range: f32, aspect: f32) -> f32 {
        let (na, nr) = (self.aspects.len(), self.ranges.len());
        if self.hit.len() < na * nr || na == 0 {
            return 0.0;
        }
        let (ri, rf) = Self::frac(&self.ranges, range);
        let (ai, af) = Self::frac(&self.aspects, aspect);
        let node = |r: usize, a: usize| self.hit[r.min(nr - 1) * na + a.min(na - 1)];
        let row = |r: usize| node(r, ai) * (1.0 - af) + node(r, ai + 1) * af;
        row(ri) * (1.0 - rf) + row(ri + 1) * rf
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

/// Damage per minute from a shooter's AP/HE curves (the better shell at each range) plus its secondaries in their reach.
pub struct Fire<'a> {
    curves: [Option<&'a Curve>; 2],
    gun: &'a ShipState,
    /// Whose pose sets the aspect: the target, or the shooter itself for fire on us.
    pub ship: &'a ShipState,
    /// Per LUT_M step, aspect mean, mains only, already in damage per minute.
    mean: Vec<f32>,
    /// Calibration books mains only.
    pub sec_on: bool,
}

impl<'a> Fire<'a> {
    pub fn new(curves: [Option<&'a Curve>; 2], gun: &'a ShipState, ship: &'a ShipState) -> Self {
        let n = curves.iter().flatten().map(|c| c.lut_mean.len()).max().unwrap_or(1);
        let mut f = Fire { curves, gun, ship, mean: Vec::new(), sec_on: true };
        let pm = f.per_min();
        f.mean = (0..n).map(|i| {
            let r = i as f32 * LUT_M;
            (0..2).filter_map(|a| f.curves[a].map(|c| c.mean_at(r) * gun.damage[a])).fold(0.0, f32::max) * pm
        }).collect();
        f
    }

    /// Only `ammo`'s curve (0 AP, 1 HE) when it has one; None keeps the worse of the two.
    pub fn read(self, ammo: Option<usize>) -> Self {
        match ammo.filter(|&a| self.curves[a].is_some()) {
            Some(a) => {
                let mut c = self.curves;
                c[1 - a] = None;
                Fire { sec_on: self.sec_on, ..Fire::new(c, self.gun, self.ship) }
            }
            None => self,
        }
    }

    pub fn mains(self) -> Self {
        Fire { sec_on: false, ..self }
    }

    fn per_min(&self) -> f32 {
        if self.gun.reload <= 0.0 { 0.0 } else { self.gun.barrels * 60.0 / self.gun.reload }
    }

    pub fn gun_range(&self) -> f32 {
        self.gun.gun_range
    }

    pub fn sec_at(&self, d: f32) -> f32 {
        if self.sec_on && d <= self.gun.sec_range { self.gun.sec_dpm } else { 0.0 }
    }

    pub fn mean_at(&self, d: f32) -> f32 {
        self.mean[((d / LUT_M).round().max(0.0) as usize).min(self.mean.len() - 1)] + self.sec_at(d)
    }

    pub fn at(&self, d: f32, aspect: f32) -> f32 {
        let v = (0..2).filter_map(|a| self.curves[a].map(|c| c.at(d, aspect) * self.gun.damage[a])).fold(0.0, f32::max);
        v * self.per_min() + self.sec_at(d)
    }
}

pub struct Threat<'a> {
    pub at: Vector2,
    pub range: f32,
    pub row: Option<&'a [AtomicU64]>,
    pub fire: Fire<'a>,
    /// Share of its fire we draw, from where we are now.
    pub aim: f32,
    /// No station inside this; 0 for none.
    pub ring: f32,
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

/// Per minute in cell k: every threat whose shells land there, while some enemy sees the cell; `aimed` weighs each by its aim on us.
pub fn exposure_at(threats: &[Threat], seen: bool, k: usize, p: Vector2) -> f32 {
    exposure_w(threats, seen, k, p, false)
}

pub fn exposure_w(threats: &[Threat], seen: bool, k: usize, p: Vector2, aimed: bool) -> f32 {
    if !seen {
        return 0.0;
    }
    threats.iter().filter_map(|t| {
        let d = t.at.distance_to(p);
        let hit = d <= t.range && t.row.is_none_or(|r| r[k / 64].load(Relaxed) >> (k % 64) & 1 != 0);
        hit.then(|| t.fire.mean_at(d) * if aimed { t.aim } else { 1.0 })
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
    /// Score only this station, no search.
    pub only: Option<Vector2>,
    /// Cover first: a station may carry at most this exposure (HP share per minute), at its worse moment.
    pub cover: Option<f32>,
    /// Disengage: least exposure within reach of `anchor` (us), no offence.
    pub escape: bool,
    /// Disengage cones: (bearing from us, transit multiplier); a cell must lie within CONE_HALF of one. Empty: no limit.
    pub cones: Vec<(f32, f32)>,
    /// v4 island cover instead of a fighting station.
    pub hide: Option<super::cover::CoverArgs>,
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
    /// Range band a station holds to it: the trade's, or a spotter's spot band.
    pub band: (f32, f32),
    /// The spotter's spot target: every station must be in its band with line of sight to it.
    pub must: bool,
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
    pub field: &'a TeamField,
    pub island: Option<&'a super::edge::IslandMesh>,
    pub arc: Option<super::edge::Flight>,
    /// Hull-deep water at a point, finer than the cells.
    pub nav_ok: &'a dyn Fn(Vector2) -> bool,
    /// Metres to land.
    pub land: &'a dyn Fn(Vector2) -> f32,
    /// Presumed and lost enemies and the flank centre, with our gun-matrix column there: cover's targets before any contact.
    pub aims: Vec<(Vector2, Arc<[u64]>)>,
    pub route: std::cell::OnceCell<Vec<f32>>,
    pub my: Vector2,
    pub speed: f32,
    pub conceal: f32,
    pub clearance: f32,
    pub turn_radius: f32,
    pub risk: f32,
    pub reach: f32,
    pub my_hp: f32,
    pub k_in: f32,
    /// May hold fire to spot unseen: destroyers, and cruisers that hide well inside their gun range.
    pub dark_ok: bool,
    /// Where the rest of our team is.
    pub allies: Option<Vector2>,
    /// Flank-mates' stations.
    pub mates: Vec<Vector2>,
    /// Every ally's engage station.
    pub taken: Vec<Vector2>,
    /// Own spawn and the unit vector toward the enemy's: no station past the nearest enemy that reaches it.
    pub front: Option<(Vector2, Vector2)>,
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
    /// The kite leg: sailed straight away, recomputed every tick.
    pub kite: bool,
    pub deep: bool,
    /// Cover: targets in reach from the station.
    pub targets: u32,
    /// Cover hold: the soft test the station fails (seen ahead, no target); it is kept, not dropped.
    pub soft: Option<&'static str>,
    /// Cover: water-route metres from us.
    pub route: f32,
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
            let in_band = d >= f.band.0 && d <= f.band.1;
            n_band += in_band as usize;
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
            let hidden = self.vis.cell_of(req.anchor).is_some_and(|a| !self.vis.visible_idx(a, k)) as u8 as f32;
            let flank = self.allies.map_or(0.0, |c| {
                let (u, v) = (p - req.anchor, c - req.anchor);
                (u.angle_to(v).abs() / OPEN_FLANK_RAD).min(1.0)
            });
            let net = OPEN_COVER_W * hidden + OPEN_FLANK_W * flank - x;
            return (d >= req.lo && d <= req.hi).then_some(Eval { value: 0.0, spot: 0.0, exposure: x, net, dark: false });
        }
        if req.escape {
            let dark = self.dark_ok;
            let x = (0..1 + full as usize).map(|m| exposure_at(&self.threats[m], has(&self.seen[m][dark as usize], k), k, p))
                .fold(0.0, f32::max) * self.k_in / self.my_hp;
            return Some(Eval { value: 0.0, spot: 0.0, exposure: x, net: -self.risk * x, dark });
        }
        let spread = self.spread(p, req.anchor);
        let mut best: Option<Eval> = None;
        for dark in [false, true] {
            // Dark is not shooting: only a spotter's station may be dark.
            if dark && (!self.dark_ok || !self.foes.iter().any(|f| f.must)) {
                continue;
            }
            let mut e = Eval { value: 0.0, spot: 0.0, exposure: 0.0, net: f32::INFINITY, dark };
            let mut worst_x = 0.0f32;
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
                if req.cover.is_some() {
                    worst_x = worst_x.max(exposure_w(&self.threats[m], has(&self.seen[m][dark as usize], k), k, p, true) * self.k_in / self.my_hp);
                }
                e.net = e.net.min(value * spread + spot - self.risk * x);
            }
            if req.cover.is_some_and(|c| worst_x > c) || (0..1 + full as usize).any(|m| self.crossfire(m, k, p, dark) > CROSSFIRE) {
                continue;
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

    fn spread(&self, p: Vector2, anchor: Vector2) -> f32 {
        let b = |q: Vector2| (q.x - anchor.x).atan2(q.y - anchor.y);
        let sep = self.mates.iter().map(|&m| wrap(b(p) - b(m)).abs()).fold(f32::INFINITY, f32::min);
        if sep.is_finite() { 1.0 + SPREAD_W * (sep / SPREAD_FULL).min(1.0) } else { 1.0 }
    }

    /// Inside some enemy's ring where its shells land.
    fn ringed(&self, p: Vector2) -> bool {
        let k = self.vis.cell_of(p);
        self.threats.iter().flatten().any(|t| t.ring > 0.0 && t.at.distance_to(p) < t.ring
            && k.is_none_or(|k| t.row.is_none_or(|r| r[k / 64].load(Relaxed) >> (k % 64) & 1 != 0)))
    }

    /// The transit multiplier of the disengage cone cell p lies in; None outside every cone.
    fn cone_ratio(&self, req: &Req, p: Vector2) -> Option<f32> {
        if req.cones.is_empty() {
            return Some(1.0);
        }
        let b = (p.x - self.my.x).atan2(p.y - self.my.y);
        req.cones.iter().filter(|c| wrap(b - c.0).abs() <= CONE_HALF).map(|c| c.1).reduce(f32::min)
    }

    /// v4's kite leg: KITE_REACH ahead along the first cone, swung either way until the point is open water.
    fn kite(&self, req: &Req, turn_radius: f32, ok: &mut dyn FnMut(Vector2) -> bool) -> Option<Vector2> {
        let axis = req.cones.first()?.0;
        let reach = KITE_REACH_M.max(KITE_REACH_TURNS * turn_radius);
        let n = (KITE_SWING_MAX / KITE_SWING).round() as i32;
        (0..=n).flat_map(|k| [k, -k]).map(|k| axis + k as f32 * KITE_SWING).map(|a| self.my + Vector2::new(a.sin(), a.cos()) * reach)
            .find(|&p| self.vis.cell_of(p).is_some_and(|k| self.vis.sdf_c[k] >= self.clearance) && ok(p))
    }

    /// A spotter's station: in its spot target's band with line of sight to it.
    fn spots_must(&self, p: Vector2) -> bool {
        self.foes.iter().find(|f| f.must).is_none_or(|f| {
            let d = p.distance_to(f.at[0].at);
            d >= f.band.0 && d <= f.band.1 && self.vis.cell_of(p).is_some_and(|k| self.vis.visible_idx(k, f.at[0].cell))
        })
    }

    /// Nearest open water on the target's band (any distance from us) with a shot, for when nothing in the window has one.
    fn shot_ring(&self, req: &Req, ok: &mut dyn FnMut(Vector2) -> bool) -> Option<Vector2> {
        let hi = req.hi.min(self.reach);
        let lo = req.lo.min(hi);
        let mut pts: Vec<Vector2> = [lo, 0.5 * (lo + hi), hi].iter().filter(|&&r| r > 0.0).flat_map(|&r| {
            (0..RING_BEARINGS).map(move |i| req.anchor + Vector2::from_angle(i as f32 * std::f32::consts::TAU / RING_BEARINGS as f32) * r)
        }).filter(|&p| self.vis.cell_of(p).is_some_and(|k| self.vis.sdf_c[k] >= self.clearance) && !self.ringed(p)
            && p.distance_to(self.my) <= WINDOW_M && !self.past_front(p) && self.taken.iter().all(|q| q.distance_to(p) >= MATE_SEP_M)
            && self.cone_ratio(req, p).is_some() && self.spots_must(p)).collect();
        pts.sort_unstable_by(|a, b| a.distance_to(self.my).total_cmp(&b.distance_to(self.my)));
        pts.into_iter().take(VERIFY).find(|&p| ok(p))
    }

    pub(super) fn past_front(&self, p: Vector2) -> bool {
        let Some((o, f)) = self.front else { return false };
        let depth = self.threats[0].iter().filter(|t| t.at.distance_to(p) <= t.range).map(|t| (t.at - o).dot(f)).fold(f32::INFINITY, f32::min);
        (p - o).dot(f) > depth
    }

    /// Narrowest arc holding the bearings of every threat whose shells land on cell k while it is seen; 0 for one or none.
    fn crossfire(&self, m: usize, k: usize, p: Vector2, dark: bool) -> f32 {
        if !has(&self.seen[m][dark as usize], k) {
            return 0.0;
        }
        let mut b: Vec<f32> = self.threats[m].iter().filter(|t| {
            t.at.distance_to(p) <= t.range && t.row.is_none_or(|r| r[k / 64].load(Relaxed) >> (k % 64) & 1 != 0)
        }).map(|t| (t.at.x - p.x).atan2(t.at.y - p.y)).collect();
        arc_of(&mut b)
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
            d >= f.band.0 && d <= f.band.1 || self.dark_ok && f.spot > 0.0 && d <= f.fire.ship.conceal
        };
        let spots = |f: &Foe| {
            let d = p.distance_to(f.at[0].at);
            d >= f.band.0 && d <= f.band.1 && self.vis.visible_idx(k, f.at[0].cell)
        };
        let placed = if req.escape || self.foes.is_empty() {
            (req.lo..=req.hi).contains(&p.distance_to(req.anchor)) && self.cone_ratio(req, p).is_some()
        } else if let Some(f) = self.foes.iter().find(|f| f.must) {
            spots(f)
        } else {
            self.foes.iter().any(near)
        };
        let fighting = !req.escape && !self.foes.is_empty();
        placed && self.vis.sdf_c[k] >= self.clearance && self.cone_ratio(req, p).is_some()
            && !req.avoid.is_some_and(|q| q.distance_to(p) < MOVE_ON_M)
            && (self.foes.is_empty() || p.distance_to(self.my) <= WINDOW_M)
            && !(fighting && (self.ringed(p) || self.past_front(p)))
            && (req.escape || self.taken.iter().all(|q| q.distance_to(p) >= MATE_SEP_M))
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

    /// Water-route metres from us, INF past WINDOW_M.
    pub(super) fn route(&self) -> &[f32] {
        self.route.get_or_init(|| self.vis.water_route(self.my, self.clearance, WINDOW_M))
    }


    fn rank(&self, req: &Req, cells: &[(usize, u8)], here: f32, need: usize, d: &mut Diag) -> Vec<Cand> {
        let score = |p: Vector2, net: f32, sail: bool| {
            let m = if sail { self.vis.sail_route(self.my, p) } else { None };
            let t = m.unwrap_or_else(|| self.my.distance_to(p)) / self.speed.max(1.0) * self.cone_ratio(req, p).unwrap_or(1.0);
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
        let mut out: Vec<Cand> = Vec::with_capacity(REFINE + 1);
        for (i, c) in quick.iter().enumerate() {
            if i >= REFINE && Some(c.k) != keep {
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
            net: c.e.net, dark: c.e.dark, negative, candidates: n, kite: false, deep: false, targets: 0, soft: None, route: f32::INFINITY };
        if let Some(q) = req.only {
            let k = v.cell_of(q)?;
            let e = self.eval(k, req, MIN_IN_RANGE.min(self.foes.len()), true).or_else(|| self.eval(k, req, 1, true))?;
            let needs = !req.escape && req.target.is_some();
            return (!needs || exact(q)).then(|| found(&Cand { k, p: q, e, score: e.net, transit_s: 0.0 }, needs, e.net < 0.0, 1));
        }
        let mut d = Diag::default();
        let here = v.cell_of(self.my).and_then(|k| self.eval(k, req, 1, true)).map_or_else(
            || -self.risk * v.cell_of(self.my).map_or(0.0, |k| exposure_at(&self.threats[0], has(&self.seen[0][0], k), k, self.my)) * self.k_in / self.my_hp,
            |e| e.net);
        let lattice = || -> Vec<(usize, u8)> { self.feats.lattice.iter().map(|&k| (k as usize, 2u8)).filter(|&(k, _)| self.usable(k, req)).collect() };
        let needs = [MIN_IN_RANGE.min(self.foes.len()), 1];
        let mut cands = Vec::new();
        let cells = self.gather(req);
        // Fewer targets in range only when no station has the full count.
        for need in needs {
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
        let needs_shot = |_: &Cand| !req.escape && req.target.is_some();
        let keep_k = req.keep.and_then(|q| v.cell_of(q));
        let mut point = |c: &Cand| -> Option<Vector2> { (!needs_shot(c) || exact(c.p)).then_some(c.p) };
        let mut chosen: Option<(usize, bool, Vector2)> = None;
        for (i, c) in cands.iter().enumerate().take(VERIFY) {
            if let Some(p) = point(c) {
                chosen = Some((i, needs_shot(c), p));
                break;
            }
        }
        if let Some((i, _, _)) = chosen {
            let floor = cands[i].score - KEEP_MARGIN * cands[i].score.abs();
            let kept = keep_k.and_then(|q| cands.iter().position(|c| c.k == q))
                .filter(|&j| j != i && cands[j].score >= floor);
            if let Some((j, p)) = kept.and_then(|j| point(&cands[j]).map(|p| (j, p))) {
                chosen = Some((j, needs_shot(&cands[j]), p));
            }
        }
        drop(point);
        let found = |c: &Cand, shot: bool, negative: bool, n: usize, p: Vector2| Found { station: p, ..found(c, shot, negative, n) };
        if let Some(out) = diag {
            d.passing = cands.iter().filter(|c| c.e.net >= 0.0).count();
            let cell = |c: &Cand| DiagCell { p: c.p, range: c.p.distance_to(req.anchor), value: c.e.value, exposure: c.e.exposure,
                transit_s: c.transit_s, score: c.score };
            for c in cands.iter().filter(|c| c.e.exposure <= 0.0) {
                if has(&self.seen[0][c.e.dark as usize], c.k) { d.shielded += 1 } else { d.hidden += 1 }
            }
            d.pick = chosen.map(|(i, shot, _)| (cell(&cands[i]), shot));
            let best = cands.iter().enumerate().filter(|(_, c)| c.e.exposure <= 0.0).max_by(|a, b| a.1.e.net.total_cmp(&b.1.e.net));
            d.cover = best.map(|(j, c)| (cell(c), match chosen {
                Some((i, _, _)) if j == i => "picked",
                Some((i, true, _)) if j < i => "exact_fail",
                Some((i, _, _)) if c.e.net > cands[i].e.net => "transit",
                _ => "net",
            }));
            d.us = t0.elapsed().as_micros() as u64;
            *out = d;
        }
        let fire = !req.escape && req.target.is_some();
        let mut ok = |p: Vector2| !fire || exact(p);
        if !req.cones.is_empty() && chosen.is_none() {
            return self.kite(req, self.turn_radius, &mut ok).map(|p| Found { station: p, shot: fire, value: 0.0, exposure: 0.0, net: 0.0,
                dark: false, negative: true, candidates: n, kite: true, deep: false, targets: 0, soft: None, route: f32::INFINITY });
        }
        match chosen {
            Some((i, shot, p)) => Some(found(&cands[i], shot, negative, n, p)),
            None => fire.then(|| self.shot_ring(req, &mut ok)).flatten().map(|p| Found { station: p, shot: true,
                value: 0.0, exposure: 0.0, net: 0.0, dark: false, negative: true, candidates: n, kite: false, deep: false, targets: 0, soft: None, route: f32::INFINITY }),
        }
    }

}

/// Narrowest arc holding every bearing in `b`.
pub fn arc_of(b: &mut [f32]) -> f32 {
    if b.len() < 2 {
        return 0.0;
    }
    b.sort_unstable_by(f32::total_cmp);
    let mut gap = b[0] + std::f32::consts::TAU - b[b.len() - 1];
    for w in b.windows(2) {
        gap = gap.max(w[1] - w[0]);
    }
    std::f32::consts::TAU - gap
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arc_spans_the_tightest_side() {
        use std::f32::consts::PI;
        assert_eq!(arc_of(&mut [1.0]), 0.0);
        assert!((arc_of(&mut [0.1, -0.1]) - 0.2).abs() < 1e-5);
        assert!((arc_of(&mut [PI - 0.1, -PI + 0.1]) - 0.2).abs() < 1e-5);
        assert!((arc_of(&mut [0.0, PI / 2.0, PI]) - PI).abs() < 1e-5);
    }

    fn ship(sec_range: f32, sec_dpm: f32) -> ShipState {
        let mut r = [0.0f32; super::super::snapshot::STRIDE];
        (r[1], r[9], r[16], r[32], r[33]) = (1.0, 1.0, 1000.0, sec_range, sec_dpm);
        let mut s = super::super::snapshot::Snapshot::default();
        s.load(&[1], &r);
        s.ships[0]
    }

    #[test]
    fn secondaries_only_inside_their_range() {
        let them = ship(5000.0, 600.0);
        let f = Fire::new([None, None], &them, &them);
        assert_eq!(f.mean_at(4000.0), 600.0);
        assert_eq!(f.mean_at(6000.0), 0.0);
    }

    #[test]
    fn curve_blends_range_and_aspect() {
        let mut c = Curve { ranges: vec![1000.0, 2000.0], aspects: vec![0.0, 90.0], v: vec![1.0, 3.0, 5.0, 7.0],
            hit: vec![0.5, 1.0, 1.5, 2.0], mean: vec![2.0, 6.0], lut: Vec::new(), lut_mean: Vec::new(), done: true, at: 0.0, buckets: 4 };
        c.resample();
        assert_eq!(c.at(1500.0, 45.0), 4.0);
        assert_eq!(c.at(500.0, 0.0), 1.0);
        assert_eq!(c.at(9000.0, 90.0), 7.0);
        assert_eq!(c.mean_at(1500.0), 4.0);
        assert_eq!(c.hit_at(1500.0, 45.0), 1.25);
    }
}
