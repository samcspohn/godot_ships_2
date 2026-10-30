use godot::prelude::*;

use crate::nav::spot_walk::SpotInputs;
use crate::nav::visibility::VisibilityGrid;

/// fight_search's per-enemy trade curves, weights and rings, from the opts dictionary.
pub(crate) struct FightArgs {
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
    /// Per enemy: inside this range, a cell its shells reach is no station.
    pub ring: Vec<f32>,
    /// Per enemy: the circle stations are walked on, 0 for none.
    pub walk_r: Vec<f32>,
    /// Per enemy: a chase keeps out of its sight inside this, 0 for none.
    pub chase_ring: Vec<f32>,
    pub window_m: f32,
    pub speed: f32,
    /// Unseen now: the route costs only where it would be seen.
    pub dark: bool,
    /// The last station: a cell scores `move_cost` less per weighted metre of water route from it, a
    /// chase cell counts `chase_anchor_w` straight metres per metre from it.
    pub anchor: Vector2,
    pub move_cost: f32,
    /// Route weight per metre through cells some free heavy enemy sees, hidden ones, and hidden ones our guns reach a target from.
    pub route_w: Vector3,
    pub chase_anchor_w: f32,
    /// A new station lies no more than `walk_slack` behind `walk_from` along
    /// `walk_axis` (zero: any way), and every station's offset from
    /// `lat_origin` along `lat_axis` lies in [lat_min, lat_max].
    pub walk_axis: Vector2,
    pub walk_from: Vector2,
    pub walk_slack: f32,
    pub lat_axis: Vector2,
    pub lat_origin: Vector2,
    pub lat_min: f32,
    pub lat_max: f32,
    /// Team-mates' stations: a cell inside `claim_r` of one loses up to `claim_cost`.
    pub claims: Vec<Vector2>,
    pub claim_r: f32,
    pub claim_cost: f32,
    /// Per enemy, nonzero while it shoots a friend of ours: its ring stops no station,
    /// and checkpoints need only hide from the others.
    pub busy: Vec<u8>,
    /// Island-shadow checkpoints toward `goal`: a full-window step is worth this share
    /// of the best our guns could do; 0 for none.
    pub checkpoint: f32,
    pub goal: Vector2,
}

impl FightArgs {
    pub(crate) fn from_opts(o: &VarDictionary) -> Self {
        let f = |k: &str, d: f32| o.get(k).map_or(d, |v| v.to::<f32>());
        let arr = |k: &str| o.get(k).and_then(|v| v.try_to::<PackedFloat32Array>().ok()).map_or(Vec::new(), |a| a.to_vec());
        Self {
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
            ring: arr("ring"),
            walk_r: arr("walk_r"),
            chase_ring: arr("chase_ring"),
            window_m: f("window_m", 6000.0),
            speed: f("speed", 10.0).max(1.0),
            dark: o.get("dark").is_some_and(|v| v.to::<bool>()),
            anchor: o.get("anchor").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::INF),
            move_cost: f("move_cost", 0.0),
            route_w: o.get("route_w").and_then(|v| v.try_to::<Vector3>().ok()).unwrap_or(Vector3::ONE),
            chase_anchor_w: f("chase_anchor_w", 0.0),
            walk_axis: o.get("walk_axis").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::ZERO),
            walk_from: o.get("walk_from").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::ZERO),
            walk_slack: f("walk_slack", 0.0),
            lat_axis: o.get("lat_axis").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::ZERO),
            lat_origin: o.get("lat_origin").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::ZERO),
            lat_min: f("lat_min", f32::NEG_INFINITY),
            lat_max: f("lat_max", f32::INFINITY),
            claims: o.get("claims").and_then(|v| v.try_to::<PackedVector2Array>().ok()).map_or(Vec::new(), |a| a.to_vec()),
            claim_r: f("claim_r", 0.0),
            claim_cost: f("claim_cost", 0.0),
            busy: o.get("busy").and_then(|v| v.try_to::<PackedByteArray>().ok()).map_or(Vec::new(), |a| a.to_vec()),
            checkpoint: f("checkpoint", 0.0),
            goal: o.get("goal").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::INF),
        }
    }

    fn busy(&self, i: usize) -> bool {
        self.busy.get(i).is_some_and(|&b| b != 0)
    }

    /// The most any target is worth to our guns at any range.
    fn best_value(&self, inp: &SpotInputs) -> f32 {
        inp.enemies.iter().enumerate().take(64).filter(|(_, e)| e.shootable).fold(0.0f32, |m, (i, _)| {
            let peak = self.out.get(i * self.steps..(i + 1) * self.steps).map_or(0.0, |c| c.iter().copied().fold(0.0, f32::max));
            m.max(self.value.get(i).copied().unwrap_or(0.0) * peak)
        })
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

/// route_field's costs to the cells it settled, and how many it settled.
#[derive(Default)]
pub(crate) struct RouteField {
    /// Per water cell, INF where not settled; empty for no field.
    pub cost: Vec<f32>,
    pub settled: usize,
}

/// route_field searches out to this many times the farthest target's straight distance.
const ROUTE_REACH: f32 = 1.2;

/// A checkpoint must gain this much toward the goal.
const CHECKPOINT_MIN_M: f32 = 500.0;

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

impl VisibilityGrid {
    /// What our guns do at cell `k` to the best target they reach, and what we
    /// take there; None without a target.
    pub(crate) fn fight_cell(&self, k: usize, inp: &SpotInputs, a: &FightArgs) -> Option<FightCell> {
        if self.sdf_c[k] < inp.clearance || self.ringed(k, inp, a) {
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

    /// Inside some enemy's ring where its shells land, or may.
    fn ringed(&self, k: usize, inp: &SpotInputs, a: &FightArgs) -> bool {
        let p = self.centres[k];
        let fire = inp.fire.as_ref().map(|f| (f.known_mask(), f.mask(p)));
        inp.enemies.iter().enumerate().take(64).any(|(i, e)| {
            !a.busy(i)
                && a.ring.get(i).is_some_and(|&r| p.distance_to(e.pos) < r)
                && fire.is_none_or(|(known, hit)| known & (1 << i) == 0 || hit & (1 << i) != 0)
        })
    }

    /// A cell no heavy enemy but a busy one sees inside its sight of us.
    fn hidden_from_free(&self, k: usize, inp: &SpotInputs, a: &FightArgs) -> bool {
        let p = self.centres[k];
        !inp.enemies.iter().enumerate().take(64).any(|(i, e)| {
            e.heavy && !a.busy(i) && p.distance_to(e.pos) < e.det_r && e.cell.is_none_or(|ec| self.visible_idx(k, ec))
        })
    }

    /// A hidden cell gaining CHECKPOINT_MIN_M from `from` toward the goal, out of
    /// every ring: worth `checkpoint` of `best` per full window gained, less what it takes.
    pub(crate) fn checkpoint_cell(&self, k: usize, from: Vector2, best: f32, inp: &SpotInputs, a: &FightArgs) -> Option<FightCell> {
        if a.checkpoint <= 0.0 || !a.goal.is_finite() || best <= 0.0 || self.sdf_c[k] < inp.clearance {
            return None;
        }
        let gain = from.distance_to(a.goal) - self.centres[k].distance_to(a.goal);
        if gain < CHECKPOINT_MIN_M || !self.hidden_from_free(k, inp, a) || self.ringed(k, inp, a) {
            return None;
        }
        let value = a.checkpoint * best * gain.min(a.window_m) / a.window_m;
        Some(FightCell { mask: 0, value, harm: exposure(self, k, inp, a).0 })
    }

    /// fight_cell, else checkpoint_cell from `from`.
    pub(crate) fn station_cell(&self, k: usize, from: Vector2, inp: &SpotInputs, a: &FightArgs) -> Option<FightCell> {
        self.fight_cell(k, inp, a).or_else(|| self.checkpoint_cell(k, from, a.best_value(inp), inp, a))
    }

    /// Inside the chase ring of some enemy that sees the cell.
    fn chase_seen(&self, k: usize, inp: &SpotInputs, a: &FightArgs) -> bool {
        let p = self.centres[k];
        inp.enemies.iter().enumerate().take(64).any(|(i, e)| {
            a.chase_ring.get(i).is_some_and(|&r| p.distance_to(e.pos) < r)
                && e.cell.is_none_or(|ec| self.visible_idx(k, ec))
        })
    }

    /// Metres from the anchor, 0 without one.
    fn off_anchor(&self, k: usize, a: &FightArgs) -> f32 {
        if a.anchor.is_finite() { self.centres[k].distance_to(a.anchor) } else { 0.0 }
    }

    /// What a station at `k` gives up for the route from the anchor and for crowding team-mates.
    fn penalty(&self, k: usize, a: &FightArgs, route: &RouteField) -> f32 {
        let p = self.centres[k];
        let crowd: f32 = if a.claim_r > 0.0 {
            a.claims.iter().map(|c| (1.0 - p.distance_to(*c) / a.claim_r).max(0.0)).sum()
        } else { 0.0 };
        let moved = route.cost.get(k).copied().filter(|c| c.is_finite()).unwrap_or(self.off_anchor(k, a) * a.route_w.x);
        a.move_cost * moved + a.claim_cost * crowd
    }

    /// Shoot-over from answers the reach planes already hold, so the route traces no rays.
    fn route_weight(&self, k: usize, inp: &SpotInputs, a: &FightArgs) -> f32 {
        if !self.hidden_from_free(k, inp, a) {
            return a.route_w.x;
        }
        let shootable = inp.enemies.iter().take(64).enumerate().fold(0u64, |m, (i, e)| m | ((e.shootable as u64) << i));
        let reach = inp.reach.as_ref().map_or(0, |r| r.mask_cached(self.centres[k]));
        if reach & shootable != 0 { a.route_w.z } else { a.route_w.y }
    }

    /// Weighted metres through water at our clearance from `origin` to each of `targets`,
    /// stopping once all are settled (with `reach_m`, to every cell within it); a target with no route is left out.
    pub(crate) fn route_field(&self, origin: Vector2, targets: &[usize], reach_m: Option<f32>, inp: &SpotInputs, a: &FightArgs) -> RouteField {
        use std::cmp::Reverse;
        use std::collections::BinaryHeap;
        let mut out = RouteField::default();
        let (ox, oz) = self.grid_of(origin);
        let Some(start) = self.water(ox, oz) else { return out };
        let n_cells = self.centres.len();
        out.cost = vec![f32::INFINITY; n_cells];
        let mut want = vec![false; n_cells];
        let mut left = 0usize;
        for &k in targets {
            if !want[k] {
                want[k] = true;
                left += 1;
            }
        }
        let reach = reach_m.unwrap_or_else(|| targets.iter().map(|&k| self.centres[k].distance_to(origin)).fold(0.0f32, f32::max) * ROUTE_REACH)
            + 2.0 * self.cell;
        let mut dist = vec![f32::INFINITY; n_cells];
        let mut weight = vec![f32::NAN; n_cells];
        let mut heap = BinaryHeap::new();
        dist[start] = 0.0;
        heap.push(Reverse((0u32, start)));
        while let Some(Reverse((bits, k))) = heap.pop() {
            let d = f32::from_bits(bits);
            if d > dist[k] {
                continue;
            }
            out.settled += 1;
            if reach_m.is_some() || want[k] {
                out.cost[k] = d;
                if want[k] {
                    want[k] = false;
                    left -= 1;
                    if left == 0 && reach_m.is_none() {
                        break;
                    }
                }
            }
            if weight[k].is_nan() {
                weight[k] = self.route_weight(k, inp, a);
            }
            let wk = weight[k];
            let (ix, iz) = self.grid_of(self.centres[k]);
            for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let Some(n) = self.water(ix + dx, iz + dz) else { continue };
                if self.sdf_c[n] < inp.clearance && n != start || self.centres[n].distance_to(origin) > reach {
                    continue;
                }
                if weight[n].is_nan() {
                    weight[n] = self.route_weight(n, inp, a);
                }
                let step = self.cell * if dx != 0 && dz != 0 { std::f32::consts::SQRT_2 } else { 1.0 };
                let nd = d + step * 0.5 * (wk + weight[n]);
                if nd < dist[n] {
                    dist[n] = nd;
                    heap.push(Reverse((nd.to_bits(), n)));
                }
            }
        }
        out
    }

    /// Inside the lateral band, and for a new station not back against the walk.
    fn walk_ok(&self, p: Vector2, new: bool, a: &FightArgs) -> bool {
        let lat = (p - a.lat_origin).dot(a.lat_axis);
        (a.lat_axis == Vector2::ZERO || (lat >= a.lat_min && lat <= a.lat_max))
            && (!new || a.walk_axis == Vector2::ZERO || (p - a.walk_from).dot(a.walk_axis) >= -a.walk_slack)
    }

    /// Harm taken sailing the straight line `from` to `to`, at `speed`.
    pub(crate) fn route_harm(&self, from: Vector2, to: Vector2, inp: &SpotInputs, a: &FightArgs) -> f32 {
        let len = from.distance_to(to);
        let n = (len / (self.cell * 0.5)).ceil().max(1.0) as usize;
        let dt = len / n as f32 / a.speed;
        let mut last = usize::MAX;
        let mut per_s = 0.0;
        let mut harm = 0.0;
        for j in 0..n {
            let (ix, iz) = self.grid_of(from.lerp(to, (j as f32 + 0.5) / n as f32));
            if let Some(k) = self.water(ix, iz) {
                if k != last {
                    let (h, seen) = exposure(self, k, inp, a);
                    per_s = if a.dark && !seen { 0.0 } else { h };
                    last = k;
                }
                harm += per_s * dt;
            }
        }
        harm
    }

    /// The best cell on the walk circles within window_m of `from`: what we
    /// deal there less what we take and the penalty, outside every ring whose
    /// owner's shells land. Where none has a target, of those cells and the
    /// step from `from` toward the most valued target's circle, the nearest that
    /// target out of sight of any enemy whose chase ring holds it (chase). Also
    /// `held`'s score. (best, held score, chase (cell, target), weighed).
    pub(crate) fn fight_search_impl(&self, from: Vector2, held: Vector2, inp: &SpotInputs, a: &FightArgs)
        -> (Option<(usize, f32, FightCell)>, Option<(f32, FightCell)>, Option<(usize, Vector2)>, usize) {
        let chase = inp.enemies.iter().enumerate().take(64)
            .filter(|(i, e)| e.shootable && a.value.get(*i).is_some_and(|&v| v > 0.0))
            .max_by(|x, y| a.value[x.0].total_cmp(&a.value[y.0]))
            .map(|(i, e)| (i, e.pos));
        let mut seen = std::collections::HashSet::new();
        let mut cand: Vec<usize> = Vec::new();
        let mut add = |p: Vector2, cand: &mut Vec<usize>| {
            if p.distance_to(from) > a.window_m {
                return;
            }
            let (ix, iz) = self.grid_of(p);
            if let Some(k) = self.water(ix, iz).filter(|&k| self.sdf_c[k] >= inp.clearance && self.walk_ok(self.centres[k], true, a)) {
                if seen.insert(k) {
                    cand.push(k);
                }
            }
        };
        for (i, e) in inp.enemies.iter().enumerate().take(64) {
            let r = a.walk_r.get(i).copied().unwrap_or(0.0);
            if r <= 0.0 || (e.pos.distance_to(from) - r).abs() > a.window_m {
                continue;
            }
            let n = ((std::f32::consts::TAU * r / self.cell).ceil() as usize).max(8);
            for j in 0..n {
                let t = std::f32::consts::TAU * j as f32 / n as f32;
                add(e.pos + Vector2::new(t.sin(), t.cos()) * r, &mut cand);
            }
        }
        if let Some((i, t)) = chase {
            let r = a.walk_r.get(i).copied().unwrap_or(0.0);
            let on = if from.distance_to(t) > 1.0 { t + (from - t).normalized() * r } else { from };
            add(from + (on - from).limit_length(Some(a.window_m)), &mut cand);
        }
        let held_k = held.is_finite().then(|| self.grid_of(held)).and_then(|(hx, hz)| self.water(hx, hz));
        let cells: Vec<(usize, Option<FightCell>)> = cand.iter().map(|&k| (k, self.fight_cell(k, inp, a))).collect();
        let mut targets: Vec<usize> = cells.iter().filter(|c| c.1.is_some()).map(|c| c.0).collect();
        targets.extend(held_k);
        let origin = if a.anchor.is_finite() { a.anchor } else { from };
        let top = a.best_value(inp);
        let checkpoints = a.checkpoint > 0.0 && a.goal.is_finite() && top > 0.0;
        let route = if a.move_cost <= 0.0 || (targets.is_empty() && !checkpoints) {
            RouteField::default()
        } else {
            self.route_field(origin, &targets, checkpoints.then(|| a.window_m + origin.distance_to(from)), inp, a)
        };
        let mut best: Option<(usize, f32, FightCell)> = None;
        let mut near: Option<(usize, f32)> = None;
        for (k, fc) in cells {
            if let Some(fc) = fc {
                let sc = fc.value - fc.harm - self.penalty(k, a, &route);
                if best.as_ref().is_none_or(|b| sc > b.1) {
                    best = Some((k, sc, fc));
                }
            } else if let Some((_, t)) = chase.filter(|_| best.is_none() && !self.ringed(k, inp, a) && !self.chase_seen(k, inp, a)) {
                let d = self.centres[k].distance_to(t) + a.chase_anchor_w * self.off_anchor(k, a);
                if near.is_none_or(|b| d < b.1) {
                    near = Some((k, d));
                }
            }
        }
        let mut weighed = cand.len();
        if checkpoints {
            let r = (a.window_m / self.cell).ceil() as i32;
            let (cx, cz) = self.grid_of(from);
            for iz in cz - r..=cz + r {
                for ix in cx - r..=cx + r {
                    let Some(k) = self.water(ix, iz) else { continue };
                    if seen.contains(&k) || self.centres[k].distance_to(from) > a.window_m || !self.walk_ok(self.centres[k], true, a) {
                        continue;
                    }
                    weighed += 1;
                    if let Some(fc) = self.checkpoint_cell(k, from, top, inp, a) {
                        let sc = fc.value - fc.harm - self.penalty(k, a, &route);
                        if best.as_ref().is_none_or(|b| sc > b.1) {
                            best = Some((k, sc, fc));
                        }
                    }
                }
            }
        }
        let held = held_k
            .filter(|&k| self.walk_ok(self.centres[k], false, a))
            .and_then(|k| self.station_cell(k, from, inp, a).map(|fc| (fc.value - fc.harm - self.penalty(k, a, &route), fc)));
        let chase = if best.is_none() { near.zip(chase).map(|(x, (_, t))| (x.0, t)) } else { None };
        (best, held, chase, weighed)
    }
}
