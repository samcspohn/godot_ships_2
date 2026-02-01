import matplotlib.pyplot as plt
import numpy as np


class BallisticsTest:
    """Test harness comparing analytical approximations to numerical integration."""

    def __init__(self, v0: float, beta: float, beta_truth: float, g: float = 9.81):
        self.v0 = v0
        self.beta = beta
        self.beta_truth = beta_truth
        self.g = g
        self.vt = np.sqrt(g / beta)
        self.tau = self.vt / g

    def numerical_trajectory(
        self, theta: float, dt: float = 0.01, max_t: float = 200.0
    ):
        """Ground truth: RK4 integration of coupled quadratic drag."""
        c, s = np.cos(theta), np.sin(theta)
        vx, vy = self.v0 * c, self.v0 * s
        x, y = 0.0, 0.0

        trajectory = [(0.0, x, y, vx, vy)]
        t = 0.0

        while t < max_t and y >= 0.0:
            # RK4 for coupled system
            def derivs(vx, vy):
                v = np.sqrt(vx * vx + vy * vy)
                return (-self.beta_truth * v * vx, -self.g - self.beta_truth * v * vy)

            k1 = derivs(vx, vy)
            k2 = derivs(vx + 0.5 * dt * k1[0], vy + 0.5 * dt * k1[1])
            k3 = derivs(vx + 0.5 * dt * k2[0], vy + 0.5 * dt * k2[1])
            k4 = derivs(vx + dt * k3[0], vy + dt * k3[1])

            vx += dt * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0]) / 6
            vy += dt * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1]) / 6
            x += vx * dt
            y += vy * dt
            t += dt

            trajectory.append((t, x, y, vx, vy))

        return np.array(trajectory)

    def _vertical_position(self, sin_theta: float, t: float) -> float:
        vy0 = self.v0 * sin_theta
        phi0 = np.arctan(vy0 / self.vt)
        t_apex = self.tau * phi0

        if t <= t_apex and phi0 > 0.0:
            return (
                self.tau * self.vt * np.log(np.cos(phi0 - t / self.tau) / np.cos(phi0))
            )
        else:
            y_apex = (
                self.tau * self.vt * np.log(1.0 / np.cos(phi0)) if phi0 > 0.0 else 0.0
            )
            dt = t - max(0.0, t_apex)
            return y_apex - self.tau * self.vt * np.log(np.cosh(dt / self.tau))

    def position_decoupled(self, theta: float, t: float):
        """Original decoupled approximation."""
        c, s = np.cos(theta), np.sin(theta)
        vx0 = self.v0 * c
        x = np.log(1.0 + self.beta * vx0 * t) / self.beta
        y = self._vertical_position(s, t)
        return x, y

    def position_cosine_correction(self, theta: float, t: float):
        """Your empirical correction: multiply by cos²(θ/2)."""
        c, s = np.cos(theta), np.sin(theta)
        vx0 = self.v0 * c
        correction = (c + 1.0) * 0.5  # = cos²(θ/2)
        x = np.log(1.0 + self.beta * vx0 * t) / self.beta * correction
        y = self._vertical_position(s, t)
        return x, y

    def position_secant_averaged(self, theta: float, t: float):
        """Physics-motivated: average of 1 and 1/sec(θ)."""
        c, s = np.cos(theta), np.sin(theta)
        vx0 = self.v0 * c
        # At t=0, coupling factor is sec(θ). Average with 1 for trajectory average.
        correction = (1.0 + c) / 2.0  # Same as yours!
        x = np.log(1.0 + self.beta * vx0 * t) / self.beta * correction
        y = self._vertical_position(s, t)
        return x, y

    def position_effective_beta(self, theta: float, t: float):
        """Use modified drag coefficient instead of post-hoc correction."""
        c, s = np.cos(theta), np.sin(theta)
        vx0 = self.v0 * c

        # Effective beta accounts for coupling: β_eff = β * avg(|v|/vx)
        # Initial coupling is sec(θ), decays toward 1 as vy→0
        # Use geometric mean: sqrt(sec(θ) * 1) = 1/sqrt(cos(θ))
        sec_theta = 1.0 / c if c > 0.01 else 100.0
        coupling = np.sqrt(sec_theta)
        beta_eff = self.beta * coupling

        x = np.log(1.0 + beta_eff * vx0 * t) / beta_eff
        y = self._vertical_position(s, t)
        return x, y

    def position_velocity_weighted(self, theta: float, t: float):
        """Weight correction by how much velocity has decayed."""
        c, s = np.cos(theta), np.sin(theta)
        vx0 = self.v0 * c

        # Base horizontal position
        arg = 1.0 + self.beta * vx0 * t
        x_base = np.log(arg) / self.beta

        # Time-varying correction: stronger early (when vy is large)
        # Approximate velocity ratio at time t
        vx_t = vx0 / arg
        velocity_ratio = vx_t / vx0  # How much vx has decayed (1 → 0)

        # Correction interpolates from cos²(θ/2) to 1 as velocity decays
        correction_initial = (c + 1.0) * 0.5
        correction = correction_initial + (1.0 - correction_initial) * (
            1.0 - velocity_ratio
        )

        x = x_base * correction
        y = self._vertical_position(s, t)
        return x, y


BETA_TRUTH = 0.00001726


def compare_methods(v0=800.0, beta=0.0001, angles_deg=None):
    """Compare all methods against numerical ground truth."""
    if angles_deg is None:
        angles_deg = [20, 30, 45, 60, 75, 85]

    ballistics = BallisticsTest(v0, beta, BETA_TRUTH)

    fig, axes = plt.subplots(2, 3, figsize=(15, 10))
    axes = axes.flatten()

    methods = [
        ("Decoupled", ballistics.position_decoupled, "r--"),
        ("cos²(θ/2)", ballistics.position_cosine_correction, "g-"),
        ("Effective β", ballistics.position_effective_beta, "b-."),
        ("Vel-weighted", ballistics.position_velocity_weighted, "m:"),
    ]

    for idx, angle_deg in enumerate(angles_deg):
        ax = axes[idx]
        theta = np.radians(angle_deg)

        # Numerical ground truth
        traj = ballistics.numerical_trajectory(theta)
        ax.plot(traj[:, 1], traj[:, 2], "k-", linewidth=2, label="Numerical (truth)")

        # Sample times for analytical
        t_max = traj[-1, 0]
        times = np.linspace(0, t_max, 100)

        for name, method, style in methods:
            positions = [method(theta, t) for t in times]
            xs, ys = zip(*positions)
            ax.plot(xs, ys, style, label=name, alpha=0.8)

        ax.set_xlabel("x (m)")
        ax.set_ylabel("y (m)")
        ax.set_title(f"θ = {angle_deg}°")
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)
        ax.set_ylim(bottom=0)

    plt.tight_layout()
    plt.savefig("ballistics_comparison.png", dpi=150)
    plt.show()


def compute_errors(v0=800.0, beta=0.0001):
    """Compute range errors for each method across angles."""
    ballistics = BallisticsTest(v0, beta, BETA_TRUTH)
    angles_deg = np.arange(20, 86, 5)

    methods = [
        ("Decoupled", ballistics.position_decoupled),
        ("cos²(θ/2)", ballistics.position_cosine_correction),
        ("Effective β", ballistics.position_effective_beta),
        ("Vel-weighted", ballistics.position_velocity_weighted),
    ]

    print(f"{'Angle':>6} | " + " | ".join(f"{name:>12}" for name, _ in methods))
    print("-" * (10 + 15 * len(methods)))

    for angle_deg in angles_deg:
        theta = np.radians(angle_deg)
        traj = ballistics.numerical_trajectory(theta)
        true_range = traj[-1, 1]
        true_tof = traj[-1, 0]

        errors = []
        for name, method in methods:
            x, y = method(theta, true_tof)
            error_pct = 100 * (x - true_range) / true_range
            errors.append(f"{error_pct:+.2f}%")

        print(f"{angle_deg:>5}° | " + " | ".join(f"{e:>12}" for e in errors))


BETA = 0.00002
if __name__ == "__main__":
    compute_errors(820, BETA)
    compare_methods(820, BETA)
