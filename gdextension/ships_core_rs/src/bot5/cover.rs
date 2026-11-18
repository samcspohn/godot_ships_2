//! v4's SkillCover search (nav/cover_search.rs cover_search_impl): the cheapest safe cell by water route, deep first,
//! with a target in reach for offense; cells on the gun matrix's edge and their quarters settled by the island mesh.

use godot::prelude::*;
use std::cell::Cell;
use std::sync::Arc;

use super::field::has;
use super::hive::wrap;
use super::station::{Scan, WINDOW_M};

pub const AWAY_RATIO: f32 = 2.0;
pub const CONE_HALF: f32 = 40.0 * std::f32::consts::PI / 180.0;
pub const CLIP_HALF: f32 = 35.0 * std::f32::consts::PI / 180.0;
/// A station the exact shot refutes is kept out this far.
pub const BLOCK_M: f32 = 300.0;
pub const VERIFY_TRIES: usize = 3;
/// v4 _tuck: a hidden defense station is slid toward its rock in TUCK_STEP_M steps, at most TUCK_MAX_M, to
/// TUCK_MARGIN_M outside the hull's clearance, while the island mesh still hides it.
const TUCK_STEP_M: f32 = 25.0;
const TUCK_MAX_M: f32 = 300.0;
const TUCK_MARGIN_M: f32 = 25.0;
/// v4 _left_cones: a tuck that leaves the cones (by more than the slack, past the near distance) is not taken.
const CONE_HOLD_NEAR_M: f32 = 1000.0;
const CONE_HOLD_SLACK: f32 = 5.0 * std::f32::consts::PI / 180.0;
/// v4: dark water is also this much farther from each enemy than we are now.
const DARK_MARGIN_M: f32 = 500.0;
/// v4 LEAD_SPEED_FRAC.
const LEAD_SPEED: f32 = 0.75;
/// Arriving later than this, a target is aimed at where it will be FORECAST_S ahead.
const LEAD_AHEAD_S: f32 = 30.0;
/// Island-mesh shots per search; past it the matrix answers.
const MESH_BUDGET: u32 = 256;
const NEIGHBOURS: [(i32, i32); 8] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)];

#[derive(Clone, Debug)]
pub struct CoverArgs {
    /// Fires from the station: unseen at its firing bloom, needs a target. Defense: unseen at concealment, shields ok.
    pub offense: bool,
    /// Toward-cone bearing; INF searches every direction at 1x.
    pub axis: f32,
    pub cone_half: f32,
    pub away_ratio: f32,
    /// Only cells nearer than .1 to .0.
    pub near: Option<(Vector2, f32)>,
    /// Enemies that see us: a cell must lie within CLIP_HALF of each one's bearing to `from`.
    pub clip: Vec<Vector2>,
    pub exclude: Vec<(Vector2, f32)>,
    pub shield_ok: bool,
    pub from: Vector2,
    pub deep_only: bool,
    /// Defense: dark water counts, after every hidden or shielded cell.
    pub allow_dark: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct Hit {
    pub station: Vector2,
    pub deep: bool,
    pub dark: bool,
    pub shielded: bool,
    pub targets: u32,
    /// Water-route metres from the search's origin (cover_eval: from us).
    pub route: f32,
}

/// Trace: why weighed cells failed [shallow, seen now, seen ahead, no target, clip/exclude], mesh [hit, miss, over budget].
#[derive(Default, Debug)]
pub struct CoverDiag {
    pub cells: usize,
    pub why: [Cell<u32>; 5],
    pub mesh: [Cell<u32>; 3],
    pub tries: u32,
    pub refuted: Vec<Vector2>,
    pub quarter: bool,
}

fn bump(c: &Cell<u32>) {
    c.set(c.get() + 1);
}

impl Scan<'_> {
    /// v4 CoverArgs::cost: route metres, times away_ratio in the away cone; None outside both cones, past reach, or excluded.
    fn cover_cost(&self, a: &CoverArgs, p: Vector2, d: f32) -> Option<f32> {
        if a.near.is_some_and(|(q, r)| p.distance_to(q) >= r) || !self.in_clip(a, p) || a.exclude.iter().any(|(x, r)| x.distance_to(p) < *r) {
            return None;
        }
        if a.offense && self.past_front(p) {
            return None;
        }
        if !a.axis.is_finite() || d < 1.0 {
            return (d <= WINDOW_M).then_some(d);
        }
        let off = wrap(a.axis - (p - a.from).x.atan2((p - a.from).y)).abs();
        if off <= a.cone_half {
            (d <= WINDOW_M).then_some(d)
        } else if std::f32::consts::PI - off <= a.cone_half {
            (d * a.away_ratio <= WINDOW_M).then_some(d * a.away_ratio)
        } else {
            None
        }
    }

    pub fn in_clip(&self, a: &CoverArgs, p: Vector2) -> bool {
        a.clip.iter().all(|&c| {
            let (u, v) = (a.from - c, p - c);
            v.length() < 1.0 || wrap(u.x.atan2(u.y) - v.x.atan2(v.y)).abs() <= CLIP_HALF
        })
    }

    /// v4 cover_safe / safety: hull-deep and unseen now and ahead, or seen only where no gun lands (shield_ok),
    /// or (allow_dark) dark to every enemy; Some((dark, shielded)).
    /// Off its cell's centre (a quarter or a tuck), `p` itself must be navigable instead of the centre deep.
    fn cover_safe(&self, a: &CoverArgs, k: usize, p: Vector2, d: Option<&CoverDiag>) -> Option<(bool, bool)> {
        let deep = if p == self.vis.centres[k] { self.vis.sdf_c[k] >= self.clearance } else { (self.nav_ok)(p) };
        if !deep {
            d.map(|d| bump(&d.why[0]));
            return None;
        }
        if a.offense {
            for m in 0..2 {
                if has(&self.seen[m][0], k) {
                    d.map(|d| bump(&d.why[1 + m]));
                    return None;
                }
            }
            return Some((false, false));
        }
        let c = self.vis.centres[k];
        let mut dark = true;
        for s in self.field.sources.iter().chain(&self.field.ghosts) {
            let r = s.at.distance_to(c);
            if a.allow_dark && r >= self.conceal.max(s.at.distance_to(self.my) + DARK_MARGIN_M) {
                continue;
            }
            dark = false;
            if r > s.force && !self.vis.visible_idx(s.cell, k) {
                continue;
            }
            if a.shield_ok && self.field.shielded(self.vis, k) {
                return Some((false, true));
            }
            d.map(|d| bump(&d.why[1 + s.ahead as usize]));
            return None;
        }
        Some((dark, false))
    }

    /// v4 cover_deep: every hull-deep neighbour safe too.
    fn cover_deep(&self, a: &CoverArgs, k: usize) -> bool {
        let v = self.vis;
        let (ix, iz) = v.grid_of(v.centres[k]);
        NEIGHBOURS.iter().all(|&(dx, dz)| v.water(ix + dx, iz + dz)
            .is_none_or(|n| v.sdf_c[n] < self.clearance || self.cover_safe(a, n, v.centres[n], None).is_some()))
    }

    fn eta(&self, k: usize, p: Vector2) -> f32 {
        let d = self.route().get(k).copied().filter(|d| d.is_finite()).unwrap_or_else(|| self.my.distance_to(p));
        d / (self.speed * LEAD_SPEED).max(1.0)
    }

    /// What a cover station shoots: foes in our field where they will be when we arrive, else the presumed and lost
    /// enemies and the flank centre (v4's refs).
    fn cover_targets(&self, eta: f32) -> Vec<(Vector2, Option<&Arc<[u64]>>)> {
        let m = (eta >= LEAD_AHEAD_S) as usize;
        if self.foes.is_empty() {
            self.aims.iter().map(|(q, c)| (*q, Some(c))).collect()
        } else {
            self.foes.iter().map(|f| (f.at[m].at, f.at[m].col.as_ref())).collect()
        }
    }

    fn mesh(&self, p: Vector2, q: Vector2, d: Option<&CoverDiag>, used: &Cell<u32>) -> Option<bool> {
        let (isl, arc) = (self.island?, self.arc.as_ref()?);
        if used.get() >= MESH_BUDGET {
            d.map(|d| bump(&d.mesh[2]));
            return None;
        }
        used.set(used.get() + 1);
        let s = isl.shot(arc, p, q);
        d.map(|d| bump(&d.mesh[if s { 0 } else { 1 }]));
        Some(s)
    }

    /// v4 lead_mask_at: targets the matrix says we hit from cell k; on its edge (a neighbour disagrees) or from a
    /// quarter, the island mesh says.
    fn lead(&self, k: usize, p: Vector2, d: Option<&CoverDiag>, used: &Cell<u32>) -> u32 {
        let v = self.vis;
        let (ix, iz) = v.grid_of(v.centres[k]);
        let centre = p == v.centres[k];
        self.cover_targets(self.eta(k, p)).into_iter().filter(|&(q, col)| {
            let Some(col) = col.filter(|_| p.distance_to(q) <= self.reach) else { return false };
            let here = has(col, k);
            let edge = !centre || NEIGHBOURS.iter().any(|&(dx, dz)| v.water(ix + dx, iz + dz).is_some_and(|n| has(col, n) != here));
            if edge { self.mesh(p, q, d, used).unwrap_or(here) } else { here }
        }).count() as u32
    }

    /// The exact check v4 ran on each found station: navigable, and the island mesh clears a shell onto some target.
    fn cover_exact(&self, p: Vector2) -> bool {
        let (Some(isl), Some(arc)) = (self.island, self.arc.as_ref()) else { return false };
        (self.nav_ok)(p) && self.cover_targets(self.eta(self.vis.cell_of(p).unwrap_or(0), p)).iter()
            .any(|&(q, _)| p.distance_to(q) <= self.reach && isl.shot(arc, p, q))
    }

    /// A quarter is nearer the rock than its cell centre: its own sight lines from every enemy that could see it.
    fn mesh_hidden(&self, a: &CoverArgs, q: Vector2) -> bool {
        let Some(isl) = self.island else { return false };
        let r = if a.offense { self.reach.max(self.conceal) } else { self.conceal };
        self.field.sources.iter().chain(&self.field.ghosts).all(|s| s.at.distance_to(q) > r || !isl.los(s.at, q))
    }

    /// v4 cover_ok_at: safe, and (offense) a target in reach from `p`.
    fn cover_ok_at(&self, a: &CoverArgs, k: usize, p: Vector2, d: Option<&CoverDiag>, used: &Cell<u32>) -> Option<Hit> {
        let (dark, shielded) = self.cover_safe(a, k, p, d)?;
        let targets = if a.offense { self.lead(k, p, d, used) } else { 0 };
        if a.offense && targets == 0 {
            d.map(|d| bump(&d.why[3]));
            return None;
        }
        Some(Hit { station: p, deep: false, dark, shielded, targets, route: f32::INFINITY })
    }

    /// v4 cover_quarter: the nearest hidden, hull-deep quarter of a safe cell with a target, where the centre has none.
    fn cover_quarter(&self, a: &CoverArgs, k: usize, used: &Cell<u32>) -> Option<Hit> {
        if !a.offense || self.cover_safe(a, k, self.vis.centres[k], None).is_none() {
            return None;
        }
        let (c, off) = (self.vis.centres[k], self.vis.cell * 0.25);
        let mut qs = [(-off, -off), (off, -off), (-off, off), (off, off)].map(|(x, z)| c + Vector2::new(x, z));
        qs.sort_by(|x, y| a.from.distance_to(*x).total_cmp(&a.from.distance_to(*y)));
        qs.into_iter().filter(|&q| (self.nav_ok)(q) && self.mesh_hidden(a, q)).find_map(|q| self.cover_ok_at(a, k, q, None, used))
    }

    /// v4 cover_search_impl: cells by route cost from `a.from`; the first deep safe one, else the first safe cell or quarter,
    /// else the first dark one.
    pub fn cover_search(&self, a: &CoverArgs, d: &mut CoverDiag) -> Option<Hit> {
        let own;
        let route: &[f32] = if a.from.distance_to(self.my) < self.vis.cell { self.route() } else {
            own = self.vis.water_route(a.from, self.clearance, WINDOW_M);
            &own
        };
        let mut cells: Vec<(f32, usize)> = route.iter().enumerate().filter(|(_, r)| r.is_finite())
            .filter_map(|(k, &r)| match self.cover_cost(a, self.vis.centres[k], r) {
                Some(c) => Some((c, k)),
                None => {
                    bump(&d.why[4]);
                    None
                }
            }).collect();
        cells.sort_by(|x, y| x.0.total_cmp(&y.0));
        d.cells = cells.len();
        let used = Cell::new(0);
        let (mut edge, mut dark) = (None, None);
        for &(_, k) in &cells {
            let whole = self.cover_ok_at(a, k, self.vis.centres[k], Some(d), &used).map(|h| Hit { route: route[k], ..h });
            if let Some(h) = whole.filter(|h| h.dark) {
                dark = dark.or(Some(h));
                continue;
            }
            if let Some(h) = whole.filter(|_| self.cover_deep(a, k)) {
                return Some(Hit { deep: true, ..h });
            }
            if edge.is_none() && !a.deep_only {
                edge = whole.or_else(|| self.cover_quarter(a, k, &used).map(|h| Hit { route: route[k], ..h }));
            }
        }
        d.quarter = edge.is_some_and(|h| self.vis.cell_of(h.station).is_some_and(|k| self.vis.centres[k] != h.station));
        edge.or(dark)
    }

    fn tuck(&self, a: &CoverArgs, mut p: Vector2) -> Vector2 {
        let stop = self.clearance + TUCK_MARGIN_M;
        let (mut best, mut moved) = (p, 0.0);
        let (dx, dz, land) = (Vector2::new(TUCK_STEP_M, 0.0), Vector2::new(0.0, TUCK_STEP_M), self.land);
        while moved < TUCK_MAX_M {
            let g = Vector2::new(land(p + dx) - land(p - dx), land(p + dz) - land(p - dz));
            if land(p) - TUCK_STEP_M < stop || g.length_squared() < 1e-6 {
                break;
            }
            p -= g.normalized() * TUCK_STEP_M;
            moved += TUCK_STEP_M;
            if !self.mesh_hidden(a, p) {
                break;
            }
            best = p;
        }
        best
    }

    fn left_cones(a: &CoverArgs, st: Vector2) -> bool {
        if !a.axis.is_finite() || a.from.distance_to(st) < CONE_HOLD_NEAR_M {
            return false;
        }
        let off = wrap(a.axis - (st - a.from).x.atan2((st - a.from).y)).abs();
        let half = a.cone_half + CONE_HOLD_SLACK;
        off > half && std::f32::consts::PI - off > half
    }

    /// The search with v4's rescan: a station the exact shot refutes is excluded and searched again, VERIFY_TRIES in all.
    /// A defense station that is not dark is tucked.
    pub fn cover(&self, a: &CoverArgs, d: &mut CoverDiag) -> Option<Hit> {
        let mut a = a.clone();
        for _ in 0..VERIFY_TRIES {
            d.tries += 1;
            let h = self.cover_search(&a, d)?;
            if !a.offense {
                let t = if h.dark { h.station } else { self.tuck(&a, h.station) };
                return Some(Hit { station: if Self::left_cones(&a, t) { h.station } else { t }, ..h });
            }
            if self.cover_exact(h.station) {
                return Some(h);
            }
            d.refuted.push(h.station);
            a.exclude.push((h.station, BLOCK_M));
        }
        None
    }

    /// v4 cover_eval on a held station; Err names the hard test it fails, Ok's third the soft one (offense: seen
    /// ahead, no target). `shot`: the exact check from where it is.
    pub fn cover_eval(&self, a: &CoverArgs, p: Vector2) -> Result<(Hit, bool, Option<&'static str>), &'static str> {
        let k = self.vis.cell_of(p).ok_or("off_grid")?;
        let d = CoverDiag::default();
        let used = Cell::new(0);
        if p != self.vis.centres[k] && !self.mesh_hidden(a, p) {
            return Err("seen_quarter");
        }
        let shot = !a.offense || self.cover_exact(p);
        if let Some(h) = self.cover_ok_at(a, k, p, Some(&d), &used) {
            let deep = self.cover_deep(a, k);
            // Only a station that may be traded (edge) needs its cost.
            let route = if deep { f32::INFINITY } else { self.route()[k] };
            return Ok((Hit { deep, route, ..h }, shot, None));
        }
        let route = self.route()[k];
        let why = ["shallow", "seen", "seen_ahead", "no_target", "?"][d.why.iter().position(|c| c.get() > 0).unwrap_or(4)];
        if !a.offense || !matches!(why, "seen_ahead" | "no_target") {
            return Err(why);
        }
        let targets = if why == "no_target" { 0 } else { self.lead(k, p, None, &used) };
        Ok((Hit { station: p, deep: false, dark: false, shielded: false, targets, route }, shot, Some(why)))
    }
}
