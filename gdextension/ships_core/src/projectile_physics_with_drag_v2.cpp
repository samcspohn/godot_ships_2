#include "projectile_physics_with_drag_v2.h"
#include "projectile_physics.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>

namespace godot {

void ProjectilePhysicsWithDragV2::_bind_methods() {
	// Bind 2D forward problem methods
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("position", "theta", "t", "shell_params"), &ProjectilePhysicsWithDragV2::position);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("velocity", "theta", "t", "shell_params"), &ProjectilePhysicsWithDragV2::velocity);

	// Bind 2D inverse problem methods
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("firing_solution", "target_x", "target_y", "shell_params", "high_arc"), &ProjectilePhysicsWithDragV2::firing_solution, DEFVAL(false));

	// Bind 2D utility methods
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("time_of_flight", "theta", "shell_params", "target_y"), &ProjectilePhysicsWithDragV2::time_of_flight, DEFVAL(0.0));
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("range_at_angle", "theta", "shell_params"), &ProjectilePhysicsWithDragV2::range_at_angle);

	// Bind static utility
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("acosh", "x"), &ProjectilePhysicsWithDragV2::acosh);

	// Bind 3D API methods (compatible with ProjectilePhysicsWithDrag interface)
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_position_at_time", "start_pos", "launch_vector", "time", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_position_at_time);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_velocity_at_time", "launch_vector", "time", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_velocity_at_time);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_launch_vector", "start_pos", "target_pos", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_launch_vector);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_leading_launch_vector", "start_pos", "target_pos", "target_velocity", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_leading_launch_vector);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_impact_position", "start_pos", "launch_velocity", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_impact_position);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_absolute_max_range", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_absolute_max_range);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_max_range_from_angle", "angle", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_max_range_from_angle);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("calculate_angle_from_max_range", "max_range", "shell_params"), &ProjectilePhysicsWithDragV2::calculate_angle_from_max_range);
}

ProjectilePhysicsWithDragV2::ProjectilePhysicsWithDragV2() {
}

ProjectilePhysicsWithDragV2::~ProjectilePhysicsWithDragV2() {
}

//==============================================================================
// Forward Problem
//==============================================================================

Vector2 ProjectilePhysicsWithDragV2::position(double theta, double t, const Ref<Resource> &shell_params) {
	if (!shell_params.is_valid()) {
		return Vector2(NAN, NAN);
	}

	double v0 = shell_params->get("speed");
	double beta = shell_params->get("drag");
	double vt = shell_params->get("vt");
	double tau = shell_params->get("tau");

	double c = std::cos(theta);
	double s = std::sin(theta);

	double x = _horizontal_position(c, t, v0, beta);
	double y = _vertical_position(s, t, v0, vt, tau);

	return Vector2(x, y);
}

Vector2 ProjectilePhysicsWithDragV2::velocity(double theta, double t, const Ref<Resource> &shell_params) {
	if (!shell_params.is_valid()) {
		return Vector2(NAN, NAN);
	}

	double v0 = shell_params->get("speed");
	double beta = shell_params->get("drag");
	double vt = shell_params->get("vt");
	double tau = shell_params->get("tau");

	double c = std::cos(theta);
	double s = std::sin(theta);

	double vx = _horizontal_velocity(c, t, v0, beta);
	double vy = _vertical_velocity(s, t, v0, vt, tau);

	return Vector2(vx, vy);
}

double ProjectilePhysicsWithDragV2::_horizontal_position(double cos_theta, double t, double v0, double beta) {
	double vx0 = v0 * cos_theta;
	double sqrt_c = std::sqrt(cos_theta);
	double beta_eff = beta / sqrt_c;

	return std::log(1.0 + beta_eff * vx0 * t) / beta_eff;
}

double ProjectilePhysicsWithDragV2::_horizontal_velocity(double cos_theta, double t, double v0, double beta) {
	double vx0 = v0 * cos_theta;
	double sqrt_c = std::sqrt(cos_theta);
	double beta_eff = beta / sqrt_c;

	return vx0 / (1.0 + beta_eff * vx0 * t);
}

double ProjectilePhysicsWithDragV2::_vertical_position(double sin_theta, double t, double v0, double vt, double tau) {
	double vy0 = v0 * sin_theta;

	if (vy0 >= 0.0) {
		// Upward or horizontal: tan/atan formulation
		double phi0 = std::atan(vy0 / vt);
		double t_apex = tau * phi0;

		if (t <= t_apex) {
			double phi = phi0 - t / tau;
			return tau * vt * std::log(std::cos(phi) / std::cos(phi0));
		} else {
			double y_apex = tau * vt * std::log(1.0 / std::cos(phi0));
			double dt = t - t_apex;
			return y_apex - tau * vt * std::log(std::cosh(dt / tau));
		}
	} else {
		// Downward: tanh/atanh formulation
		double ratio = vy0 / vt;  // Negative, |ratio| < 1 for subsonic

		if (ratio > -1.0) {
			double psi0 = std::atanh(ratio);
			double psi = psi0 - t / tau;
			return tau * vt * std::log(std::cosh(psi0) / std::cosh(psi));
		} else {
			// Supersonic downward - quickly approaches terminal velocity
			double v_avg = (vy0 - vt) * 0.5;
			return v_avg * t;
		}
	}
}

double ProjectilePhysicsWithDragV2::_vertical_velocity(double sin_theta, double t, double v0, double vt, double tau) {
	double vy0 = v0 * sin_theta;

	if (vy0 >= 0.0) {
		double phi0 = std::atan(vy0 / vt);
		double t_apex = tau * phi0;

		if (t <= t_apex) {
			return vt * std::tan(phi0 - t / tau);
		} else {
			double dt = t - t_apex;
			return -vt * std::tanh(dt / tau);
		}
	} else {
		double ratio = vy0 / vt;

		if (ratio > -1.0) {
			double psi0 = std::atanh(ratio);
			return vt * std::tanh(psi0 - t / tau);
		} else {
			return -vt;
		}
	}
}

//==============================================================================
// Inverse Problem
//==============================================================================

Vector2 ProjectilePhysicsWithDragV2::firing_solution(double target_x, double target_y, const Ref<Resource> &shell_params, bool high_arc) {
	if (!shell_params.is_valid()) {
		return Vector2(NAN, NAN);
	}

	if (target_x <= 0.0) {
		return Vector2(NAN, NAN);
	}

	double v0 = shell_params->get("speed");
	double beta = shell_params->get("drag");
	double vt = shell_params->get("vt");
	double tau = shell_params->get("tau");

	double theta = _vacuum_angle(target_x, target_y, v0, high_arc);
	if (std::isnan(theta)) {
		return Vector2(NAN, NAN);
	}

	theta = _newton_refine_angle(theta, target_x, target_y, 4, v0, beta, vt, tau);

	double t = _time_from_x(target_x, theta, v0, beta);
	return Vector2(theta, t);
}

double ProjectilePhysicsWithDragV2::_vacuum_angle(double x, double y, double v0, bool high_arc) {
	double v0sq = v0 * v0;
	double A = GRAVITY * x * x / (2.0 * v0sq);
	double disc = x * x - 4.0 * A * (A + y);

	if (disc < 0.0) {
		return NAN;
	}

	double sqrt_disc = std::sqrt(disc);
	double tan_theta;

	if (high_arc) {
		tan_theta = (x + sqrt_disc) / (2.0 * A);
	} else {
		tan_theta = (x - sqrt_disc) / (2.0 * A);
	}

	return std::atan(tan_theta);
}

double ProjectilePhysicsWithDragV2::_time_from_x(double x, double theta, double v0, double beta) {
	double c = std::cos(theta);
	double sqrt_c = std::sqrt(c);
	double vx0 = v0 * c;
	double beta_eff = beta / sqrt_c;

	return (std::exp(beta_eff * x) - 1.0) / (beta_eff * vx0);
}

// double ProjectilePhysicsWithDragV2::_analytical_angle(double x, double y, double v0, double beta, bool high_arc) {
// 	double v0sq = v0 * v0;

// 	// Vacuum solution: y = x·tan(θ) - g·x²·sec²(θ)/(2v0²)
// 	// Quadratic in tan(θ): A·tan² - x·tan + (A + y) = 0
// 	double A = GRAVITY * x * x / (2.0 * v0sq);
// 	double disc = x * x - 4.0 * A * (A + y);

// 	if (disc < 0.0) {
// 		return NAN;
// 	}

// 	double sqrt_disc = std::sqrt(disc);
// 	double tan_theta;

// 	if (high_arc) {
// 		tan_theta = (x + sqrt_disc) / (2.0 * A);
// 	} else {
// 		tan_theta = (x - sqrt_disc) / (2.0 * A);
// 	}

// 	double theta0 = std::atan(tan_theta);

// 	// Drag correction via perturbation expansion
// 	double c0 = std::cos(theta0);
// 	double s0 = std::sin(theta0);
// 	double sqrt_c0 = std::sqrt(c0);
// 	double t0 = x / (v0 * c0);
// 	double vx0 = v0 * c0;
// 	double eps = beta * vx0 * t0 / sqrt_c0;

// 	double sec0_sq = 1.0 / (c0 * c0);
// 	double tan0_sq = s0 * s0 / (c0 * c0);

// 	double C1 = 0.5 * sec0_sq * (1.0 + tan0_sq / 3.0) * sqrt_c0;
// 	double C2 = sec0_sq * sec0_sq * (0.2 + tan0_sq / 4.0) * c0;

// 	double delta_theta = eps * (C1 + eps * C2);
// 	double theta = theta0 + delta_theta;

// 	const double PI = 3.14159265358979323846;
// 	return Math::clamp(theta, -PI / 2.0 + 0.001, PI / 2.0 - 0.001);
// }

double ProjectilePhysicsWithDragV2::_newton_refine_angle(double theta, double target_x, double target_y, int max_iter, double v0, double beta, double vt, double tau) {
	const double PI = 3.14159265358979323846;

	for (int i = 0; i < max_iter; i++) {
		double c = std::cos(theta);
		double s = std::sin(theta);

		double t = _time_from_x(target_x, theta, v0, beta);
		double y = _vertical_position(s, t, v0, vt, tau);
		double error = y - target_y;

		if (std::abs(error) < 1e-6) {
			break;
		}

		double dy_dtheta = _total_deriv_y_theta(theta, target_x, t, v0, beta, vt, tau);

		if (std::abs(dy_dtheta) < 1e-10) {
			break;
		}

		theta -= error / dy_dtheta;
		theta = Math::clamp(theta, -PI / 2.0 + 0.001, PI / 2.0 - 0.001);
	}

	return theta;
}

double ProjectilePhysicsWithDragV2::_total_deriv_y_theta(double theta, double x, double t, double v0, double beta, double vt, double tau) {
	double c = std::cos(theta);
	double s = std::sin(theta);

	double dt_dtheta = _time_deriv_theta(x, theta, t, v0, beta);
	double dy_ds = _vertical_position_deriv_s(s, t, v0, vt, tau);
	double dy_dt = _vertical_velocity(s, t, v0, vt, tau);

	// dy/dθ = ∂y/∂s · cos(θ) + ∂y/∂t · dt/dθ
	return dy_ds * c + dy_dt * dt_dtheta;
}

double ProjectilePhysicsWithDragV2::_time_deriv_theta(double x, double theta, double t, double v0, double beta) {
	double c = std::cos(theta);
	double s = std::sin(theta);
	double sqrt_c = std::sqrt(c);
	double beta_eff = beta / sqrt_c;
	double vx0 = v0 * c;

	double u = beta_eff * x;
	double exp_u = std::exp(u);
	double w = beta_eff * vx0;

	// du/dθ = β·x·tan(θ) / (2c)
	double du_dtheta = beta * x * s / (2.0 * c * sqrt_c);

	// dw/dθ = -β·v0·tan(θ) / (2√c)
	double dw_dtheta = -beta * v0 * s / (2.0 * sqrt_c);

	return (exp_u * du_dtheta * w - (exp_u - 1.0) * dw_dtheta) / (w * w);
}

double ProjectilePhysicsWithDragV2::_vertical_position_deriv_s(double sin_theta, double t, double v0, double vt, double tau) {
	double vy0 = v0 * sin_theta;

	if (vy0 >= 0.0) {
		double phi0 = std::atan(vy0 / vt);
		double t_apex = tau * phi0;
		double dphi0_ds = v0 * vt / (vt * vt + vy0 * vy0);

		if (t <= t_apex) {
			double phi = phi0 - t / tau;
			return tau * vt * dphi0_ds * (std::tan(phi0) - std::tan(phi));
		} else {
			double dt = t - t_apex;
			double dy_apex_ds = tau * vt * std::tan(phi0) * dphi0_ds;
			double dcosh_term_ds = std::tanh(dt / tau) * (-dphi0_ds);
			return dy_apex_ds - tau * vt * dcosh_term_ds;
		}
	} else {
		double ratio = vy0 / vt;
		if (ratio > -1.0) {
			double psi0 = std::atanh(ratio);
			double dpsi0_ds = v0 / vt / (1.0 - ratio * ratio);
			double psi = psi0 - t / tau;
			return tau * vt * dpsi0_ds * (std::tanh(psi0) - std::tanh(psi));
		} else {
			return t * 0.5;
		}
	}
}

//==============================================================================
// Utility Functions
//==============================================================================

double ProjectilePhysicsWithDragV2::time_of_flight(double theta, const Ref<Resource> &shell_params, double target_y) {
	if (!shell_params.is_valid()) {
		return NAN;
	}

	double v0 = shell_params->get("speed");
	double vt = shell_params->get("vt");
	double tau = shell_params->get("tau");

	double s = std::sin(theta);
	double vy0 = v0 * s;

	if (vy0 >= 0.0) {
		double phi0 = std::atan(vy0 / vt);
		double t_apex = tau * phi0;
		double y_apex = tau * vt * std::log(1.0 / std::cos(phi0));

		if (target_y >= y_apex) {
			double cos_phi = std::cos(phi0) * std::exp(target_y / (tau * vt));
			if (cos_phi > 1.0) {
				return NAN;
			}
			return tau * (phi0 - std::acos(cos_phi));
		}

		double arg = std::exp((y_apex - target_y) / (tau * vt));
		return t_apex + tau * acosh(arg);
	} else {
		if (target_y > 0.0) {
			return NAN;
		}

		double ratio = vy0 / vt;
		if (ratio > -1.0) {
			double psi0 = std::atanh(ratio);
			double arg = std::cosh(psi0) * std::exp(-target_y / (tau * vt));
			return tau * (psi0 + acosh(arg));
		} else {
			return -target_y / vt;
		}
	}
}

double ProjectilePhysicsWithDragV2::range_at_angle(double theta, const Ref<Resource> &shell_params) {
	double t = time_of_flight(theta, shell_params, 0.0);
	if (std::isnan(t)) {
		return NAN;
	}
	return position(theta, t, shell_params).x;
}

double ProjectilePhysicsWithDragV2::acosh(double x) {
	return std::log(x + std::sqrt(x * x - 1.0));
}

//==============================================================================
// 3D API Implementation
//==============================================================================

bool ProjectilePhysicsWithDragV2::_extract_params(const Ref<Resource> &shell_params, double &v0, double &beta, double &vt, double &tau) {
	if (!shell_params.is_valid()) {
		return false;
	}
	v0 = shell_params->get("speed");
	beta = shell_params->get("drag");
	vt = shell_params->get("vt");
	tau = shell_params->get("tau");
	return true;
}

Vector3 ProjectilePhysicsWithDragV2::calculate_position_at_time(const Vector3 &start_pos, const Vector3 &launch_vector,
	double time, const Ref<Resource> &shell_params) {

	if (time <= 0.0) {
		return start_pos;
	}

	double v0, beta, vt, tau;
	if (!_extract_params(shell_params, v0, beta, vt, tau)) {
		// Fallback to simple ballistic trajectory without drag
		return Vector3(
			start_pos.x + launch_vector.x * time,
			start_pos.y + launch_vector.y * time - 0.5 * GRAVITY * time * time,
			start_pos.z + launch_vector.z * time
		);
	}

	// Get horizontal distance and direction
	double vx = launch_vector.x;
	double vz = launch_vector.z;
	double vy0 = launch_vector.y;
	double v_horiz = std::sqrt(vx * vx + vz * vz);

	if (v_horiz < 1e-10) {
		// Purely vertical shot
		double sin_theta = (vy0 >= 0) ? 1.0 : -1.0;
		double y_offset = _vertical_position(sin_theta, time, std::abs(vy0), vt, tau);
		return Vector3(start_pos.x, start_pos.y + y_offset, start_pos.z);
	}

	// Calculate theta (elevation angle)
	double speed = std::sqrt(vx * vx + vy0 * vy0 + vz * vz);
	double cos_theta = v_horiz / speed;
	double sin_theta = vy0 / speed;

	// Calculate horizontal and vertical positions using analytical formulas
	double x_dist = _horizontal_position(cos_theta, time, speed, beta);
	double y_offset = _vertical_position(sin_theta, time, speed, vt, tau);

	// Convert back to 3D - distribute horizontal distance along original direction
	double horiz_scale = x_dist / v_horiz;
	return Vector3(
		start_pos.x + vx * horiz_scale,
		start_pos.y + y_offset,
		start_pos.z + vz * horiz_scale
	);
}

Vector3 ProjectilePhysicsWithDragV2::calculate_velocity_at_time(const Vector3 &launch_vector, double time,
	const Ref<Resource> &shell_params) {

	double v0, beta, vt, tau;
	if (!_extract_params(shell_params, v0, beta, vt, tau)) {
		// Fallback to simple ballistic velocity
		return Vector3(
			launch_vector.x,
			launch_vector.y - GRAVITY * time,
			launch_vector.z
		);
	}

	double vx = launch_vector.x;
	double vz = launch_vector.z;
	double vy0 = launch_vector.y;
	double v_horiz = std::sqrt(vx * vx + vz * vz);

	if (v_horiz < 1e-10) {
		// Purely vertical shot
		double sin_theta = (vy0 >= 0) ? 1.0 : -1.0;
		double vy = _vertical_velocity(sin_theta, time, std::abs(vy0), vt, tau);
		return Vector3(0, vy, 0);
	}

	// Calculate theta (elevation angle)
	double speed = std::sqrt(vx * vx + vy0 * vy0 + vz * vz);
	double cos_theta = v_horiz / speed;
	double sin_theta = vy0 / speed;

	// Calculate velocities using analytical formulas
	double v_horiz_new = _horizontal_velocity(cos_theta, time, speed, beta);
	double vy_new = _vertical_velocity(sin_theta, time, speed, vt, tau);

	// Scale horizontal components
	double horiz_scale = v_horiz_new / v_horiz;
	return Vector3(
		vx * horiz_scale,
		vy_new,
		vz * horiz_scale
	);
}

Array ProjectilePhysicsWithDragV2::calculate_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
	const Ref<Resource> &shell_params) {

	Array result;

	double v0, beta, vt, tau;
	if (!_extract_params(shell_params, v0, beta, vt, tau)) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result;
	}

	// Calculate displacement
	Vector3 disp = target_pos - start_pos;
	double horiz_dist = std::sqrt(disp.x * disp.x + disp.z * disp.z);
	double vert_dist = disp.y;

	if (horiz_dist < 1e-6) {
		// Target is directly above/below - can't solve with this method
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result;
	}

	// Get firing solution using 2D analytical solver
	Vector2 solution = firing_solution(horiz_dist, vert_dist, shell_params, false);

	if (std::isnan(solution.x)) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		return result;
	}

	double theta = solution.x;
	double flight_time = solution.y;

	// Convert 2D solution to 3D launch vector
	double cos_theta = std::cos(theta);
	double sin_theta = std::sin(theta);

	// Horizontal direction
	double horiz_dir_x = disp.x / horiz_dist;
	double horiz_dir_z = disp.z / horiz_dist;

	Vector3 launch_vector(
		v0 * cos_theta * horiz_dir_x,
		v0 * sin_theta,
		v0 * cos_theta * horiz_dir_z
	);

	result.push_back(launch_vector);
	result.push_back(flight_time);
	return result;
}

Array ProjectilePhysicsWithDragV2::calculate_leading_launch_vector(const Vector3 &start_pos, const Vector3 &target_pos,
	const Vector3 &target_velocity, const Ref<Resource> &shell_params) {

	Array result;

	double v0, beta, vt, tau;
	if (!_extract_params(shell_params, v0, beta, vt, tau)) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		result.push_back(Variant()); // null
		return result;
	}

	// Start with the time it would take to hit the current position (non-drag estimation)
	// This gives us a good initial estimate for fast convergence
	Array initial_result = ProjectilePhysics::calculate_launch_vector(start_pos, target_pos, v0);

	if (initial_result[0].get_type() == Variant::NIL) {
		result.push_back(Variant()); // null
		result.push_back(-1.0);
		result.push_back(Variant()); // null
		return result; // No solution exists in basic physics
	}

	double time_estimate = initial_result[1];

	// Refine the estimate iteratively - only 3 iterations needed with good initial estimate
	for (int i = 0; i < 3; i++) {
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

Vector3 ProjectilePhysicsWithDragV2::calculate_impact_position(const Vector3 &start_pos, const Vector3 &launch_velocity,
	const Ref<Resource> &shell_params) {

	double v0, beta, vt, tau;
	if (!_extract_params(shell_params, v0, beta, vt, tau)) {
		// Fallback: simple ballistic calculation
		double vy0 = launch_velocity.y;
		double disc = vy0 * vy0 + 2.0 * GRAVITY * start_pos.y;
		if (disc < 0) {
			return start_pos;
		}
		double t = (vy0 + std::sqrt(disc)) / GRAVITY;
		return Vector3(
			start_pos.x + launch_velocity.x * t,
			0.0,
			start_pos.z + launch_velocity.z * t
		);
	}

	// Calculate theta from launch velocity
	double vx = launch_velocity.x;
	double vz = launch_velocity.z;
	double vy0 = launch_velocity.y;
	double v_horiz = std::sqrt(vx * vx + vz * vz);
	double speed = std::sqrt(vx * vx + vy0 * vy0 + vz * vz);

	if (v_horiz < 1e-10 || speed < 1e-10) {
		return start_pos;
	}

	double theta = std::atan2(vy0, v_horiz);

	// Use time_of_flight to find when y = -start_pos.y (relative to start)
	double target_y = -start_pos.y;
	double t = time_of_flight(theta, shell_params, target_y);

	if (std::isnan(t) || t < 0) {
		return start_pos;
	}

	// Calculate position at impact time
	return calculate_position_at_time(start_pos, launch_velocity, t, shell_params);
}

Array ProjectilePhysicsWithDragV2::calculate_absolute_max_range(const Ref<Resource> &shell_params) {
	Array result;

	double v0, beta, vt, tau;
	if (!_extract_params(shell_params, v0, beta, vt, tau)) {
		result.push_back(0.0);
		result.push_back(0.0);
		result.push_back(0.0);
		return result;
	}

	// Binary search for optimal angle
	double min_angle = 0.0;
	double max_angle = Math_PI / 2.0 - 0.01;
	double best_range = 0.0;
	double best_angle = 0.0;
	double best_time = 0.0;

	for (int i = 0; i < MAX_ITERATIONS; i++) {
		double mid1 = min_angle + (max_angle - min_angle) / 3.0;
		double mid2 = max_angle - (max_angle - min_angle) / 3.0;

		double range1 = range_at_angle(mid1, shell_params);
		double range2 = range_at_angle(mid2, shell_params);

		if (std::isnan(range1)) range1 = 0.0;
		if (std::isnan(range2)) range2 = 0.0;

		if (range1 < range2) {
			min_angle = mid1;
			if (range2 > best_range) {
				best_range = range2;
				best_angle = mid2;
			}
		} else {
			max_angle = mid2;
			if (range1 > best_range) {
				best_range = range1;
				best_angle = mid1;
			}
		}
	}

	best_time = time_of_flight(best_angle, shell_params, 0.0);

	result.push_back(best_range);
	result.push_back(best_angle);
	result.push_back(best_time);
	return result;
}

double ProjectilePhysicsWithDragV2::calculate_max_range_from_angle(double angle, const Ref<Resource> &shell_params) {
	return range_at_angle(angle, shell_params);
}

double ProjectilePhysicsWithDragV2::calculate_angle_from_max_range(double max_range, const Ref<Resource> &shell_params) {
	double v0, beta, vt, tau;
	if (!_extract_params(shell_params, v0, beta, vt, tau)) {
		return 0.0;
	}

	// Binary search to find angle that gives desired range
	double min_angle = 0.0;
	double max_angle = Math_PI / 4.0; // With drag, max range is usually below 45 degrees

	// First check if the range is achievable
	Array max_range_result = calculate_absolute_max_range(shell_params);
	double absolute_max = max_range_result[0];
	if (max_range > absolute_max) {
		return max_range_result[1]; // Return optimal angle if requested range exceeds max
	}

	for (int i = 0; i < MAX_ITERATIONS; i++) {
		double mid_angle = (min_angle + max_angle) / 2.0;
		double test_range = range_at_angle(mid_angle, shell_params);

		if (std::isnan(test_range)) {
			max_angle = mid_angle;
			continue;
		}

		double error = test_range - max_range;

		if (std::abs(error) < 0.1) { // Within 10cm
			return mid_angle;
		}

		if (error < 0) {
			min_angle = mid_angle;
		} else {
			max_angle = mid_angle;
		}
	}

	return (min_angle + max_angle) / 2.0;
}

} // namespace godot
