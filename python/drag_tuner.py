"""
Interactive Drag Coefficient Tuner for Naval Shell Ballistics

A live application for hand-tuning linear drag approximation parameters
to match quadratic drag simulation.

Usage:
    python drag_tuner.py
"""

from dataclasses import dataclass
from typing import List, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.widgets import Button, RadioButtons, Slider

# =============================================================================
# CONSTANTS
# =============================================================================

GRAVITY = 9.81  # m/s²


# =============================================================================
# SHELL PARAMETERS
# =============================================================================


@dataclass
class ShellParameters:
    """Parameters for a naval shell"""

    caliber: float  # meters
    mass: float  # kg
    muzzle_velocity: float  # m/s
    target_range: float  # meters
    target_elevation: float  # radians
    expected_time: float  # seconds
    expected_impact_velocity: float  # m/s
    max_range: float  # meters
    name: str = "Shell"


# Define shells
SHELL_380MM = ShellParameters(
    caliber=0.380,
    mass=800.0,
    muzzle_velocity=820.0,
    target_range=35000.0,
    target_elevation=np.radians(30.0),
    expected_time=71.45,
    expected_impact_velocity=470.7,
    max_range=38000.0,
    name="380mm",
)

SHELL_203MM = ShellParameters(
    caliber=0.203,
    mass=152.0,
    muzzle_velocity=762.0,
    target_range=27900.0,
    target_elevation=np.radians(45.28),
    expected_time=84.0,
    expected_impact_velocity=404.0,
    max_range=30000.0,
    name="203mm",
)

# Select shell
CURRENT_SHELL = SHELL_203MM


# =============================================================================
# SIMULATION CLASSES
# =============================================================================


class QuadraticDragSimulator:
    """Full numerical integration with quadratic drag using RK4"""

    def __init__(self, k: float, gravity: float = GRAVITY):
        self.k = k
        self.gravity = gravity

    def simulate(
        self,
        v0: float,
        angle_rad: float,
        dt: float = 0.1,
        max_time: float = 200.0,
        max_range: float = None,
    ) -> Tuple[List[float], np.ndarray]:
        v0x = v0 * np.cos(angle_rad)
        v0y = v0 * np.sin(angle_rad)

        state = np.array([0.0, 0.0, v0x, v0y])
        times = [0.0]
        trajectory = [state.copy()]

        t = 0.0
        while t < max_time:
            k1 = self._derivatives(state)
            k2 = self._derivatives(state + 0.5 * dt * k1)
            k3 = self._derivatives(state + 0.5 * dt * k2)
            k4 = self._derivatives(state + dt * k3)

            state = state + (dt / 6.0) * (k1 + 2 * k2 + 2 * k3 + k4)
            t += dt

            if max_range is not None and state[0] > max_range:
                break

            times.append(t)
            trajectory.append(state.copy())

            if state[1] < 0 and t > 0:
                break

        return times, np.array(trajectory)

    def _derivatives(self, state: np.ndarray) -> np.ndarray:
        x, y, vx, vy = state
        speed = np.sqrt(vx**2 + vy**2)

        if speed > 0:
            drag_accel_x = -self.k * speed * vx
            drag_accel_y = -self.k * speed * vy
        else:
            drag_accel_x = 0.0
            drag_accel_y = 0.0

        return np.array([vx, vy, drag_accel_x, drag_accel_y - self.gravity])


class LinearDragApproximation:
    """Linear drag approximation with analytical solution and time warp"""

    def __init__(
        self,
        beta: float,
        gravity: float = GRAVITY,
        muzzle_velocity_multiplier: float = 1.0,
        time_warp_min_rate: float = 1.0,
        time_warp_apex: float = 30.0,
    ):
        self.beta = beta
        self.gravity = gravity
        self.muzzle_velocity_multiplier = muzzle_velocity_multiplier
        self.time_warp_min_rate = time_warp_min_rate
        self.time_warp_apex = time_warp_apex

        # Quadratic coefficient: rate(t) = min_rate + k*(t - apex)²
        if time_warp_apex > 0:
            self.time_warp_k = (1.0 - time_warp_min_rate) / (time_warp_apex**2)
        else:
            self.time_warp_k = 0.0

    def warp_time(self, t: float) -> float:
        """Calculate warped time using quadratic rate integration."""
        if self.time_warp_min_rate >= 1.0:
            return t

        apex = self.time_warp_apex
        k = self.time_warp_k
        min_rate = self.time_warp_min_rate

        t_warped = min_rate * t + k * ((t - apex) ** 3 + apex**3) / 3.0
        return t_warped

    def get_rate(self, t: float) -> float:
        """Get the time warp rate at time t."""
        if self.time_warp_min_rate >= 1.0:
            return 1.0
        return (
            self.time_warp_min_rate + self.time_warp_k * (t - self.time_warp_apex) ** 2
        )

    def calculate_position_at_time(
        self, v0x: float, v0y: float, time: float
    ) -> Tuple[float, float]:
        t_warped = self.warp_time(time)

        beta = self.beta
        g = self.gravity

        drag_factor = 1.0 - np.exp(-beta * t_warped)

        x = (v0x / beta) * drag_factor
        y = (
            (v0y / beta) * drag_factor
            - (g / beta) * t_warped
            + (g / (beta**2)) * drag_factor
        )

        return x, y

    def simulate(
        self,
        v0: float,
        angle_rad: float,
        dt: float = 0.1,
        max_time: float = 200.0,
        max_range: float = None,
    ) -> Tuple[List[float], np.ndarray]:
        v0_effective = v0 * self.muzzle_velocity_multiplier
        v0x = v0_effective * np.cos(angle_rad)
        v0y = v0_effective * np.sin(angle_rad)

        times = []
        trajectory = []

        t = dt
        prev_x, prev_y = 0.0, 0.0

        while t < max_time:
            x, y = self.calculate_position_at_time(v0x, v0y, t)
            vx, vy = (x - prev_x) / dt, (y - prev_y) / dt
            prev_x, prev_y = x, y

            if max_range is not None and x > max_range:
                break

            if t > 1.0 and x < prev_x:
                break

            times.append(t)
            trajectory.append([x, y, vx, vy])

            if y < 0 and t > 0:
                break

            t += dt

        return times, np.array(trajectory)


# =============================================================================
# FIND QUADRATIC DRAG COEFFICIENT
# =============================================================================


def find_quadratic_drag_coefficient(shell: ShellParameters) -> float:
    """Find the quadratic drag coefficient that matches expected shell performance."""
    best_k = None
    best_error = float("inf")

    for k_test in np.linspace(0.00001, 0.0001, 200):
        sim = QuadraticDragSimulator(k_test)
        times, traj = sim.simulate(shell.muzzle_velocity, shell.target_elevation)

        actual_range = traj[-1, 0]
        actual_time = times[-1]
        actual_impact_vel = np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2)

        range_error = abs(actual_range - shell.target_range) / shell.target_range
        time_error = abs(actual_time - shell.expected_time) / shell.expected_time
        vel_error = (
            abs(actual_impact_vel - shell.expected_impact_velocity)
            / shell.expected_impact_velocity
        )

        total_error = range_error + time_error + vel_error

        if total_error < best_error:
            best_error = total_error
            best_k = k_test

    return best_k


# =============================================================================
# INTERACTIVE TUNER APPLICATION
# =============================================================================


class DragTunerApp:
    """Interactive application for tuning linear drag parameters."""

    def __init__(self, shell: ShellParameters):
        self.shell = shell
        self.k_quadratic = find_quadratic_drag_coefficient(shell)

        # Initial parameter values
        self.beta = 0.015
        self.gravity = 9.81
        self.muzzle_vel_mult = 1.0
        self.time_warp_min_rate = 1.0
        self.time_warp_apex = 30.0

        # Set up the figure
        self.fig = plt.figure(figsize=(18, 12))
        self.fig.suptitle(
            f"Drag Coefficient Tuner - {shell.name}", fontsize=14, fontweight="bold"
        )

        # Create axes for plots (3 columns x 2 rows)
        self.ax_traj = self.fig.add_axes([0.04, 0.55, 0.28, 0.35])
        self.ax_vel_time = self.fig.add_axes([0.36, 0.55, 0.28, 0.35])
        self.ax_impact_vel = self.fig.add_axes([0.68, 0.55, 0.28, 0.35])
        self.ax_vel_range = self.fig.add_axes([0.04, 0.18, 0.28, 0.30])
        self.ax_rate = self.fig.add_axes([0.36, 0.18, 0.28, 0.30])

        # Create sliders
        slider_left = 0.12
        slider_width = 0.28
        slider_height = 0.02

        self.ax_beta = self.fig.add_axes(
            [slider_left, 0.13, slider_width, slider_height]
        )
        self.ax_grav = self.fig.add_axes(
            [slider_left, 0.09, slider_width, slider_height]
        )
        self.ax_mv_mult = self.fig.add_axes(
            [slider_left, 0.05, slider_width, slider_height]
        )
        self.ax_tw_rate = self.fig.add_axes(
            [slider_left, 0.01, slider_width, slider_height]
        )
        self.ax_tw_apex = self.fig.add_axes(
            [slider_left + 0.45, 0.01, slider_width, slider_height]
        )

        self.slider_beta = Slider(
            self.ax_beta, "Beta (β)", 0.005, 0.03, valinit=self.beta, valfmt="%.4f"
        )
        self.slider_grav = Slider(
            self.ax_grav, "Gravity", 5.0, 25.0, valinit=self.gravity, valfmt="%.2f"
        )
        self.slider_mv_mult = Slider(
            self.ax_mv_mult,
            "Muzzle Vel Mult",
            0.5,
            1.5,
            valinit=self.muzzle_vel_mult,
            valfmt="%.3f",
        )
        self.slider_tw_rate = Slider(
            self.ax_tw_rate,
            "Time Warp Min Rate",
            0.5,
            1.0,
            valinit=self.time_warp_min_rate,
            valfmt="%.3f",
        )
        self.slider_tw_apex = Slider(
            self.ax_tw_apex,
            "Time Warp Apex (s)",
            10.0,
            60.0,
            valinit=self.time_warp_apex,
            valfmt="%.1f",
        )

        # Connect sliders to update function
        self.slider_beta.on_changed(self.update)
        self.slider_grav.on_changed(self.update)
        self.slider_mv_mult.on_changed(self.update)
        self.slider_tw_rate.on_changed(self.update)
        self.slider_tw_apex.on_changed(self.update)

        # Reset button
        self.ax_reset = self.fig.add_axes([0.8, 0.03, 0.1, 0.03])
        self.btn_reset = Button(self.ax_reset, "Reset")
        self.btn_reset.on_clicked(self.reset)

        # Info text
        self.ax_info = self.fig.add_axes([0.55, 0.06, 0.2, 0.08])
        self.ax_info.axis("off")
        self.info_text = self.ax_info.text(
            0, 0.5, "", fontsize=9, verticalalignment="center", family="monospace"
        )

        # Initial plot
        self.update(None)

    def update(self, val):
        """Update plots when sliders change."""
        # Get current slider values
        self.beta = self.slider_beta.val
        self.gravity = self.slider_grav.val
        self.muzzle_vel_mult = self.slider_mv_mult.val
        self.time_warp_min_rate = self.slider_tw_rate.val
        self.time_warp_apex = self.slider_tw_apex.val

        # Run simulations
        quad_sim = QuadraticDragSimulator(self.k_quadratic)
        times_quad, traj_quad = quad_sim.simulate(
            self.shell.muzzle_velocity,
            self.shell.target_elevation,
            max_range=self.shell.max_range,
        )

        linear_sim = LinearDragApproximation(
            self.beta,
            gravity=self.gravity,
            muzzle_velocity_multiplier=self.muzzle_vel_mult,
            time_warp_min_rate=self.time_warp_min_rate,
            time_warp_apex=self.time_warp_apex,
        )
        times_lin, traj_lin = linear_sim.simulate(
            self.shell.muzzle_velocity,
            self.shell.target_elevation,
            max_range=self.shell.max_range,
        )

        # Calculate speeds
        speed_quad = np.sqrt(traj_quad[:, 2] ** 2 + traj_quad[:, 3] ** 2)
        speed_lin = (
            np.sqrt(traj_lin[:, 2] ** 2 + traj_lin[:, 3] ** 2)
            if len(traj_lin) > 0
            else []
        )

        # Clear and redraw plots
        self._plot_trajectory(traj_quad, traj_lin)
        self._plot_velocity_vs_time(times_quad, speed_quad, times_lin, speed_lin)
        self._plot_impact_velocity()
        self._plot_velocity_vs_range(traj_quad, speed_quad, traj_lin, speed_lin)
        self._plot_time_warp_rate(
            linear_sim,
            max(times_quad[-1], times_lin[-1] if len(times_lin) > 0 else 100),
        )

        # Update info text
        self._update_info(
            traj_quad, times_quad, speed_quad, traj_lin, times_lin, speed_lin
        )

        self.fig.canvas.draw_idle()

    def _plot_trajectory(self, traj_quad, traj_lin):
        self.ax_traj.clear()
        self.ax_traj.plot(
            traj_quad[:, 0] / 1000,
            traj_quad[:, 1] / 1000,
            "b-",
            linewidth=2,
            label="Quadratic",
        )
        if len(traj_lin) > 0:
            self.ax_traj.plot(
                traj_lin[:, 0] / 1000,
                traj_lin[:, 1] / 1000,
                "r--",
                linewidth=2,
                label="Linear",
            )
        self.ax_traj.set_xlabel("Range (km)")
        self.ax_traj.set_ylabel("Altitude (km)")
        self.ax_traj.set_title("Trajectory")
        self.ax_traj.legend(loc="upper right")
        self.ax_traj.grid(True, alpha=0.3)
        self.ax_traj.set_xlim(left=0)
        self.ax_traj.set_ylim(bottom=0)

    def _plot_velocity_vs_time(self, times_quad, speed_quad, times_lin, speed_lin):
        self.ax_vel_time.clear()
        self.ax_vel_time.plot(
            times_quad, speed_quad, "b-", linewidth=2, label="Quadratic"
        )
        if len(times_lin) > 0 and len(speed_lin) > 0:
            self.ax_vel_time.plot(
                times_lin, speed_lin, "r--", linewidth=2, label="Linear"
            )
        self.ax_vel_time.set_xlabel("Time (s)")
        self.ax_vel_time.set_ylabel("Velocity (m/s)")
        self.ax_vel_time.set_title("Velocity vs Time")
        self.ax_vel_time.legend(loc="upper right")
        self.ax_vel_time.grid(True, alpha=0.3)

    def _plot_impact_velocity(self):
        """Plot impact velocity vs range for both drag models."""
        self.ax_impact_vel.clear()

        # Test elevation angles from 5° to 60°
        angles_deg = np.linspace(5, 60, 25)
        angles_rad = np.radians(angles_deg)

        # Quadratic drag simulation
        quad_sim = QuadraticDragSimulator(self.k_quadratic)
        quad_ranges = []
        quad_impact_vels = []
        prev_quad_range = -1.0

        for angle in angles_rad:
            times, traj = quad_sim.simulate(
                self.shell.muzzle_velocity, angle, max_range=self.shell.max_range
            )
            if traj[-1, 1] <= 0 or traj[-1, 0] >= self.shell.max_range:
                current_range = traj[-1, 0] / 1000  # km
                # Stop when range starts decreasing
                if current_range < prev_quad_range:
                    break
                prev_quad_range = current_range
                quad_ranges.append(current_range)
                quad_impact_vels.append(np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2))

        # Linear drag simulation
        linear_sim = LinearDragApproximation(
            self.beta,
            gravity=self.gravity,
            muzzle_velocity_multiplier=self.muzzle_vel_mult,
            time_warp_min_rate=self.time_warp_min_rate,
            time_warp_apex=self.time_warp_apex,
        )
        lin_ranges = []
        lin_impact_vels = []
        prev_lin_range = -1.0

        for angle in angles_rad:
            times, traj = linear_sim.simulate(
                self.shell.muzzle_velocity, angle, max_range=self.shell.max_range
            )
            if len(traj) > 0 and (
                traj[-1, 1] <= 0 or traj[-1, 0] >= self.shell.max_range
            ):
                current_range = traj[-1, 0] / 1000  # km
                # Stop when range starts decreasing
                if current_range < prev_lin_range:
                    break
                prev_lin_range = current_range
                lin_ranges.append(current_range)
                lin_impact_vels.append(np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2))

        # Plot
        self.ax_impact_vel.plot(
            quad_ranges, quad_impact_vels, "b-", linewidth=2, label="Quadratic"
        )
        self.ax_impact_vel.plot(
            lin_ranges, lin_impact_vels, "r--", linewidth=2, label="Linear"
        )

        self.ax_impact_vel.set_xlabel("Range (km)")
        self.ax_impact_vel.set_ylabel("Impact Velocity (m/s)")
        self.ax_impact_vel.set_title("Impact Velocity vs Range")
        self.ax_impact_vel.legend(loc="upper right", fontsize=8)
        self.ax_impact_vel.grid(True, alpha=0.3)

    def _plot_velocity_vs_range(self, traj_quad, speed_quad, traj_lin, speed_lin):
        self.ax_vel_range.clear()
        self.ax_vel_range.plot(
            traj_quad[:, 0] / 1000, speed_quad, "b-", linewidth=2, label="Quadratic"
        )
        if len(traj_lin) > 0 and len(speed_lin) > 0:
            self.ax_vel_range.plot(
                traj_lin[:, 0] / 1000, speed_lin, "r--", linewidth=2, label="Linear"
            )
        self.ax_vel_range.set_xlabel("Range (km)")
        self.ax_vel_range.set_ylabel("Velocity (m/s)")
        self.ax_vel_range.set_title("Velocity vs Range")
        self.ax_vel_range.legend(loc="upper right")
        self.ax_vel_range.grid(True, alpha=0.3)

    def _plot_time_warp_rate(self, linear_sim, max_time):
        self.ax_rate.clear()
        times = np.linspace(0, max_time, 200)
        rates = [linear_sim.get_rate(t) for t in times]
        self.ax_rate.plot(times, rates, "g-", linewidth=2)
        self.ax_rate.axhline(y=1.0, color="gray", linestyle="--", alpha=0.5)
        self.ax_rate.axvline(
            x=self.time_warp_apex,
            color="orange",
            linestyle=":",
            alpha=0.7,
            label=f"Apex ({self.time_warp_apex:.0f}s)",
        )
        self.ax_rate.set_xlabel("Time (s)")
        self.ax_rate.set_ylabel("Time Warp Rate")
        self.ax_rate.set_title("Time Warp Rate (1.0 = normal)")
        self.ax_rate.legend(loc="upper right")
        self.ax_rate.grid(True, alpha=0.3)
        self.ax_rate.set_ylim(0.5, 1.5)

    def _update_info(
        self, traj_quad, times_quad, speed_quad, traj_lin, times_lin, speed_lin
    ):
        # Calculate errors
        if len(traj_lin) > 0 and len(speed_lin) > 0:
            range_quad = traj_quad[-1, 0]
            range_lin = traj_lin[-1, 0]
            range_err = (range_lin - range_quad) / range_quad * 100

            time_quad = times_quad[-1]
            time_lin = times_lin[-1]
            time_err = (time_lin - time_quad) / time_quad * 100

            impact_vel_quad = speed_quad[-1]
            impact_vel_lin = speed_lin[-1]
            vel_err = (impact_vel_lin - impact_vel_quad) / impact_vel_quad * 100

            info = (
                f"Range:  {range_lin / 1000:.2f}km ({range_err:+.1f}%)\n"
                f"Time:   {time_lin:.1f}s ({time_err:+.1f}%)\n"
                f"Impact: {impact_vel_lin:.0f}m/s ({vel_err:+.1f}%)"
            )
        else:
            info = "No valid trajectory"

        self.info_text.set_text(info)

    def reset(self, event):
        """Reset sliders to initial values."""
        self.slider_beta.reset()
        self.slider_grav.reset()
        self.slider_mv_mult.reset()
        self.slider_tw_rate.reset()
        self.slider_tw_apex.reset()

    def run(self):
        """Start the application."""
        plt.show()


# =============================================================================
# MAIN
# =============================================================================


def main():
    print("=" * 60)
    print("INTERACTIVE DRAG COEFFICIENT TUNER")
    print("=" * 60)
    print(f"Shell: {CURRENT_SHELL.name}")
    print(f"  Caliber: {CURRENT_SHELL.caliber * 1000:.0f}mm")
    print(f"  Mass: {CURRENT_SHELL.mass:.0f}kg")
    print(f"  Muzzle Velocity: {CURRENT_SHELL.muzzle_velocity:.0f}m/s")
    print(f"  Target Range: {CURRENT_SHELL.target_range / 1000:.1f}km")
    print(f"  Target Elevation: {np.degrees(CURRENT_SHELL.target_elevation):.1f}°")
    print("=" * 60)
    print("\nAdjust sliders to tune linear drag parameters.")
    print("Blue = Quadratic (reference), Red = Linear (tunable)")
    print()

    app = DragTunerApp(CURRENT_SHELL)
    app.run()


if __name__ == "__main__":
    main()
