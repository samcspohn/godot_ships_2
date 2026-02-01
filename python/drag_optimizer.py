"""
Drag Coefficient Optimizer for Naval Shell Ballistics
Finds optimal linear drag coefficient to match quadratic drag simulation
with adjustable weighting between range and impact velocity accuracy.

Usage:
    python drag_optimizer.py

    Or modify the SHELL_PARAMETERS at the top of the script.
"""

import argparse
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import matplotlib.gridspec as gridspec
import matplotlib.pyplot as plt
import numpy as np
from scipy.optimize import minimize_scalar

# =============================================================================
# CONFIGURATION - Edit these values for your shell
# =============================================================================


@dataclass
class BallisticDataPoint:
    """A single known ballistic data point for fitting the drag coefficient"""

    elevation: float  # radians - launch angle
    range: float  # meters - horizontal distance traveled
    time: float  # seconds - time of flight
    impact_velocity: float  # m/s - velocity at impact
    weight: float = 1.0  # relative weight for this data point in optimization


@dataclass
class ShellParameters:
    """Parameters for a naval shell"""

    caliber: float  # meters
    mass: float  # kg
    muzzle_velocity: float  # m/s
    max_range: float  # meters - maximum effective range (simulation stops here)
    data_points: List[BallisticDataPoint] = field(
        default_factory=list
    )  # known ballistic data for fitting
    linear_gravity: float = 9.81  # m/s² - gravity for linear drag (can differ from quadratic for game balance)
    # Quadratic rate time warp: rate(t) = min_rate + k*(t - apex)²
    # Starts at rate>1, slows to min_rate at apex, then speeds back up past 1.0
    time_warp_min_rate: float = 1.0  # minimum rate at apex (0.88 = 88% speed)
    time_warp_apex: float = 30.0  # time when rate is minimum (seconds)
    name: str = "Shell"

    @property
    def target_range(self) -> float:
        """Return the first data point's range for backward compatibility"""
        if self.data_points:
            return self.data_points[0].range
        return 0.0

    @property
    def target_elevation(self) -> float:
        """Return the first data point's elevation for backward compatibility"""
        if self.data_points:
            return self.data_points[0].elevation
        return 0.0

    @property
    def expected_time(self) -> float:
        """Return the first data point's time for backward compatibility"""
        if self.data_points:
            return self.data_points[0].time
        return 0.0

    @property
    def expected_impact_velocity(self) -> float:
        """Return the first data point's impact velocity for backward compatibility"""
        if self.data_points:
            return self.data_points[0].impact_velocity
        return 0.0


# Define your shells here
SHELL_380MM = ShellParameters(
    caliber=0.380,
    mass=800.0,
    muzzle_velocity=820.0,
    max_range=38000.0,  # Maximum effective range
    data_points=[
        BallisticDataPoint(
            elevation=np.radians(29.1),
            range=35000.0,
            time=69.9,
            impact_velocity=462,
            weight=1.0,
        ),
        BallisticDataPoint(
            elevation=np.radians(16.8),
            range=25000.0,
            time=43.0,
            impact_velocity=473.0,
            weight=1.0,
        ),
        # Add more data points here for better fitting:
        # BallisticDataPoint(elevation=np.radians(15.0), range=20000.0, time=35.0, impact_velocity=550.0),
        # BallisticDataPoint(elevation=np.radians(45.0), range=38000.0, time=90.0, impact_velocity=420.0),
    ],
    linear_gravity=10.5,  # Custom gravity for linear drag approximation
    time_warp_min_rate=1.0,  # No time warp (rate always 1.0)
    time_warp_apex=30.0,
    name="380mm",
)

SHELL_203MM = ShellParameters(
    caliber=0.203,
    mass=152.0,
    muzzle_velocity=762.0,
    max_range=30000.0,  # Maximum effective range
    data_points=[
        BallisticDataPoint(
            elevation=np.radians(45.28),
            range=27900.0,
            time=84.0,
            impact_velocity=404.0,
            weight=1.0,
        ),
        # Add more data points here for better fitting:
        # BallisticDataPoint(elevation=np.radians(20.0), range=15000.0, time=40.0, impact_velocity=500.0),
    ],
    linear_gravity=9.81,  # Custom gravity for linear drag approximation
    time_warp_min_rate=0.88,  # Slow to 88% at apex
    time_warp_apex=30.0,  # Apex at 30 seconds
    name="203mm",
)

# Select which shell to optimize
CURRENT_SHELL = SHELL_380MM

# Optimization search parameters
BETA_SEARCH_PARAMS = {
    "beta_min": 0.0001,  # Minimum beta to search
    "beta_max": 0.025,  # Maximum beta to search
    "num_samples": 300,  # Number of beta values to test
}

# Error weighting (must sum to 1.0)
ERROR_WEIGHTS = {
    "weight_range": 0.0,  # Weight for range error
    "weight_impact_velocity": 0.0,  # Weight for impact velocity error
    "weight_time": 0.0,  # Weight for time of flight error
    "weight_rms_velocity": 1.0,  # Weight for overall RMS velocity error
}

# Plotting parameters
PLOT_PARAMS = {
    "dpi": 150,
    "figsize": (16, 11),
    "save_plots": True,
    "output_dir": "output/",
}

# Constants
GRAVITY = 9.81  # m/s² - Standard Earth gravity (used for quadratic drag reference)
AIR_DENSITY = 1.225  # kg/m³

# Note: Linear drag can use custom gravity via ShellParameters.linear_gravity
# This allows game balance tweaks without affecting the quadratic reference


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
        dt: float = 0.05,
        max_time: float = 200.0,
        max_range: float = None,
    ) -> Tuple[List[float], np.ndarray]:
        """
        Simulate projectile trajectory with quadratic drag

        Args:
            v0: Initial velocity (m/s)
            angle_rad: Launch angle (radians)
            dt: Time step (seconds)
            max_time: Maximum simulation time (seconds)
            max_range: Maximum range - stop simulation if exceeded (meters)

        Returns:
            times: List of time points
            trajectory: Array of [x, y, vx, vy] at each time point
        """
        v0x = v0 * np.cos(angle_rad)
        v0y = v0 * np.sin(angle_rad)

        state = np.array([0.0, 0.0, v0x, v0y])
        trajectory = [state.copy()]
        times = [0.0]

        t = 0.0
        prev_x = 0.0

        while t < max_time and state[1] >= 0.0:
            # Check if max range exceeded
            if max_range is not None and state[0] > max_range:
                break

            # Check if shell is moving backwards (range decreasing)
            # This happens at very high angles when shell falls back toward gun
            if t > 1.0 and state[0] < prev_x:  # Range is decreasing
                break

            prev_x = state[0]

            # RK4 integration
            k1 = self.derivatives(state)
            k2 = self.derivatives(state + 0.5 * dt * k1)
            k3 = self.derivatives(state + 0.5 * dt * k2)
            k4 = self.derivatives(state + dt * k3)

            state = state + (dt / 6.0) * (k1 + 2 * k2 + 2 * k3 + k4)
            t += dt

            trajectory.append(state.copy())
            times.append(t)

            if state[1] < 0:
                break

        return times, np.array(trajectory)

    def derivatives(self, state: np.ndarray) -> np.ndarray:
        """Compute derivatives for quadratic drag"""
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
    """Linear drag approximation with analytical solution"""

    def __init__(
        self,
        beta: float,
        gravity: float = GRAVITY,
        time_warp_min_rate: float = 1.0,
        time_warp_apex: float = 30.0,
    ):
        self.beta = beta
        self.gravity = gravity
        self.time_warp_min_rate = time_warp_min_rate
        self.time_warp_apex = time_warp_apex
        # Quadratic coefficient: rate(t) = min_rate + k*(t - apex)²
        # At t=0: rate = 1.0, so 1.0 = min_rate + k*apex²
        # k = (1 - min_rate) / apex²
        if time_warp_apex > 0:
            self.time_warp_k = (1.0 - time_warp_min_rate) / (time_warp_apex**2)
        else:
            self.time_warp_k = 0.0

    def warp_time(self, t: float) -> float:
        """Calculate warped time using quadratic rate integration.

        rate(t) = min_rate + k*(t - apex)²
        t_warped = integral of rate from 0 to t
                 = min_rate*t + k*((t-apex)³ - (-apex)³)/3
                 = min_rate*t + k*((t-apex)³ + apex³)/3
        """
        if self.time_warp_min_rate >= 1.0:
            return t  # No warp

        apex = self.time_warp_apex
        k = self.time_warp_k
        min_rate = self.time_warp_min_rate

        t_warped = min_rate * t + k * ((t - apex) ** 3 + apex**3) / 3.0
        return t_warped

    def calculate_position_at_time(
        self, v0x: float, v0y: float, time: float
    ) -> Tuple[float, float]:
        """Calculate position at given time (with time warp applied)"""
        t_warped = self.warp_time(time)

        beta = self.beta
        g = self.gravity

        drag_factor = 1.0 - np.exp(-beta * t_warped)

        x = (v0x / beta) * drag_factor
        y = (
            (v0y / beta) * drag_factor
            - (g / beta) * t_warped
            + (g / (beta * beta)) * drag_factor
        )

        return x, y

    # def calculate_velocity_at_time(
    #     self, v0x: float, v0y: float, time: float
    # ) -> Tuple[float, float]:
    #     """Calculate velocity at given time (with time warp applied)

    #     The velocity is computed using warped time for game balance consistency.
    #     This means the velocity follows the same physics as the position calculation.
    #     """
    #     # Apply time warp: t = pow(t, mod)
    #     t_warped = pow(time, self.time_warp) if time > 0 else 0.0

    #     beta = self.beta
    #     g = self.gravity

    #     exp_term = np.exp(-beta * t_warped)

    #     vx = v0x * exp_term
    #     vy = v0y * exp_term - (g / beta) * (1.0 - exp_term)

    #     return vx, vy

    def simulate(
        self,
        v0: float,
        angle_rad: float,
        dt: float = 0.05,
        max_time: float = 200.0,
        max_range: float = None,
    ) -> Tuple[List[float], np.ndarray]:
        """
        Generate trajectory using analytical linear drag formulas

        Args:
            v0: Initial velocity (m/s)
            angle_rad: Launch angle (radians)
            dt: Time step (seconds)
            max_time: Maximum simulation time (seconds)
            max_range: Maximum range - stop simulation if exceeded (meters)

        Returns:
            times: List of time points
            trajectory: Array of [x, y, vx, vy] at each time point
        """
        v0x = v0 * np.cos(angle_rad)
        v0y = v0 * np.sin(angle_rad)

        times = []
        trajectory = []

        t = dt
        prev_x = 0.0
        prev_y = 0.0

        while t < max_time:
            x, y = self.calculate_position_at_time(v0x, v0y, t)
            vx, vy = (x - prev_x) / dt, (y - prev_y) / dt
            prev_x, prev_y = x, y
            # vx, vy = self.calculate_velocity_at_time(v0x, v0y, t)

            # Check if max range exceeded
            if max_range is not None and x > max_range:
                break

            # Check if shell is moving backwards (range decreasing)
            if t > 1.0 and x < prev_x:  # Range is decreasing
                break

            prev_x = x

            times.append(t)
            trajectory.append([x, y, vx, vy])

            if y < 0 and t > 0:
                break

            t += dt

        return times, np.array(trajectory)


# =============================================================================
# OPTIMIZATION FUNCTIONS
# =============================================================================


def find_quadratic_drag_coefficient(
    shell: ShellParameters,
    k_min: float = 0.00001,
    k_max: float = 0.0005,
    error_weights: Optional[Dict[str, float]] = None,
) -> float:
    """
    Find quadratic drag coefficient that best matches all known ballistic data points.

    Uses scipy.optimize.minimize_scalar with Brent's method for robust optimization.

    Args:
        shell: Shell parameters with data_points list
        k_min: Minimum k value to search
        k_max: Maximum k value to search
        error_weights: Optional weights for error components:
            - 'range': weight for range error (default 1.0)
            - 'time': weight for time error (default 1.0)
            - 'velocity': weight for impact velocity error (default 1.0)

    Returns:
        Optimal quadratic drag coefficient k
    """
    if not shell.data_points:
        raise ValueError("No ballistic data points provided in shell.data_points")

    # Default error weights
    if error_weights is None:
        error_weights = {"range": 1.0, "time": 1.0, "velocity": 1.0}

    print(f"Finding quadratic drag coefficient for {shell.name}...")
    print(f"  Using {len(shell.data_points)} data point(s) for fitting")
    print(
        f"  Error weights: range={error_weights['range']:.2f}, "
        f"time={error_weights['time']:.2f}, velocity={error_weights['velocity']:.2f}"
    )

    def compute_total_error(k: float) -> float:
        """Compute weighted total error across all data points for a given k"""
        if k <= 0:
            return float("inf")

        sim = QuadraticDragSimulator(k)
        total_error = 0.0
        total_weight = 0.0

        for dp in shell.data_points:
            times, traj = sim.simulate(
                shell.muzzle_velocity, dp.elevation, max_range=shell.max_range
            )

            if len(traj) < 2:
                return float("inf")

            actual_range = traj[-1, 0]
            actual_time = times[-1]
            actual_impact_vel = np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2)

            # Compute normalized errors
            range_error = abs(actual_range - dp.range) / dp.range if dp.range > 0 else 0
            time_error = abs(actual_time - dp.time) / dp.time if dp.time > 0 else 0
            vel_error = (
                abs(actual_impact_vel - dp.impact_velocity) / dp.impact_velocity
                if dp.impact_velocity > 0
                else 0
            )

            # Weighted sum of squared errors for this data point
            point_error = (
                error_weights["range"] * range_error**2
                + error_weights["time"] * time_error**2
                + error_weights["velocity"] * vel_error**2
            )

            total_error += dp.weight * point_error
            total_weight += dp.weight

        return total_error / total_weight if total_weight > 0 else float("inf")

    # Use scipy's minimize_scalar with Brent's method for robust optimization
    result = minimize_scalar(
        compute_total_error,
        bounds=(k_min, k_max),
        method="bounded",
        options={"xatol": 1e-10, "maxiter": 500},
    )

    best_k = result.x
    best_error = result.fun

    print(f"  Optimization {'converged' if result.success else 'did not converge'}")
    print(f"  Found k = {best_k:.10f} (RMS error: {np.sqrt(best_error) * 100:.4f}%)")

    # Print per-data-point results
    sim = QuadraticDragSimulator(best_k)
    print("\n  Per-data-point results:")
    print(
        f"  {'Angle°':<10} {'Range km':<12} {'Exp km':<10} {'Time s':<10} {'Exp s':<10} {'Vel m/s':<10} {'Exp m/s':<10}"
    )
    print("  " + "-" * 75)

    for dp in shell.data_points:
        times, traj = sim.simulate(
            shell.muzzle_velocity, dp.elevation, max_range=shell.max_range
        )
        actual_range = traj[-1, 0]
        actual_time = times[-1]
        actual_vel = np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2)

        print(
            f"  {np.degrees(dp.elevation):<10.2f} {actual_range / 1000:<12.2f} {dp.range / 1000:<10.2f} "
            f"{actual_time:<10.2f} {dp.time:<10.2f} {actual_vel:<10.1f} {dp.impact_velocity:<10.1f}"
        )

    return best_k


def optimize_linear_drag(
    shell: ShellParameters, k_quadratic: float, weights: Dict[str, float]
) -> Dict:
    """
    Find optimal linear drag coefficient with adjustable error weighting

    Args:
        shell: Shell parameters
        k_quadratic: Quadratic drag coefficient for reference
        weights: Dictionary of error weights (must sum to 1.0)

    Returns:
        Dictionary with optimization results
    """
    print(f"\nOptimizing linear drag coefficient for {shell.name}...")
    print(
        f"Error weights: Range={weights['weight_range']:.2f}, "
        f"Impact Vel={weights['weight_impact_velocity']:.2f}, "
        f"Time={weights['weight_time']:.2f}, "
        f"RMS Vel={weights['weight_rms_velocity']:.2f}"
    )

    # Validate weights
    total_weight = sum(weights.values())
    if abs(total_weight - 1.0) > 0.001:
        print(f"WARNING: Weights sum to {total_weight:.3f}, normalizing to 1.0")
        for key in weights:
            weights[key] /= total_weight

    # Run reference quadratic simulation
    quad_sim = QuadraticDragSimulator(k_quadratic)
    times_quad, traj_quad = quad_sim.simulate(
        shell.muzzle_velocity, shell.target_elevation
    )

    x_quad = traj_quad[:, 0]
    speed_quad = np.sqrt(traj_quad[:, 2] ** 2 + traj_quad[:, 3] ** 2)

    # Search beta space
    beta_values = np.linspace(
        BETA_SEARCH_PARAMS["beta_min"],
        BETA_SEARCH_PARAMS["beta_max"],
        BETA_SEARCH_PARAMS["num_samples"],
    )

    best_beta = None
    best_error = float("inf")
    results = []

    print(
        f"Testing {len(beta_values)} beta values from {beta_values[0]:.6f} to {beta_values[-1]:.6f}..."
    )

    for beta in beta_values:
        linear_sim = LinearDragApproximation(
            beta,
            gravity=shell.linear_gravity,
            time_warp_min_rate=shell.time_warp_min_rate,
            time_warp_apex=shell.time_warp_apex,
        )
        times, traj = linear_sim.simulate(shell.muzzle_velocity, shell.target_elevation)

        x = traj[:, 0]
        speed = np.sqrt(traj[:, 2] ** 2 + traj[:, 3] ** 2)

        # Calculate errors
        range_error = abs(x[-1] - x_quad[-1]) / x_quad[-1]
        time_error = abs(times[-1] - times_quad[-1]) / times_quad[-1]
        impact_vel_error = abs(speed[-1] - speed_quad[-1]) / speed_quad[-1]

        # RMS velocity error across trajectory
        x_common = np.linspace(0, min(x_quad[-1], x[-1]), 100)
        speed_quad_interp = np.interp(x_common, x_quad, speed_quad)
        speed_interp = np.interp(x_common, x, speed)
        rms_vel_error = (
            np.sqrt(np.mean((speed_interp - speed_quad_interp) ** 2))
            / shell.muzzle_velocity
        )

        # Weighted total error
        total_error = (
            range_error * weights["weight_range"]
            + impact_vel_error * weights["weight_impact_velocity"]
            + time_error * weights["weight_time"]
            + rms_vel_error * weights["weight_rms_velocity"]
        )

        results.append(
            {
                "beta": beta,
                "range": x[-1],
                "range_error": range_error,
                "time": times[-1],
                "time_error": time_error,
                "impact_vel": speed[-1],
                "impact_vel_error": impact_vel_error,
                "rms_vel_error": rms_vel_error,
                "total_error": total_error,
            }
        )

        if total_error < best_error:
            best_error = total_error
            best_beta = beta

    # Sort results by total error
    results.sort(key=lambda r: r["total_error"])

    print(f"\nOptimal β = {best_beta:.6f}")
    print(
        f"  Range: {results[0]['range'] / 1000:.2f}km (error: {results[0]['range_error'] * 100:+.2f}%)"
    )
    print(
        f"  Impact velocity: {results[0]['impact_vel']:.1f}m/s (error: {results[0]['impact_vel_error'] * 100:+.2f}%)"
    )
    print(
        f"  Time: {results[0]['time']:.2f}s (error: {results[0]['time_error'] * 100:+.2f}%)"
    )
    print(f"  RMS velocity error: {results[0]['rms_vel_error'] * 100:.2f}%")

    return {
        "optimal_beta": best_beta,
        "all_results": results,
        "reference_quad": {
            "times": times_quad,
            "trajectory": traj_quad,
            "x": x_quad,
            "speed": speed_quad,
        },
    }


# =============================================================================
# PLOTTING FUNCTIONS
# =============================================================================


def plot_comparison(
    shell: ShellParameters,
    k_quadratic: float,
    beta_values: List[float],
    beta_labels: List[str],
    optimization_results: Dict = None,
    axes: List = None,
):
    """
    Create comprehensive comparison plots

    Args:
        shell: Shell parameters
        k_quadratic: Quadratic drag coefficient
        beta_values: List of beta values to plot
        beta_labels: Labels for each beta value
        optimization_results: Optional results from optimization
        axes: Optional list of 4 axes to plot on (for combined view)
    """
    print("\nGenerating comparison plots...")

    # Run simulations
    quad_sim = QuadraticDragSimulator(k_quadratic)
    times_quad, traj_quad = quad_sim.simulate(
        shell.muzzle_velocity, shell.target_elevation
    )

    x_quad = traj_quad[:, 0]
    y_quad = traj_quad[:, 1]
    speed_quad = np.sqrt(traj_quad[:, 2] ** 2 + traj_quad[:, 3] ** 2)

    # Run linear simulations
    linear_results = []
    for beta in beta_values:
        sim = LinearDragApproximation(
            beta,
            gravity=shell.linear_gravity,
            time_warp_min_rate=shell.time_warp_min_rate,
            time_warp_apex=shell.time_warp_apex,
        )
        times, traj = sim.simulate(shell.muzzle_velocity, shell.target_elevation)
        linear_results.append(
            {
                "beta": beta,
                "times": times,
                "traj": traj,
                "x": traj[:, 0],
                "y": traj[:, 1],
                "speed": np.sqrt(traj[:, 2] ** 2 + traj[:, 3] ** 2),
            }
        )

    # Create plots - use provided axes or create new figure
    if axes is None:
        fig, axes_arr = plt.subplots(2, 2, figsize=PLOT_PARAMS["figsize"])
        axes = [axes_arr[0, 0], axes_arr[0, 1], axes_arr[1, 0], axes_arr[1, 1]]
        standalone = True
    else:
        standalone = False

    colors = ["orange", "green", "red", "purple", "brown"]
    linestyles = [":", "--", "--", "-.", "-."]

    # Plot 1: Trajectory
    ax = axes[0]
    ax.plot(
        x_quad / 1000,
        y_quad / 1000,
        "b-",
        linewidth=3,
        label=f"Quadratic (k={k_quadratic:.6f})",
        zorder=len(beta_values) + 1,
    )

    for i, (result, label) in enumerate(zip(linear_results, beta_labels)):
        ax.plot(
            result["x"] / 1000,
            result["y"] / 1000,
            color=colors[i % len(colors)],
            linestyle=linestyles[i % len(linestyles)],
            linewidth=2.5,
            label=label,
            zorder=len(beta_values) - i,
            alpha=0.8,
        )

    ax.set_xlabel("Range (km)", fontsize=10)
    ax.set_ylabel("Altitude (km)", fontsize=10)
    ax.set_title(
        f"Trajectory at {np.degrees(shell.target_elevation):.2f}° - {shell.name}",
        fontsize=11,
        fontweight="bold",
    )
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=8)

    # Plot 2: Velocity vs Time
    ax = axes[1]
    ax.plot(
        times_quad,
        speed_quad,
        "b-",
        linewidth=3,
        label="Quadratic",
        zorder=len(beta_values) + 1,
    )

    for i, (result, label) in enumerate(zip(linear_results, beta_labels)):
        ax.plot(
            result["times"],
            result["speed"],
            color=colors[i % len(colors)],
            linestyle=linestyles[i % len(linestyles)],
            linewidth=2.5,
            label=label,
            zorder=len(beta_values) - i,
            alpha=0.8,
        )

    ax.set_xlabel("Time (s)", fontsize=10)
    ax.set_ylabel("Velocity (m/s)", fontsize=10)
    ax.set_title("Velocity vs Time", fontsize=11, fontweight="bold")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=8)

    # Plot 3: Velocity vs Range
    ax = axes[2]
    ax.plot(
        x_quad / 1000,
        speed_quad,
        "b-",
        linewidth=3,
        label="Quadratic",
        zorder=len(beta_values) + 1,
    )

    for i, (result, label) in enumerate(zip(linear_results, beta_labels)):
        ax.plot(
            result["x"] / 1000,
            result["speed"],
            color=colors[i % len(colors)],
            linestyle=linestyles[i % len(linestyles)],
            linewidth=2.5,
            label=label,
            zorder=len(beta_values) - i,
            alpha=0.8,
        )

    ax.set_xlabel("Range (km)", fontsize=10)
    ax.set_ylabel("Velocity (m/s)", fontsize=10)
    ax.set_title("Velocity vs Range", fontsize=11, fontweight="bold")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=8)

    # Plot 4: Velocity Error
    ax = axes[3]
    x_common = np.linspace(0, x_quad[-1], 1000)
    speed_quad_interp = np.interp(x_common, x_quad, speed_quad)

    for i, (result, label) in enumerate(zip(linear_results, beta_labels)):
        speed_interp = np.interp(x_common, result["x"], result["speed"])
        error = ((speed_interp - speed_quad_interp) / speed_quad_interp) * 100

        ax.plot(
            x_common / 1000,
            error,
            color=colors[i % len(colors)],
            linestyle=linestyles[i % len(linestyles)],
            linewidth=2.5,
            label=label,
            alpha=0.8,
        )

    ax.axhline(y=0, color="b", linestyle="-", alpha=0.3, linewidth=1)
    ax.set_xlabel("Range (km)", fontsize=10)
    ax.set_ylabel("Velocity Error (%)", fontsize=10)
    ax.set_title("Velocity Error (Linear - Quadratic)", fontsize=11, fontweight="bold")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=8)

    if standalone:
        plt.tight_layout()

        if PLOT_PARAMS["save_plots"]:
            filename = f"{PLOT_PARAMS['output_dir']}{shell.name}_drag_comparison.png"
            plt.savefig(filename, dpi=PLOT_PARAMS["dpi"], bbox_inches="tight")
            print(f"Saved plot to {filename}")

        # If optimization results provided, create optimization surface plot
        if optimization_results:
            plot_optimization_surface(shell, optimization_results)

        plt.show(block=False)


def plot_optimization_surface(
    shell: ShellParameters, opt_results: Dict, axes: List = None
):
    """Plot optimization error surface

    Args:
        shell: Shell parameters
        opt_results: Optimization results dictionary
        axes: Optional list of 2 axes to plot on (for combined view)
    """
    results = opt_results["all_results"]

    # Create plots - use provided axes or create new figure
    if axes is None:
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))
        standalone = True
    else:
        ax1, ax2 = axes[0], axes[1]
        standalone = False

    betas = [r["beta"] for r in results]
    range_errors = [r["range_error"] * 100 for r in results]
    impact_vel_errors = [r["impact_vel_error"] * 100 for r in results]
    total_errors = [r["total_error"] * 100 for r in results]

    # Plot 1: Individual errors
    ax1.plot(betas, range_errors, "b-", linewidth=2, label="Range Error")
    ax1.plot(betas, impact_vel_errors, "r-", linewidth=2, label="Impact Velocity Error")
    ax1.plot(betas, total_errors, "g-", linewidth=2, label="Weighted Total Error")

    optimal_beta = opt_results["optimal_beta"]
    ax1.axvline(
        x=optimal_beta,
        color="orange",
        linestyle="--",
        linewidth=2,
        label=f"Optimal β={optimal_beta:.6f}",
    )

    ax1.set_xlabel("Beta Coefficient", fontsize=10)
    ax1.set_ylabel("Error (%)", fontsize=10)
    ax1.set_title(f"Error vs Beta - {shell.name}", fontsize=11, fontweight="bold")
    ax1.grid(True, alpha=0.3)
    ax1.legend(fontsize=8)

    # Plot 2: 2D error contour
    scatter = ax2.scatter(
        range_errors, impact_vel_errors, c=betas, cmap="viridis", s=20, alpha=0.6
    )

    # Mark optimal point
    opt_idx = next(i for i, r in enumerate(results) if r["beta"] == optimal_beta)
    ax2.scatter(
        range_errors[opt_idx],
        impact_vel_errors[opt_idx],
        color="red",
        s=200,
        marker="*",
        edgecolors="black",
        linewidths=2,
        label="Optimal",
        zorder=10,
    )

    ax2.set_xlabel("Range Error (%)", fontsize=10)
    ax2.set_ylabel("Impact Velocity Error (%)", fontsize=10)
    ax2.set_title("Error Space", fontsize=11, fontweight="bold")
    ax2.grid(True, alpha=0.3)
    ax2.legend(fontsize=8)

    cbar = plt.colorbar(scatter, ax=ax2)
    cbar.set_label("Beta Coefficient", fontsize=9)

    if standalone:
        plt.tight_layout()

        if PLOT_PARAMS["save_plots"]:
            filename = (
                f"{PLOT_PARAMS['output_dir']}{shell.name}_optimization_surface.png"
            )
            plt.savefig(filename, dpi=PLOT_PARAMS["dpi"], bbox_inches="tight")
            print(f"Saved optimization plot to {filename}")

        plt.show(block=False)


def plot_range_curves(
    shell: ShellParameters,
    k_quadratic: float,
    beta_optimal: float,
    additional_betas: List[float] = None,
    axes: List = None,
):
    """
    Plot impact velocity and time to target vs range at different elevation angles

    Args:
        shell: Shell parameters
        k_quadratic: Quadratic drag coefficient
        beta_optimal: Optimal linear drag coefficient
        additional_betas: Optional list of additional beta values to plot
        axes: Optional list of 3 axes to plot on (for combined view)
    """
    print("\nGenerating range curves...")

    # Test range of elevation angles - start from very low to show full range curve
    angles_deg = np.linspace(
        1, 60, 40
    )  # More samples, starting from 1° for near-zero range
    angles_rad = np.radians(angles_deg)

    # Storage for results
    quad_ranges = []
    quad_impact_vels = []
    quad_times = []

    linear_opt_ranges = []
    linear_opt_impact_vels = []
    linear_opt_times = []

    # Additional beta results if provided
    additional_results = []
    if additional_betas:
        for beta in additional_betas:
            additional_results.append(
                {"beta": beta, "ranges": [], "impact_vels": [], "times": []}
            )

    # Simulate at each angle
    quad_sim = QuadraticDragSimulator(k_quadratic)
    linear_opt_sim = LinearDragApproximation(
        beta_optimal,
        gravity=shell.linear_gravity,
        time_warp_min_rate=shell.time_warp_min_rate,
        time_warp_apex=shell.time_warp_apex,
    )

    additional_sims = []
    if additional_betas:
        for beta in additional_betas:
            additional_sims.append(
                LinearDragApproximation(
                    beta,
                    gravity=shell.linear_gravity,
                    time_warp_min_rate=shell.time_warp_min_rate,
                    time_warp_apex=shell.time_warp_apex,
                )
            )

    for angle in angles_rad:
        # Quadratic
        times, traj = quad_sim.simulate(
            shell.muzzle_velocity, angle, max_range=shell.max_range
        )
        # Only add if shell actually reached ground (not cut off mid-flight)
        if traj[-1, 1] <= 0 or traj[-1, 0] >= shell.max_range:
            curr_range = traj[-1, 0] / 1000  # km

            # Stop collecting data if range starts decreasing (passed optimal angle)
            if len(quad_ranges) > 3 and curr_range < quad_ranges[-1]:
                break

            quad_ranges.append(curr_range)
            quad_impact_vels.append(np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2))
            quad_times.append(times[-1])

        # Optimal linear
        times, traj = linear_opt_sim.simulate(
            shell.muzzle_velocity, angle, max_range=shell.max_range
        )
        if traj[-1, 1] <= 0 or traj[-1, 0] >= shell.max_range:
            curr_range = traj[-1, 0] / 1000  # km

            # Stop if range decreasing
            if len(linear_opt_ranges) > 3 and curr_range < linear_opt_ranges[-1]:
                break

            linear_opt_ranges.append(curr_range)
            linear_opt_impact_vels.append(np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2))
            linear_opt_times.append(times[-1])

        # Additional betas
        for i, sim in enumerate(additional_sims):
            times, traj = sim.simulate(
                shell.muzzle_velocity, angle, max_range=shell.max_range
            )
            if traj[-1, 1] <= 0 or traj[-1, 0] >= shell.max_range:
                curr_range = traj[-1, 0] / 1000

                # Stop if range decreasing
                if (
                    len(additional_results[i]["ranges"]) > 3
                    and curr_range < additional_results[i]["ranges"][-1]
                ):
                    continue  # Skip this beta but keep testing others

                additional_results[i]["ranges"].append(curr_range)
                additional_results[i]["impact_vels"].append(
                    np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2)
                )
                additional_results[i]["times"].append(times[-1])

    # Create plots - use provided axes or create new figure
    if axes is None:
        fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(20, 6))
        standalone = True
    else:
        ax1, ax2, ax3 = axes[0], axes[1], axes[2]
        standalone = False

    colors = ["orange", "red", "purple", "brown"]
    linestyles = ["--", "--", "-.", "-."]

    # Plot 1: Impact Velocity vs Range
    ax1.plot(
        quad_ranges,
        quad_impact_vels,
        "b-",
        linewidth=3,
        label=f"Quadratic (k={k_quadratic:.6f})",
        zorder=10,
    )
    ax1.plot(
        linear_opt_ranges,
        linear_opt_impact_vels,
        "g:",
        linewidth=3,
        label=f"Optimal Linear (β={beta_optimal:.6f})",
        zorder=9,
    )

    for i, result in enumerate(additional_results):
        ax1.plot(
            result["ranges"],
            result["impact_vels"],
            color=colors[i % len(colors)],
            linestyle=linestyles[i % len(linestyles)],
            linewidth=2,
            label=f"β={result['beta']:.6f}",
            zorder=8 - i,
            alpha=0.7,
        )

    ax1.set_xlabel("Range (km)", fontsize=10)
    ax1.set_ylabel("Impact Velocity (m/s)", fontsize=10)
    ax1.set_title(
        f"Impact Velocity vs Range - {shell.name}", fontsize=11, fontweight="bold"
    )
    ax1.grid(True, alpha=0.3)
    ax1.legend(fontsize=8)

    # Add angle annotations at key points
    # With 40 samples from 1° to 60°: indices 0≈1°, 6≈10°, 13≈20°, 20≈30°, 26≈40°
    for i in [0, 6, 13, 20, 26]:
        if i < len(quad_ranges):  # Only annotate if we have this data point
            ax1.annotate(
                f"{angles_deg[i]:.0f}°",
                xy=(quad_ranges[i], quad_impact_vels[i]),
                xytext=(5, 5),
                textcoords="offset points",
                fontsize=7,
                alpha=0.6,
            )

    # Plot 2: Time to Target vs Range
    ax2.plot(quad_ranges, quad_times, "b-", linewidth=3, label="Quadratic", zorder=10)
    ax2.plot(
        linear_opt_ranges,
        linear_opt_times,
        "g:",
        linewidth=3,
        label=f"Optimal Linear",
        zorder=9,
    )

    for i, result in enumerate(additional_results):
        ax2.plot(
            result["ranges"],
            result["times"],
            color=colors[i % len(colors)],
            linestyle=linestyles[i % len(linestyles)],
            linewidth=2,
            label=f"β={result['beta']:.6f}",
            zorder=8 - i,
            alpha=0.7,
        )

    ax2.set_xlabel("Range (km)", fontsize=10)
    ax2.set_ylabel("Time to Target (s)", fontsize=10)
    ax2.set_title(
        f"Time of Flight vs Range - {shell.name}", fontsize=11, fontweight="bold"
    )
    ax2.grid(True, alpha=0.3)
    ax2.legend(fontsize=8)

    # Add angle annotations
    for i in [0, 6, 13, 20, 26]:
        if i < len(quad_ranges):  # Only annotate if we have this data point
            ax2.annotate(
                f"{angles_deg[i]:.0f}°",
                xy=(quad_ranges[i], quad_times[i]),
                xytext=(5, 5),
                textcoords="offset points",
                fontsize=7,
                alpha=0.6,
            )

    # Plot 3: Elevation Angle vs Range
    # Create angle data that corresponds to the ranges
    quad_angles_for_ranges = angles_deg[: len(quad_ranges)]
    linear_opt_angles_for_ranges = angles_deg[: len(linear_opt_ranges)]

    ax3.plot(
        quad_ranges,
        quad_angles_for_ranges,
        "b-",
        linewidth=3,
        label="Quadratic",
        zorder=10,
    )
    ax3.plot(
        linear_opt_ranges,
        linear_opt_angles_for_ranges,
        "g:",
        linewidth=3,
        label="Optimal Linear",
        zorder=9,
    )

    for i, result in enumerate(additional_results):
        result_angles = angles_deg[: len(result["ranges"])]
        ax3.plot(
            result["ranges"],
            result_angles,
            color=colors[i % len(colors)],
            linestyle=linestyles[i % len(linestyles)],
            linewidth=2,
            label=f"β={result['beta']:.6f}",
            zorder=8 - i,
            alpha=0.7,
        )

    ax3.set_xlabel("Range (km)", fontsize=10)
    ax3.set_ylabel("Elevation Angle (degrees)", fontsize=10)
    ax3.set_title(
        f"Firing Solution - Angle vs Range - {shell.name}",
        fontsize=11,
        fontweight="bold",
    )
    ax3.grid(True, alpha=0.3)
    ax3.legend(fontsize=8)

    # Add range annotations at key angles
    for i in [0, 6, 13, 20, 26]:
        if i < len(quad_ranges):
            ax3.annotate(
                f"{quad_ranges[i]:.1f}km",
                xy=(quad_ranges[i], quad_angles_for_ranges[i]),
                xytext=(5, -10),
                textcoords="offset points",
                fontsize=7,
                alpha=0.6,
            )

    if standalone:
        plt.tight_layout()

        if PLOT_PARAMS["save_plots"]:
            filename = f"{PLOT_PARAMS['output_dir']}{shell.name}_range_curves.png"
            plt.savefig(filename, dpi=PLOT_PARAMS["dpi"], bbox_inches="tight")
            print(f"Saved range curves to {filename}")

    # Print some key data points
    print(f"\n{'=' * 80}")
    print(f"RANGE CURVES DATA - {shell.name}")
    print(f"{'=' * 80}")
    print(f"{'Angle':<8} {'Range (km)':<12} {'Impact Vel (m/s)':<18} {'Time (s)':<12}")
    print(f"{'(deg)':<8} {'Quad/Linear':<12} {'Quad/Linear':<18} {'Quad/Linear':<12}")
    print("-" * 80)

    # Use the length of the shortest list
    min_len = min(len(quad_ranges), len(linear_opt_ranges))
    for i in range(0, min_len, 5):  # Every 10 degrees approximately
        print(
            f"{angles_deg[i]:<8.0f} {quad_ranges[i]:>5.1f}/{linear_opt_ranges[i]:<5.1f} "
            f"{quad_impact_vels[i]:>7.1f}/{linear_opt_impact_vels[i]:<9.1f} "
            f"{quad_times[i]:>5.1f}/{linear_opt_times[i]:<6.1f}"
        )

    print(
        f"\nNote: Data stops at {angles_deg[min_len - 1]:.0f}° where range begins to decrease"
    )

    if standalone:
        plt.show()


def plot_ballistic_performance_curves(
    shell: ShellParameters,
    k_quadratic: float,
    beta_values: List[float],
    beta_labels: List[str],
    axes: List = None,
):
    """
    Plot impact velocity and time to target vs range at different elevation angles

    This creates performance curves showing how impact velocity and flight time
    vary with range for both quadratic and linear drag models.

    Args:
        shell: Shell parameters
        k_quadratic: Quadratic drag coefficient
        beta_values: List of beta values to plot
        beta_labels: Labels for each beta value
        axes: Optional list of 2 axes to plot on (for combined view)
    """
    print("\nGenerating ballistic performance curves...")

    # Test elevation angles from 5° to 60°
    angles_deg = np.linspace(5, 60, 25)
    angles_rad = np.radians(angles_deg)

    # Store results for each drag model
    models = []

    # Quadratic drag
    quad_sim = QuadraticDragSimulator(k_quadratic)
    quad_ranges = []
    quad_impact_vels = []
    quad_times = []

    for angle in angles_rad:
        times, traj = quad_sim.simulate(
            shell.muzzle_velocity, angle, max_range=shell.max_range
        )
        # Only include if shell landed within max range
        if traj[-1, 1] <= 0 or traj[-1, 0] >= shell.max_range:
            quad_ranges.append(traj[-1, 0] / 1000)  # km
            quad_impact_vels.append(np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2))
            quad_times.append(times[-1])

    models.append(
        {
            "name": "Quadratic",
            "ranges": quad_ranges,
            "impact_vels": quad_impact_vels,
            "times": quad_times,
            "color": "blue",
            "linestyle": "-",
            "linewidth": 3,
        }
    )

    # Linear drag models
    colors = ["orange", "green", "red", "purple"]
    linestyles = [":", "--", "-.", "--"]

    for i, (beta, label) in enumerate(zip(beta_values, beta_labels)):
        linear_sim = LinearDragApproximation(
            beta,
            gravity=shell.linear_gravity,
            time_warp_min_rate=shell.time_warp_min_rate,
            time_warp_apex=shell.time_warp_apex,
        )
        lin_ranges = []
        lin_impact_vels = []
        lin_times = []

        for angle in angles_rad:
            times, traj = linear_sim.simulate(
                shell.muzzle_velocity, angle, max_range=shell.max_range
            )
            # Only include if shell landed within max range
            if traj[-1, 1] <= 0 or traj[-1, 0] >= shell.max_range:
                lin_ranges.append(traj[-1, 0] / 1000)  # km
                lin_impact_vels.append(np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2))
                lin_times.append(times[-1])

        models.append(
            {
                "name": label,
                "ranges": lin_ranges,
                "impact_vels": lin_impact_vels,
                "times": lin_times,
                "color": colors[i % len(colors)],
                "linestyle": linestyles[i % len(linestyles)],
                "linewidth": 2.5,
            }
        )

    # Create plots - use provided axes or create new figure
    if axes is None:
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 6))
        standalone = True
    else:
        ax1, ax2 = axes[0], axes[1]
        standalone = False

    # Plot 1: Impact Velocity vs Range
    for model in models:
        ax1.plot(
            model["ranges"],
            model["impact_vels"],
            color=model["color"],
            linestyle=model["linestyle"],
            linewidth=model["linewidth"],
            label=model["name"],
            alpha=0.9 if model["name"] == "Quadratic" else 0.8,
        )

    ax1.set_xlabel("Range (km)", fontsize=10)
    ax1.set_ylabel("Impact Velocity (m/s)", fontsize=10)
    ax1.set_title(
        f"Impact Velocity vs Range - {shell.name}", fontsize=11, fontweight="bold"
    )
    ax1.grid(True, alpha=0.3)
    ax1.legend(fontsize=8, loc="best")

    # Add annotations for key angles
    quad_model = models[0]
    key_angles_deg = [15, 30, 45]
    for angle_deg in key_angles_deg:
        idx = np.argmin(np.abs(angles_deg - angle_deg))
        ax1.annotate(
            f"{angle_deg}°",
            xy=(quad_model["ranges"][idx], quad_model["impact_vels"][idx]),
            xytext=(5, 5),
            textcoords="offset points",
            fontsize=8,
            alpha=0.7,
            bbox=dict(boxstyle="round,pad=0.3", facecolor="yellow", alpha=0.3),
        )

    # Plot 2: Time to Target vs Range
    for model in models:
        ax2.plot(
            model["ranges"],
            model["times"],
            color=model["color"],
            linestyle=model["linestyle"],
            linewidth=model["linewidth"],
            label=model["name"],
            alpha=0.9 if model["name"] == "Quadratic" else 0.8,
        )

    ax2.set_xlabel("Range (km)", fontsize=10)
    ax2.set_ylabel("Time to Target (s)", fontsize=10)
    ax2.set_title(
        f"Time to Target vs Range - {shell.name}", fontsize=11, fontweight="bold"
    )
    ax2.grid(True, alpha=0.3)
    ax2.legend(fontsize=8, loc="best")

    # Add annotations for key angles
    for angle_deg in key_angles_deg:
        idx = np.argmin(np.abs(angles_deg - angle_deg))
        ax2.annotate(
            f"{angle_deg}°",
            xy=(quad_model["ranges"][idx], quad_model["times"][idx]),
            xytext=(5, 5),
            textcoords="offset points",
            fontsize=8,
            alpha=0.7,
            bbox=dict(boxstyle="round,pad=0.3", facecolor="yellow", alpha=0.3),
        )

    if standalone:
        plt.tight_layout()

        if PLOT_PARAMS["save_plots"]:
            filename = (
                f"{PLOT_PARAMS['output_dir']}{shell.name}_ballistic_performance.png"
            )
            plt.savefig(filename, dpi=PLOT_PARAMS["dpi"], bbox_inches="tight")
            print(f"Saved ballistic performance curves to {filename}")

    # Print performance data table
    print("\n" + "=" * 90)
    print("BALLISTIC PERFORMANCE DATA")
    print("=" * 90)
    print(f"{'Angle':<8} {'Range (km)':<12} {'Impact Vel (m/s)':<18} {'Time (s)':<12}")
    print(f"{'':<8} {'Quadratic':<12} {'Quadratic':<18} {'Quadratic':<12}")
    print("-" * 90)

    key_angles_idx = [np.argmin(np.abs(angles_deg - a)) for a in [15, 30, 45]]
    for idx in key_angles_idx:
        print(
            f"{angles_deg[idx]:<8.0f} {quad_model['ranges'][idx]:<12.2f} "
            f"{quad_model['impact_vels'][idx]:<18.1f} {quad_model['times'][idx]:<12.2f}"
        )

    if standalone:
        plt.show(block=False)


# =============================================================================
# MAIN EXECUTION
# =============================================================================


def plot_all_combined(
    shell: ShellParameters,
    k_quadratic: float,
    opt_results: Dict,
    beta_values: List[float],
    beta_labels: List[str],
    additional_test_betas: List[float],
):
    """
    Create a single figure with all plots organized in sections.

    Layout (using 12-column grid):
    - Row 0-1: Comparison plots (2x2 = 4 plots)
    - Row 2: Optimization surface (2 plots)
    - Row 3: Range curves (3 plots)
    - Row 4: Ballistic performance (2 plots)

    Args:
        shell: Shell parameters
        k_quadratic: Quadratic drag coefficient
        opt_results: Optimization results dictionary
        beta_values: List of beta values to plot
        beta_labels: Labels for each beta value
        additional_test_betas: Additional beta values for range curves
    """
    print("\n" + "=" * 70)
    print("GENERATING COMBINED PLOT")
    print("=" * 70)

    optimal_beta = opt_results["optimal_beta"]

    # Create figure with GridSpec - 5 rows, 12 columns for flexibility
    fig = plt.figure(figsize=(24, 28))
    gs = gridspec.GridSpec(5, 12, figure=fig, hspace=0.35, wspace=0.4)

    # Add section titles
    fig.text(
        0.5,
        0.98,
        f"Drag Coefficient Analysis - {shell.name}",
        ha="center",
        va="top",
        fontsize=16,
        fontweight="bold",
    )

    # Section 1: Comparison plots (Row 0-1, 2x2 layout)
    # Each plot spans 6 columns (half width)
    ax_comp = [
        fig.add_subplot(gs[0, 0:6]),  # Trajectory
        fig.add_subplot(gs[0, 6:12]),  # Velocity vs Time
        fig.add_subplot(gs[1, 0:6]),  # Velocity vs Range
        fig.add_subplot(gs[1, 6:12]),  # Velocity Error
    ]

    # Add section label for comparison
    fig.text(
        0.02,
        0.96,
        "COMPARISON PLOTS",
        fontsize=12,
        fontweight="bold",
        rotation=90,
        va="top",
    )

    # Section 2: Optimization surface (Row 2, 2 plots)
    # Each plot spans 6 columns
    ax_opt = [
        fig.add_subplot(gs[2, 0:6]),  # Error vs Beta
        fig.add_subplot(gs[2, 6:12]),  # Error Space
    ]

    # Add section label for optimization
    fig.text(
        0.02,
        0.58,
        "OPTIMIZATION",
        fontsize=12,
        fontweight="bold",
        rotation=90,
        va="center",
    )

    # Section 3: Range curves (Row 3, 3 plots)
    # Each plot spans 4 columns
    ax_range = [
        fig.add_subplot(gs[3, 0:4]),  # Impact Velocity vs Range
        fig.add_subplot(gs[3, 4:8]),  # Time of Flight vs Range
        fig.add_subplot(gs[3, 8:12]),  # Angle vs Range
    ]

    # Add section label for range curves
    fig.text(
        0.02,
        0.38,
        "RANGE CURVES",
        fontsize=12,
        fontweight="bold",
        rotation=90,
        va="center",
    )

    # Section 4: Ballistic performance (Row 4, 2 plots)
    # Each plot spans 6 columns
    ax_ballistic = [
        fig.add_subplot(gs[4, 0:6]),  # Impact Velocity vs Range
        fig.add_subplot(gs[4, 6:12]),  # Time to Target vs Range
    ]

    # Add section label for ballistic performance
    fig.text(
        0.02,
        0.18,
        "BALLISTIC\nPERFORMANCE",
        fontsize=12,
        fontweight="bold",
        rotation=90,
        va="center",
    )

    # Call plotting functions with axes
    plot_comparison(
        shell,
        k_quadratic,
        beta_values,
        beta_labels,
        optimization_results=None,
        axes=ax_comp,
    )

    plot_optimization_surface(shell, opt_results, axes=ax_opt)

    plot_range_curves(
        shell, k_quadratic, optimal_beta, additional_test_betas, axes=ax_range
    )

    plot_ballistic_performance_curves(
        shell, k_quadratic, beta_values, beta_labels, axes=ax_ballistic
    )

    # Adjust layout
    plt.subplots_adjust(top=0.96, bottom=0.03, left=0.05, right=0.98)

    if PLOT_PARAMS["save_plots"]:
        filename = f"{PLOT_PARAMS['output_dir']}{shell.name}_combined_analysis.png"
        plt.savefig(filename, dpi=PLOT_PARAMS["dpi"], bbox_inches="tight")
        print(f"Saved combined plot to {filename}")

    plt.show()


def main():
    """Main execution function"""
    shell = CURRENT_SHELL

    print("=" * 70)
    print(f"DRAG COEFFICIENT OPTIMIZER - {shell.name}")
    print("=" * 70)
    print(
        f"Shell: {shell.caliber * 1000:.0f}mm, {shell.mass:.0f}kg, {shell.muzzle_velocity:.0f}m/s"
    )
    print(f"Linear params: gravity={shell.linear_gravity:.2f}m/s²")
    print(
        f"Time warp: min_rate={shell.time_warp_min_rate:.2f} at apex={shell.time_warp_apex:.0f}s"
    )
    print(
        f"Target: {shell.target_range / 1000:.2f}km at {np.degrees(shell.target_elevation):.2f}°"
    )
    print("=" * 70)

    # Find quadratic drag coefficient
    k_quadratic = find_quadratic_drag_coefficient(shell)

    # Optimize linear drag with given weights
    opt_results = optimize_linear_drag(shell, k_quadratic, ERROR_WEIGHTS)
    optimal_beta = opt_results["optimal_beta"]

    # Print top candidates
    print("\nTop 10 Beta Candidates:")
    print(
        f"{'Beta':<12} {'Range Err%':<12} {'Impact Err%':<12} {'Time Err%':<12} {'Total Err%':<12}"
    )
    print("-" * 65)
    for r in opt_results["all_results"][:10]:
        print(
            f"{r['beta']:<12.6f} {r['range_error'] * 100:<12.2f} "
            f"{r['impact_vel_error'] * 100:<12.2f} {r['time_error'] * 100:<12.2f} "
            f"{r['total_error'] * 100:<12.2f}"
        )

    # Create comparison plots with optimal and a few other candidates
    beta_values = [
        optimal_beta,
        0.016,
        0.0125,
        0.0205,
        0.014,
    ]  # Add your comparison betas
    beta_labels = [
        f"Optimal β={optimal_beta:.6f}",
        "β=0.016",
        "β=0.0125",
        "β=0.0205",
        "β=0.014",
    ]

    # Filter out any betas that are duplicates of optimal
    unique_betas = []
    unique_labels = []
    for beta, label in zip(beta_values, beta_labels):
        if abs(beta - optimal_beta) > 0.0001:
            unique_betas.append(beta)
            unique_labels.append(label)
        elif "Optimal" in label:
            unique_betas.append(beta)
            unique_labels.append(label)

    # Generate range curve betas
    additional_test_betas = [
        b for b in [0.016, 0.0125, 0.0205, 0.014] if abs(b - optimal_beta) > 0.001
    ]

    # Create single combined plot with all visualizations
    plot_all_combined(
        shell,
        k_quadratic,
        opt_results,
        unique_betas,
        unique_labels,
        additional_test_betas,
    )

    print("\n" + "=" * 70)
    print("OPTIMIZATION COMPLETE")
    print("=" * 70)
    print(f"Recommended β for {shell.name}: {optimal_beta:.6f}")
    print("=" * 70)


if __name__ == "__main__":
    main()
