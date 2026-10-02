use godot::prelude::*;
use crate::variant_cast::VariantCast;
use std::cmp::Reverse;
use std::collections::BinaryHeap;

use crate::nav::spot_walk::{SpotInputs, AVOID_DET, AVOID_LOS};
use crate::nav::visibility::VisibilityGrid;
use crate::projectile::damage_model::{DamageModel, DpsGrid};

/// The target's presentation is unknown; a typical angle between bow-on and broadside.
const OUT_ASPECT_DEG: f32 = 60.0;
const DIRS8: [(i32, i32); 8] = [(1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (-1, -1), (1, -1)];

pub(crate) struct SweepArgs {
    pub from: Vector2,
    pub box_m: f32,
    pub speed: f32,
    pub my_hp: f32,
    pub me: i64,
    pub ids: Vec<i64>,
    /// Value of one point of damage on each enemy.
    pub prio: Vec<f32>,
    /// Inside this, with line of sight, an enemy lights us for its team.
    pub seen_r: Vec<f32>,
    pub pref_range: f32,
    pub gun_range: f32,
    pub hold_s: f32,
    pub need: u32,
    /// Bit per enemy currently in sight; only these count as targets.
    pub live: u64,
    /// Targets that stay lit (battleships); reaching one raises the gain by w_sticky.
    pub sticky: u64,
    pub w_sticky: f32,
    pub allow_hard: bool,
    pub w_gain: f32,
    pub w_risk: f32,
    pub w_time: f32,
    pub w_range: f32,
    pub w_hard: f32,
    pub held: Option<Vector2>,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct Pick {
    pub k: usize,
    pub score: f32,
    pub gain: f32,
    pub risk: f32,
    pub time: f32,
    pub mask: u64,
    pub hard: bool,
}

#[derive(Default)]
pub(crate) struct SweepResult {
    pub best: Option<Pick>,
    pub held: Option<Pick>,
    /// Cheapest cell no enemy lights.
    pub dark: Option<Pick>,
    pub cells: u32,
}

fn aspect_deg(heading: Vector2, to: Vector2) -> f32 {
    let (a, b) = (heading.normalized(), to.normalized());
    a.dot(b).clamp(-1.0, 1.0).acos().to_degrees()
}

impl VisibilityGrid {
    /// Dijkstra over water from `from`, pricing each step by time and by the
    /// damage lit enemies' fire would do at the aspect the step presents;
    /// every settled cell hidden (or, with allow_hard, out of heavy fire) and
    /// reaching `need` targets is scored as gain - cost.
    pub(crate) fn cover_sweep_impl(&self, inp: &SpotInputs, a: &SweepArgs, dm: &DamageModel) -> SweepResult {
        let mut res = SweepResult::default();
        let Some(start) = self.cell_of(a.from) else { return res };
        let (sx, sz) = self.grid_of(self.centres[start]);
        let r = (a.box_m / self.cell).ceil() as i32;
        let lw = 2 * r + 1;
        let local = |ix: i32, iz: i32| -> Option<usize> {
            let (lx, lz) = (ix - sx + r, iz - sz + r);
            (lx >= 0 && lz >= 0 && lx < lw && lz < lw).then(|| (lz * lw + lx) as usize)
        };
        let n = (lw * lw) as usize;
        let (mut cost, mut risk, mut time) = (vec![f32::INFINITY; n], vec![0f32; n], vec![0f32; n]);
        let mut lit = vec![-1i8; n];
        let mut done = vec![false; n];
        let dps_in: Vec<Option<&DpsGrid>> = a.ids.iter().map(|&id| dm.grid(id, a.me)).collect();
        let dps_out: Vec<Option<&DpsGrid>> = a.ids.iter().map(|&id| dm.grid(a.me, id)).collect();
        let speed = a.speed.max(1.0);
        let hp = a.my_hp.max(1.0);
        let pass = |k: usize| self.sdf_c[k] >= inp.clearance || k == start;
        let lit_at = |k: usize| -> bool {
            let p = self.centres[k];
            inp.enemies.iter().enumerate().any(|(i, e)| {
                let d2 = p.distance_squared_to(e.pos);
                d2 < e.det_r * e.det_r
                    || e.cell.is_some_and(|ec| {
                        let s = a.seen_r.get(i).copied().unwrap_or(0.0);
                        d2 <= s * s && self.visible_idx(k, ec)
                    })
            })
        };
        let held_k = a.held.and_then(|p| self.cell_of(p));

        let l0 = local(sx, sz).unwrap();
        cost[l0] = 0.0;
        let mut heap = BinaryHeap::new();
        heap.push(Reverse((0u32, start)));
        while let Some(Reverse((cb, k))) = heap.pop() {
            let (gx, gz) = self.grid_of(self.centres[k]);
            let Some(l) = local(gx, gz) else { continue };
            if done[l] || f32::from_bits(cb) > cost[l] {
                continue;
            }
            done[l] = true;
            res.cells += 1;
            if lit[l] < 0 {
                lit[l] = lit_at(k) as i8;
            }
            let here = Pick { k, score: f32::NEG_INFINITY, gain: 0.0, risk: risk[l], time: time[l], mask: 0, hard: false };
            if res.dark.is_none() && lit[l] == 0 {
                res.dark = Some(Pick { score: -cost[l], ..here });
            }
            let hold = if lit[l] == 1 { self.hold_dps(inp, &dps_in, k) * a.hold_s / hp } else { 0.0 };
            if let Some(p) = self.score_cell(inp, a, &dps_out, (gx, gz), here, cost[l] + a.w_risk * hold) {
                // The held station outlives a target ducking out of sight; SkillCover times it out.
                if held_k == Some(k) {
                    res.held = Some(p);
                }
                if p.mask.count_ones() >= a.need && res.best.is_none_or(|b| p.score > b.score) {
                    res.best = Some(p);
                }
            }

            for (j, &(dx, dz)) in DIRS8.iter().enumerate() {
                let (nx, nz) = (gx + dx, gz + dz);
                let (Some(q), Some(lq)) = (self.water(nx, nz), local(nx, nz)) else { continue };
                if done[lq] || !pass(q) {
                    continue;
                }
                if j >= 4 && !(self.water(gx + dx, gz).is_some_and(pass) && self.water(gx, gz + dz).is_some_and(pass)) {
                    continue;
                }
                let step = Vector2::new(dx as f32, dz as f32);
                let dt = step.length() * self.cell / speed;
                if lit[lq] < 0 {
                    lit[lq] = lit_at(q) as i8;
                }
                let mut dps = 0.0;
                if lit[lq] == 1 {
                    let c = self.centres[q];
                    for (i, e) in inp.enemies.iter().enumerate() {
                        let Some(g) = dps_in[i] else { continue };
                        if inp.fire.as_ref().is_some_and(|f| !f.hits(i, c)) {
                            continue;
                        }
                        dps += g.at(c.distance_to(e.pos), aspect_deg(step, e.pos - c));
                    }
                }
                let dmg = dps * dt / hp;
                let nc = cost[l] + a.w_time * dt / 60.0 + a.w_risk * dmg;
                if nc < cost[lq] {
                    cost[lq] = nc;
                    risk[lq] = risk[l] + dmg;
                    time[lq] = time[l] + dt;
                    heap.push(Reverse((nc.to_bits(), q)));
                }
            }
        }
        res
    }

    /// Incoming dps at cell `k` presenting the better end to each shooter that can land shells there.
    fn hold_dps(&self, inp: &SpotInputs, dps_in: &[Option<&DpsGrid>], k: usize) -> f32 {
        let c = self.centres[k];
        inp.enemies.iter().enumerate().filter_map(|(i, e)| {
            let g = dps_in[i]?;
            if inp.fire.as_ref().is_some_and(|f| !f.hits(i, c)) {
                return None;
            }
            let r = c.distance_to(e.pos);
            Some(g.at(r, 0.0).min(g.at(r, 180.0)))
        }).sum()
    }

    fn score_cell(&self, inp: &SpotInputs, a: &SweepArgs, dps_out: &[Option<&DpsGrid>], g: (i32, i32), here: Pick, cost: f32) -> Option<Pick> {
        let concealed = !self.in_zone_of(g, inp, AVOID_DET | AVOID_LOS);
        let c = self.centres[here.k];
        // Spotting's AVOID_FIRE counts heavy shooters only; cover must be out of every gun.
        let hard = !concealed && a.allow_hard
            && inp.fire.as_ref().is_some_and(|f| (0..inp.enemies.len()).all(|i| f.known(i) && !f.hits(i, c)));
        if !concealed && !hard {
            return None;
        }
        let mask = self.spotted_mask(here.k, inp) & a.live;
        // One battery, one target: a cell is worth its best target, not the crowd it can see.
        let (mut top, mut top_range) = (0.0, 0.0);
        for (i, e) in inp.enemies.iter().enumerate().take(64) {
            if mask & (1 << i) == 0 {
                continue;
            }
            let range = c.distance_to(e.pos);
            let v = a.prio.get(i).copied().unwrap_or(0.0) * dps_out[i].map_or(0.0, |d| d.at(range, OUT_ASPECT_DEG));
            if v > top {
                (top, top_range) = (v, range);
            }
        }
        let gain = top * a.hold_s * if mask & a.sticky != 0 { 1.0 + a.w_sticky } else { 1.0 };
        let range_err = if a.pref_range > 0.0 && top > 0.0 { (top_range - a.pref_range).abs() / a.gun_range.max(1.0) } else { 0.0 };
        let score = a.w_gain * gain - cost - a.w_range * range_err - if hard { a.w_hard } else { 0.0 };
        Some(Pick { score, gain, mask, hard, ..here })
    }
}

pub(crate) fn pick_dict(d: &mut VarDictionary, key: &str, p: Option<Pick>, centres: &[Vector2]) {
    let Some(p) = p else {
        d.set(key, &VarDictionary::new());
        return;
    };
    let mut o = VarDictionary::new();
    o.set("pos", centres[p.k]);
    o.set("score", p.score);
    o.set("gain", p.gain);
    o.set("risk", p.risk);
    o.set("time", p.time);
    o.set("mask", p.mask as i64);
    o.set("count", p.mask.count_ones() as i64);
    o.set("hard", p.hard);
    d.set(key, &o);
}

pub(crate) fn sweep_args(from: Vector2, o: &VarDictionary, dm: &mut DamageModel) -> SweepArgs {
    let f = |k: &str, def: f32| o.get(k).map_or(def, |v| v.to_f32());
    let f32s = |k: &str| o.get(k).and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default().to_vec();
    let ids = o.get("ids").and_then(|v| v.try_to::<PackedInt64Array>().ok()).unwrap_or_default().to_vec();
    let me = o.get("me").map_or(0, |v| v.to_i64());
    let bits = |k: &str| o.get(k).and_then(|v| v.try_to::<PackedByteArray>().ok()).unwrap_or_default().as_slice().iter()
        .take(64).enumerate().fold(0u64, |m, (i, &b)| if b != 0 { m | 1 << i } else { m });
    for &id in &ids {
        dm.ensure_grid(id, me);
        dm.ensure_grid(me, id);
    }
    SweepArgs {
        from,
        box_m: f("box_m", 8000.0),
        speed: f("speed", 15.0),
        my_hp: f("my_hp", 1.0),
        me,
        ids,
        prio: f32s("prio"),
        seen_r: f32s("seen_r"),
        pref_range: f("pref_range", 0.0),
        gun_range: f("gun_range", 1.0),
        hold_s: f("hold_s", 60.0),
        need: o.get("need").map_or(1, |v| v.to_i32()).max(0) as u32,
        live: bits("live"),
        sticky: bits("sticky"),
        w_sticky: f("w_sticky", 0.0),
        allow_hard: o.get("allow_hard").is_some_and(|v| v.to::<bool>()),
        w_gain: f("w_gain", 1.0),
        w_risk: f("w_risk", 1.0),
        w_time: f("w_time", 0.1),
        w_range: f("w_range", 0.0),
        w_hard: f("w_hard", 0.0),
        held: o.get("held").and_then(|v| v.try_to::<Vector2>().ok()).filter(|p| p.is_finite()),
    }
}
