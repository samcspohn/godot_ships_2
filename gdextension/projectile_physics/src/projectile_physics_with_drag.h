#ifndef PROJECTILE_PHYSICS_WITH_DRAG_H
#define PROJECTILE_PHYSICS_WITH_DRAG_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class ProjectilePhysicsWithDrag : public Node {
	GDCLASS(ProjectilePhysicsWithDrag, Node)

public:
	// Constants
	static constexpr double GRAVITY = -9.8;
	static constexpr double DEFAULT_DRAG_COEFFICIENT = 0.1 / 50.0;

	// Specific object drag coefficients - formula: (Cd × Area) / Mass
	// German 380mm AP shell - recalculated with proper ballistic coefficient
	// Diameter: 380mm, Mass: 800kg, Cd: 0.17 (streamlined artillery shell)
	static constexpr double SHELL_380MM_DRAG_COEFFICIENT = 0.009;

	// Ping Pong Ball
	// Diameter: 40mm, Mass: 2.7g, Cd: 0.5 (sphere)
	static constexpr double PING_PONG_DRAG_COEFFICIENT = 0.233;

	// Bowling Ball
	// Diameter: 218mm, Mass: 7kg, Cd: 0.5 (smooth sphere)
	static constexpr double BOWLING_BALL_DRAG_COEFFICIENT = 0.00267;

	// Target position tolerance (in meters)
	static constexpr double POSITION_TOLERANCE = 0.05;
	// Maximum iterations for binary search
	static constexpr int MAX_ITERATIONS = 16;
	// Angle adjustment step for binary search (in radians)
	static constexpr double INITIAL_ANGLE_STEP = 0.1;

protected:
	static void _bind_methods();

public:
	ProjectilePhysicsWithDrag();
	~ProjectilePhysicsWithDrag();

	// Constant accessors for GDScript compatibility
	static double get_gravity();
	static double get_default_drag_coefficient();
	static double get_shell_380mm_drag_coefficient();
	static double get_ping_pong_drag_coefficient();
	static double get_bowling_ball_drag_coefficient();
	static double get_position_tolerance();
	static int get_max_iterations();
	static double get_initial_angle_step();

	/// Calculate the absolute maximum range possible with the given projectile speed,
	/// regardless of direction, and return [max_range, optimal_angle, flight_time]
	static Array calculate_absolute_max_range(double projectile_speed, double drag_coefficient);

	/// Calculate projectile velocity at any time with drag effects
	/// Returns the velocity vector at the specified time
	static Vector3 calculate_velocity_at_time(const Vector3 &launch_vector, double time, double drag_coefficient);

	/// Calculates shell position with endpoint precision guarantee
	/// This ensures the shell will hit exactly at the target position despite floating point errors
	/// Allows shell to continue past the target with the correct final velocity
	static Vector3 calculate_precise_shell_position(const Vector3 &start_pos, const Vector3 &target_pos,
		const Vector3 &launch_vector, double current_time, double total_flight_time, double drag_coefficient);

	/// Calculates the launch vector needed to hit a stationary target from a given position
	/// with drag effects considered
	/// Returns [launch_vector, time_to_target] or [null, -1] if no solution exists
	static Array calculate_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
		double projectile_speed, double drag_coefficient);

	/// Calculate the impact position where y = 0 using advanced analytical approximation
	/// This function uses Newton-Raphson refinement with a high-accuracy initial guess
	/// to solve the transcendental equation for projectile motion with drag
	static Vector3 calculate_impact_position(const Vector3 &start_pos, const Vector3 &launch_velocity,
		double drag_coefficient);

	/// Estimate time of flight with drag effects
	static double estimate_time_of_flight(const Vector3 &start_pos, const Vector3 &launch_vector,
		double horiz_dist, double drag_coefficient);

	/// Calculate projectile position at any time with drag effects
	static Vector3 calculate_position_at_time(const Vector3 &start_pos, const Vector3 &launch_vector,
		double time, double drag_coefficient);

	/// Calculate launch vector to lead a moving target with drag effects
	/// Returns [launch_vector, time_to_target, final_target_position] or [null, -1, null] if no solution exists
	static Array calculate_leading_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
		const Vector3 &target_velocity, double projectile_speed, double drag_coefficient);

	/// Calculate the maximum horizontal range given a launch angle, accounting for drag
	static double calculate_max_range_from_angle(double angle, double projectile_speed, double drag_coefficient);

	/// Calculate the required launch angle to achieve a specific range with drag
	static double calculate_angle_from_max_range(double max_range, double projectile_speed, double drag_coefficient);
};

} // namespace godot

#endif // PROJECTILE_PHYSICS_WITH_DRAG_H