use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Node, PhysicsDirectSpaceState3D, PhysicsRayQueryParameters3D, Resource};

use super::ProjectilePhysicsWithDragV2 as P;
use crate::nav::map::NavigationMap;

impl P {
    pub(crate) fn calculate_position_at_time_impl(
        start_pos: Vector3, launch_vector: Vector3, time: f64, shell_params: &Gd<Resource>,
    ) -> Vector3 {
        if time <= 0.0 {
            return start_pos;
        }

        let Some((_v0, beta, vt, tau)) = Self::extract_params(shell_params) else {
            // Fallback to simple ballistic trajectory without drag
            return Vector3::new(
                (start_pos.x as f64 + launch_vector.x as f64 * time) as f32,
                (start_pos.y as f64 + launch_vector.y as f64 * time
                    - 0.5 * super::GRAVITY * time * time) as f32,
                (start_pos.z as f64 + launch_vector.z as f64 * time) as f32,
            );
        };

        // Get horizontal distance and direction
        let vx = launch_vector.x as f64;
        let vz = launch_vector.z as f64;
        let vy0 = launch_vector.y as f64;
        let v_horiz = (vx * vx + vz * vz).sqrt();

        if v_horiz < 1e-10 {
            // Purely vertical shot
            let sin_theta = if vy0 >= 0.0 { 1.0 } else { -1.0 };
            let y_offset = Self::vertical_position(sin_theta, time, vy0.abs(), vt, tau);
            return Vector3::new(start_pos.x, (start_pos.y as f64 + y_offset) as f32, start_pos.z);
        }

        // Calculate theta (elevation angle)
        let speed = (vx * vx + vy0 * vy0 + vz * vz).sqrt();
        let cos_theta = v_horiz / speed;
        let sin_theta = vy0 / speed;

        // Calculate horizontal and vertical positions using analytical formulas
        let x_dist = Self::horizontal_position(cos_theta, time, speed, beta);
        let y_offset = Self::vertical_position(sin_theta, time, speed, vt, tau);

        // Convert back to 3D - distribute horizontal distance along original direction
        let horiz_scale = x_dist / v_horiz;
        Vector3::new(
            (start_pos.x as f64 + vx * horiz_scale) as f32,
            (start_pos.y as f64 + y_offset) as f32,
            (start_pos.z as f64 + vz * horiz_scale) as f32,
        )
    }

    pub(crate) fn calculate_velocity_at_time_impl(
        launch_vector: Vector3, time: f64, shell_params: &Gd<Resource>,
    ) -> Vector3 {
        let Some((_v0, beta, vt, tau)) = Self::extract_params(shell_params) else {
            // Fallback to simple ballistic velocity
            return Vector3::new(
                launch_vector.x,
                (launch_vector.y as f64 - super::GRAVITY * time) as f32,
                launch_vector.z,
            );
        };

        let vx = launch_vector.x as f64;
        let vz = launch_vector.z as f64;
        let vy0 = launch_vector.y as f64;
        let v_horiz = (vx * vx + vz * vz).sqrt();

        if v_horiz < 1e-10 {
            // Purely vertical shot
            let sin_theta = if vy0 >= 0.0 { 1.0 } else { -1.0 };
            let vy = Self::vertical_velocity(sin_theta, time, vy0.abs(), vt, tau);
            return Vector3::new(0.0, vy as f32, 0.0);
        }

        // Calculate theta (elevation angle)
        let speed = (vx * vx + vy0 * vy0 + vz * vz).sqrt();
        let cos_theta = v_horiz / speed;
        let sin_theta = vy0 / speed;

        // Calculate velocities using analytical formulas
        let v_horiz_new = Self::horizontal_velocity(cos_theta, time, speed, beta);
        let vy_new = Self::vertical_velocity(sin_theta, time, speed, vt, tau);

        // Scale horizontal components
        let horiz_scale = v_horiz_new / v_horiz;
        Vector3::new((vx * horiz_scale) as f32, vy_new as f32, (vz * horiz_scale) as f32)
    }

    /// Returns [launch_vector: Vector3, time_to_target: float], or [null, -1].
    pub(crate) fn calculate_launch_vector_impl(
        start_pos: Vector3, target_pos: Vector3, shell_params: &Gd<Resource>,
    ) -> VarArray {
        let Some((v0, _beta, _vt, _tau)) = Self::extract_params(shell_params) else {
            return no_solution2();
        };

        // Calculate displacement
        let disp = target_pos - start_pos;
        // sqrt runs in float (both operands float) and is widened after, matching
        // `double horiz_dist = std::sqrt(disp.x * disp.x + disp.z * disp.z);`.
        let horiz_dist = (disp.x * disp.x + disp.z * disp.z).sqrt() as f64;
        let vert_dist = disp.y as f64;

        if horiz_dist < 1e-6 {
            // Target is directly above/below - can't solve with this method
            return no_solution2();
        }

        // Get firing solution using 2D analytical solver
        let solution = Self::firing_solution(horiz_dist, vert_dist, shell_params, false);

        if solution.x.is_nan() {
            return no_solution2();
        }

        let theta = solution.x as f64;
        let flight_time = solution.y as f64;

        // Convert 2D solution to 3D launch vector
        let cos_theta = theta.cos();
        let sin_theta = theta.sin();

        // Horizontal direction
        let horiz_dir_x = disp.x as f64 / horiz_dist;
        let horiz_dir_z = disp.z as f64 / horiz_dist;

        let launch_vector = Vector3::new(
            (v0 * cos_theta * horiz_dir_x) as f32,
            (v0 * sin_theta) as f32,
            (v0 * cos_theta * horiz_dir_z) as f32,
        );

        let mut result = VarArray::new();
        result.push(&launch_vector.to_variant());
        result.push(&flight_time.to_variant());
        result
    }

    /// Returns [launch_vector, time_to_target, predicted_target_position],
    /// or [null, -1, null].
    pub(crate) fn calculate_leading_launch_vector_impl(
        start_pos: Vector3, target_pos: Vector3, target_velocity: Vector3,
        shell_params: &Gd<Resource>,
    ) -> VarArray {
        let Some((v0, _beta, _vt, _tau)) = Self::extract_params(shell_params) else {
            return no_solution3();
        };

        // Start with the time it would take to hit the current position (non-drag
        // estimation). This gives us a good initial estimate for fast convergence.
        let initial_result = crate::ballistics::physics::ProjectilePhysics::calculate_launch_vector(start_pos, target_pos, v0);

        if initial_result.at(0).is_nil() {
            return no_solution3(); // No solution exists in basic physics
        }

        let mut time_estimate: f64 = initial_result.at(1).to_f64();

        // Refine the estimate iteratively - only 3 iterations needed with good initial estimate
        for _ in 0..3 {
            // Predict target position after estimated time
            let predicted_pos = target_pos + target_velocity * time_estimate as f32;

            // Calculate launch vector to hit that position with drag
            let iter_result = Self::calculate_launch_vector_impl(start_pos, predicted_pos, shell_params);

            if iter_result.at(0).is_nil() {
                return no_solution3();
            }

            time_estimate = iter_result.at(1).to_f64();
        }

        // Final calculation with the best time estimate
        let final_target_pos = target_pos + target_velocity * time_estimate as f32;
        let final_result = Self::calculate_launch_vector_impl(start_pos, final_target_pos, shell_params);

        // Return launch vector, time to target, and the final target position
        let mut result = VarArray::new();
        if final_result.at(0).is_nil() {
            result.push(&Variant::nil());
            result.push(&(-1.0f64).to_variant());
            result.push(&Variant::nil());
        } else {
            result.push(&final_result.at(0));
            result.push(&final_result.at(1));
            result.push(&final_target_pos.to_variant());
        }
        result
    }

    /// Where a target under a constant rate of turn will be after `t` seconds.
    /// The arc is the exact integral of a velocity rotating at a constant rate;
    /// as w approaches zero it reduces to v*t, so the straight-line case falls
    /// out of the same expression rather than needing its own path.
    pub(crate) fn advance_turning(pos: Vector3, vel: Vector3, yaw_rate: f64, t: f64) -> Vector3 {
        // Below this rate the arc and the straight line are indistinguishable over
        // any shell flight, and the 1/w terms below would be dividing by noise.
        const MIN_YAW_RATE: f64 = 1e-5;
        if yaw_rate.abs() < MIN_YAW_RATE {
            return pos + vel * t as f32;
        }

        let flat_vel = Vector3::new(vel.x, 0.0, vel.z);
        // perp(v): v rotated +90 degrees about +Y. Godot's Y rotation maps
        // (x, z) -> (x*cos + z*sin, -x*sin + z*cos), so at 90 degrees that is
        // (z, -x).
        let perp = Vector3::new(flat_vel.z, 0.0, -flat_vel.x);

        let a = yaw_rate * t;
        let along = a.sin() / yaw_rate;
        let across = (1.0 - a.cos()) / yaw_rate;

        let mut disp = flat_vel * along as f32 + perp * across as f32;
        disp.y = (vel.y as f64 * t) as f32;
        pos + disp
    }

    pub(crate) fn calculate_leading_launch_vector_turning_impl(
        start_pos: Vector3, target_pos: Vector3, target_velocity: Vector3,
        target_yaw_rate: f64, shell_params: &Gd<Resource>,
    ) -> VarArray {
        let Some((v0, _beta, _vt, _tau)) = Self::extract_params(shell_params) else {
            return no_solution3();
        };

        // Same initial estimate as the straight-line solver: time to the target's
        // present position, ignoring drag, which converges in very few steps.
        let initial_result = crate::ballistics::physics::ProjectilePhysics::calculate_launch_vector(start_pos, target_pos, v0);

        if initial_result.at(0).is_nil() {
            return no_solution3(); // No solution exists in basic physics
        }

        let mut time_estimate: f64 = initial_result.at(1).to_f64();

        // Refine: each pass carries the target along its ARC for the current flight
        // time, then re-solves for the flight time to that new point.
        for _ in 0..3 {
            let predicted_pos = Self::advance_turning(target_pos, target_velocity, target_yaw_rate, time_estimate);

            let iter_result = Self::calculate_launch_vector_impl(start_pos, predicted_pos, shell_params);

            if iter_result.at(0).is_nil() {
                return no_solution3();
            }

            time_estimate = iter_result.at(1).to_f64();
        }

        let final_target_pos = Self::advance_turning(target_pos, target_velocity, target_yaw_rate, time_estimate);
        let final_result = Self::calculate_launch_vector_impl(start_pos, final_target_pos, shell_params);

        let mut result = VarArray::new();
        if final_result.at(0).is_nil() {
            result.push(&Variant::nil());
            result.push(&(-1.0f64).to_variant());
            result.push(&Variant::nil());
        } else {
            result.push(&final_result.at(0));
            result.push(&final_result.at(1));
            result.push(&final_target_pos.to_variant());
        }
        result
    }

    pub(crate) fn calculate_impact_position_impl(
        start_pos: Vector3, launch_velocity: Vector3, shell_params: &Gd<Resource>,
    ) -> Vector3 {
        let Some((_v0, _beta, _vt, _tau)) = Self::extract_params(shell_params) else {
            // Fallback: simple ballistic calculation
            let vy0 = launch_velocity.y as f64;
            let disc = vy0 * vy0 + 2.0 * super::GRAVITY * start_pos.y as f64;
            if disc < 0.0 {
                return start_pos;
            }
            let t = (vy0 + disc.sqrt()) / super::GRAVITY;
            return Vector3::new(
                (start_pos.x as f64 + launch_velocity.x as f64 * t) as f32,
                0.0,
                (start_pos.z as f64 + launch_velocity.z as f64 * t) as f32,
            );
        };

        // Calculate theta from launch velocity
        let vx = launch_velocity.x as f64;
        let vz = launch_velocity.z as f64;
        let vy0 = launch_velocity.y as f64;
        let v_horiz = (vx * vx + vz * vz).sqrt();
        let speed = (vx * vx + vy0 * vy0 + vz * vz).sqrt();

        if v_horiz < 1e-10 || speed < 1e-10 {
            return start_pos;
        }

        let theta = vy0.atan2(v_horiz);

        // Use time_of_flight to find when y = -start_pos.y (relative to start)
        let target_y = -(start_pos.y as f64);
        let t = Self::time_of_flight_impl(theta, shell_params, target_y);

        if t.is_nan() || t < 0.0 {
            return start_pos;
        }

        // Calculate position at impact time
        Self::calculate_position_at_time_impl(start_pos, launch_velocity, t, shell_params)
    }

    /// Returns [max_range, optimal_angle, flight_time].
    pub(crate) fn calculate_absolute_max_range(shell_params: &Gd<Resource>) -> VarArray {
        let mut result = VarArray::new();

        if Self::extract_params(shell_params).is_none() {
            result.push(&0.0f64.to_variant());
            result.push(&0.0f64.to_variant());
            result.push(&0.0f64.to_variant());
            return result;
        }

        // Binary search for optimal angle
        let mut min_angle = 0.0f64;
        let mut max_angle = std::f64::consts::PI / 2.0 - 0.01;
        let mut best_range = 0.0f64;
        let mut best_angle = 0.0f64;

        for _ in 0..super::MAX_ITERATIONS {
            let mid1 = min_angle + (max_angle - min_angle) / 3.0;
            let mid2 = max_angle - (max_angle - min_angle) / 3.0;

            let mut range1 = Self::range_at_angle(mid1, shell_params);
            let mut range2 = Self::range_at_angle(mid2, shell_params);

            if range1.is_nan() {
                range1 = 0.0;
            }
            if range2.is_nan() {
                range2 = 0.0;
            }

            if range1 < range2 {
                min_angle = mid1;
                if range2 > best_range {
                    best_range = range2;
                    best_angle = mid2;
                }
            } else {
                max_angle = mid2;
                if range1 > best_range {
                    best_range = range1;
                    best_angle = mid1;
                }
            }
        }

        let best_time = Self::time_of_flight_impl(best_angle, shell_params, 0.0);

        result.push(&best_range.to_variant());
        result.push(&best_angle.to_variant());
        result.push(&best_time.to_variant());
        result
    }

    /// Trajectory clearance over terrain and ships.
    /// Returns { terrain_blocked, terrain_position, obb_hit, obb_collider, obb_position }.
    pub(crate) fn sim_can_shoot_over_terrain_impl(
        start_pos: Vector3,
        launch_vector: Vector3,
        flight_time: f64,
        shell_params: &Gd<Resource>,
        nav_map: Option<Gd<NavigationMap>>,
        mut space_state: Option<Gd<PhysicsDirectSpaceState3D>>,
        exclude_rids: VarArray,
        mut precision_world: Option<Gd<Node>>,
    ) -> VarDictionary {
        let mut result = VarDictionary::new();
        result.set("terrain_blocked", false);
        result.set("terrain_position", Vector3::new(0.0, 0.0, 0.0));
        result.set("obb_hit", false);
        result.set("obb_collider", &Variant::nil());
        result.set("obb_position", Vector3::new(0.0, 0.0, 0.0));

        // The trajectory is only simulated up to the aim point. Anything past it
        // is irrelevant: the shell either hits what we aimed at or lands where the
        // gunner intended, so terrain *behind* the target must never block the shot
        // (this is what made every ship parked in front of an island unshootable at
        // close range, where the arc is flat and overshoot travels a long way).
        let end_time = flight_time.min(100.0);
        if end_time <= 0.0 {
            return result;
        }

        let vx = launch_vector.x as f64;
        let vz = launch_vector.z as f64;
        let vy0 = launch_vector.y as f64;
        let v_horiz = (vx * vx + vz * vz).sqrt();
        let speed = (vx * vx + vy0 * vy0 + vz * vz).sqrt();
        if v_horiz < 1e-10 || speed < 1e-10 {
            return result;
        }

        let Some((_shell_v0, beta, vt, tau)) = Self::extract_params(shell_params) else {
            return result;
        };

        let cos_theta = v_horiz / speed;
        let sin_theta = vy0 / speed;
        let theta = vy0.atan2(v_horiz);
        let dir_x = vx / v_horiz;
        let dir_z = vz / v_horiz;
        let end_dist = Self::horizontal_position(cos_theta, end_time, speed, beta);
        if end_dist <= 0.0 || end_dist.is_nan() {
            return result;
        }

        // Bind once; every march step and the terrain helper reuse this guard.
        let nav_bind = nav_map.as_ref().map(|g| g.bind());
        let has_nav_map = nav_bind.as_deref().map_or(false, |m| m.is_built());
        let cell_size: f32 = if has_nav_map {
            nav_bind.as_deref().unwrap().get_cell_size_value()
        } else {
            50.0
        };
        let min_step = 5.0f64.max(cell_size as f64 * 0.5);
        let sdf_margin = 2.0f64.max(cell_size as f64 * 0.5);
        let max_low_altitude_time_step = 0.5f64;
        let ship_clear_height = 200.0f64;

        let position_at_time = |t: f64| -> Vector3 {
            let horizontal_dist = Self::horizontal_position(cos_theta, t, speed, beta);
            let y_offset = Self::vertical_position(sin_theta, t, speed, vt, tau);
            Vector3::new(
                (start_pos.x as f64 + dir_x * horizontal_dist) as f32,
                (start_pos.y as f64 + y_offset) as f32,
                (start_pos.z as f64 + dir_z * horizontal_dist) as f32,
            )
        };

        let position_at_distance = |horizontal_dist: f64| -> (Vector3, f64) {
            let sample_t = Self::time_from_x(horizontal_dist, theta, speed, beta);
            let y_offset = Self::vertical_position(sin_theta, sample_t, speed, vt, tau);
            let pos = Vector3::new(
                (start_pos.x as f64 + dir_x * horizontal_dist) as f32,
                (start_pos.y as f64 + y_offset) as f32,
                (start_pos.z as f64 + dir_z * horizontal_dist) as f32,
            );
            (pos, sample_t)
        };

        // Build the ray queries once (reused across segments).
        let mut obb_ray: Option<Gd<PhysicsRayQueryParameters3D>> = None;
        let mut terrain_ray: Option<Gd<PhysicsRayQueryParameters3D>> = None;
        let mut obb_excludes: Array<Rid> = Array::new();
        if space_state.is_some() {
            for i in 0..exclude_rids.len() {
                let rid: Rid = exclude_rids.at(i).to();
                obb_excludes.push(rid);
            }

            let mut oray = PhysicsRayQueryParameters3D::new_gd();
            oray.set_collide_with_bodies(true);
            oray.set_collide_with_areas(false);
            oray.set_hit_back_faces(true);
            oray.set_hit_from_inside(true);
            oray.set_collision_mask(1 << 4); // OBB_COLLISION_LAYER
            oray.set_exclude(&obb_excludes);
            obb_ray = Some(oray);

            // Terrain is resolved against the real island colliders (layer 1), the
            // same way live shells are in NativeArmorInteraction::process_travel.
            let mut tray = PhysicsRayQueryParameters3D::new_gd();
            tray.set_collide_with_bodies(true);
            tray.set_collide_with_areas(false);
            tray.set_hit_back_faces(true);
            tray.set_hit_from_inside(false);
            tray.set_collision_mask(1);
            terrain_ray = Some(tray);
        }

        let mut prev_pos = start_pos;
        let mut prev_dist = 0.0f64;
        let mut prev_t = 0.0f64;

        while prev_dist < end_dist {
            let default_next_t = end_time.min(prev_t + max_low_altitude_time_step);
            let default_next_dist = Self::horizontal_position(cos_theta, default_next_t, speed, beta);
            let mut step_dist = min_step.max(default_next_dist - prev_dist);
            let mut can_skip_obb = false;

            if has_nav_map {
                let sdf_dist = nav_bind.as_deref().unwrap().get_distance_impl(prev_pos.x, prev_pos.z);
                if sdf_dist as f64 > sdf_margin {
                    step_dist = step_dist.max(sdf_dist as f64 - sdf_margin);
                }
            }

            let mut next_dist = end_dist.min(prev_dist + step_dist);
            let (mut curr_pos, mut next_t) = position_at_distance(next_dist);

            if (prev_pos.y as f64).min(curr_pos.y as f64) > ship_clear_height {
                can_skip_obb = true;
            } else {
                // Keep ray segments short while we are down in ship territory.
                let capped_t = end_time.min(prev_t + max_low_altitude_time_step);
                let capped_dist = Self::horizontal_position(cos_theta, capped_t, speed, beta);
                if capped_dist > prev_dist && capped_dist < next_dist {
                    next_dist = capped_dist;
                    let (p, t) = position_at_distance(next_dist);
                    curr_pos = p;
                    next_t = t;
                }
            }

            // --- Terrain -------------------------------------------------------
            let mut terrain_found = false;
            let mut terrain_pos = Vector3::new(0.0, 0.0, 0.0);
            let mut terrain_d2 = 0.0f64;
            if let Some(space) = space_state.as_mut() {
                if terrain_ray.is_some() {
                    if !has_nav_map || segment_may_hit_terrain(nav_bind.as_deref(), prev_pos, curr_pos) {
                        // Walk the arc in short sub-segments: a single long chord sags
                        // below the real trajectory and would clip terrain the shell
                        // actually flies over.
                        let mut subs = 1i32;
                        if next_t > prev_t {
                            subs = (((next_t - prev_t) / max_low_altitude_time_step).ceil() as i32).max(1);
                            subs = subs.min(64);
                        }
                        let mut sub_from = prev_pos;
                        for i in 1..=subs {
                            let sub_to = if i == subs {
                                curr_pos
                            } else {
                                position_at_time(prev_t + (next_t - prev_t) * (i as f64 / subs as f64))
                            };
                            let tray = terrain_ray.as_mut().unwrap();
                            tray.set_from(sub_from);
                            tray.set_to(sub_to);
                            let hit = space.intersect_ray(&*tray);
                            if !hit.is_empty() {
                                let hit_pos: Vector3 = hit.get("position").unwrap().to();
                                if hit_pos.y > 0.001 {
                                    terrain_found = true;
                                    terrain_pos = hit_pos;
                                    terrain_d2 = prev_pos.distance_squared_to(hit_pos) as f64;
                                    break;
                                }
                            }
                            sub_from = sub_to;
                        }
                    }
                }
            } else if has_nav_map {
                // No physics world available — fall back to the conservative
                // height-grid estimate.
                if segment_may_hit_terrain(nav_bind.as_deref(), prev_pos, curr_pos) {
                    terrain_found = true;
                    terrain_pos = curr_pos;
                    terrain_d2 = prev_pos.distance_squared_to(curr_pos) as f64;
                }
            }

            // --- Ships ---------------------------------------------------------
            let mut obb_found = false;
            let mut obb_collider = Variant::nil();
            let mut obb_pos = Vector3::new(0.0, 0.0, 0.0);
            let mut obb_d2 = 0.0f64;
            if !can_skip_obb {
                if let (Some(space), Some(oray)) = (space_state.as_mut(), obb_ray.as_mut()) {
                    oray.set_from(prev_pos);
                    oray.set_to(curr_pos);
                    oray.set_exclude(&obb_excludes);
                    // Ships skipped below are only skipped for this segment — a later
                    // segment may still run into the part of the hull it missed here.
                    let base_excludes = obb_excludes.len();
                    for _guard in 0..16 {
                        let hit = space.intersect_ray(&*oray);
                        if hit.is_empty() {
                            break;
                        }
                        let mut hit_pos: Vector3 = hit.get("position").unwrap().to();
                        let mut real_hit = true;
                        if let Some(pw) = precision_world.as_mut() {
                            let collider = hit.get("collider").unwrap();
                            let ship_variant = pw.call("get_ship_from_obb", &[collider]);
                            if !ship_variant.is_nil() {
                                // The OBB is only a broadphase box — confirm the shell
                                // actually intersects hull geometry before calling the
                                // trajectory blocked.
                                let narrow_variant = pw.call(
                                    "narrowphase_hit",
                                    &[ship_variant, prev_pos.to_variant(), curr_pos.to_variant()],
                                );
                                // C++ `(Dictionary)variant` yields an empty dict when the
                                // call returns nil; gdext's `.to()` would panic instead.
                                let narrow: VarDictionary =
                                    narrow_variant.try_to().unwrap_or_default();
                                if narrow.is_empty() {
                                    real_hit = false;
                                } else {
                                    hit_pos = narrow.get("world_pos").unwrap().to();
                                }
                            }
                        }
                        if real_hit {
                            obb_found = true;
                            obb_collider = hit.get("collider").unwrap();
                            obb_pos = hit_pos;
                            obb_d2 = prev_pos.distance_squared_to(hit_pos) as f64;
                            break;
                        }
                        // Passed through the box without touching the hull — skip it and
                        // keep looking further along this segment.
                        if !hit.contains_key("rid") {
                            break;
                        }
                        let rid: Rid = hit.get("rid").unwrap().to();
                        obb_excludes.push(rid);
                        oray.set_exclude(&obb_excludes);
                    }
                    obb_excludes.resize(base_excludes, Rid::Invalid);
                }
            }

            if terrain_found && (!obb_found || terrain_d2 <= obb_d2) {
                result.set("terrain_blocked", true);
                result.set("terrain_position", terrain_pos);
                return result;
            }
            if obb_found {
                result.set("obb_hit", true);
                result.set("obb_collider", &obb_collider);
                result.set("obb_position", obb_pos);
                return result;
            }

            if next_dist <= prev_dist + 1e-6 {
                break;
            }
            prev_pos = curr_pos;
            prev_dist = next_dist;
            prev_t = next_t;
        }

        // --- Aim point probe ---------------------------------------------------
        // The arc above stops exactly at the aim point, and the aim point is very
        // often a raycast hit that lies *on* a terrain face. A ray that terminates
        // on the surface it is testing is a floating-point coin flip, so probe a
        // short way past the aim point to make that case deterministic. The margin
        // is deliberately tiny next to a ship (25 m against ~200 m of hull, here
        // 0.1 m past the point), so terrain *behind* a target still never blocks
        // the shot.
        if let Some(space) = space_state.as_mut() {
            if let Some(tray) = terrain_ray.as_mut() {
                let terrain_end_margin = 0.1f64;
                // Start slightly short of the aim point: the loop already proved that
                // stretch is clear, and it guarantees the probe begins in open air so
                // the crossing into the surface registers.
                let (probe_from, _) = position_at_distance(0.0f64.max(end_dist - 0.1));
                let (probe_to, _) = position_at_distance(end_dist + terrain_end_margin);
                if !has_nav_map || segment_may_hit_terrain(nav_bind.as_deref(), probe_from, probe_to) {
                    tray.set_from(probe_from);
                    tray.set_to(probe_to);
                    let hit = space.intersect_ray(&*tray);
                    if !hit.is_empty() {
                        let hit_pos: Vector3 = hit.get("position").unwrap().to();
                        if hit_pos.y > 0.001 {
                            result.set("terrain_blocked", true);
                            result.set("terrain_position", hit_pos);
                            return result;
                        }
                    }
                }
            }
        }

        result
    }
}

/// Vacuum ballistic launch vector, used only as ProjectilePhysicsWithDragV2's fast
/// initial estimate before drag refinement. Mirrors
/// `ProjectilePhysics::calculate_launch_vector` bit-for-bit (including its own
/// GRAVITY = -9.8, distinct from this class's GRAVITY = 9.81); that method is
/// private to the `physics` module, so the C++ cross-class call is reproduced here

/// Cheap conservative pre-filter: could this straight segment possibly touch
/// terrain? The height grid stores the MAX terrain height per cell and is
/// sampled bilinearly, so it massively over-estimates height near shorelines —
/// it is only ever used to skip the physics ray, never to declare a block.
fn segment_may_hit_terrain(nav: Option<&NavigationMap>, from: Vector3, to: Vector3) -> bool {
    let Some(nav) = nav else {
        return true;
    };
    if !nav.is_built() {
        return true;
    }

    let delta = to - from;
    let dx = delta.x as f64;
    let dz = delta.z as f64;
    let horizontal_len = (dx * dx + dz * dz).sqrt();
    let cell_size = nav.get_cell_size_value();
    let margin = 2.0f64.max(cell_size as f64 * 0.5);
    let terrain_step = 5.0f64.max(cell_size as f64 * 0.5);

    let start_sdf = nav.get_distance_impl(from.x, from.z);
    if start_sdf as f64 > horizontal_len + margin {
        return false;
    }

    let steps: i32 = if horizontal_len > 0.001 {
        2i32.max((horizontal_len / terrain_step).ceil() as i32)
    } else {
        1
    };

    for i in 0..=steps {
        let alpha = i as f64 / steps as f64;
        let pos = from + delta * alpha as f32;
        let sdf = nav.get_distance_impl(pos.x, pos.z);
        if sdf as f64 > margin {
            continue;
        }
        let terrain_height = nav.get_terrain_height_impl(pos.x, pos.z);
        if terrain_height > 0.001 && pos.y as f64 <= terrain_height as f64 + margin {
            return true;
        }
    }
    false
}

fn no_solution2() -> VarArray {
    let mut result = VarArray::new();
    result.push(&Variant::nil());
    result.push(&(-1.0f64).to_variant());
    result
}

fn no_solution3() -> VarArray {
    let mut result = VarArray::new();
    result.push(&Variant::nil());
    result.push(&(-1.0f64).to_variant());
    result.push(&Variant::nil());
    result
}
