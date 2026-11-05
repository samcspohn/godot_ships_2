//! Point tables held natively: the runtime worker writes buckets straight in, file-mode tables are put in once,
//! and `best` answers a lookup (PointTable.best_sorted's corner blend and early-exit walk) without GDScript.

use godot::prelude::*;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

pub(crate) struct PtTable {
    pub ranges: Vec<f64>,
    pub aspects: Vec<f64>,
    pub points: Vec<Vector3>,
    pub n_comp: usize,
    /// bucket (range_i * n_aspect + aspect_i) -> per point n_comp values then landed.
    pub buckets: HashMap<usize, Vec<f32>>,
    /// bucket -> per point sum of components: its value at full pools, the walk's upper bound.
    pub full: HashMap<usize, Vec<f32>>,
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
    pub fn new(ranges: Vec<f64>, aspects: Vec<f64>, points: Vec<Vector3>, n_comp: usize) -> Self {
        PtTable { ranges, aspects, points, n_comp, buckets: HashMap::new(), full: HashMap::new() }
    }

    pub fn insert(&mut self, bucket: usize, vals: Vec<f32>) {
        let stride = self.n_comp + 1;
        let full = (0..self.points.len())
            .map(|k| vals[k * stride..k * stride + self.n_comp].iter().map(|v| v.max(0.0)).sum())
            .collect();
        self.full.insert(bucket, full);
        self.buckets.insert(bucket, vals);
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
            if !self.buckets.contains_key(&key) {
                return None;
            }
            out.push((key, wt));
        }
        Some(out)
    }

    /// PointTable.best_sorted. `w`: live weight per component; `fires`: target-local fire positions with whether
    /// each is burning (a point's nearest fire alight means no new fire there).
    #[allow(clippy::too_many_arguments)]
    pub fn best(&self, range_m: f64, aspect_deg: f64, w: &[f32], damage: f64, raw_fire: f64, fire_k: f64,
            fires: &[(Vector3, bool)]) -> Option<Best> {
        let cs = self.corners(range_m, aspect_deg)?;
        let n = self.points.len();
        let stride = self.n_comp + 1;
        let mut ub = vec![0.0f64; n];
        let mut landed = vec![0.0f64; n];
        for &(key, wt) in &cs {
            let (f, b) = (&self.full[&key], &self.buckets[&key]);
            for k in 0..n {
                ub[k] += f[k] as f64 * wt;
                landed[k] += (b[k * stride + self.n_comp].max(0.0) as f64) * wt;
            }
        }
        let key: Vec<f64> = (0..n).map(|k| ub[k] * damage + raw_fire * fire_k * landed[k]).collect();
        let mut order: Vec<usize> = (0..n).collect();
        order.sort_by(|&a, &b| key[b].partial_cmp(&key[a]).unwrap_or(std::cmp::Ordering::Equal));
        let mut best: Option<Best> = None;
        let mut visited = 0;
        for k in order {
            let bv = best.as_ref().map_or(f64::NEG_INFINITY, |b| b.value);
            if key[k] <= bv {
                break;
            }
            visited += 1;
            let mut v = 0.0f64;
            for &(bk, wt) in &cs {
                let b = &self.buckets[&bk];
                let acc: f64 = (0..self.n_comp).map(|c| (b[k * stride + c].max(0.0) * w[c]) as f64).sum();
                v += acc * wt;
            }
            let dmg = v * damage;
            let chance = if fire_k <= 0.0 {
                0.0
            } else {
                let p = self.points[k];
                let near = fires.iter().min_by(|a, b| {
                    a.0.distance_squared_to(p).partial_cmp(&b.0.distance_squared_to(p)).unwrap_or(std::cmp::Ordering::Equal)
                });
                if near.is_some_and(|f| f.1) { 0.0 } else { raw_fire }
            };
            let val = dmg + chance * fire_k * landed[k];
            if val > bv {
                best = Some(Best { point: k, value: val, damage: dmg, landed: landed[k], visited });
            }
        }
        best.map(|mut b| {
            b.visited = visited;
            b
        })
    }
}
