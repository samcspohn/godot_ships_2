#include "projectile_physics_with_drag.h"
#include "projectile_physics.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>

using namespace godot;

void ProjectilePhysicsWithDrag::_bind_methods() {
	// Bind integer constants (BIND_CONSTANT only works with integers)
	BIND_CONSTANT(MAX_ITERATIONS);

	// Bind constant accessors for GDScript compatibility (floats exposed via getters)
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_gravity"), &ProjectilePhysicsWithDrag::get_gravity);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_default_drag_coefficient"), &ProjectilePhysicsWithDrag::get_default_drag_coefficient);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_shell_380mm_drag_coefficient"), &ProjectilePhysicsWithDrag::get_shell_380mm_drag_coefficient);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_ping_pong_drag_coefficient"), &ProjectilePhysicsWithDrag::get_ping_pong_drag_coefficient);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_bowling_ball_drag_coefficient"), &ProjectilePhysicsWithDrag::get_bowling_ball_drag_coefficient);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_position_tolerance"), &ProjectilePhysicsWithDrag::get_position_tolerance);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_max_iterations"), &ProjectilePhysicsWithDrag::get_max_iterations);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_initial_angle_step"), &ProjectilePhysicsWithDrag::get_initial_angle_step);

	// Bind static methods
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_absolute_max_range", "shell_params"), &ProjectilePhysicsWithDrag::calculate_absolute_max_range);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_velocity_at_time", "launch_vector", "time", "shell_params"), &ProjectilePhysicsWithDrag::calculate_velocity_at_time);
	// ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_precise_shell_position", "start_pos", "target_pos", "launch_vector", "current_time", "total_flight_time", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_precise_shell_position);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_launch_vector", "start_pos", "target_pos", "shell_params"), &ProjectilePhysicsWithDrag::calculate_launch_vector);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_impact_position", "start_pos", "launch_velocity", "shell_params"), &ProjectilePhysicsWithDrag::calculate_impact_position);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("estimate_time_of_flight", "start_pos", "launch_vector", "horiz_dist", "shell_params"), &ProjectilePhysicsWithDrag::estimate_time_of_flight);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_position_at_time", "start_pos", "launch_vector", "time", "shell_params"), &ProjectilePhysicsWithDrag::calculate_position_at_time);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_leading_launch_vector", "start_pos", "target_pos", "target_velocity", "shell_params"), &ProjectilePhysicsWithDrag::calculate_leading_launch_vector);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_max_range_from_angle", "angle", "shell_params"), &ProjectilePhysicsWithDrag::calculate_max_range_from_angle);
	ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_angle_from_max_range", "max_range", "shell_params"), &ProjectilePhysicsWithDrag::calculate_angle_from_max_range);
}

ProjectilePhysicsWithDrag::ProjectilePhysicsWithDrag() {
}

ProjectilePhysicsWithDrag::~ProjectilePhysicsWithDrag() {
}

float ProjectilePhysicsWithDrag::time_warp(double t, Ref<Resource> params) {
	if (!params.is_valid()) {
		return t; // No warp if params are invalid
	}
	
	Variant rate_var = params->get("time_warp_rate");
	Variant apex_var = params->get("time_warp_apex");
	Variant k_var = params->get("time_warp_k");
	
	// Use safe defaults if properties don't exist or are nil
	float rate = (rate_var.get_type() != Variant::NIL) ? (float)rate_var : 1.0f;
	float apex = (apex_var.get_type() != Variant::NIL) ? (float)apex_var : 30.0f;
	float k = (k_var.get_type() != Variant::NIL) ? (float)k_var : 0.0f;

	return rate * t + k * (pow(t - apex, 3.0) + pow(apex, 3.0)) / 3.0;
}
// Constant accessors
double ProjectilePhysicsWithDrag::get_gravity() {
	return GRAVITY;
}

double ProjectilePhysicsWithDrag::get_default_drag_coefficient() {
	return DEFAULT_DRAG_COEFFICIENT;
}

double ProjectilePhysicsWithDrag::get_shell_380mm_drag_coefficient() {
	return SHELL_380MM_DRAG_COEFFICIENT;
}

double ProjectilePhysicsWithDrag::get_ping_pong_drag_coefficient() {
	return PING_PONG_DRAG_COEFFICIENT;
}

double ProjectilePhysicsWithDrag::get_bowling_ball_drag_coefficient() {
	return BOWLING_BALL_DRAG_COEFFICIENT;
}

double ProjectilePhysicsWithDrag::get_position_tolerance() {
	return POSITION_TOLERANCE;
}

int ProjectilePhysicsWithDrag::get_max_iterations() {
	return MAX_ITERATIONS;
}

double ProjectilePhysicsWithDrag::get_initial_angle_step() {
	return INITIAL_ANGLE_STEP;
}

Array ProjectilePhysicsWithDrag::calculate_absolute_max_range(Ref<Resource> shell_params) {
	// Initialize search parameters
	double min_range = 0.0;
	double projectile_speed = shell_params->get("speed");
	double max_range = projectile_speed * projectile_speed / std::abs(GRAVITY) * 2.0; // Theoretical max without drag
	double best_range = 0.0;
	double best_angle = 0.0;
	double best_time = 0.0;

	// Binary search to find maximum range
	for (int i = 0; i < MAX_ITERATIONS; i++) {
		double test_range = (min_range + max_range) / 2.0;
		Vector3 target_pos = Vector3(test_range, 0, 0);
		Array result = calculate_launch_vector(Vector3(), target_pos, shell_params);

		if (result[0].get_type() != Variant::NIL && (double)result[1] > 0) {
			if (test_range > best_range) {
				best_range = test_range;
				Vector3 velocity = result[0];
				best_angle = std::atan2(velocity.y, std::sqrt(velocity.x * velocity.x + velocity.z * velocity.z));
				best_time = result[1];
				min_range = best_range;
			}
		} else {
			max_range = test_range;
		}

		if (max_range - min_range < 0.01) { // 1cm tolerance
			break;
		}
	}

	Array result;
	result.push_back(best_range);
	result.push_back(best_angle);
	result.push_back(best_time);
	return result;
}

Vector3 ProjectilePhysicsWithDrag::calculate_velocity_at_time(const Vector3 &launch_vector, double time, double drag_coefficient) {
	double v0x = launch_vector.x;
	double v0y = launch_vector.y;
	double v0z = launch_vector.z;
	double beta = drag_coefficient;
	double g = std::abs(GRAVITY);

	// Calculate exponential decay due to drag
	double drag_decay = std::exp(-beta * time);

	// For x and z (horizontal components with drag)
	// vx = v₀x * e^(-βt)
	double vx = v0x * drag_decay;
	double vz = v0z * drag_decay;

	// For y (vertical component with drag and gravity)
	// vy = v₀y * e^(-βt) - (g/β) + (g/β) * e^(-βt)
	double vy = v0y * drag_decay - (g / beta) + (g / beta) * drag_decay;

	return Vector3(vx, vy, vz);
}

// Vector3 ProjectilePhysicsWithDrag::calculate_precise_shell_position(const Vector3 &start_pos, const Vector3 &target_pos,
// 	const Vector3 &launch_vector, double current_time, double total_flight_time, double drag_coefficient) {

// 	// Safety check
// 	if (total_flight_time <= 0.0) {
// 		return start_pos;
// 	}

// 	// If we haven't reached the target yet, use physics with correction
// 	if (current_time <= total_flight_time) {
// 		// Calculate the physically expected position using drag physics
// 		Vector3 physics_position = calculate_position_at_time(start_pos, launch_vector, current_time, drag_coefficient);

// 		// If we're at the end time or very close to it, return exactly the target position
// 		if (Math::is_equal_approx(current_time, total_flight_time) ||
// 			(total_flight_time - current_time) < 0.001) {
// 			return target_pos;
// 		}

// 		// Generate a correction factor that smoothly transitions from 0 to 1
// 		// Starts small and increases toward the end of the flight
// 		// Using a smooth cubic function for natural-looking correction
// 		double t = current_time / total_flight_time;
// 		double correction_strength = t * t * t; // Smooth step function

// 		// Apply increasing correction as we get closer to the target
// 		// For artillery shells, the correction is very small until near the end
// 		Vector3 projected_error = target_pos - calculate_position_at_time(start_pos, launch_vector,
// 			total_flight_time, drag_coefficient);
// 		// Scale error correction - minimal during most of flight, increasing toward end
// 		Vector3 corrected_position = physics_position + projected_error * correction_strength;

// 		return corrected_position;
// 	}

// 	// If we're past the target, extrapolate from end position using end velocity
// 	else {
// 		// Calculate velocity at impact point
// 		Vector3 impact_velocity = calculate_velocity_at_time(launch_vector, total_flight_time, drag_coefficient);

// 		// Ensure we have exactly the target position at impact time
// 		double excess_time = current_time - total_flight_time;

// 		// Linear extrapolation past the target using the final velocity
// 		return target_pos + impact_velocity * excess_time;
// 	}
// }

Array ProjectilePhysicsWithDrag::calculate_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
	Ref<Resource> shell_params) {

	Array result;

	// Start with the non-drag physics as initial approximation
	Array initial_result = ProjectilePhysics::calculate_launch_vector(start_pos, target_pos, shell_params->get("speed"));

	if (initial_result[0].get_type() == Variant::NIL) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result; // Target is out of range even without drag
	}

	Vector3 initial_vector = initial_result[0];

	// Calculate direction to target (azimuth angle - remains constant)
	Vector3 disp = target_pos - start_pos;
	double horiz_dist = Vector2(disp.x, disp.z).length();
	Vector2 horiz_dir = Vector2(disp.x, disp.z).normalized();

	// Extract elevation angle from initial vector
	double initial_speed_xz = Vector2(initial_vector.x, initial_vector.z).length();
	double elevation_angle = std::atan2(initial_vector.y, initial_speed_xz);

	double beta = shell_params->get("drag");
	double g = std::abs(GRAVITY);
	double theta = elevation_angle;

	// Newton-Raphson refinement loop
	const int REFINEMENT_ITERATIONS = 3;
	const double DELTA_THETA = 0.0001;

	double v0_horiz;
	double v0y;
	double drag_factor;
	double flight_time;
	double drag_decay;
	double calc_y;
	double f_val;
	double projectile_speed = shell_params->get("speed");


	for (int iteration = 0; iteration < REFINEMENT_ITERATIONS; iteration++) {
		// Calculate current trajectory error
		v0_horiz = projectile_speed * std::cos(theta);
		v0y = projectile_speed * std::sin(theta);

		// Calculate flight time using horizontal constraint: horiz_dist = (v₀/β)(1-e^(-βt))
		drag_factor = beta * horiz_dist / v0_horiz;
		if (drag_factor >= 0.99) {
			result.push_back(Variant()); // null
			result.push_back(-1.0);
			return result; // Too much drag
		}

		flight_time = -std::log(1.0 - drag_factor) / beta;

		// Calculate vertical position at this flight time
		drag_decay = 1.0 - std::exp(-beta * flight_time);
		calc_y = start_pos.y + (v0y / beta) * drag_decay - (g / beta) * flight_time + (g / (beta * beta)) * drag_decay;
		f_val = calc_y - target_pos.y;

		// Calculate derivative numerically
		double theta_plus = theta + DELTA_THETA;
		double v0_horiz_plus = projectile_speed * std::cos(theta_plus);
		double v0y_plus = projectile_speed * std::sin(theta_plus);

		double drag_factor_plus = beta * horiz_dist / v0_horiz_plus;
		if (drag_factor_plus < 0.99) {
			double flight_time_plus = -std::log(1.0 - drag_factor_plus) / beta;
			double drag_decay_plus = 1.0 - std::exp(-beta * flight_time_plus);
			double calc_y_plus = start_pos.y + (v0y_plus / beta) * drag_decay_plus - (g / beta) * flight_time_plus + (g / (beta * beta)) * drag_decay_plus;
			double f_prime = (calc_y_plus - calc_y) / DELTA_THETA;

			if (std::abs(f_prime) > 1e-10) {
				theta = theta - f_val / f_prime;
			}
		}
	}

	// Create final launch vector
	Vector3 final_launch_vector(
		projectile_speed * std::cos(theta) * horiz_dir.x,
		projectile_speed * std::sin(theta),
		projectile_speed * std::cos(theta) * horiz_dir.y
	);

	// Calculate final flight time
	double final_v0_horiz = projectile_speed * std::cos(theta);
	double final_drag_factor = beta * horiz_dist / final_v0_horiz;

	if (final_drag_factor >= 0.99) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result;
	}

	double final_flight_time = -std::log(1.0 - final_drag_factor) / beta;

	// Verify accuracy - check if we hit close enough to target
	double final_drag_decay = 1.0 - std::exp(-beta * final_flight_time);
	double final_y = start_pos.y + (projectile_speed * std::sin(theta) / beta) * final_drag_decay - (g / beta) * final_flight_time + (g / (beta * beta)) * final_drag_decay;

	double error_distance = std::abs(final_y - target_pos.y);
	if (error_distance > POSITION_TOLERANCE) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result; // Solution not accurate enough
	}

	double warped_time = time_warp(final_flight_time, shell_params);

	result.push_back(final_launch_vector);
	result.push_back(warped_time);
	return result;
}

Vector3 ProjectilePhysicsWithDrag::calculate_impact_position(const Vector3 &start_pos, const Vector3 &launch_velocity,
	double drag_coefficient) {

	// Safety checks
	if (start_pos.y <= 0.0) {
		return start_pos; // Already at or below ground level
	}

	if (drag_coefficient <= 0.0) {
		UtilityFunctions::push_error("Invalid drag coefficient: must be positive");
		return Vector3();
	}

	// Extract components
	double y0 = start_pos.y;
	double v0y = launch_velocity.y;
	double v0x = launch_velocity.x;
	double v0z = launch_velocity.z;
	double beta = drag_coefficient;
	double g = std::abs(GRAVITY);

	// First, get a very good initial guess using the ballistic formula (no drag)
	double no_drag_time = 0.0;
	if (v0y >= 0) {
		// Upward trajectory: t = (v₀y + sqrt(v₀y² + 2gy₀))/g
		no_drag_time = (v0y + std::sqrt(v0y * v0y + 2.0 * g * y0)) / g;
	} else {
		// Downward trajectory: t = (-v₀y + sqrt(v₀y² + 2gy₀))/g
		double discriminant = v0y * v0y + 2.0 * g * y0;
		if (discriminant < 0) {
			return Vector3(); // No solution
		}
		no_drag_time = (-v0y + std::sqrt(discriminant)) / g;
	}

	// Refine using Newton-Raphson method (analytically - fixed number of steps)
	double t = no_drag_time;

	// Apply 2 Newton-Raphson steps for high accuracy
	// Step 1
	double exp_term = std::exp(-beta * t);
	double f_val = y0 + (v0y / beta) * (1.0 - exp_term) - (g / beta) * t + (g / (beta * beta)) * (1.0 - exp_term);
	double f_prime = (v0y + g / beta) * exp_term - g / beta;

	if (std::abs(f_prime) > 1e-10) {
		t = t - f_val / f_prime;
	}

	// Step 2 (refinement)
	exp_term = std::exp(-beta * t);
	f_val = y0 + (v0y / beta) * (1.0 - exp_term) - (g / beta) * t + (g / (beta * beta)) * (1.0 - exp_term);
	f_prime = (v0y + g / beta) * exp_term - g / beta;

	if (std::abs(f_prime) > 1e-10) {
		t = t - f_val / f_prime;
	}

	// Ensure positive time
	if (t <= 0) {
		return Vector3();
	}

	// Calculate final horizontal positions using analytical drag formula
	double drag_factor = 1.0 - std::exp(-beta * t);

	double final_x = start_pos.x + (v0x / beta) * drag_factor;
	double final_z = start_pos.z + (v0z / beta) * drag_factor;

	// Return impact position (y = 0 by definition)
	return Vector3(final_x, 0.0, final_z);
}

double ProjectilePhysicsWithDrag::estimate_time_of_flight(const Vector3 &start_pos, const Vector3 &launch_vector,
	double horiz_dist, double drag_coefficient) {

	// Extract horizontal and vertical components
	double v0_horiz = Vector2(launch_vector.x, launch_vector.z).length();
	double beta = drag_coefficient;

	// For horizontal motion with drag: x = (v₀/β) * (1-e^(-βt))
	// Solve for t: t = -ln(1-βx/v₀)/β

	// We need to find approximate time based on horizontal distance
	double target_time = 0.0;

	// Solve for time using the analytical formula for horizontal motion with drag
	double drag_factor = beta * horiz_dist / v0_horiz;

	// Handle edge case where drag would slow projectile too much
	if (drag_factor >= 0.99) {
		target_time = INFINITY;
	} else {
		target_time = -std::log(1.0 - drag_factor) / beta;
	}

	return target_time;
}

Vector3 ProjectilePhysicsWithDrag::calculate_position_at_time(const Vector3 &start_pos, const Vector3 &launch_vector,
	double time, Ref<Resource> shell_params) {

	if (time <= 0.0) {
		return start_pos;
	}
	
	// Validate shell_params before use
	if (!shell_params.is_valid()) {
		UtilityFunctions::push_warning("ProjectilePhysicsWithDrag: Invalid shell_params, using simple ballistic trajectory");
		// Fallback to simple ballistic trajectory without drag
		double g = std::abs(GRAVITY);
		return Vector3(
			start_pos.x + launch_vector.x * time,
			start_pos.y + launch_vector.y * time - 0.5 * g * time * time,
			start_pos.z + launch_vector.z * time
		);
	}
	
	time = time_warp(time, shell_params);

	// Extract components
	double v0x = launch_vector.x;
	double v0y = launch_vector.y;
	double v0z = launch_vector.z;
	
	Variant drag_var = shell_params->get("drag");
	double beta = (drag_var.get_type() != Variant::NIL) ? (double)drag_var : DEFAULT_DRAG_COEFFICIENT;
	
	// Prevent division by zero - use minimum drag value
	if (beta <= 0.0001) {
		beta = 0.0001;
		UtilityFunctions::push_warning("ProjectilePhysicsWithDrag: drag coefficient too small, using minimum value");
	}
	
	double g = std::abs(GRAVITY);

	Vector3 position;

	// For x and z (horizontal components with drag)
	// x = (v₀/β) * (1-e^(-βt))
	double drag_factor = 1.0 - std::exp(-beta * time);
	if (std::isnan(drag_factor)) {
		drag_factor = 0.0;
	}
	position.x = start_pos.x + (v0x / beta) * drag_factor;
	position.z = start_pos.z + (v0z / beta) * drag_factor;

	// For y (vertical component with drag and gravity)
	// y ≈ y₀ + v₀y*(1-e^(-βt))/β - (g/β)t + (g/β²)(1-e^(-βt))
	position.y = start_pos.y + (v0y / beta) * drag_factor - (g / beta) * time + (g / (beta * beta)) * drag_factor;

	return position;
}

Array ProjectilePhysicsWithDrag::calculate_leading_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
	const Vector3 &target_velocity, Ref<Resource> shell_params) {

	Array result;

	// Start with the time it would take to hit the current position (non-drag estimation)
	Array initial_result = ProjectilePhysics::calculate_launch_vector(start_pos, target_pos, shell_params->get("speed"));

	if (initial_result[0].get_type() == Variant::NIL) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		result.push_back(Variant()); // null
		return result; // No solution exists in basic physics
	}

	double time_estimate = initial_result[1];

	// Refine the estimate iteratively
	for (int i = 0; i < 3; i++) { // Just a few iterations for prediction
		// Predict target position after estimated time
		Vector3 predicted_pos = target_pos + target_velocity * time_estimate;

		// Calculate launch vector to hit that position with drag
		Array iter_result = calculate_launch_vector(start_pos, predicted_pos, shell_params);

		if (iter_result[0].get_type() == Variant::NIL) {
			result.push_back(Variant()); // null
			result.push_back(-1.0);
			result.push_back(Variant()); // null
			return result;
		}

		time_estimate = iter_result[1];
	}

	// Final calculation with the best time estimate
	Vector3 final_target_pos = target_pos + target_velocity * time_estimate;
	Array final_result = calculate_launch_vector(start_pos, final_target_pos, shell_params);

	// Return launch vector, time to target, and the final target position
	if (final_result[0].get_type() == Variant::NIL) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		result.push_back(Variant()); // null
	} else {
		result.push_back(final_result[0]);
		result.push_back(final_result[1]);
		result.push_back(final_target_pos);
	}
	return result;
}

double ProjectilePhysicsWithDrag::calculate_max_range_from_angle(double angle, Ref<Resource> shell_params) {
	// Create a launch vector for this angle
	double projectile_speed = shell_params->get("speed");
	double drag_coefficient = shell_params->get("drag");

	Vector3 launch_vector(
		projectile_speed * std::cos(angle),
		projectile_speed * std::sin(angle),
		0
	);

	// Use the same horizontal calculation that's used in other functions for consistency
	double v0x = projectile_speed * std::cos(angle);

	// Use estimate_time_of_flight to find when the projectile would hit the ground
	// First, we need to estimate when y=0 (the projectile returns to ground level)
	// This is an iterative process

	double max_time = 100.0; // Safety limit for flight time
	double time_step = 0.1;
	double current_time = 0.0;
	Vector3 prev_pos = Vector3();
	Vector3 current_pos = Vector3();

	// Find when the projectile hits the ground (y=0) by stepping through time
	while (current_time < max_time) {
		current_pos = calculate_position_at_time(Vector3(), launch_vector, current_time, shell_params);

		// If we've gone below y=0, we can interpolate to find the exact impact point
		if (current_pos.y < 0 && prev_pos.y >= 0) {
			// Linear interpolation to find more precise impact time
			double t_ratio = prev_pos.y / (prev_pos.y - current_pos.y);
			double impact_time = current_time - time_step + (time_step * t_ratio);

			// Calculate final position at impact time
			Vector3 impact_pos = calculate_position_at_time(Vector3(), launch_vector, impact_time, shell_params);

			// Return the horizontal distance traveled (the range)
			return Vector2(impact_pos.x, impact_pos.z).length();
		}

		prev_pos = current_pos;
		current_time += time_step;
	}

	// If we never hit the ground (unlikely but possible with certain drag values)
	// Calculate the asymptotic range
	double asymptotic_range = v0x / drag_coefficient;
	return asymptotic_range;
}

double ProjectilePhysicsWithDrag::calculate_angle_from_max_range(double max_range, Ref<Resource> shell_params) {
	double beta = shell_params->get("drag");
	double projectile_speed = shell_params->get("speed");

	// With drag, we need to search for the angle that gives desired range
	// Binary search through angles to find best match

	// Start with reasonable bounds: 0 to 45 degrees
	// (with drag, maximum range is usually below 45 degrees)
	double min_angle = 0.0;
	double max_angle = Math_PI / 4.0;

	// Find theoretical max range first
	double max_possible_range = 0.0;
	double test_angles[] = { Math_PI / 6.0, Math_PI / 5.0, Math_PI / 4.0, Math_PI / 3.0 };
	for (int i = 0; i < 4; i++) {
		double test_range = calculate_max_range_from_angle(test_angles[i], shell_params);
		if (test_range > max_possible_range) {
			max_possible_range = test_range;
		}
	}

	// Check if requested range is possible
	if (max_range > max_possible_range) {
		return -1; // Impossible range
	}

	// Binary search for angle that gives desired range
	for (int i = 0; i < MAX_ITERATIONS; i++) {
		double test_angle = (min_angle + max_angle) / 2.0;
		double test_range = calculate_max_range_from_angle(test_angle, shell_params);

		double error = test_range - max_range;

		// If close enough, return this angle
		if (std::abs(error) < 0.1) { // 10cm tolerance
			return test_angle;
		}

		// Adjust search bounds
		if (error < 0) {
			min_angle = test_angle; // Range too short, increase angle
		} else {
			max_angle = test_angle; // Range too far, decrease angle
		}
	}

	// Return best approximation after max iterations
	return (min_angle + max_angle) / 2.0;
}
