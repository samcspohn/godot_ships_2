#ifndef PROJECTILE_PHYSICS_WITH_DRAG_V2_H
#define PROJECTILE_PHYSICS_WITH_DRAG_V2_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/array.hpp>

namespace godot {

/// Analytical ballistics with quadratic drag.
/// Supports angles from -π/2 to π/2 (downward to upward, forward only).
/// All methods are static and take ShellParams as an argument.
class ProjectilePhysicsWithDragV2 : public RefCounted {
	GDCLASS(ProjectilePhysicsWithDragV2, RefCounted)

public:
	// Gravity constant
	static constexpr double GRAVITY = 9.81;

	// Maximum iterations for iterative solutions
	static constexpr int MAX_ITERATIONS = 4;

protected:
	static void _bind_methods();

public:
	ProjectilePhysicsWithDragV2();
	~ProjectilePhysicsWithDragV2();

	//==========================================================================
	// 2D Forward Problem - Calculate position/velocity given angle and time
	//==========================================================================

	/// Calculate position at time t for a given launch angle theta
	/// Returns Vector2(x, y) where x is horizontal distance and y is vertical
	/// @param shell_params Resource with speed (v0), drag (beta), vt, tau properties
	static Vector2 position(double theta, double t, const Ref<Resource> &shell_params);

	/// Calculate velocity at time t for a given launch angle theta
	/// Returns Vector2(vx, vy)
	/// @param shell_params Resource with speed (v0), drag (beta), vt, tau properties
	static Vector2 velocity(double theta, double t, const Ref<Resource> &shell_params);

	//==========================================================================
	// 2D Inverse Problem - Calculate firing solution to hit a target
	//==========================================================================

	/// Calculate firing solution to hit target at (target_x, target_y)
	/// @param target_x Horizontal distance to target (must be > 0)
	/// @param target_y Vertical distance to target
	/// @param shell_params Resource with speed (v0), drag (beta), vt, tau properties
	/// @param high_arc If true, returns the high arc solution; otherwise low arc
	/// @return Vector2(theta, time) or Vector2(NAN, NAN) if no solution exists
	static Vector2 firing_solution(double target_x, double target_y, const Ref<Resource> &shell_params, bool high_arc = false);

	//==========================================================================
	// 2D Utility Functions
	//==========================================================================

	/// Calculate time of flight for a given angle to reach target_y
	/// @param theta Launch angle in radians
	/// @param shell_params Resource with speed (v0), drag (beta), vt, tau properties
	/// @param target_y Target vertical position (default 0.0 for ground level)
	/// @return Time of flight, or NAN if target cannot be reached
	static double time_of_flight(double theta, const Ref<Resource> &shell_params, double target_y = 0.0);

	/// Calculate horizontal range at a given angle (to y=0)
	/// @param theta Launch angle in radians
	/// @param shell_params Resource with speed (v0), drag (beta), vt, tau properties
	/// @return Horizontal range, or NAN if no valid solution
	static double range_at_angle(double theta, const Ref<Resource> &shell_params);

	/// Inverse hyperbolic cosine (acosh)
	static double acosh(double x);

	//==========================================================================
	// 3D API - Compatible with ProjectilePhysicsWithDrag interface
	//==========================================================================

	/// Calculate projectile position at any time with drag effects
	/// @param start_pos Starting position in 3D space
	/// @param launch_vector Initial velocity vector
	/// @param time Time since launch
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Position at the given time
	static Vector3 calculate_position_at_time(const Vector3 &start_pos, const Vector3 &launch_vector,
		double time, const Ref<Resource> &shell_params);

	/// Calculate projectile velocity at any time with drag effects
	/// @param launch_vector Initial velocity vector
	/// @param time Time since launch
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Velocity vector at the given time
	static Vector3 calculate_velocity_at_time(const Vector3 &launch_vector, double time,
		const Ref<Resource> &shell_params);

	/// Calculate the launch vector needed to hit a stationary target
	/// @param start_pos Starting position
	/// @param target_pos Target position
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Array [launch_vector: Vector3, time_to_target: float] or [null, -1] if no solution
	static Array calculate_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
		const Ref<Resource> &shell_params);

	/// Calculate launch vector to lead a moving target with drag effects
	/// @param start_pos Starting position
	/// @param target_pos Current target position
	/// @param target_velocity Target's velocity vector
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Array [launch_vector, time_to_target, predicted_target_position] or [null, -1, null] if no solution
	static Array calculate_leading_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
		const Vector3 &target_velocity, const Ref<Resource> &shell_params);

	/// Calculate the impact position where y = 0
	/// @param start_pos Starting position
	/// @param launch_velocity Initial velocity vector
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Impact position at ground level
	static Vector3 calculate_impact_position(const Vector3 &start_pos, const Vector3 &launch_velocity,
		const Ref<Resource> &shell_params);

	/// Calculate the absolute maximum range possible with the given shell params
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Array [max_range, optimal_angle, flight_time]
	static Array calculate_absolute_max_range(const Ref<Resource> &shell_params);

	/// Calculate the maximum horizontal range given a launch angle
	/// @param angle Launch angle in radians
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Maximum horizontal range at this angle
	static double calculate_max_range_from_angle(double angle, const Ref<Resource> &shell_params);

	/// Calculate the required launch angle to achieve a specific range
	/// @param max_range Desired horizontal range
	/// @param shell_params Resource with speed, drag, vt, tau properties
	/// @return Required launch angle in radians
	static double calculate_angle_from_max_range(double max_range, const Ref<Resource> &shell_params);

private:
	//==========================================================================
	// Internal Helper Functions - 2D Analytical
	//==========================================================================

	// Horizontal motion
	static double _horizontal_position(double cos_theta, double t, double v0, double beta);
	static double _horizontal_velocity(double cos_theta, double t, double v0, double beta);

	// Vertical motion
	static double _vertical_position(double sin_theta, double t, double v0, double vt, double tau);
	static double _vertical_velocity(double sin_theta, double t, double v0, double vt, double tau);

	// Inverse problem helpers
	static double _time_from_x(double x, double theta, double v0, double beta);
	static double _vacuum_angle(double x, double y, double v0, bool high_arc);
	static double _newton_refine_angle(double theta, double target_x, double target_y, int max_iter, double v0, double beta, double vt, double tau);

	// Derivatives for Newton refinement
	static double _total_deriv_y_theta(double theta, double x, double t, double v0, double beta, double vt, double tau);
	static double _time_deriv_theta(double x, double theta, double t, double v0, double beta);
	static double _vertical_position_deriv_s(double sin_theta, double t, double v0, double vt, double tau);

	//==========================================================================
	// Internal Helper Functions - 3D
	//==========================================================================

	/// Extract shell parameters from resource
	static bool _extract_params(const Ref<Resource> &shell_params, double &v0, double &beta, double &vt, double &tau);
};

} // namespace godot

#endif // PROJECTILE_PHYSICS_WITH_DRAG_V2_H
