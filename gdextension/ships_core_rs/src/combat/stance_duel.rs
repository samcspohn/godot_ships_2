//! SkillStance duel option scores, every option in one call. Float steps mirror the GDScript they replaced: PackedFloat32Array
//! slots round to f32 on every store, Vector2 maths in f32, the rest in f64.

use godot::builtin::AnyArray;
use godot::prelude::*;

use crate::combat::stance::track_masks;
use crate::combat::stance_price::{Pricer, Torps};
use crate::combat::stance_sec::{add as sec_add, SecCache, JOB_STRIDE};
use crate::nav::reach::ReachField;
use crate::projectile::manager::stance_cells::{gun_dps, Pack};
use crate::projectile::manager::ProjectileManager;

pub(crate) const OUT_STRIDE: usize = 7;

fn f(d: &VarDictionary, k: &str, def: f64) -> f64 {
    d.get(k).and_then(|v| v.try_to_relaxed::<f64>().ok()).unwrap_or(def)
}

fn get<T: FromGodot>(d: &VarDictionary, k: &str) -> Option<T> {
    d.get(k).and_then(|v| v.try_to::<T>().ok())
}

fn v2(d: &VarDictionary, k: &str) -> Vector2 {
    get::<Vector2>(d, k).unwrap_or(Vector2::ZERO)
}

fn f32s(d: &VarDictionary, k: &str) -> Vec<f32> {
    get::<PackedFloat32Array>(d, k).map_or_else(Vec::new, |a| a.to_vec())
}

fn f64s(d: &VarDictionary, k: &str) -> Vec<f64> {
    get::<PackedFloat64Array>(d, k).map_or_else(Vec::new, |a| a.to_vec())
}

struct Tubes {
    list: AnyArray,
    traverse: f32,
    ready: Vec<f32>,
    speed: f64,
    curve: Vec<f32>,
    range: f64,
    count: f64,
    reload: f64,
}

/// Per option [score, pred dealt, pred taken, kill s, die s, dealt share, taken share]; with the row cells
/// (Pricer::missing) and secondary cells ([job, range, aspect, bearing, sat], out jobs first) the tables lacked.
pub(crate) fn scores(cache: &mut SecCache, pm: &ProjectileManager, tracks: &[Vec<f64>], cfg: &VarDictionary)
        -> (Vec<f64>, PackedFloat64Array, Vec<f64>) {
    let price: VarDictionary = get(cfg, "price").unwrap_or_default();
    let mut pricer = Pricer::new(&price);
    let dt = f(cfg, "dt", 1.0);
    let torps_in = Torps::new(&price, pricer.dt());
    let dark_w = f(&price, "dark_w", 1.0);
    let guns: Option<AnyArray> = if get::<bool>(cfg, "guns_free").unwrap_or(false) { get(cfg, "guns") } else { None };
    let (pos0, hdg0) = (v2(cfg, "pos0"), f(cfg, "hdg0", 0.0) as f32);
    let traverse = f(cfg, "traverse", 0.0) as f32;
    let ready0 = f32s(cfg, "ready");
    let live = f(cfg, "live", 0.0).max(1.0);
    let (g_range, reload) = (f(cfg, "range", 0.0), f(cfg, "reload", 0.0));
    let (t0, tv) = (v2(cfg, "t0"), v2(cfg, "tv"));
    let t_id = get::<i64>(cfg, "t_id").unwrap_or(0);
    let hp_t = f(cfg, "hp_t", 1.0);
    let hp = f(cfg, "hp", 1.0);
    let cal = v2(cfg, "cal");
    let asp = f(cfg, "asp", 0.0);
    let affine = f64s(cfg, "affine");
    let pack = get::<VarDictionary>(cfg, "gpack").map(|d| Pack::read(&d));
    let tubes = get::<AnyArray>(cfg, "tubes").map(|list| Tubes {
        list, traverse: f(cfg, "tube_traverse", 0.0) as f32, ready: f32s(cfg, "tube_ready"), speed: f(cfg, "tube_speed", 1.0),
        curve: f32s(cfg, "tube_curve"), range: f(cfg, "tube_range", 0.0), count: f(cfg, "tube_count", 1.0),
        reload: f(cfg, "tube_reload", 0.0),
    });
    let (pb, step) = (f(cfg, "pb", 0.0), f(cfg, "curve_step", 1.0));
    let sec_out = f64s(cfg, "sec_out");
    let mut sec_in = f64s(cfg, "sec_in");
    let n_out_jobs = (sec_out.len() / JOB_STRIDE) as f64;
    let field: Option<Gd<ReachField>> = get(cfg, "field");
    let fb = field.as_ref().map(|g| g.bind());
    let team = f(cfg, "team", 0.0) as i32;
    let window = f(cfg, "window", 60.0);

    let mut out = Vec::with_capacity(tracks.len() * OUT_STRIDE);
    let mut sec_missing = Vec::new();
    for track in tracks {
        let n = track.len() / 4;
        let pos: Vec<Vector2> = (0..n).map(|k| Vector2::new(track[4 * k] as f32, track[4 * k + 1] as f32)).collect();
        let hdgs: Vec<f32> = (0..n).map(|k| track[4 * k + 2] as f32).collect();
        let tpos: Vec<Vector2> = (0..n).map(|k| t0 + tv * ((k + 1) as f32) * (dt as f32)).collect();
        let mut dealt = vec![0.0f32; n];
        if let Some(list) = guns.as_ref() {
            let masks = track_masks(list, pos0, hdg0, &pos, &hdgs, &tpos, traverse, dt as f32);
            let mut ready = ready0.clone();
            let (mut fire_k, mut fire_n, mut ranges) = (Vec::new(), Vec::new(), Vec::new());
            for k in 0..n.min(masks.len()) {
                let time = (k + 1) as f64 * dt;
                let d = pos[k].distance_to(tpos[k]) as f64;
                if d > g_range || masks[k] == 0 {
                    continue;
                }
                let mut g = 0;
                for (i, r) in ready.iter_mut().enumerate() {
                    if (*r as f64) <= time && masks[k] & (1 << i) != 0 {
                        g += 1;
                        *r = (time + reload) as f32;
                    }
                }
                if g > 0 {
                    fire_k.push(k);
                    fire_n.push(g);
                    ranges.push(d);
                }
            }
            if let (Some(p), false) = (pack.as_ref(), fire_k.is_empty()) {
                for (j, &k) in fire_k.iter().enumerate() {
                    let dps = gun_dps(pm, p, ranges[j], asp, &affine).unwrap_or(f64::NAN);
                    let per_gun = (if dps.is_finite() { dps } else { 0.0 }) * reload / live;
                    for _ in 0..fire_n[j] {
                        dealt[k] = (dealt[k] as f64 + per_gun) as f32;
                    }
                }
            }
        }
        if let Some(tb) = tubes.as_ref() {
            let masks = track_masks(&tb.list, pos0, hdg0, &pos, &hdgs, &tpos, tb.traverse, dt as f32);
            let mut ready = tb.ready.clone();
            for k in 0..n.min(masks.len()) {
                let time = (k + 1) as f64 * dt;
                let d = pos[k].distance_to(tpos[k]) as f64;
                if d > tb.range || masks[k] == 0 {
                    continue;
                }
                let land = k as i64 + (d / tb.speed / dt) as i64;
                let ci = ((d - pb) / step).round() as i64;
                let at = if ci >= 0 && (ci as usize) < tb.curve.len() { tb.curve[ci as usize] as f64 } else { 0.0 };
                let per = at / tb.count;
                for (i, r) in ready.iter_mut().enumerate() {
                    if (*r as f64) <= time && masks[k] & (1 << i) != 0 {
                        *r = (time + tb.reload) as f32;
                        if land >= 0 && (land as usize) < n {
                            dealt[land as usize] = (dealt[land as usize] as f64 + per) as f32;
                        }
                    }
                }
            }
        }
        if !sec_out.is_empty() {
            for m in sec_add(cache, pm, track, &sec_out, fb.as_deref(), team, dt, &mut dealt).chunks_exact(5) {
                sec_missing.extend_from_slice(m);
            }
        }
        let mut sum = 0.0;
        let mut kill_t = f64::INFINITY;
        for (k, &v) in dealt.iter().enumerate() {
            sum += v as f64;
            if sum >= hp_t {
                kill_t = (k + 1) as f64 * dt;
                break;
            }
        }
        pricer.set_stop(t_id, kill_t);
        let mut taken = pricer.incoming(track, dark_w);
        for (o, v) in taken.iter_mut().zip(torps_in.per_step(track, n as f64 * pricer.dt())) {
            *o += v;
        }
        if !sec_in.is_empty() {
            let s = if kill_t.is_finite() { (n as i64).min((kill_t / dt) as i64) } else { n as i64 };
            for jb in sec_in.chunks_exact_mut(JOB_STRIDE).filter(|jb| jb[0] == t_id as f64) {
                jb[11] = s as f64;
            }
            for m in sec_add(cache, pm, track, &sec_in, fb.as_deref(), team, dt, &mut taken).chunks_exact(5) {
                sec_missing.push(m[0] + n_out_jobs);
                sec_missing.extend_from_slice(&m[1..]);
            }
        }
        let pred_d = dealt.iter().fold(0.0, |a, &x| a + x as f64).min(hp_t);
        let pred_t = taken.iter().fold(0.0, |a, &x| a + x as f64);
        let (mut o, mut inn, mut die_k, mut kill_k) = (0.0, 0.0, -1i64, -1i64);
        for k in 0..n {
            o += ((dealt[k] as f64 * cal.x as f64) as f32) as f64;
            inn += ((taken[k] as f64 * cal.y as f64) as f32) as f64;
            if o >= hp_t {
                kill_k = k as i64;
                break;
            }
            if inn >= hp {
                die_k = k as i64;
                break;
            }
        }
        let ds = (o / hp_t).min(1.0);
        let ts = (inn / hp).min(1.0);
        let lost = if die_k >= 0 { (window - (die_k + 1) as f64 * dt) / window } else { 0.0 };
        let won = if kill_k >= 0 { (window - (kill_k + 1) as f64 * dt) / window } else { 0.0 };
        let kill_s = if kill_k >= 0 { (kill_k + 1) as f64 * dt } else { f64::INFINITY };
        let die_s = if die_k >= 0 { (die_k + 1) as f64 * dt } else { f64::INFINITY };
        out.extend_from_slice(&[ds - ts - lost + won, pred_d, pred_t, kill_s, die_s, ds, ts]);
    }
    (out, pricer.missing(), sec_missing)
}
