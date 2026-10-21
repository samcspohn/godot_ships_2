use godot::prelude::*;

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
    pub need: u32,
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
            need: o.get("need").map_or(0, |v| v.to::<i32>().max(0) as u32),
        }
    }

    /// What reaching `p` from `from` costs: its distance, times away_ratio in
    /// the away cone; None outside both cones or past reach.
    pub(crate) fn cost(&self, from: Vector2, p: Vector2) -> Option<f32> {
        let d = from.distance_to(p);
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

/// An enemy this far past its gun range is taken to close it before we leave.
const ADVANCE_M: f32 = 2000.0;

/// Why cell `k` is safe, as (dark, seen): dark when concealment keeps every
/// threat off it, seen when some threat sees it and an island stops every gun
/// in or near range; None when one of those guns lands. Spotting is the team's:
/// one threat seeing us lays every gun on us. Threats are the `heavy` enemies:
/// det_r is how far each sees us, los_r its radar.
pub(crate) fn safety(g: &VisibilityGrid, k: usize, inp: &SpotInputs, allow_dark: bool) -> Option<(bool, bool)> {
    let p = g.centres[k];
    let (mut dark, mut seen, mut blind) = (true, false, false);
    for (i, e) in inp.enemies.iter().enumerate() {
        if !e.heavy {
            continue;
        }
        let d = p.distance_to(e.pos);
        if allow_dark && d >= e.det_r {
            continue;
        }
        dark = false;
        if d >= e.los_r && e.cell.is_some_and(|ec| !g.visible_idx(k, ec)) {
            continue;
        }
        seen = true;
        blind = blind || i >= 64 || inp.fire.as_ref().is_none_or(|f| !f.known(i));
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
        if !e.heavy || known & (1 << i) == 0 {
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
        if self.sdf_c[k] < inp.clearance {
            return None;
        }
        let why = safety(self, k, inp, a.allow_dark)?;
        let mask = if a.need > 0 { self.spotted_mask(k, inp) } else { 0 };
        (mask.count_ones() >= a.need).then_some((why, mask))
    }

    /// The cheapest safe cell from `from` (CoverArgs::cost) and every cell weighed, by cost.
    pub(crate) fn cover_search_impl(&self, from: Vector2, inp: &SpotInputs, a: &CoverArgs)
        -> (Option<(usize, (bool, bool), u64)>, Vec<(f32, usize)>) {
        let r = (a.reach_m / self.cell).ceil() as i32 + 1;
        let (cx, cz) = self.grid_of(from);
        let mut cells: Vec<(f32, usize)> = Vec::new();
        for iz in (cz - r).max(0)..=(cz + r).min(self.h - 1) {
            for ix in (cx - r).max(0)..=(cx + r).min(self.w - 1) {
                if let Some(k) = self.water(ix, iz) {
                    if let Some(c) = a.cost(from, self.centres[k]) {
                        cells.push((c, k));
                    }
                }
            }
        }
        cells.sort_by(|x, y| x.0.total_cmp(&y.0));
        let found = cells.iter().find_map(|&(_, k)| self.cover_ok(k, inp, a).map(|(why, m)| (k, why, m)));
        (found, cells)
    }
}
