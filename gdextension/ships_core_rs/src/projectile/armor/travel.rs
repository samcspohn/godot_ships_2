use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Engine, Node, PhysicsDirectSpaceState3D};

use super::mesh::{Hit, V3};
use super::registry::{ArmorRegistry, ShipArmor};
use super::walk::{walk_plates, ShellSpec};
use super::{hit_result, ArmorHitResult, NativeArmorInteraction, RaycastCache, EPSILON, WATER_DRAG};
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::nav::map::NavigationMap;
use crate::projectile::data::ProjectileData;

/// Mirrors the C++ anonymous-namespace `constexpr double INF_DIST`.
const INF_DIST: f64 = 1.0e300;

/// Mirrors the C++ anonymous-namespace `static Vector3 basis_xform(...)`.
fn basis_xform(basis: &Basis, v: Vector3) -> Vector3 {
    Vector3::new(basis.rows[0].dot(v), basis.rows[1].dot(v), basis.rows[2].dot(v))
}

fn to_rid_array(arr: &VarArray) -> Array<Rid> {
    let mut out: Array<Rid> = Array::new();
    for i in 0..arr.len() {
        out.push(arr.at(i).to::<Rid>());
    }
    out
}

impl NativeArmorInteraction {
    /// Closest armour hit of a registered ship along a world segment, with
    /// the hit's world position.
    fn mesh_cast(armor: &ArmorRegistry, ship_id: i64, from_w: Vector3, to_w: Vector3) -> Option<(Hit, Vector3)> {
        let sa = armor.get(ship_id)?;
        if !sa.ship.is_instance_valid() {
            return None;
        }
        let xf = sa.ship.get_global_transform();
        let inv = xf.affine_inverse();
        let hit = sa.mesh.raycast(V3::from_godot(inv * from_w), V3::from_godot(inv * to_w))?;
        Some((hit, xf * hit.pos.to_godot()))
    }

    /// Walk the shell from `prev_pos` to its current position, resolving
    /// terrain, water and armour along the way. The broadphase is the OBB
    /// layer of `space_state`; the narrowphase is the ship's armour mesh.
    #[allow(clippy::too_many_arguments)]
    pub fn process_travel(
        projectile: &Gd<ProjectileData>,
        prev_pos: Vector3,
        t: f64,
        space_state: Option<&mut Gd<PhysicsDirectSpaceState3D>>,
        precision_physics_world: Option<&Gd<Node>>,
        armor: &mut ArmorRegistry,
        nav_map: &Option<Gd<NavigationMap>>,
        raycast_cache: &mut RaycastCache,
        log_armor: bool,
    ) -> ArmorHitResult {
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

        let frame = Engine::singleton().get_physics_frames() as i64;
        let mut ship_id: i64 = 0;
        let mut mesh_hit: Option<(Hit, Vector3)> = None;
        if !obb_result.is_empty() && precision_physics_world.is_some() && precision_ship.is_some() {
            let mut pw = precision_physics_world.unwrap().clone();
            pw.call("notify_obb_hit", &[precision_ship.clone().to_variant()]);
            ship_id = precision_ship.as_ref().unwrap().instance_id().to_i64();
            armor.sync(ship_id, frame);
            mesh_hit = Self::mesh_cast(armor, ship_id, extended_from, curr_pos);
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
        if let Some((_, wp)) = &mesh_hit {
            precision_dist = prev_pos.distance_squared_to(*wp) as f64;
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

        let mut precision_vel = Vector3::ZERO;
        let mut fuze: f64 = -1.0;
        if mesh_hit.is_some() {
            let launch_velocity = projectile.bind().launch_velocity;
            let params_for_vel = projectile.bind().params.clone().unwrap();
            precision_vel = ProjectilePhysicsWithDragV2::calculate_velocity_at_time_impl(
                launch_velocity,
                t,
                &params_for_vel,
            );
        }

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
                ship_id = precision_ship.as_ref().unwrap().instance_id().to_i64();
                armor.sync(ship_id, frame);
                mesh_hit = Self::mesh_cast(armor, ship_id, water_pos, fuzed_position);
                let Some((_, hit_pos)) = &mesh_hit else {
                    return Self::make_result(
                        hit_result::WATER,
                        water_pos,
                        None,
                        Vector3::ZERO,
                        None,
                        Vector3::new(0.0, 1.0, 0.0),
                        1.0,
                    );
                };
                precision_dist = prev_pos.distance_squared_to(*hit_pos) as f64;
                let total_dist = (fuzed_position - water_pos).length() as f64;
                let hit_dist = (*hit_pos - water_pos).length() as f64;
                let fuze_delay = match projectile.bind().params.as_ref() {
                    Some(p) => p.get("fuze_delay").to_f64(),
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

        if precision_dist < INF_DIST && precision_ship.is_some() {
            if let (Some((hit, _)), Some(sa)) = (mesh_hit, armor.get(ship_id)) {
                return Self::process_hit(sa, &hit, projectile, precision_vel, fuze, hit_water, log_armor);
            }
        }

        ArmorHitResult::default()
    }

    /// The plate walk against one ship, from a first hit in ship space, with
    /// the outcome mapped back onto scene objects and world space.
    pub fn process_hit(
        sa: &ShipArmor,
        hit: &Hit,
        projectile: &Gd<ProjectileData>,
        impact_velocity: Vector3,
        fuze: f64,
        hit_water: bool,
        log_armor: bool,
    ) -> ArmorHitResult {
        let Some(params) = projectile.bind().params.clone() else {
            return ArmorHitResult::default();
        };
        if !sa.ship.is_instance_valid() {
            return ArmorHitResult::default();
        }
        let spec = ShellSpec::from_params(&params);
        let ship_xform = sa.ship.get_global_transform();
        let ship_basis = ship_xform.basis;
        let ship_basis_inv = ship_basis.inverse();
        let first_hit_pos = ship_xform * hit.pos.to_godot();
        let first_hit_normal = (ship_basis * hit.normal.to_godot()).normalized();

        let out = walk_plates(&sa.mesh, &spec, hit, basis_xform(&ship_basis_inv, impact_velocity), fuze, hit_water, log_armor);

        if hit_water && spec.is_he {
            return Self::make_result(hit_result::WATER, first_hit_pos, None, impact_velocity, None, first_hit_normal, 1.0);
        }

        let ship_obj = sa.ship.clone().upcast::<Object>();
        let mut armor_part: Option<Gd<Object>> = sa.parts.get(out.final_part.unwrap_or(out.first_part)).cloned();
        if out.damage_result == hit_result::CITADEL_OVERPEN {
            let citadel = sa.ship.get("citadel");
            if !citadel.is_nil() {
                armor_part = citadel.to();
            }
        }

        let mut res = Self::make_result(
            out.damage_result,
            first_hit_pos,
            armor_part,
            basis_xform(&ship_basis, out.velocity),
            Some(ship_obj),
            first_hit_normal,
            out.integrity,
        );
        res.overmatch_first_armor = out.overmatch_first_armor;
        if log_armor && !out.steps.is_empty() {
            let mut log_steps = VarArray::new();
            for st in &out.steps {
                let mut step = VarDictionary::new();
                step.set("result", st.result as i32);
                step.set("is_citadel", st.is_citadel);
                step.set("armor_mm", st.armor_mm);
                step.set("effective_mm", st.effective_mm);
                step.set("impact_angle", st.impact_angle);
                step.set("pen", st.pen);
                step.set("integrity", st.integrity);
                step.set("pos", ship_xform * st.pos);
                step.set("vel", basis_xform(&ship_basis, st.vel));
                step.set("impact_vel", basis_xform(&ship_basis, st.impact_vel));
                let path = sa.parts.get(st.part).map(|p| p.get("armor_path")).unwrap_or_else(Variant::nil);
                step.set("armor_path", &path);
                log_steps.push(&step.to_variant());
            }
            res.log_steps = log_steps;
            res.log_final_pos = ship_xform * out.end_position;
            res.log_valid = true;
        }
        res
    }
}
