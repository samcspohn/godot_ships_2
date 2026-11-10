//! SkillStance's duel secondaries along a track (_add_secondaries_in and the dealt side of _duel_score), with
//! BotBehavior._secondary_dps's cells cached here; cells not held come back as missing for GDScript to fill.

use std::collections::{HashMap, HashSet};
use std::f64::consts::PI;

use godot::prelude::*;

use crate::combat::stance_price::adiff;
use crate::nav::reach::ReachField;

const RANGE_BUCKET_M: f64 = 1000.0;
const ASPECT_BUCKET_DEG: f64 = 15.0;
const BEARING_BUCKET_DEG: f64 = 5.0;
pub(crate) const JOB_STRIDE: usize = 13;

type Key = (i64, i64, i32, i32, i32);

fn key(shooter: i64, target: i64, range_m: f64, aspect_deg: f64, bearing_deg: f64) -> Key {
    (shooter, target, (range_m / RANGE_BUCKET_M) as i32, (aspect_deg / ASPECT_BUCKET_DEG) as i32,
        (bearing_deg / BEARING_BUCKET_DEG) as i32)
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SecCache {
    base: Base<RefCounted>,
    cells: HashMap<Key, f32>,
}

#[godot_api]
impl SecCache {
    /// Per value: [shooter id, target id, range m, aspect deg, bearing deg] in `q`, the dps in `vals`.
    #[func]
    fn put(&mut self, q: PackedFloat64Array, vals: PackedFloat32Array) {
        for (c, &v) in q.as_slice().chunks_exact(5).zip(vals.as_slice()) {
            self.cells.entry(key(c[0] as i64, c[1] as i64, c[2], c[3], c[4])).or_insert(v);
        }
    }

    #[func]
    fn size(&self) -> i64 {
        self.cells.len() as i64
    }
}

/// Adds every job's secondaries into `steps` along `track` ([x, z, heading, speed] per `dt`). A job is [shooter id,
/// target id, reach, weight, mode (0: its fire on us, 1: ours on it), its heading, x, z, vx, vz, reach-field bit,
/// stop step, fixed aspect deg]. Mode 0: the enemy at (x, z) + v t, the aspect we show it and the bearing it shows us;
/// mode 1: the target at (x, z) + v t, the fixed aspect, the bearing it lies off our bow.
/// Returns the missing cells as [job, range, aspect, bearing] each.
pub(crate) fn add(cache: &SecCache, track: &[f64], jobs: &[f64], field: Option<&ReachField>, team: i32, dt: f64,
        steps: &mut [f32]) -> Vec<f64> {
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
            let kk = key(sid, tid, d, a, brg);
            match cache.cells.get(&kk) {
                Some(&v) => steps[k] = (steps[k] as f64 + w * v as f64 * dt) as f32,
                None => {
                    if asked.insert(kk) {
                        missing.extend_from_slice(&[j as f64, d, a, brg]);
                    }
                }
            }
        }
    }
    missing
}
