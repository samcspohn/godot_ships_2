use std::collections::{HashMap, HashSet};
use std::f64::consts::PI;

use godot::prelude::*;

use crate::combat::stance_price::{adiff, dodge_search};
use crate::combat::turret::wrapf;
use crate::projectile::manager::{ProjectileManager, ShellLandingEntry};

/// Full rudder held this long either way, then centred (0: centred now); the hull swings on as it answers.
const HOLDS: [f32; 7] = [0.0, 1.0, 2.0, 3.0, 4.0, 6.0, 99.0];
const THROTTLES: [f32; 5] = [1.0, 0.75, 0.5, 0.0, -1.0];
const ASPECTS: usize = 37;

/// A stance throttle as the hull's engine power: astern is the navigator's half power astern.
fn power(t: f64) -> f64 {
    if t < 0.0 { -0.5 } else { t }
}

fn sign(x: f64) -> f64 {
    if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 }
}

/// SkillStance's shell dodge: which shells it has planned against, and the plan.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct DodgePlanner {
    seen: HashSet<(i32, i64)>,
    #[init(val = f64::NEG_INFINITY)]
    until: f64,
    #[init(val = f64::INFINITY)]
    h: f64,
    #[init(val = 1.0)]
    t: f64,
    kind: GString,
    cost: Vector2,
    /// threat_half_len of the heaviest shell last seen coming at us.
    #[init(val = 30.0)]
    fall_half: f64,
    shells: Vec<(ShellLandingEntry, f32)>,
    horizon: f64,
}

fn key(e: &ShellLandingEntry, tr: f32, now: f64) -> (i32, i64) {
    (e.shell_id, ((now + tr as f64) * 2.0).round() as i64)
}

#[godot_api]
impl DodgePlanner {
    /// Whether a shell lands within `radius` of `at` that the last plan did not see.
    #[func]
    fn fresh(&self, pm: Gd<ProjectileManager>, at: Vector2, radius: f32, team: i32, now: f64) -> bool {
        pm.bind().shells_near(at, radius, team).iter().any(|(e, tr)| !self.seen.contains(&key(e, *tr, now)))
    }

    /// 0: no dodge; 1: the held plan dodges; 2: fresh shells, plan() to re-plan.
    #[func]
    fn check(&mut self, pm: Gd<ProjectileManager>, at: Vector2, radius: f32, team: i32, now: f64) -> i32 {
        let shells = pm.bind().shells_near(at, radius, team);
        let mut seen = HashSet::with_capacity(shells.len());
        let mut fresh = false;
        let mut horizon = 0.0f64;
        let mut big = 0.0f64;
        for (e, tr) in &shells {
            let k = key(e, *tr, now);
            seen.insert(k);
            fresh = fresh || !self.seen.contains(&k);
            horizon = horizon.max(*tr as f64);
            if e.caliber as f64 > big {
                big = e.caliber as f64;
                self.fall_half = e.threat_half_len as f64;
            }
        }
        if !fresh && now < self.until {
            return if self.h.is_finite() { 1 } else { 0 };
        }
        self.seen = seen;
        self.h = f64::INFINITY;
        if shells.is_empty() {
            self.until = f64::NEG_INFINITY;
            self.shells.clear();
            return 0;
        }
        self.until = now + horizon;
        self.horizon = horizon;
        self.shells = shells;
        2
    }

    /// StanceSim.dodge_search over the shells check() kept, cfg as SkillStance builds it. Rows it lacks come back as
    /// "missing" (rows) and "missing_hit" (hit_rows) without a plan, unless `last`; with one, "pick" is set.
    #[func]
    fn plan(&mut self, cfg: VarDictionary, last: bool) -> VarDictionary {
        let mut c = cfg.duplicate_shallow();
        let get = |k: &str, d: f64| cfg.get(k).and_then(|v| v.try_to::<f64>().ok()).unwrap_or(d);
        let f64s = |k: &str| cfg.get(k).and_then(|v| v.try_to::<PackedFloat64Array>().ok()).unwrap_or_default();
        let at = cfg.get("at").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or_default();
        let sh = f64s("shooters");
        let bearings = f64s("bearings");
        let hit_rows: VarArray = cfg.get("hit_rows").and_then(|v| v.try_to().ok()).unwrap_or_default();
        let bucket_m = get("bucket_m", 250.0);
        let source_match = get("source_match", 0.0);

        let mut pack = Vec::with_capacity(self.shells.len() * 7);
        let mut aspect_w: Vec<f32> = Vec::with_capacity(self.shells.len() * ASPECTS);
        let mut missing_hit: Vec<f64> = Vec::new();
        let mut asked: HashSet<(usize, i64)> = HashSet::new();
        for (e, tr) in &self.shells {
            pack.extend_from_slice(&[e.landing_x, e.landing_z, e.landing_vx, e.landing_vz, *tr, e.threat_half_len, e.caliber]);
            let from = (-(e.landing_vx as f64)).atan2(-(e.landing_vz as f64));
            let mut best = source_match;
            let mut sel = None;
            for (i, &b) in bearings.as_slice().iter().enumerate() {
                if !b.is_finite() {
                    continue;
                }
                let d = adiff(from, b).abs();
                if d < best {
                    best = d;
                    sel = Some(i);
                }
            }
            let mut row: Option<Vec<f32>> = None;
            if let Some(i) = sel {
                let pos = Vector2::new(sh[i * 10] as f32, sh[i * 10 + 1] as f32);
                let r = (pos.distance_to(at) as f64).min(sh[i * 10 + 6]);
                let bucket = (r / bucket_m) as i64;
                let got = hit_rows.get(i).and_then(|v| v.try_to::<VarDictionary>().ok())
                    .and_then(|d| d.get(bucket)).and_then(|v| v.try_to::<PackedFloat32Array>().ok());
                match got {
                    None => {
                        if asked.insert((i, bucket)) {
                            for a in 0..ASPECTS {
                                missing_hit.extend_from_slice(&[i as f64, r, a as f64]);
                            }
                        }
                    }
                    Some(v) => {
                        let nan: Vec<usize> = (0..v.len()).filter(|&a| v[a].is_nan()).collect();
                        if !nan.is_empty() {
                            if asked.insert((i, bucket)) {
                                for a in nan {
                                    missing_hit.extend_from_slice(&[i as f64, r, a as f64]);
                                }
                            }
                        } else if v.len() == ASPECTS {
                            row = Some(v.to_vec());
                        }
                    }
                }
            }
            aspect_w.extend_from_slice(row.as_deref().unwrap_or(&[1.0; ASPECTS]));
        }
        if !missing_hit.is_empty() && !last {
            let mut out = VarDictionary::new();
            out.set("missing_hit", &PackedFloat64Array::from(missing_hit.as_slice()));
            out.set("missing", &PackedFloat64Array::new());
            return out;
        }

        // HP per weight unit of these shells, from our shooters' shell damage by caliber.
        let (cals, dmgs) = (f64s("shell_cal"), f64s("shell_dmg"));
        let ref_cal = get("ref_cal", 300.0);
        let mut dmg: HashMap<i64, f64> = HashMap::new();
        for (cal, d) in cals.as_slice().iter().zip(dmgs.as_slice()) {
            if cal.is_finite() {
                dmg.insert(cal.round() as i64, *d);
            }
        }
        let (mut hp, mut wt) = (0.0, 0.0);
        for (e, _) in &self.shells {
            if let Some(d) = dmg.get(&((e.caliber as f64).round() as i64)).copied() {
                hp += d;
                wt += (e.caliber as f64 / ref_cal).powf(3.0);
            }
        }
        let per_w = if wt > 0.0 { hp / wt } else { 0.0 };

        let (heading, throttle) = (get("heading", 0.0), get("throttle", 1.0));
        let mut cands = vec![Vector3::new(heading as f32, -1.0, power(throttle) as f32)];
        let mut thr = vec![throttle as f32];
        for hold in HOLDS {
            let sides: &[f32] = if hold == 0.0 { &[0.0] } else { &[-1.0, 1.0] };
            for &side in sides {
                for t in THROTTLES {
                    cands.push(Vector3::new(side, hold, power(t as f64) as f32));
                    thr.push(t);
                }
            }
        }

        let window = self.horizon + get("price_s", 0.0);
        let slices = f64s("slices");
        let full = f64s("coef_full");
        let mut coef = full.clone();
        let mut lo = 0.0;
        for (i, &hi) in slices.as_slice().iter().enumerate() {
            if 4 * i + 3 < coef.len() {
                let covered = ((window.min(hi) - lo) / (hi - lo)).clamp(0.0, 1.0);
                coef[4 * i + 3] = full[4 * i + 3] * covered;
            }
            lo = hi;
        }

        c.set("shells", &PackedFloat32Array::from(pack.as_slice()));
        c.set("aspect_w", &PackedFloat32Array::from(aspect_w.as_slice()));
        c.set("per_w", per_w);
        c.set("horizon", self.horizon);
        c.set("window", window);
        c.set("skip", self.horizon);
        c.set("coef", &coef);
        c.set("cands", &PackedVector3Array::from(cands.as_slice()));
        c.set("throttles", &PackedFloat32Array::from(thr.as_slice()));
        let mut r = dodge_search(&c);
        if r.is_empty() {
            return r;
        }
        let missing = r.get("missing").and_then(|v| v.try_to::<PackedFloat64Array>().ok()).unwrap_or_default();
        if !missing.is_empty() && !last {
            return r;
        }
        let pick = r.get("pick").and_then(|v| v.try_to::<i64>().ok()).unwrap_or(-1);
        if pick > 0 {
            let p = pick as usize;
            self.h = r.get("heading").and_then(|v| v.try_to::<f64>().ok()).unwrap_or(f64::INFINITY);
            self.t = thr[p] as f64;
            self.kind = (if thr[p] < 0.0 { "astern" } else if cands[p].y > 0.0 { "turn" } else if thr[p] > 0.0 { "forward" } else { "stop" }).into();
        }
        let w = get_f(&r, "w") as f32;
        self.cost = Vector2::new(get_f(&r, "cost0") as f32, get_f(&r, "score") as f32) / w;
        r.set("picked", pick);
        r
    }

    /// After apply's lie, or with stance off (`off`): [heading, throttle, on_route, write, throttle_override (-1: keep),
    /// force_reverse, forbid_reverse]. s: [heading, throttle, on_route, aimed, duel, hdg, route, cone, turning,
    /// turn_way, turn_lead, juke].
    #[func]
    fn tail(&self, off: bool, s: PackedFloat64Array) -> PackedFloat64Array {
        let (mut h, mut t, mut on_route) = (s[0], s[1], s[2] != 0.0);
        let (aimed, duel, hdg, route, cone) = (s[3] != 0.0, s[4] != 0.0, s[5], s[6], s[7]);
        let (turning, turn_way, lead, juke) = (s[8] != 0.0, s[9], s[10], s[11] != 0.0);
        let keep = |h: f64, t: f64, on: bool| PackedFloat64Array::from(&[h, t, on as i64 as f64, 0.0, -1.0, 0.0, 0.0]);
        let order = |h: f64, t: f64, on: bool, over: f64| PackedFloat64Array::from(&[h, t, on as i64 as f64, 1.0, over,
            (t < 0.0) as i64 as f64, (t >= 0.0) as i64 as f64]);
        if off {
            if !juke {
                return keep(h, t, on_route);
            }
            let (h, t) = (self.h, self.t);
            return order(h, t, on_route, if t > 0.0 { (t * 4.0).round() } else { -1.0 });
        }
        if juke {
            h = self.h;
            t = self.t;
            on_route = false;
        }
        if on_route {
            return keep(h, t, on_route);
        }
        let in_cone = |h: f64, t: f64| -> bool {
            if !route.is_finite() {
                return true;
            }
            if t == 0.0 {
                return false;
            }
            let motion = if t > 0.0 { h } else { wrapf(h + PI, -PI, PI) };
            adiff(route, motion).abs() <= cone + 1e-4
        };
        let cone_heading = |h: f64| if route.is_finite() { wrapf(route + adiff(route, h).clamp(-cone, cone), -PI, PI) } else { h };
        // SkillStance._to_cone.
        'cone: {
            if !route.is_finite() || in_cone(h, t) {
                break 'cone;
            }
            if t < 0.0 {
                if adiff(route, wrapf(hdg + PI, -PI, PI)).abs() <= PI / 2.0 {
                    h = wrapf(cone_heading(wrapf(h + PI, -PI, PI)) + PI, -PI, PI);
                    break 'cone;
                }
                t = 1.0;
            }
            if t == 0.0 {
                t = 1.0;
            }
            h = cone_heading(h);
            let left = adiff(hdg, h);
            if turning && left.abs() > lead && sign(left) != turn_way {
                h = wrapf(hdg + turn_way * lead, -PI, PI);
            }
        }
        let over = if (juke || aimed) && t > 0.0 {
            (t * 4.0).round().max(1.0)
        } else if duel && t > 0.0 {
            // A duel is fought under way: the navigator would brake for a destination stance is not sailing to.
            4.0
        } else {
            -1.0
        };
        order(h, t, on_route, over)
    }

    #[func]
    fn heading(&self) -> f64 {
        self.h
    }

    #[func]
    fn throttle(&self) -> f64 {
        self.t
    }

    #[func]
    fn kind(&self) -> GString {
        self.kind.clone()
    }

    #[func]
    fn cost(&self) -> Vector2 {
        self.cost
    }

    #[func]
    fn fall_half(&self) -> f64 {
        self.fall_half
    }
}

fn get_f(d: &VarDictionary, k: &str) -> f64 {
    d.get(k).and_then(|v| v.try_to::<f64>().ok()).unwrap_or(0.0)
}
