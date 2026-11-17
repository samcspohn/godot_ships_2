use godot::prelude::*;
use std::collections::BTreeMap;

use super::gunnery::Aim;
use super::snapshot::{HullClass, ShipState, Snapshot};

const RANGE_BUCKETS_M: [f32; 3] = [5000.0, 10000.0, 15000.0];
const MANEUVER_SPEED: f32 = 1.5;
const MANEUVER_YAW: f32 = 0.01;
/// Plunging shells reach past the hull's footprint by roughly superstructure height / tan(descent).
const RANGE_SLACK_M: f32 = 60.0;

struct Pending {
    shooter_class: HullClass,
    from: Vector2,
    aim: Aim,
    impact_t: f64,
    speed0: f32,
    yaw0: f32,
    guns: i32,
}

#[derive(Default, Clone)]
struct Bucket {
    shots: u32,
    guns: u32,
    off_hull: u32,
    along_abs: f64,
    cross_abs: f64,
    along_signed: f64,
    maneuver: u32,
    maneuver_off: u32,
    steady_off: u32,
    off_lateral: u32,
    off_over: u32,
    off_short: u32,
    target_gone: u32,
}

/// Lead error per salvo: where the aimed hull point actually is at impact vs where we aimed.
#[derive(Default)]
pub struct Telemetry {
    pending: Vec<Pending>,
    buckets: BTreeMap<String, Bucket>,
    pub counters: BTreeMap<&'static str, u64>,
    pub releases: BTreeMap<&'static str, u64>,
    /// Release reason -> [n, station kept, station shift m, shift > 2 km, anchor shift m, old station distance m].
    pub shift: BTreeMap<&'static str, [f64; 6]>,
    /// Damage key -> [predicted, real, minutes].
    pub calib: BTreeMap<String, [f64; 3]>,
    /// "ship|ap" / "ship|he" -> samples per 10° of the angle off our bow incoming shells come from.
    pub angling: BTreeMap<String, [u64; 19]>,
}

impl Telemetry {
    pub fn count(&mut self, k: &'static str) {
        *self.counters.entry(k).or_default() += 1;
    }

    pub fn calib(&mut self, k: String, pred: f32, real: f32, minutes: f32) {
        let e = self.calib.entry(k).or_default();
        e[0] += pred as f64;
        e[1] += real.max(0.0) as f64;
        e[2] += minutes as f64;
    }

    pub fn shift(&mut self, k: &'static str, station: f32, anchor: f32, away: f32) {
        let e = self.shift.entry(k).or_default();
        e[0] += 1.0;
        e[1] += (station < 1.0) as u8 as f64;
        e[2] += station as f64;
        e[3] += (station > 2000.0) as u8 as f64;
        e[4] += anchor as f64;
        e[5] += away as f64;
    }

    pub fn angling(&mut self, ship: &str, he: bool, off_bow_deg: f32) {
        let e = self.angling.entry(format!("{ship}|{}", if he { "he" } else { "ap" })).or_default();
        e[((off_bow_deg / 10.0).round() as usize).min(18)] += 1;
    }

    pub fn release(&mut self, k: &'static str) {
        *self.releases.entry(k).or_default() += 1;
    }

    pub fn salvo(&mut self, now: f64, shooter: &ShipState, target: &ShipState, aim: Aim, guns: i32) {
        self.pending.push(Pending {
            shooter_class: shooter.class,
            from: shooter.p2(),
            aim,
            impact_t: now + aim.tof_game.max(0.0) as f64,
            speed0: target.speed(),
            yaw0: target.yaw_rate,
            guns,
        });
    }

    pub fn resolve(&mut self, now: f64, snap: &Snapshot) {
        let mut i = 0;
        while i < self.pending.len() {
            if self.pending[i].impact_t > now {
                i += 1;
                continue;
            }
            let p = self.pending.swap_remove(i);
            let rb = RANGE_BUCKETS_M.iter().position(|&r| p.aim.range < r).unwrap_or(RANGE_BUCKETS_M.len());
            let key = format!("{}>{}|{}", p.shooter_class.name(),
                snap.get(p.aim.target).map_or("?", |t| t.class.name()), ["0-5", "5-10", "10-15", "15+"][rb]);
            let b = self.buckets.entry(key).or_default();
            b.shots += 1;
            b.guns += p.guns as u32;
            let Some(t) = snap.get(p.aim.target).filter(|t| t.alive) else {
                b.target_gone += 1;
                continue;
            };
            let intended = t.pos + t.to_world_dir(p.aim.offset_local);
            let err = t.to_local_dir(p.aim.world - intended);
            let along = -err.z;
            let cross = err.x;
            let flat = |v: Vector3| Vector2::new(v.x, v.z);
            let los = (flat(intended) - p.from).normalized();
            let lat = Vector2::new(los.y, -los.x);
            let e = flat(p.aim.world - intended);
            let c = flat(intended - t.pos);
            let f = flat(t.fwd());
            let (sa, ca) = ((f.x * los.y - f.y * los.x).abs(), f.dot(los).abs());
            let half_w = 0.5 * (t.length * sa + t.beam * ca);
            let half_d = 0.5 * (t.length * ca + t.beam * sa) + RANGE_SLACK_M;
            let (pl, pr) = (c.dot(lat) + e.dot(lat), c.dot(los) + e.dot(los));
            let off_lat = pl.abs() > half_w;
            let off_rng = pr.abs() > half_d;
            let off = off_lat || off_rng;
            let maneuver = (t.speed() - p.speed0).abs() > MANEUVER_SPEED || (t.yaw_rate - p.yaw0).abs() > MANEUVER_YAW;
            b.along_abs += along.abs() as f64;
            b.cross_abs += cross.abs() as f64;
            b.along_signed += along as f64;
            if maneuver {
                b.maneuver += 1;
            }
            if off {
                b.off_hull += 1;
                if maneuver {
                    b.maneuver_off += 1;
                } else {
                    b.steady_off += 1;
                }
                if off_lat {
                    b.off_lateral += 1;
                } else if pr > 0.0 {
                    b.off_over += 1;
                } else {
                    b.off_short += 1;
                }
            }
        }
    }

    pub fn to_dict(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        let mut ang = VarDictionary::new();
        for (k, v) in &self.angling {
            ang.set(k.as_str(), &PackedInt64Array::from(v.map(|x| x as i64).as_slice()));
        }
        out.set("angling", &ang);
        let mut salvos = VarDictionary::new();
        for (k, b) in &self.buckets {
            let n = (b.shots - b.target_gone).max(1) as f64;
            let mut d = VarDictionary::new();
            d.set("shots", b.shots as i64);
            d.set("guns", b.guns as i64);
            d.set("off_hull", b.off_hull as i64);
            d.set("off_hull_pct", 100.0 * b.off_hull as f64 / n);
            d.set("along_abs_m", b.along_abs / n);
            d.set("cross_abs_m", b.cross_abs / n);
            d.set("along_bias_m", b.along_signed / n);
            d.set("maneuver", b.maneuver as i64);
            d.set("maneuver_off", b.maneuver_off as i64);
            d.set("steady_off", b.steady_off as i64);
            d.set("off_lateral", b.off_lateral as i64);
            d.set("off_over", b.off_over as i64);
            d.set("off_short", b.off_short as i64);
            d.set("target_gone", b.target_gone as i64);
            salvos.set(k.as_str(), &d);
        }
        out.set("shots", &salvos);
        let mut c = VarDictionary::new();
        for (k, v) in &self.counters {
            c.set(*k, *v as i64);
        }
        out.set("counters", &c);
        let mut r = VarDictionary::new();
        for (k, v) in &self.releases {
            r.set(*k, *v as i64);
        }
        out.set("releases", &r);
        let mut c = VarDictionary::new();
        for (k, v) in &self.calib {
            c.set(k.as_str(), &PackedFloat64Array::from(&v[..]));
        }
        out.set("calib", &c);
        let mut sh = VarDictionary::new();
        for (k, v) in &self.shift {
            sh.set(*k, &PackedFloat64Array::from(&v[..]));
        }
        out.set("shift", &sh);
        out
    }
}
