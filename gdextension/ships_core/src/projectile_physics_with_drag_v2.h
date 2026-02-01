#ifndef PROJECTILE_PHYSICS_WITH_DRAG_V2_H
#define PROJECTILE_PHYSICS_WITH_DRAG_V2_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

/// Analytical ballistics with quadratic drag.
/// Supports angles from -π/2 to π/2 (downward to upward, forward only).
/// All methods are static and take ShellParams as an argument.
class ProjectilePhysicsWithDragV2 : public RefCounted {
	GDCLASS(ProjectilePhysicsWithDragV2, RefCounted)

public:
	// Gravity constant
	static constexpr double GRAVITY = 9.81;

protected:
	static void _bind_methods();

public:
	ProjectilePhysicsWithDragV2();
	~ProjectilePhysicsWithDragV2();

	//==========================================================================
	// Forward Problem - Calculate position/velocity given angle and time
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
	// Inverse Problem - Calculate firing solution to hit a target
	//==========================================================================

	/// Calculate firing solution to hit target at (target_x, target_y)
	/// @param target_x Horizontal distance to target (must be > 0)
	/// @param target_y Vertical distance to target
	/// @param shell_params Resource with speed (v0), drag (beta), vt, tau properties
	/// @param high_arc If true, returns the high arc solution; otherwise low arc
	/// @param refine If true, uses Newton refinement for higher accuracy
	/// @return Vector2(theta, time) or Vector2(NAN, NAN) if no solution exists
	static Vector2 firing_solution(double target_x, double target_y, const Ref<Resource> &shell_params, bool high_arc = false, bool refine = true);

	//==========================================================================
	// Utility Functions
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

private:
	//==========================================================================
	// Internal Helper Functions
	//==========================================================================

	// Horizontal motion
	static double _horizontal_position(double cos_theta, double t, double v0, double beta);
	static double _horizontal_velocity(double cos_theta, double t, double v0, double beta);

	// Vertical motion
	static double _vertical_position(double sin_theta, double t, double v0, double vt, double tau);
	static double _vertical_velocity(double sin_theta, double t, double v0, double vt, double tau);

	// Inverse problem helpers
	static double _time_from_x(double x, double theta, double v0, double beta);
	static double _analytical_angle(double x, double y, double v0, double beta, bool high_arc);
	static double _newton_refine_angle(double theta, double target_x, double target_y, int max_iter, double v0, double beta, double vt, double tau);

	// Derivatives for Newton refinement
	static double _total_deriv_y_theta(double theta, double x, double t, double v0, double beta, double vt, double tau);
	static double _time_deriv_theta(double x, double theta, double t, double v0, double beta);
	static double _vertical_position_deriv_s(double sin_theta, double t, double v0, double vt, double tau);
};

} // namespace godot

#endif // PROJECTILE_PHYSICS_WITH_DRAG_V2_H