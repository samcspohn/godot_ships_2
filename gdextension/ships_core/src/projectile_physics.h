#ifndef PROJECTILE_PHYSICS_H
#define PROJECTILE_PHYSICS_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class ProjectilePhysics : public Node {
	GDCLASS(ProjectilePhysics, Node)

public:
	// Constants
	static constexpr double GRAVITY = -9.8;

protected:
	static void _bind_methods();

public:
	ProjectilePhysics();
	~ProjectilePhysics();

	// Static methods exposed to GDScript
	static double get_gravity();

	/// Calculates the launch vector needed to hit a stationary target from a given position
	/// with a specified projectile speed
	/// Returns [launch_vector, time_to_target] or [null, -1] if no solution exists
	static Array calculate_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos, double projectile_speed);

	/// Calculate projectile position at any time without simulation
	static Vector3 calculate_position_at_time(const Vector3 &start_pos, const Vector3 &launch_vector, double time);

	/// Calculate launch vector to lead a moving target
	/// This uses the analytical solution with iterative refinement
	static Array calculate_leading_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
		const Vector3 &target_velocity, double projectile_speed);

	/// Calculate the maximum horizontal range given a launch angle and projectile speed
	/// Returns the maximum distance the projectile can travel on flat ground
	static double calculate_max_range_from_angle(double angle, double projectile_speed);

	/// Calculate the required launch angle to achieve a specific maximum range
	/// Returns the angle in radians or -1 if the range exceeds the physical limit
	static double calculate_angle_from_max_range(double max_range, double projectile_speed);
};

} // namespace godot

#endif // PROJECTILE_PHYSICS_H