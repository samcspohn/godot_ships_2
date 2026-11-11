//! Secondary dps from the secondary point tables (BotBehavior._secondary_dps), cached per cell, and SkillStance's duel
//! secondaries along a track. A pair without a pack, or whose tables are not built, comes back missing for GDScript.

use std::collections::{HashMap, HashSet};
use std::f64::consts::PI;

use godot::prelude::*;

use crate::combat::stance_price::adiff;
use crate::nav::reach::ReachField;
use crate::projectile::manager::stance_cells::{salvo_fire_share, table_best};
use crate::projectile::manager::ProjectileManager;

const RANGE_BUCKET_M: f64 = 1000.0;
const ASPECT_BUCKET_DEG: f64 = 15.0;
const BEARING_BUCKET_DEG: f64 = 5.0;
pub(crate) const JOB_STRIDE: usize = 13;

/// (shooter, target, target saturation mask or -1 without a pack, range, aspect, bearing buckets).
type Key = (i64, i64, i64, i32, i32, i32);

fn key(shooter: i64, target: i64, sat: i64, range_m: f64, aspect_deg: f64, bearing_deg: f64) -> Key {
    (shooter, target, sat, (range_m / RANGE_BUCKET_M) as i32, (aspect_deg / ASPECT_BUCKET_DEG) as i32,
        (bearing_deg / BEARING_BUCKET_DEG) as i32)
}

/// One secondary sub-battery: its table per ammo slot ("" none), [damage, raw fire chance, fire dps x burn s, size mod,
/// fire chance] per slot, reload, range, and barrels bearing per 0.5 degree of bearing 0..180.
struct Battery {
    keys: [String; 2],
    q: [[f64; 5]; 2],
    reload: f64,
    range: f64,
    counts: Vec<i32>,
}

/// BotGunnery.sec_pack: what `shooter`'s secondaries do to `target` as it is now.
struct Pack {
    sig: i64,
    sat: i64,
    fires: Vec<(Vector3, bool)>,
    bats: Vec<Battery>,
}

impl Pack {
    fn read(sig: i64, d: &VarDictionary) -> Pack {
        let fires: PackedFloat32Array = d.get("fires").and_then(|v| v.try_to().ok()).unwrap_or_default();
        let mut bats = Vec::new();
        if let Some(arr) = d.get("bats").and_then(|v| v.try_to::<VarArray>().ok()) {
            for b in arr.iter_shared() {
                let Ok(b) = b.try_to::<VarDictionary>() else { continue };
                let keys: PackedStringArray = b.get("keys").and_then(|v| v.try_to().ok()).unwrap_or_default();
                let q: PackedFloat64Array = b.get("q").and_then(|v| v.try_to().ok()).unwrap_or_default();
                let counts: PackedInt32Array = b.get("counts").and_then(|v| v.try_to().ok()).unwrap_or_default();
                let qv = |i: usize| q.get(i).unwrap_or(0.0);
                bats.push(Battery {
                    keys: [keys.get(0).map(|k| k.to_string()).unwrap_or_default(), keys.get(1).map(|k| k.to_string()).unwrap_or_default()],
                    q: [std::array::from_fn(qv), std::array::from_fn(|i| qv(5 + i))],
                    reload: b.get("reload").map(|v| v.to::<f64>()).unwrap_or(1.0).max(0.01),
                    range: b.get("range").map(|v| v.to::<f64>()).unwrap_or(0.0),
                    counts: counts.to_vec(),
                });
            }
        }
        Pack {
            sig, sat: d.get("sat").map(|v| v.to::<i64>()).unwrap_or(0), bats,
            fires: fires.as_slice().chunks_exact(4).map(|c| (Vector3::new(c[0], c[1], c[2]), c[3] > 0.5)).collect(),
        }
    }

    /// max(slot 0, slot 1) dps over the batteries bearing at `bearing` (NAN: all); None while a table is unanswered.
    fn dps(&self, pm: &ProjectileManager, range: f64, aspect: f64, bearing: f64) -> Option<f64> {
        let bi = if bearing.is_nan() { None } else { Some(((bearing / 0.5).round() as i64).clamp(0, 360) as usize) };
        let mut slot = [0.0f64; 2];
        for b in &self.bats {
            if b.range < range {
                continue;
            }
            let all = b.counts.last().copied().unwrap_or(0);
            let c = match bi { Some(i) => b.counts.get(i).copied().unwrap_or(0), None => all };
            if c <= 0 {
                continue;
            }
            let rate = c as f64 / b.reload;
            for (s, key) in b.keys.iter().enumerate() {
                let q = &b.q[s];
                if key.is_empty() {
                    // A shell without a queued table is unknown, not harmless.
                    if q[0] > 0.0 {
                        return None;
                    }
                    continue;
                }
                let (value, damage, landed) = table_best(pm, key, range, aspect, self.sat, q[0], q[1], q[2], &self.fires)?;
                let ev = damage * q[3] + (value - damage) * salvo_fire_share(c as i64, landed, q[4]);
                slot[s] += rate * ev;
            }
        }
        Some(slot[0].max(slot[1]))
    }
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SecCache {
    base: Base<RefCounted>,
    cells: HashMap<Key, f32>,
    packs: HashMap<(i64, i64), Pack>,
}

#[godot_api]
impl SecCache {
    /// GDScript's fallback values: per value [shooter id, target id, sat, range m, aspect deg, bearing deg] in `q`.
    #[func]
    fn put(&mut self, q: PackedFloat64Array, vals: PackedFloat32Array) {
        for (c, &v) in q.as_slice().chunks_exact(6).zip(vals.as_slice()) {
            self.cells.entry(key(c[0] as i64, c[1] as i64, c[2] as i64, c[3], c[4], c[5])).or_insert(v);
        }
    }

    #[func]
    fn has_pack(&self, shooter: i64, target: i64, sig: i64) -> bool {
        self.packs.get(&(shooter, target)).is_some_and(|p| p.sig == sig)
    }

    #[func]
    fn set_pack(&mut self, shooter: i64, target: i64, sig: i64, pack: VarDictionary) {
        self.packs.insert((shooter, target), Pack::read(sig, &pack));
    }

    /// One cell's dps, filled from the pack when absent; NAN when only GDScript can answer it.
    #[func]
    fn dps(&mut self, pm: Gd<ProjectileManager>, shooter: i64, target: i64, range: f64, aspect: f64, bearing: f64) -> f64 {
        self.cell(&pm.bind(), shooter, target, range, aspect, bearing).map_or(f64::NAN, |(v, _)| v as f64)
    }

    /// `dps` at each of `ranges`: 0 past `max_range`, NAN where only GDScript can answer.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn curve(&mut self, pm: Gd<ProjectileManager>, shooter: i64, target: i64, ranges: PackedFloat64Array, aspect: f64,
            bearing: f64, max_range: f64) -> PackedFloat32Array {
        let pm = pm.bind();
        let v: Vec<f32> = ranges.as_slice().iter().map(|&r| if r > max_range { 0.0 } else {
            self.cell(&pm, shooter, target, r, aspect, bearing).map_or(f32::NAN, |(v, _)| v)
        }).collect();
        PackedFloat32Array::from(v.as_slice())
    }

    #[func]
    fn size(&self) -> i64 {
        self.cells.len() as i64
    }
}

impl SecCache {
    /// (dps, sat key) of a cell; Err(sat) when it must come from GDScript.
    fn cell(&mut self, pm: &ProjectileManager, sid: i64, tid: i64, d: f64, a: f64, brg: f64) -> Result<(f32, i64), i64> {
        let sat = self.packs.get(&(sid, tid)).map_or(-1, |p| p.sat);
        let k = key(sid, tid, sat, d, a, brg);
        if let Some(&v) = self.cells.get(&k) {
            return Ok((v, sat));
        }
        let v = self.packs.get(&(sid, tid)).and_then(|p| p.dps(pm, d, a, brg)).ok_or(sat)? as f32;
        self.cells.insert(k, v);
        Ok((v, sat))
    }
}

/// Adds every job's secondaries into `steps` along `track` ([x, z, heading, speed] per `dt`). A job is [shooter id,
/// target id, reach, weight, mode (0: its fire on us, 1: ours on it), its heading, x, z, vx, vz, reach-field bit,
/// stop step, fixed aspect deg]. Mode 0: the enemy at (x, z) + v t, the aspect we show it and the bearing it shows us;
/// mode 1: the target at (x, z) + v t, the fixed aspect, the bearing it lies off our bow.
/// Returns the missing cells as [job, range, aspect, bearing, sat] each.
#[allow(clippy::too_many_arguments)]
pub(crate) fn add(cache: &mut SecCache, pm: &ProjectileManager, track: &[f64], jobs: &[f64], field: Option<&ReachField>,
        team: i32, dt: f64, steps: &mut [f32]) -> Vec<f64> {
    let n = (track.len() / 4).min(steps.len());
    let lookup = field.and_then(|f| f.team_fire_lookup(team));
    let mut masks: HashMap<usize, u64> = HashMap::new();
    let mut missing = Vec::new();
    let mut asked: HashSet<Key> = HashSet::new();
    let deg = 180.0 / PI;
    for (j, jb) in jobs.chunks_exact(JOB_STRIDE).enumerate() {
        let (sid, tid, reach, w, mode) = (jb[0] as i64, jb[1] as i64, jb[2], jb[3], jb[4] as i32);
        let e_hdg = jb[5];
        let (ep, ev) = (Vector2::new(jb[6] as f32, jb[7] as f32), Vector2::new(jb[8] as f32, jb[9] as f32));
        let bit = jb[10] as i64;
        let stop = (jb[11].max(0.0) as usize).min(n);
        let asp_fixed = jb[12];
        for k in 0..stop {
            let at = Vector2::new(track[4 * k] as f32, track[4 * k + 1] as f32);
            let hdg = track[4 * k + 2];
            let p = ep + ev * ((k + 1) as f64 * dt) as f32;
            let (a, brg, d) = if mode == 0 {
                let to = p - at;
                let d = to.length() as f64;
                if d > reach {
                    continue;
                }
                if bit >= 0 && field.is_some() {
                    let m = *masks.entry(k).or_insert_with(|| lookup.as_ref().map_or(0, |l| l.mask(at)));
                    if m & (1u64 << bit) == 0 {
                        continue;
                    }
                }
                ((adiff(hdg, (to.x as f64).atan2(to.y as f64)).abs()) * deg,
                    (adiff(e_hdg, (-to.x as f64).atan2(-to.y as f64)).abs()) * deg, d)
            } else {
                let to = p - at;
                let d = to.length() as f64;
                if d > reach {
                    continue;
                }
                (asp_fixed, (adiff(hdg, (to.x as f64).atan2(to.y as f64)).abs()) * deg, d)
            };
            match cache.cell(pm, sid, tid, d, a, brg) {
                Ok((v, _)) => steps[k] = (steps[k] as f64 + w * v as f64 * dt) as f32,
                Err(sat) => {
                    if asked.insert(key(sid, tid, sat, d, a, brg)) {
                        missing.extend_from_slice(&[j as f64, d, a, brg, sat as f64]);
                    }
                }
            }
        }
    }
    missing
}
