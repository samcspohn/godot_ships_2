use godot::prelude::*;
use std::collections::HashMap;

use crate::projectile::manager::ev::{ev_levels, ev_lookup};

/// HpParams defaults: light, pen, citadel repair.
const DEFAULT_REPAIR: [f32; 3] = [0.95, 0.5, 0.15];
/// Matches BotGunnery.FIRE_VALUE_PER_FIRE.
const FIRE_VALUE_PER_FIRE: f32 = 0.06;
/// Per range sample: descent and pen for each ammo, then half-dispersion h, v.
const CURVE_STRIDE: usize = 6;
const GRID_RANGE_STEP_M: f32 = 500.0;
const GRID_ASPECT_STEP_DEG: f32 = 15.0;
const GRID_ASPECTS: usize = 13;

struct Ammo {
    overmatch: f32,
    is_he: bool,
    damage: f32,
    fire_buildup: f32,
}

struct Shooter {
    step: f32,
    curve: Vec<f32>,
    rate: f32,
    ammo: [Option<Ammo>; 2],
}

struct Hull {
    /// Baked chunks by aspect bucket * n_descent + descent bucket.
    chunks: HashMap<usize, Vec<u8>>,
    max_hp: f32,
    max_buildup: f32,
    fire_dps: f32,
    /// Repairable share of light, medium and heavy damage (HpParams).
    repair: [f32; 3],
}

/// dps of one shooter on one hull by range and aspect, sampled off expected().
pub(crate) struct DpsGrid {
    rows: usize,
    dps: Vec<f32>,
}

impl DpsGrid {
    /// 0 beyond the shooter's range; `aspect_deg` in [0, 180], 0 bow-on.
    pub(crate) fn at(&self, range: f32, aspect_deg: f32) -> f32 {
        let r = (range / GRID_RANGE_STEP_M).round() as usize;
        if r >= self.rows {
            return 0.0;
        }
        let a = (aspect_deg.clamp(0.0, 180.0) / GRID_ASPECT_STEP_DEG).min((GRID_ASPECTS - 1) as f32);
        let (a0, f) = (a.floor() as usize, a.fract());
        let a1 = (a0 + 1).min(GRID_ASPECTS - 1);
        let row = &self.dps[r * GRID_ASPECTS..(r + 1) * GRID_ASPECTS];
        row[a0] + (row[a1] - row[a0]) * f
    }
}

#[derive(Clone, Copy, Default)]
pub(crate) struct Expected {
    pub ap_ev: f32,
    pub he_ev: f32,
    pub he_fire_ev: f32,
    pub ap_dps: f32,
    pub he_dps: f32,
    /// Shares of ap_dps / he_dps a repair party can win back.
    pub ap_heal: f32,
    pub he_heal: f32,
}

impl Expected {
    pub(crate) fn dps(&self) -> f32 {
        self.ap_dps.max(self.he_dps)
    }
}

/// BotGunnery.expected() with every per-call input prepared once, for
/// callers that ask many times per tick.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct DamageModel {
    base: Base<RefCounted>,
    aspect_edges: Vec<f64>,
    descent_edges: Vec<f64>,
    bucket_stride: usize,
    shooters: HashMap<i64, Shooter>,
    hulls: HashMap<i64, Hull>,
    grids: HashMap<(i64, i64), DpsGrid>,
}

fn upper(edges: &[f64], x: f64) -> usize {
    edges.partition_point(|e| *e <= x).min(edges.len().saturating_sub(1))
}

/// Matches BotGunnery.ev_bucket_index: the summary lives on even buckets.
fn even(i: usize, n: usize) -> usize {
    (2 * ((i as f64 / 2.0).round() as usize)).min(2 * ((n.max(1) - 1) / 2))
}

impl DamageModel {
    pub(crate) fn grid(&self, shooter: i64, hull: i64) -> Option<&DpsGrid> {
        self.grids.get(&(shooter, hull))
    }

    /// Builds the pair's grid once; false when either side is unknown.
    pub(crate) fn ensure_grid(&mut self, shooter: i64, hull: i64) -> bool {
        if !self.grids.contains_key(&(shooter, hull)) {
            let (Some(s), Some(_)) = (self.shooters.get(&shooter), self.hulls.get(&hull)) else { return false };
            let top = s.step * (s.curve.len() / CURVE_STRIDE) as f32;
            let rows = (top / GRID_RANGE_STEP_M) as usize + 1;
            let mut dps = Vec::with_capacity(rows * GRID_ASPECTS);
            for r in 0..rows {
                for a in 0..GRID_ASPECTS {
                    let e = self.expected(shooter, hull, (r as f32 * GRID_RANGE_STEP_M).max(s.step), a as f32 * GRID_ASPECT_STEP_DEG);
                    dps.push(e.map_or(0.0, |e| e.dps()));
                }
            }
            self.grids.insert((shooter, hull), DpsGrid { rows, dps });
        }
        true
    }

    pub(crate) fn expected(&self, shooter: i64, hull: i64, range: f32, aspect_deg: f32) -> Option<Expected> {
        let (s, h) = (self.shooters.get(&shooter)?, self.hulls.get(&hull)?);
        let n_asp = self.aspect_edges.len();
        let n_desc = self.descent_edges.len();
        if n_asp == 0 || n_desc == 0 || s.step <= 0.0 {
            return None;
        }
        let rows = s.curve.len() / CURVE_STRIDE;
        let t = range / s.step - 1.0;
        if rows == 0 || t > rows as f32 {
            return None;
        }
        let i0 = (t.floor().max(0.0) as usize).min(rows - 1);
        let i1 = (i0 + 1).min(rows - 1);
        let f = (t - i0 as f32).clamp(0.0, 1.0);
        let at = |k: usize| s.curve[i0 * CURVE_STRIDE + k] + (s.curve[i1 * CURVE_STRIDE + k] - s.curve[i0 * CURVE_STRIDE + k]) * f;
        let ai = even(upper(&self.aspect_edges, aspect_deg as f64), n_asp);
        let (hd_h, hd_v) = (at(4), at(5));
        let mut value = [0.0f32; 2];
        let mut heal = [h.repair[1]; 2];
        let mut landed_he = 0.0f32;
        for (k, ammo) in s.ammo.iter().enumerate() {
            let Some(a) = ammo else { continue };
            let (desc, pen) = (at(2 * k), at(2 * k + 1));
            if !desc.is_finite() || desc as f64 > self.descent_edges[n_desc - 1] {
                continue;
            }
            let di = even(upper(&self.descent_edges, desc as f64), n_desc);
            let Some(chunk) = h.chunks.get(&(ai * self.bucket_stride + di)) else { continue };
            let Some((v, l)) = ev_lookup(chunk, pen as f64, a.overmatch as f64, a.is_he, hd_h, hd_v) else { continue };
            value[k] = v * a.damage;
            if let Some((heavy, medium)) = ev_levels(chunk, pen as f64, a.overmatch as f64, a.is_he, hd_h, hd_v) {
                let light = (1.0 - heavy - medium).max(0.0);
                heal[k] = light * h.repair[0] + medium * h.repair[1] + heavy * h.repair[2];
            }
            if k == 1 {
                landed_he = l;
            }
        }
        let ap_ev = value[0];
        let mut fire_ev = s.ammo[1].as_ref().map_or(0.0, |a| {
            let chance = if h.max_buildup > 0.0 { (a.fire_buildup / h.max_buildup).clamp(0.0, 1.0) } else { 0.0 };
            chance * landed_he * h.max_hp * FIRE_VALUE_PER_FIRE
        });
        if h.fire_dps > 0.0 && ap_ev > 0.0 {
            fire_ev *= (h.fire_dps / (ap_ev * s.rate)).clamp(0.0, 1.0);
        }
        let he_ev = value[1] + fire_ev;
        let he_heal = if he_ev > 0.0 { (value[1] * heal[1] + fire_ev * h.repair[0]) / he_ev } else { heal[1] };
        Some(Expected { ap_ev, he_ev, he_fire_ev: fire_ev, ap_dps: ap_ev * s.rate, he_dps: he_ev * s.rate,
            ap_heal: heal[0], he_heal })
    }
}

#[godot_api]
impl DamageModel {
    /// BotGunnery's aspect and descent bucket edges, in degrees.
    #[func]
    fn set_edges(&mut self, aspect: PackedFloat64Array, descent: PackedFloat64Array) {
        self.aspect_edges = aspect.to_vec();
        self.descent_edges = descent.to_vec();
        // BotGunnery.bucket_id is aspect * 64 + descent.
        self.bucket_stride = 64;
    }

    /// `curve`: per `step` metres from `step`, [desc0, pen0, desc1, pen1, half_h, half_v]
    /// (NaN for a missing ammo). `ammo`: [overmatch, is_he, damage, fire_buildup] x 2,
    /// damage <= 0 where the slot is empty. `rate`: shells per second.
    #[func]
    fn set_shooter(&mut self, id: i64, step: f32, curve: PackedFloat32Array, rate: f32, ammo: PackedFloat32Array) {
        let a = ammo.as_slice();
        let slot = |k: usize| -> Option<Ammo> {
            let b = &a.get(4 * k..4 * k + 4)?;
            (b[2] > 0.0).then(|| Ammo { overmatch: b[0], is_he: b[1] != 0.0, damage: b[2], fire_buildup: b[3] })
        };
        self.grids.retain(|k, _| k.0 != id);
        self.shooters.insert(id, Shooter { step, curve: curve.to_vec(), rate, ammo: [slot(0), slot(1)] });
    }

    /// `ev`: the hull table's "ev" dictionary, bucket id -> chunk.
    #[func]
    fn set_hull(&mut self, id: i64, ev: VarDictionary, max_hp: f32, max_buildup: f32, fire_dps: f32) {
        let chunks = ev
            .iter_shared()
            .filter_map(|(k, v)| Some((k.try_to::<i64>().ok()? as usize, v.try_to::<PackedByteArray>().ok()?.to_vec())))
            .collect();
        self.grids.retain(|k, _| k.1 != id);
        let repair = self.hulls.get(&id).map_or(DEFAULT_REPAIR, |h| h.repair);
        self.hulls.insert(id, Hull { chunks, max_hp, max_buildup, fire_dps, repair });
    }

    /// Repairable shares of light, medium and heavy damage on hull `id` (HpParams).
    #[func]
    fn set_repair(&mut self, id: i64, light: f32, medium: f32, heavy: f32) {
        if let Some(h) = self.hulls.get_mut(&id) {
            h.repair = [light, medium, heavy];
        }
    }

    #[func]
    fn has_shooter(&self, id: i64) -> bool {
        self.shooters.contains_key(&id)
    }

    #[func]
    fn has_hull(&self, id: i64) -> bool {
        self.hulls.contains_key(&id)
    }

    /// Builds every pair's dps grid among `ids` (shooter != hull) now, so the
    /// first engagement does not stall a frame building them.
    #[func]
    fn warm_grids(&mut self, ids: PackedInt64Array) {
        for &a in ids.as_slice() {
            for &b in ids.as_slice() {
                if a != b {
                    self.ensure_grid(a, b);
                }
            }
        }
    }

    #[func]
    fn forget(&mut self, id: i64) {
        self.shooters.remove(&id);
        self.hulls.remove(&id);
        self.grids.retain(|k, _| k.0 != id && k.1 != id);
    }

    /// {ap_ev, he_ev, he_fire_ev, ap_dps, he_dps, ap_heal, he_heal}, or empty when either side is unknown.
    #[func]
    fn get_expected(&self, shooter: i64, hull: i64, range: f32, aspect_deg: f32) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(e) = self.expected(shooter, hull, range, aspect_deg) {
            d.set("ap_ev", e.ap_ev);
            d.set("he_ev", e.he_ev);
            d.set("he_fire_ev", e.he_fire_ev);
            d.set("ap_dps", e.ap_dps);
            d.set("he_dps", e.he_dps);
            d.set("ap_heal", e.ap_heal);
            d.set("he_heal", e.he_heal);
        }
        d
    }
}
