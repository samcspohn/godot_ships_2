"""
Combined Drag Optimization/Tuning Application for Naval Shell Ballistics

An interactive application combining manual tuning and automatic optimization
for matching linear drag approximation to quadratic drag simulation.

Usage:
    python drag_optimizer_app.py
"""

import json
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from queue import Empty, Queue
from typing import Callable, Dict, List, Tuple

import matplotlib.gridspec as gridspec
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.widgets import Button, Slider, TextBox
from scipy.optimize import minimize_scalar

# =============================================================================
# SAVE/LOAD CONFIGURATION
# =============================================================================

SAVE_FILE = Path(__file__).parent / "drag_optimizer_state.json"

# =============================================================================
# CONSTANTS
# =============================================================================

GRAVITY = 9.81  # m/s²


# =============================================================================
# DATA CLASSES
# =============================================================================


@dataclass
class BallisticDataPoint:
    """A single known ballistic data point for fitting the drag coefficient"""

    elevation: float  # radians - launch angle
    range: float  # meters - horizontal distance traveled
    time: float  # seconds - time of flight
    impact_velocity: float  # m/s - velocity at impact
    max_height: float = 0.0  # meters - maximum altitude reached (0 = not used)
    weight: float = 1.0  # relative weight for this data point in optimization


@dataclass
class ShellParameters:
    """Parameters for a naval shell"""

    caliber: float  # meters
    mass: float  # kg
    muzzle_velocity: float  # m/s
    max_range: float  # meters - maximum effective range
    data_points: List[BallisticDataPoint] = field(default_factory=list)
    linear_gravity: float = 9.81  # m/s²
    time_warp_min_rate: float = 1.0  # minimum rate at apex
    time_warp_apex: float = 30.0  # time when rate is minimum (seconds)
    name: str = "Shell"

    @property
    def target_range(self) -> float:
        if self.data_points:
            return self.data_points[0].range
        return 0.0

    @property
    def target_elevation(self) -> float:
        if self.data_points:
            return self.data_points[0].elevation
        return np.radians(30.0)

    @property
    def expected_time(self) -> float:
        if self.data_points:
            return self.data_points[0].time
        return 0.0

    @property
    def expected_impact_velocity(self) -> float:
        if self.data_points:
            return self.data_points[0].impact_velocity
        return 0.0


# Define shells
SHELL_380MM = ShellParameters(
    caliber=0.380,
    mass=800.0,
    muzzle_velocity=820.0,
    max_range=38000.0,
    data_points=[
        BallisticDataPoint(
            elevation=np.radians(29.1),
            range=35000.0,
            time=69.9,
            impact_velocity=462,
            max_height=8500.0,  # meters - maximum altitude at this angle
            weight=1.0,
        ),
        BallisticDataPoint(
            elevation=np.radians(16.8),
            range=25000.0,
            time=43.0,
            impact_velocity=473.0,
            max_height=3800.0,  # meters
            weight=1.0,
        ),
    ],
    linear_gravity=9.81,
    time_warp_min_rate=1.0,
    time_warp_apex=30.0,
    name="380mm",
)

SHELL_203MM = ShellParameters(
    caliber=0.203,
    mass=152.0,
    muzzle_velocity=762.0,
    max_range=30000.0,
    data_points=[
        BallisticDataPoint(
            elevation=np.radians(45.28),
            range=27900.0,
            time=84.0,
            impact_velocity=404.0,
            max_height=12000.0,  # meters
            weight=0.1,
        ),
        BallisticDataPoint(
            elevation=np.radians(10.75),
            range=14630.0,
            time=26.93,
            impact_velocity=419,
            max_height=0.0,  # meters - maximum altitude at this angle
            weight=1.0,
        ),
    ],
    linear_gravity=9.81,
    time_warp_min_rate=0.88,
    time_warp_apex=30.0,
    name="203mm",
)

# Example shell with height-only data (range=0 means don't use range for fitting)
SHELL_HEIGHT_ONLY = ShellParameters(
    caliber=0.380,
    mass=800.0,
    muzzle_velocity=820.0,
    max_range=40000.0,
    data_points=[
        BallisticDataPoint(
            elevation=np.radians(45.0),
            range=0.0,  # Not used for fitting
            time=0.0,  # Not used for fitting
            impact_velocity=0.0,  # Not used for fitting
            max_height=15000.0,  # Only height is used
            weight=1.0,
        ),
    ],
    linear_gravity=9.81,
    time_warp_min_rate=1.0,
    time_warp_apex=30.0,
    name="380mm (height-only)",
)

SHELL_150MM_GERAT = ShellParameters(
    caliber=0.15,
    mass=42.0,
    muzzle_velocity=1200.0,
    max_range=35000.0,
    data_points=[
        BallisticDataPoint(
            elevation=np.radians(85.0),
            range=0.0,
            time=0.0,
            impact_velocity=0.0,
            max_height=18000.0,  # meters
            weight=1.0,
        ),
    ],
    linear_gravity=9.81,
    time_warp_min_rate=1.0,
    time_warp_apex=30.0,
    name="150mm gerat",
)

# Select shell
CURRENT_SHELL = SHELL_380MM


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
        prev_x = 0.0

        while t < max_time:
            k1 = self._derivatives(state)
            k2 = self._derivatives(state + 0.5 * dt * k1)
            k3 = self._derivatives(state + 0.5 * dt * k2)
            k4 = self._derivatives(state + dt * k3)

            state = state + (dt / 6.0) * (k1 + 2 * k2 + 2 * k3 + k4)
            t += dt

            if max_range is not None and state[0] > max_range:
                break

            if t > 1.0 and state[0] < prev_x:
                break

            prev_x = state[0]
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
        time_warp_min_rate: float = 1.0,
        time_warp_apex: float = 30.0,
    ):
        self.beta = beta
        self.gravity = gravity
        self.time_warp_min_rate = time_warp_min_rate
        self.time_warp_apex = time_warp_apex

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
        v0x = v0 * np.cos(angle_rad)
        v0y = v0 * np.sin(angle_rad)

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

            times.append(t)
            trajectory.append([x, y, vx, vy])

            if y < 0 and t > 0:
                break

            t += dt

        return times, np.array(trajectory)


class AnalyticalDragSimulator:
    """
    Analytical solution for projectile motion with quadratic drag.

    This uses the exact closed-form solution that separates horizontal
    and vertical motion, using different formulas for ascent and descent.

    Based on the mathematical model where:
    - vt = sqrt(g/beta) is the terminal velocity
    - tau = vt/g is the characteristic time
    - Horizontal: uses logarithmic decay
    - Vertical ascent: uses tangent functions
    - Vertical descent: uses hyperbolic tangent functions
    """

    def __init__(
        self, muzzle_velocity: float, drag_coef: float, gravity: float = GRAVITY
    ):
        self.v0 = muzzle_velocity
        self.beta = drag_coef
        self.g = gravity
        self.vt = np.sqrt(gravity / drag_coef)
        self.tau = self.vt / gravity

    def position(self, theta: float, t: float) -> tuple:
        """Calculate position at time t for launch angle theta (radians)."""
        c = np.cos(theta)
        s = np.sin(theta)

        x = self._horizontal_position(c, t)
        y = self._vertical_position(s, t)

        return (x, y)

    def _horizontal_position(self, cos_theta: float, t: float) -> float:
        """Calculate horizontal position using sqrt(cos_theta) correction."""
        vx0 = self.v0 * cos_theta
        sqrt_c = np.sqrt(cos_theta)
        beta_eff = self.beta / sqrt_c

        return np.log(1.0 + beta_eff * vx0 * t) / beta_eff

    def velocity(self, theta: float, t: float) -> tuple:
        """Calculate velocity at time t for launch angle theta (radians)."""
        c = np.cos(theta)
        s = np.sin(theta)
        alpha = self.beta * self.v0

        vx = self.v0 * c / (1.0 + alpha * c * t)
        vy = self._vertical_velocity(s, t)

        return (vx, vy)

    def _vertical_position(self, sin_theta: float, t: float) -> float:
        """Calculate vertical position using ascent/descent formulas."""
        vy0 = self.v0 * sin_theta

        if vy0 >= 0.0:
            # Upward or horizontal: tan/atan formulation
            phi0 = np.arctan(vy0 / self.vt)
            t_apex = self.tau * phi0

            if t <= t_apex:
                phi = phi0 - t / self.tau
                return self.tau * self.vt * np.log(np.cos(phi) / np.cos(phi0))
            else:
                y_apex = self.tau * self.vt * np.log(1.0 / np.cos(phi0))
                dt = t - t_apex
                return y_apex - self.tau * self.vt * np.log(np.cosh(dt / self.tau))
        else:
            # Downward: tanh/atanh formulation
            ratio = vy0 / self.vt  # Negative, |ratio| < 1 for subsonic

            if ratio > -1.0:
                psi0 = np.arctanh(ratio)
                psi = psi0 - t / self.tau
                return self.tau * self.vt * np.log(np.cosh(psi0) / np.cosh(psi))
            else:
                # Supersonic downward - quickly approaches terminal velocity
                v_avg = (vy0 - self.vt) * 0.5
                return v_avg * t

    def _vertical_velocity(self, sin_theta: float, t: float) -> float:
        """Calculate vertical velocity using ascent/descent formulas."""
        vy0 = self.v0 * sin_theta
        phi0 = np.arctan(vy0 / self.vt)
        t_apex = self.tau * phi0

        if t <= t_apex and phi0 > 0.0:
            # Ascending phase
            return self.vt * np.tan(phi0 - t / self.tau)
        else:
            # Descending phase
            dt = t - max(0.0, t_apex)
            return -self.vt * np.tanh(dt / self.tau)

    def simulate(
        self,
        v0: float,
        angle_rad: float,
        dt: float = 0.1,
        max_time: float = 200.0,
        max_range: float = None,
    ) -> tuple:
        """
        Simulate trajectory and return times and trajectory array.

        Returns:
            Tuple of (times, trajectory) where trajectory is array of [x, y, vx, vy]
        """
        times = []
        trajectory = []

        t = dt
        prev_x = 0.0
        prev_y = 0.0
        while t < max_time:
            x, y = self.position(angle_rad, t)
            # vx, vy = self.velocity(angle_rad, t)
            vx = (x - prev_x) / dt
            vy = (y - prev_y) / dt
            prev_x = x
            prev_y = y

            if max_range is not None and x > max_range:
                break

            # Check if going backwards (shouldn't happen with this model)
            if t > 1.0 and x < prev_x:
                break

            prev_x = x
            times.append(t)
            trajectory.append([x, y, vx, vy])

            if y < 0 and t > 0:
                break

            t += dt

        return times, np.array(trajectory) if trajectory else np.array([])


# =============================================================================
# OPTIMIZATION FUNCTIONS
# =============================================================================


def find_quadratic_drag_coefficient(
    shell: ShellParameters, use_height: bool = False
) -> float:
    """
    Find the quadratic drag coefficient that matches expected shell performance.

    Args:
        shell: Shell parameters with data points
        use_height: If True, prioritize max_height for fitting instead of range
    """

    if not shell.data_points:
        # Fallback to simple grid search
        best_k = None
        best_error = float("inf")

        for k_test in np.linspace(0.00001, 0.0001, 200):
            sim = QuadraticDragSimulator(k_test)
            times, traj = sim.simulate(shell.muzzle_velocity, shell.target_elevation)

            if len(traj) < 2:
                continue

            actual_range = traj[-1, 0]
            actual_time = times[-1]
            actual_impact_vel = np.sqrt(traj[-1, 2] ** 2 + traj[-1, 3] ** 2)

            range_error = (
                abs(actual_range - shell.target_range) / shell.target_range
                if shell.target_range > 0
                else 0
            )
            time_error = (
                abs(actual_time - shell.expected_time) / shell.expected_time
                if shell.expected_time > 0
                else 0
            )
            vel_error = (
                abs(actual_impact_vel - shell.expected_impact_velocity)
                / shell.expected_impact_velocity
                if shell.expected_impact_velocity > 0
                else 0
            )

            total_error = range_error + time_error + vel_error

            if total_error < best_error:
                best_error = total_error
                best_k = k_test

        return best_k

    # Use scipy optimization with data points
    def compute_total_error(k: float) -> float:
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
            actual_max_height = np.max(traj[:, 1])

            # Calculate individual errors
            range_error = abs(actual_range - dp.range) / dp.range if dp.range > 0 else 0
            time_error = abs(actual_time - dp.time) / dp.time if dp.time > 0 else 0
            vel_error = (
                abs(actual_impact_vel - dp.impact_velocity) / dp.impact_velocity
                if dp.impact_velocity > 0
                else 0
            )
            height_error = (
                abs(actual_max_height - dp.max_height) / dp.max_height
                if dp.max_height > 0
                else 0
            )

            if use_height and dp.max_height > 0:
                # Prioritize height matching
                point_error = height_error**2 + 0.1 * (time_error**2 + vel_error**2)
            else:
                # Standard: use range, time, velocity, and height if available
                point_error = range_error**2 + time_error**2 + vel_error**2
                if dp.max_height > 0:
                    point_error += height_error**2

            total_error += dp.weight * point_error
            total_weight += dp.weight

        return total_error / total_weight if total_weight > 0 else float("inf")

    result = minimize_scalar(
        compute_total_error,
        bounds=(0.00001, 0.0005),
        method="bounded",
        options={"xatol": 1e-10, "maxiter": 500},
    )

    return result.x


def find_quadratic_drag_from_height(
    muzzle_velocity: float,
    elevation_rad: float,
    target_height: float,
    k_min: float = 0.00001,
    k_max: float = 0.001,
) -> float:
    """
    Find quadratic drag coefficient that produces the specified maximum height.

    Args:
        muzzle_velocity: Initial velocity in m/s
        elevation_rad: Launch angle in radians
        target_height: Desired maximum height in meters
        k_min: Minimum k value to search
        k_max: Maximum k value to search

    Returns:
        Optimal quadratic drag coefficient k
    """

    def height_error(k: float) -> float:
        if k <= 0:
            return float("inf")

        sim = QuadraticDragSimulator(k)
        times, traj = sim.simulate(muzzle_velocity, elevation_rad)

        if len(traj) < 2:
            return float("inf")

        actual_max_height = np.max(traj[:, 1])
        return abs(actual_max_height - target_height) / target_height

    result = minimize_scalar(
        height_error,
        bounds=(k_min, k_max),
        method="bounded",
        options={"xatol": 1e-12, "maxiter": 500},
    )

    return result.x


def optimize_linear_drag(
    shell: ShellParameters,
    k_quadratic: float,
    current_gravity: float,
    current_tw_min_rate: float,
    current_tw_apex: float,
) -> Dict:
    """
    Find optimal linear drag coefficient (beta) given current parameters.
    """
    quad_sim = QuadraticDragSimulator(k_quadratic)
    times_quad, traj_quad = quad_sim.simulate(
        shell.muzzle_velocity, shell.target_elevation
    )

    x_quad = traj_quad[:, 0]
    speed_quad = np.sqrt(traj_quad[:, 2] ** 2 + traj_quad[:, 3] ** 2)

    beta_values = np.linspace(0.005, 0.03, 300)

    best_beta = None
    best_error = float("inf")
    all_results = []

    for beta in beta_values:
        linear_sim = LinearDragApproximation(
            beta,
            gravity=current_gravity,
            time_warp_min_rate=current_tw_min_rate,
            time_warp_apex=current_tw_apex,
        )
        times, traj = linear_sim.simulate(shell.muzzle_velocity, shell.target_elevation)

        if len(traj) < 2:
            continue

        x = traj[:, 0]
        speed = np.sqrt(traj[:, 2] ** 2 + traj[:, 3] ** 2)

        # Calculate errors
        range_error = abs(x[-1] - x_quad[-1]) / x_quad[-1] if x_quad[-1] > 0 else 0
        time_error = (
            abs(times[-1] - times_quad[-1]) / times_quad[-1]
            if times_quad[-1] > 0
            else 0
        )
        impact_vel_error = (
            abs(speed[-1] - speed_quad[-1]) / speed_quad[-1]
            if speed_quad[-1] > 0
            else 0
        )

        # RMS velocity error across trajectory
        x_common = np.linspace(0, min(x_quad[-1], x[-1]), 100)
        speed_quad_interp = np.interp(x_common, x_quad, speed_quad)
        speed_interp = np.interp(x_common, x, speed)
        rms_vel_error = (
            np.sqrt(np.mean((speed_interp - speed_quad_interp) ** 2))
            / shell.muzzle_velocity
        )

        # Weighted total error - prioritize RMS velocity match
        total_error = (
            0.1 * range_error
            + 0.1 * impact_vel_error
            + 0.1 * time_error
            + 0.7 * rms_vel_error
        )

        all_results.append(
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

    return {
        "optimal_beta": best_beta,
        "all_results": all_results,
    }


# =============================================================================
# INTERACTIVE APPLICATION
# =============================================================================
# PERSISTENT THREAD POOL WITH WORK-STEALING QUEUE
# =============================================================================

# De Marre constant for penetration calculation
_DE_MARRE_K = 0.06


def _calc_penetration(
    velocity: float, mass_kg: float, caliber_mm: float, impact_angle_deg: float
) -> float:
    """Calculate armor penetration using de Marre formula, adjusted for impact angle.

    The penetration is reduced by cos(impact_angle) to account for the effective
    thickness of armor at oblique angles.

    Args:
        velocity: Impact velocity in m/s
        mass_kg: Shell mass in kg
        caliber_mm: Shell diameter in mm
        impact_angle_deg: Impact angle in degrees (0 = horizontal, 90 = vertical)

    Returns:
        Effective penetration in mm
    """
    if velocity < 1.0:
        return 0.0
    base_penetration = (
        _DE_MARRE_K * pow(mass_kg, 0.55) * pow(velocity, 1.43) / pow(caliber_mm, 0.65)
    )
    # Apply cosine correction for oblique impact
    # Impact angle is measured from horizontal, so we use cos(impact_angle)
    angle_rad = np.radians(impact_angle_deg)
    angle_factor = np.cos(angle_rad)
    # Clamp to avoid negative or zero values at extreme angles
    angle_factor = max(0.1, angle_factor)
    return base_penetration * angle_factor


class SimulationWorkerPool:
    """Persistent thread pool with work-stealing queue for low-latency simulation updates.

    Keeps threads warm and ready to process work, avoiding thread creation overhead
    on each parameter update. Uses a work-stealing queue pattern where idle threads
    pick up available tasks.
    """

    def __init__(self, n_workers: int = 10):
        self.n_workers = n_workers
        self._task_queue: Queue = Queue()
        self._results: Dict[int, any] = {}
        self._results_lock = threading.Lock()
        self._pending_count = 0
        self._pending_lock = threading.Lock()
        self._completion_event = threading.Event()
        self._shutdown = False
        self._workers: List[threading.Thread] = []

        # Start persistent worker threads
        for i in range(n_workers):
            t = threading.Thread(target=self._worker_loop, daemon=True)
            t.start()
            self._workers.append(t)

    def _worker_loop(self):
        """Main loop for each worker thread - continuously steal work from queue."""
        while not self._shutdown:
            try:
                # Wait for work with timeout to allow checking shutdown flag
                task = self._task_queue.get(timeout=0.1)
            except Empty:
                continue

            if task is None:  # Shutdown signal
                break

            task_id, func, args = task
            try:
                result = func(args)
            except Exception as e:
                result = e

            # Store result
            with self._results_lock:
                self._results[task_id] = result

            # Decrement pending count and signal if all done
            with self._pending_lock:
                self._pending_count -= 1
                if self._pending_count == 0:
                    self._completion_event.set()

    def submit_batch(self, tasks: List[Tuple[Callable, tuple]]) -> List:
        """Submit a batch of tasks and wait for all to complete.

        Args:
            tasks: List of (function, args) tuples

        Returns:
            List of results in the same order as tasks
        """
        if not tasks:
            return []

        # Reset state for new batch
        with self._results_lock:
            self._results.clear()
        with self._pending_lock:
            self._pending_count = len(tasks)
        self._completion_event.clear()

        # Submit all tasks to the queue
        for task_id, (func, args) in enumerate(tasks):
            self._task_queue.put((task_id, func, args))

        # Wait for all tasks to complete
        self._completion_event.wait()

        # Collect results in order
        with self._results_lock:
            return [self._results[i] for i in range(len(tasks))]

    def shutdown(self):
        """Shutdown the worker pool."""
        self._shutdown = True
        # Send shutdown signals
        for _ in self._workers:
            self._task_queue.put(None)
        # Wait for workers to finish
        for t in self._workers:
            t.join(timeout=1.0)


# Global worker pool instance (created lazily)
_worker_pool: SimulationWorkerPool = None
_worker_pool_lock = threading.Lock()


def _get_worker_pool() -> SimulationWorkerPool:
    """Get or create the global worker pool."""
    global _worker_pool
    if _worker_pool is None:
        with _worker_pool_lock:
            if _worker_pool is None:
                _worker_pool = SimulationWorkerPool(n_workers=64)
    return _worker_pool


# =============================================================================
# SIMULATION WORKER FUNCTIONS
# =============================================================================


def _simulate_quadratic_chunk(args: Tuple) -> List[Tuple[int, dict]]:
    """Worker to simulate a chunk of angles for Quadratic simulator.

    Args:
        args: (chunk_indices, angles_rad, k_quadratic, muzzle_velocity, max_range, mass_kg, caliber_mm)
              where chunk_indices is a list of (idx, angle_rad) pairs

    Returns:
        List of (angle_idx, result_dict) tuples
    """
    (
        chunk_data,
        k_quadratic,
        muzzle_velocity,
        max_range,
        mass_kg,
        caliber_mm,
    ) = args

    sim = QuadraticDragSimulator(k_quadratic)
    results = []

    for angle_idx, angle_rad in chunk_data:
        times, traj = sim.simulate(muzzle_velocity, angle_rad, max_range=max_range)

        if len(traj) > 1 and (traj[-1, 1] <= 0 or traj[-1, 0] >= max_range):
            r = traj[-1, 0] / 1000
            vx, vy = traj[-1, 2], traj[-1, 3]
            impact_vel = np.sqrt(vx**2 + vy**2)
            impact_angle = np.degrees(np.arctan2(-vy, vx))

            results.append(
                (
                    angle_idx,
                    {
                        "range_km": r,
                        "impact_velocity": impact_vel,
                        "impact_angle": impact_angle,
                        "time": times[-1],
                        "angle_deg": np.degrees(angle_rad),
                        "penetration": _calc_penetration(
                            impact_vel, mass_kg, caliber_mm, impact_angle
                        ),
                    },
                )
            )
        else:
            results.append((angle_idx, None))

    return results


def _simulate_linear_all_angles(args: Tuple) -> Dict[str, List]:
    """Simulate all angles for Linear simulator (fast, no need to parallelize angles)."""
    (
        angles_rad,
        beta,
        gravity,
        time_warp_min_rate,
        time_warp_apex,
        muzzle_velocity,
        max_range,
        mass_kg,
        caliber_mm,
    ) = args

    result = {
        "ranges": [],
        "impact_velocities": [],
        "times": [],
        "angles": [],
        "impact_angles": [],
        "penetrations": [],
    }

    sim = LinearDragApproximation(
        beta,
        gravity=gravity,
        time_warp_min_rate=time_warp_min_rate,
        time_warp_apex=time_warp_apex,
    )

    prev_range = -1.0
    for angle_rad in angles_rad:
        times, traj = sim.simulate(muzzle_velocity, angle_rad, max_range=max_range)

        if len(traj) > 1 and (traj[-1, 1] <= 0 or traj[-1, 0] >= max_range):
            r = traj[-1, 0] / 1000
            if prev_range > 0 and r < prev_range:
                break
            prev_range = r

            vx, vy = traj[-1, 2], traj[-1, 3]
            impact_vel = np.sqrt(vx**2 + vy**2)
            impact_angle = np.degrees(np.arctan2(-vy, vx))

            result["ranges"].append(r)
            result["impact_velocities"].append(impact_vel)
            result["times"].append(times[-1])
            result["angles"].append(np.degrees(angle_rad))
            result["impact_angles"].append(impact_angle)
            result["penetrations"].append(
                _calc_penetration(impact_vel, mass_kg, caliber_mm, impact_angle)
            )

    return result


def _simulate_analytical_all_angles(args: Tuple) -> Dict[str, List]:
    """Simulate all angles for Analytical simulator (fast, no need to parallelize angles)."""
    (
        angles_rad,
        analytical_beta,
        gravity,
        muzzle_velocity,
        max_range,
        mass_kg,
        caliber_mm,
    ) = args

    result = {
        "ranges": [],
        "impact_velocities": [],
        "times": [],
        "angles": [],
        "impact_angles": [],
        "penetrations": [],
    }

    sim = AnalyticalDragSimulator(muzzle_velocity, analytical_beta, gravity)

    prev_range = -1.0
    for angle_rad in angles_rad:
        times, traj = sim.simulate(muzzle_velocity, angle_rad, max_range=max_range)

        if len(traj) > 1 and (traj[-1, 1] <= 0 or traj[-1, 0] >= max_range):
            r = traj[-1, 0] / 1000
            if prev_range > 0 and r < prev_range:
                break
            prev_range = r

            vx, vy = traj[-1, 2], traj[-1, 3]
            impact_vel = np.sqrt(vx**2 + vy**2)
            impact_angle = np.degrees(np.arctan2(-vy, vx))

            result["ranges"].append(r)
            result["impact_velocities"].append(impact_vel)
            result["times"].append(times[-1])
            result["angles"].append(np.degrees(angle_rad))
            result["impact_angles"].append(impact_angle)
            result["penetrations"].append(
                _calc_penetration(impact_vel, mass_kg, caliber_mm, impact_angle)
            )

    return result


def _compute_all_simulations_parallel(
    angles_rad: np.ndarray,
    k_quadratic: float,
    beta: float,
    gravity: float,
    time_warp_min_rate: float,
    time_warp_apex: float,
    analytical_beta: float,
    muzzle_velocity: float,
    max_range: float,
    mass_kg: float,
    caliber_mm: float,
) -> Dict[str, Dict[str, List]]:
    """Compute all simulations in parallel using persistent worker pool.

    Uses a pre-warmed thread pool with work-stealing queue for low latency.

    Chunked parallelism strategy:
    - Quadratic (slow, ~80% of time): split into 8 chunks
    - Linear (fast): single task for all angles
    - Analytical (fast): single task for all angles

    Total: 10 tasks distributed across persistent worker threads.

    Returns a dictionary with 'quadratic', 'linear', 'analytical' keys,
    each containing lists of ranges, impact_velocities, times, angles,
    impact_angles, and penetrations.
    """
    pool = _get_worker_pool()

    # Split Quadratic angles into 8 chunks
    n_chunks = 8
    angle_data = [(idx, angle_rad) for idx, angle_rad in enumerate(angles_rad)]
    chunk_size = (len(angle_data) + n_chunks - 1) // n_chunks
    chunks = [
        angle_data[i : i + chunk_size] for i in range(0, len(angle_data), chunk_size)
    ]

    # Build task list: (function, args) tuples
    # First 8 tasks are quadratic chunks, then linear, then analytical
    tasks = []

    # Quadratic chunk tasks
    for chunk in chunks:
        tasks.append(
            (
                _simulate_quadratic_chunk,
                (chunk, k_quadratic, muzzle_velocity, max_range, mass_kg, caliber_mm),
            )
        )

    # Linear task
    tasks.append(
        (
            _simulate_linear_all_angles,
            (
                angles_rad,
                beta,
                gravity,
                time_warp_min_rate,
                time_warp_apex,
                muzzle_velocity,
                max_range,
                mass_kg,
                caliber_mm,
            ),
        )
    )

    # Analytical task
    tasks.append(
        (
            _simulate_analytical_all_angles,
            (
                angles_rad,
                analytical_beta,
                gravity,
                muzzle_velocity,
                max_range,
                mass_kg,
                caliber_mm,
            ),
        )
    )

    # Submit all tasks to the persistent pool and wait for completion
    results = pool.submit_batch(tasks)

    # Parse results: first n_chunks are quadratic, then linear, then analytical
    quad_chunk_results = results[: len(chunks)]
    linear_result = results[len(chunks)]
    analytical_result = results[len(chunks) + 1]

    # Flatten quadratic chunk results
    quad_raw_results = []
    for chunk_result in quad_chunk_results:
        quad_raw_results.extend(chunk_result)

    # Process quadratic results: sort by angle index, stop when range decreases
    quad_result = {
        "ranges": [],
        "impact_velocities": [],
        "times": [],
        "angles": [],
        "impact_angles": [],
        "penetrations": [],
    }

    # Sort by angle index and filter
    quad_raw_results.sort(key=lambda x: x[0])
    prev_range = -1.0
    for angle_idx, data in quad_raw_results:
        if data is None:
            continue
        r = data["range_km"]
        if prev_range > 0 and r < prev_range:
            break
        prev_range = r

        quad_result["ranges"].append(r)
        quad_result["impact_velocities"].append(data["impact_velocity"])
        quad_result["times"].append(data["time"])
        quad_result["angles"].append(data["angle_deg"])
        quad_result["impact_angles"].append(data["impact_angle"])
        quad_result["penetrations"].append(data["penetration"])

    return {
        "quadratic": quad_result,
        "linear": linear_result,
        "analytical": analytical_result,
    }


class DragOptimizerApp:
    """Combined interactive optimization and tuning application."""

    def __init__(self, shell: ShellParameters):
        self.shell = shell
        self.k_quadratic = find_quadratic_drag_coefficient(shell)
        print(f"Found quadratic drag coefficient: k = {self.k_quadratic:.8f}")

        # Calculate maximum altitude and range for static axes
        self._update_axis_limits()

        # Initial parameter values
        self.beta = 0.015
        self.analytical_beta = 0.00005  # Beta for analytical simulator
        self.gravity = shell.linear_gravity
        self.time_warp_min_rate = shell.time_warp_min_rate
        self.time_warp_apex = shell.time_warp_apex
        self.launch_angle = np.degrees(shell.target_elevation)

        # Set up the figure with custom layout
        self.fig = plt.figure(figsize=(20, 14))
        self.fig.suptitle(
            f"Drag Optimizer - {shell.name} Shell", fontsize=14, fontweight="bold"
        )

        # Create main grid: left side for plots, right side for controls
        gs_main = gridspec.GridSpec(
            1, 2, figure=self.fig, width_ratios=[4, 1], wspace=0.15
        )

        # Left side: plots in 3 rows
        gs_plots = gridspec.GridSpecFromSubplotSpec(
            3,
            3,
            subplot_spec=gs_main[0],
            hspace=0.35,
            wspace=0.3,
            height_ratios=[1, 1, 0.6],
        )

        # Row 1: Trajectory and Velocity vs Time (2 plots spanning 1.5 columns each)
        self.ax_trajectory = self.fig.add_subplot(gs_plots[0, 0:2])
        self.ax_vel_time = self.fig.add_subplot(gs_plots[0, 2])

        # Row 2: Impact Velocity vs Range, Time of Flight vs Range, Angle vs Range
        self.ax_impact_vel = self.fig.add_subplot(gs_plots[1, 0])
        self.ax_tof = self.fig.add_subplot(gs_plots[1, 1])
        self.ax_angle_range = self.fig.add_subplot(gs_plots[1, 2])

        # Row 3: Impact Angle vs Range and Armor Penetration vs Range
        self.ax_impact_angle = self.fig.add_subplot(gs_plots[2, 0:2])
        self.ax_armor_pen = self.fig.add_subplot(gs_plots[2, 2])

        # Right side: controls
        gs_controls = gridspec.GridSpecFromSubplotSpec(
            12, 1, subplot_spec=gs_main[1], hspace=0.5
        )

        # Control section - optimize button at top
        self.ax_optimize = self.fig.add_subplot(gs_controls[0])
        self.ax_optimize.axis("off")
        self.btn_optimize = Button(
            plt.axes([0.84, 0.92, 0.12, 0.04]),
            "OPTIMIZE",
            color="lightgreen",
            hovercolor="green",
        )
        self.btn_optimize.on_clicked(self.optimize)

        # Reset button
        self.btn_reset = Button(
            plt.axes([0.84, 0.87, 0.12, 0.03]),
            "Reset",
            color="lightcoral",
            hovercolor="red",
        )
        self.btn_reset.on_clicked(self.reset)

        # Fit from Height button
        self.btn_fit_height = Button(
            plt.axes([0.84, 0.82, 0.12, 0.03]),
            "Fit from Height",
            color="lightyellow",
            hovercolor="yellow",
        )
        self.btn_fit_height.on_clicked(self.fit_from_height)

        # Track which fitting mode was used
        self.fit_mode = "range"  # "range" or "height"

        # Save button
        self.btn_save = Button(
            plt.axes([0.84, 0.77, 0.058, 0.03]),
            "Save",
            color="lightblue",
            hovercolor="deepskyblue",
        )
        self.btn_save.on_clicked(self.save_state)

        # Load button
        self.btn_load = Button(
            plt.axes([0.902, 0.77, 0.058, 0.03]),
            "Load",
            color="lightblue",
            hovercolor="deepskyblue",
        )
        self.btn_load.on_clicked(self.load_state)

        # Info text area - positioned above sliders
        self.ax_info = plt.axes([0.82, 0.68, 0.16, 0.08])
        self.ax_info.axis("off")
        self.info_text = self.ax_info.text(
            0.05,
            0.95,
            "",
            fontsize=8,
            verticalalignment="top",
            family="monospace",
            transform=self.ax_info.transAxes,
        )

        # Sliders - positioned on right side, compressed spacing
        slider_left = 0.83
        slider_width = 0.13
        slider_height = 0.02

        # Launch Angle slider
        self.ax_angle = plt.axes([slider_left, 0.60, slider_width, slider_height])
        self.slider_angle = Slider(
            self.ax_angle, "Angle (°)", 5, 85, valinit=self.launch_angle, valfmt="%.1f"
        )

        # Beta slider
        self.ax_beta = plt.axes([slider_left, 0.54, slider_width, slider_height])
        self.slider_beta = Slider(
            self.ax_beta, "Beta (β)", 0.005, 0.1, valinit=self.beta, valfmt="%.5f"
        )

        # Gravity slider
        self.ax_grav = plt.axes([slider_left, 0.48, slider_width, slider_height])
        self.slider_grav = Slider(
            self.ax_grav, "Gravity", 5.0, 20.0, valinit=self.gravity, valfmt="%.2f"
        )

        # Time Warp Min Rate slider
        self.ax_tw_rate = plt.axes([slider_left, 0.42, slider_width, slider_height])
        self.slider_tw_rate = Slider(
            self.ax_tw_rate,
            "TW Rate",
            0.5,
            1.0,
            valinit=self.time_warp_min_rate,
            valfmt="%.3f",
        )

        # Time Warp Apex slider
        self.ax_tw_apex = plt.axes([slider_left, 0.36, slider_width, slider_height])
        self.slider_tw_apex = Slider(
            self.ax_tw_apex,
            "TW Apex (s)",
            10,
            80,
            valinit=self.time_warp_apex,
            valfmt="%.1f",
        )

        # Analytical Beta slider (smaller range for analytical model)
        self.ax_analytical_beta = plt.axes(
            [slider_left, 0.30, slider_width * 0.65, slider_height]
        )
        self.slider_analytical_beta = Slider(
            self.ax_analytical_beta,
            "Anlyt β",
            0.00001,
            0.0001,
            valinit=self.analytical_beta,
            valfmt="%.6f",
        )

        # Analytical Beta text input box
        self.ax_analytical_beta_input = plt.axes(
            [slider_left + slider_width * 0.7, 0.30, slider_width * 0.3, slider_height]
        )
        self.textbox_analytical_beta = TextBox(
            self.ax_analytical_beta_input,
            "",
            initial=f"{self.analytical_beta:.6f}",
        )
        self.textbox_analytical_beta.on_submit(self._on_analytical_beta_text_submit)

        # Connect sliders to update function
        self.slider_angle.on_changed(self.update)
        self.slider_beta.on_changed(self.update)
        self.slider_grav.on_changed(self.update)
        self.slider_tw_rate.on_changed(self.update)
        self.slider_tw_apex.on_changed(self.update)
        self.slider_analytical_beta.on_changed(self._on_analytical_beta_slider_changed)

        # Parameter display area - positioned below analytical beta slider
        self.ax_params = plt.axes([0.82, 0.08, 0.16, 0.20])
        self.ax_params.axis("off")
        self.params_text = self.ax_params.text(
            0.05,
            0.95,
            "",
            fontsize=7,
            verticalalignment="top",
            family="monospace",
            transform=self.ax_params.transAxes,
        )

        # Initial plot
        self.update(None)

    def _on_analytical_beta_slider_changed(self, val):
        """Handle analytical beta slider change and sync text box."""
        self.analytical_beta = val
        # Update text box without triggering submit
        self.textbox_analytical_beta.set_val(f"{val:.6f}")
        self.update(None)

    def _on_analytical_beta_text_submit(self, text):
        """Handle analytical beta text input submission."""
        try:
            val = float(text)
            # Clamp to slider range
            val = max(0.00001, min(0.0001, val))
            self.analytical_beta = val
            # Update slider without triggering callback
            self.slider_analytical_beta.set_val(val)
            self.update(None)
        except ValueError:
            # Reset text box to current value if invalid input
            self.textbox_analytical_beta.set_val(f"{self.analytical_beta:.6f}")

    def update(self, val):
        """Update all plots when any slider changes."""
        # Get current slider values
        self.launch_angle = self.slider_angle.val
        self.beta = self.slider_beta.val
        self.gravity = self.slider_grav.val
        self.time_warp_min_rate = self.slider_tw_rate.val
        self.time_warp_apex = self.slider_tw_apex.val

        angle_rad = np.radians(self.launch_angle)

        # Run simulations for current angle (single trajectory plots)
        quad_sim = QuadraticDragSimulator(self.k_quadratic)
        times_quad, traj_quad = quad_sim.simulate(
            self.shell.muzzle_velocity, angle_rad, max_range=self.shell.max_range
        )

        linear_sim = LinearDragApproximation(
            self.beta,
            gravity=self.gravity,
            time_warp_min_rate=self.time_warp_min_rate,
            time_warp_apex=self.time_warp_apex,
        )
        times_lin, traj_lin = linear_sim.simulate(
            self.shell.muzzle_velocity, angle_rad, max_range=self.shell.max_range
        )

        # Analytical simulation (uses its own beta parameter)
        analytical_sim = AnalyticalDragSimulator(
            self.shell.muzzle_velocity, self.analytical_beta, self.gravity
        )
        times_analytical, traj_analytical = analytical_sim.simulate(
            self.shell.muzzle_velocity, angle_rad, max_range=self.shell.max_range
        )

        # Calculate speeds
        speed_quad = np.sqrt(traj_quad[:, 2] ** 2 + traj_quad[:, 3] ** 2)
        speed_lin = (
            np.sqrt(traj_lin[:, 2] ** 2 + traj_lin[:, 3] ** 2)
            if len(traj_lin) > 0
            else np.array([])
        )
        speed_analytical = (
            np.sqrt(traj_analytical[:, 2] ** 2 + traj_analytical[:, 3] ** 2)
            if len(traj_analytical) > 0
            else np.array([])
        )

        # Compute all multi-angle simulations in parallel
        # Use exponential distribution with more samples near 0 for some plots
        t = np.linspace(0, 1, 40)
        angles_exp_deg = 55 * (np.exp(t) - 1) / (np.exp(1) - 1)
        angles_exp_rad = np.radians(angles_exp_deg)

        # Compute parallel simulations for all plots
        self._cached_sim_results = _compute_all_simulations_parallel(
            angles_exp_rad,
            self.k_quadratic,
            self.beta,
            self.gravity,
            self.time_warp_min_rate,
            self.time_warp_apex,
            self.analytical_beta,
            self.shell.muzzle_velocity,
            self.shell.max_range,
            self.shell.mass,
            self.shell.caliber * 1000,  # Convert to mm
        )

        # Update all plots
        self._plot_trajectory(traj_quad, traj_lin, traj_analytical)
        self._plot_velocity_vs_time(
            times_quad,
            speed_quad,
            times_lin,
            speed_lin,
            times_analytical,
            speed_analytical,
        )
        self._plot_impact_velocity_vs_range()
        self._plot_tof_vs_range()
        self._plot_angle_vs_range()
        self._plot_impact_angle_vs_range()
        self._plot_armor_penetration_vs_range()

        # Update info text
        self._update_info(
            traj_quad, times_quad, speed_quad, traj_lin, times_lin, speed_lin
        )
        self._update_params()

        self.fig.canvas.draw_idle()

    def _update_axis_limits(self):
        """Calculate max altitude and range for static axes based on current k."""
        quad_sim = QuadraticDragSimulator(self.k_quadratic)

        # Max altitude at high angle (85°)
        _, traj_height = quad_sim.simulate(
            self.shell.muzzle_velocity, np.radians(85), max_range=self.shell.max_range
        )
        self.max_altitude_km = np.max(traj_height[:, 1]) / 1000 * 1.05  # 5% margin

        # Max range at optimal angle (~45° with drag, but check a range)
        max_range = 0
        for angle in np.linspace(30, 50, 10):
            _, traj_range = quad_sim.simulate(
                self.shell.muzzle_velocity,
                np.radians(angle),
                max_range=self.shell.max_range,
            )
            if len(traj_range) > 1:
                max_range = max(max_range, traj_range[-1, 0])
        self.max_range_km = max_range / 1000 * 1.05  # 5% margin

    def _plot_trajectory(self, traj_quad, traj_lin, traj_analytical=None):
        """Plot trajectory comparison (Row 1.1)"""
        self.ax_trajectory.clear()
        self.ax_trajectory.plot(
            traj_quad[:, 0] / 1000,
            traj_quad[:, 1] / 1000,
            "b-",
            linewidth=2,
            label="Quadratic",
        )
        if len(traj_lin) > 0:
            self.ax_trajectory.plot(
                traj_lin[:, 0] / 1000,
                traj_lin[:, 1] / 1000,
                "r--",
                linewidth=2,
                label="Linear",
            )
        if traj_analytical is not None and len(traj_analytical) > 0:
            self.ax_trajectory.plot(
                traj_analytical[:, 0] / 1000,
                traj_analytical[:, 1] / 1000,
                "g-.",
                linewidth=2,
                label="Analytical",
            )
        self.ax_trajectory.set_xlabel("Range (km)")
        self.ax_trajectory.set_ylabel("Altitude (km)")
        self.ax_trajectory.set_title(f"Trajectory at {self.launch_angle:.1f}°")
        self.ax_trajectory.legend(loc="upper right")
        self.ax_trajectory.grid(True, alpha=0.3)
        self.ax_trajectory.set_xlim(left=0, right=self.max_range_km)
        self.ax_trajectory.set_ylim(bottom=0, top=self.max_altitude_km)

    def _plot_velocity_vs_time(
        self,
        times_quad,
        speed_quad,
        times_lin,
        speed_lin,
        times_analytical=None,
        speed_analytical=None,
    ):
        """Plot velocity vs time (Row 1.2)"""
        self.ax_vel_time.clear()
        self.ax_vel_time.plot(
            times_quad, speed_quad, "b-", linewidth=2, label="Quadratic"
        )
        if len(times_lin) > 0 and len(speed_lin) > 0:
            self.ax_vel_time.plot(
                times_lin, speed_lin, "r--", linewidth=2, label="Linear"
            )
        if (
            times_analytical is not None
            and speed_analytical is not None
            and len(times_analytical) > 0
        ):
            self.ax_vel_time.plot(
                times_analytical,
                speed_analytical,
                "g-.",
                linewidth=2,
                label="Analytical",
            )
        self.ax_vel_time.set_xlabel("Time (s)")
        self.ax_vel_time.set_ylabel("Velocity (m/s)")
        self.ax_vel_time.set_title("Velocity vs Time")
        self.ax_vel_time.legend(loc="upper right", fontsize=8)
        self.ax_vel_time.grid(True, alpha=0.3)

    def _plot_impact_velocity_vs_range(self):
        """Plot impact velocity vs range over multiple angles (Row 2.1)"""
        self.ax_impact_vel.clear()

        # Use cached simulation results from parallel computation
        results = self._cached_sim_results

        self.ax_impact_vel.plot(
            results["quadratic"]["ranges"],
            results["quadratic"]["impact_velocities"],
            "b-",
            linewidth=2,
            label="Quadratic",
        )
        self.ax_impact_vel.plot(
            results["linear"]["ranges"],
            results["linear"]["impact_velocities"],
            "r--",
            linewidth=2,
            label="Linear",
        )
        self.ax_impact_vel.plot(
            results["analytical"]["ranges"],
            results["analytical"]["impact_velocities"],
            "g-.",
            linewidth=2,
            label="Analytical",
        )
        self.ax_impact_vel.set_xlabel("Range (km)")
        self.ax_impact_vel.set_ylabel("Impact Velocity (m/s)")
        self.ax_impact_vel.set_title("Impact Velocity vs Range")
        self.ax_impact_vel.legend(loc="best", fontsize=8)
        self.ax_impact_vel.grid(True, alpha=0.3)

    def _plot_tof_vs_range(self):
        """Plot time of flight vs range (Row 2.2)"""
        self.ax_tof.clear()

        # Use cached simulation results from parallel computation
        results = self._cached_sim_results

        self.ax_tof.plot(
            results["quadratic"]["ranges"],
            results["quadratic"]["times"],
            "b-",
            linewidth=2,
            label="Quadratic",
        )
        self.ax_tof.plot(
            results["linear"]["ranges"],
            results["linear"]["times"],
            "r--",
            linewidth=2,
            label="Linear",
        )
        self.ax_tof.plot(
            results["analytical"]["ranges"],
            results["analytical"]["times"],
            "g-.",
            linewidth=2,
            label="Analytical",
        )
        self.ax_tof.set_xlabel("Range (km)")
        self.ax_tof.set_ylabel("Time of Flight (s)")
        self.ax_tof.set_title("Time of Flight vs Range")
        self.ax_tof.legend(loc="best", fontsize=8)
        self.ax_tof.grid(True, alpha=0.3)

    def _plot_angle_vs_range(self):
        """Plot elevation angle vs range (Row 2.3)"""
        self.ax_angle_range.clear()

        # Use cached simulation results from parallel computation
        results = self._cached_sim_results

        self.ax_angle_range.plot(
            results["quadratic"]["ranges"],
            results["quadratic"]["angles"],
            "b-",
            linewidth=2,
            label="Quadratic",
        )
        self.ax_angle_range.plot(
            results["linear"]["ranges"],
            results["linear"]["angles"],
            "r--",
            linewidth=2,
            label="Linear",
        )
        self.ax_angle_range.plot(
            results["analytical"]["ranges"],
            results["analytical"]["angles"],
            "g-.",
            linewidth=2,
            label="Analytical",
        )
        self.ax_angle_range.set_xlabel("Range (km)")
        self.ax_angle_range.set_ylabel("Elevation Angle (°)")
        self.ax_angle_range.set_title("Firing Solution: Angle vs Range")
        self.ax_angle_range.legend(loc="best", fontsize=8)
        self.ax_angle_range.grid(True, alpha=0.3)

    def _calculate_de_marre_penetration(
        self, mass_kg: float, velocity_ms: float, caliber_mm: float
    ) -> float:
        """Calculate penetration using de Marre formula (metric)
        mass_kg: shell mass in kg
        velocity_ms: impact velocity in m/s
        caliber_mm: shell diameter in mm
        Returns: penetration in mm
        """
        DE_MARRE_K = 0.06
        if velocity_ms < 1.0:
            return 0.0
        return (
            DE_MARRE_K
            * pow(mass_kg, 0.55)
            * pow(velocity_ms, 1.43)
            / pow(caliber_mm, 0.65)
        )

    def _plot_impact_angle_vs_range(self):
        """Plot impact angle vs range (Row 3.1)"""
        self.ax_impact_angle.clear()

        # Use cached simulation results from parallel computation
        results = self._cached_sim_results

        self.ax_impact_angle.plot(
            results["quadratic"]["ranges"],
            results["quadratic"]["impact_angles"],
            "b-",
            linewidth=2,
            label="Quadratic",
        )
        self.ax_impact_angle.plot(
            results["linear"]["ranges"],
            results["linear"]["impact_angles"],
            "r--",
            linewidth=2,
            label="Linear",
        )
        self.ax_impact_angle.plot(
            results["analytical"]["ranges"],
            results["analytical"]["impact_angles"],
            "g-.",
            linewidth=2,
            label="Analytical",
        )
        self.ax_impact_angle.set_xlabel("Range (km)")
        self.ax_impact_angle.set_ylabel("Impact Angle (°)")
        self.ax_impact_angle.set_title("Impact Angle vs Range")
        self.ax_impact_angle.legend(loc="best", fontsize=8)
        self.ax_impact_angle.grid(True, alpha=0.3)

    def _plot_armor_penetration_vs_range(self):
        """Plot armor penetration vs range using de Marre formula (Row 3.2)"""
        self.ax_armor_pen.clear()

        # Use cached simulation results from parallel computation
        results = self._cached_sim_results

        self.ax_armor_pen.plot(
            results["quadratic"]["ranges"],
            results["quadratic"]["penetrations"],
            "b-",
            linewidth=2,
            label="Quadratic",
        )
        self.ax_armor_pen.plot(
            results["linear"]["ranges"],
            results["linear"]["penetrations"],
            "r--",
            linewidth=2,
            label="Linear",
        )
        self.ax_armor_pen.plot(
            results["analytical"]["ranges"],
            results["analytical"]["penetrations"],
            "g-.",
            linewidth=2,
            label="Analytical",
        )
        self.ax_armor_pen.set_xlabel("Range (km)")
        self.ax_armor_pen.set_ylabel("Penetration (mm)")
        self.ax_armor_pen.set_title("Armor Penetration vs Range (de Marre)")
        self.ax_armor_pen.legend(loc="best", fontsize=8)
        self.ax_armor_pen.grid(True, alpha=0.3)

    def _update_info(
        self, traj_quad, times_quad, speed_quad, traj_lin, times_lin, speed_lin
    ):
        """Update info text with current comparison results."""
        if len(traj_lin) > 0 and len(speed_lin) > 0:
            range_quad = traj_quad[-1, 0]
            range_lin = traj_lin[-1, 0]
            range_err = (
                (range_lin - range_quad) / range_quad * 100 if range_quad > 0 else 0
            )

            time_quad = times_quad[-1]
            time_lin = times_lin[-1]
            time_err = (time_lin - time_quad) / time_quad * 100 if time_quad > 0 else 0

            impact_vel_quad = speed_quad[-1]
            impact_vel_lin = speed_lin[-1]
            vel_err = (
                (impact_vel_lin - impact_vel_quad) / impact_vel_quad * 100
                if impact_vel_quad > 0
                else 0
            )

            info = (
                f"Current Angle: {self.launch_angle:.1f}°\n"
                f"─────────────────\n"
                f"Range: {range_lin / 1000:.2f}km\n"
                f"  Error: {range_err:+.2f}%\n"
                f"Time: {time_lin:.1f}s\n"
                f"  Error: {time_err:+.2f}%\n"
                f"Impact: {impact_vel_lin:.0f}m/s\n"
                f"  Error: {vel_err:+.2f}%"
            )
        else:
            info = "No valid trajectory"

        self.info_text.set_text(info)

    def _update_params(self):
        """Update parameter display."""
        fit_mode_str = getattr(self, "fit_mode", "range")
        params = (
            f"CURRENT PARAMETERS\n"
            f"══════════════════\n"
            f"k (quad): {self.k_quadratic:.8f}\n"
            f"  fit: {fit_mode_str}\n"
            f"β (lin):  {self.beta:.6f}\n"
            f"β (anly): {self.analytical_beta:.6f}\n"
            f"gravity:  {self.gravity:.2f} m/s²\n"
            f"TW rate:  {self.time_warp_min_rate:.3f}\n"
            f"TW apex:  {self.time_warp_apex:.1f}s\n"
            f"\n"
            f"SHELL: {self.shell.name}\n"
            f"──────────────────\n"
            f"Muzzle: {self.shell.muzzle_velocity:.0f} m/s\n"
            f"Max rng: {self.shell.max_range / 1000:.0f} km"
        )
        self.params_text.set_text(params)

    def optimize(self, event):
        """Run optimization and set sliders to optimal values."""
        print("Running optimization...")

        # Optimize beta with current gravity and time warp settings
        opt_results = optimize_linear_drag(
            self.shell,
            self.k_quadratic,
            self.gravity,
            self.time_warp_min_rate,
            self.time_warp_apex,
        )

        if opt_results["optimal_beta"] is not None:
            optimal_beta = opt_results["optimal_beta"]
            print(f"Optimal β = {optimal_beta:.6f}")

            # Set slider to optimal value (this triggers update)
            self.slider_beta.set_val(optimal_beta)
        else:
            print("Optimization failed to find optimal beta")

    def reset(self, event):
        """Reset all sliders to initial values."""
        # Reset to range-based fitting
        self.k_quadratic = find_quadratic_drag_coefficient(self.shell, use_height=False)
        self.fit_mode = "range"
        print(f"Reset to range-based fitting: k = {self.k_quadratic:.8f}")

        # Recalculate axis limits for new k
        self._update_axis_limits()

        self.slider_angle.set_val(np.degrees(self.shell.target_elevation))
        self.slider_beta.set_val(0.015)
        self.slider_grav.set_val(self.shell.linear_gravity)
        self.slider_tw_rate.set_val(self.shell.time_warp_min_rate)
        self.slider_tw_apex.set_val(self.shell.time_warp_apex)

    def fit_from_height(self, event):
        """Recalculate quadratic drag coefficient from max height data."""
        # Check if any data point has max_height specified
        has_height_data = any(dp.max_height > 0 for dp in self.shell.data_points)

        if has_height_data:
            # Use height-prioritized fitting
            self.k_quadratic = find_quadratic_drag_coefficient(
                self.shell, use_height=True
            )
            self.fit_mode = "height"
            print(f"Fitted from height data: k = {self.k_quadratic:.8f}")
        else:
            # Use current angle and calculate from trajectory apex
            angle_rad = np.radians(self.launch_angle)

            # First, simulate with a reference k to get a height to match
            # Then ask user or use a heuristic
            # For now, use the current trajectory's max height as target
            # and find k that produces it at 45 degrees (optimal height angle)

            # Alternative: Calculate from first data point's expected trajectory
            if self.shell.data_points:
                dp = self.shell.data_points[0]
                # Estimate max height from range and angle using ballistic formula
                # For high drag, max height is roughly: h ≈ range * tan(angle) / 4
                estimated_height = dp.range * np.tan(dp.elevation) / 3

                self.k_quadratic = find_quadratic_drag_from_height(
                    self.shell.muzzle_velocity,
                    dp.elevation,
                    estimated_height,
                )
                self.fit_mode = "height (estimated)"
                print(
                    f"Fitted from estimated height ({estimated_height:.0f}m): k = {self.k_quadratic:.8f}"
                )
            else:
                print("No data points available for height fitting")
                return

        # Recalculate axis limits for new k
        self._update_axis_limits()

        # Trigger update
        self.update(None)

    def save_state(self, event=None):
        """Save current working conditions to a JSON file."""
        state = {
            "shell_name": self.shell.name,
            "k_quadratic": self.k_quadratic,
            "fit_mode": self.fit_mode,
            "beta": self.beta,
            "analytical_beta": self.analytical_beta,
            "gravity": self.gravity,
            "time_warp_min_rate": self.time_warp_min_rate,
            "time_warp_apex": self.time_warp_apex,
            "launch_angle": self.launch_angle,
        }

        try:
            with open(SAVE_FILE, "w") as f:
                json.dump(state, f, indent=2)
            print(f"State saved to {SAVE_FILE}")
        except Exception as e:
            print(f"Error saving state: {e}")

    def load_state(self, event=None):
        """Load working conditions from a JSON file."""
        if not SAVE_FILE.exists():
            print(f"No save file found at {SAVE_FILE}")
            return

        try:
            with open(SAVE_FILE, "r") as f:
                state = json.load(f)

            # Check if the saved state is for the same shell
            if state.get("shell_name") != self.shell.name:
                print(
                    f"Warning: Saved state is for {state.get('shell_name')}, "
                    f"current shell is {self.shell.name}"
                )

            # Restore k_quadratic and fit_mode
            if "k_quadratic" in state:
                self.k_quadratic = state["k_quadratic"]
            if "fit_mode" in state:
                self.fit_mode = state["fit_mode"]

            # Recalculate axis limits for loaded k
            self._update_axis_limits()

            # Restore slider values (this will trigger updates)
            if "launch_angle" in state:
                self.slider_angle.set_val(state["launch_angle"])
            if "beta" in state:
                self.slider_beta.set_val(state["beta"])
            if "gravity" in state:
                self.slider_grav.set_val(state["gravity"])
            if "time_warp_min_rate" in state:
                self.slider_tw_rate.set_val(state["time_warp_min_rate"])
            if "time_warp_apex" in state:
                self.slider_tw_apex.set_val(state["time_warp_apex"])
            if "analytical_beta" in state:
                self.analytical_beta = state["analytical_beta"]
                self.slider_analytical_beta.set_val(state["analytical_beta"])
                self.textbox_analytical_beta.set_val(f"{state['analytical_beta']:.6f}")

            print(f"State loaded from {SAVE_FILE}")
            print(f"  k = {self.k_quadratic:.8f} (fit: {self.fit_mode})")
            print(f"  β = {self.beta:.6f}")
            print(f"  β (analytical) = {self.analytical_beta:.6f}")

        except Exception as e:
            print(f"Error loading state: {e}")

    def run(self):
        """Start the application."""
        # Try to auto-load previous state
        if SAVE_FILE.exists():
            print(f"Found saved state at {SAVE_FILE}")
            self.load_state()

        plt.show()


# =============================================================================
# MAIN
# =============================================================================


def main():
    print("=" * 60)
    print("DRAG OPTIMIZER APPLICATION")
    print("=" * 60)
    print(f"Shell: {CURRENT_SHELL.name}")
    print(f"  Caliber: {CURRENT_SHELL.caliber * 1000:.0f}mm")
    print(f"  Mass: {CURRENT_SHELL.mass:.0f}kg")
    print(f"  Muzzle Velocity: {CURRENT_SHELL.muzzle_velocity:.0f}m/s")
    print(f"  Max Range: {CURRENT_SHELL.max_range / 1000:.1f}km")
    if CURRENT_SHELL.data_points:
        print(f"  Data Points: {len(CURRENT_SHELL.data_points)}")
        for i, dp in enumerate(CURRENT_SHELL.data_points):
            print(
                f"    {i + 1}. {np.degrees(dp.elevation):.1f}° -> {dp.range / 1000:.1f}km, {dp.time:.1f}s, {dp.impact_velocity:.0f}m/s"
            )
    print("=" * 60)
    print("\nControls:")
    print("  - Adjust sliders to tune linear drag parameters")
    print("  - Click OPTIMIZE to find best beta for current settings")
    print("  - Blue = Quadratic (reference), Red = Linear (tunable)")
    print()

    app = DragOptimizerApp(CURRENT_SHELL)
    app.run()


if __name__ == "__main__":
    main()
