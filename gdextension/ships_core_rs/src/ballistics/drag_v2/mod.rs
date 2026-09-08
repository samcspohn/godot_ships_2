use godot::prelude::*;
use godot::classes::{Node, PhysicsDirectSpaceState3D, Resource};

use crate::nav::map::NavigationMap;

mod api3d;
mod core2d;

pub const GRAVITY: f64 = 9.81;
/// Maximum iterations for iterative solutions.
pub const MAX_ITERATIONS: i32 = 4;

/// Analytical ballistics with quadratic drag. Supports angles from -PI/2 to
/// PI/2 (downward to upward, forward only). All methods are static and take
/// ShellParams as an argument.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct ProjectilePhysicsWithDragV2 {
    base: Base<RefCounted>,
}

// Only the surface GDScript actually calls is bound. The C++ additionally binds
// position, velocity, firing_solution, range_at_angle, acosh, advance_turning,
// calculate_absolute_max_range, calculate_max_range_from_angle and
// calculate_angle_from_max_range; none of those bindings has a caller. The
// underlying functions for position/firing_solution/range_at_angle/acosh/
// advance_turning/calculate_absolute_max_range ARE still needed internally and
// are ported as plain associated functions.
#[godot_api]
impl ProjectilePhysicsWithDragV2 {
    #[func]
    fn time_of_flight(theta: f64, shell_params: Gd<Resource>, #[opt(default = 0.0)] target_y: f64) -> f64 {
        Self::time_of_flight_impl(theta, &shell_params, target_y)
    }

    #[func]
    fn calculate_position_at_time(
        start_pos: Vector3,
        launch_vector: Vector3,
        time: f64,
        shell_params: Gd<Resource>,
    ) -> Vector3 {
        Self::calculate_position_at_time_impl(start_pos, launch_vector, time, &shell_params)
    }

    #[func]
    fn calculate_velocity_at_time(
        launch_vector: Vector3,
        time: f64,
        shell_params: Gd<Resource>,
    ) -> Vector3 {
        Self::calculate_velocity_at_time_impl(launch_vector, time, &shell_params)
    }

    #[func]
    fn calculate_launch_vector(
        start_pos: Vector3,
        target_pos: Vector3,
        shell_params: Gd<Resource>,
    ) -> VarArray {
        Self::calculate_launch_vector_impl(start_pos, target_pos, &shell_params)
    }

    #[func]
    fn calculate_leading_launch_vector(
        start_pos: Vector3,
        target_pos: Vector3,
        target_velocity: Vector3,
        shell_params: Gd<Resource>,
    ) -> VarArray {
        Self::calculate_leading_launch_vector_impl(start_pos, target_pos, target_velocity, &shell_params)
    }

    #[func]
    fn calculate_leading_launch_vector_turning(
        start_pos: Vector3,
        target_pos: Vector3,
        target_velocity: Vector3,
        target_yaw_rate: f64,
        shell_params: Gd<Resource>,
    ) -> VarArray {
        Self::calculate_leading_launch_vector_turning_impl(
            start_pos, target_pos, target_velocity, target_yaw_rate, &shell_params,
        )
    }

    #[func]
    fn calculate_impact_position(
        start_pos: Vector3,
        launch_velocity: Vector3,
        shell_params: Gd<Resource>,
    ) -> Vector3 {
        Self::calculate_impact_position_impl(start_pos, launch_velocity, &shell_params)
    }

    #[func]
    fn sim_can_shoot_over_terrain(
        start_pos: Vector3,
        launch_vector: Vector3,
        flight_time: f64,
        shell_params: Gd<Resource>,
        nav_map: Option<Gd<NavigationMap>>,
        space_state: Option<Gd<PhysicsDirectSpaceState3D>>,
        exclude_rids: VarArray,
        precision_world: Option<Gd<Node>>,
    ) -> VarDictionary {
        Self::sim_can_shoot_over_terrain_impl(
            start_pos, launch_vector, flight_time, &shell_params,
            nav_map, space_state, exclude_rids, precision_world,
        )
    }
}
