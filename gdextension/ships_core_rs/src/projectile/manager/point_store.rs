//! Point tables held natively: the runtime worker writes buckets straight in, file-mode tables are put in once,
//! and `best` answers a lookup (PointTable.best_sorted's corner blend and early-exit walk) without GDScript.

use godot::prelude::*;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

/// Aim roles per bucket: superstructure twice (fore and aft of its middle, so a fire on one leaves the other),
/// casemate, citadel, bow, stern.
pub(crate) const ROLES: usize = 6;
/// Saturable sections, PointTable.SAT_SECTIONS order: one mask bit each.
const SAT_SECTIONS: [i32; 4] = [2, 3, 4, 5];
const SEC_CITADEL: i32 = 1;
const SEC_SUPER: i32 = 5;
const MASKS: usize = 1 << SAT_SECTIONS.len();
const NO_POINT: u32 = u32::MAX;

/// One role's best point in a bucket: its value per shot (payout units, before shell damage) under each
/// saturation mask, and the share of its shells that land.
#[derive(Clone, Copy)]
pub(crate) struct Slot {
    pub point: u32,
    pub v: [f32; MASKS],
    pub landed: f32,
}

impl Slot {
    const NONE: Slot = Slot { point: NO_POINT, v: [0.0; MASKS], landed: 0.0 };
}

pub(crate) struct PtTable {
    pub ranges: Vec<f64>,
    pub aspects: Vec<f64>,
    pub points: Vec<Vector3>,
    pub n_comp: usize,
    /// Per point, its ArmorPart.Type section; -1 unknown.
    pub sections: Vec<i32>,
    /// Weight of a saturated section's component per pen-code slot (PointTable.PEN_CODES order).
    pub sat_w: [f32; 4],
    /// bucket (range_i * n_aspect + aspect_i) -> per point n_comp values then landed (probes).
    pub buckets: HashMap<usize, Vec<f32>>,
    pub slots: HashMap<usize, [Slot; ROLES]>,
}

pub(crate) type Store = Arc<RwLock<HashMap<String, Arc<RwLock<PtTable>>>>>;

pub(crate) struct Best {
    pub point: usize,
    pub value: f64,
    pub damage: f64,
    pub landed: f64,
    pub visited: usize,
}

impl PtTable {
    pub fn new(ranges: Vec<f64>, aspects: Vec<f64>, points: Vec<Vector3>, n_comp: usize, sections: Vec<i32>, sat_w: [f32; 4]) -> Self {
        PtTable { ranges, aspects, points, n_comp, sections, sat_w, buckets: HashMap::new(), slots: HashMap::new() }
    }

    pub fn insert(&mut self, bucket: usize, vals: Vec<f32>) {
        let slots = self.reduce(&vals);
        self.slots.insert(bucket, slots);
        self.buckets.insert(bucket, vals);
    }

    /// Each role's best point at full pools, priced under every mask.
    fn reduce(&self, vals: &[f32]) -> [Slot; ROLES] {
        let stride = self.n_comp + 1;
        let n = self.points.len().min(vals.len() / stride.max(1));
        let comps = |k: usize| &vals[k * stride..k * stride + self.n_comp];
        let full: Vec<f32> = (0..n).map(|k| comps(k).iter().map(|v| v.max(0.0)).sum()).collect();
        let sec = |k: usize| self.sections.get(k).copied().unwrap_or(-1);
        let best_of = |pick: &dyn Fn(usize) -> bool| (0..n).filter(|&k| pick(k)).max_by(|&a, &b| full[a].total_cmp(&full[b]));
        let sup: Vec<usize> = (0..n).filter(|&k| sec(k) == SEC_SUPER).collect();
        let mid = if sup.is_empty() { 0.0 } else {
            let (lo, hi) = sup.iter().fold((f32::INFINITY, f32::NEG_INFINITY), |(l, h), &k| (l.min(self.points[k].z), h.max(self.points[k].z)));
            0.5 * (lo + hi)
        };
        let a = best_of(&|k| sec(k) == SEC_SUPER);
        let b = a.and_then(|a| {
            let fore = self.points[a].z < mid;
            best_of(&|k| sec(k) == SEC_SUPER && (self.points[k].z < mid) != fore)
        });
        let picks = [a, b, best_of(&|k| sec(k) == 2), best_of(&|k| sec(k) == SEC_CITADEL), best_of(&|k| sec(k) == 3),
            best_of(&|k| sec(k) == 4)];
        let mut out = [Slot::NONE; ROLES];
        for (r, p) in picks.iter().enumerate() {
            let Some(k) = *p else { continue };
            let c = comps(k);
            let mut v = [0.0f32; MASKS];
            for (m, vm) in v.iter_mut().enumerate() {
                *vm = c.iter().enumerate().map(|(j, &x)| {
                    let x = x.max(0.0);
                    if j == 0 { return x; }
                    let (si, ci) = ((j - 1) / 4, (j - 1) % 4);
                    if si < SAT_SECTIONS.len() && m & (1 << si) != 0 { x * self.sat_w[ci] } else { x }
                }).sum();
            }
            out[r] = Slot { point: k as u32, v, landed: vals[k * stride + self.n_comp].max(0.0) };
        }
        out
    }

    /// (lower index, fraction to the next) of `x` in ascending `xs`, clamped: PointTable._frac.
    fn frac(xs: &[f64], x: f64) -> (usize, f64) {
        if xs.len() < 2 || x <= xs[0] {
            return (0, 0.0);
        }
        if x >= xs[xs.len() - 1] {
            return (xs.len() - 1, 0.0);
        }
        let i = xs.partition_point(|&e| e < x) - 1;
        (i, (x - xs[i]) / (xs[i + 1] - xs[i]))
    }

    /// The four weighted corner buckets, or None while any one with weight is not built.
    fn corners(&self, range_m: f64, aspect_deg: f64) -> Option<Vec<(usize, f64)>> {
        if self.ranges.is_empty() {
            return None;
        }
        let (ri, rf) = Self::frac(&self.ranges, range_m);
        let (ai, af) = Self::frac(&self.aspects, aspect_deg);
        let na = self.aspects.len();
        let mut out = Vec::with_capacity(4);
        for corner in 0..4 {
            let wt = (if corner & 1 != 0 { rf } else { 1.0 - rf }) * (if corner >> 1 != 0 { af } else { 1.0 - af });
            if wt <= 0.0 {
                continue;
            }
            let key = (ri + (corner & 1)).min(self.ranges.len() - 1) * na + (ai + (corner >> 1)).min(na - 1);
            if !self.slots.contains_key(&key) {
                return None;
            }
            out.push((key, wt));
        }
        Some(out)
    }

    /// The best role under saturation mask `sat` (bit i: SAT_SECTIONS[i] drained), each role's value and landed
    /// blended over the corners and its point taken from the heaviest; `fires`: target-local fire positions with
    /// whether each is burning (a point's nearest fire alight means no new fire there).
    #[allow(clippy::too_many_arguments)]
    pub fn best(&self, range_m: f64, aspect_deg: f64, sat: i64, damage: f64, raw_fire: f64, fire_k: f64,
            fires: &[(Vector3, bool)]) -> Option<Best> {
        let roles = self.roles(range_m, aspect_deg, sat, damage, raw_fire, fire_k, fires)?;
        let visited = roles.iter().flatten().count();
        let mut best: Option<Best> = None;
        for b in roles.into_iter().flatten() {
            if best.as_ref().is_none_or(|x| b.value > x.value) {
                best = Some(b);
            }
        }
        best.map(|mut b| {
            b.visited = visited;
            b
        })
    }

    /// Each role's blended value at its heaviest corner's point; None where a corner lacks the role.
    #[allow(clippy::too_many_arguments)]
    pub fn roles(&self, range_m: f64, aspect_deg: f64, sat: i64, damage: f64, raw_fire: f64, fire_k: f64,
            fires: &[(Vector3, bool)]) -> Option<[Option<Best>; ROLES]> {
        let cs = self.corners(range_m, aspect_deg)?;
        let m = (sat.max(0) as usize) & (MASKS - 1);
        let heavy = cs.iter().max_by(|a, b| a.1.total_cmp(&b.1))?.0;
        let mut out: [Option<Best>; ROLES] = Default::default();
        for (r, slot) in out.iter_mut().enumerate() {
            let mut v = 0.0f64;
            let mut l = 0.0f64;
            let mut ok = true;
            for &(key, wt) in &cs {
                let s = &self.slots[&key][r];
                if s.point == NO_POINT {
                    ok = false;
                    break;
                }
                v += s.v[m] as f64 * wt;
                l += s.landed as f64 * wt;
            }
            let k = self.slots[&heavy][r].point;
            if !ok || k == NO_POINT {
                continue;
            }
            let p = self.points[k as usize];
            let chance = if fire_k <= 0.0 {
                0.0
            } else {
                let near = fires.iter().min_by(|a, b| {
                    a.0.distance_squared_to(p).partial_cmp(&b.0.distance_squared_to(p)).unwrap_or(std::cmp::Ordering::Equal)
                });
                if near.is_some_and(|f| f.1) { 0.0 } else { raw_fire }
            };
            let dmg = v * damage;
            *slot = Some(Best { point: k as usize, value: dmg + chance * fire_k * l, damage: dmg, landed: l, visited: 0 });
        }
        Some(out)
    }
}
