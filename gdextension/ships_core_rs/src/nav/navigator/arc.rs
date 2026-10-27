use std::f64::consts::PI;

use godot::prelude::*;

use super::hull::{rudder_to_heading, Hull, PHYSICS_DT};
use super::{ArcInputs, DesiredDirection, ShipNavigator};
use crate::nav::types::{
    angle_difference, clamp_f, normalize_angle, throttle_to_speed_fraction, ArcPoint,
    ObstacleCollisionInfo, ShipParams,
};

/// Speed trails engine power by 1 / (linear_damp + Godot's default 0.1) in ShipMovementV4.
pub(crate) const HULL_SPEED_LAG_S: f32 = 5.0;

/// Arc step: two physics ticks, a few metres off the exact hull over a minute.
pub(crate) const SIM_DT: f32 = 2.0 * PHYSICS_DT;

impl ShipNavigator {
    pub(crate) fn hull_now(&self) -> Hull {
        let power = if self.state.engine_power.is_finite() {
            self.state.engine_power
        } else {
            clamp_f(self.state.current_speed / self.params.max_speed.max(0.1), -0.5, 1.0)
        };
        Hull {
            pos: self.state.position,
            vel: self.state.velocity,
            heading: self.state.heading,
            yaw: self.state.angular_velocity_y,
            rudder: self.state.current_rudder,
            power,
        }
    }

    /// Emits arc sample points spaced by get_ship_clearance().
    pub(crate) fn predict_arc_internal(
        &self,
        commanded_rudder: f32,
        commanded_throttle: i32,
        lookahead_distance: f32,
    ) -> Vec<ArcPoint> {
        let min_expected_speed = self
            .state
            .current_speed
            .abs()
            .max(self.params.max_speed * 0.25);
        let time_for_lookahead = lookahead_distance / min_expected_speed.max(1.0);
        let effective_max_time = (time_for_lookahead * 1.2).max(30.0);
        integrate_arc(
            &self.params,
            self.hull_now(),
            commanded_rudder,
            throttle_to_speed_fraction(commanded_throttle),
            self.get_ship_clearance(),
            lookahead_distance,
            effective_max_time,
        )
    }

    pub(crate) fn arc_inputs(&self, rudder: f32, throttle: i32, turn_t: f32) -> ArcInputs {
        let h = self.hull_now();
        ArcInputs {
            rudder0: self.state.current_rudder,
            speed0: self.state.current_speed,
            lateral0: self.lateral_speed(),
            rudder,
            throttle,
            turn_t,
            end_t: turn_t,
            power0: h.power,
            yaw0: h.yaw,
        }
    }

    pub(crate) fn set_winning_arc(&mut self, arc: Vec<ArcPoint>, rudder: f32, throttle: i32) {
        self.winning_arc_inputs = self.arc_inputs(rudder, throttle, arc.last().map_or(0.0, |p| p.time));
        self.winning_arc = arc;
    }

    /// Lateral (starboard-positive) component of the current velocity.
    pub(crate) fn lateral_speed(&self) -> f32 {
        let fwd_x0 = self.state.heading.sin();
        let fwd_z0 = self.state.heading.cos();
        let lat_x0 = fwd_z0;
        let lat_z0 = -fwd_x0;
        self.state.velocity.x * lat_x0 + self.state.velocity.y * lat_z0
    }

    /// Holds the rudder until the bow (stern when `reverse_alignment`) bears on `target_pos`.
    pub(crate) fn predict_arc_to_heading(
        &self,
        commanded_rudder: f32,
        commanded_throttle: i32,
        target_pos: Vector2,
        lookahead_distance: f32,
        max_time: f32,
        reverse_alignment: bool,
    ) -> Vec<ArcPoint> {
        let mut h = self.hull_now();
        let power = throttle_to_speed_fraction(commanded_throttle);
        let mut arc: Vec<ArcPoint> = Vec::with_capacity(64);
        arc.push(ArcPoint::new(h.pos, h.heading, h.speed(), 0.0));

        let max_arc_distance =
            lookahead_distance.max((2.0f64 * PI * self.params.turning_circle_radius as f64) as f32);
        let emit_interval = self.get_ship_clearance();
        let mut next_emit_dist = emit_interval;
        let (mut t, mut total_distance) = (0.0f32, 0.0f32);
        let mut rudder_settled = false;

        while t < max_time && total_distance < max_arc_distance {
            let dt = SIM_DT.min(max_time - t);
            if dt < 0.001 {
                break;
            }
            let prev = h.pos;
            h.step(&self.params, commanded_rudder, power, dt);
            t += dt;
            total_distance += h.pos.distance_to(prev);
            if (h.rudder - commanded_rudder).abs() < 0.01 {
                rudder_settled = true;
            }
            if total_distance >= next_emit_dist {
                arc.push(ArcPoint::new(h.pos, h.heading, h.speed(), t));
                next_emit_dist += emit_interval;
                if rudder_settled {
                    let to_target = target_pos - h.pos;
                    if to_target.length() > 1.0 {
                        let mut want = to_target.x.atan2(to_target.y);
                        if reverse_alignment {
                            want = normalize_angle(want + PI as f32);
                        }
                        if angle_difference(h.heading, want).abs() < 0.087 {
                            break;
                        }
                    }
                }
            }
        }

        if arc.len() < 2 || arc.last().unwrap().position.distance_to(h.pos) > 1.0 {
            arc.push(ArcPoint::new(h.pos, h.heading, h.speed(), t));
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
                        result.relative_bearing =
                            angle_difference(self.state.heading, bearing_to_obs);
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
        rudder_to_heading(&self.hull_now(), &self.params, desired_heading, reverse)
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

        // Highest magnitude the ship can still stop from before the point.
        let room = distance_to_target - self.params.turning_circle_radius * 0.25;
        for mag in [4, 3, 2] {
            let s = self.throttle_to_speed(mag);
            if s * s / (2.0 * max_decel) + s * HULL_SPEED_LAG_S <= room {
                return mag;
            }
        }
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
pub(crate) fn obb_obb_overlap_2d(
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

/// Free-running arc at a fixed commanded rudder; shared with replay re-simulation.
pub(crate) fn integrate_arc(
    p: &ShipParams,
    start: Hull,
    commanded_rudder: f32,
    target_power: f32,
    emit_interval: f32,
    lookahead_distance: f32,
    max_time: f32,
) -> Vec<ArcPoint> {
    let mut h = start;
    let mut arc: Vec<ArcPoint> = Vec::with_capacity(64);
    arc.push(ArcPoint::new(h.pos, h.heading, h.speed(), 0.0));
    let (mut t, mut total_distance) = (0.0f32, 0.0f32);
    let mut next_emit_dist = emit_interval;
    while total_distance < lookahead_distance && t < max_time {
        let dt = SIM_DT.min(max_time - t);
        if dt < 0.001 {
            break;
        }
        let prev = h.pos;
        h.step(p, commanded_rudder, target_power, dt);
        t += dt;
        total_distance += h.pos.distance_to(prev);
        if total_distance >= next_emit_dist || total_distance >= lookahead_distance - 0.1 {
            arc.push(ArcPoint::new(h.pos, h.heading, h.speed(), t));
            next_emit_dist += emit_interval;
        }
    }
    if arc.len() < 2 || arc.last().unwrap().position.distance_to(h.pos) > 1.0 {
        arc.push(ArcPoint::new(h.pos, h.heading, h.speed(), t));
    }
    arc
}
