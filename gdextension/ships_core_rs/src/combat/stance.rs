use std::f64::consts::{PI, TAU};

use godot::builtin::AnyArray;
use godot::classes::Node3D;
use godot::prelude::*;

use crate::combat::turret::{wrapf, Turret};

/// A turret within this of its target's bearing counts as trained.
const TRAINED_RAD: f64 = 0.01;

/// Heading search resolution: half a degree.
const STEPS: usize = 720;

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
        let n = pos.len().min(hdg.len()).min(target.len());
        let mut out = vec![0i64; n];
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
        PackedInt64Array::from(out.as_slice())
    }

    /// Per mount in `list`: 1 when live and bearing on `target` with the hull at `at`.
    #[func]
    fn bearing_mask(list: AnyArray, target: Vector2, heading: f32, at: f32) -> PackedByteArray {
        let turned = diff(heading as f64, at as f64);
        mounts(&list, target).iter().map(|m| m.as_ref().map_or(0, |m| bears(m, turned) as u8)).collect()
    }
}
