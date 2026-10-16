use std::f64::consts::{PI, TAU};

use godot::builtin::AnyArray;
use godot::classes::Node3D;
use godot::prelude::*;

use crate::combat::turret::{wrapf, Turret};

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

    /// Per mount in `list`: 1 when live and bearing on `target` with the hull at `at`.
    #[func]
    fn bearing_mask(list: AnyArray, target: Vector2, heading: f32, at: f32) -> PackedByteArray {
        let turned = diff(heading as f64, at as f64);
        mounts(&list, target).iter().map(|m| m.as_ref().map_or(0, |m| bears(m, turned) as u8)).collect()
    }
}
