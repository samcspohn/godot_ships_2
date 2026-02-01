#include "projectile_physics_with_drag_v2.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>

namespace godot {

void ProjectilePhysicsWithDragV2::_bind_methods() {
	// Bind forward problem methods
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("position", "theta", "t", "shell_params"), &ProjectilePhysicsWithDragV2::position);
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("velocity", "theta", "t", "shell_params"), &ProjectilePhysicsWithDragV2::velocity);

	// Bind inverse problem methods
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("firing_solution", "target_x", "target_y", "shell_params", "high_arc", "refine"), &ProjectilePhysicsWithDragV2::firing_solution, DEFVAL(false), DEFVAL(true));

	// Bind utility methods
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("time_of_flight", "theta", "shell_params", "target_y"), &ProjectilePhysicsWithDragV2::time_of_flight, DEFVAL(0.0));
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("range_at_angle", "theta", "shell_params"), &ProjectilePhysicsWithDragV2::range_at_angle);

	// Bind static utility
	ClassDB::bind_static_method("ProjectilePhysicsWithDragV2", D_METHOD("acosh", "x"), &ProjectilePhysicsWithDragV2::acosh);
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

Vector2 ProjectilePhysicsWithDragV2::firing_solution(double target_x, double target_y, const Ref<Resource> &shell_params, bool high_arc, bool refine) {
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

	double theta = _analytical_angle(target_x, target_y, v0, beta, high_arc);
	if (std::isnan(theta)) {
		return Vector2(NAN, NAN);
	}

	if (refine) {
		theta = _newton_refine_angle(theta, target_x, target_y, 6, v0, beta, vt, tau);
	}

	double t = _time_from_x(target_x, theta, v0, beta);
	return Vector2(theta, t);
}

double ProjectilePhysicsWithDragV2::_time_from_x(double x, double theta, double v0, double beta) {
	double c = std::cos(theta);
	double sqrt_c = std::sqrt(c);
	double vx0 = v0 * c;
	double beta_eff = beta / sqrt_c;

	return (std::exp(beta_eff * x) - 1.0) / (beta_eff * vx0);
}

double ProjectilePhysicsWithDragV2::_analytical_angle(double x, double y, double v0, double beta, bool high_arc) {
	double v0sq = v0 * v0;

	// Vacuum solution: y = x·tan(θ) - g·x²·sec²(θ)/(2v0²)
	// Quadratic in tan(θ): A·tan² - x·tan + (A + y) = 0
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

	double theta0 = std::atan(tan_theta);

	// Drag correction via perturbation expansion
	double c0 = std::cos(theta0);
	double s0 = std::sin(theta0);
	double sqrt_c0 = std::sqrt(c0);
	double t0 = x / (v0 * c0);
	double vx0 = v0 * c0;
	double eps = beta * vx0 * t0 / sqrt_c0;

	double sec0_sq = 1.0 / (c0 * c0);
	double tan0_sq = s0 * s0 / (c0 * c0);

	double C1 = 0.5 * sec0_sq * (1.0 + tan0_sq / 3.0) * sqrt_c0;
	double C2 = sec0_sq * sec0_sq * (0.2 + tan0_sq / 4.0) * c0;

	double delta_theta = eps * (C1 + eps * C2);
	double theta = theta0 + delta_theta;

	const double PI = 3.14159265358979323846;
	return Math::clamp(theta, -PI / 2.0 + 0.001, PI / 2.0 - 0.001);
}

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

} // namespace godot