#include "ship_navigator.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <algorithm>

#include <chrono>

using namespace godot;

// ============================================================================
// Bind methods
// ============================================================================

void ShipNavigator::_bind_methods() {
	// Setup
	ClassDB::bind_method(D_METHOD("set_map", "map"), &ShipNavigator::set_map);
	ClassDB::bind_method(D_METHOD("set_ship_params",
		"turning_circle_radius", "rudder_response_time",
		"acceleration_time", "deceleration_time",
		"max_speed", "reverse_speed_ratio",
		"ship_length", "ship_beam", "turn_speed_loss",
		"linear_drag"),
		&ShipNavigator::set_ship_params);

	// Per-frame state
	ClassDB::bind_method(D_METHOD("set_state",
		"position", "velocity", "heading",
		"angular_velocity_y", "current_rudder", "current_speed", "delta"),
		&ShipNavigator::set_state);

	// Bot identity
	ClassDB::bind_method(D_METHOD("set_bot_id", "id"), &ShipNavigator::set_bot_id);
	ClassDB::bind_method(D_METHOD("get_bot_id"), &ShipNavigator::get_bot_id);

	// Navigation commands
	ClassDB::bind_method(D_METHOD("navigate_to", "target", "heading", "hold_radius", "heading_tolerance"),
		&ShipNavigator::navigate_to, DEFVAL(0.0f), DEFVAL(0.2618f));
	ClassDB::bind_method(D_METHOD("stop"), &ShipNavigator::stop);

	ClassDB::bind_method(D_METHOD("set_grounded", "grounded"), &ShipNavigator::set_grounded);
	ClassDB::bind_method(D_METHOD("get_grounded"), &ShipNavigator::get_grounded);

	// Output
	ClassDB::bind_method(D_METHOD("get_rudder"), &ShipNavigator::get_rudder);
	ClassDB::bind_method(D_METHOD("get_throttle"), &ShipNavigator::get_throttle);
	ClassDB::bind_method(D_METHOD("get_nav_state"), &ShipNavigator::get_nav_state);
	ClassDB::bind_method(D_METHOD("is_collision_imminent"), &ShipNavigator::is_collision_imminent);


	// Dynamic obstacles
	ClassDB::bind_method(D_METHOD("register_obstacle", "id", "position", "velocity", "radius", "length"), &ShipNavigator::register_obstacle);
	ClassDB::bind_method(D_METHOD("update_obstacle", "id", "position", "velocity"), &ShipNavigator::update_obstacle);
	ClassDB::bind_method(D_METHOD("remove_obstacle", "id"), &ShipNavigator::remove_obstacle);
	ClassDB::bind_method(D_METHOD("clear_obstacles"), &ShipNavigator::clear_obstacles);

	// Path info
	ClassDB::bind_method(D_METHOD("get_current_path"), &ShipNavigator::get_current_path);
	ClassDB::bind_method(D_METHOD("get_predicted_trajectory"), &ShipNavigator::get_predicted_trajectory);
	ClassDB::bind_method(D_METHOD("get_current_waypoint"), &ShipNavigator::get_current_waypoint);

	// Debug
	ClassDB::bind_method(D_METHOD("get_desired_heading"), &ShipNavigator::get_desired_heading);
	ClassDB::bind_method(D_METHOD("get_distance_to_destination"), &ShipNavigator::get_distance_to_destination);

	ClassDB::bind_method(D_METHOD("get_clearance_radius"), &ShipNavigator::get_ship_clearance);
	ClassDB::bind_method(D_METHOD("get_soft_clearance_radius"), &ShipNavigator::get_soft_clearance);

	// Timing
	ClassDB::bind_method(D_METHOD("get_timing_update_us"), &ShipNavigator::get_timing_update_us);
	ClassDB::bind_method(D_METHOD("get_timing_avoidance_us"), &ShipNavigator::get_timing_avoidance_us);
	ClassDB::bind_method(D_METHOD("get_timing_plan_us"), &ShipNavigator::get_timing_plan_us);
	ClassDB::bind_method(D_METHOD("get_timing_replan_reason"), &ShipNavigator::get_timing_replan_reason);
	ClassDB::bind_method(D_METHOD("get_timing_plan_phase"), &ShipNavigator::get_timing_plan_phase);

	// Backward-compatible stub
	ClassDB::bind_method(D_METHOD("get_simulated_path"), &ShipNavigator::get_simulated_path);
}

// ============================================================================
// Constructor / Destructor
// ============================================================================

ShipNavigator::ShipNavigator() {
	nav_state = NavState::NORMAL;
	grounded_ = false;
	current_wp_index = 0;
	path_valid = false;
	plan_phase = PlanPhase::IDLE;
	plan_min_clearance = 0.0f;
	plan_comfortable_clearance = 0.0f;
	replan_requested_ = true;  // plan on first frame
	out_rudder = 0.0f;
	out_throttle = 0;
	out_collision_imminent = false;
	timing_update_us = 0.0f;
	timing_avoidance_us = 0.0f;
	timing_plan_us = 0.0f;
	timing_replan_reason = 0;
	timing_plan_phase_val = 0;

	skip_ship_obstacles_ = false;
	emergency_grounding_pos = Vector2();
	emergency_initialized = false;
	bot_id_ = 0;
	replan_frame_counter_ = 0;
}

ShipNavigator::~ShipNavigator() {
}

// ============================================================================
// Setup
// ============================================================================

void ShipNavigator::set_map(Ref<NavigationMap> p_map) {
	map = p_map;
}

void ShipNavigator::set_bot_id(int id) {
	bot_id_ = id;
	replan_frame_counter_ = id % REPLAN_INTERVAL;
}

int ShipNavigator::get_bot_id() const {
	return bot_id_;
}

void ShipNavigator::set_ship_params(
	float turning_circle_radius,
	float rudder_response_time,
	float acceleration_time,
	float deceleration_time,
	float max_speed,
	float reverse_speed_ratio,
	float ship_length,
	float ship_beam,
	float turn_speed_loss,
	float linear_drag
) {
	params.turning_circle_radius = turning_circle_radius;
	params.rudder_response_time = rudder_response_time;
	params.acceleration_time = acceleration_time;
	params.deceleration_time = deceleration_time;
	params.max_speed = max_speed;
	params.reverse_speed_ratio = reverse_speed_ratio;
	params.ship_length = ship_length;
	params.ship_beam = ship_beam;
	params.turn_speed_loss = turn_speed_loss;
	params.linear_drag = linear_drag;
}

// ============================================================================
// Per-frame state update — runs the full steering pipeline
// ============================================================================

void ShipNavigator::set_state(
	Vector3 position,
	Vector3 velocity,
	float heading,
	float angular_velocity_y,
	float current_rudder,
	float current_speed,
	float delta
) {
	state.position = Vector2(position.x, position.z);
	state.velocity = Vector2(velocity.x, velocity.z);
	state.heading = heading;
	state.angular_velocity_y = angular_velocity_y;
	state.current_rudder = current_rudder;
	state.current_speed = current_speed;

	// Run state machine
	update(delta);
}

// ============================================================================
// Navigation commands
// ============================================================================

void ShipNavigator::navigate_to(Vector3 p_target, float p_heading, float p_hold_radius, float p_heading_tolerance) {
	Vector2 new_pos(p_target.x, p_target.z);
	float dist_change = new_pos.distance_to(target.position);
	bool position_changed = dist_change > params.turning_circle_radius * 0.5f;

	// Detect heading change (> ~15°)
	float heading_diff = std::abs(p_heading - target.heading);
	if (heading_diff > Math_PI) heading_diff = Math_TAU - heading_diff;
	bool heading_changed = heading_diff > HEADING_TOLERANCE;

	target.position = new_pos;
	target.heading = p_heading;
	target.hold_radius = p_hold_radius;
	target.heading_tolerance = p_heading_tolerance;

	if (position_changed || heading_changed) {
		replan_requested_ = true;
	}
}

void ShipNavigator::stop() {
	target.position = state.position;
	target.heading = state.heading;
	target.hold_radius = 0.0f;
	path_valid = false;
	set_steering_output(0.0f, 0, false);
}

void ShipNavigator::set_grounded(bool grounded) {
	grounded_ = grounded;
}

bool ShipNavigator::get_grounded() const {
	return grounded_;
}

// ============================================================================
// Output getters
// ============================================================================

float ShipNavigator::get_rudder() const {
	return out_rudder;
}

int ShipNavigator::get_throttle() const {
	return out_throttle;
}

int ShipNavigator::get_nav_state() const {
	return static_cast<int>(nav_state);
}

bool ShipNavigator::is_collision_imminent() const {
	return out_collision_imminent;
}

// ============================================================================
// Dynamic obstacles
// ============================================================================

void ShipNavigator::register_obstacle(int id, Vector2 position, Vector2 velocity, float radius, float length) {
	obstacles[id] = DynamicObstacle(id, position, velocity, radius, length);
}

void ShipNavigator::update_obstacle(int id, Vector2 position, Vector2 velocity) {
	auto it = obstacles.find(id);
	if (it != obstacles.end()) {
		it->second.position = position;
		it->second.velocity = velocity;
	}
}

void ShipNavigator::remove_obstacle(int id) {
	obstacles.erase(id);
}

void ShipNavigator::clear_obstacles() {
	obstacles.clear();
}

// ============================================================================
// Path / trajectory info
// ============================================================================

PackedVector3Array ShipNavigator::get_current_path() const {
	PackedVector3Array result;
	if (!path_valid || current_path.waypoints.empty()) return result;

	for (int i = current_wp_index; i < static_cast<int>(current_path.waypoints.size()); i++) {
		const Vector2 &wp = current_path.waypoints[i];
		float flag_y = 0.0f;
		if (i < static_cast<int>(current_path.flags.size())) {
			flag_y = static_cast<float>(current_path.flags[i]);
		}
		result.push_back(Vector3(wp.x, flag_y, wp.y));
	}
	return result;
}

PackedVector3Array ShipNavigator::get_predicted_trajectory() const {
	PackedVector3Array result;
	for (const auto &pt : winning_arc) {
		result.push_back(Vector3(pt.position.x, 0.0f, pt.position.y));
	}
	return result;
}

Vector3 ShipNavigator::get_current_waypoint() const {
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		Vector2 wp = current_path.waypoints[current_wp_index];
		return Vector3(wp.x, 0.0f, wp.y);
	}
	return Vector3(target.position.x, 0.0f, target.position.y);
}

float ShipNavigator::get_desired_heading() const {
	return target.heading;
}

float ShipNavigator::get_distance_to_destination() const {
	return state.position.distance_to(target.position);
}

// ============================================================================
// Backward-compatible API stub
// ============================================================================

PackedVector3Array ShipNavigator::get_simulated_path() const {
	return get_predicted_trajectory();
}

// ============================================================================
// Internal helpers
// ============================================================================

float ShipNavigator::get_ship_clearance() const {
	return params.ship_length / 2.0 + get_safety_margin();
}

float ShipNavigator::get_soft_clearance() const {
	float hard = get_ship_clearance();
	float soft = std::max(hard, params.turning_circle_radius) + get_safety_margin();
	return soft;
}

float ShipNavigator::get_safety_margin() const {
	return params.ship_beam;
}

float ShipNavigator::get_lookahead_distance() const {
	return params.turning_circle_radius * 1.2f;
}

float ShipNavigator::get_stopping_distance() const {
	float max_decel = params.max_speed / std::max(params.acceleration_time, 0.1f);
	if (max_decel < 0.001f) return 0.0f;
	return (state.current_speed * state.current_speed) / (2.0f * max_decel);
}

float ShipNavigator::throttle_to_speed(int throttle) const {
	float fraction = throttle_to_speed_fraction(throttle);
	if (fraction < 0.0f) {
		return fraction * params.max_speed * params.reverse_speed_ratio;
	}
	return fraction * params.max_speed;
}

float ShipNavigator::get_reach_radius() const {
	float base = params.ship_length;
	float speed_factor = std::abs(state.current_speed) * 2.0f;
	float turn_factor = params.turning_circle_radius * 0.3f;
	return std::max(base, std::min(turn_factor, speed_factor));
}

void ShipNavigator::set_steering_output(float rudder, int throttle, bool collision) {
	out_rudder = rudder;
	out_throttle = throttle;
	out_collision_imminent = collision;
}



// ============================================================================
// Two-state machine
// ============================================================================

void ShipNavigator::update(float delta) {
	auto t0 = std::chrono::steady_clock::now();

	// Transition to EMERGENCY if grounded or SDF indicates on land,
	// but NOT if the ship is already at the destination within tolerance.
	if (nav_state != NavState::EMERGENCY) {
		float dist_to_dest_check = state.position.distance_to(target.position);
		float arrived_radius_check = std::max(target.hold_radius, params.ship_beam * 2.0f);
		bool at_destination = dist_to_dest_check < arrived_radius_check;

		bool enter_emergency = false;
		if (grounded_) {
			enter_emergency = true;
		} else if (map.is_valid() && map->is_built()) {
			float sdf = map->get_distance(state.position.x, state.position.y);
			if (sdf <= 0.0f) {
				enter_emergency = true;
			}
		}
		if (enter_emergency && !at_destination) {
			nav_state = NavState::EMERGENCY;
			emergency_initialized = false;
		}
	}

	switch (nav_state) {
		case NavState::NORMAL:    update_normal(delta); break;
		case NavState::EMERGENCY: update_emergency(delta); break;
	}

	auto t1 = std::chrono::steady_clock::now();
	timing_update_us = std::chrono::duration<float, std::micro>(t1 - t0).count();
}

// ============================================================================
// NORMAL state — path following + weighted avoidance
// ============================================================================

void ShipNavigator::update_normal(float delta) {
	// --- 1. Path planning (event-driven + periodic refresh) ---
	auto plan_t0 = std::chrono::steady_clock::now();

	// Periodic replan every REPLAN_INTERVAL frames, staggered by bot_id
	replan_frame_counter_++;
	if (replan_frame_counter_ >= REPLAN_INTERVAL) {
		replan_frame_counter_ = 0;
		replan_requested_ = true;
	}

	timing_replan_reason = 0;

	if constexpr (USE_ASYNC_PATHFINDING) {
		// Async mode: start_plan + tick_plan across frames
		if (plan_phase != PlanPhase::IDLE) {
			timing_replan_reason = 4; // ticking ongoing plan
		} else if (replan_requested_) {
			timing_replan_reason = 1;
		}

		if (timing_replan_reason == 1 && plan_phase == PlanPhase::IDLE) {
			start_plan();
			replan_requested_ = false;
		}

		if (plan_phase != PlanPhase::IDLE) {
			tick_plan();
			if (timing_replan_reason == 0) timing_replan_reason = 4;
		}
	} else {
		// Sync mode: full search in one frame
		if (replan_requested_) {
			timing_replan_reason = 1;
			run_plan_sync();
			replan_requested_ = false;
		}
	}

	timing_plan_phase_val = static_cast<int>(plan_phase);

	auto plan_t1 = std::chrono::steady_clock::now();
	timing_plan_us = std::chrono::duration<float, std::micro>(plan_t1 - plan_t0).count();

	// --- 2. Advance waypoints ---
	if (path_valid) advance_waypoint();

	// --- 3. Compute desired rudder + magnitude + direction ---
	float desired_rudder = 0.0f;
	int desired_magnitude = 4;
	DesiredDirection direction = DesiredDirection::FORWARD;

	float dist_to_dest = state.position.distance_to(target.position);

	// arrived_radius: close enough to consider "at the destination".
	// Respects hold_radius from the behavior (e.g. CA cover zone) with a
	// floor of ship_beam so the ship can actually reach the point.
	float arrived_radius = std::max(target.hold_radius, params.ship_beam * 2.0f);

	// maneuver_radius: zone around the destination where the ship is allowed
	// to overshoot and perform multi-point turns to align heading.  The ship
	// may oscillate forward/reverse within this zone while aligning.
	float maneuver_radius = std::max(arrived_radius, params.turning_circle_radius * 1.0f);

	// approach_radius: outer zone where deceleration begins.
	// Set to TCR so the ship drives straight at the destination and only
	// begins alignment once it's within one turning circle.
	float approach_radius_inner = std::max(params.turning_circle_radius,
	                                        get_stopping_distance() * 1.5f);

	bool path_exhausted = !path_valid || current_wp_index >= static_cast<int>(current_path.waypoints.size());

	// Detect when we're on the final waypoint segment — the ship should start
	// decelerating toward the destination before consuming the last waypoint,
	// not after blowing past it at full speed.
	bool on_final_segment = !path_exhausted
		&& current_wp_index == static_cast<int>(current_path.waypoints.size()) - 1;

	// // Determine the immediate steering target (next waypoint, or destination if path exhausted)
	// Vector2 steer_target = path_exhausted
	// 	? target.position
	// 	: current_path.waypoints[current_wp_index];
	Vector2 steer_target = target.position;

	// Determine desired direction: BACKWARD if the steering target is behind
	// the ship and within 3.5 × turning circle radius
	if (is_target_behind_within_reverse_zone(steer_target)) {
		direction = DesiredDirection::BACKWARD;
	}

	// Heading error to desired heading at destination
	float heading_error = std::abs(angle_difference(state.heading, target.heading));
	bool heading_aligned = heading_error < target.heading_tolerance;

	if ((path_exhausted || on_final_segment) && dist_to_dest < approach_radius_inner) {
		// Approaching / maneuvering at destination.
		// Triggered on the final waypoint segment OR after path is consumed.
		//
		// Three zones (inside → outside):
		//   1. arrived_radius:   close enough AND heading aligned → stop
		//   2. maneuver_radius:  multi-point turn zone — overshoot allowed,
		//                        oscillate fwd/rev to align heading
		//   3. approach_radius:  decelerate toward destination

		if (dist_to_dest < arrived_radius && heading_aligned) {
			// Arrived AND aligned: stop
			desired_rudder = compute_rudder_to_heading(target.heading, false);
			desired_magnitude = 0;
			direction = DesiredDirection::FORWARD;

		} else if (dist_to_dest < maneuver_radius) {
			// Inside the maneuver zone — multi-point turn.
			// Priority: align heading.  Use position only to prevent
			// drifting too far from the destination.
			//
			// Strategy:
			//   - Always steer toward the desired heading
			//   - Creep forward/backward to give the rudder water flow
			//   - If destination is behind, reverse toward it (which also
			//     turns the ship); if ahead, go forward
			//   - The ship naturally oscillates: overshoot forward → reverse
			//     back → overshoot reverse → forward again, each pass
			//     closing the heading error.

			// Determine which direction moves us back toward the destination
			Vector2 to_dest = target.position - state.position;
			float fwd_x = std::sin(state.heading);
			float fwd_z = std::cos(state.heading);
			float dest_along = to_dest.x * fwd_x + to_dest.y * fwd_z;
			bool dest_ahead = dest_along >= 0.0f;

			if (dist_to_dest < arrived_radius) {
				// Very close but heading not aligned — creep to give rudder authority
				desired_magnitude = 1;
				direction = dest_ahead ? DesiredDirection::FORWARD : DesiredDirection::BACKWARD;
			} else {
				// Drifted within maneuver zone — head back toward destination
				// at moderate speed while turning
				desired_magnitude = 2;
				direction = dest_ahead ? DesiredDirection::FORWARD : DesiredDirection::BACKWARD;
			}

			bool reversing = (direction == DesiredDirection::BACKWARD);
			desired_rudder = compute_rudder_to_heading(target.heading, reversing);

		} else {
			// Approach zone: decelerate toward destination, steer to align heading
			desired_rudder = compute_rudder_to_heading(target.heading);
			desired_magnitude = compute_magnitude_for_approach(dist_to_dest);
			direction = DesiredDirection::FORWARD;
		}
	} else if (!path_exhausted) {
		if (direction == DesiredDirection::BACKWARD) {
			// Waypoint behind in reverse zone: reverse toward it at full magnitude
			desired_rudder = compute_rudder_to_position(steer_target, true);
			desired_magnitude = 4;
		} else {
			// Pure pursuit toward next waypoint — full speed forward
			desired_rudder = compute_pure_pursuit_rudder();
			desired_magnitude = 4;
		}
	} else {
		// No path or beyond approach zone — steer directly to destination
		if (direction == DesiredDirection::BACKWARD && dist_to_dest > params.ship_beam) {
			desired_rudder = compute_rudder_to_position(target.position, true);
			desired_magnitude = 4;
		} else {
			desired_rudder = compute_rudder_to_position(target.position);
			desired_magnitude = 4;
		}
	}

	// Resolve direction + magnitude into a throttle value for the rest of the pipeline
	int desired_throttle = resolve_throttle(direction, desired_magnitude);

	// --- 4. Scored candidate steering ---
	// One unified function replaces terrain-aware rudder, avoidance blending,
	// and stuck detection.  Every candidate rudder/throttle pair is simulated
	// and scored; the best one wins.  No blending of untested values.
	auto avoid_t0 = std::chrono::steady_clock::now();

	SteeringChoice choice = select_best_steering(desired_rudder, desired_throttle);

	auto avoid_t1 = std::chrono::steady_clock::now();
	timing_avoidance_us = std::chrono::duration<float, std::micro>(avoid_t1 - avoid_t0).count();

	float final_rudder = choice.rudder;
	int final_throttle = choice.throttle;

	if (choice.torpedo_evasion) {
		// Torpedo: ensure max throttle for escape speed
		final_throttle = std::max(desired_throttle, 4);
	}

	// --- 4.5. Rudder-discrepancy throttle reduction ---
	// When the desired rudder is far from the current physical rudder position,
	// the ship will travel straight (at the old rudder) until the rudder catches
	// up, causing wide overshooting turns.  Reduce throttle proportionally to
	// the rudder discrepancy so the ship slows while the rudder moves into
	// position, giving tighter and more controlled turns.
	// Skip when: torpedo evasion (need max speed), reversing, or already slow.
	if (!choice.torpedo_evasion && final_throttle > 1) {
		float rudder_discrepancy = std::abs(final_rudder - state.current_rudder);
		const float discrepancy_threshold = 0.3f;  // below this, no reduction
		const float discrepancy_full = 1.2f;        // at or above this, maximum reduction
		if (rudder_discrepancy > discrepancy_threshold) {
			float t = clamp_f((rudder_discrepancy - discrepancy_threshold)
			                   / (discrepancy_full - discrepancy_threshold), 0.0f, 1.0f);
			// At full discrepancy, reduce throttle by up to 2 steps, but never below 1
			int reduction = static_cast<int>(std::round(t * 2.0f));
			final_throttle = std::max(1, final_throttle - reduction);
		}
	}

	set_steering_output(final_rudder, final_throttle, choice.collision_imminent);
}

// ============================================================================
// EMERGENCY state — grounded or critical collision
// ============================================================================

void ShipNavigator::update_emergency(float delta) {
	(void)delta;

	if (!map.is_valid() || !map->is_built()) {
		float rudder = (state.angular_velocity_y > 0.0f) ? 1.0f : -1.0f;
		set_steering_output(rudder, -1, true);
		return;
	}

	// Record grounding position on first emergency frame
	if (!emergency_initialized) {
		emergency_grounding_pos = state.position;
		emergency_initialized = true;
	}

	// --- SDF and gradient at current position ---
	float sdf_here = map->get_distance(state.position.x, state.position.y);
	Vector2 grad = map->get_gradient(state.position.x, state.position.y);
	float grad_len = grad.length();

	// Normalised away-from-land direction (SDF gradient points away from land)
	Vector2 away_dir;
	if (grad_len > 0.001f) {
		away_dir = grad / grad_len;
	} else {
		// No gradient — fall back to direction away from grounding position
		Vector2 from_ground = state.position - emergency_grounding_pos;
		float from_ground_len = from_ground.length();
		if (from_ground_len > 0.1f) {
			away_dir = from_ground / from_ground_len;
		} else {
			// Perfectly on grounding spot with no gradient — use ship's stern direction
			away_dir = Vector2(-std::sin(state.heading), -std::cos(state.heading));
		}
	}

	// --- Compute coastline tangent toward destination ---
	// Two tangent candidates (perpendicular to away_dir): pick the one toward destination
	Vector2 tangent_a(-away_dir.y,  away_dir.x);  // +90°
	Vector2 tangent_b( away_dir.y, -away_dir.x);  // -90°

	// Direction toward next waypoint (or destination if no path)
	Vector2 next_wp = target.position;
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		next_wp = current_path.waypoints[current_wp_index];
	}
	Vector2 to_dest = next_wp - state.position;
	float to_dest_len = to_dest.length();

	// Forward tangent selection: pick tangent closest to destination (normal escape)
	Vector2 chosen_tangent_fwd;
	if (to_dest_len > 1.0f) {
		chosen_tangent_fwd = (tangent_a.dot(to_dest) >= tangent_b.dot(to_dest)) ? tangent_a : tangent_b;
	} else {
		chosen_tangent_fwd = (tangent_a.dot(state.velocity) >= tangent_b.dot(state.velocity)) ? tangent_a : tangent_b;
	}

	// Reverse tangent selection for 3-point turn: pick the tangent so that the
	// BOW (opposite to travel direction) ends up closest to the next waypoint.
	// When reversing along a tangent, the stern travels in the tangent direction
	// while the bow points in the opposite direction (-tangent).  We want
	// -chosen_tangent_rev to be closest to to_dest, i.e. the tangent whose
	// negation has the greatest dot with to_dest — equivalently, the tangent
	// with the LEAST dot with to_dest.
	Vector2 chosen_tangent_rev;
	if (to_dest_len > 1.0f) {
		chosen_tangent_rev = (tangent_a.dot(to_dest) <= tangent_b.dot(to_dest)) ? tangent_a : tangent_b;
	} else {
		// No meaningful destination — pick tangent whose reverse aligns with current heading (bow direction)
		Vector2 bow_dir(std::sin(state.heading), std::cos(state.heading));
		chosen_tangent_rev = (tangent_a.dot(bow_dir) <= tangent_b.dot(bow_dir)) ? tangent_a : tangent_b;
	}

	// --- Blend from away-from-land toward tangent based on distance from terrain ---
	// At sdf <= 0 (inside land): fully away
	// At sdf >= soft_clearance: fully tangent
	// In between: linear blend
	float soft_clearance = get_soft_clearance();
	float blend_start = soft_clearance * 0.2f;
	float blend_end = soft_clearance * 0.8f;  // start going mostly tangential well before full clearance
	float blend_t = clamp_f((sdf_here - blend_start) / std::max(blend_end - blend_start, 1.0f), 0.0f, 1.0f);

	// --- Determine forward vs backward first using forward tangent ---
	// Blend escape direction using the forward tangent to decide direction
	Vector2 escape_dir_fwd;
	escape_dir_fwd.x = lerp_f(away_dir.x, chosen_tangent_fwd.x, blend_t);
	escape_dir_fwd.y = lerp_f(away_dir.y, chosen_tangent_fwd.y, blend_t);
	float escape_fwd_len = escape_dir_fwd.length();
	if (escape_fwd_len > 0.001f) {
		escape_dir_fwd /= escape_fwd_len;
	} else {
		escape_dir_fwd = away_dir;
	}

	float fwd_x = std::sin(state.heading);
	float fwd_z = std::cos(state.heading);
	float escape_dot_fwd = escape_dir_fwd.x * fwd_x + escape_dir_fwd.y * fwd_z;

	// --- Evaluate forward vs reverse using the escape heading ---
	// Simulate one arc for each direction and score by the minimum SDF along
	// the arc.  The candidate whose tightest point is farthest from land wins
	// — this ensures we pick the direction that avoids squeezing through a
	// narrow gap or clipping terrain at any point along the escape path.

	float lookahead = std::max(params.turning_circle_radius * 2.0f, params.ship_length * 3.0f);

	float best_min_sdf = -std::numeric_limits<float>::infinity();
	float best_rudder = 0.0f;
	int best_throttle = -1;

	// Evaluate both directions: 0 = forward, 1 = reverse
	for (int dir = 0; dir < 2; ++dir) {
		bool rev = (dir == 1);
		Vector2 chosen_tangent = rev ? chosen_tangent_rev : chosen_tangent_fwd;

		Vector2 escape_dir;
		escape_dir.x = lerp_f(away_dir.x, chosen_tangent.x, blend_t);
		escape_dir.y = lerp_f(away_dir.y, chosen_tangent.y, blend_t);
		float escape_len = escape_dir.length();
		if (escape_len > 0.001f) {
			escape_dir /= escape_len;
		} else {
			escape_dir = away_dir;
		}

		float escape_heading = std::atan2(escape_dir.x, escape_dir.y);
		float rudder_heading = rev ? normalize_angle(escape_heading + Math_PI) : escape_heading;
		float candidate_rudder = compute_rudder_to_heading(rudder_heading, rev);
		int throttle = rev ? -1 : 4;

		auto arc = predict_arc_internal(candidate_rudder, throttle, lookahead);
		if (arc.size() < 2) continue;

		// Score: minimum SDF across all arc points — pick the direction
		// whose worst point is farthest from land.
		float min_sdf = std::numeric_limits<float>::infinity();
		for (const auto &pt : arc) {
			float sdf = map->get_distance(pt.position.x, pt.position.y);
			if (sdf < min_sdf) min_sdf = sdf;
		}

		if (min_sdf > best_min_sdf) {
			best_min_sdf = min_sdf;
			best_rudder = candidate_rudder;
			best_throttle = throttle;
			winning_arc = std::move(arc);
		}
	}

	float rudder = best_rudder;
	int throttle = best_throttle;
	bool use_reverse = (throttle < 0);

	// --- Rudder-discrepancy throttle reduction (emergency) ---
	// Same principle as normal mode: when the desired rudder is far from the
	// current physical rudder, reduce throttle so the ship doesn't charge
	// forward/backward on the old rudder heading before the rudder catches up.
	// In emergency mode we map forward throttle 4 → magnitude steps and
	// reverse throttle -1 stays as-is (already minimum reverse).
	if (!use_reverse && throttle > 1) {
		float rudder_discrepancy = std::abs(rudder - state.current_rudder);
		const float discrepancy_threshold = 0.3f;
		const float discrepancy_full = 1.2f;
		if (rudder_discrepancy > discrepancy_threshold) {
			float t = clamp_f((rudder_discrepancy - discrepancy_threshold)
			                   / (discrepancy_full - discrepancy_threshold), 0.0f, 1.0f);
			int reduction = static_cast<int>(std::round(t * 2.0f));
			throttle = std::max(1, throttle - reduction);
		}
	}

	// --- Exit condition: at destination with heading aligned — no need to escape ---
	{
		float dist_to_dest_em = state.position.distance_to(target.position);
		float arrived_radius_em = std::max(target.hold_radius, params.ship_beam * 2.0f);
		float heading_error_em = std::abs(angle_difference(state.heading, target.heading));
		if (dist_to_dest_em < arrived_radius_em && heading_error_em < target.heading_tolerance) {
			nav_state = NavState::NORMAL;
			emergency_initialized = false;
			replan_requested_ = true;
			return;
		}
	}

	// --- Exit condition: no longer grounded AND arc toward next waypoint is clear ---
	float soft_cl = get_soft_clearance();
	float hard_cl = get_ship_clearance();
	if (!grounded_ && sdf_here > hard_cl * 2.0) {
		// If waypoint is far (> 3 TCR) the exit cruise direction flips from the current emergency direction
		bool exit_reverse = to_dest_len < params.turning_circle_radius * 3.0f;
		int exit_throttle = exit_reverse ? -1 : 2;
		float wp_heading = std::atan2(to_dest.x, to_dest.y);
		float exit_rudder = compute_rudder_to_heading(exit_reverse ? normalize_angle(wp_heading + Math_PI) : wp_heading, exit_reverse);
		float exit_lookahead = 2.0f * Math_PI * params.turning_circle_radius;

		auto arc = predict_arc_to_heading(exit_rudder, exit_throttle, next_wp, exit_lookahead);
		float arc_time = arc.empty() ? 0.0f : arc.back().time;
		float ttc = check_arc_collision(arc, hard_cl * 0.8f, soft_cl);

		if (arc_time > 0.0f && ttc >= arc_time) {
			nav_state = NavState::NORMAL;
			emergency_initialized = false;
			replan_requested_ = true;
			return;
		}
	}

	set_steering_output(rudder, throttle, true);
}

// ============================================================================
// Plan management (extracted from old update_planning)
// ============================================================================

void ShipNavigator::start_plan() {
	if (map.is_null() || !map->is_built()) {
		path_valid = false;
		plan_phase = PlanPhase::IDLE;
		return;
	}

	plan_min_clearance = get_ship_clearance();
	plan_comfortable_clearance = std::min(
		plan_min_clearance + params.ship_beam * 0.5f,
		plan_min_clearance * 2.0f);

	// Begin forward search — simple 8-direction MR A* (no heading awareness)
	bool immediate = map->begin_path_search(
		path_search, state.position, target.position,
		plan_min_clearance, 0.0f);

	if (immediate) {
		plan_forward_result = path_search.result;
		plan_phase = PlanPhase::DONE;
	} else if (path_search.active) {
		plan_phase = PlanPhase::FORWARD;
	} else {
		plan_forward_result = PathResult();
		plan_phase = PlanPhase::FALLBACK;
	}
}

void ShipNavigator::tick_plan() {
	// --- FORWARD phase ---
	if (plan_phase == PlanPhase::FORWARD) {
		bool complete = map->continue_path_search(path_search, PLAN_ITER_BUDGET);
		if (complete) {
			plan_forward_result = map->finish_path_search(path_search);
			if (!plan_forward_result.valid || plan_forward_result.waypoints.empty()) {
				plan_phase = PlanPhase::FALLBACK;
			} else {
				plan_phase = PlanPhase::DONE;
			}
		}
		return;
	}

	// --- FALLBACK phase ---
	if (plan_phase == PlanPhase::FALLBACK) {
		if (!path_search.active) {
			// Reset search state so begin_path_search can start fresh
			path_search.complete = false;
			bool immediate = map->begin_path_search(
				path_search, state.position, target.position,
				plan_min_clearance * 0.5f, 0.0f);
			if (immediate) {
				plan_forward_result = path_search.result;
				if (plan_forward_result.valid && !plan_forward_result.waypoints.empty()) {
					plan_phase = PlanPhase::DONE;
				} else {
					plan_phase = PlanPhase::GRID_FALLBACK;
				}
				return;
			} else if (!path_search.active) {
				plan_forward_result = PathResult();
				plan_phase = PlanPhase::GRID_FALLBACK;
				return;
			}
		}

		if (path_search.active) {
			bool complete = map->continue_path_search(path_search, PLAN_ITER_BUDGET);
			if (complete) {
				plan_forward_result = map->finish_path_search(path_search);
				if (plan_forward_result.valid && !plan_forward_result.waypoints.empty()) {
					plan_phase = PlanPhase::DONE;
				} else {
					plan_phase = PlanPhase::GRID_FALLBACK;
				}
			}
		}
		return;
	}

	// --- GRID_FALLBACK phase ---
	if (plan_phase == PlanPhase::GRID_FALLBACK) {
		if (!path_search.active) {
			// Reset search state so begin_path_search can start fresh
			path_search.complete = false;
			float grid_fb_clearance = map->get_cell_size_value() * 0.5f;
			bool immediate = map->begin_path_search(
				path_search, state.position, target.position,
				grid_fb_clearance, 0.0f);
			if (immediate) {
				plan_forward_result = path_search.result;
				if (plan_forward_result.valid && !plan_forward_result.waypoints.empty()) {
					map->post_process_path_clearance(plan_forward_result, plan_min_clearance);
				}
				plan_phase = PlanPhase::DONE;
				return;
			} else if (!path_search.active) {
				plan_forward_result = PathResult();
				plan_phase = PlanPhase::DONE;
				return;
			}
		}

		if (path_search.active) {
			bool complete = map->continue_path_search(path_search, PLAN_ITER_BUDGET);
			if (complete) {
				plan_forward_result = map->finish_path_search(path_search);
				if (plan_forward_result.valid && !plan_forward_result.waypoints.empty()) {
					map->post_process_path_clearance(plan_forward_result, plan_min_clearance);
				}
				plan_phase = PlanPhase::DONE;
			}
		}
		return;
	}

	// --- DONE phase ---
	if (plan_phase == PlanPhase::DONE) {
		accept_plan_result(plan_forward_result);
		plan_phase = PlanPhase::IDLE;
	}
}

void ShipNavigator::run_plan_sync() {
	if (map.is_null() || !map->is_built()) {
		path_valid = false;
		return;
	}

	plan_min_clearance = get_ship_clearance();
	plan_comfortable_clearance = std::min(
		plan_min_clearance + params.ship_beam * 0.5f,
		plan_min_clearance * 2.0f);

	// Phase 1: Full clearance search — simple 8-direction MR A* (no heading awareness)
	bool immediate = map->begin_path_search(
		path_search, state.position, target.position,
		plan_min_clearance, 0.0f);

	if (!immediate && path_search.active) {
		map->continue_path_search(path_search, SYNC_ITER_LIMIT);
	}

	PathResult result;
	if (path_search.complete && path_search.found) {
		result = map->finish_path_search(path_search);
	}

	// Phase 2: Reduced clearance fallback
	if (!result.valid || result.waypoints.empty()) {
		immediate = map->begin_path_search(
			path_search, state.position, target.position,
			plan_min_clearance * 0.5f, 0.0f);
		if (!immediate && path_search.active) {
			map->continue_path_search(path_search, SYNC_ITER_LIMIT);
		}
		if (path_search.complete && path_search.found) {
			result = map->finish_path_search(path_search);
		}
	}

	// Phase 3: Minimum clearance (grid cell) fallback
	if (!result.valid || result.waypoints.empty()) {
		float grid_fb_clearance = map->get_cell_size_value() * 0.5f;
		immediate = map->begin_path_search(
			path_search, state.position, target.position,
			grid_fb_clearance, 0.0f);
		if (!immediate && path_search.active) {
			map->continue_path_search(path_search, SYNC_ITER_LIMIT);
		}
		if (path_search.complete && path_search.found) {
			result = map->finish_path_search(path_search);
			if (result.valid && !result.waypoints.empty()) {
				map->post_process_path_clearance(result, plan_min_clearance);
			}
		}
	}

	accept_plan_result(result);
	plan_phase = PlanPhase::IDLE;
}

// ============================================================================
// Scored candidate steering — unified terrain + obstacle avoidance
//
// Scoring: each candidate rudder/throttle is simulated until the ship's
// heading aligns with the next waypoint.  The score is:
//
//   score = alignment_time + travel_time_to_waypoint
//
// where travel_time = distance_from_endpoint_to_waypoint / speed_at_endpoint.
// Lowest score wins.  Arcs that enter the hard clearance zone are disqualified.
// Arcs with obstacle collisions (where we're the hitter) have their score
// doubled as a penalty.  Reverse candidates are always included — they are
// naturally penalised by slower speed producing longer times.
// ============================================================================

ShipNavigator::SteeringChoice ShipNavigator::select_best_steering(float desired_rudder, int desired_throttle) {
	SteeringChoice result = { desired_rudder, desired_throttle, false, false };

	float hard_clearance = get_ship_clearance();
	float soft_clearance = get_soft_clearance();
	float lookahead = get_lookahead_distance();

	// --- Adaptive clearance: halve when already inside the clearance zone ---
	// If the ship is already closer to terrain than hard_clearance, insisting
	// on full clearance causes oscillation: the ship drives forward into the
	// zone, every arc is disqualified, it reverses out, then drives back in.
	// Instead, accept the situation and halve the threshold so the ship can
	// continue navigating.  Full clearance is restored naturally once the
	// ship moves to open water (SDF > hard_clearance on the next frame).
	if (map.is_valid() && map->is_built()) {
		float sdf_here = map->get_distance(state.position.x, state.position.y);
		if (sdf_here < hard_clearance) {
			hard_clearance *= 0.5f;
		}
	}

	// --- Parked-ship filter ---
	skip_ship_obstacles_ = (std::abs(state.current_speed) < PARKED_SPEED_THRESHOLD
	                         && desired_throttle <= 0);

	// --- Fast early-exit: skip when clearly safe ---
	bool terrain_safe = false;
	if (map.is_valid() && map->is_built()) {
		float sdf_here = map->get_distance(state.position.x, state.position.y);
		if (sdf_here > soft_clearance + lookahead) {
			terrain_safe = true;
		}
	}

	bool obstacles_safe = true;
	float engagement_range = lookahead + params.max_speed * 30.0f;
	for (const auto &[id, obs] : obstacles) {
		if (skip_ship_obstacles_ && !obs.is_torpedo()) continue;
		float dist = state.position.distance_to(obs.position);
		if (dist < engagement_range) {
			obstacles_safe = false;
			break;
		}
	}

	if (terrain_safe && obstacles_safe) {
		// Cache a short debug arc for visualization even on the fast path
		float debug_lookahead = std::min(lookahead, params.ship_length * 4.0f);
		winning_arc = predict_arc_internal(desired_rudder, desired_throttle, debug_lookahead);
		return result;
	}

	// --- Torpedo special case: scan for dodge, return immediately ---
	{
		auto desired_arc = predict_arc_internal(desired_rudder, desired_throttle, lookahead);
		// Cache for debug visualisation (will be overwritten by winning arc below if no torpedo)
		winning_arc = desired_arc;

		ObstacleCollisionInfo obs_info = check_arc_obstacles_detailed(desired_arc);
		if (obs_info.has_collision && obs_info.is_torpedo) {
			// Compute perpendicular dodge bias
			float dodge_bias = 0.0f;
			Vector2 torpedo_dir = obs_info.obstacle_velocity;
			float torp_speed = torpedo_dir.length();
			if (torp_speed > 1.0f) {
				torpedo_dir /= torp_speed;
				Vector2 ship_side = state.position - obs_info.obstacle_position;
				float cross = torpedo_dir.x * ship_side.y - torpedo_dir.y * ship_side.x;
				dodge_bias = (cross >= 0.0f) ? -1.0f : 1.0f;
			}

			// Scan rudder candidates for best torpedo dodge
			float best_ttc = obs_info.time_to_collision;
			float best_rudder = desired_rudder;
			const float mag_steps[] = { 0.3f, 0.6f, 1.0f, 1.5f, 2.0f };
			for (int i = 0; i < 5; ++i) {
				float offsets[2] = { mag_steps[i] * dodge_bias, -mag_steps[i] * dodge_bias };
				for (int j = 0; j < 2; ++j) {
					float candidate = clamp_f(desired_rudder + offsets[j], -1.0f, 1.0f);
					auto arc = predict_arc_internal(candidate, std::max(desired_throttle, 4), lookahead);
					float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
					float cand_ttc = check_arc_obstacles(arc);
					if (cand_ttc > best_ttc) {
						best_ttc = cand_ttc;
						best_rudder = candidate;
						winning_arc = std::move(arc);
						if (best_ttc >= cand_arc_time * 0.95f) break;
					}
				}
				if (best_ttc >= (desired_arc.empty() ? 0.0f : desired_arc.back().time) * 0.95f) break;
			}

			return { best_rudder, std::max(desired_throttle, 4), true, true };
		}
	}

	// --- Determine waypoint target for alignment scoring ---
	Vector2 wp_target = target.position;
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		wp_target = current_path.waypoints[current_wp_index];
	}
	float wp_reach_radius = get_reach_radius();

	// --- Ship-obstacle hitter determination ---
	float our_heading_x = std::sin(state.heading);
	float our_heading_z = std::cos(state.heading);
	Vector2 our_fwd(our_heading_x, our_heading_z);

	// --- Build candidate list ---
	struct Candidate {
		float rudder;
		int throttle;
	};

	// Forward candidates: desired ± offsets
	const float rudder_offsets[] = { 0.0f, -0.3f, 0.3f, -0.6f, 0.6f, -1.0f, 1.0f };
	constexpr int N_OFFSETS = 7;

	// +4 for: full opposite rudder, full opposite at reduced throttle, 2 reverse candidates
	Candidate candidates[N_OFFSETS + 4];
	int n_candidates = 0;

	auto add_candidate = [&](float r, int t) {
		r = clamp_f(r, -1.0f, 1.0f);
		for (int j = 0; j < n_candidates; ++j) {
			if (std::abs(candidates[j].rudder - r) < 0.05f && candidates[j].throttle == t) return;
		}
		candidates[n_candidates++] = { r, t };
	};

	// Forward candidates at desired throttle
	for (int i = 0; i < N_OFFSETS; ++i) {
		add_candidate(desired_rudder + rudder_offsets[i], desired_throttle);
	}

	// Full opposite rudder — covers the go-around case when desired_rudder
	// is far from ±1.0 and the offset candidates don't reach it.
	if (std::abs(desired_rudder) > 0.15f) {
		float opposite_rudder = (desired_rudder > 0.0f) ? -1.0f : 1.0f;
		add_candidate(opposite_rudder, desired_throttle);
	}

	// Reverse candidates — always included.  Reverse is naturally penalised
	// by slower speed producing longer alignment + travel times.
	add_candidate(0.0f, -1);
	add_candidate(-desired_rudder, -1);

	// --- Simulation parameters ---
	// Simulate long enough for the ship to complete a full turning circle
	// (the go-around case) plus some margin.
	float turn_circumference = 2.0f * Math_PI * params.turning_circle_radius;
	float sim_lookahead = std::max(turn_circumference, lookahead * 2.0f);
	float sim_max_time = 120.0f;

	// --- Score each candidate: alignment_time + travel_time (lowest wins) ---
	float best_time = std::numeric_limits<float>::infinity();
	float best_rudder = desired_rudder;
	int best_throttle = desired_throttle;
	bool any_collision = false;

	for (int i = 0; i < n_candidates; ++i) {
		float cand_rudder = candidates[i].rudder;
		int cand_throttle = candidates[i].throttle;

		// Simulate until heading aligns with waypoint
		auto arc = predict_arc_to_heading(cand_rudder, cand_throttle, wp_target,
		                                   sim_lookahead, sim_max_time);
		if (arc.size() < 2) continue;

		// Early termination: if alignment time already exceeds the best,
		// this candidate cannot win (travel_time can only add to it).
		if (arc.back().time >= best_time) continue;

		// --- (a) Terrain safety: disqualify if any point enters hard clearance ---
		// Truncate the check at the destination: once an arc point reaches the
		// waypoint, the ship will stop advancing — terrain beyond that point
		// is irrelevant.  This prevents arcs aimed at a destination near an
		// island from being disqualified by terrain the ship will never reach.
		bool terrain_blocked = false;
		float arrival_time = -1.0f;  // time at which arc reaches the waypoint
		if (map.is_valid() && map->is_built()) {
			for (const auto &pt : arc) {
				// Check if this point has reached the waypoint
				if (pt.position.distance_to(wp_target) < wp_reach_radius) {
					arrival_time = pt.time;
					break;  // stop checking — ship stops here
				}
				float sdf = map->get_distance(pt.position.x, pt.position.y);
				if (sdf < hard_clearance) {
					terrain_blocked = true;
					break;
				}
			}
		}
		if (terrain_blocked) continue;

		// --- (b) Alignment time / arrival time ---
		// If the arc physically reached the waypoint before aligning, use
		// the arrival time directly (travel_time = 0).  Otherwise use the
		// alignment time + estimated travel.
		float total_time;
		if (arrival_time >= 0.0f) {
			// Arc passed through the waypoint — score is just the arrival time
			total_time = arrival_time;
		} else {
			float alignment_time = arc.back().time;
			float endpoint_dist = arc.back().position.distance_to(wp_target);
			float endpoint_speed = std::abs(arc.back().speed);
			if (endpoint_speed < 1.0f) endpoint_speed = 1.0f;
			float travel_time = endpoint_dist / endpoint_speed;
			total_time = alignment_time + travel_time;
		}

		// --- (d) Obstacle check: double total time if hitter collision ---
		ObstacleCollisionInfo obs_info = check_arc_obstacles_detailed(arc);
		if (obs_info.has_collision && !obs_info.is_torpedo) {
			Vector2 to_obs = obs_info.obstacle_position - state.position;
			float to_obs_len = to_obs.length();
			bool hitter = false;
			if (to_obs_len > 0.1f) {
				float bow_dot = our_fwd.dot(to_obs / to_obs_len);
				hitter = (bow_dot > 0.3f);
			}
			if (hitter) {
				total_time *= 2.0f;
				any_collision = true;
			}
		}

		if (total_time < best_time) {
			best_time = total_time;
			best_rudder = cand_rudder;
			best_throttle = cand_throttle;
			winning_arc = std::move(arc);
		}
	}

	// If ALL candidates were disqualified (every arc enters hard clearance),
	// fall back: pick the candidate whose minimum SDF is least bad.
	if (best_time == std::numeric_limits<float>::infinity()) {
		float least_bad_sdf = -std::numeric_limits<float>::infinity();
		for (int i = 0; i < n_candidates; ++i) {
			auto arc = predict_arc_internal(candidates[i].rudder, candidates[i].throttle, lookahead);
			if (arc.empty()) continue;

			float min_sdf = std::numeric_limits<float>::infinity();
			if (map.is_valid() && map->is_built()) {
				for (const auto &pt : arc) {
					float sdf = map->get_distance(pt.position.x, pt.position.y);
					if (sdf < min_sdf) min_sdf = sdf;
				}
			}

			if (min_sdf > least_bad_sdf) {
				least_bad_sdf = min_sdf;
				best_rudder = candidates[i].rudder;
				best_throttle = candidates[i].throttle;
				winning_arc = std::move(arc);
			}
		}
		any_collision = true;
	}

	result.rudder = best_rudder;
	result.throttle = best_throttle;
	result.torpedo_evasion = false;
	result.collision_imminent = any_collision || (best_rudder != desired_rudder) || (best_throttle != desired_throttle);
	return result;
}

// ============================================================================
// Pure pursuit steering
// ============================================================================

float ShipNavigator::compute_pure_pursuit_rudder() const {
	float R = params.turning_circle_radius;
	float speed = std::max(std::abs(state.current_speed), 1.0f);
	float lookahead = std::max(R * 2.0f, speed * 5.0f);
	Vector2 lookahead_pt = find_path_lookahead(lookahead);

	Vector2 to_target = lookahead_pt - state.position;
	float forward_x = std::sin(state.heading);
	float forward_z = std::cos(state.heading);
	float along  = to_target.x * forward_x + to_target.y * forward_z;
	float lateral = to_target.x * forward_z - to_target.y * forward_x;
	float dist_sq = to_target.x * to_target.x + to_target.y * to_target.y;
	if (dist_sq < 1.0f) dist_sq = 1.0f;

	float curvature = 2.0f * lateral / dist_sq;
	float rudder = clamp_f(-curvature * R, -1.0f, 1.0f);

	// If target is behind, steer directly
	if (along < 0.0f) {
		Vector2 wp = current_path.waypoints[current_wp_index];
		rudder = compute_rudder_to_position(wp, false);
	}

	return rudder;
}

// ============================================================================
// Direction determination — is the target behind within the reverse zone?
// ============================================================================

bool ShipNavigator::is_target_behind_within_reverse_zone(Vector2 target_pos) const {
	Vector2 to_target = target_pos - state.position;
	float forward_x = std::sin(state.heading);
	float forward_z = std::cos(state.heading);
	float along = to_target.x * forward_x + to_target.y * forward_z;
	float dist = to_target.length();

	// Tighter threshold: target must be more than 110° off the bow
	// cos(110°) ≈ -0.342, so along/dist must be less than that
	if (dist < 1e-6f) return false;
	if (along / dist >= -0.342f) return false;

	// Target is behind — check if it's within 3.0 × turning circle radius
	return dist < params.turning_circle_radius * 3.0f;
}

// ============================================================================
// Path acceptance (oscillation check + commit)
// ============================================================================

void ShipNavigator::accept_plan_result(const PathResult &forward_result) {
	if (forward_result.valid && !forward_result.waypoints.empty()) {
		bool should_accept = true;

		if (path_valid && current_path.waypoints.size() >= 2
			&& forward_result.waypoints.size() >= 2
			&& current_wp_index < (int)current_path.waypoints.size()) {

			Vector2 to_dest = target.position - state.position;

			Vector2 old_wp = current_path.waypoints[current_wp_index];
			Vector2 to_old = old_wp - state.position;
			float old_cross = to_dest.x * to_old.y - to_dest.y * to_old.x;

			int new_wp_idx = 0;
			if (forward_result.waypoints.size() > 1 &&
				state.position.distance_to(forward_result.waypoints[0]) < params.turning_circle_radius * 0.25f) {
				new_wp_idx = 1;
			}
			Vector2 new_wp = forward_result.waypoints[new_wp_idx];
			Vector2 to_new = new_wp - state.position;
			float new_cross = to_dest.x * to_new.y - to_dest.y * to_new.x;

			bool sides_differ = (old_cross * new_cross < 0.0f);
			float deviation = state.position.distance_to(old_wp);
			bool ship_on_old_path = (deviation < params.turning_circle_radius * 3.0f);

			if (sides_differ && ship_on_old_path) {
				should_accept = false;
			}
		}

		if (should_accept) {
			current_path = forward_result;
			path_valid = true;
			current_wp_index = 0;
			if (current_path.waypoints.size() > 1 &&
				state.position.distance_to(current_path.waypoints[0]) < params.turning_circle_radius * 0.25f) {
				current_wp_index = 1;
			}
		}
	} else {
		// Path planning failed — use direct line to destination as fallback
		current_path = PathResult();
		current_path.waypoints.push_back(state.position);
		current_path.waypoints.push_back(target.position);
		current_path.flags.push_back(WP_NONE);
		current_path.flags.push_back(WP_NONE);
		current_path.valid = true;
		current_path.total_distance = state.position.distance_to(target.position);
		path_valid = true;
		current_wp_index = 1;
	}
}

// ============================================================================
// Arc prediction
// ============================================================================

std::vector<ArcPoint> ShipNavigator::predict_arc_internal(float commanded_rudder, int commanded_throttle,
														   float lookahead_distance) const {
	std::vector<ArcPoint> arc;
	arc.reserve(64);

	float sim_rudder = state.current_rudder;
	float sim_speed = state.current_speed;
	float sim_heading = state.heading;
	Vector2 sim_pos = state.position;
	float sim_time = 0.0f;
	float total_distance = 0.0f;

	// --- Drift model: decompose current velocity into forward and lateral ---
	// The heading unit vector (forward direction in XZ)
	float fwd_x0 = std::sin(state.heading);
	float fwd_z0 = std::cos(state.heading);
	// Lateral (starboard) unit vector: rotate forward 90° clockwise
	float lat_x0 = fwd_z0;
	float lat_z0 = -fwd_x0;
	// Project actual velocity onto forward and lateral axes
	// lateral > 0 means drifting to starboard
	float sim_lateral_speed = state.velocity.x * lat_x0 + state.velocity.y * lat_z0;
	// Drag decay rate — matches Godot's linear_damp applied uniformly
	float lateral_drag = std::max(params.linear_drag, 0.01f);

	float target_speed_val = throttle_to_speed(commanded_throttle);

	arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, 0.0f));

	const float base_dt = 0.1f;
	const float integration_dt = std::min(
		base_dt * std::max(1.0f, params.rudder_response_time / 4.0f),
		0.5f
	);
	float emit_interval = get_ship_clearance();
	float next_emit_dist = emit_interval;
	Vector2 prev_pos = sim_pos;

	float min_expected_speed = std::max(std::abs(state.current_speed), params.max_speed * 0.25f);
	float time_for_lookahead = lookahead_distance / std::max(min_expected_speed, 1.0f);
	float effective_max_time = std::max(30.0f, time_for_lookahead * 1.2f);

	while (total_distance < lookahead_distance && sim_time < effective_max_time) {
		float dt = integration_dt;
		if (sim_time + dt > effective_max_time) dt = effective_max_time - sim_time;
		if (dt < 0.001f) break;

		if (params.rudder_response_time > 0.001f) {
			sim_rudder = move_toward_f(sim_rudder, commanded_rudder, dt / params.rudder_response_time);
		} else {
			sim_rudder = commanded_rudder;
		}

		if (target_speed_val > sim_speed) {
			float accel_rate = params.max_speed / std::max(params.acceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * accel_rate);
		} else {
			float decel_rate = params.max_speed / std::max(params.deceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * decel_rate);
		}

		float effective_speed = sim_speed * (1.0f - params.turn_speed_loss * std::abs(sim_rudder));

		float prev_heading = sim_heading;

		float omega = 0.0f;
		if (params.turning_circle_radius > 0.001f) {
			omega = (effective_speed / params.turning_circle_radius) * (-sim_rudder);
		}

		sim_heading += omega * dt;
		sim_heading = normalize_angle(sim_heading);

		// --- Drift model integration ---
		// When the heading rotates, velocity that was "forward" partially becomes
		// "lateral" from the new heading's perspective.  This models the inertia
		// mismatch: the hull rotates but the velocity vector lags behind.
		float heading_delta = sim_heading - prev_heading;
		// Rotate lateral speed by the heading change:
		//   new_lateral ≈ old_lateral * cos(dh) + forward_speed * sin(dh)
		// For small dh this is: old_lateral + forward_speed * dh
		sim_lateral_speed = sim_lateral_speed * std::cos(heading_delta)
						  + effective_speed * std::sin(heading_delta);
		// Decay lateral speed via drag (exponential decay matching Godot linear_damp)
		sim_lateral_speed *= std::exp(-lateral_drag * dt);

		// Forward movement along heading + lateral drift perpendicular to heading
		float cur_fwd_x = std::sin(sim_heading);
		float cur_fwd_z = std::cos(sim_heading);
		float cur_lat_x = cur_fwd_z;   // starboard = forward rotated 90° CW
		float cur_lat_z = -cur_fwd_x;
		sim_pos.x += cur_fwd_x * effective_speed * dt + cur_lat_x * sim_lateral_speed * dt;
		sim_pos.y += cur_fwd_z * effective_speed * dt + cur_lat_z * sim_lateral_speed * dt;

		sim_time += dt;

		float step_dist = sim_pos.distance_to(prev_pos);
		total_distance += step_dist;
		prev_pos = sim_pos;

		if (total_distance >= next_emit_dist || total_distance >= lookahead_distance - 0.1f) {
			arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
			next_emit_dist += emit_interval;
		}
	}

	if (arc.size() < 2 || arc.back().position.distance_to(sim_pos) > 1.0f) {
		arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
	}

	return arc;
}

std::vector<ArcPoint> ShipNavigator::predict_arc_to_heading(float commanded_rudder, int commanded_throttle,
															Vector2 target_pos, float lookahead_distance,
															float max_time) const {
	std::vector<ArcPoint> arc;
	arc.reserve(64);

	float sim_rudder = state.current_rudder;
	float sim_speed = state.current_speed;
	float sim_heading = state.heading;
	Vector2 sim_pos = state.position;
	float sim_time = 0.0f;
	float total_distance = 0.0f;

	// --- Drift model: decompose current velocity into forward and lateral ---
	float fwd_x0 = std::sin(state.heading);
	float fwd_z0 = std::cos(state.heading);
	float lat_x0 = fwd_z0;
	float lat_z0 = -fwd_x0;
	float sim_lateral_speed = state.velocity.x * lat_x0 + state.velocity.y * lat_z0;
	float lateral_drag = std::max(params.linear_drag, 0.01f);

	float target_speed_val = throttle_to_speed(commanded_throttle);

	arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, 0.0f));

	float turning_circle_perimeter = 2.0f * Math_PI * params.turning_circle_radius;
	float max_arc_distance = std::max(lookahead_distance, turning_circle_perimeter);

	const float base_dt = 0.1f;
	const float integration_dt = std::min(
		base_dt * std::max(1.0f, params.rudder_response_time / 4.0f),
		0.5f
	);
	float emit_interval = get_ship_clearance();
	float next_emit_dist = emit_interval;
	Vector2 prev_pos = sim_pos;

	const float alignment_threshold = 0.087f;
	bool rudder_settled = false;

	bool aligned = false;
	while (sim_time < max_time && total_distance < max_arc_distance) {
		float dt = integration_dt;
		if (sim_time + dt > max_time) dt = max_time - sim_time;
		if (dt < 0.001f) break;

		if (params.rudder_response_time > 0.001f) {
			sim_rudder = move_toward_f(sim_rudder, commanded_rudder, dt / params.rudder_response_time);
		} else {
			sim_rudder = commanded_rudder;
		}

		if (!rudder_settled && std::abs(sim_rudder - commanded_rudder) < 0.01f) {
			rudder_settled = true;
		}

		if (target_speed_val > sim_speed) {
			float accel_rate = params.max_speed / std::max(params.acceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * accel_rate);
		} else {
			float decel_rate = params.max_speed / std::max(params.deceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * decel_rate);
		}

		float effective_speed = sim_speed * (1.0f - params.turn_speed_loss * std::abs(sim_rudder));

		float prev_heading = sim_heading;

		float omega = 0.0f;
		if (params.turning_circle_radius > 0.001f) {
			omega = (effective_speed / params.turning_circle_radius) * (-sim_rudder);
		}

		sim_heading += omega * dt;
		sim_heading = normalize_angle(sim_heading);

		// --- Drift model integration ---
		float heading_delta = sim_heading - prev_heading;
		sim_lateral_speed = sim_lateral_speed * std::cos(heading_delta)
						  + effective_speed * std::sin(heading_delta);
		sim_lateral_speed *= std::exp(-lateral_drag * dt);

		float cur_fwd_x = std::sin(sim_heading);
		float cur_fwd_z = std::cos(sim_heading);
		float cur_lat_x = cur_fwd_z;
		float cur_lat_z = -cur_fwd_x;
		sim_pos.x += cur_fwd_x * effective_speed * dt + cur_lat_x * sim_lateral_speed * dt;
		sim_pos.y += cur_fwd_z * effective_speed * dt + cur_lat_z * sim_lateral_speed * dt;

		sim_time += dt;

		float step_dist = sim_pos.distance_to(prev_pos);
		total_distance += step_dist;
		prev_pos = sim_pos;

		if (total_distance >= next_emit_dist) {
			arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
			next_emit_dist += emit_interval;
		}

		// Check alignment once the rudder has settled to the commanded value.
		// Before that, the ship is still on its old arc and may momentarily
		// point at the waypoint — that's a false positive, not real alignment.
		if (rudder_settled) {
			Vector2 to_target = target_pos - sim_pos;
			float dist_to_target = to_target.length();
			if (dist_to_target > 1.0f) {
				float desired_heading = std::atan2(to_target.x, to_target.y);
				float heading_error = std::abs(angle_difference(sim_heading, desired_heading));
				if (heading_error < alignment_threshold) {
					aligned = true;
					arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
					break;
				}
			}
		}
	}

	if (arc.size() < 2 || arc.back().position.distance_to(sim_pos) > 1.0f) {
		arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
	}

	return arc;
}

float ShipNavigator::check_arc_collision(const std::vector<ArcPoint> &arc,
										  float hard_clearance, float soft_clearance) const {
	if (map.is_null() || !map->is_built()) return std::numeric_limits<float>::infinity();
	if (arc.empty()) return std::numeric_limits<float>::infinity();

	float first_soft_violation = std::numeric_limits<float>::infinity();
	bool arc_exits_soft_zone = false;
	bool was_in_soft_zone = false;
	int valid_points = 0;

	for (size_t i = 0; i < arc.size(); i++) {
		const auto &pt = arc[i];
		float sdf = map->get_distance(pt.position.x, pt.position.y);

		if (sdf < hard_clearance) {
			if (pt.time == 0.0f) {
				// Already inside hard clearance — find time to exit and negate it.
				// More negative = longer to escape = worse.
				for (size_t j = i + 1; j < arc.size(); j++) {
					float exit_sdf = map->get_distance(arc[j].position.x, arc[j].position.y);
					if (exit_sdf >= hard_clearance) {
						return -arc[j].time;
					}
				}
				// Never escaped — return negative arc duration (worst case)
				return -arc.back().time;
			}
			return pt.time;
		}

		if (sdf < soft_clearance) {
			if (!was_in_soft_zone) {
				was_in_soft_zone = true;
			}
			if (first_soft_violation > pt.time) {
				first_soft_violation = pt.time;
			}
		} else {
			if (was_in_soft_zone) {
				arc_exits_soft_zone = true;
			}
			valid_points++;
		}
	}

	if (was_in_soft_zone && !arc_exits_soft_zone && valid_points < 3) {
		// If the first soft violation is at t=0, the arc starts inside the
		// soft zone.  Find exit time and negate it, same as the hard case.
		if (first_soft_violation == 0.0f) {
			for (size_t i = 0; i < arc.size(); i++) {
				float sdf = map->get_distance(arc[i].position.x, arc[i].position.y);
				if (sdf >= soft_clearance) {
					return -arc[i].time;
				}
			}
			return -arc.back().time;
		}
		return first_soft_violation;
	}

	return std::numeric_limits<float>::infinity();
}

float ShipNavigator::check_arc_obstacles(const std::vector<ArcPoint> &arc) const {
	return check_arc_obstacles_detailed(arc).time_to_collision;
}

ObstacleCollisionInfo ShipNavigator::check_arc_obstacles_detailed(const std::vector<ArcPoint> &arc) const {
	ObstacleCollisionInfo result;
	float clearance = get_ship_clearance();

	for (const auto &[id, obs] : obstacles) {
		// When parked, skip non-torpedo obstacles — the moving ship should
		// be the one that avoids, not a stationary ship holding position.
		if (skip_ship_obstacles_ && !obs.is_torpedo()) continue;

		for (const auto &pt : arc) {
			Vector2 obs_pos = obs.position + obs.velocity * pt.time;
			float dist = pt.position.distance_to(obs_pos);

			if (dist < clearance + obs.radius) {
				if (pt.time < result.time_to_collision) {
					result.has_collision = true;
					result.time_to_collision = pt.time;
					result.obstacle_id = id;
					result.obstacle_length = obs.length;
					result.obstacle_position = obs_pos;
					result.obstacle_velocity = obs.velocity;
					result.is_torpedo = obs.is_torpedo();

					Vector2 to_obs = obs_pos - state.position;
					float bearing_to_obs = std::atan2(to_obs.x, to_obs.y);
					result.relative_bearing = angle_difference(state.heading, bearing_to_obs);
				}
				break;
			}
		}
	}

	return result;
}

// ============================================================================
// Steering pipeline helpers
// ============================================================================

float ShipNavigator::compute_rudder_to_position(Vector2 target_pos, bool reverse) const {
	Vector2 to_target = target_pos - state.position;
	float target_angle = std::atan2(to_target.x, to_target.y);

	if (reverse) {
		// Desired bow direction: pointing away from target so stern faces target.
		float bow_away = normalize_angle(target_angle + Math_PI);
		return compute_rudder_to_heading(bow_away, true);
	}

	return compute_rudder_to_heading(target_angle);
}

float ShipNavigator::compute_rudder_to_heading(float desired_heading, bool reverse) const {
	float angle_diff = angle_difference(state.heading, desired_heading);
	float abs_diff = std::abs(angle_diff);

	float rudder_travel_time = std::abs(0.0f - state.current_rudder) * params.rudder_response_time;
	float heading_drift = state.angular_velocity_y * rudder_travel_time;

	float effective_target = desired_heading - heading_drift * 0.5f;
	float effective_diff = angle_difference(state.heading, effective_target);
	float abs_effective_diff = std::abs(effective_diff);

	float rudder;

	const float full_rudder_threshold = static_cast<float>(Math_PI / 6.0);

	if (abs_effective_diff < 0.02f) {
		rudder = 0.0f;
	} else if (abs_effective_diff > full_rudder_threshold) {
		rudder = (effective_diff > 0.0f) ? -1.0f : 1.0f;
	} else {
		float t = (abs_effective_diff - 0.02f) / (full_rudder_threshold - 0.02f);
		rudder = lerp_f(0.1f, 1.0f, t);
		if (effective_diff < 0.0f) rudder = -rudder;
		rudder = -rudder;
	}

	float lead_threshold = std::abs(state.angular_velocity_y * params.rudder_response_time * 0.3f);
	if (abs_diff < lead_threshold) {
		float lead_factor = abs_diff / std::max(0.01f, lead_threshold);
		rudder *= lead_factor;
	}

	// In reverse, the physics inverts rudder effect:
	//   omega = (speed / R) * (-rudder), and speed is negative,
	//   so the same rudder value produces the opposite turn direction.
	// Negate the rudder to compensate.
	if (reverse) rudder = -rudder;

	return clamp_f(rudder, -1.0f, 1.0f);
}

int ShipNavigator::compute_magnitude_for_approach(float distance_to_target) const {
	float max_decel = params.max_speed / std::max(params.acceleration_time, 0.1f);
	if (max_decel < 0.001f) return 0;

	// Within ship beam: fully stopped
	if (distance_to_target < params.ship_beam * 2.0f) {
		return 0;
	}

	// Pick the highest magnitude whose target speed we can decelerate from
	// within the remaining distance.  For each candidate magnitude, compute
	// the distance needed to decelerate from current speed to that magnitude's
	// target speed: d = (v² - v_target²) / (2 * decel).
	// We add a safety margin so the ship starts slowing a bit early.
	float safety_margin = params.turning_circle_radius * 0.5f;
	float v = std::abs(state.current_speed);

	// Magnitudes 4→1, check from highest to lowest
	const int magnitudes[] = { 4, 3, 2, 1 };
	for (int mag : magnitudes) {
		float target_speed = throttle_to_speed(mag);
		if (target_speed >= v) return mag; // already at or below target — use this magnitude
		float decel_dist = (v * v - target_speed * target_speed) / (2.0f * max_decel);
		if (distance_to_target > decel_dist + safety_margin) {
			return mag;
		}
	}

	// Within stopping distance from a crawl — use minimum forward
	return 1;
}

int ShipNavigator::resolve_throttle(DesiredDirection dir, int magnitude) const {
	if (magnitude <= 0) return 0;
	if (dir == DesiredDirection::BACKWARD) return -1;
	return magnitude; // 1, 2, 3, or 4
}

// ============================================================================
// Waypoint following
// ============================================================================

void ShipNavigator::advance_waypoint() {
	if (!path_valid || current_path.waypoints.empty()) return;

	while (current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		if (is_waypoint_reached(current_path.waypoints[current_wp_index])) {
			current_wp_index++;
		} else {
			break;
		}
	}

	int last_wp = static_cast<int>(current_path.waypoints.size()) - 1;
	while (current_wp_index < last_wp) {
		if (is_waypoint_in_turning_dead_zone(current_path.waypoints[current_wp_index])) {
			current_wp_index++;
		} else {
			break;
		}
	}

	// Don't clamp back — let path_exhausted detect that all waypoints are consumed
}

bool ShipNavigator::is_waypoint_reached(Vector2 waypoint) const {
	Vector2 to_wp = waypoint - state.position;
	float dist = to_wp.length();

	float reach_radius = get_reach_radius();

	if (dist < reach_radius) return true;

	Vector2 forward(std::sin(state.heading), std::cos(state.heading));
	float along_track = to_wp.x * forward.x + to_wp.y * forward.y;

	if (along_track < 0.0f && dist < reach_radius * 2.0f) return true;

	return false;
}

bool ShipNavigator::is_waypoint_in_turning_dead_zone(Vector2 waypoint) const {
	float r = params.turning_circle_radius;
	if (r < 1.0f) return false;

	float perp_x = std::cos(state.heading);
	float perp_z = -std::sin(state.heading);

	Vector2 center_starboard(
		state.position.x + perp_x * r,
		state.position.y + perp_z * r
	);
	Vector2 center_port(
		state.position.x - perp_x * r,
		state.position.y - perp_z * r
	);

	float dist_starboard = waypoint.distance_to(center_starboard);
	float dist_port = waypoint.distance_to(center_port);

	float threshold = r * 0.9f;

	return (dist_starboard < threshold || dist_port < threshold);
}

Vector2 ShipNavigator::find_path_lookahead(float lookahead_dist) const {
	if (!path_valid || current_path.waypoints.empty()) return target.position;

	int last = static_cast<int>(current_path.waypoints.size()) - 1;
	int idx = current_wp_index;
	if (idx > last) idx = last;

	Vector2 pos = state.position;
	float remaining = lookahead_dist;

	while (remaining > 0.0f && idx <= last) {
		Vector2 wp = current_path.waypoints[idx];
		float seg_dist = pos.distance_to(wp);

		if (seg_dist >= remaining) {
			Vector2 dir = (wp - pos).normalized();
			return pos + dir * remaining;
		}

		remaining -= seg_dist;
		pos = wp;
		idx++;
	}

	return current_path.waypoints[last];
}
