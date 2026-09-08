use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::Resource;

use super::{ProjectilePhysicsWithDragV2 as P, GRAVITY};

impl P {
    /// Position at time t for launch angle theta. x is horizontal distance, y vertical.
    pub(crate) fn position(theta: f64, t: f64, shell_params: &Gd<Resource>) -> Vector2 {
        // `Gd<Resource>` cannot be null the way `Ref<>` can in C++, so the
        // `shell_params.is_valid()` check in the source always takes the
        // "valid" branch here.
        let v0: f64 = shell_params.get("speed").to_f64();
        let beta: f64 = shell_params.get("drag").to_f64();
        let vt: f64 = shell_params.get("vt").to_f64();
        let tau: f64 = shell_params.get("tau").to_f64();

        let c = theta.cos();
        let s = theta.sin();

        let x = Self::horizontal_position(c, t, v0, beta);
        let y = Self::vertical_position(s, t, v0, vt, tau);

        Vector2::new(x as f32, y as f32)
    }

    /// Firing solution to hit (target_x, target_y). Returns Vector2(theta, time),
    /// or Vector2(NAN, NAN) if no solution exists.
    pub(crate) fn firing_solution(
        target_x: f64,
        target_y: f64,
        shell_params: &Gd<Resource>,
        high_arc: bool,
    ) -> Vector2 {
        // See `position()`: the `shell_params.is_valid()` branch is dead here.
        if target_x <= 0.0 {
            return Vector2::new(f32::NAN, f32::NAN);
        }

        let v0: f64 = shell_params.get("speed").to_f64();
        let beta: f64 = shell_params.get("drag").to_f64();
        let vt: f64 = shell_params.get("vt").to_f64();
        let tau: f64 = shell_params.get("tau").to_f64();

        let theta = Self::vacuum_angle(target_x, target_y, v0, high_arc);
        if theta.is_nan() {
            return Vector2::new(f32::NAN, f32::NAN);
        }

        let theta = Self::newton_refine_angle(theta, target_x, target_y, 4, v0, beta, vt, tau);

        let t = Self::time_from_x(target_x, theta, v0, beta);
        Vector2::new(theta as f32, t as f32)
    }

    /// Time of flight for `theta` to reach `target_y`, or NAN if unreachable.
    pub(crate) fn time_of_flight_impl(theta: f64, shell_params: &Gd<Resource>, target_y: f64) -> f64 {
        // See `position()`: the `shell_params.is_valid()` branch is dead here.
        let v0: f64 = shell_params.get("speed").to_f64();
        let vt: f64 = shell_params.get("vt").to_f64();
        let tau: f64 = shell_params.get("tau").to_f64();

        let s = theta.sin();
        let vy0 = v0 * s;

        if vy0 >= 0.0 {
            let phi0 = (vy0 / vt).atan();
            let t_apex = tau * phi0;
            let y_apex = tau * vt * (1.0 / phi0.cos()).ln();

            if target_y >= y_apex {
                let cos_phi = phi0.cos() * (target_y / (tau * vt)).exp();
                if cos_phi > 1.0 {
                    return f64::NAN;
                }
                return tau * (phi0 - cos_phi.acos());
            }

            let arg = ((y_apex - target_y) / (tau * vt)).exp();
            t_apex + tau * Self::acosh(arg)
        } else {
            if target_y > 0.0 {
                return f64::NAN;
            }

            let ratio = vy0 / vt;
            if ratio > -1.0 {
                let psi0 = ratio.atanh();
                let arg = psi0.cosh() * (-target_y / (tau * vt)).exp();
                tau * (psi0 + Self::acosh(arg))
            } else {
                -target_y / vt
            }
        }
    }

    /// Horizontal range at `theta` (to y = 0), or NAN if no valid solution.
    pub(crate) fn range_at_angle(theta: f64, shell_params: &Gd<Resource>) -> f64 {
        let t = Self::time_of_flight_impl(theta, shell_params, 0.0);
        if t.is_nan() {
            return f64::NAN;
        }
        Self::position(theta, t, shell_params).x as f64
    }

    /// C++ defines its own `acosh` rather than using libm's; port that one
    /// exactly and use it everywhere the C++ calls it.
    pub(crate) fn acosh(x: f64) -> f64 {
        (x + (x * x - 1.0).sqrt()).ln()
    }

    // --- Internal 2D analytical helpers ---

    pub(crate) fn horizontal_position(cos_theta: f64, t: f64, v0: f64, beta: f64) -> f64 {
        let vx0 = v0 * cos_theta;
        let sqrt_c = cos_theta.sqrt();
        let beta_eff = beta / sqrt_c;

        (1.0 + beta_eff * vx0 * t).ln() / beta_eff
    }

    pub(crate) fn horizontal_velocity(cos_theta: f64, t: f64, v0: f64, beta: f64) -> f64 {
        let vx0 = v0 * cos_theta;
        let sqrt_c = cos_theta.sqrt();
        let beta_eff = beta / sqrt_c;

        vx0 / (1.0 + beta_eff * vx0 * t)
    }

    pub(crate) fn vertical_position(sin_theta: f64, t: f64, v0: f64, vt: f64, tau: f64) -> f64 {
        let vy0 = v0 * sin_theta;

        if vy0 >= 0.0 {
            // Upward or horizontal: tan/atan formulation
            let phi0 = (vy0 / vt).atan();
            let t_apex = tau * phi0;

            if t <= t_apex {
                let phi = phi0 - t / tau;
                tau * vt * (phi.cos() / phi0.cos()).ln()
            } else {
                let y_apex = tau * vt * (1.0 / phi0.cos()).ln();
                let dt = t - t_apex;
                y_apex - tau * vt * (dt / tau).cosh().ln()
            }
        } else {
            // Downward: tanh/atanh formulation
            let ratio = vy0 / vt; // Negative, |ratio| < 1 for subsonic

            if ratio > -1.0 {
                let psi0 = ratio.atanh();
                let psi = psi0 - t / tau;
                tau * vt * (psi0.cosh() / psi.cosh()).ln()
            } else {
                // Supersonic downward - quickly approaches terminal velocity
                let v_avg = (vy0 - vt) * 0.5;
                v_avg * t
            }
        }
    }

    pub(crate) fn vertical_velocity(sin_theta: f64, t: f64, v0: f64, vt: f64, tau: f64) -> f64 {
        let vy0 = v0 * sin_theta;

        if vy0 >= 0.0 {
            let phi0 = (vy0 / vt).atan();
            let t_apex = tau * phi0;

            if t <= t_apex {
                vt * (phi0 - t / tau).tan()
            } else {
                let dt = t - t_apex;
                -vt * (dt / tau).tanh()
            }
        } else {
            let ratio = vy0 / vt;

            if ratio > -1.0 {
                let psi0 = ratio.atanh();
                vt * (psi0 - t / tau).tanh()
            } else {
                -vt
            }
        }
    }

    pub(crate) fn time_from_x(x: f64, theta: f64, v0: f64, beta: f64) -> f64 {
        let c = theta.cos();
        let sqrt_c = c.sqrt();
        let vx0 = v0 * c;
        let beta_eff = beta / sqrt_c;

        ((beta_eff * x).exp() - 1.0) / (beta_eff * vx0)
    }

    pub(crate) fn vacuum_angle(x: f64, y: f64, v0: f64, high_arc: bool) -> f64 {
        let v0sq = v0 * v0;
        let a = GRAVITY * x * x / (2.0 * v0sq);
        let disc = x * x - 4.0 * a * (a + y);

        if disc < 0.0 {
            return f64::NAN;
        }

        let sqrt_disc = disc.sqrt();
        let tan_theta = if high_arc {
            (x + sqrt_disc) / (2.0 * a)
        } else {
            (x - sqrt_disc) / (2.0 * a)
        };

        tan_theta.atan()
    }

    pub(crate) fn newton_refine_angle(
        theta: f64,
        target_x: f64,
        target_y: f64,
        max_iter: i32,
        v0: f64,
        beta: f64,
        vt: f64,
        tau: f64,
    ) -> f64 {
        const PI: f64 = 3.14159265358979323846;
        let mut theta = theta;

        for i in 0..max_iter {
            let s = theta.sin();

            let t = Self::time_from_x(target_x, theta, v0, beta);
            let y = Self::vertical_position(s, t, v0, vt, tau);
            let error = y - target_y;

            if error.abs() < 1e-6 {
                if i > 3 {
                    godot_print!("Converged in {} iterations with error: {}", i, error);
                }
                break;
            }

            let dy_dtheta = Self::total_deriv_y_theta(theta, target_x, t, v0, beta, vt, tau);

            if dy_dtheta.abs() < 1e-10 {
                break;
            }

            theta -= error / dy_dtheta;
            theta = theta.clamp(-PI / 2.0 + 0.001, PI / 2.0 - 0.001);
        }

        theta
    }

    pub(crate) fn total_deriv_y_theta(
        theta: f64, x: f64, t: f64, v0: f64, beta: f64, vt: f64, tau: f64,
    ) -> f64 {
        let c = theta.cos();
        let s = theta.sin();

        let dt_dtheta = Self::time_deriv_theta(x, theta, t, v0, beta);
        let dy_ds = Self::vertical_position_deriv_s(s, t, v0, vt, tau);
        let dy_dt = Self::vertical_velocity(s, t, v0, vt, tau);

        // dy/dθ = ∂y/∂s · cos(θ) + ∂y/∂t · dt/dθ
        dy_ds * c + dy_dt * dt_dtheta
    }

    pub(crate) fn time_deriv_theta(x: f64, theta: f64, _t: f64, v0: f64, beta: f64) -> f64 {
        let c = theta.cos();
        let s = theta.sin();
        let sqrt_c = c.sqrt();
        let beta_eff = beta / sqrt_c;
        let vx0 = v0 * c;

        let u = beta_eff * x;
        let exp_u = u.exp();
        let w = beta_eff * vx0;

        // du/dθ = β·x·tan(θ) / (2c)
        let du_dtheta = beta * x * s / (2.0 * c * sqrt_c);

        // dw/dθ = -β·v0·tan(θ) / (2√c)
        let dw_dtheta = -beta * v0 * s / (2.0 * sqrt_c);

        (exp_u * du_dtheta * w - (exp_u - 1.0) * dw_dtheta) / (w * w)
    }

    pub(crate) fn vertical_position_deriv_s(
        sin_theta: f64, t: f64, v0: f64, vt: f64, tau: f64,
    ) -> f64 {
        let vy0 = v0 * sin_theta;

        if vy0 >= 0.0 {
            let phi0 = (vy0 / vt).atan();
            let t_apex = tau * phi0;
            let dphi0_ds = v0 * vt / (vt * vt + vy0 * vy0);

            if t <= t_apex {
                let phi = phi0 - t / tau;
                tau * vt * dphi0_ds * (phi0.tan() - phi.tan())
            } else {
                let dt = t - t_apex;
                let dy_apex_ds = tau * vt * phi0.tan() * dphi0_ds;
                let dcosh_term_ds = (dt / tau).tanh() * (-dphi0_ds);
                dy_apex_ds - tau * vt * dcosh_term_ds
            }
        } else {
            let ratio = vy0 / vt;
            if ratio > -1.0 {
                let psi0 = ratio.atanh();
                let dpsi0_ds = v0 / vt / (1.0 - ratio * ratio);
                let psi = psi0 - t / tau;
                tau * vt * dpsi0_ds * (psi0.tanh() - psi.tanh())
            } else {
                t * 0.5
            }
        }
    }

    /// Extract (v0, beta, vt, tau) from the ShellParams resource.
    /// C++ returns false only when `!shell_params.is_valid()`. `Gd<Resource>`
    /// cannot be null the way `Ref<>` can in C++, so that branch is dead here
    /// and this always returns Some. Property names are read verbatim from
    /// `_extract_params`. Note: a ShellParams loaded straight from a .tres has
    /// vt/tau == 0.0 until `_update_derived_values()` runs; the C++ performs no
    /// extra validation for that case, so neither does this.
    pub(crate) fn extract_params(shell_params: &Gd<Resource>) -> Option<(f64, f64, f64, f64)> {
        let v0: f64 = shell_params.get("speed").to_f64();
        let beta: f64 = shell_params.get("drag").to_f64();
        let vt: f64 = shell_params.get("vt").to_f64();
        let tau: f64 = shell_params.get("tau").to_f64();
        Some((v0, beta, vt, tau))
    }
}
