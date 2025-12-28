#include "projectile_physics.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>

using namespace godot;

void ProjectilePhysics::_bind_methods() {
	// Bind static methods - constants are exposed via getter methods since BIND_CONSTANT only works with integers
	ClassDB::bind_static_method("ProjectilePhysics", D_METHOD("get_gravity"), &ProjectilePhysics::get_gravity);
	ClassDB::bind_static_method("ProjectilePhysics", D_METHOD("calculate_launch_vector", "start_pos", "target_pos", "projectile_speed"), &ProjectilePhysics::calculate_launch_vector);
	ClassDB::bind_static_method("ProjectilePhysics", D_METHOD("calculate_position_at_time", "start_pos", "launch_vector", "time"), &ProjectilePhysics::calculate_position_at_time);
	ClassDB::bind_static_method("ProjectilePhysics", D_METHOD("calculate_leading_launch_vector", "start_pos", "target_pos", "target_velocity", "projectile_speed"), &ProjectilePhysics::calculate_leading_launch_vector);
	ClassDB::bind_static_method("ProjectilePhysics", D_METHOD("calculate_max_range_from_angle", "angle", "projectile_speed"), &ProjectilePhysics::calculate_max_range_from_angle);
	ClassDB::bind_static_method("ProjectilePhysics", D_METHOD("calculate_angle_from_max_range", "max_range", "projectile_speed"), &ProjectilePhysics::calculate_angle_from_max_range);
}

ProjectilePhysics::ProjectilePhysics() {
}

ProjectilePhysics::~ProjectilePhysics() {
}

double ProjectilePhysics::get_gravity() {
	return GRAVITY;
}

Array ProjectilePhysics::calculate_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos, double projectile_speed) {
	Array result;

	// Calculate displacement vector
	Vector3 disp = target_pos - start_pos;

	// Calculate horizontal distance and direction
	double horiz_dist = Vector2(disp.x, disp.z).length();
	double horiz_angle = std::atan2(disp.z, disp.x);

	// Physical parameters
	double g = std::abs(GRAVITY);
	double v = projectile_speed;
	double h = disp.y;

	// Calculate the discriminant from the quadratic equation derived from the physics
	double discriminant = std::pow(v, 4) - g * (g * std::pow(horiz_dist, 2) + 2 * h * std::pow(v, 2));

	if (discriminant < 0) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result; // No solution exists - target is out of range
	}

	// Calculate the two possible elevation angles (high and low arc)
	double sqrt_disc = std::sqrt(discriminant);
	double angle1 = std::atan((std::pow(v, 2) + sqrt_disc) / (g * horiz_dist));
	double angle2 = std::atan((std::pow(v, 2) - sqrt_disc) / (g * horiz_dist));

	// Calculate flight times for both possible angles
	// A valid trajectory requires that cos(angle) != 0 (not firing straight up or down)
	double time1 = -1.0;
	double time2 = -1.0;

	if (std::abs(std::cos(angle1)) > 0.001) { // Avoid division by zero
		time1 = horiz_dist / (v * std::cos(angle1));
		// Make sure this is a valid forward trajectory (not firing backward)
		if (time1 <= 0) {
			time1 = -1.0;
		}
	}

	if (std::abs(std::cos(angle2)) > 0.001) { // Avoid division by zero
		time2 = horiz_dist / (v * std::cos(angle2));
		// Make sure this is a valid forward trajectory (not firing backward)
		if (time2 <= 0) {
			time2 = -1.0;
		}
	}

	// Choose the angle that results in the shortest time to target (shortest path)
	double elev_angle;

	// If only one solution is valid, use that one
	if (time1 < 0 && time2 >= 0) {
		elev_angle = angle2;
	} else if (time2 < 0 && time1 >= 0) {
		elev_angle = angle1;
	// If both are valid, use the one with shorter time
	} else if (time1 >= 0 && time2 >= 0) {
		elev_angle = (time1 < time2) ? angle1 : angle2;
	} else {
		// No valid solution
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result;
	}

	// Calculate the initial velocity components
	Vector3 launch_vector(
		v * std::cos(elev_angle) * std::cos(horiz_angle),
		v * std::sin(elev_angle),
		v * std::cos(elev_angle) * std::sin(horiz_angle)
	);

	// Calculate time to target
	double time_to_target = horiz_dist / (v * std::cos(elev_angle));

	result.push_back(launch_vector);
	result.push_back(time_to_target);
	return result;
}

Vector3 ProjectilePhysics::calculate_position_at_time(const Vector3 &start_pos, const Vector3 &launch_vector, double time) {
	return Vector3(
		start_pos.x + launch_vector.x * time,
		start_pos.y + launch_vector.y * time + 0.5 * GRAVITY * time * time,
		start_pos.z + launch_vector.z * time
	);
}

Array ProjectilePhysics::calculate_leading_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
	const Vector3 &target_velocity, double projectile_speed) {

	// Start with the time it would take to hit the current position
	Array result = calculate_launch_vector(start_pos, target_pos, projectile_speed);

	if (result[0].get_type() == Variant::NIL) {
		Array no_solution;
		no_solution.push_back(Variant()); // null
		no_solution.push_back(-1.0);
		return no_solution; // No solution exists
	}

	double time_estimate = result[1];

	// Refine the estimate a few times
	for (int i = 0; i < 1; i++) { // Just a few iterations should be sufficient
		Vector3 predicted_pos = target_pos + target_velocity * time_estimate;
		result = calculate_launch_vector(start_pos, predicted_pos, projectile_speed);

		if (result[0].get_type() == Variant::NIL) {
			Array no_solution;
			no_solution.push_back(Variant()); // null
			no_solution.push_back(-1.0);
			return no_solution;
		}

		time_estimate = result[1];
	}

	// Final calculation with the best time estimate
	Vector3 final_target_pos = target_pos + target_velocity * time_estimate;
	return calculate_launch_vector(start_pos, final_target_pos, projectile_speed);
}

double ProjectilePhysics::calculate_max_range_from_angle(double angle, double projectile_speed) {
	double g = std::abs(GRAVITY);

	// Using the range formula: R = (v² * sin(2θ)) / g
	double max_range = (std::pow(projectile_speed, 2) * std::sin(2 * angle)) / g;

	// Handle negative results (when firing downward)
	if (max_range < 0) {
		return 0.0;
	}

	return max_range;
}

double ProjectilePhysics::calculate_angle_from_max_range(double max_range, double projectile_speed) {
	double g = std::abs(GRAVITY);

	// The theoretical maximum range is achieved at 45 degrees
	double theoretical_max = std::pow(projectile_speed, 2) / g;

	// Check if the requested range is physically possible
	if (max_range > theoretical_max || max_range < 0) {
		return -1; // Impossible range
	}

	// Using the formula: sin(2θ) = (R * g) / v²
	double sin_2theta = (max_range * g) / std::pow(projectile_speed, 2);

	// Calculate the angle (there are two solutions, we'll return the flatter trajectory)
	double angle = std::asin(sin_2theta) / 2;

	return angle;
}