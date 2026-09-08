use std::f64::consts::PI;

use godot::prelude::*;

use super::{DesiredDirection, ShipNavigator};
use crate::nav::types::{
    angle_difference, clamp_f, lerp_f, move_toward_f, normalize_angle, ArcPoint,
    ObstacleCollisionInfo,
};

impl ShipNavigator {
    /// Emits arc sample points spaced by get_ship_clearance().
    pub(crate) fn predict_arc_internal(
        &self,
        commanded_rudder: f32,
        commanded_throttle: i32,
        lookahead_distance: f32,
    ) -> Vec<ArcPoint> {
        let mut arc: Vec<ArcPoint> = Vec::with_capacity(64);

        let mut sim_rudder = self.state.current_rudder;
        let mut sim_speed = self.state.current_speed;
        let mut sim_heading = self.state.heading;
        let mut sim_pos = self.state.position;
        let mut sim_time: f32 = 0.0;
        let mut total_distance: f32 = 0.0;

        // --- Drift model: decompose current velocity into forward and lateral ---
        // The heading unit vector (forward direction in XZ)
        let fwd_x0 = self.state.heading.sin();
        let fwd_z0 = self.state.heading.cos();
        // Lateral (starboard) unit vector: rotate forward 90° clockwise
        let lat_x0 = fwd_z0;
        let lat_z0 = -fwd_x0;
        // Project actual velocity onto forward and lateral axes
        // lateral > 0 means drifting to starboard
        let mut sim_lateral_speed = self.state.velocity.x * lat_x0 + self.state.velocity.y * lat_z0;

        let target_speed_val = self.throttle_to_speed(commanded_throttle);

        arc.push(ArcPoint::new(sim_pos, sim_heading, sim_speed, 0.0));

        let base_dt: f32 = 0.1;
        let integration_dt: f32 =
            (base_dt * (self.params.rudder_response_time / 4.0).max(1.0)).min(0.5);
        let emit_interval = self.get_ship_clearance();
        let mut next_emit_dist = emit_interval;
        let mut prev_pos = sim_pos;

        let min_expected_speed = self
            .state
            .current_speed
            .abs()
            .max(self.params.max_speed * 0.25);
        let time_for_lookahead = lookahead_distance / min_expected_speed.max(1.0);
        let effective_max_time = (time_for_lookahead * 1.2).max(30.0);

        // Bow-pivot fractions mirror ShipMovementV4 constants.
        const BOW_PIVOT_FRACTION_LOW: f32 = 0.9;
        const BOW_PIVOT_FRACTION_HIGH: f32 = 1.1;

        while total_distance < lookahead_distance && sim_time < effective_max_time {
            let mut dt = integration_dt;
            if sim_time + dt > effective_max_time {
                dt = effective_max_time - sim_time;
            }
            if dt < 0.001 {
                break;
            }

            if self.params.rudder_response_time > 0.001 {
                sim_rudder = move_toward_f(
                    sim_rudder,
                    commanded_rudder,
                    dt / self.params.rudder_response_time,
                );
            } else {
                sim_rudder = commanded_rudder;
            }

            if target_speed_val > sim_speed {
                let accel_rate = self.params.max_speed / self.params.acceleration_time.max(0.1);
                sim_speed = move_toward_f(sim_speed, target_speed_val, dt * accel_rate);
            } else {
                let decel_rate = self.params.max_speed / self.params.deceleration_time.max(0.1);
                sim_speed = move_toward_f(sim_speed, target_speed_val, dt * decel_rate);
            }

            let effective_speed = sim_speed * (1.0 - self.params.turn_speed_loss * sim_rudder.abs());

            let mut omega: f32 = 0.0;
            if self.params.turning_circle_radius > 0.001 {
                omega = (effective_speed / self.params.turning_circle_radius) * (-sim_rudder);
            }

            sim_heading += omega * dt;
            sim_heading = normalize_angle(sim_heading);

            // --- Bow-pivot lateral velocity model (matches ShipMovementV4) ---
            // The kinematic pivot sits (ship_length/2 * bow_pivot_fraction) ahead of the COM.
            // drift_scale ramps 0→1 with speed, gating the pivot effect at low speed.
            // target_lat_vel = omega * pivot_dist, matching GDScript's target_lat_vel exactly.
            // Lateral speed converges to target with time constant = rudder_response_time,
            // matching GDScript: pivot_force = lat_vel_error * mass / rudder_response_time.
            let drift_scale = (sim_speed.abs() / self.params.max_speed.max(0.1))
                .max(0.0)
                .min(1.0);
            let bow_pivot_fraction = BOW_PIVOT_FRACTION_LOW
                + (BOW_PIVOT_FRACTION_HIGH - BOW_PIVOT_FRACTION_LOW) * drift_scale;
            let target_lat_vel =
                omega * (self.params.ship_length * 0.5) * bow_pivot_fraction * drift_scale;
            sim_lateral_speed += (target_lat_vel - sim_lateral_speed)
                * (1.0 - (-dt / self.params.rudder_response_time.max(0.01)).exp());

            // Forward movement along heading + lateral drift perpendicular to heading
            let cur_fwd_x = sim_heading.sin();
            let cur_fwd_z = sim_heading.cos();
            let cur_lat_x = cur_fwd_z; // starboard = forward rotated 90° CW
            let cur_lat_z = -cur_fwd_x;
            sim_pos.x += cur_fwd_x * effective_speed * dt + cur_lat_x * sim_lateral_speed * dt;
            sim_pos.y += cur_fwd_z * effective_speed * dt + cur_lat_z * sim_lateral_speed * dt;

            sim_time += dt;

            let step_dist = sim_pos.distance_to(prev_pos);
            total_distance += step_dist;
            prev_pos = sim_pos;

            if total_distance >= next_emit_dist || total_distance >= lookahead_distance - 0.1 {
                arc.push(ArcPoint::new(sim_pos, sim_heading, sim_speed, sim_time));
                next_emit_dist += emit_interval;
            }
        }

        if arc.len() < 2 || arc.last().unwrap().position.distance_to(sim_pos) > 1.0 {
            arc.push(ArcPoint::new(sim_pos, sim_heading, sim_speed, sim_time));
        }

        arc
    }

    pub(crate) fn predict_arc_to_heading(
        &self,
        commanded_rudder: f32,
        commanded_throttle: i32,
        target_pos: Vector2,
        lookahead_distance: f32,
        max_time: f32,
        reverse_alignment: bool,
    ) -> Vec<ArcPoint> {
        let mut arc: Vec<ArcPoint> = Vec::with_capacity(64);

        let mut sim_rudder = self.state.current_rudder;
        let mut sim_speed = self.state.current_speed;
        let mut sim_heading = self.state.heading;
        let mut sim_pos = self.state.position;
        let mut sim_time: f32 = 0.0;
        let mut total_distance: f32 = 0.0;

        // --- Drift model: decompose current velocity into forward and lateral ---
        let fwd_x0 = self.state.heading.sin();
        let fwd_z0 = self.state.heading.cos();
        let lat_x0 = fwd_z0;
        let lat_z0 = -fwd_x0;
        let mut sim_lateral_speed = self.state.velocity.x * lat_x0 + self.state.velocity.y * lat_z0;

        let target_speed_val = self.throttle_to_speed(commanded_throttle);

        arc.push(ArcPoint::new(sim_pos, sim_heading, sim_speed, 0.0));

        // 2.0f * Math::PI * radius: float promotes to double for the whole
        // expression (Math::PI is double), then narrows on assignment.
        let turning_circle_perimeter =
            (2.0f64 * PI * self.params.turning_circle_radius as f64) as f32;
        let max_arc_distance = lookahead_distance.max(turning_circle_perimeter);

        let base_dt: f32 = 0.1;
        let integration_dt: f32 =
            (base_dt * (self.params.rudder_response_time / 4.0).max(1.0)).min(0.5);
        let emit_interval = self.get_ship_clearance();
        let mut next_emit_dist = emit_interval;

        let alignment_threshold: f32 = 0.087;
        let mut rudder_settled = false;

        // Bow-pivot fractions mirror ShipMovementV4 constants.
        const BOW_PIVOT_FRACTION_LOW: f32 = 0.9;
        const BOW_PIVOT_FRACTION_HIGH: f32 = 1.1;

        // Simulate at the commanded rudder until the bow aligns with the direction
        // to target_pos, then stop.  Remaining travel is estimated analytically in
        // select_best_steering (endpoint_dist / speed).  The post-alignment straight
        // segment was removed: it rarely passed accurately through the waypoint
        // (5° threshold leaves a residual cross-track error), so both left- and
        // right-turn candidates landed at nearly identical endpoint distances and
        // produced frame-to-frame oscillation.
        while sim_time < max_time && total_distance < max_arc_distance {
            let mut dt = integration_dt;
            if sim_time + dt > max_time {
                dt = max_time - sim_time;
            }
            if dt < 0.001 {
                break;
            }

            if self.params.rudder_response_time > 0.001 {
                sim_rudder = move_toward_f(
                    sim_rudder,
                    commanded_rudder,
                    dt / self.params.rudder_response_time,
                );
            } else {
                sim_rudder = commanded_rudder;
            }

            if !rudder_settled && (sim_rudder - commanded_rudder).abs() < 0.01 {
                rudder_settled = true;
            }

            if target_speed_val > sim_speed {
                let accel_rate = self.params.max_speed / self.params.acceleration_time.max(0.1);
                sim_speed = move_toward_f(sim_speed, target_speed_val, dt * accel_rate);
            } else {
                let decel_rate = self.params.max_speed / self.params.deceleration_time.max(0.1);
                sim_speed = move_toward_f(sim_speed, target_speed_val, dt * decel_rate);
            }

            let effective_speed = sim_speed * (1.0 - self.params.turn_speed_loss * sim_rudder.abs());

            let mut omega: f32 = 0.0;
            if self.params.turning_circle_radius > 0.001 {
                omega = (effective_speed / self.params.turning_circle_radius) * (-sim_rudder);
            }

            sim_heading += omega * dt;
            sim_heading = normalize_angle(sim_heading);

            // --- Bow-pivot lateral velocity model (matches ShipMovementV4) ---
            let drift_scale = (sim_speed.abs() / self.params.max_speed.max(0.1))
                .max(0.0)
                .min(1.0);
            let bow_pivot_fraction = BOW_PIVOT_FRACTION_LOW
                + (BOW_PIVOT_FRACTION_HIGH - BOW_PIVOT_FRACTION_LOW) * drift_scale;
            let target_lat_vel =
                omega * (self.params.ship_length * 0.5) * bow_pivot_fraction * drift_scale;
            sim_lateral_speed += (target_lat_vel - sim_lateral_speed)
                * (1.0 - (-dt / self.params.rudder_response_time.max(0.01)).exp());

            let cur_fwd_x = sim_heading.sin();
            let cur_fwd_z = sim_heading.cos();
            let cur_lat_x = cur_fwd_z;
            let cur_lat_z = -cur_fwd_x;
            sim_pos.x += cur_fwd_x * effective_speed * dt + cur_lat_x * sim_lateral_speed * dt;
            sim_pos.y += cur_fwd_z * effective_speed * dt + cur_lat_z * sim_lateral_speed * dt;

            sim_time += dt;

            // step_dist: fwd and lat basis vectors are orthogonal unit vectors so the
            // magnitude of the displacement is exactly dt * hypot(effective_speed, sim_lateral_speed).
            // This avoids tracking prev_pos and calling distance_to (which also does a sqrt).
            let step_dist = dt
                * (effective_speed * effective_speed + sim_lateral_speed * sim_lateral_speed)
                    .sqrt();
            total_distance += step_dist;

            if total_distance >= next_emit_dist {
                arc.push(ArcPoint::new(sim_pos, sim_heading, sim_speed, sim_time));
                next_emit_dist += emit_interval;

                // Check alignment at emit points only (atan2 is expensive).
                // Stop as soon as the bow points at the target — the scoring in
                // select_best_steering estimates the remaining travel analytically.
                if rudder_settled {
                    let to_target = target_pos - sim_pos;
                    if to_target.length() > 1.0 {
                        let mut desired_heading = to_target.x.atan2(to_target.y);
                        // For reverse arcs, check that the bow faces AWAY from the
                        // target (i.e. stern faces the target) rather than bow-toward.
                        // Math::PI is explicitly cast to float here (unlike the
                        // compute_rudder_to_position case), so this is a plain
                        // float + float addition — no double promotion.
                        if reverse_alignment {
                            desired_heading = normalize_angle(desired_heading + PI as f32);
                        }
                        let heading_error = angle_difference(sim_heading, desired_heading).abs();
                        if heading_error < alignment_threshold {
                            break;
                        }
                    }
                }
            }
        }

        if arc.len() < 2 || arc.last().unwrap().position.distance_to(sim_pos) > 1.0 {
            arc.push(ArcPoint::new(sim_pos, sim_heading, sim_speed, sim_time));
        }

        arc
    }

    pub(crate) fn check_arc_collision(
        &self,
        arc: &[ArcPoint],
        hard_clearance: f32,
        soft_clearance: f32,
    ) -> f32 {
        if self.map.is_none() {
            return f32::INFINITY;
        }
        // Bind once — this function samples the SDF for every arc point.
        let map = self.map.as_ref().unwrap().bind();
        if !map.is_built() {
            return f32::INFINITY;
        }
        if arc.is_empty() {
            return f32::INFINITY;
        }

        let mut first_soft_violation = f32::INFINITY;
        let mut arc_exits_soft_zone = false;
        let mut was_in_soft_zone = false;
        let mut valid_points: i32 = 0;

        for i in 0..arc.len() {
            let pt = &arc[i];
            let sdf = map.get_distance_impl(pt.position.x, pt.position.y);

            if sdf < hard_clearance {
                if pt.time == 0.0 {
                    // Already inside hard clearance — find time to exit and negate it.
                    // More negative = longer to escape = worse.
                    for j in (i + 1)..arc.len() {
                        let exit_sdf = map.get_distance_impl(arc[j].position.x, arc[j].position.y);
                        if exit_sdf >= hard_clearance {
                            return -arc[j].time;
                        }
                    }
                    // Never escaped — return negative arc duration (worst case)
                    return -arc.last().unwrap().time;
                }
                return pt.time;
            }

            if sdf < soft_clearance {
                if !was_in_soft_zone {
                    was_in_soft_zone = true;
                }
                if first_soft_violation > pt.time {
                    first_soft_violation = pt.time;
                }
            } else {
                if was_in_soft_zone {
                    arc_exits_soft_zone = true;
                }
                valid_points += 1;
            }
        }

        if was_in_soft_zone && !arc_exits_soft_zone && valid_points < 3 {
            // If the first soft violation is at t=0, the arc starts inside the
            // soft zone.  Find exit time and negate it, same as the hard case.
            if first_soft_violation == 0.0 {
                for i in 0..arc.len() {
                    let sdf = map.get_distance_impl(arc[i].position.x, arc[i].position.y);
                    if sdf >= soft_clearance {
                        return -arc[i].time;
                    }
                }
                return -arc.last().unwrap().time;
            }
            return first_soft_violation;
        }

        f32::INFINITY
    }

    pub(crate) fn check_arc_obstacles_detailed(&self, arc: &[ArcPoint]) -> ObstacleCollisionInfo {
        let mut result = ObstacleCollisionInfo::default();

        // Safety margin added to our OBB on every face so the ship maintains a
        // small buffer beyond hull-to-hull contact.
        let margin = self.params.ship_beam * 0.5;
        let our_hl = self.params.ship_length * 0.5 + margin;
        let our_hb = self.params.ship_beam * 0.5 + margin;

        // Fallback circle clearance for torpedo obstacles (no orientation info).
        let torp_clearance = self.get_ship_clearance();

        // NOTE: iterates self.obstacles (a HashMap<i32, DynamicObstacle>) in
        // Rust's HashMap order, which differs from C++'s unordered_map order.
        // If two obstacles produce a collision at exactly the same pt.time,
        // the `pt.time < result.time_to_collision` tiebreak below means
        // whichever is visited FIRST wins ties, and that first-visited
        // obstacle can differ between the two languages. Flagging per
        // instructions; not fixing.
        for (&id, obs) in self.obstacles.iter() {
            // When parked, skip non-torpedo obstacles — the moving ship should
            // be the one that avoids, not a stationary ship holding position.
            if self.skip_ship_obstacles && !obs.is_torpedo() {
                continue;
            }

            for pt in arc {
                let obs_pos = obs.position + obs.velocity * pt.time;
                let collision;

                if obs.length > 0.0 {
                    // Ship obstacle: OBB-OBB separating axis test.
                    // obs.radius is the obstacle's half-beam; obs.length is its full length.
                    // The obstacle heading is kept up-to-date by update_obstacle().
                    collision = obb_obb_overlap_2d(
                        pt.position,
                        pt.heading,
                        our_hl,
                        our_hb,
                        obs_pos,
                        obs.heading,
                        obs.length * 0.5,
                        obs.radius,
                    );
                } else {
                    // Torpedo (or unknown circular obstacle): fall back to circle test.
                    let dist = pt.position.distance_to(obs_pos);
                    collision = dist < torp_clearance + obs.radius;
                }

                if collision {
                    if pt.time < result.time_to_collision {
                        result.has_collision = true;
                        result.time_to_collision = pt.time;
                        result.obstacle_id = id;
                        result.obstacle_length = obs.length;
                        result.obstacle_position = obs_pos;
                        result.obstacle_velocity = obs.velocity;
                        result.is_torpedo = obs.is_torpedo();

                        let to_obs = obs_pos - self.state.position;
                        let bearing_to_obs = to_obs.x.atan2(to_obs.y);
                        result.relative_bearing = angle_difference(self.state.heading, bearing_to_obs);
                    }
                    break;
                }
            }
        }

        result
    }

    pub(crate) fn compute_rudder_to_position(&self, target_pos: Vector2, reverse: bool) -> f32 {
        let to_target = target_pos - self.state.position;
        let target_angle = to_target.x.atan2(to_target.y);

        if reverse {
            // Desired bow direction: pointing away from target so stern faces target.
            // Math::PI here is NOT cast to float before the addition, so the sum
            // is computed in double precision and narrowed only when passed into
            // normalize_angle's float parameter.
            let bow_away = normalize_angle((target_angle as f64 + PI) as f32);
            return self.compute_rudder_to_heading(bow_away, true);
        }

        self.compute_rudder_to_heading(target_angle, false)
    }

    pub(crate) fn compute_rudder_to_heading(&self, desired_heading: f32, reverse: bool) -> f32 {
        let angle_diff = angle_difference(self.state.heading, desired_heading);
        let abs_diff = angle_diff.abs();

        let rudder_travel_time =
            (0.0 - self.state.current_rudder).abs() * self.params.rudder_response_time;
        let heading_drift = self.state.angular_velocity_y * rudder_travel_time;

        let effective_target = desired_heading - heading_drift * 0.5;
        let effective_diff = angle_difference(self.state.heading, effective_target);
        let abs_effective_diff = effective_diff.abs();

        let mut rudder;

        // Math::PI / 6.0: double / double, cast to float on assignment.
        let full_rudder_threshold: f32 = (PI / 6.0) as f32;

        if abs_effective_diff < 0.02 {
            rudder = 0.0;
        } else if abs_effective_diff > full_rudder_threshold {
            // --- Near-180° stability fix ---
            // When abs_effective_diff is near ±π the sign of effective_diff is
            // unreliable: a sub-ULP perturbation in the ship's position flips
            // angle_difference() between +π and −π, causing the rudder to
            // alternate between −1 and +1 every frame (net ≈ 0, so the ship
            // drives straight away from the target).
            // Use state continuity as tiebreaker: current_rudder → angular
            // velocity → deterministic default.
            // Convention: negative rudder = right turn = positive angular_velocity_y.
            let near_pi_threshold: f32 = (PI * 0.85) as f32;
            if abs_effective_diff > near_pi_threshold {
                if self.state.current_rudder.abs() > 0.05 {
                    rudder = if self.state.current_rudder < 0.0 { -1.0 } else { 1.0 };
                } else if self.state.angular_velocity_y.abs() > 0.001 {
                    rudder = if self.state.angular_velocity_y > 0.0 { -1.0 } else { 1.0 };
                } else {
                    rudder = -1.0; // deterministic default: start a right turn
                }
            } else {
                rudder = if effective_diff > 0.0 { -1.0 } else { 1.0 };
            }
        } else {
            let t = (abs_effective_diff - 0.02) / (full_rudder_threshold - 0.02);
            rudder = lerp_f(0.1, 1.0, t);
            if effective_diff < 0.0 {
                rudder = -rudder;
            }
            rudder = -rudder;
        }

        let lead_threshold =
            (self.state.angular_velocity_y * self.params.rudder_response_time * 0.3).abs();
        if abs_diff < lead_threshold {
            let lead_factor = abs_diff / lead_threshold.max(0.01);
            rudder *= lead_factor;
        }

        // Rudder authority comes from water flowing over the rudder, i.e. the
        // ACTUAL direction of travel — not the commanded/desired direction.
        // When moving backward the physics inverts the rudder effect:
        //   omega = (speed / R) * (-rudder), and speed is negative,
        //   so the same rudder value produces the opposite turn direction.
        // Negate to compensate.
        //
        // Critically, this must key off the real speed sign rather than the
        // `reverse` request: during a forward->reverse transition (e.g. a bow-in
        // ship commanded to kite away in reverse) the hull is still coasting
        // forward even though reverse throttle was ordered.  Using the commanded
        // direction there would invert the rudder while the ship still has
        // forward way on, swinging the bow out broadside instead of holding the
        // desired heading.  Only near zero speed (standstill setup, where the
        // rudder has no authority yet) do we fall back to the commanded
        // direction so the rudder is pre-positioned for the impending reverse.
        const RUDDER_TRAVEL_SPEED_EPSILON: f32 = 0.5; // m/s
        let physically_reversing = if self.state.current_speed.abs() > RUDDER_TRAVEL_SPEED_EPSILON {
            self.state.current_speed < 0.0
        } else {
            reverse
        };
        if physically_reversing {
            rudder = -rudder;
        }

        clamp_f(rudder, -1.0, 1.0)
    }

    pub(crate) fn compute_magnitude_for_approach(&self, distance_to_target: f32) -> i32 {
        let max_decel = self.params.max_speed / self.params.acceleration_time.max(0.1);
        if max_decel < 0.001 {
            return 0;
        }

        // Within ship beam: fully stopped
        if distance_to_target < self.params.ship_beam * 2.0 {
            return 0;
        }

        // Pick the highest magnitude whose target speed we can decelerate from
        // within the remaining distance.  For each candidate magnitude, compute
        // the distance needed to decelerate from current speed to that magnitude's
        // target speed: d = (v² - v_target²) / (2 * decel).
        // We add a safety margin so the ship starts slowing a bit early.
        let safety_margin = self.params.turning_circle_radius * 0.5;
        let v = self.state.current_speed.abs();

        // Magnitudes 4→1, check from highest to lowest
        const MAGNITUDES: [i32; 4] = [4, 3, 2, 1];
        for mag in MAGNITUDES {
            let target_speed = self.throttle_to_speed(mag);
            if target_speed >= v {
                return mag; // already at or below target — use this magnitude
            }
            let decel_dist = (v * v - target_speed * target_speed) / (2.0 * max_decel);
            if distance_to_target > decel_dist + safety_margin {
                return mag;
            }
        }

        // Within stopping distance from a crawl — use minimum forward
        1
    }

    pub(crate) fn resolve_throttle(&self, dir: DesiredDirection, magnitude: i32) -> i32 {
        if magnitude <= 0 {
            return 0;
        }
        if dir == DesiredDirection::Backward {
            return -1;
        }
        magnitude // 1, 2, 3, or 4
    }
}

// ---------------------------------------------------------------------------
// 2D OBB-OBB separating axis test (SAT).
// Each OBB is defined by a center position, a heading (radians, forward axis
// = (sin h, cos h)), a half-length along the forward axis, and a half-beam
// perpendicular to it.  Returns true when the boxes overlap (collision).
// ---------------------------------------------------------------------------
#[allow(clippy::too_many_arguments)]
fn obb_obb_overlap_2d(
    a_pos: Vector2,
    a_heading: f32,
    a_hl: f32,
    a_hb: f32,
    b_pos: Vector2,
    b_heading: f32,
    b_hl: f32,
    b_hb: f32,
) -> bool {
    // Local axes for each OBB  (forward = (sin h, cos h), right = (cos h, -sin h))
    let fa_x = a_heading.sin();
    let fa_y = a_heading.cos();
    let ra_x = fa_y;
    let ra_y = -fa_x;
    let fb_x = b_heading.sin();
    let fb_y = b_heading.cos();
    let rb_x = fb_y;
    let rb_y = -fb_x;

    // Center separation
    let tx = b_pos.x - a_pos.x;
    let ty = b_pos.y - a_pos.y;

    // Precompute absolute cross-axis dot products (used across all four axes)
    let c00 = (fa_x * fb_x + fa_y * fb_y).abs(); // |fwd_a . fwd_b|
    let c01 = (fa_x * rb_x + fa_y * rb_y).abs(); // |fwd_a . rgt_b|
    let c10 = (ra_x * fb_x + ra_y * fb_y).abs(); // |rgt_a . fwd_b|
    let c11 = (ra_x * rb_x + ra_y * rb_y).abs(); // |rgt_a . rgt_b|

    // Test axis 1: A forward
    if (tx * fa_x + ty * fa_y).abs() > a_hl + b_hl * c00 + b_hb * c01 {
        return false;
    }
    // Test axis 2: A right (starboard)
    if (tx * ra_x + ty * ra_y).abs() > a_hb + b_hl * c10 + b_hb * c11 {
        return false;
    }
    // Test axis 3: B forward
    if (tx * fb_x + ty * fb_y).abs() > b_hl + a_hl * c00 + a_hb * c10 {
        return false;
    }
    // Test axis 4: B right (starboard)
    if (tx * rb_x + ty * rb_y).abs() > b_hb + a_hl * c01 + a_hb * c11 {
        return false;
    }

    true // no separating axis found — boxes overlap
}
