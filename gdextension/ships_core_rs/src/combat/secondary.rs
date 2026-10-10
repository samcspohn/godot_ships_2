use std::collections::HashMap;

use godot::builtin::{AnyArray, AnyDictionary};
use godot::classes::{Node3D, Object, Resource, RigidBody3D};
use godot::prelude::*;

use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2 as Drag;
use crate::combat::turret::{GunStats, Turret};
use crate::names::names;
use crate::variant_cast::VariantCast;

names!(guns, get_params, get_shell_params, super_structure;);

thread_local! {
    // Dropping StringNames after engine shutdown panics.
    static NAMES: std::mem::ManuallyDrop<Names> = std::mem::ManuallyDrop::new(Names::new());
}

// Typed GDScript dictionaries are read-only through AnyDictionary.
fn put(d: &AnyDictionary, k: &Variant, v: Variant) {
    d.to_variant().call("set", &[k.clone(), v]);
}

fn horizontal(a: Vector3, b: Vector3) -> f64 {
    let mut d = a - b;
    d.y = 0.0;
    d.length() as f64 - 0.001
}

/// SecondaryController_._update_cached_auto_aim.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SecondaryAim {
    base: Base<RefCounted>,
}

#[godot_api]
impl SecondaryAim {
    /// Aims every auto-targeted secondary at its cached target's lead (without `solve`, guns
    /// with a goal only rotate toward it); returns whether any gun is active.
    #[func]
    fn aim(sub_controllers: AnyArray, gun_targets: AnyDictionary, can_shoot: AnyDictionary, manual: AnyDictionary,
            priority: Variant, target_offset: Vector3, time_mult: f32, ship_pos: Vector3, delta: f64, solve: bool) -> bool {
        NAMES.with(|n| {
            let priority = priority.try_to::<Gd<Object>>().ok().map(|o| o.instance_id());
            let mut active = false;
            for sc in sub_controllers.iter_shared() {
                let Ok(mut sc) = sc.try_to::<Gd<Object>>() else { continue };
                let Ok(params) = sc.call(&n.get_params, &[]).try_to::<Gd<Resource>>() else { continue };
                let Ok(shell) = sc.call(&n.get_shell_params, &[]).try_to::<Gd<Resource>>() else { continue };
                let stats = GunStats::of(&params);
                let mut leads: HashMap<InstanceId, Option<Vector3>> = HashMap::new();
                for gv in sc.get(&n.guns).to_any_array().iter_shared() {
                    let Ok(node) = gv.try_to::<Gd<Node3D>>() else { continue };
                    if manual.contains_key(&gv) {
                        continue;
                    }
                    let tv = gun_targets.get(&gv).unwrap_or_default();
                    let aiming = !tv.is_nil() && can_shoot.get(&gv).is_some_and(|v| v.to_bool());
                    if !solve && aiming && Turret::gun_track(&node, delta, &stats) {
                        active = true;
                        continue;
                    }
                    let mut g = Turret::load(node.clone());
                    if tv.is_nil() || !can_shoot.get(&gv).is_some_and(|v| v.to_bool()) {
                        active |= g.gun_home(delta, stats.traverse);
                        g.store();
                        continue;
                    }
                    let Ok(e) = tv.try_to::<Gd<RigidBody3D>>() else {
                        put(&gun_targets, &gv, Variant::nil());
                        put(&can_shoot, &gv, false.to_variant());
                        active |= g.gun_home(delta, stats.traverse);
                        g.store();
                        continue;
                    };
                    let pos = if priority == Some(e.instance_id()) {
                        e.to_global(target_offset)
                    } else {
                        e.get(&n.super_structure).try_to::<Gd<Node3D>>().map_or(e.get_global_position(), |s| s.get_global_position())
                    };
                    let gun_pos = node.get_global_position();
                    let lead = *leads.entry(e.instance_id()).or_insert_with(|| {
                        let sol = Drag::calculate_leading_launch_vector_impl(gun_pos, pos, e.get_linear_velocity() / time_mult, &shell);
                        sol.at(2).try_to::<Vector3>().ok().filter(|_| horizontal(pos, ship_pos) < stats.range)
                    });
                    let valid = horizontal(pos, ship_pos) < stats.range && g.bearing_valid(pos);
                    match lead {
                        Some(l) if l != Vector3::ZERO && valid => {
                            g.gun_aim(l, delta, false, false, ship_pos, &stats, &shell);
                            active = true;
                        }
                        _ => {
                            put(&can_shoot, &gv, false.to_variant());
                            active |= g.gun_home(delta, stats.traverse);
                        }
                    }
                    g.store();
                }
            }
            active
        })
    }
}
