use std::f64::consts::{PI, TAU};

use godot::builtin::AnyArray;
use godot::classes::Node3D;
use godot::prelude::*;

use crate::combat::turret::{wrapf, Turret};
use crate::nav::navigator::hull::{rudder_to_heading, Hull, PHYSICS_DT};
use crate::nav::types::{normalize_angle, ShipParams};

/// A turret within this of its target's bearing counts as trained.
const TRAINED_RAD: f64 = 0.01;

/// Heading search resolution: half a degree.
const STEPS: usize = 720;

/// SkillStance.SWUNG.
const SWUNG: f64 = 3.0 * PI / 180.0;

fn diff(from: f64, to: f64) -> f64 {
    wrapf(to - from, -PI, PI)
}

/// Per mount (None when disabled or not a turret): the rotation, relative to
/// the hull as it lies now, that bears it on `target`.
fn mounts(list: &AnyArray, target: Vector2) -> Vec<Option<(f64, Turret)>> {
    let t3 = Vector3::new(target.x, 0.0, target.y);
    list.iter_shared().map(|g| {
        let t = Turret::load(g.try_to::<Gd<Node3D>>().ok()?);
        (!t.is_disabled()).then(|| (t.rot_y() + t.angle_to_target(t3), t))
    }).collect()
}

fn bears(m: &(f64, Turret), turned: f64) -> bool {
    m.1.in_fire_arcs(wrapf(m.0 - turned, -PI, PI))
}

/// Hull-heading helpers for SkillStance: which mounts bear on a point at a
/// given heading, and the headings nearest a wanted one at which they do.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct StanceSim {
    base: Base<RefCounted>,
}

#[godot_api]
impl StanceSim {
    /// Nearest hull heading to `want`, turning each way ([one way, the other]),
    /// at which every live mount (`all`) or any live mount bears on `target`;
    /// empty when none does. `heading` is the hull's heading now.
    #[func]
    fn nearest_bearing(list: AnyArray, target: Vector2, heading: f32, want: f32, all: bool) -> PackedFloat32Array {
        let live: Vec<(f64, Turret)> = mounts(&list, target).into_iter().flatten().collect();
        if live.is_empty() {
            return PackedFloat32Array::new();
        }
        let (h0, w) = (heading as f64, want as f64);
        let ok = |h: f64| {
            let turned = diff(h0, h);
            if all { live.iter().all(|m| bears(m, turned)) } else { live.iter().any(|m| bears(m, turned)) }
        };
        let step = TAU / STEPS as f64;
        let first = |sign: f64| (0..=STEPS / 2).map(|k| wrapf(w + sign * k as f64 * step, -PI, PI)).find(|&h| ok(h));
        match (first(1.0), first(-1.0)) {
            (Some(a), Some(b)) => PackedFloat32Array::from(&[a as f32, b as f32][..]),
            _ => PackedFloat32Array::new(),
        }
    }

    /// Per step of a hull track (`pos`, `hdg`: 0 = +Z, π/2 = +X), with the hull now at `pos0`/`hdg0`: a
    /// bitmask of the live mounts trained on `target` (one point per step) and inside their fire arcs. Each
    /// mount slews from where it lies now at `traverse_deg_s` for `dt` a step, the long way round its rotation limits.
    #[func]
    fn track_bearing(list: AnyArray, pos0: Vector2, hdg0: f32, pos: PackedVector2Array, hdg: PackedFloat32Array,
            target: PackedVector2Array, traverse_deg_s: f32, dt: f32) -> PackedInt64Array {
        PackedInt64Array::from(track_masks(&list, pos0, hdg0, pos.as_slice(), hdg.as_slice(), target.as_slice(), traverse_deg_s, dt).as_slice())
    }

    /// SkillStance's dodge, sailed on the navigator's hull: per candidate [cost, heading at `horizon`]. A candidate is
    /// (rudder order, seconds held, power): the rudder held that long and then centred, the hull swinging on as it
    /// answers; a negative hold steers for heading x instead (the lie). The cost is the weight of the shells in the
    /// air that strike the hull, each its caliber over `ref_cal` cubed, citadel ones `cit_w` extra. `shells` is
    /// [landing x, z, fall vx, vz, seconds left, threat_half_len, caliber] each; `params` ShipNavigator's
    /// get_debug_arc_inputs; `state` [x, z, vx, vz, heading, yaw rate, rudder, power]. Boxes are (side, forward)
    /// metres in the hull frame; `top` how high above the water a falling shell still strikes.
    #[func]
    #[allow(clippy::too_many_arguments)]
    /// `aspect_w`: per shell, its damage per hit at each aspect off our bow (0..180, evenly), alpha 1; empty, all 1.
    fn dodge_costs(shells: PackedFloat32Array, hull: Rect2, cit: Rect2, top: f32, ref_cal: f32, cit_w: f32,
            params: PackedFloat32Array, state: PackedFloat32Array, cands: PackedVector3Array, horizon: f32,
            aspect_w: PackedFloat32Array) -> PackedFloat32Array {
        let (Some(p), Some(h0)) = (ship_params(params.as_slice()), start_hull(state.as_slice())) else {
            return PackedFloat32Array::new();
        };
        let sh = shells.as_slice();
        let mut track = Vec::new();
        let mut out = Vec::with_capacity(cands.len() * 2);
        for c in cands.as_slice() {
            sail(&p, h0, *c, horizon, &mut track);
            out.push(shell_cost(sh, &track, hull, cit, top as f64, ref_cal as f64, cit_w as f64, aspect_w.as_slice()) as f32);
            out.push(track.last().map_or(h0.heading, |h| h.heading));
        }
        PackedFloat32Array::from(out.as_slice())
    }

    /// One dodge candidate's hull positions every `every` seconds over `horizon`, for SkillStance's land check.
    /// SkillStance._track_slices and _track_torps over `track` ([x, z, heading, speed] per cfg.dt): {slices ([on, by, dark]
    /// x slice), torps, missing ([shooter, range, aspect] of row cells not in cfg.rows)}. cfg as stance_price::Pricer / Torps.
    #[func]
    fn track_price(track: PackedFloat64Array, cfg: VarDictionary) -> VarDictionary {
        let pr = crate::combat::stance_price::Pricer::new(&cfg);
        let t = track.as_slice();
        let mut out = VarDictionary::new();
        out.set("slices", &PackedFloat64Array::from(pr.slices(t).as_slice()));
        if cfg.contains_key("kind2") {
            out.set("slices2", &PackedFloat64Array::from(pr.slices_k(t, 1).as_slice()));
        }
        let window = cfg.get("window").and_then(|v| v.try_to::<f64>().ok()).unwrap_or(f64::INFINITY);
        out.set("torps", crate::combat::stance_price::Torps::new(&cfg, pr.dt()).sum(t, window));
        out.set("missing", &pr.missing());
        out
    }

    /// SkillStance._track_incoming over `track`: {steps (PackedFloat32Array), missing}; cfg as track_price plus dark_w.
    #[func]
    fn track_incoming(track: PackedFloat64Array, cfg: VarDictionary) -> VarDictionary {
        let pr = crate::combat::stance_price::Pricer::new(&cfg);
        let t = track.as_slice();
        let dark_w = cfg.get("dark_w").and_then(|v| v.try_to::<f64>().ok()).unwrap_or(1.0);
        let mut steps = pr.incoming(t, dark_w);
        let torps = crate::combat::stance_price::Torps::new(&cfg, pr.dt()).per_step(t, (t.len() / 4) as f64 * pr.dt());
        for (o, v) in steps.iter_mut().zip(torps) {
            *o += v;
        }
        let mut out = VarDictionary::new();
        out.set("steps", &PackedFloat32Array::from(steps.as_slice()));
        out.set("missing", &pr.missing());
        out
    }

    /// The dodge's pick among cfg.cands, best first (stance_price::dodge_search).
    /// SkillStance._cut over helm_paths' leg at `from` (`m` points, the first the start; heading in z): `c` = [start x,
    /// z, goal dir x, z, want, final, swung, then, after_s, reach, clearance, dt]. Returns [steps kept, -1 aground;
    /// seconds the swing took].
    #[func]
    fn cut(paths: PackedVector3Array, from: i64, m: i64, c: PackedFloat64Array, map: Option<Gd<crate::nav::map::NavigationMap>>)
            -> PackedFloat64Array {
        let ps = paths.as_slice();
        let (from, m) = (from.max(0) as usize, m.max(0) as usize);
        if c.len() < 12 || from + m > ps.len() || m == 0 {
            return PackedFloat64Array::from(&[-1.0, 0.0][..]);
        }
        let c = c.as_slice();
        let (start, gdir) = (Vector2::new(c[0] as f32, c[1] as f32), Vector2::new(c[2] as f32, c[3] as f32));
        let (want, mut fin, swung, mut then, after_s, reach, clearance, dt) = (c[4], c[5], c[6] != 0.0, c[7], c[8], c[9], c[10], c[11]);
        let mb = map.as_ref().map(|g| g.bind());
        let n = m - 1;
        let mut swing_k: i64 = -1;
        let mut first_s = -1.0;
        let mut after = 0.0;
        let secs = |swing_k: i64, k: usize, first_s: f64| if first_s >= 0.0 { first_s } else if swing_k >= 0 {
            (swing_k + 1) as f64 * dt } else { k as f64 * dt };
        for k in 0..n {
            let q = ps[from + k + 1];
            let prev = ps[from + k];
            let at = Vector2::new(q.x, q.y);
            if then.is_finite() && (k + 1) as f64 * dt >= after_s {
                first_s = if swing_k >= 0 { (swing_k + 1) as f64 * dt } else { (k + 1) as f64 * dt };
                fin = then;
                then = f64::INFINITY;
                swing_k = -1;
                after = 0.0;
            }
            if swing_k < 0 && crate::combat::stance_price::adiff(q.z as f64, fin).abs() <= SWUNG {
                swing_k = k as i64;
            }
            if swing_k >= 0 {
                after += (Vector2::new(q.x - prev.x, q.y - prev.y).length() as f64 / dt) * dt;
            }
            if after <= reach && mb.as_ref().map_or(10000.0, |mp| mp.get_distance_impl(at.x, at.y)) < clearance as f32 {
                return PackedFloat64Array::from(&[-1.0, 0.0][..]);
            }
            if (swing_k >= 0 || !swung) && ((at - start).dot(gdir) as f64) >= want {
                return PackedFloat64Array::from(&[(k + 1) as f64, secs(swing_k, k + 1, first_s)][..]);
            }
        }
        PackedFloat64Array::from(&[n as f64, secs(swing_k, n, first_s)][..])
    }

    /// BotBehavior.aggro_radius's search: over `ranges` (far to near), how `scorer` would rank us (priority_value of
    /// score_parts from its curves) until that passes `tank` x `switch`. [take, release], -1 where none.
    /// `k`: [our hp, its hp, its reach, torpedo speed, reload, bear s, point blank m, step m, harm cap].
    #[func]
    fn aggro_take(danger: PackedFloat32Array, tdanger: PackedFloat32Array, dps: PackedFloat32Array, torp: PackedFloat32Array,
            k: PackedFloat64Array, ranges: PackedFloat64Array, tank: f64, switch: f64) -> PackedFloat64Array {
        let k = k.as_slice();
        if k.len() < 9 {
            return PackedFloat64Array::from(&[-1.0, -1.0][..]);
        }
        let (shp, hp, reach, speed, reload, bear, pb, step, cap) = (k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8]);
        let (danger, tdanger, dps, torp) = (danger.as_slice(), tdanger.as_slice(), dps.as_slice(), torp.as_slice());
        let at = |c: &[f32], r: f64| -> f64 {
            let i = ((r - pb) / step).round() as i64;
            if i >= 0 && (i as usize) < c.len() { c[i as usize] as f64 } else { 0.0 }
        };
        let (mut take, mut release) = (-1.0, -1.0);
        for &r in ranges.as_slice() {
            let threat = at(danger, r) / shp + at(tdanger, r);
            let a = r.min(reach);
            let salvo = at(torp, a);
            let gun = if dps.is_empty() { 0.0 } else {
                dps[(((a - pb) / step).round() as i64).clamp(0, dps.len() as i64 - 1) as usize] as f64
            };
            let ours = gun / hp + if salvo > 0.0 { 1.0 / (bear + a / speed + reload * (hp / salvo - 1.0).max(0.0)) } else { 0.0 };
            let x = (100.0 * threat) as f32 as f64;
            let y = (100.0 * ours) as f32 as f64;
            let w = (threat / ours.max(1e-6)).min(cap) as f32 as f64;
            let v = x * y * (1.0 + w);
            if v > tank * switch {
                break;
            }
            take = r;
            if v <= tank / switch {
                release = r;
            }
        }
        PackedFloat64Array::from(&[take, release][..])
    }

    /// Per range, stance_cells::gun_dps of `pack` (BotGunnery.stance_cell_pack) at `aspect`; NAN unknown.
    #[func]
    fn gun_dealt(pm: Gd<crate::projectile::manager::ProjectileManager>, pack: VarDictionary, ranges: PackedFloat64Array,
            aspect: f64, cal_ab: PackedFloat64Array) -> PackedFloat64Array {
        let p = crate::projectile::manager::stance_cells::Pack::read(&pack);
        let pm = pm.bind();
        let v: Vec<f64> = ranges.as_slice().iter()
            .map(|&r| crate::projectile::manager::stance_cells::gun_dps(&pm, &p, r, aspect, cal_ab.as_slice()).unwrap_or(f64::NAN)).collect();
        PackedFloat64Array::from(v.as_slice())
    }

    /// stance_duel::scores over `tracks` (_pack_track each): {out, rows, sec}.
    #[func]
    fn duel_scores(mut cache: Gd<crate::combat::stance_sec::SecCache>, pm: Gd<crate::projectile::manager::ProjectileManager>,
            tracks: VarArray, cfg: VarDictionary) -> VarDictionary {
        let tr: Vec<Vec<f64>> = tracks.iter_shared().map(|v| v.try_to::<PackedFloat64Array>().map_or_else(|_| Vec::new(), |a| a.to_vec())).collect();
        let (o, rows, sec) = crate::combat::stance_duel::scores(&mut cache.bind_mut(), &pm.bind(), &tr, &cfg);
        let mut out = VarDictionary::new();
        out.set("out", &PackedFloat64Array::from(o.as_slice()));
        out.set("rows", &rows);
        out.set("sec", &PackedFloat64Array::from(sec.as_slice()));
        out
    }

    /// stance_sec::add over `steps`: {steps, missing ([job, range, aspect, bearing] each)}.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn secondaries(mut cache: Gd<crate::combat::stance_sec::SecCache>, pm: Gd<crate::projectile::manager::ProjectileManager>,
            track: PackedFloat64Array, jobs: PackedFloat64Array, field: Option<Gd<crate::nav::reach::ReachField>>, team: i32,
            dt: f64, steps: PackedFloat32Array) -> VarDictionary {
        let mut st = steps.to_vec();
        let fb = field.as_ref().map(|f| f.bind());
        let missing = crate::combat::stance_sec::add(&mut cache.bind_mut(), &pm.bind(), track.as_slice(), jobs.as_slice(),
            fb.as_deref(), team, dt, &mut st);
        let mut out = VarDictionary::new();
        out.set("steps", &PackedFloat32Array::from(st.as_slice()));
        out.set("missing", &PackedFloat64Array::from(missing.as_slice()));
        out
    }

    #[func]
    fn dodge_prof() -> PackedInt64Array {
        let v: Vec<i64> = crate::combat::stance_price::DPROF.iter().map(|a| a.load(std::sync::atomic::Ordering::Relaxed) as i64).collect();
        PackedInt64Array::from(v.as_slice())
    }

    #[func]
    fn dodge_search(cfg: VarDictionary) -> VarDictionary {
        crate::combat::stance_price::dodge_search(&cfg)
    }

    #[func]
    fn dodge_track(params: PackedFloat32Array, state: PackedFloat32Array, cand: Vector3, horizon: f32, every: f32) -> PackedVector2Array {
        let (Some(p), Some(h0)) = (ship_params(params.as_slice()), start_hull(state.as_slice())) else {
            return PackedVector2Array::new();
        };
        let mut track = Vec::new();
        sail(&p, h0, cand, horizon, &mut track);
        let k = ((every / PHYSICS_DT).round() as usize).max(1);
        track.iter().step_by(k).map(|h| h.pos).collect()
    }

    /// Every candidate's (x, z, heading) every `every` seconds over `horizon`, `horizon / every` + 1 points each, back to back.
    #[func]
    fn dodge_paths(params: PackedFloat32Array, state: PackedFloat32Array, cands: PackedVector3Array, horizon: f32, every: f32) -> PackedVector3Array {
        let (Some(p), Some(h0)) = (ship_params(params.as_slice()), start_hull(state.as_slice())) else {
            return PackedVector3Array::new();
        };
        let k = ((every / PHYSICS_DT).round() as usize).max(1);
        let n = (horizon / every).floor() as usize + 1;
        let mut track = Vec::new();
        let mut out = Vec::with_capacity(cands.len() * n);
        for c in cands.as_slice() {
            sail(&p, h0, *c, horizon, &mut track);
            out.extend((0..n).map(|i| { let h = track[(i * k).min(track.len() - 1)]; Vector3::new(h.pos.x, h.pos.y, h.heading) }));
        }
        PackedVector3Array::from(out.as_slice())
    }

    /// SkillStance's own tracks on the navigator's hull: per leg [heading, power, way, then, after_s], the bow steered
    /// for `heading` (way ±1: round that way, the stance's lead), for `then` once `after_s` has run (INF: never);
    /// (x, z, heading) every `every` seconds over `horizon`, `horizon / every` + 1 points each, back to back.
    #[func]
    fn helm_paths(params: PackedFloat32Array, state: PackedFloat32Array, legs: PackedFloat32Array, horizon: f32, every: f32) -> PackedVector3Array {
        let (Some(p), Some(h0)) = (ship_params(params.as_slice()), start_hull(state.as_slice())) else {
            return PackedVector3Array::new();
        };
        let k = ((every / PHYSICS_DT).round() as usize).max(1);
        let n = (horizon / every).floor() as usize + 1;
        let steps = (horizon / PHYSICS_DT).ceil().max(0.0) as usize;
        let mut out = Vec::new();
        for l in legs.as_slice().chunks_exact(5) {
            let mut h = h0;
            for s in 0..=steps {
                if s % k == 0 && s / k < n {
                    out.push(Vector3::new(h.pos.x, h.pos.y, h.heading));
                }
                let t = s as f32 * PHYSICS_DT;
                let (want, way) = if l[3].is_finite() && t >= l[4] { (l[3], 0.0) } else { (l[0], l[2]) };
                let left = normalize_angle(want - h.heading);
                let aim = if way != 0.0 && left.abs() > std::f32::consts::FRAC_PI_2 && left.signum() != way {
                    h.heading + way * std::f32::consts::FRAC_PI_2
                } else { want };
                h.step(&p, rudder_to_heading(&h, &p, aim, l[1] < 0.0), l[1], PHYSICS_DT);
            }
        }
        PackedVector3Array::from(out.as_slice())
    }

    /// The navigator's path through `pts` at full ahead, a point passed within `wp_m`, on the hull: (x, z, heading)
    /// every `every` seconds until the last is reached or `horizon` runs out.
    #[func]
    fn route_path(params: PackedFloat32Array, state: PackedFloat32Array, pts: PackedVector2Array, wp_m: f32, horizon: f32, every: f32) -> PackedVector3Array {
        let (Some(p), Some(mut h)) = (ship_params(params.as_slice()), start_hull(state.as_slice())) else {
            return PackedVector3Array::new();
        };
        let k = ((every / PHYSICS_DT).round() as usize).max(1);
        let steps = (horizon / PHYSICS_DT).ceil().max(0.0) as usize;
        let pts = pts.as_slice();
        let mut i = 0;
        let mut out = Vec::new();
        for s in 1..=steps {
            while i < pts.len() && h.pos.distance_to(pts[i]) < wp_m {
                i += 1;
            }
            if i >= pts.len() {
                break;
            }
            let to = pts[i] - h.pos;
            h.step(&p, rudder_to_heading(&h, &p, to.x.atan2(to.y), false), 1.0, PHYSICS_DT);
            if s % k == 0 {
                out.push(Vector3::new(h.pos.x, h.pos.y, h.heading));
            }
        }
        PackedVector3Array::from(out.as_slice())
    }

    /// Per mount in `list`: 1 when live and bearing on `target` with the hull at `at`.
    #[func]
    fn bearing_mask(list: AnyArray, target: Vector2, heading: f32, at: f32) -> PackedByteArray {
        let turned = diff(heading as f64, at as f64);
        mounts(&list, target).iter().map(|m| m.as_ref().map_or(0, |m| bears(m, turned) as u8)).collect()
    }
}

pub(crate) fn ship_params(v: &[f32]) -> Option<ShipParams> {
    if v.len() < 19 {
        return None;
    }
    Some(ShipParams {
        turning_circle_radius: v[0], rudder_response_time: v[1], acceleration_time: v[2], max_speed: v[3],
        reverse_speed_ratio: v[4], ship_length: v[5], ship_beam: v[6], turn_speed_loss: v[7],
        turn_tightening: v[17], linear_drag: v[18], ..ShipParams::default()
    })
}

pub(crate) fn start_hull(s: &[f32]) -> Option<Hull> {
    (s.len() >= 8).then(|| Hull { pos: Vector2::new(s[0], s[1]), vel: Vector2::new(s[2], s[3]), heading: s[4], yaw: s[5],
        rudder: s[6], power: s[7] })
}

/// The hull every physics tick for `horizon` under candidate `c` (see dodge_costs).
fn sail(p: &ShipParams, h0: Hull, c: Vector3, horizon: f32, track: &mut Vec<Hull>) {
    let n = (horizon / PHYSICS_DT).ceil().max(0.0) as usize;
    let mut h = h0;
    track.clear();
    track.push(h);
    for k in 0..n {
        let t = k as f32 * PHYSICS_DT;
        let rudder = if c.y < 0.0 { rudder_to_heading(&h, p, c.x, c.z < 0.0) } else if t < c.y { c.x } else { 0.0 };
        h.step(p, rudder, c.z, PHYSICS_DT);
        track.push(h);
    }
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
fn shell_cost(sh: &[f32], track: &[Hull], hull: Rect2, cit: Rect2, top: f64, ref_cal: f64, cit_w: f64, aspect_w: &[f32]) -> f64 {
    let n_shells = sh.len() / 7;
    sh.chunks_exact(7).enumerate().map(|(j, s)| {
        let k = ((s[4] / PHYSICS_DT).round().max(0.0) as usize).min(track.len() - 1);
        shell_hit(s, j, &track[k], hull, cit, top, ref_cal, cit_w, aspect_w, n_shells)
    }).sum()
}

/// Shell j's weight if it strikes the hull at `at` (see dodge_costs), else 0.
#[allow(clippy::too_many_arguments)]
pub(crate) fn shell_hit(s: &[f32], j: usize, at: &Hull, hull: Rect2, cit: Rect2, top: f64, ref_cal: f64, cit_w: f64,
        aspect_w: &[f32], n_shells: usize) -> f64 {
    let n_asp = if n_shells > 0 { aspect_w.len() / n_shells } else { 0 };
    let (ax, az, ah) = (at.pos.x as f64, at.pos.y as f64, at.heading as f64);
    let (fx, fz) = (ah.sin(), ah.cos());
    let (sx, sz) = (-ah.cos(), ah.sin());
    let (wx, wz) = (s[0] as f64 - ax, s[1] as f64 - az);
    let (vx, vz) = (s[2] as f64, s[3] as f64);
    let vl = (vx * vx + vz * vz).sqrt();
    let (dx, dz) = if vl > 1e-3 { (vx / vl, vz / vl) } else { (0.0, 0.0) };
    // threat_half_len encodes the sine of the fall's angle from vertical.
    let f = ((s[5] as f64 - 15.0) / 35.0).clamp(0.0, 0.99);
    let run = top * f / (1.0 - f * f).sqrt();
    let (ux, uz) = (wx - dx * run, wz - dz * run);
    let a = (ux * sx + uz * sz, ux * fx + uz * fz);
    let b = (wx * sx + wz * sz, wx * fx + wz * fz);
    if !segment_in(a, b, hull) {
        return 0.0;
    }
    // Off our bow, the bearing the shell comes from: what it meets there.
    let w = if n_asp > 1 {
        let off = diff(ah, (-vx).atan2(-vz)).abs();
        let i = ((off / PI * (n_asp - 1) as f64).round() as usize).min(n_asp - 1);
        aspect_w[j * n_asp + i] as f64
    } else { 1.0 };
    w * (s[6] as f64 / ref_cal).powi(3) * (1.0 + if segment_in(a, b, cit) { cit_w } else { 0.0 })
}

/// Whether segment a-b crosses `r` (Liang-Barsky).
fn segment_in(a: (f64, f64), b: (f64, f64), r: Rect2) -> bool {
    let (x0, y0) = (r.position.x as f64, r.position.y as f64);
    let (x1, y1) = (x0 + r.size.x as f64, y0 + r.size.y as f64);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    for (p, q) in [(-dx, a.0 - x0), (dx, x1 - a.0), (-dy, a.1 - y0), (dy, y1 - a.1)] {
        if p.abs() < 1e-9 {
            if q < 0.0 {
                return false;
            }
            continue;
        }
        let t = q / p;
        if p < 0.0 { t0 = t0.max(t) } else { t1 = t1.min(t) }
        if t0 > t1 {
            return false;
        }
    }
    true
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn track_masks(list: &AnyArray, pos0: Vector2, hdg0: f32, pos: &[Vector2], hdg: &[f32], target: &[Vector2],
        traverse_deg_s: f32, dt: f32) -> Vec<i64> {
    let n = pos.len().min(hdg.len()).min(target.len());
    let mut out = vec![0i64; n];
    if n == 0 {
        return out;
    }
    let fwd = |h: f64| Vector2::new(h.sin() as f32, h.cos() as f32);
    let right = |h: f64| Vector2::new(h.cos() as f32, -h.sin() as f32);
    // Signed angle off `f` to `d`, as Turret::angle_to_target measures it.
    let off = |f: Vector2, d: Vector2| { let d = d.normalized_or_zero(); d.cross(f).atan2(d.dot(f)) as f64 };
    let max_step = (traverse_deg_s as f64).to_radians() * dt as f64;
    for (bit, g) in list.iter_shared().enumerate().take(63) {
        let Ok(node) = g.try_to::<Gd<Node3D>>() else { continue };
        let t = Turret::load(node.clone());
        if t.is_disabled() {
            continue;
        }
        let gp = node.get_global_position();
        let rel = Vector2::new(gp.x, gp.z) - pos0;
        let (along, across) = (rel.dot(fwd(hdg0 as f64)), rel.dot(right(hdg0 as f64)));
        let mount = |k: usize| { let h = hdg[k] as f64; pos[k] + fwd(h) * along + right(h) * across };
        let t0 = Vector3::new(target[0].x, 0.0, target[0].y);
        // Hull-relative bearing to turret rotation: fixed while the hull carries the mount.
        let c = t.rot_y() + t.angle_to_target(t0) - off(fwd(hdg0 as f64), Vector2::new(t0.x, t0.z) - Vector2::new(gp.x, gp.z));
        let mut y = t.rot_y();
        for k in 0..n {
            let want = wrapf(c + off(fwd(hdg[k] as f64), target[k] - mount(k)), -PI, PI);
            let step = t.apply_rotation_limits(y, wrapf(want - y, -PI, PI)).clamp(-max_step, max_step);
            y = wrapf(y + step, -PI, PI);
            if wrapf(want - y, -PI, PI).abs() <= TRAINED_RAD && t.in_fire_arcs(want) {
                out[k] |= 1 << bit;
            }
        }
    }
    out
}
