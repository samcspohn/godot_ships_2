use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;

use godot::prelude::*;

use crate::nav::cover_search::CoverArgs;
use crate::nav::spot_walk::SpotInputs;
use crate::nav::visibility::VisibilityGrid;

/// fight_search's per-enemy trade curves and weights, from the opts dictionary.
pub(crate) struct FightArgs {
    pub cones: CoverArgs,
    /// Per enemy, `steps` samples every `step_m` from `p0_m`: our share of its HP
    /// per second (out) and its share of ours (inn).
    pub out: Vec<f32>,
    pub inn: Vec<f32>,
    pub steps: usize,
    pub p0_m: f32,
    pub step_m: f32,
    /// Per enemy: what reaching it is worth, 0 for no target.
    pub value: Vec<f32>,
    /// Per enemy: the chance its guns are on us rather than a friend, and the
    /// range to our nearest lit friend: nearer than that, we are its target.
    pub aggro: Vec<f32>,
    pub front: Vec<f32>,
    /// Per enemy: our HP over that friend's, 0 unless we are tankier. Drawing its fire costs only what we take beyond what it would.
    pub front_hp: Vec<f32>,
    /// Harm grows by this share for each shooter past the first.
    pub focus: f32,
    /// Harm grows by this share as the shooters' arc widens from CROSSFIRE_FREE to CROSSFIRE_FULL.
    pub crossfire: f32,
    /// Seconds a station is scored over, sailing there included.
    pub hold_s: f32,
    pub speed: f32,
    /// Share of our HP a second that being seen costs a dark ship en route.
    pub detect_rate: f32,
    pub dark: bool,
}

impl FightArgs {
    pub(crate) fn from_opts(axis: f32, o: &VarDictionary) -> Self {
        let f = |k: &str, d: f32| o.get(k).map_or(d, |v| v.to::<f32>());
        let arr = |k: &str| o.get(k).and_then(|v| v.try_to::<PackedFloat32Array>().ok()).map_or(Vec::new(), |a| a.to_vec());
        Self {
            cones: CoverArgs::from_opts(axis, o),
            out: arr("curve_out"),
            inn: arr("curve_in"),
            steps: o.get("curve_steps").map_or(0, |v| v.to::<i32>().max(0) as usize),
            p0_m: f("curve_p0_m", 100.0),
            step_m: f("curve_step_m", 1000.0),
            value: arr("value"),
            aggro: arr("aggro"),
            front: arr("front"),
            front_hp: arr("front_hp"),
            focus: f("focus", 0.0),
            crossfire: f("crossfire", 0.0),
            hold_s: f("hold_s", 90.0),
            speed: f("speed", 10.0).max(1.0),
            detect_rate: f("detect_rate", 0.0),
            dark: o.get("dark").is_some_and(|v| v.to::<bool>()),
        }
    }

    fn at(&self, curve: &[f32], i: usize, d: f32) -> f32 {
        if self.steps == 0 || curve.len() < (i + 1) * self.steps {
            return 0.0;
        }
        let t = (d - self.p0_m) / self.step_m;
        if t < 0.0 {
            return curve[i * self.steps];
        }
        let k = t.floor() as usize;
        if k + 1 >= self.steps {
            return if k + 1 == self.steps { curve[i * self.steps + k] } else { 0.0 };
        }
        let f = t - k as f32;
        curve[i * self.steps + k] * (1.0 - f) + curve[i * self.steps + k + 1] * f
    }
}

/// One cell's reckoning: what we deal there to the best target, what we take, and who we reach.
pub(crate) struct FightCell {
    pub mask: u64,
    pub value: f32,
    pub harm: f32,
}

/// What being at cell `k` costs a second: (harm, seen). Harm sums every enemy
/// whose shells land there: where we would be its nearest target, what we take
/// beyond what the friend we screen would, else at its aggro; grown by `focus`
/// for each shooter past the first and by `crossfire` as their bearings spread
/// past what one angle can face. Seen: some enemy sees the cell inside its sight of us.
pub(crate) fn exposure(g: &VisibilityGrid, k: usize, inp: &SpotInputs, a: &FightArgs) -> (f32, bool) {
    let p = g.centres[k];
    let (mut harm, mut shooters, mut seen) = (0.0f32, 0.0f32, false);
    let mut bearings = [(0.0f32, 0.0f32); 64];
    let mut nb = 0;
    // One answer per cell for every enemy: ReachLookup::hits recomputes the whole mask per call.
    let fire = inp.fire.as_ref().map(|f| (f.known_mask(), f.mask(p)));
    for (i, e) in inp.enemies.iter().enumerate().take(64) {
        if !e.heavy {
            continue;
        }
        let d = p.distance_to(e.pos);
        seen = seen || (d < e.det_r && e.cell.is_none_or(|ec| g.visible_idx(k, ec)));
        if fire.is_some_and(|(known, hit)| known & (1 << i) != 0 && hit & (1 << i) == 0) {
            continue;
        }
        let dps = a.at(&a.inn, i, d);
        if dps <= 0.0 {
            continue;
        }
        let front = a.front.get(i).copied().unwrap_or(f32::INFINITY);
        let h = if d < front {
            let spared = if front.is_finite() { a.at(&a.inn, i, front) * a.front_hp.get(i).copied().unwrap_or(0.0) } else { 0.0 };
            (dps - spared).max(0.0)
        } else {
            a.aggro.get(i).copied().unwrap_or(1.0) * dps
        };
        harm += h;
        shooters += h / dps;
        if h > 0.0 {
            bearings[nb] = ((e.pos - p).x.atan2((e.pos - p).y), h);
            nb += 1;
        }
    }
    let spread = (shooter_arc(&mut bearings[..nb]) - CROSSFIRE_FREE) / (CROSSFIRE_FULL - CROSSFIRE_FREE);
    (harm * (1.0 + a.focus * (shooters - 1.0).max(0.0)) * (1.0 + a.crossfire * spread.clamp(0.0, 1.0)), seen)
}

const CROSSFIRE_FREE: f32 = std::f32::consts::FRAC_PI_3;
const CROSSFIRE_FULL: f32 = std::f32::consts::PI;
/// Shooters doing less than this share of the worst one's harm do not widen the arc.
const CROSSFIRE_MIN_SHARE: f32 = 0.1;

/// The narrowest arc holding every shooter that matters: 2π less the widest gap between bearings.
fn shooter_arc(b: &mut [(f32, f32)]) -> f32 {
    let top = b.iter().map(|x| x.1).fold(0.0f32, f32::max);
    let mut n = 0;
    for i in 0..b.len() {
        if b[i].1 >= top * CROSSFIRE_MIN_SHARE {
            b[n] = b[i];
            n += 1;
        }
    }
    if n < 2 {
        return 0.0;
    }
    let b = &mut b[..n];
    b.sort_unstable_by(|x, y| x.0.total_cmp(&y.0));
    let mut gap = b[0].0 + std::f32::consts::TAU - b[n - 1].0;
    for w in b.windows(2) {
        gap = gap.max(w[1].0 - w[0].0);
    }
    std::f32::consts::TAU - gap
}

#[derive(Clone, Copy, PartialEq)]
struct Q(f32, usize);
impl Eq for Q {}
impl Ord for Q {
    fn cmp(&self, o: &Self) -> Ordering {
        self.0.total_cmp(&o.0).then(self.1.cmp(&o.1))
    }
}
impl PartialOrd for Q {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

impl VisibilityGrid {
    /// What our guns do at cell `k` to the best target they reach, and what we
    /// take there; None without a target.
    pub(crate) fn fight_cell(&self, k: usize, inp: &SpotInputs, a: &FightArgs) -> Option<FightCell> {
        if self.sdf_c[k] < inp.clearance {
            return None;
        }
        let mask = self.spotted_mask(k, inp);
        if mask == 0 {
            return None;
        }
        let value = self.fight_value(k, mask, inp, a);
        if value <= 0.0 {
            return None;
        }
        Some(FightCell { mask, value, harm: exposure(self, k, inp, a).0 })
    }

    /// One target at a time: the best of those `mask` reaches is what the guns are worth at `k`.
    fn fight_value(&self, k: usize, mask: u64, inp: &SpotInputs, a: &FightArgs) -> f32 {
        let p = self.centres[k];
        let mut value = 0.0f32;
        for (i, e) in inp.enemies.iter().enumerate().take(64) {
            if mask & (1 << i) != 0 {
                value = value.max(a.value.get(i).copied().unwrap_or(0.0) * a.at(&a.out, i, p.distance_to(e.pos)));
            }
        }
        value
    }

    /// The best cell to fight from in the cones from `from`: over a window of
    /// hold_s, what the guns deal on the way there plus (value - harm) for the
    /// rest of the window once there, less the harm taken on the
    /// cheapest way there (dark, only where seen, plus detect_rate). Also the
    /// same reckoning for `held`. ((cell, score, reckoning), held score, weighed).
    pub(crate) fn fight_search_impl(&self, from: Vector2, held: Vector2, inp: &SpotInputs, a: &FightArgs)
        -> (Option<(usize, f32, FightCell)>, Option<(f32, FightCell)>, usize) {
        let r = (a.cones.reach_m / self.cell).ceil() as i32 + 1;
        let (cx, cz) = self.grid_of(from);
        let (x0, z0) = ((cx - r).max(0), (cz - r).max(0));
        let (x1, z1) = ((cx + r).min(self.w - 1), (cz + r).min(self.h - 1));
        let bw = (x1 - x0 + 1) as usize;
        let n = bw * (z1 - z0 + 1) as usize;
        let local = |ix: i32, iz: i32| (iz - z0) as usize * bw + (ix - x0) as usize;
        // Each cell's (harm, seen), once: the route and the station both read it.
        let mut expo: Vec<Option<(f32, bool)>> = vec![None; n];
        let exposure_at = |v: usize, k: usize, expo: &mut Vec<Option<(f32, bool)>>| -> (f32, bool) {
            *expo[v].get_or_insert_with(|| exposure(self, k, inp, a))
        };
        // Each cell's (targets reached, what the guns do there), once.
        let mut vals: Vec<Option<(u64, f32)>> = vec![None; n];
        let value_at = |v: usize, k: usize, vals: &mut Vec<Option<(u64, f32)>>| -> (u64, f32) {
            *vals[v].get_or_insert_with(|| {
                let mask = self.spotted_mask(k, inp);
                (mask, if mask == 0 { 0.0 } else { self.fight_value(k, mask, inp, a) })
            })
        };
        // Cheapest route by harm taken, time breaking ties; what the guns deal along it.
        let mut cost = vec![f32::INFINITY; n];
        let mut time = vec![f32::INFINITY; n];
        let mut dealt = vec![0.0f32; n];
        let mut heap = BinaryHeap::new();
        let s = local(cx.clamp(x0, x1), cz.clamp(z0, z1));
        cost[s] = 0.0;
        time[s] = 0.0;
        heap.push(Reverse(Q(0.0, s)));
        while let Some(Reverse(Q(c, u))) = heap.pop() {
            if c > cost[u] {
                continue;
            }
            let (ux, uz) = (x0 + (u % bw) as i32, z0 + (u / bw) as i32);
            for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let (vx, vz) = (ux + dx, uz + dz);
                if vx < x0 || vx > x1 || vz < z0 || vz > z1 {
                    continue;
                }
                let Some(k) = self.water(vx, vz) else { continue };
                if self.sdf_c[k] < inp.clearance {
                    continue;
                }
                let v = local(vx, vz);
                let (harm, seen) = exposure_at(v, k, &mut expo);
                let per_s = if a.dark { if seen { harm + a.detect_rate } else { 0.0 } } else { harm };
                let dt = self.cell * if dx != 0 && dz != 0 { std::f32::consts::SQRT_2 } else { 1.0 } / a.speed;
                let nc = c + per_s * dt + 1.0e-7 * dt;
                if nc < cost[v] {
                    cost[v] = nc;
                    time[v] = time[u] + dt;
                    dealt[v] = dealt[u] + value_at(v, k, &mut vals).1 * dt.min((a.hold_s - time[u]).max(0.0));
                    heap.push(Reverse(Q(nc, v)));
                }
            }
        }
        let cell_at = |v: usize, k: usize, expo: &mut Vec<Option<(f32, bool)>>, vals: &mut Vec<Option<(u64, f32)>>| -> Option<FightCell> {
            let (mask, value) = value_at(v, k, vals);
            (value > 0.0).then(|| FightCell { mask, value, harm: exposure_at(v, k, expo).0 })
        };
        let held_v = held.is_finite().then(|| self.grid_of(held)).and_then(|(hx, hz)| {
            if hx < x0 || hx > x1 || hz < z0 || hz > z1 {
                return None;
            }
            let k = self.water(hx, hz)?;
            let v = local(hx, hz);
            cost[v].is_finite().then_some((v, k))
        });
        let held_fc = held_v.and_then(|(v, k)| cell_at(v, k, &mut expo, &mut vals));
        // Past the window a station adds nothing but the sailing: the nearer of equals wins.
        let score = |v: usize, fc: &FightCell| dealt[v] - cost[v] + (fc.value - fc.harm) * (a.hold_s - time[v]).max(0.0)
            - 1.0e-6 * time[v];
        let mut best: Option<(usize, f32, FightCell)> = None;
        let mut weighed = 0;
        for v in 0..n {
            let (ix, iz) = (x0 + (v % bw) as i32, z0 + (v / bw) as i32);
            let Some(k) = self.water(ix, iz) else { continue };
            if !cost[v].is_finite() || a.cones.cost(from, self.centres[k]).is_none() {
                continue;
            }
            weighed += 1;
            if let Some(fc) = cell_at(v, k, &mut expo, &mut vals) {
                let sc = score(v, &fc);
                if best.as_ref().is_none_or(|b| sc > b.1) {
                    best = Some((k, sc, fc));
                }
            }
        }
        let held = held_v.zip(held_fc).map(|((v, _), fc)| (score(v, &fc), fc));
        (best, held, weighed)
    }
}
