//! SkillStance's track pricing (_track_slices, _track_torps) and the dodge's best-first search over its candidates.
//! Float steps mirror the GDScript they replace: Vector2 maths in f32, the rest in f64.

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};
use std::f64::consts::{PI, TAU};

use godot::prelude::*;

use crate::combat::turret::wrapf;
use crate::nav::map::NavigationMap;
use crate::nav::navigator::hull::{rudder_to_heading, Hull, PHYSICS_DT};
use crate::nav::reach::{ReachField, ReachLookup};
use crate::combat::stance::{shell_hit, ship_params, start_hull};
use crate::nav::types::ShipParams;

const SH_STRIDE: usize = 10;
const TORP_STRIDE: usize = 8;

/// Godot's angle_difference.
pub(crate) fn adiff(from: f64, to: f64) -> f64 {
    let d = (to - from) % TAU;
    (2.0 * d) % TAU - d
}

fn len32(x: f32, z: f32) -> f32 {
    (x * x + z * z).sqrt()
}

struct Shooter {
    x: f32,
    z: f32,
    weight: f64,
    group: usize,
    bit: i32,
    spread: f64,
    range: f64,
    reload: f64,
    first: f64,
    stop: f64,
}

impl Shooter {
    /// Salvo landings before `end`, by repeated addition as the GDScript stepped them.
    fn times(&self, end: f64) -> impl Iterator<Item = f64> + '_ {
        let stop = self.stop.min(end);
        let reload = self.reload;
        std::iter::successors(Some(self.first), move |&t| Some(t + reload)).take_while(move |&t| t < stop && reload > 0.0)
    }
}

pub(crate) struct Pricer {
    sh: Vec<Shooter>,
    rows: HashMap<(usize, i32), Vec<f32>>,
    /// (shooter, range) of the first visit to each row bucket not given.
    /// (shooter, range, bucket, aspect) of cells not given (absent bucket or NAN cell).
    missing: RefCell<Vec<(usize, f64, i32, usize)>>,
    slices: Vec<f64>,
    vmax: f64,
    at_speed: f64,
    field: bool,
    lookup: Option<ReachLookup>,
    dt: f64,
    n_asp: usize,
    asp_step: f64,
    bucket_m: f64,
}

fn f(d: &VarDictionary, k: &str, def: f64) -> f64 {
    d.get(k).and_then(|v| v.try_to::<f64>().ok()).unwrap_or(def)
}

fn f64s(d: &VarDictionary, k: &str) -> Vec<f64> {
    d.get(k).and_then(|v| v.try_to::<PackedFloat64Array>().ok()).map_or_else(Vec::new, |a| a.to_vec())
}

fn f32s(d: &VarDictionary, k: &str) -> Vec<f32> {
    d.get(k).and_then(|v| v.try_to::<PackedFloat32Array>().ok()).map_or_else(Vec::new, |a| a.to_vec())
}

impl Pricer {
    /// cfg: shooters [x, z, weight, group, bit, spread, range, reload, next, stop] each, rows (per shooter
    /// {bucket: PackedFloat32Array}), slices, vmax, at_speed, team, field, window, skip, dt, aspects, aspect_step, bucket_m.
    pub(crate) fn new(cfg: &VarDictionary) -> Self {
        let raw = f64s(cfg, "shooters");
        let (window, skip) = (f(cfg, "window", f64::INFINITY), f(cfg, "skip", 0.0));
        let sh: Vec<Shooter> = raw.chunks_exact(SH_STRIDE).map(|s| {
            let reload = s[7];
            let mut t = s[8];
            while t < skip && reload > 0.0 {
                t += reload;
            }
            Shooter { x: s[0] as f32, z: s[1] as f32, weight: s[2], group: s[3] as usize, bit: s[4] as i32, spread: s[5],
                range: s[6], reload, first: t, stop: s[9].min(window) }
        }).collect();
        let mut rows = HashMap::new();
        if let Some(arr) = cfg.get("rows").and_then(|v| v.try_to::<VarArray>().ok()) {
            for (i, d) in arr.iter_shared().enumerate() {
                let Ok(d) = d.try_to::<VarDictionary>() else { continue };
                for (k, v) in d.iter_shared() {
                    if let (Ok(b), Ok(r)) = (k.try_to::<i64>(), v.try_to::<PackedFloat32Array>()) {
                        rows.insert((i, b as i32), r.to_vec());
                    }
                }
            }
        }
        let field = cfg.get("field").and_then(|v| v.try_to::<Gd<ReachField>>().ok());
        let team = f(cfg, "team", 0.0) as i32;
        let lookup = field.as_ref().and_then(|g| g.bind().team_fire_lookup(team));
        Pricer {
            sh, rows, missing: RefCell::new(Vec::new()), slices: f64s(cfg, "slices"), vmax: f(cfg, "vmax", 1.0).max(1.0),
            at_speed: f(cfg, "at_speed", 0.0), field: field.is_some(), lookup, dt: f(cfg, "dt", 1.0),
            n_asp: f(cfg, "aspects", 37.0) as usize, asp_step: f(cfg, "aspect_step", 5.0), bucket_m: f(cfg, "bucket_m", 250.0),
        }
    }

    pub(crate) fn dt(&self) -> f64 {
        self.dt
    }

    pub(crate) fn n_slices(&self) -> usize {
        self.slices.len().max(1)
    }

    fn slice_of(&self, t: f64) -> usize {
        let mut si = 0;
        while si + 1 < self.slices.len() && t >= self.slices[si] {
            si += 1;
        }
        si
    }

    fn mask(&self, x: f32, z: f32) -> u64 {
        self.lookup.as_ref().map_or(0, |l| l.mask(Vector2::new(x, z)))
    }

    /// Shooter i's salvo landing at t on a hull at (x, z) heading `hdg` making `speed`: (slice, value).
    fn salvo(&self, i: usize, t: f64, x: f32, z: f32, hdg: f64, speed: f64, mask: &mut Option<u64>) -> Option<(usize, f64)> {
        self.salvo_w(i, t, x, z, hdg, speed, mask, self.sh[i].weight)
    }

    #[allow(clippy::too_many_arguments)]
    fn salvo_w(&self, i: usize, t: f64, x: f32, z: f32, hdg: f64, speed: f64, mask: &mut Option<u64>, weight: f64)
            -> Option<(usize, f64)> {
        let s = &self.sh[i];
        let (tx, tz) = (s.x - x, s.z - z);
        if s.bit >= 0 && self.field {
            let m = *mask.get_or_insert_with(|| self.mask(x, z));
            if m & (1u64 << s.bit) == 0 {
                return None;
            }
        }
        let dist = len32(tx, tz) as f64;
        let reach = if s.spread <= 0.0 {
            if dist <= s.range { 1.0 } else { 0.0 }
        } else {
            ((s.range - dist + s.spread) / (2.0 * s.spread)).clamp(0.0, 1.0)
        };
        if reach <= 0.0 {
            return None;
        }
        let deg = adiff(hdg, (tx as f64).atan2(tz as f64)).abs() * (180.0 / PI);
        let a = ((deg / self.asp_step).round() as i64).clamp(0, self.n_asp as i64 - 1) as usize;
        let r = dist.min(s.range);
        let b = (r / self.bucket_m) as i32;
        let cell = self.rows.get(&(i, b)).map(|row| row.get(a).copied());
        let v = match cell {
            Some(None) => return None,
            Some(Some(v)) if !v.is_nan() => v as f64,
            _ => {
                let mut m = self.missing.borrow_mut();
                if !m.iter().any(|&(j, _, bb, aa)| j == i && bb == b && aa == a) {
                    m.push((i, r, b, a));
                }
                return None;
            }
        };
        Some((self.slice_of(t), s.reload * weight * reach * v * (1.0 - self.at_speed * speed / self.vmax)))
    }

    /// _track_slices over `track` ([x, z, heading, speed] per dt): [on, by, dark] x slice.
    pub(crate) fn slices(&self, track: &[f64]) -> Vec<f64> {
        let n = track.len() / 4;
        let ns = self.n_slices();
        let mut out = vec![0.0; 3 * ns];
        if n == 0 {
            return out;
        }
        let end = n as f64 * self.dt;
        let mut masks: HashMap<usize, Option<u64>> = HashMap::new();
        for (i, s) in self.sh.iter().enumerate() {
            for t in s.times(end) {
                let k = ((t / self.dt) as i64).clamp(0, n as i64 - 1) as usize;
                let p = &track[4 * k..4 * k + 4];
                let m = masks.entry(k).or_insert(None);
                if let Some((si, v)) = self.salvo(i, t, p[0] as f32, p[1] as f32, p[2], p[3], m) {
                    out[s.group * ns + si] += v;
                }
            }
        }
        out
    }

    /// SkillStance._track_incoming's salvos: per step, f32 sums in shooter order; `dark_w` scales unspotted ones.
    pub(crate) fn incoming(&self, track: &[f64], dark_w: f64) -> Vec<f32> {
        let n = track.len() / 4;
        let mut out = vec![0.0f32; n];
        if n == 0 {
            return out;
        }
        let end = n as f64 * self.dt;
        let mut masks: HashMap<usize, Option<u64>> = HashMap::new();
        for (i, s) in self.sh.iter().enumerate() {
            let w = s.weight * if s.group == 2 { dark_w } else { 1.0 };
            for t in s.times(end) {
                let k = ((t / self.dt) as i64).clamp(0, n as i64 - 1) as usize;
                let p = &track[4 * k..4 * k + 4];
                let m = masks.entry(k).or_insert(None);
                if let Some((_, v)) = self.salvo_w(i, t, p[0] as f32, p[1] as f32, p[2], p[3], m, w) {
                    out[k] = (out[k] as f64 + v) as f32;
                }
            }
        }
        out
    }

    /// [shooter, range, aspect index] per missing cell.
    pub(crate) fn missing(&self) -> PackedFloat64Array {
        let v: Vec<f64> = self.missing.borrow().iter().flat_map(|&(i, r, _, a)| [i as f64, r, a as f64]).collect();
        PackedFloat64Array::from(v.as_slice())
    }
}

/// _track_torps' spreads, one shooter's state carried step to step.
pub(crate) struct Torps {
    sh: Vec<[f64; TORP_STRIDE]>,
    length: f64,
    beam: f64,
    reach: f64,
    habit: f64,
    rrt: f64,
    lane: f64,
    keep: f64,
    dt: f64,
}

impl Torps {
    /// cfg: torps [x, z, range, fan, dmg, vt, det, bear] each; torp_hull [length, beam, reach, habit, rudder response, lane rad, keep].
    pub(crate) fn new(cfg: &VarDictionary, dt: f64) -> Self {
        let sh = f64s(cfg, "torps").chunks_exact(TORP_STRIDE).map(|c| c.try_into().unwrap()).collect();
        let h = f64s(cfg, "torp_hull");
        let g = |i: usize| h.get(i).copied().unwrap_or(0.0);
        Torps { sh, length: g(0), beam: g(1), reach: g(2), habit: g(3).max(1e-6), rrt: g(4), lane: g(5), keep: g(6), dt }
    }

    /// _track_torps summed over `track` ([x, z, heading, speed] per dt) to `window_s`.
    pub(crate) fn sum(&self, track: &[f64], window_s: f64) -> f64 {
        let mut st = vec![(0.0, 0.0); self.sh.len()];
        // GDScript's int(INF) is INT64_MIN: an unbounded window priced no torpedoes.
        let n = if window_s.is_finite() { (track.len() / 4).min((window_s / self.dt).max(0.0) as usize) } else { 0 };
        (0..n).map(|k| self.step(track[4 * k] as f32, track[4 * k + 1] as f32, track[4 * k + 2], track[4 * k + 3], &mut st)).sum()
    }

    /// _track_torps' per-step HP over `track` to `window_s`, f32 sums in shooter order.
    pub(crate) fn per_step(&self, track: &[f64], window_s: f64) -> Vec<f32> {
        let n_all = track.len() / 4;
        let mut out = vec![0.0f32; n_all];
        let n = if window_s.is_finite() { n_all.min((window_s / self.dt).max(0.0) as usize) } else { 0 };
        for s in 0..self.sh.len() {
            let mut st = vec![(0.0, 0.0); self.sh.len()];
            for (k, o) in out.iter_mut().enumerate().take(n) {
                let v = self.one(s, track[4 * k] as f32, track[4 * k + 1] as f32, track[4 * k + 2], track[4 * k + 3], &mut st[s]);
                if let Some(v) = v {
                    *o = (*o as f64 + v) as f32;
                }
            }
        }
        out
    }

    /// One step's HP at (x, z) heading `hdg` making `speed`; got/cap per shooter carried in `st`.
    fn step(&self, x: f32, z: f32, hdg: f64, speed: f64, st: &mut [(f64, f64)]) -> f64 {
        let mut sum = 0.0;
        for (j, gc) in st.iter_mut().enumerate() {
            if let Some(v) = self.one(j, x, z, hdg, speed, gc) {
                sum += v;
            }
        }
        sum
    }

    /// Shooter j's share at one step, None out of its reach.
    fn one(&self, j: usize, x: f32, z: f32, hdg: f64, speed: f64, gc: &mut (f64, f64)) -> Option<f64> {
        let s = &self.sh[j];
        let (got, cap) = (&mut gc.0, &mut gc.1);
        {
            let (tx, tz) = (s[0] as f32 - x, s[1] as f32 - z);
            let d = len32(tx, tz) as f64;
            if d > s[2] || d < 1.0 {
                return None;
            }
            let a = adiff(hdg, (tx as f64).atan2(tz as f64));
            let width = self.length * a.sin().abs() + self.beam;
            let hits = s[3].min(1.0 + width / (d * self.lane));
            let run = d / s[5];
            let warn = d.min(s[6]) / s[5];
            let shift = self.reach / speed.max(1.0);
            let react = ((warn - self.rrt) / shift.max(0.1)).clamp(0.0, 1.0);
            let spread = hits * s[4] * (1.0 + (self.keep - 1.0) * react) * (-run / self.habit).exp();
            *cap = cap.max(spread);
            let v = (spread * self.dt / (s[7] + run)).min((*cap - *got).max(0.0));
            *got += v;
            Some(v)
        }
    }
}

/// One candidate sailed and priced a sample at a time.
struct Run {
    c: Vector3,
    hull: Hull,
    step: usize,
    /// Next sample to take (k * dt).
    k: usize,
    prev: (f32, f32),
    last: (f32, f32),
    air: f64,
    sums: Vec<f64>,
    torps: f64,
    torp_st: Vec<(f64, f64)>,
    out_h: Option<f32>,
    off: f64,
    offed: bool,
    clear: bool,
}

struct Search<'a> {
    p: ShipParams,
    pr: &'a Pricer,
    tp: &'a Torps,
    shells: Vec<f32>,
    aspect_w: Vec<f32>,
    hull: Rect2,
    cit: Rect2,
    top: f64,
    ref_cal: f64,
    cit_w: f64,
    /// Physics steps to the horizon, samples over the window, samples torps are priced over.
    n_h: usize,
    m: usize,
    m_price: usize,
    n_t: usize,
    every: usize,
    salvos: Vec<Vec<(f64, usize)>>,
    map: Option<Gd<NavigationMap>>,
    clearance: f32,
    price_later: bool,
}

impl Search<'_> {
    fn new_run(&self, h0: Hull, c: Vector3) -> Run {
        Run { c, hull: h0, step: 0, k: 0, prev: (h0.pos.x, h0.pos.y), last: (h0.pos.x, h0.pos.y), air: 0.0,
            sums: vec![0.0; 3 * self.pr.n_slices()], torps: 0.0, torp_st: vec![(0.0, 0.0); self.tp.sh.len()], out_h: None,
            off: 0.0, offed: false, clear: true }
    }

    fn done(&self, r: &Run) -> bool {
        r.k >= self.m && r.out_h.is_some()
    }

    /// Sails `r` to its next sample and prices what lands by it.
    fn advance(&self, r: &mut Run) {
        let target = if r.k >= self.m { self.n_h.max(r.step) } else { r.k * self.every };
        while r.step < target {
            let t = r.step as f32 * PHYSICS_DT;
            let c = r.c;
            let rudder = if c.y < 0.0 { rudder_to_heading(&r.hull, &self.p, c.x, c.z < 0.0) } else if t < c.y { c.x } else { 0.0 };
            r.hull.step(&self.p, rudder, c.z, PHYSICS_DT);
            r.step += 1;
            self.land_shells(r);
            if r.step == self.n_h {
                r.out_h = Some(r.hull.heading);
            }
        }
        if r.step == 0 {
            self.land_shells(r);
            if self.n_h == 0 {
                r.out_h = Some(r.hull.heading);
            }
        }
        if r.k >= self.m {
            return;
        }
        let (x, z) = (r.hull.pos.x, r.hull.pos.y);
        let speed = if r.k == 0 { 0.0 } else { len32(x - r.prev.0, z - r.prev.1) as f64 / self.pr.dt };
        let hdg = r.hull.heading as f64;
        if r.step <= self.n_h {
            if let Some(m) = &self.map {
                if m.bind().get_distance_impl(x, z) < self.clearance {
                    r.clear = false;
                }
            }
        }
        if self.price_later && r.k < self.m_price {
            let mut mask = None;
            let ns = self.pr.n_slices();
            for &(t, i) in &self.salvos[r.k] {
                if let Some((si, v)) = self.pr.salvo(i, t, x, z, hdg, speed, &mut mask) {
                    r.sums[self.pr.sh[i].group * ns + si] += v;
                }
            }
            if r.k < self.n_t {
                r.torps += self.tp.step(x, z, hdg, speed, &mut r.torp_st);
            }
        }
        r.prev = (x, z);
        r.last = (x, z);
        r.k += 1;
    }

    fn land_shells(&self, r: &mut Run) {
        let n = self.shells.len() / 7;
        for (j, s) in self.shells.chunks_exact(7).enumerate() {
            let k = ((s[4] / PHYSICS_DT).round().max(0.0) as usize).min(self.n_h);
            if k == r.step {
                r.air += shell_hit(s, j, &r.hull, self.hull, self.cit, self.top, self.ref_cal, self.cit_w, &self.aspect_w, n);
            }
        }
    }
}

struct Open(f64, usize);

impl PartialEq for Open {
    fn eq(&self, o: &Self) -> bool {
        self.cmp(o) == Ordering::Equal
    }
}
impl Eq for Open {}
impl PartialOrd for Open {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Open {
    fn cmp(&self, o: &Self) -> Ordering {
        o.0.total_cmp(&self.0).then(o.1.cmp(&self.1))
    }
}

/// The dodge: the lie (candidate 0) priced whole, then the others best first by what they have cost so far, each
/// sailed on only while it could still beat the best finished one and the lie by min_gain.
pub(crate) fn dodge_search(cfg: &VarDictionary) -> VarDictionary {
    let mut out = VarDictionary::new();
    let (Some(p), Some(h0)) = (ship_params(&f32s(cfg, "params")), start_hull(&f32s(cfg, "state"))) else { return out };
    let cands: Vec<Vector3> = cfg.get("cands").and_then(|v| v.try_to::<PackedVector3Array>().ok()).map_or_else(Vec::new, |a| a.to_vec());
    let thr = f32s(cfg, "throttles");
    if cands.is_empty() || thr.len() != cands.len() {
        return out;
    }
    let pr = Pricer::new(cfg);
    let dt = pr.dt;
    let tp = Torps::new(cfg, dt);
    let (horizon, window) = (f(cfg, "horizon", 0.0) as f32, f(cfg, "window", 0.0));
    let per_w = f(cfg, "per_w", 0.0);
    let price_later = per_w > 0.0;
    let w = if price_later { per_w } else { 1.0 };
    let coef = f64s(cfg, "coef");
    let ns = pr.n_slices();
    let konst: f64 = (0..ns).map(|i| coef.get(4 * i + 3).copied().unwrap_or(0.0)).sum();
    let admissible = (0..ns).all(|i| (0..3).all(|g| coef.get(4 * i + g).copied().unwrap_or(1.0) >= 0.0));
    let every = ((dt as f32 / PHYSICS_DT).round() as usize).max(1);
    let n_h = (horizon / PHYSICS_DT).ceil().max(0.0) as usize;
    let m = (window / dt).floor() as usize + 1;
    let mut salvos: Vec<Vec<(f64, usize)>> = vec![Vec::new(); m];
    if price_later {
        let end = m as f64 * dt;
        for (i, s) in pr.sh.iter().enumerate() {
            for t in s.times(end) {
                salvos[((t / dt) as i64).clamp(0, m as i64 - 1) as usize].push((t, i));
            }
        }
    }
    let map = cfg.get("map").and_then(|v| v.try_to::<Gd<NavigationMap>>().ok());
    let sr = Search {
        p, pr: &pr, tp: &tp, shells: f32s(cfg, "shells"), aspect_w: f32s(cfg, "aspect_w"),
        hull: cfg.get("hull").and_then(|v| v.try_to::<Rect2>().ok()).unwrap_or_default(),
        cit: cfg.get("cit").and_then(|v| v.try_to::<Rect2>().ok()).unwrap_or_default(),
        top: f(cfg, "top", 0.0), ref_cal: f(cfg, "ref_cal", 300.0), cit_w: f(cfg, "cit_w", 0.0),
        n_h, m: if price_later { m.max(n_h / every + 1) } else { n_h / every + 1 }, m_price: m,
        n_t: m.min((window / dt) as usize), every, salvos, map, clearance: f(cfg, "clearance", 0.0) as f32, price_later,
    };
    let (lie_h, lie_t) = (f(cfg, "heading", 0.0), f(cfg, "throttle", 1.0));
    let (off_w, gear_w, gain) = (f(cfg, "off_w", 0.0), f(cfg, "gear_w", 0.0), f(cfg, "min_gain", 0.0));
    let route = f(cfg, "route", f64::INFINITY);
    let cone = f(cfg, "cone", PI);
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
    let price = |r: &Run| -> f64 {
        let mut s = konst;
        for i in 0..ns {
            for g in 0..3 {
                s += r.sums[g * ns + i] * coef.get(4 * i + g).copied().unwrap_or(1.0);
            }
        }
        s + r.torps
    };
    let start = (h0.pos.x, h0.pos.y);
    let lie_dir = {
        let sgn: f32 = if lie_t < 0.0 { -1.0 } else { 1.0 };
        (lie_h.sin() as f32 * sgn, lie_h.cos() as f32 * sgn)
    };
    let made = |r: &Run| -> f32 { (r.last.0 - start.0) * lie_dir.0 + (r.last.1 - start.1) * lie_dir.1 };
    let vmax = pr.vmax;
    let offset = |i: usize, oh: f32| -> f64 { w * (off_w * adiff(lie_h, oh as f64).abs() + gear_w * (thr[i] as f64 - lie_t).abs()) };
    let mut steps = 0usize;

    let mut lie = sr.new_run(h0, cands[0]);
    let max_steps = (sr.m + 2) * (cands.len() + 1);
    while !sr.done(&lie) && steps < max_steps {
        sr.advance(&mut lie);
        steps += 1;
    }
    let lie_made = made(&lie);
    let cost_of = |r: &Run| -> f64 {
        if !price_later {
            return r.air;
        }
        let short_s = (lie_made as f64 - made(r) as f64).max(0.0) / vmax;
        (r.air * per_w + price(r)) * (1.0 + short_s / window)
    };
    let cost0 = cost_of(&lie);
    let score0 = cost0 + offset(0, lie.out_h.unwrap_or(lie_h as f32));
    let cap = if lie.clear { cost0 - gain * w } else { f64::INFINITY };
    let bound = |r: &Run| -> f64 {
        if !admissible {
            return f64::NEG_INFINITY;
        }
        (if price_later { r.air * per_w + price(r) } else { r.air }) + r.off
    };

    let mut runs: Vec<Run> = cands.iter().map(|&c| sr.new_run(h0, c)).collect();
    let mut open: BinaryHeap<Open> = (1..cands.len()).map(|i| Open(f64::NEG_INFINITY, i)).collect();
    let mut pick: Option<(usize, f64)> = None;
    while let Some(Open(lb, i)) = open.pop() {
        if lb > cap || steps >= max_steps {
            break;
        }
        let r = &mut runs[i];
        if sr.done(r) {
            pick = Some((i, lb));
            break;
        }
        sr.advance(r);
        steps += 1;
        if !r.clear {
            continue;
        }
        if !r.offed {
            if let Some(oh) = r.out_h {
                if !in_cone(oh as f64, thr[i] as f64) {
                    continue;
                }
                r.off = offset(i, oh);
                r.offed = true;
            }
        }
        let key = if sr.done(r) { cost_of(r) + r.off } else { bound(r) };
        open.push(Open(key, i));
    }
    // A lie that runs aground leaves the best clear candidate however it scores; one clear needs min_gain.
    out.set("pick", pick.map_or(-1, |p| p.0 as i64));
    out.set("score", pick.map_or(score0, |p| p.1));
    out.set("cost0", cost0);
    out.set("score0", score0);
    out.set("lie_clear", lie.clear);
    out.set("heading", pick.and_then(|p| runs[p.0].out_h).unwrap_or(lie.out_h.unwrap_or(0.0)) as f64);
    out.set("w", w);
    out.set("steps", steps as i64);
    out.set("missing", &pr.missing());
    out
}
