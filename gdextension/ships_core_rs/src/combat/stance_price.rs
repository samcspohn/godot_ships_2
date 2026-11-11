//! SkillStance's track pricing (_track_slices, _track_torps) and the dodge's best-first search over its candidates.
//! Float steps mirror the GDScript they replace: Vector2 maths in f32, the rest in f64.

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};
use std::f64::consts::{PI, TAU};

use godot::prelude::*;

use crate::combat::stance_rows::StanceRows;
use crate::combat::turret::wrapf;
use crate::nav::map::NavigationMap;
use crate::nav::navigator::hull::{rudder_to_heading, Hull};
use crate::nav::reach::{ReachField, ReachLookup};
use crate::combat::stance::{shell_hit, ship_params, start_hull};
use crate::nav::types::ShipParams;

const SH_STRIDE: usize = 10;
/// Dodge hull steps: this long until the shells in the air have landed, then one price sample (cfg.dt) each.
const FINE_DT: f32 = 0.25;

/// Temporary dodge profile: [searches, total ns, land_shells ns, hull-step ns, physics steps, shell checks, hits tested].
pub(crate) static DPROF: [std::sync::atomic::AtomicU64; 7] = [const { std::sync::atomic::AtomicU64::new(0) }; 7];
fn dprof(i: usize, v: u64) {
    DPROF[i].fetch_add(v, std::sync::atomic::Ordering::Relaxed);
}
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
    /// `stop` under window2, for the second kind.
    stop2: f64,
}

impl Shooter {
    /// Salvo landings before `end`, by repeated addition as the GDScript stepped them.
    fn times(&self, end: f64) -> impl Iterator<Item = f64> + '_ {
        self.times_to(end, self.stop)
    }

    fn times_to(&self, end: f64, stop: f64) -> impl Iterator<Item = f64> + '_ {
        let stop = stop.min(end);
        let reload = self.reload;
        std::iter::successors(Some(self.first), move |&t| Some(t + reload)).take_while(move |&t| t < stop && reload > 0.0)
    }
}

pub(crate) struct Pricer {
    sh: Vec<Shooter>,
    /// cfg.kind's rows, then cfg.kind2's when given.
    rows: RefCell<[HashMap<(usize, i32), Vec<f32>>; 2]>,
    /// With cfg.pm, missing cells are filled through the store as they are met.
    store: Option<Gd<StanceRows>>,
    pm: Option<Gd<crate::projectile::manager::ProjectileManager>>,
    ids: Vec<i64>,
    kinds: [usize; 2],
    two: bool,
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
    window: f64,
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
    /// cfg: shooters [x, z, weight, group, bit, spread, range, reload, next, stop] each, store (StanceRows), ids
    /// (shooter instance ids), kind, kind2 / window2 (optional), slices, vmax, at_speed, team, field, window, skip, dt,
    /// aspects, aspect_step, bucket_m.
    pub(crate) fn new(cfg: &VarDictionary) -> Self {
        let raw = f64s(cfg, "shooters");
        let (window, skip) = (f(cfg, "window", f64::INFINITY), f(cfg, "skip", 0.0));
        let window2 = f(cfg, "window2", window);
        let sh: Vec<Shooter> = raw.chunks_exact(SH_STRIDE).map(|s| {
            let reload = s[7];
            let mut t = s[8];
            while t < skip && reload > 0.0 {
                t += reload;
            }
            Shooter { x: s[0] as f32, z: s[1] as f32, weight: s[2], group: s[3] as usize, bit: s[4] as i32, spread: s[5],
                range: s[6], reload, first: t, stop: s[9].min(window), stop2: s[9].min(window2) }
        }).collect();
        let ids: Vec<i64> = cfg.get("ids").and_then(|v| v.try_to::<PackedInt64Array>().ok()).map_or_else(Vec::new, |a| a.to_vec());
        let store = cfg.get("store").and_then(|v| v.try_to::<Gd<StanceRows>>().ok());
        let kind = |k: &str| cfg.get(k).and_then(|v| v.try_to::<i64>().ok());
        let kinds = [kind("kind").unwrap_or(0) as usize, kind("kind2").unwrap_or(1) as usize];
        let rows = match store.as_ref() {
            Some(st) => {
                let st = st.bind();
                [st.kind_rows(&ids, kinds[0]),
                    if kind("kind2").is_some() { st.kind_rows(&ids, kinds[1]) } else { HashMap::new() }]
            }
            None => [HashMap::new(), HashMap::new()],
        };
        let pm = cfg.get("pm").and_then(|v| v.try_to::<Gd<crate::projectile::manager::ProjectileManager>>().ok());
        let field = cfg.get("field").and_then(|v| v.try_to::<Gd<ReachField>>().ok());
        let team = f(cfg, "team", 0.0) as i32;
        let lookup = field.as_ref().and_then(|g| g.bind().team_fire_lookup(team));
        Pricer {
            sh, rows: RefCell::new(rows), store, pm, ids, kinds, two: kind("kind2").is_some(), missing: RefCell::new(Vec::new()), slices: f64s(cfg, "slices"), vmax: f(cfg, "vmax", 1.0).max(1.0),
            at_speed: f(cfg, "at_speed", 0.0), field: field.is_some(), lookup, dt: f(cfg, "dt", 1.0),
            n_asp: f(cfg, "aspects", 37.0) as usize, asp_step: f(cfg, "aspect_step", 5.0), bucket_m: f(cfg, "bucket_m", 250.0), window,
        }
    }

    /// Every shooter entry of instance `id` stops at `stop`, as cfg's stop column would set it.
    pub(crate) fn set_stop(&mut self, id: i64, stop: f64) {
        for (s, &sid) in self.sh.iter_mut().zip(&self.ids) {
            if sid == id {
                s.stop = stop.min(self.window);
            }
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
        self.salvo_w(i, t, x, z, hdg, speed, mask, self.sh[i].weight, 0)
    }

    #[allow(clippy::too_many_arguments)]
    fn salvo_w(&self, i: usize, t: f64, x: f32, z: f32, hdg: f64, speed: f64, mask: &mut Option<u64>, weight: f64, kind: usize)
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
        let mut cell = self.rows.borrow()[kind].get(&(i, b)).map(|row| row.get(a).copied());
        if !matches!(cell, Some(Some(v)) if !v.is_nan()) && !matches!(cell, Some(None)) && self.fill(i, r, b, a) {
            cell = self.rows.borrow()[kind].get(&(i, b)).map(|row| row.get(a).copied());
        }
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

    /// Fills shooter i's cell (bucket b at range r, aspect a) through the store and takes the bucket's rows again.
    fn fill(&self, i: usize, r: f64, b: i32, a: usize) -> bool {
        let (Some(st), Some(pm), Some(&id)) = (self.store.as_ref(), self.pm.as_ref(), self.ids.get(i)) else { return false };
        let mut st = st.clone();
        let ok = st.bind_mut().ensure_cell(&pm.bind(), id, b, r, a, self.asp_step, self.n_asp);
        if !ok {
            return false;
        }
        let Some(pair) = st.bind().pair(id, b, self.kinds) else { return false };
        let mut rows = self.rows.borrow_mut();
        let [k0, k1] = pair;
        rows[0].insert((i, b), k0);
        if self.two {
            rows[1].insert((i, b), k1);
        }
        true
    }

    /// _track_slices over `track` ([x, z, heading, speed] per dt): [on, by, dark] x slice.
    pub(crate) fn slices(&self, track: &[f64]) -> Vec<f64> {
        self.slices_k(track, 0)
    }

    /// `slices` in cfg.kind (0) or cfg.kind2 under window2 (1).
    pub(crate) fn slices_k(&self, track: &[f64], kind: usize) -> Vec<f64> {
        let n = track.len() / 4;
        let ns = self.n_slices();
        let mut out = vec![0.0; 3 * ns];
        if n == 0 {
            return out;
        }
        let end = n as f64 * self.dt;
        let mut masks: HashMap<usize, Option<u64>> = HashMap::new();
        for (i, s) in self.sh.iter().enumerate() {
            for t in s.times_to(end, if kind == 0 { s.stop } else { s.stop2 }) {
                let k = ((t / self.dt) as i64).clamp(0, n as i64 - 1) as usize;
                let p = &track[4 * k..4 * k + 4];
                let m = masks.entry(k).or_insert(None);
                if let Some((si, v)) = self.salvo_w(i, t, p[0] as f32, p[1] as f32, p[2], p[3], m, s.weight, kind) {
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
                if let Some((_, v)) = self.salvo_w(i, t, p[0] as f32, p[1] as f32, p[2], p[3], m, w, 0) {
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
    /// FINE_DT steps taken; `t` the hull's time.
    step: usize,
    t: f32,
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
    /// Shell indices by landing physics step: step k's are land_order[land_at[k]..land_at[k + 1]], ascending.
    land_at: Vec<usize>,
    land_order: Vec<usize>,
    aspect_w: Vec<f32>,
    hull: Rect2,
    cit: Rect2,
    top: f64,
    ref_cal: f64,
    cit_w: f64,
    /// Physics steps to the horizon, samples over the window, samples torps are priced over.
    n_h: usize,
    /// FINE_DT steps before the hull steps a sample at a time: the first sample at or past the horizon.
    fine_end: usize,
    m: usize,
    m_price: usize,
    n_t: usize,
    salvos: Vec<Vec<(f64, usize)>>,
    map: Option<Gd<NavigationMap>>,
    clearance: f32,
    price_later: bool,
}

impl Search<'_> {
    fn new_run(&self, h0: Hull, c: Vector3) -> Run {
        Run { c, hull: h0, step: 0, t: 0.0, k: 0, prev: (h0.pos.x, h0.pos.y), last: (h0.pos.x, h0.pos.y), air: 0.0,
            sums: vec![0.0; 3 * self.pr.n_slices()], torps: 0.0, torp_st: vec![(0.0, 0.0); self.tp.sh.len()], out_h: None,
            off: 0.0, offed: false, clear: true }
    }

    fn done(&self, r: &Run) -> bool {
        r.k >= self.m && r.out_h.is_some()
    }

    /// Sails `r` to its next sample and prices what lands by it.
    fn advance(&self, r: &mut Run) {
        let target = if r.k >= self.m { (self.n_h as f32 * FINE_DT).max(r.t) } else { r.k as f32 * self.pr.dt as f32 };
        while r.t < target - 1e-4 {
            let fine = r.step < self.fine_end;
            let h = if fine { FINE_DT } else { self.pr.dt as f32 };
            let c = r.c;
            let t0 = std::time::Instant::now();
            let rudder = if c.y < 0.0 { rudder_to_heading(&r.hull, &self.p, c.x, c.z < 0.0) } else if r.t < c.y { c.x } else { 0.0 };
            r.hull.step(&self.p, rudder, c.z, h);
            r.t += h;
            let t1 = std::time::Instant::now();
            if fine {
                r.step += 1;
                self.land_shells(r);
                if r.step == self.n_h {
                    r.out_h = Some(r.hull.heading);
                }
            }
            dprof(3, (t1 - t0).as_nanos() as u64);
            dprof(2, t1.elapsed().as_nanos() as u64);
            dprof(4, 1);
        }
        if r.step == 0 && r.k == 0 {
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
        if r.t <= self.n_h as f32 * FINE_DT + 1e-4 {
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
        if r.step > self.n_h {
            return;
        }
        let (lo, hi) = (self.land_at[r.step], self.land_at[r.step + 1]);
        dprof(5, (hi - lo) as u64);
        for &j in &self.land_order[lo..hi] {
            dprof(6, 1);
            let s = &self.shells[7 * j..7 * j + 7];
            r.air += shell_hit(s, j, &r.hull, self.hull, self.cit, self.top, self.ref_cal, self.cit_w, &self.aspect_w, n);
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
    let t_all = std::time::Instant::now();
    let out = dodge_search_inner(cfg);
    dprof(0, 1);
    dprof(1, t_all.elapsed().as_nanos() as u64);
    out
}

fn dodge_search_inner(cfg: &VarDictionary) -> VarDictionary {
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
    let every = ((dt as f32 / FINE_DT).round() as usize).max(1);
    let n_h = (horizon / FINE_DT).ceil().max(0.0) as usize;
    let fine_end = n_h.div_ceil(every) * every;
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
    let shells = f32s(cfg, "shells");
    let land_k: Vec<usize> = shells.chunks_exact(7).map(|s| ((s[4] / FINE_DT).round().max(0.0) as usize).min(n_h)).collect();
    let mut land_order: Vec<usize> = (0..land_k.len()).collect();
    land_order.sort_by_key(|&j| (land_k[j], j));
    let mut land_at = vec![0usize; n_h + 2];
    for &k in &land_k {
        land_at[k + 1] += 1;
    }
    for k in 0..=n_h {
        land_at[k + 1] += land_at[k];
    }
    let sr = Search {
        p, pr: &pr, tp: &tp, shells, land_at, land_order, aspect_w: f32s(cfg, "aspect_w"),
        hull: cfg.get("hull").and_then(|v| v.try_to::<Rect2>().ok()).unwrap_or_default(),
        cit: cfg.get("cit").and_then(|v| v.try_to::<Rect2>().ok()).unwrap_or_default(),
        top: f(cfg, "top", 0.0), ref_cal: f(cfg, "ref_cal", 300.0), cit_w: f(cfg, "cit_w", 0.0),
        n_h, fine_end, m: if price_later { m.max(n_h / every + 1) } else { n_h / every + 1 }, m_price: m,
        n_t: m.min((window / dt) as usize), salvos, map, clearance: f(cfg, "clearance", 0.0) as f32, price_later,
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
