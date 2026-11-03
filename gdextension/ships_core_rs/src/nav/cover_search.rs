use godot::prelude::*;

use crate::nav::forecast::Forecast;
use crate::nav::spot_walk::SpotInputs;
use crate::nav::visibility::VisibilityGrid;

/// cover_search / cover_eval knobs from the opts dictionary.
#[derive(Clone)]
pub(crate) struct CoverArgs {
    pub reach_m: f32,
    /// Cells in the away cone cost this many times their distance.
    pub away_ratio: f32,
    /// Bearing of the toward cone; INF searches every direction at 1x.
    pub axis: f32,
    pub cone_half: f32,
    pub allow_dark: bool,
    /// Dark water only when no cell within reach is hidden or shielded.
    pub dark_last: bool,
    /// A cell seen but out of every heavy enemy's shells counts; false: only hidden or dark ones.
    pub shield_ok: bool,
    pub need: u32,
    /// Only cells nearer than near_d to near_pos; near_d INF, any.
    pub near_pos: Vector2,
    pub near_d: f32,
    /// Enemies that see us: a cell must lie within clip_half of each one's bearing to the search origin.
    pub clip_pos: Vec<Vector2>,
    pub clip_half: f32,
    /// Cells within exclude_r of one of these are not searched.
    pub exclude: Vec<Vector2>,
    pub exclude_r: f32,
    /// A cell must also stay safe from each enemy's forecast from our arrival through the hold.
    pub forecast: Forecast,
}

impl CoverArgs {
    pub(crate) fn from_opts(axis: f32, o: &VarDictionary) -> Self {
        let f = |k: &str, d: f32| o.get(k).map_or(d, |v| v.to::<f32>());
        Self {
            reach_m: f("reach_m", 8000.0),
            away_ratio: f("away_ratio", 3.0),
            axis,
            cone_half: f("cone_half", std::f32::consts::PI),
            allow_dark: o.get("allow_dark").is_none_or(|v| v.to::<bool>()),
            dark_last: o.get("dark_last").is_some_and(|v| v.to::<bool>()),
            shield_ok: o.get("shield_ok").is_none_or(|v| v.to::<bool>()),
            need: o.get("need").map_or(0, |v| v.to::<i32>().max(0) as u32),
            near_pos: o.get("near_pos").map_or(Vector2::ZERO, |v| v.to::<Vector2>()),
            near_d: f("near_d", f32::INFINITY),
            clip_pos: o.get("clip_pos").map_or(Vec::new(), |v| v.to::<PackedVector2Array>().to_vec()),
            clip_half: f("clip_half", 35f32.to_radians()),
            exclude: o.get("exclude").map_or(Vec::new(), |v| v.to::<PackedVector2Array>().to_vec()),
            exclude_r: f("exclude_r", 0.0),
            forecast: Forecast::from_opts(o),
        }
    }

    /// What reaching `p` from `from`, `d` metres of route, costs: `d`, times away_ratio in
    /// the away cone; None outside both cones or past reach.
    pub(crate) fn cost(&self, from: Vector2, p: Vector2, d: f32) -> Option<f32> {
        if self.near_d.is_finite() && p.distance_to(self.near_pos) >= self.near_d {
            return None;
        }
        if !self.in_clip(from, p) || self.exclude.iter().any(|x| x.distance_to(p) < self.exclude_r) {
            return None;
        }
        if !self.axis.is_finite() || d < 1.0 {
            return (d <= self.reach_m).then_some(d);
        }
        let off = crate::nav::types::angle_difference(self.axis, (p - from).x.atan2((p - from).y)).abs();
        if off <= self.cone_half {
            (d <= self.reach_m).then_some(d)
        } else if std::f32::consts::PI - off <= self.cone_half {
            (d * self.away_ratio <= self.reach_m).then_some(d * self.away_ratio)
        } else {
            None
        }
    }
}

impl CoverArgs {
    /// Whether `p` is inside every clip cone pointed from its enemy at `from`.
    pub(crate) fn in_clip(&self, from: Vector2, p: Vector2) -> bool {
        self.clip_pos.iter().all(|&c| {
            let (a, b) = (from - c, p - c);
            b.length() < 1.0
                || crate::nav::types::angle_difference(a.x.atan2(a.y), b.x.atan2(b.y)).abs() <= self.clip_half
        })
    }
}

/// An enemy this far past its gun range is taken to close it before we leave.
const ADVANCE_M: f32 = 2000.0;
/// Whether, from our arrival at `k` through the hold, some heavy enemy at its forecast
/// position sees `k` (as `safety` reckons seeing) while a `shells` one's guns from there land on it.
pub(crate) fn forecast_exposed(g: &VisibilityGrid, k: usize, inp: &SpotInputs, a: &CoverArgs) -> bool {
    let fc = &a.forecast;
    let Some(fire) = inp.fire.as_ref() else { return false };
    if fc.is_empty() {
        return false;
    }
    let p = g.centres[k];
    let n = inp.enemies.len().min(64);
    let mut at = vec![(Vector2::ZERO, None, false); n];
    for s in fc.window_k(k, p) {
        let mut seen = false;
        for (i, e) in inp.enemies.iter().enumerate().take(n) {
            let q = fc.at(i, s).unwrap_or(e.pos);
            let cq = g.cell_of(q);
            let los = cq.is_none_or(|c| g.visible_idx(k, c));
            at[i] = (q, cq, los);
            let d = p.distance_to(q);
            if !e.heavy || (a.allow_dark && d >= e.det_r.max(e.dark_r)) {
                continue;
            }
            seen = seen || d < e.los_r || los;
        }
        if seen && inp.enemies.iter().enumerate().take(n).any(|(i, e)| {
            let (q, cq, los) = at[i];
            e.heavy && e.shells && fire.hits_at(i, q, cq, p, Some(k), los && cq.is_some())
        }) {
            return true;
        }
    }
    false
}

/// Why cell `k` is safe, as (dark, seen): dark when concealment keeps every
/// threat off it, seen when some threat sees it and an island stops every gun
/// in or near range; None when one of those guns lands. Spotting is the team's:
/// one threat seeing us lays every gun on us. Threats are the `heavy` enemies:
/// det_r is how far each sees us, los_r its radar; only `shells` ones' guns break a shield.
pub(crate) fn safety(g: &VisibilityGrid, k: usize, inp: &SpotInputs, allow_dark: bool) -> Option<(bool, bool)> {
    let p = g.centres[k];
    let (mut dark, mut seen, mut blind) = (true, false, false);
    for (i, e) in inp.enemies.iter().enumerate() {
        if !e.heavy {
            continue;
        }
        let d = p.distance_to(e.pos);
        if allow_dark && d >= e.det_r.max(e.dark_r) {
            continue;
        }
        dark = false;
        if d >= e.los_r && e.cell.is_some_and(|ec| !g.visible_idx(k, ec)) {
            continue;
        }
        seen = true;
        blind = blind || (e.shells && (i >= 64 || inp.fire.as_ref().is_none_or(|f| !f.known(i))));
    }
    if !seen {
        return Some((dark, false));
    }
    if blind {
        return None;
    }
    let Some(f) = inp.fire.as_ref() else { return None };
    // One mask for every enemy: ReachLookup::hits recomputes the whole mask per call.
    let (known, hit) = (f.known_mask(), f.mask(p));
    for (i, e) in inp.enemies.iter().enumerate().take(64) {
        if !e.heavy || !e.shells || known & (1 << i) == 0 {
            continue;
        }
        let d = p.distance_to(e.pos);
        let r = f.range(i);
        if hit & (1 << i) != 0 || (d >= r && d < r + ADVANCE_M) {
            return None;
        }
    }
    Some((dark, true))
}

impl VisibilityGrid {
    /// Water deep enough for the hull, safe (see `safety`), and in reach of `need` targets.
    pub(crate) fn cover_ok(&self, k: usize, inp: &SpotInputs, a: &CoverArgs) -> Option<((bool, bool), u64)> {
        self.cover_ok_at(k, self.centres[k], inp, a)
    }

    /// cover_ok with the shot taken from `p` in cell `k`.
    pub(crate) fn cover_ok_at(&self, k: usize, p: Vector2, inp: &SpotInputs, a: &CoverArgs) -> Option<((bool, bool), u64)> {
        let why = self.cover_safe(k, inp, a)?;
        let mask = if a.need > 0 { self.lead_mask_at(k, p, inp, &a.forecast) } else { 0 };
        (mask.count_ones() >= a.need).then_some((why, mask))
    }

    /// Water deep enough for the hull and safe (see `safety`), now and over the forecast hold.
    fn cover_safe(&self, k: usize, inp: &SpotInputs, a: &CoverArgs) -> Option<(bool, bool)> {
        if self.sdf_c[k] < inp.clearance {
            return None;
        }
        let why = safety(self, k, inp, a.allow_dark)?;
        if (why.1 && !a.shield_ok) || forecast_exposed(self, k, inp, a) {
            return None;
        }
        Some(why)
    }

    /// Whether every water neighbour of `k` deep enough for the hull is safe too: a margin against drift and
    /// the edge errors of the LOS grid and reach model.
    pub(crate) fn cover_deep(&self, k: usize, inp: &SpotInputs, a: &CoverArgs) -> bool {
        let (ix, iz) = self.grid_of(self.centres[k]);
        (-1..=1).all(|dz| (-1..=1).all(|dx| {
            (dx == 0 && dz == 0) || self.water(ix + dx, iz + dz)
                .is_none_or(|n| self.sdf_c[n] < inp.clearance || self.cover_safe(n, inp, a).is_some())
        }))
    }

    /// The nearest of `k`'s safe 2x2 quarters with a shot, by our guns' own check, where the cell has none:
    /// the reach edge is drawn finer than the cells.
    fn cover_quarter(&self, k: usize, inp: &SpotInputs, a: &CoverArgs) -> Option<(Vector2, (bool, bool), u64)> {
        if inp.sim.is_none() || a.need == 0 {
            return None;
        }
        let why = self.cover_safe(k, inp, a)?;
        let c = self.centres[k];
        let off = self.cell * 0.25;
        let mut quarters = [Vector2::new(-off, -off), Vector2::new(off, -off), Vector2::new(-off, off), Vector2::new(off, off)]
            .map(|o| c + o);
        let from = if a.forecast.from.is_finite() { a.forecast.from } else { c };
        quarters.sort_by(|x, y| from.distance_to(*x).total_cmp(&from.distance_to(*y)));
        quarters.into_iter().find_map(|q| {
            let mask = self.lead_mask_at(k, q, inp, &a.forecast);
            (mask.count_ones() >= a.need).then_some((q, why, mask))
        })
    }

    /// Which of cover_ok's tests `k` fails first, for the trace: shallow, fired_on, shielded, forecast, no_target, ok.
    pub(crate) fn cover_why(&self, k: usize, inp: &SpotInputs, a: &CoverArgs) -> GString {
        let why = if self.sdf_c[k] < inp.clearance {
            "shallow"
        } else if let Some(s) = safety(self, k, inp, a.allow_dark) {
            if s.1 && !a.shield_ok {
                "shielded"
            } else if forecast_exposed(self, k, inp, a) {
                "forecast"
            } else if a.need > 0 && self.lead_mask(k, inp, &a.forecast).count_ones() < a.need {
                "no_target"
            } else {
                "ok"
            }
        } else {
            "fired_on"
        };
        GString::from(why)
    }

    /// spotted_mask with each target where the forecast has it when we arrive.
    pub(crate) fn lead_mask(&self, k: usize, inp: &SpotInputs, fc: &Forecast) -> u64 {
        self.lead_mask_at(k, self.centres[k], inp, fc)
    }

    /// lead_mask with the shot taken from `p` in cell `k`: over land on the matrix's reach edge, by our guns' own check.
    pub(crate) fn lead_mask_at(&self, k: usize, p: Vector2, inp: &SpotInputs, fc: &Forecast) -> u64 {
        let Some(reach) = inp.reach.as_ref().filter(|_| !fc.is_empty()) else { return self.spotted_mask(k, inp) };
        let eta = fc.eta_k(k, p);
        let mut mask = 0u64;
        for (i, e) in inp.enemies.iter().enumerate().take(64) {
            if !e.shootable {
                continue;
            }
            let q = fc.at(i, eta).unwrap_or(e.pos);
            let cq = self.cell_of(q);
            let los = cq.is_some_and(|c| self.visible_idx(k, c));
            let edge = !los && inp.sim.is_some()
                && cq.is_some_and(|c| reach.matrix_edge(i, self, k, q, c).is_some_and(|(_, edge)| edge));
            let hit = match (edge, inp.sim.as_ref(), cq) {
                (true, Some(sim), Some(c)) => sim.hits(p, self.centres[c], c),
                _ => reach.hits_at(i, q, cq, p, Some(k), los),
            };
            if hit && (!inp.reach_needs_los || los) {
                mask |= 1u64 << i;
            }
        }
        mask
    }

    /// Metres of water route at our clearance from `from` to each grid water cell within `max_m`, INF beyond.
    pub(crate) fn water_route(&self, from: Vector2, clearance: f32, max_m: f32) -> Vec<f32> {
        use std::cmp::Reverse;
        use std::collections::BinaryHeap;
        let mut dist = vec![f32::INFINITY; self.centres.len()];
        let (ox, oz) = self.grid_of(from);
        let Some(start) = self.water(ox, oz) else { return dist };
        dist[start] = 0.0;
        let mut heap = BinaryHeap::new();
        heap.push(Reverse((0u32, start)));
        while let Some(Reverse((bits, k))) = heap.pop() {
            let d = f32::from_bits(bits);
            if d > dist[k] {
                continue;
            }
            let (ix, iz) = self.grid_of(self.centres[k]);
            for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let Some(n) = self.water(ix + dx, iz + dz) else { continue };
                if self.sdf_c[n] < clearance {
                    continue;
                }
                let nd = d + self.cell * if dx != 0 && dz != 0 { std::f32::consts::SQRT_2 } else { 1.0 };
                if nd < dist[n] && nd <= max_m {
                    dist[n] = nd;
                    heap.push(Reverse((nd.to_bits(), n)));
                }
            }
        }
        dist
    }

    /// `a` timed along the water route from its forecast's origin, so a cell is judged as we would reach it.
    pub(crate) fn routed(&self, a: &CoverArgs, clearance: f32) -> CoverArgs {
        let mut a = a.clone();
        if a.forecast.from.is_finite() {
            a.forecast.route = self.water_route(a.forecast.from, clearance, a.reach_m);
        }
        a
    }

    /// The cheapest deep (cover_deep) safe cell from `from` by water route (CoverArgs::cost), else the cheapest
    /// safe cell or quarter, else a dark one; with whether it is deep, and every cell weighed, by cost.
    pub(crate) fn cover_search_impl(&self, from: Vector2, inp: &SpotInputs, a: &CoverArgs)
        -> (Option<(Vector2, (bool, bool), u64, bool)>, Vec<(f32, usize)>) {
        let mut a = a.clone();
        let route = self.water_route(from, inp.clearance, a.reach_m);
        if !a.forecast.from.is_finite() || a.forecast.from.distance_to(from) < self.cell {
            a.forecast.route = route.clone();
        } else {
            a.forecast.route = self.water_route(a.forecast.from, inp.clearance, a.reach_m * 2.0);
        }
        let a = &a;
        let mut cells: Vec<(f32, usize)> = Vec::new();
        for (k, &d) in route.iter().enumerate() {
            if d.is_finite() {
                if let Some(c) = a.cost(from, self.centres[k], d) {
                    cells.push((c, k));
                }
            }
        }
        cells.sort_by(|x, y| x.0.total_cmp(&y.0));
        let mut deep = None;
        let mut edge = None;
        let mut dark = None;
        for &(_, k) in &cells {
            let whole = self.cover_ok(k, inp, a);
            let hit = whole.map(|(why, m)| (self.centres[k], why, m)).or_else(|| self.cover_quarter(k, inp, a));
            let Some((p, why, m)) = hit else { continue };
            if a.dark_last && why.0 {
                dark = dark.or(Some((p, why, m, false)));
                continue;
            }
            if whole.is_some() && self.cover_deep(k, inp, a) {
                deep = Some((p, why, m, true));
                break;
            }
            edge = edge.or(Some((p, why, m, false)));
        }
        (deep.or(edge).or(dark), cells)
    }
}
