use godot::prelude::*;
use std::collections::HashMap;

use crate::projectile::manager::ev::ev_lookup;

/// Matches BotGunnery.FIRE_VALUE_PER_FIRE.
const FIRE_VALUE_PER_FIRE: f32 = 0.06;
/// Per range sample: descent and pen for each ammo, then half-dispersion h, v.
const CURVE_STRIDE: usize = 6;

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
}

#[derive(Clone, Copy, Default)]
pub(crate) struct Expected {
    pub ap_ev: f32,
    pub he_ev: f32,
    pub he_fire_ev: f32,
    pub ap_dps: f32,
    pub he_dps: f32,
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
}

fn upper(edges: &[f64], x: f64) -> usize {
    edges.partition_point(|e| *e <= x).min(edges.len().saturating_sub(1))
}

/// Matches BotGunnery.ev_bucket_index: the summary lives on even buckets.
fn even(i: usize, n: usize) -> usize {
    (2 * ((i as f64 / 2.0).round() as usize)).min(2 * ((n.max(1) - 1) / 2))
}

impl DamageModel {
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
        Some(Expected { ap_ev, he_ev, he_fire_ev: fire_ev, ap_dps: ap_ev * s.rate, he_dps: he_ev * s.rate })
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
        self.shooters.insert(id, Shooter { step, curve: curve.to_vec(), rate, ammo: [slot(0), slot(1)] });
    }

    /// `ev`: the hull table's "ev" dictionary, bucket id -> chunk.
    #[func]
    fn set_hull(&mut self, id: i64, ev: VarDictionary, max_hp: f32, max_buildup: f32, fire_dps: f32) {
        let chunks = ev
            .iter_shared()
            .filter_map(|(k, v)| Some((k.try_to::<i64>().ok()? as usize, v.try_to::<PackedByteArray>().ok()?.to_vec())))
            .collect();
        self.hulls.insert(id, Hull { chunks, max_hp, max_buildup, fire_dps });
    }

    #[func]
    fn has_shooter(&self, id: i64) -> bool {
        self.shooters.contains_key(&id)
    }

    #[func]
    fn has_hull(&self, id: i64) -> bool {
        self.hulls.contains_key(&id)
    }

    #[func]
    fn forget(&mut self, id: i64) {
        self.shooters.remove(&id);
        self.hulls.remove(&id);
    }

    /// {ap_ev, he_ev, he_fire_ev, ap_dps, he_dps}, or empty when either side is unknown.
    #[func]
    fn get_expected(&self, shooter: i64, hull: i64, range: f32, aspect_deg: f32) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(e) = self.expected(shooter, hull, range, aspect_deg) {
            d.set("ap_ev", e.ap_ev);
            d.set("he_ev", e.he_ev);
            d.set("he_fire_ev", e.he_fire_ev);
            d.set("ap_dps", e.ap_dps);
            d.set("he_dps", e.he_dps);
        }
        d
    }
}
