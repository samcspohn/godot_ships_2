use godot::prelude::*;
use godot::classes::{Node, PhysicsDirectSpaceState3D};

use super::{
    hit_result, ArmorHitResult, ArmorResult, NativeArmorInteraction, RaycastCache,
    ShellState, DEFLECTION_GAMMA, EPSILON, MIN_VELOCITY, TD_ENGAGE_POWER, TD_ENGAGE_REF,
    TD_MOD_MAX, TD_MOD_ONSET, TD_MOD_SCALE, WATER_DRAG,
};
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::nav::map::NavigationMap;
use crate::projectile::data::ProjectileData;

/// Mirrors the C++ anonymous-namespace `constexpr double INF_DIST`.
const INF_DIST: f64 = 1.0e300;
/// Mirrors the C++ anonymous-namespace `DEG_TO_RAD` (`Math::PI` is double).
const DEG_TO_RAD: f64 = std::f64::consts::PI / 180.0;

/// Mirrors the C++ anonymous-namespace `static double clampd(...)`.
fn clampd(v: f64, lo: f64, hi: f64) -> f64 {
    lo.max(v.min(hi))
}

/// Mirrors the C++ anonymous-namespace `static Vector3 basis_xform(...)`.
/// `basis_xform_inv` (the other C++ anonymous-namespace helper) is never called
/// anywhere in native_armor_interaction.cpp — genuine dead code — so it is not
/// ported; every call site here that needs an inverse transform passes an
/// already-inverted Basis into this same function, exactly as the C++ does.
fn basis_xform(basis: &Basis, v: Vector3) -> Vector3 {
    Vector3::new(basis.rows[0].dot(v), basis.rows[1].dot(v), basis.rows[2].dot(v))
}

/// The engine's `PhysicsRayQueryParameters3D::set_exclude` wants a typed
/// `Array<Rid>`, while `RaycastCache::obb_excludes` (mirroring the C++ untyped
/// `Array`) is a `VarArray`. Godot's dynamic typing lets the C++ pass the
/// untyped Array straight through; Rust's static typing requires converting
/// element-by-element, same as the existing `sim_can_shoot_over_terrain_impl`.
fn to_rid_array(arr: &VarArray) -> Array<Rid> {
    let mut out: Array<Rid> = Array::new();
    for i in 0..arr.len() {
        out.push(arr.at(i).to::<Rid>());
    }
    out
}

impl NativeArmorInteraction {
    /// Walk the shell from `prev_pos` to its current position, resolving
    /// terrain, water and armor interactions along the way.
    pub fn process_travel(
        projectile: &Gd<ProjectileData>,
        prev_pos: Vector3,
        t: f64,
        space_state: Option<&mut Gd<PhysicsDirectSpaceState3D>>,
        precision_physics_world: Option<&Gd<Node>>,
        nav_map: &Option<Gd<NavigationMap>>,
        raycast_cache: &mut RaycastCache,
        log_armor: bool,
    ) -> ArmorHitResult {
        // C++: `if (!projectile.is_valid()) return ArmorHitResult();` — `projectile`
        // here is `&Gd<ProjectileData>`, which the Rust type system guarantees is
        // never null/dangling, so that guard is unreachable and omitted.

        if (prev_pos.y as f64) < 0.0 {
            godot_print!(
                "[ERROR] process_travel: prev_pos is underwater (y={}) — projectile should have been destroyed on a previous frame",
                prev_pos.y
            );
            return Self::make_result(hit_result::WATER, prev_pos, None, Vector3::ZERO, None, Vector3::ZERO, 1.0);
        }

        let curr_pos = projectile.bind().position;
        let travel = curr_pos - prev_pos;
        let mut extended_from = prev_pos;
        if projectile.bind().frame_count != 0 && travel.length_squared() > 0.0 {
            extended_from = prev_pos - travel.normalized() * 10.0;
        }

        let Some(space_state) = space_state else {
            return ArmorHitResult::default();
        };

        let use_terrain_physics = Self::should_raycast_terrain(nav_map, extended_from, curr_pos);

        if use_terrain_physics {
            let terrain_ray = raycast_cache.terrain_ray.as_mut().unwrap();
            terrain_ray.set_from(extended_from);
            terrain_ray.set_to(curr_pos);
        }

        {
            let excludes_rid = to_rid_array(&raycast_cache.obb_excludes);
            let obb_ray = raycast_cache.obb_ray.as_mut().unwrap();
            obb_ray.set_from(extended_from);
            obb_ray.set_to(curr_pos);
            obb_ray.set_exclude(&excludes_rid);
        }

        {
            let water_ray = raycast_cache.water_ray.as_mut().unwrap();
            water_ray.set_from(extended_from);
            water_ray.set_to(curr_pos);
        }

        let projectile_exclude = projectile.bind().exclude.clone();
        let projectile_owner = projectile.bind().owner.clone();

        let mut terrain_result = VarDictionary::new();
        if use_terrain_physics {
            terrain_result = space_state.intersect_ray(raycast_cache.terrain_ray.as_ref().unwrap());
        }
        let mut precision_ship: Option<Gd<Object>> = None;
        let obb_result = if projectile_owner.is_none() {
            space_state.intersect_ray(raycast_cache.obb_ray.as_ref().unwrap())
        } else {
            let (r, s) = Self::find_valid_obb_hit(
                Some(&mut *space_state),
                raycast_cache.obb_ray.as_ref().unwrap(),
                precision_physics_world,
                &projectile_owner,
                &projectile_exclude,
            );
            precision_ship = s;
            r
        };
        let water_result = space_state.intersect_ray(raycast_cache.water_ray.as_ref().unwrap());

        if projectile_owner.is_none() {
            let mut terrain_dist = INF_DIST;
            let mut water_dist = INF_DIST;
            let mut obb_dist = INF_DIST;
            if !terrain_result.is_empty() {
                let p: Vector3 = terrain_result.get("position").unwrap().to();
                terrain_dist = prev_pos.distance_squared_to(p) as f64;
            }
            if !water_result.is_empty() {
                let p: Vector3 = water_result.get("position").unwrap().to();
                water_dist = prev_pos.distance_squared_to(p) as f64;
            }
            if !obb_result.is_empty() {
                let p: Vector3 = obb_result.get("position").unwrap().to();
                obb_dist = prev_pos.distance_squared_to(p) as f64;
            }

            if terrain_dist <= water_dist && terrain_dist <= obb_dist && terrain_dist < INF_DIST {
                return Self::make_result(
                    hit_result::TERRAIN,
                    terrain_result.get("position").unwrap().to(),
                    None,
                    Vector3::ZERO,
                    None,
                    terrain_result.get("normal").unwrap().to(),
                    1.0,
                );
            }
            if water_dist <= obb_dist && water_dist < INF_DIST {
                return Self::make_result(
                    hit_result::WATER,
                    water_result.get("position").unwrap().to(),
                    None,
                    Vector3::ZERO,
                    None,
                    Vector3::ZERO,
                    1.0,
                );
            }
            return ArmorHitResult::default();
        }

        let mut precision_hit = VarDictionary::new();
        if !obb_result.is_empty() && precision_physics_world.is_some() && precision_ship.is_some() {
            let mut pw = precision_physics_world.unwrap().clone();
            pw.call("notify_obb_hit", &[precision_ship.clone().to_variant()]);
            precision_hit = pw
                .call(
                    "narrowphase_hit",
                    &[precision_ship.clone().to_variant(), extended_from.to_variant(), curr_pos.to_variant()],
                )
                .to();
        }

        let mut terrain_dist = INF_DIST;
        let mut precision_dist = INF_DIST;
        let mut water_dist = INF_DIST;
        if !terrain_result.is_empty() {
            let p: Vector3 = terrain_result.get("position").unwrap().to();
            if (p.y as f64) > EPSILON {
                terrain_dist = prev_pos.distance_squared_to(p) as f64;
            }
        }
        if !precision_hit.is_empty() {
            let p: Vector3 = precision_hit.get("world_pos").unwrap().to();
            precision_dist = prev_pos.distance_squared_to(p) as f64;
        }
        if !water_result.is_empty() {
            let p: Vector3 = water_result.get("position").unwrap().to();
            water_dist = prev_pos.distance_squared_to(p) as f64;
        }

        if terrain_dist <= precision_dist && terrain_dist <= water_dist && terrain_dist < INF_DIST {
            return Self::make_result(
                hit_result::TERRAIN,
                terrain_result.get("position").unwrap().to(),
                None,
                Vector3::ZERO,
                None,
                terrain_result.get("normal").unwrap().to(),
                1.0,
            );
        }

        let mut precision_hit_pos = Vector3::ZERO;
        let mut precision_vel = Vector3::ZERO;
        let mut fuze: f64 = -1.0;
        if !precision_hit.is_empty() {
            precision_hit_pos = precision_hit.get("world_pos").unwrap().to();
            let launch_velocity = projectile.bind().launch_velocity;
            let params_for_vel = projectile.bind().params.clone().unwrap();
            precision_vel = ProjectilePhysicsWithDragV2::calculate_velocity_at_time_impl(
                launch_velocity,
                t,
                &params_for_vel,
            );
        }
        // Silence "value assigned but never read" — precision_hit_pos is only used
        // as a scratch value here, matching the C++ local of the same name (the
        // final ArmorHitResult position always comes from `first_hit_pos` inside
        // process_hit, never from this variable).
        let _ = precision_hit_pos;

        let mut hit_water = false;
        if water_dist <= precision_dist && water_dist < INF_DIST {
            hit_water = true;
            let water_pos: Vector3 = water_result.get("position").unwrap().to();
            let params_opt = projectile.bind().params.clone();
            let fuzed_position = Self::handle_water_entry(water_pos, precision_vel, &params_opt);

            {
                let excludes_rid = to_rid_array(&raycast_cache.obb_excludes);
                let obb_ray = raycast_cache.obb_ray.as_mut().unwrap();
                obb_ray.set_from(water_pos);
                obb_ray.set_to(fuzed_position);
                obb_ray.set_exclude(&excludes_rid);
            }

            let (obb_result_underwater, s) = Self::find_valid_obb_hit(
                Some(&mut *space_state),
                raycast_cache.obb_ray.as_ref().unwrap(),
                precision_physics_world,
                &projectile_owner,
                &projectile_exclude,
            );
            precision_ship = s;

            if !obb_result_underwater.is_empty() && precision_physics_world.is_some() && precision_ship.is_some() {
                let mut pw = precision_physics_world.unwrap().clone();
                pw.call("notify_obb_hit", &[precision_ship.clone().to_variant()]);
                precision_hit = pw
                    .call(
                        "narrowphase_hit",
                        &[precision_ship.clone().to_variant(), water_pos.to_variant(), fuzed_position.to_variant()],
                    )
                    .to();
                if precision_hit.is_empty() {
                    return Self::make_result(
                        hit_result::WATER,
                        water_pos,
                        None,
                        Vector3::ZERO,
                        None,
                        Vector3::new(0.0, 1.0, 0.0),
                        1.0,
                    );
                }
                precision_hit_pos = precision_hit.get("world_pos").unwrap().to();
                precision_dist = prev_pos.distance_squared_to(precision_hit_pos) as f64;
                let total_dist = (fuzed_position - water_pos).length() as f64;
                let hit_dist = (precision_hit_pos - water_pos).length() as f64;
                let fuze_delay = match projectile.bind().params.as_ref() {
                    Some(p) => p.get("fuze_delay").to::<f64>(),
                    None => 0.0,
                };
                let t_impact = fuze_delay * (hit_dist / total_dist.max(0.001));
                let water_params = Self::duplicate_shell_params_with_drag(&projectile.bind().params.clone(), WATER_DRAG);
                precision_vel = ProjectilePhysicsWithDragV2::calculate_velocity_at_time_impl(
                    precision_vel,
                    t_impact,
                    water_params.as_ref().unwrap(),
                );
                fuze = t_impact;
            } else {
                return Self::make_result(hit_result::WATER, water_pos, None, Vector3::ZERO, None, Vector3::ZERO, 1.0);
            }
        }

        if precision_dist < INF_DIST && precision_ship.is_some() && !precision_hit.is_empty() {
            return Self::process_hit(
                precision_hit.get("armor").unwrap().to(),
                precision_hit.get("world_pos").unwrap().to(),
                precision_hit.get("world_normal").unwrap().to(),
                precision_hit.get("local_pos").unwrap().to(),
                precision_hit.get("local_normal").unwrap().to(),
                projectile,
                precision_vel,
                precision_hit.get("face_index").unwrap().to(),
                fuze,
                hit_water,
                precision_physics_world,
                log_armor,
            );
        }

        ArmorHitResult::default()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn process_hit(
        hit_node: Option<Gd<Object>>,
        world_hit_position: Vector3,
        world_hit_normal: Vector3,
        local_hit_position: Vector3,
        local_hit_normal: Vector3,
        projectile: &Gd<ProjectileData>,
        impact_velocity: Vector3,
        face_index: i32,
        fuze: f64,
        hit_water: bool,
        precision_physics_world: Option<&Gd<Node>>,
        log_armor: bool,
    ) -> ArmorHitResult {
        // C++: `if (hit_node == nullptr || !projectile.is_valid()) return ArmorHitResult();`
        // `projectile` is `&Gd<ProjectileData>` here and can never be invalid, so
        // only the `hit_node == nullptr` half of the guard is reachable.
        if hit_node.is_none() {
            return ArmorHitResult::default();
        }
        let mut hit_node = hit_node;

        let Some(params) = projectile.bind().params.clone() else {
            return ArmorHitResult::default();
        };

        let ship_variant = hit_node.as_ref().unwrap().get("ship");
        let ship: Option<Gd<Object>> = ship_variant.to();
        let ship_node: Option<Gd<Node3D>> = ship.clone().and_then(|s| s.try_cast::<Node3D>().ok());
        let (Some(ship), Some(ship_node)) = (ship, ship_node) else {
            return ArmorHitResult::default();
        };

        let first_hit_normal = world_hit_normal;
        let first_hit_pos = world_hit_position;
        let first_hit_node = hit_node.clone();
        let mut overmatch_first_armor = false;

        let ship_xform = ship_node.get_global_transform();
        let ship_basis = ship_xform.basis;
        let ship_basis_inv = ship_basis.inverse();
        let mut hit_position = local_hit_position;
        let mut hit_normal = local_hit_normal.normalized();

        let mut shell = ShellState {
            position: hit_position,
            end_position: Vector3::ZERO,
            velocity: basis_xform(&ship_basis_inv, impact_velocity),
            params: None,
            fuze,
            pen: 0.0,
            integrity: 1.0,
        };
        shell.params = Some(params.clone());
        shell.calc_end_position();

        if hit_water && params.get("type").to::<i32>() == 0 {
            return Self::make_result(hit_result::WATER, first_hit_pos, None, impact_velocity, None, first_hit_normal, 1.0);
        }

        if params.get("type").to::<i32>() == 0 {
            let armor_mm = Self::get_armor(&hit_node, face_index);
            let he_citadel = Self::is_citadel(&hit_node);
            let he_pens = params.get("overmatch").to::<f64>() >= armor_mm;
            let he_result = if he_pens {
                if he_citadel { hit_result::CITADEL } else { hit_result::PENETRATION }
            } else {
                hit_result::SHATTER
            };
            let mut he_hit = Self::make_result(
                he_result,
                first_hit_pos,
                hit_node.clone(),
                impact_velocity,
                Some(ship.clone()),
                first_hit_normal,
                1.0,
            );
            if log_armor {
                // HE resolves against a single plate, so the log gets one step whose
                // entry and exit velocity are identical and whose effective thickness
                // is the raw plate value (no obliquity correction for HE).
                let mut step = VarDictionary::new();
                step.set("result", if he_pens { ArmorResult::Pen as i32 } else { ArmorResult::Shatter as i32 });
                step.set("is_citadel", he_citadel);
                step.set("armor_mm", armor_mm);
                step.set("effective_mm", armor_mm);
                step.set(
                    "impact_angle",
                    Self::calculate_impact_angle(basis_xform(&ship_basis_inv, impact_velocity).normalized(), hit_normal),
                );
                step.set("pen", params.get("overmatch").to::<f64>());
                step.set("integrity", 1.0f64);
                step.set("pos", first_hit_pos);
                step.set("vel", impact_velocity);
                step.set("impact_vel", impact_velocity);
                step.set("armor_path", &hit_node.as_ref().unwrap().get("armor_path"));
                he_hit.log_steps.push(&step.to_variant());
                he_hit.log_final_pos = first_hit_pos;
                he_hit.log_valid = true;
            }
            return he_hit;
        }

        let mut result = ArmorResult::Overpen;
        let mut log_steps = VarArray::new();
        let mut hit_cit = false;
        let mut over_pen = false;
        let mut iteration: i32 = 0;
        const MAX_ITERATIONS: i32 = 20;
        let mut offset = Vector3::ZERO;
        let mut face_index = face_index;

        while shell.fuze <= params.get("fuze_delay").to::<f64>()
            && result != ArmorResult::Shatter
            && Self::same_object(
                &hit_node.as_ref().unwrap().get("ship").to::<Option<Gd<Object>>>(),
                &Some(ship.clone()),
            )
            && iteration < MAX_ITERATIONS
        {
            iteration += 1;
            let armor_mm = Self::get_armor(&hit_node, face_index);
            let speed = shell.get_speed();
            let impact_angle = Self::calculate_impact_angle(shell.velocity.normalized(), hit_normal);
            let e_armor = Self::calculate_effective_thickness(armor_mm, impact_angle);
            shell.pen = Self::calculate_de_marre_penetration(
                params.get("mass").to(),
                speed,
                params.get("caliber").to(),
            ) * params.get("penetration_modifier").to::<f64>();
            shell.position = hit_position + offset;
            offset = Vector3::ZERO;
            // World-space velocity as the shell arrives at this plate, captured before
            // any branch below modifies it — this is the step's "impact_vel".
            let log_impact_vel = if log_armor { basis_xform(&ship_basis, shell.velocity) } else { Vector3::ZERO };

            if armor_mm <= params.get("overmatch").to::<f64>() {
                if Self::is_citadel(&hit_node) {
                    hit_cit = true;
                }
                result = ArmorResult::Overpen;
                over_pen = true;
                if iteration == 1 {
                    overmatch_first_armor = true;
                }
                let pen_ratio = e_armor / shell.pen.max(1.0);
                shell.velocity *= (1.0 - pen_ratio) as f32;
                shell.integrity = Self::calculate_shell_integrity(pen_ratio, shell.integrity);
                if shell.velocity.length_squared() > 0.0 {
                    offset += shell.velocity.normalized() * (EPSILON as f32);
                }
                if shell.fuze < 0.0 && e_armor >= params.get("arming_threshold").to::<f64>() {
                    shell.fuze = 0.0;
                }
            } else if impact_angle >= params.get("auto_bounce").to::<f64>() {
                result = ArmorResult::Ricochet;
                let k_nose = Self::get_k_nose(&Some(params.clone()));
                let cos_a = impact_angle.cos().max(0.05);
                let tan_a = clampd(impact_angle, 0.0, 89.0 * DEG_TO_RAD).tan();
                let td_ratio = armor_mm / params.get("caliber").to::<f64>().max(1.0);
                let engagement = clampd(td_ratio / TD_ENGAGE_REF, 0.0, 1.0).powf(TD_ENGAGE_POWER);
                let f_td = 1.0 + TD_MOD_SCALE * clampd(td_ratio - TD_MOD_ONSET, 0.0, TD_MOD_MAX);
                let deflection_mult = 1.0 + engagement * k_nose * tan_a.powf(DEFLECTION_GAMMA) * f_td;
                let physics_armor = e_armor * deflection_mult;
                let energy_loss = clampd(shell.pen * cos_a / physics_armor.max(0.1), 0.0, 0.8);
                shell.velocity = Self::calculate_ricochet_velocity(shell.velocity, hit_normal, energy_loss);
                offset += hit_normal * (EPSILON as f32);
                if shell.fuze < 0.0 && impact_angle > 70.0 * DEG_TO_RAD {
                    shell.fuze = 0.0;
                }
            } else {
                let interaction =
                    Self::evaluate_armor_interaction(&shell, &Some(params.clone()), impact_angle, armor_mm, e_armor);
                result = interaction.result;
                match result {
                    ArmorResult::Ricochet => {
                        shell.velocity =
                            Self::calculate_ricochet_velocity(shell.velocity, hit_normal, interaction.energy_loss_fraction);
                        offset += hit_normal * (EPSILON as f32);
                        if shell.fuze < 0.0 && impact_angle > 70.0 * DEG_TO_RAD {
                            shell.fuze = 0.0;
                        }
                    }
                    ArmorResult::Shatter => {
                        shell.velocity = Vector3::ZERO;
                        shell.fuze = params.get("fuze_delay").to::<f64>();
                        shell.position += hit_normal * (EPSILON as f32);
                    }
                    ArmorResult::PartialPen => {
                        shell.velocity *= 0.1_f64 as f32;
                        shell.integrity *= 0.5;
                        if shell.velocity.length_squared() > 0.0 {
                            offset += shell.velocity.normalized() * (EPSILON as f32);
                        }
                    }
                    ArmorResult::Pen | ArmorResult::Overpen => {
                        if Self::is_citadel(&hit_node) {
                            hit_cit = true;
                        }
                        over_pen = true;
                        let exit_speed = Self::calculate_exit_velocity(speed, shell.pen, e_armor);
                        let exit_dir = Self::calculate_deflected_direction(shell.velocity.normalized(), hit_normal, interaction.pen_ratio);
                        shell.velocity = exit_dir * (exit_speed as f32);
                        shell.integrity = Self::calculate_shell_integrity(interaction.pen_ratio, shell.integrity);
                        if shell.velocity.length_squared() > 0.0 {
                            offset += shell.velocity.normalized() * (EPSILON as f32);
                        }
                        if shell.fuze < 0.0 && e_armor >= params.get("arming_threshold").to::<f64>() {
                            shell.fuze = 0.0;
                        }
                    }
                }
            }

            if log_armor {
                // pos = world-space entry point into this plate,
                // vel = world-space velocity leaving it.
                let mut step = VarDictionary::new();
                step.set("result", result as i32);
                step.set("is_citadel", Self::is_citadel(&hit_node));
                step.set("armor_mm", armor_mm);
                step.set("effective_mm", e_armor);
                step.set("impact_angle", impact_angle);
                step.set("pen", shell.pen);
                step.set("integrity", shell.integrity);
                step.set("pos", ship_xform * hit_position);
                step.set("vel", basis_xform(&ship_basis, shell.velocity));
                step.set("impact_vel", log_impact_vel);
                step.set("armor_path", &hit_node.as_ref().unwrap().get("armor_path"));
                log_steps.push(&step.to_variant());
            }

            if result == ArmorResult::Shatter || result == ArmorResult::PartialPen || shell.get_speed() < MIN_VELOCITY {
                shell.calc_end_position();
                break;
            }

            let next_ray_from = shell.position + offset;
            shell.calc_end_position();
            let next_ray_to = shell.end_position;
            let mut next_hit = VarDictionary::new();
            if let Some(pw) = precision_physics_world {
                let mut pw = pw.clone();
                next_hit = pw
                    .call(
                        "precision_get_next_hit",
                        &[ship.to_variant(), next_ray_from.to_variant(), next_ray_to.to_variant()],
                    )
                    .to();
            }
            if next_hit.is_empty() {
                if shell.fuze >= 0.0 {
                    shell.fuze = params.get("fuze_delay").to::<f64>();
                }
                break;
            }

            let old_pos = hit_position;
            hit_node = next_hit.get("armor").unwrap().to();
            hit_position = next_hit.get("position").unwrap().to();
            hit_normal = next_hit.get("normal").unwrap().to::<Vector3>().normalized();
            face_index = next_hit.get("face_index").unwrap().to();
            let fuze_elapsed = old_pos.distance_to(hit_position) as f64 / shell.get_speed().max(0.001);
            if shell.fuze >= 0.0 {
                shell.fuze += fuze_elapsed;
            }
            if hit_node.is_none() {
                break;
            }
        }

        let mut final_part: Option<Gd<Object>> = if let Some(pw) = precision_physics_world {
            let mut pw = pw.clone();
            pw.call("precision_get_part_hit", &[ship.to_variant(), shell.end_position.to_variant()]).to()
        } else {
            None
        };

        let damage_result = Self::resolve_hit_result(result, &final_part, hit_cit, over_pen);

        if damage_result == hit_result::CITADEL_OVERPEN {
            let citadel = ship.get("citadel");
            if !citadel.is_nil() {
                final_part = citadel.to();
            }
        }

        let final_world_vel = basis_xform(&ship_basis, shell.velocity);
        let armor_part_result = if final_part.is_some() { final_part } else { first_hit_node };
        let mut hit_result_out = Self::make_result(
            damage_result,
            first_hit_pos,
            armor_part_result,
            final_world_vel,
            Some(ship),
            first_hit_normal,
            shell.integrity,
        );
        hit_result_out.overmatch_first_armor = overmatch_first_armor;
        if log_armor && !log_steps.is_empty() {
            hit_result_out.log_steps = log_steps;
            hit_result_out.log_final_pos = ship_xform * shell.end_position;
            hit_result_out.log_valid = true;
        }
        hit_result_out
    }
}
