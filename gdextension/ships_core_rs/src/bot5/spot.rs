use godot::prelude::*;

use crate::nav::spot_walk::{Enemy, SpotInputs, WalkResult, AVOID_DET, AVOID_DET_SEEN};
use crate::nav::visibility::VisibilityGrid;

const HURT_MARGIN: f32 = 0.25;
const LOOK_M: f32 = 1000.0;
const FIND_INSIDE_M: f32 = 500.0;
pub const LEAD_S: f32 = 10.0;
pub const RUN_OUT_S: f32 = 30.0;
const SENSOR_MARGIN_M: f32 = 500.0;
const REFINE_BUDGET_M: f32 = 8000.0;
/// EnemyPresumption.RADIUS_GROWTH and EXPOSURE_PROBE_MAX.
pub const SPREAD_MPS: f32 = 30.0 * 0.514444 * 2.6 * 0.5;
pub const SPREAD_MAX_M: f32 = 2500.0;
pub const CLAIM_TTL_S: f64 = 6.0;
pub const SIDE_DEADBAND: f32 = 0.35;
pub const MIN_SPREAD_M: f32 = 2000.0;
pub const MIN_SEPARATION_M: f32 = 500.0;

/// v4 SkillPosition's held station.
#[derive(Clone, Copy, Debug)]
pub struct SpotState {
    pub station: Vector2,
    pub count: u32,
}

impl Default for SpotState {
    fn default() -> Self {
        SpotState { station: Vector2::INF, count: 0 }
    }
}

impl SpotState {
    pub fn on(&self) -> bool {
        self.station.is_finite()
    }
}

/// One belief entry as v4 _inputs sees it.
pub struct Entry {
    pub id: Option<i64>,
    pub pos: Vector2,
    pub det: f32,
    pub always: f32,
    pub spot: f32,
    pub mine: bool,
    pub wanted: bool,
}

pub struct Me {
    /// v4 reach_conceal_radius: concealment plus two turning circles.
    pub conceal: f32,
    pub hp_frac: f32,
    pub sensor: f32,
}

impl Me {
    fn margin(&self) -> f32 {
        1.0 + HURT_MARGIN * (1.0 - self.hp_frac.clamp(0.0, 1.0))
    }

    /// A contact: `spread` 0 when seen now.
    pub fn contact(&self, id: i64, pos: Vector2, seen: bool, spread: f32, conceal: f32, force: f32, mine: bool, wanted: bool) -> Entry {
        let m = self.margin();
        let sight = if self.conceal <= conceal { self.conceal } else { 0.0 };
        let sensor = if force > 0.0 { force + SENSOR_MARGIN_M } else { 0.0 };
        let det = (sight.max(sensor) * m - spread).max(0.0);
        let always = if force > 0.0 { (force * m - spread).max(0.0) } else { 0.0 };
        let mut spot = (conceal.max(self.sensor) - FIND_INSIDE_M).max(0.0);
        if !seen {
            spot = (spot - spread).max(det + LOOK_M);
        }
        Entry { id: Some(id), pos, det, always, spot, mine, wanted }
    }

    /// A presumed enemy of unknown identity; `hide` the best concealment it could have.
    pub fn presumed(&self, pos: Vector2, hide: f32, wanted: bool) -> Entry {
        let m = self.margin();
        let (det, spot) = if hide <= 0.0 {
            (self.conceal * m, self.conceal * m + LOOK_M)
        } else {
            let sight = if self.conceal <= hide { self.conceal * m } else { 0.0 };
            (sight, ((hide.max(self.sensor)) - FIND_INSIDE_M).max(sight + LOOK_M))
        };
        Entry { id: None, pos, det, always: 0.0, spot, mine: false, wanted }
    }
}

pub struct Ask<'a> {
    pub vis: &'a VisibilityGrid,
    pub entries: &'a [Entry],
    pub clearance: f32,
    pub flank: Vector2,
    pub danger: Vector2,
    pub here: Vector2,
    /// The last station another mode held.
    pub seed: Vector2,
}

#[derive(Default, Debug)]
pub struct Diag {
    pub held: bool,
    pub snapped: bool,
    pub plus: bool,
    pub fresh: bool,
}

impl Ask<'_> {
    fn inputs(&self, shoot: impl Fn(&Entry) -> bool) -> SpotInputs {
        SpotInputs {
            enemies: self.entries.iter().map(|e| Enemy { pos: e.pos, cell: self.vis.cell_of(e.pos), det_r: e.det, dark_r: 0.0, spot_r: e.spot,
                los_r: e.always, heavy: false, shells: false, shootable: shoot(e) }).collect(),
            clearance: self.clearance,
            avoid: AVOID_DET | AVOID_DET_SEEN,
            los_margin: 0,
            reach: None,
            reach_needs_los: false,
            fire: None,
            value: Vec::new(),
            harm: Vec::new(),
            sim: None,
        }
    }

    fn walk(&self, from: Vector2, toward: Vector2, outward: bool, inp: &SpotInputs, need: u32, budget: f32) -> WalkResult {
        self.vis.spot_walk_impl(from, toward, outward, inp, need, budget, self.flank)
    }

    /// v4 SkillPosition._fresh_walk.
    fn fresh(&self, inp: &SpotInputs) -> WalkResult {
        let mut r: Option<WalkResult> = None;
        if self.seed.is_finite() && self.seed.distance_to(self.here) > 1.0 {
            r = Some(if self.vis.spot_eval_impl(self.seed, inp).0 {
                self.walk(self.seed, self.seed + (self.seed - self.here), false, inp, 1, REFINE_BUDGET_M)
            } else {
                self.walk(self.seed, self.here, true, inp, 1, REFINE_BUDGET_M)
            });
        }
        if r.as_ref().is_none_or(|r| r.start.is_none()) {
            r = Some(self.walk(self.here, self.danger, false, inp, 1, REFINE_BUDGET_M));
        }
        if r.as_ref().is_none_or(|r| r.start.is_none()) {
            r = Some(self.walk(self.danger, self.here, true, inp, 1, REFINE_BUDGET_M));
        }
        r.unwrap()
    }

    /// v4 SkillSpot.execute's search: the held station while it still spots something wanted, re-snapped onto the
    /// zone edge for its count, then walked on for count + 1; else a fresh walk for our own priorities, then for the
    /// team's wanted. Returns the spotted entries' mask.
    pub fn run(&self, st: &mut SpotState, d: &mut Diag) -> Option<u64> {
        let mine = self.entries.iter().any(|e| e.mine);
        let shoot = |e: &Entry| if mine { e.mine } else { e.wanted };
        let mut mask = 0u64;
        if st.on() {
            let any = self.inputs(|e| e.mine || e.wanted);
            let (free, m) = self.vis.spot_eval_impl(st.station, &any);
            if free && m != 0 {
                d.held = true;
                st.count = m.count_ones();
                mask = m;
                let snap = self.walk(st.station, self.danger, false, &any, st.count, REFINE_BUDGET_M);
                if let Some((k, m)) = snap.found.filter(|f| f.1.count_ones() >= st.count) {
                    d.snapped = true;
                    st.station = self.vis.centres[k];
                    mask = m;
                }
                let budget = REFINE_BUDGET_M / 2f32.powi(st.count.saturating_sub(1) as i32);
                if let Some((k, m)) = self.walk(st.station, self.danger, false, &any, st.count + 1, budget).found {
                    d.plus = true;
                    st.station = self.vis.centres[k];
                    st.count = m.count_ones();
                    mask = m;
                }
            } else {
                *st = SpotState::default();
            }
        }
        if !st.on() {
            d.fresh = true;
            let passes: &[bool] = if mine { &[true, false] } else { &[false] };
            for &own in passes {
                let inp = self.inputs(|e| if own { shoot(e) } else { e.wanted });
                if let Some((k, m)) = self.fresh(&inp).found {
                    *st = SpotState { station: self.vis.centres[k], count: m.count_ones() };
                    mask = m;
                    break;
                }
            }
        }
        st.on().then_some(mask)
    }
}

/// v4 SkillPosition._flank_dir: out along our side of the fleet line, zero inside the deadband.
pub fn flank_dir(my: Vector2, allies: &[Vector2], enemy: Option<Vector2>, spawn_fwd: Vector2) -> Vector2 {
    if allies.is_empty() {
        return Vector2::ZERO;
    }
    let fc = allies.iter().copied().sum::<Vector2>() / allies.len() as f32;
    let axis = enemy.map_or(Vector2::ZERO, |e| e - fc);
    let fwd = if axis.length() >= MIN_SEPARATION_M { axis.normalized() } else { spawn_fwd.normalized_or_zero() };
    let right = Vector2::new(fwd.y, -fwd.x);
    let spread = (allies.iter().map(|a| (*a - fc).dot(right).powi(2)).sum::<f32>() / allies.len() as f32).sqrt().max(MIN_SPREAD_M);
    let side = (my - fc).dot(right) / spread;
    if side.abs() < SIDE_DEADBAND { Vector2::ZERO } else { right * side.signum() }
}

/// v4 SkillSpot._run_out: past the station, away from the lit enemy closing on it fastest.
pub fn run_out(lit: &[(Vector2, Vector2)], st: Vector2) -> Vector2 {
    let mut out = Vector2::ZERO;
    for &(p, v) in lit {
        let away = (st - p).normalized_or_zero();
        let closing = v.dot(away);
        if closing > 0.0 && away.length_squared() > 0.0 {
            let r = away * closing * RUN_OUT_S;
            if r.length() > out.length() {
                out = r;
            }
        }
    }
    out
}
