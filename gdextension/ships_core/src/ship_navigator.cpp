#include "ship_navigator.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <algorithm>
#include <sstream>

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
		"ship_length", "ship_beam", "turn_speed_loss"),
		&ShipNavigator::set_ship_params);

	// Per-frame state
	ClassDB::bind_method(D_METHOD("set_state",
		"position", "velocity", "heading",
		"angular_velocity_y", "current_rudder", "current_speed", "delta"),
		&ShipNavigator::set_state);

	// Navigation commands
	ClassDB::bind_method(D_METHOD("navigate_to", "target", "heading", "hold_radius", "heading_tolerance"),
		&ShipNavigator::navigate_to, DEFVAL(0.0f), DEFVAL(0.2618f));
	ClassDB::bind_method(D_METHOD("stop"), &ShipNavigator::stop);

	// Output
	ClassDB::bind_method(D_METHOD("get_rudder"), &ShipNavigator::get_rudder);
	ClassDB::bind_method(D_METHOD("get_throttle"), &ShipNavigator::get_throttle);
	ClassDB::bind_method(D_METHOD("get_nav_state"), &ShipNavigator::get_nav_state);
	ClassDB::bind_method(D_METHOD("is_collision_imminent"), &ShipNavigator::is_collision_imminent);
	ClassDB::bind_method(D_METHOD("get_time_to_collision"), &ShipNavigator::get_time_to_collision);

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
	ClassDB::bind_method(D_METHOD("get_debug_info"), &ShipNavigator::get_debug_info);
	ClassDB::bind_method(D_METHOD("get_clearance_radius"), &ShipNavigator::get_ship_clearance);
	ClassDB::bind_method(D_METHOD("get_soft_clearance_radius"), &ShipNavigator::get_soft_clearance);

	// Backward-compatible stubs
	ClassDB::bind_method(D_METHOD("validate_destination_pose", "ship_position", "candidate"), &ShipNavigator::validate_destination_pose);
	ClassDB::bind_method(D_METHOD("get_simulated_path"), &ShipNavigator::get_simulated_path);
	ClassDB::bind_method(D_METHOD("is_simulation_complete"), &ShipNavigator::is_simulation_complete);

	// Enum constants for NavState
	BIND_CONSTANT(0);  // PLANNING
	BIND_CONSTANT(1);  // NAVIGATING
	BIND_CONSTANT(2);  // ARRIVING
	BIND_CONSTANT(3);  // SETTLING
	BIND_CONSTANT(4);  // HOLDING
	BIND_CONSTANT(5);  // AVOIDING
	BIND_CONSTANT(6);  // EMERGENCY
}

// ============================================================================
// Constructor / Destructor
// ============================================================================

ShipNavigator::ShipNavigator() {
	nav_state = NavState::HOLDING;
	current_wp_index = 0;
	path_valid = false;
	settle_timer = 0.0f;
	hold_timer = 0.0f;
	stuck_timer = 0.0f;
	replan_frame_cooldown = 0;
	settle_dir = 1;
	out_rudder = 0.0f;
	out_throttle = 0;
	out_collision_imminent = false;
	out_time_to_collision = std::numeric_limits<float>::infinity();
}

ShipNavigator::~ShipNavigator() {
}

// ============================================================================
// Setup
// ============================================================================

void ShipNavigator::set_map(Ref<NavigationMap> p_map) {
	map = p_map;
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
	float turn_speed_loss
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

	// Tick timers
	if (replan_frame_cooldown > 0) replan_frame_cooldown--;
	avoidance.tick(delta);

	// Run state machine
	update(delta);

	// Update predicted arc for debug visualization
	update_predicted_arc();
}

// ============================================================================
// Navigation commands
// ============================================================================

void ShipNavigator::navigate_to(Vector3 p_target, float p_heading, float p_hold_radius, float p_heading_tolerance) {
	Vector2 new_pos(p_target.x, p_target.z);
	float dist_change = new_pos.distance_to(target.position);
	float heading_change = std::abs(angle_difference(target.heading, p_heading));

	bool position_changed = dist_change > params.turning_circle_radius * 0.5f;
	bool heading_changed = heading_change > 0.35f;  // ~20 degrees
	bool radius_changed = std::abs(p_hold_radius - target.hold_radius) > 50.0f;

	target.position = new_pos;
	target.heading = p_heading;
	target.hold_radius = p_hold_radius;
	target.heading_tolerance = p_heading_tolerance;

	if (position_changed || radius_changed) {
		// Meaningful target change — replan
		nav_state = NavState::PLANNING;
	} else if (heading_changed) {
		// Heading changed but position didn't
		if (nav_state == NavState::HOLDING) {
			nav_state = NavState::SETTLING;
			settle_timer = 0.0f;
		}
	}
	// else: trivial change — ignore
}

void ShipNavigator::stop() {
	target.position = state.position;
	target.heading = state.heading;
	target.hold_radius = 0.0f;
	path_valid = false;
	nav_state = NavState::HOLDING;
	set_steering_output(0.0f, 0, false, std::numeric_limits<float>::infinity());
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

float ShipNavigator::get_time_to_collision() const {
	return out_time_to_collision;
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
		// Encode waypoint flags in Y channel for debug visualization:
		// Y = 0 normal, Y = 1 reverse, Y = 2 departure, Y = 3 reverse+departure
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
	for (const auto &pt : predicted_arc) {
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
	// For all states, the target heading is the desired heading
	return target.heading;
}

float ShipNavigator::get_distance_to_destination() const {
	return state.position.distance_to(target.position);
}

String ShipNavigator::get_debug_info() const {
	std::ostringstream oss;

	const char *state_names[] = {"PLANNING", "NAVIGATING", "ARRIVING",
		"SETTLING", "HOLDING", "AVOIDING", "EMERGENCY"};

	int si = static_cast<int>(nav_state);

	oss << "state=" << (si >= 0 && si <= 6 ? state_names[si] : "?")
		<< " rudder=" << out_rudder
		<< " throttle=" << out_throttle
		<< " speed=" << state.current_speed
		<< " dist=" << state.position.distance_to(target.position)
		<< " hold_r=" << target.hold_radius
		<< " path_valid=" << path_valid
		<< " wp=" << current_wp_index << "/" << current_path.waypoints.size()
		<< " collision=" << out_collision_imminent
		<< " ttc=" << out_time_to_collision;

	return String(oss.str().c_str());
}

// ============================================================================
// Backward-compatible API stubs
// ============================================================================

Dictionary ShipNavigator::validate_destination_pose(Vector3 ship_position, Vector3 candidate) {
	Vector2 ship_pos_2d(ship_position.x, ship_position.z);
	Vector2 cand_2d(candidate.x, candidate.z);
	float clearance = get_ship_clearance();

	Vector2 safe_pos = cand_2d;
	bool adjusted = false;
	float heading = 0.0f;

	if (map.is_valid() && map->is_built()) {
		safe_pos = map->safe_nav_point(ship_pos_2d, cand_2d, clearance, params.turning_circle_radius);
		adjusted = safe_pos.distance_to(cand_2d) > 10.0f;

		Vector2 approach = safe_pos - ship_pos_2d;
		if (approach.length_squared() > 1.0f) {
			heading = std::atan2(approach.x, approach.y);
		}
	}

	Dictionary dict;
	dict["position"] = Vector3(safe_pos.x, 0.0f, safe_pos.y);
	dict["heading"] = heading;
	dict["valid"] = true;
	dict["adjusted"] = adjusted;
	return dict;
}

PackedVector3Array ShipNavigator::get_simulated_path() const {
	return get_predicted_trajectory();
}

bool ShipNavigator::is_simulation_complete() const {
	return true;
}

// ============================================================================
// Internal helpers
// ============================================================================

float ShipNavigator::get_ship_clearance() const {
	return params.ship_beam + get_safety_margin();
}

float ShipNavigator::get_soft_clearance() const {
	float hard = get_ship_clearance();
	float soft = std::max(hard, params.turning_circle_radius) + get_safety_margin();
	return soft;
}

float ShipNavigator::get_safety_margin() const {
	return std::max(150.0f, params.ship_beam * 2.0f);
}

float ShipNavigator::get_lookahead_distance() const {
	float speed = std::max(std::abs(state.current_speed), params.max_speed * 0.5f);
	float rudder_lag_dist = speed * params.rudder_response_time;
	float turn_arc = params.turning_circle_radius * 1.57f; // PI/2
	float physics_dist = rudder_lag_dist + turn_arc + params.ship_length;
	float legacy_min = params.ship_length * 3.0f;
	float stopping = get_stopping_distance();
	float dist = std::max({legacy_min, physics_dist, stopping + params.ship_length * 2.0f});
	float max_dist = std::max(params.ship_length * 8.0f, 3000.0f);
	return std::min(dist, max_dist);
}

float ShipNavigator::get_stopping_distance() const {
	float max_decel = params.max_speed / std::max(params.deceleration_time, 0.1f);
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

float ShipNavigator::get_approach_radius() const {
	return std::max(params.turning_circle_radius * 2.0f, get_stopping_distance() * 1.5f);
}

void ShipNavigator::set_steering_output(float rudder, int throttle, bool collision, float ttc) {
	out_rudder = rudder;
	out_throttle = throttle;
	out_collision_imminent = collision;
	out_time_to_collision = ttc;
}

void ShipNavigator::update_predicted_arc() {
	predicted_arc = predict_arc_internal(out_rudder, out_throttle, get_lookahead_distance());
}

// ============================================================================
// Unified State Machine
// ============================================================================

void ShipNavigator::update(float delta) {
	switch (nav_state) {
		case NavState::PLANNING:    update_planning(); break;
		case NavState::NAVIGATING:  update_navigating(delta); break;
		case NavState::ARRIVING:    update_arriving(delta); break;
		case NavState::SETTLING:    update_settling(delta); break;
		case NavState::HOLDING:     update_holding(delta); break;
		case NavState::AVOIDING:    update_navigating(delta); break; // same loop, avoidance tracked separately
		case NavState::EMERGENCY:   update_emergency(); break;
	}
}

void ShipNavigator::update_planning() {
	compute_path();

	if (path_valid) {
		stuck_timer = 0.0f;
		nav_state = NavState::NAVIGATING;
	} else {
		// No path found — try to reach destination directly
		float dist = state.position.distance_to(target.position);
		if (dist < params.turning_circle_radius * 0.5f) {
			nav_state = NavState::ARRIVING;
		} else {
			nav_state = NavState::HOLDING;
		}
	}

	// Always produce steering output even on the planning frame
	update(0.0f);
}

void ShipNavigator::update_navigating(float delta) {
	// --- 1. Advance waypoints ---
	advance_waypoint();

	// --- 2. Check: arrived at approach radius? ---
	// Skip this check while executing departure waypoints (e.g. 3-point turn
	// heading correction) — the ship is already near the destination and needs
	// to follow the correction path before re-entering arrival.
	float dist_to_dest = state.position.distance_to(target.position);
	float approach_radius = get_approach_radius();
	bool on_departure_leg = path_valid
		&& current_wp_index < (int)current_path.flags.size()
		&& (current_path.flags[current_wp_index] & WP_DEPARTURE) != 0;
	if (dist_to_dest < approach_radius && !on_departure_leg) {
		nav_state = NavState::ARRIVING;
		return;
	}

	// --- 3. Determine steer target and direction ---
	Vector2 steer_target;
	bool use_reverse = false;

	if (path_valid && current_wp_index < (int)current_path.waypoints.size()) {
		steer_target = current_path.waypoints[current_wp_index];
		use_reverse = current_waypoint_is_reverse();
	} else {
		steer_target = target.position;
	}

	// --- 4. Compute steering ---
	float desired_rudder = compute_rudder_to_position(steer_target, use_reverse);

	int desired_throttle;
	if (use_reverse) {
		desired_throttle = -1;
	} else {
		// desired_throttle = compute_throttle_for_approach(dist_to_dest);
		// float turn_angle = std::abs(angle_difference(state.heading,
		// 	std::atan2(steer_target.x - state.position.x,
		// 			   steer_target.y - state.position.y)));
		// if (turn_angle > Math_PI * 0.5f && desired_throttle > 2) {
		// 	desired_throttle = 2;
		// }
		desired_throttle = 4;  // full forward, no speed limit while navigating (except collision avoidance)
	}

	// --- 5. Collision avoidance ---
	float ttc;
	bool collision;
	float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

	// --- 6. State transitions ---
	if (collision && ttc < 3.0f) {
		nav_state = NavState::EMERGENCY;
	} else if (collision) {
		nav_state = NavState::AVOIDING;
	} else if (nav_state == NavState::AVOIDING) {
		nav_state = NavState::NAVIGATING;
	}

	// --- 7. Compute final throttle ---
	int final_throttle;
	if (collision) {
		if (nav_state == NavState::EMERGENCY) {
			final_throttle = out_throttle;
		} else {
			final_throttle = std::min(desired_throttle, std::max(use_reverse ? -1 : 1, out_throttle));
		}
	} else {
		final_throttle = desired_throttle;
	}

	set_steering_output(safe_rudder, final_throttle, collision, ttc);

	// --- 8. Stuck detection ---
	if (std::abs(state.current_speed) < SPEED_THRESHOLD && !use_reverse) {
		stuck_timer += delta;
		if (stuck_timer > STUCK_TIME_THRESHOLD) {
			nav_state = NavState::PLANNING;
			stuck_timer = 0.0f;
		}
	} else {
		stuck_timer = 0.0f;
	}

	// --- 9. Replan check ---
	if (check_replan_needed()) {
		nav_state = NavState::PLANNING;
	}
}

void ShipNavigator::update_arriving(float delta) {
	float dist = state.position.distance_to(target.position);
	float heading_error = std::abs(angle_difference(state.heading, target.heading));

	// Close enough in position? Start settling.
	if (dist < params.turning_circle_radius * 0.3f) {
		nav_state = NavState::SETTLING;
		settle_timer = 0.0f;
		settle_dir = 1;  // Start moving forward when settling begins
		return;
	}

	// Drifted too far back out? Return to planning.
	float approach_radius = get_approach_radius();
	if (dist > approach_radius * 1.5f) {
		nav_state = NavState::PLANNING;
		return;
	}

	// Overshoot detection: ship was moving forward and is now past the target.
	// Use current_speed to determine if we overshot (still moving forward but
	// target is receding) rather than the instantaneous along_track which flips.
	Vector2 to_target = target.position - state.position;
	Vector2 forward_dir(std::sin(state.heading), std::cos(state.heading));
	float along_track = to_target.x * forward_dir.x + to_target.y * forward_dir.y;
	bool overshot = (along_track < -params.ship_beam) && (state.current_speed > -SPEED_THRESHOLD);

	float desired_rudder;
	int desired_throttle;

	if (overshot) {
		// Past the target while still moving forward — reverse back
		desired_rudder = compute_rudder_to_position(target.position, true);
		desired_throttle = -1;
	} else {
		// Normal approach: blend position and heading steering
		float heading_weight = 1.0f - (dist / approach_radius);
		heading_weight = clamp_f(heading_weight, 0.0f, 0.7f);

		float pos_rudder = compute_rudder_to_position(target.position);
		float heading_rudder = compute_rudder_to_heading(target.heading);
		desired_rudder = lerp_f(pos_rudder, heading_rudder, heading_weight);

		desired_throttle = compute_throttle_for_approach(dist);
		desired_throttle = std::min(desired_throttle, 2);
	}

	// Collision avoidance
	float ttc;
	bool collision;
	float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

	int final_throttle;
	if (collision) {
		final_throttle = (desired_throttle < 0) ? 0 : std::min(desired_throttle, 1);
	} else {
		final_throttle = desired_throttle;
	}

	set_steering_output(safe_rudder, final_throttle, collision, ttc);
}

void ShipNavigator::update_settling(float delta) {
	settle_timer += delta;
	float heading_error = std::abs(angle_difference(state.heading, target.heading));
	float speed = std::abs(state.current_speed);
	float dist = state.position.distance_to(target.position);

	// Heading achieved?
	if (heading_error < target.heading_tolerance && speed < SPEED_THRESHOLD) {
		nav_state = NavState::HOLDING;
		hold_timer = 0.0f;
		return;
	}

	// Drifted too far from position?
	float max_drift = (target.hold_radius > 0.0f)
		? target.hold_radius * 1.5f
		: params.turning_circle_radius;
	if (dist > max_drift) {
		nav_state = NavState::PLANNING;
		return;
	}

	// --- Pendulum heading correction ---
	// The ship bounces forward and backward within the station zone while its
	// rudder turns it toward the desired heading.
	// settle_dir (+1 or -1) is the committed motion direction and only flips
	// when the ship has reached the zone boundary with speed in the outward direction.
	float zone_radius = std::max(target.hold_radius, params.turning_circle_radius * 0.5f);
	float zone_edge = zone_radius * 0.8f;

	// Flip settle_dir only when: at zone edge AND moving outward (speed matches settle_dir)
	// The outward speed check prevents flipping when the ship is decelerating at the edge.
	float outward_speed = state.current_speed * static_cast<float>(settle_dir);
	if (dist > zone_edge && outward_speed > SPEED_THRESHOLD) {
		settle_dir = -settle_dir;
	}

	int desired_throttle;
	if (heading_error < target.heading_tolerance) {
		desired_throttle = 0;
	} else {
		desired_throttle = settle_dir;
	}

	// Rudder steers toward desired heading; flip sense when reversing
	bool use_reverse = (desired_throttle < 0);
	float desired_rudder;
	if (heading_error > 0.05f) {
		desired_rudder = use_reverse
			? -compute_rudder_to_heading(target.heading)
			: compute_rudder_to_heading(target.heading);
	} else {
		desired_rudder = 0.0f;
	}

	// Collision avoidance
	float ttc;
	bool collision;
	float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

	int final_throttle = collision ? 0 : desired_throttle;
	set_steering_output(safe_rudder, final_throttle, collision, ttc);
}

void ShipNavigator::update_holding(float delta) {
	hold_timer += delta;
	float dist = state.position.distance_to(target.position);
	float heading_error = std::abs(angle_difference(state.heading, target.heading));

	// Drifted out of zone?
	float max_drift = (target.hold_radius > 0.0f)
		? target.hold_radius
		: params.turning_circle_radius * 0.5f;
	if (dist > max_drift) {
		nav_state = NavState::PLANNING;
		return;
	}

	// Heading drifted significantly?
	if (heading_error > target.heading_tolerance * 2.0f) {
		nav_state = NavState::SETTLING;
		settle_timer = 0.0f;
		return;
	}

	// Check if the ship has drifted past the target while still moving forward.
	// Use current_speed to avoid the instantaneous along_track flip.
	Vector2 to_target = target.position - state.position;
	Vector2 forward_dir(std::sin(state.heading), std::cos(state.heading));
	float along_track = to_target.x * forward_dir.x + to_target.y * forward_dir.y;
	bool overshot = (along_track < -params.ship_beam) && (state.current_speed > -SPEED_THRESHOLD);

	float rudder = 0.0f;
	int throttle = 0;

	if (overshot) {
		// Drifted past — reverse back
		rudder = compute_rudder_to_position(target.position, true);
		throttle = -1;
	} else {
		// Micro-corrections (forward)
		if (heading_error > target.heading_tolerance) {
			rudder = compute_rudder_to_heading(target.heading);
			rudder = clamp_f(rudder, -0.3f, 0.3f);
		}
		if (std::abs(rudder) > 0.1f && std::abs(state.current_speed) < 1.0f) {
			throttle = 1;
		}
	}

	// Even in holding, check for collisions
	float ttc;
	bool collision;
	float safe_rudder = select_safe_rudder(rudder, throttle, ttc, collision);

	set_steering_output(safe_rudder, collision ? 0 : throttle, collision, ttc);
}

void ShipNavigator::update_emergency() {
	// Check if we've cleared the emergency
	auto desired_arc = predict_arc_internal(0.0f, 2, get_lookahead_distance());
	float ttc = check_arc_collision(desired_arc, get_ship_clearance() / 2.0, get_soft_clearance());
	float arc_time = desired_arc.empty() ? 0.0f : desired_arc.back().time;

	if (ttc >= arc_time * 0.9f) {
		// Clear — replan from here
		nav_state = NavState::PLANNING;
		return;
	}

	// Still in danger — gradient escape
	if (map.is_valid() && map->is_built()) {
		Vector2 grad = map->get_gradient(state.position.x, state.position.y);
		float escape_heading = std::atan2(grad.x, grad.y);
		float rudder = compute_rudder_to_heading(escape_heading);
		float angle_to_escape = std::abs(angle_difference(state.heading, escape_heading));

		if (angle_to_escape < Math_PI * 0.5f) {
			set_steering_output(rudder, 2, true, ttc);
		} else {
			set_steering_output(rudder, -1, true, ttc);
		}
	} else {
		float rudder = (state.angular_velocity_y > 0.0f) ? 1.0f : -1.0f;
		set_steering_output(rudder, -1, true, ttc);
	}
}

// ============================================================================
// Heading correction planner (3-point turn)
// ============================================================================

void ShipNavigator::plan_heading_correction() {
	// The ship is near target.position but facing the wrong way.
	// Strategy: reverse along the OPPOSITE of the target heading, then drive
	// forward back to target.position. This naturally aligns the ship with
	// the desired heading on the forward approach.
	//
	// Path: [reverse_wp (WP_REVERSE)] → [target.position (forward)]

	float reverse_heading = angle_difference(0.0f, target.heading + Math_PI);
	float room_reverse = estimate_room_in_direction(reverse_heading);

	float reverse_dist = std::min(room_reverse, params.ship_length * 1.5f);
	reverse_dist = std::max(reverse_dist, params.ship_beam);

	Vector2 reverse_dir(std::sin(reverse_heading), std::cos(reverse_heading));
	Vector2 wp_reverse = state.position + reverse_dir * reverse_dist;

	// Validate navigability, shorten if needed
	if (!map.is_null() && map->is_built()) {
		float clearance = get_ship_clearance();
		if (map->get_distance(wp_reverse.x, wp_reverse.y) < clearance) {
			for (float frac = 0.75f; frac >= 0.25f; frac -= 0.25f) {
				Vector2 test = state.position + reverse_dir * (reverse_dist * frac);
				if (map->get_distance(test.x, test.y) >= clearance) {
					wp_reverse = test;
					break;
				}
			}
		}
	}

	// Build the correction path
	current_path.waypoints.clear();
	current_path.flags.clear();

	// WP0: reverse to a point behind where target heading points
	current_path.waypoints.push_back(wp_reverse);
	current_path.flags.push_back(WP_REVERSE | WP_DEPARTURE);

	// WP1: drive forward back to target position (approach aligns with target heading)
	current_path.waypoints.push_back(target.position);
	current_path.flags.push_back(WP_DEPARTURE);

	current_path.valid = true;
	path_valid = true;
	current_wp_index = 0;
}

float ShipNavigator::estimate_room_in_direction(float heading) const {
	if (map.is_null() || !map->is_built()) return params.ship_length * 2.0f;

	float clearance = get_ship_clearance();
	Vector2 dir(std::sin(heading), std::cos(heading));

	for (float d = params.ship_beam; d <= params.ship_length * 3.0f; d += params.ship_beam) {
		Vector2 test = state.position + dir * d;
		if (map->get_distance(test.x, test.y) < clearance) {
			return std::max(d - params.ship_beam, 0.0f);
		}
	}
	return params.ship_length * 3.0f;
}

// ============================================================================
// Path replan checks
// ============================================================================

bool ShipNavigator::check_replan_needed() {
	if (replan_frame_cooldown > 0) return false;

	// Path deviation
	if (path_valid && current_wp_index < (int)current_path.waypoints.size()) {
		Vector2 nearest_wp = current_path.waypoints[current_wp_index];
		float dist = state.position.distance_to(nearest_wp);
		if (dist > params.turning_circle_radius * 2.0f) {
			replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
			return true;
		}

		// Current waypoint in turning dead zone (and it's the last one)
		if (current_wp_index >= (int)current_path.waypoints.size() - 1) {
			if (is_waypoint_in_turning_dead_zone(nearest_wp)) {
				replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
				return true;
			}
		}
	}

	// Avoidance just cleared — check if path is still viable
	if (!avoidance.active && nav_state == NavState::AVOIDING) {
		replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
		return true;
	}

	return false;
}

bool ShipNavigator::current_waypoint_is_reverse() const {
	if (!path_valid || current_wp_index >= (int)current_path.waypoints.size()) return false;
	if (current_wp_index >= (int)current_path.flags.size()) return false;
	return (current_path.flags[current_wp_index] & WP_REVERSE) != 0;
}

void ShipNavigator::flag_reverse_departure(PathResult &path, float ship_heading) {
	for (int i = 0; i < (int)path.waypoints.size(); i++) {
		if (i == 0) {
			path.flags[i] |= WP_REVERSE | WP_DEPARTURE;
			continue;
		}

		Vector2 dir = (path.waypoints[i] - path.waypoints[i - 1]).normalized();
		float wp_heading = std::atan2(dir.x, dir.y);

		float angle_diff = std::abs(angle_difference(ship_heading, wp_heading));
		if (angle_diff < Math_PI * 0.5f) {
			break;
		} else {
			path.flags[i] |= WP_REVERSE;
		}
	}
}

// ============================================================================
// Path computation (replaces maybe_recalc_path)
// ============================================================================

void ShipNavigator::compute_path() {
	if (map.is_null() || !map->is_built()) {
		path_valid = false;
		return;
	}

	float min_clearance = get_ship_clearance();
	float comfortable_clearance = std::min(min_clearance + params.ship_beam * 0.5f, min_clearance * 2.0f);
	float turning_radius = params.turning_circle_radius;

	// --- Forward path (heading-aware) ---
	PathResult forward_result = map->find_path_internal(
		state.position, target.position, comfortable_clearance, turning_radius, state.heading);

	if (!forward_result.valid || forward_result.waypoints.empty()) {
		// Fallback: minimum clearance, still heading-aware
		forward_result = map->find_path_internal(
			state.position, target.position, min_clearance, turning_radius, state.heading);
	}

	if (!forward_result.valid || forward_result.waypoints.empty()) {
		// Last resort: half minimum clearance, no turning penalty, no heading
		forward_result = map->find_path_internal(state.position, target.position, min_clearance * 0.5f, 0.0f);
	}

	// --- Should we try reverse? ---
	float bearing_to_dest = std::atan2(
		target.position.x - state.position.x,
		target.position.y - state.position.y);
	float angle_to_dest = std::abs(angle_difference(state.heading, bearing_to_dest));
	float dist_to_dest = state.position.distance_to(target.position);
	float reverse_cap = params.turning_circle_radius * REVERSE_DISTANCE_CAP_FACTOR;

	bool try_reverse = (angle_to_dest > Math_PI * 0.5f)
		&& (dist_to_dest < reverse_cap)
		&& (forward_result.valid);

	if (try_reverse) {
		// Reverse heading = heading + PI
		float reverse_heading = angle_difference(0.0f, state.heading + Math_PI);
		// Use heading-aware A* with cost_bound for early termination
		PathResult reverse_result = map->find_path_internal(
			state.position, target.position, comfortable_clearance, turning_radius,
			reverse_heading, forward_result.total_distance);

		if (!reverse_result.valid || reverse_result.waypoints.empty()) {
			// Fallback: minimum clearance
			reverse_result = map->find_path_internal(
				state.position, target.position, min_clearance, turning_radius,
				reverse_heading, forward_result.total_distance);
		}

		if (reverse_result.valid && !reverse_result.waypoints.empty()
			&& reverse_result.total_distance < forward_result.total_distance) {
			// Use reverse path — flag departure waypoints as WP_REVERSE
			flag_reverse_departure(reverse_result, state.heading);
			current_path = reverse_result;
			path_valid = true;
			current_wp_index = 0;
			replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
			return;
		}
	}

	// Use forward path — but check for side-flip oscillation first.
	// If we already have a valid path and the new path goes around obstacles
	// on the opposite side, keep the old path to prevent left-right oscillation.
	if (forward_result.valid && !forward_result.waypoints.empty()) {
		bool should_accept = true;

		if (path_valid && current_path.waypoints.size() >= 2
			&& forward_result.waypoints.size() >= 2
			&& current_wp_index < (int)current_path.waypoints.size()) {

			// Compare the side of the new path vs old path relative to the
			// direct line from ship to destination. Use the cross product of
			// (ship→dest) × (ship→first_meaningful_waypoint) to determine side.
			Vector2 to_dest = target.position - state.position;

			// Old path side: use the waypoint the ship is currently heading toward
			Vector2 old_wp = current_path.waypoints[current_wp_index];
			Vector2 to_old = old_wp - state.position;
			float old_cross = to_dest.x * to_old.y - to_dest.y * to_old.x;

			// New path side: use the first waypoint that isn't at the ship position
			int new_wp_idx = 0;
			if (forward_result.waypoints.size() > 1 &&
				state.position.distance_to(forward_result.waypoints[0]) < params.turning_circle_radius * 0.25f) {
				new_wp_idx = 1;
			}
			Vector2 new_wp = forward_result.waypoints[new_wp_idx];
			Vector2 to_new = new_wp - state.position;
			float new_cross = to_dest.x * to_new.y - to_dest.y * to_new.x;

			// If sides differ (cross products have opposite signs) and the ship
			// hasn't deviated far from the old path, keep the old path
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
			// Skip the first waypoint if very close (it's our current position)
			if (current_path.waypoints.size() > 1 &&
				state.position.distance_to(current_path.waypoints[0]) < params.turning_circle_radius * 0.25f) {
				current_wp_index = 1;
			}
		}
		// else: keep current_path unchanged — the ship stays committed to its current side
	} else {
		path_valid = false;
	}

	replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
}

bool ShipNavigator::is_destination_shift_small(Vector2 old_target, Vector2 new_target) const {
	float shift = old_target.distance_to(new_target);
	if (shift < PATH_REUSE_ABSOLUTE_THRESHOLD) return true;

	float remaining = state.position.distance_to(old_target);
	if (remaining > 100.0f && shift < remaining * PATH_REUSE_RELATIVE_FRACTION) {
		return true;
	}

	return false;
}

// ============================================================================
// Arc prediction
// ============================================================================

std::vector<ArcPoint> ShipNavigator::predict_arc_internal(float commanded_rudder, int commanded_throttle,
														   float lookahead_distance, float max_time) const {
	std::vector<ArcPoint> arc;
	arc.reserve(64);

	float sim_rudder = state.current_rudder;
	float sim_speed = state.current_speed;
	float sim_heading = state.heading;
	Vector2 sim_pos = state.position;
	float sim_time = 0.0f;
	float total_distance = 0.0f;

	float target_speed_val = throttle_to_speed(commanded_throttle);

	arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, 0.0f));

	const float base_dt = 0.1f;
	const float integration_dt = std::min(
		base_dt * std::max(1.0f, params.rudder_response_time / 4.0f),
		0.5f
	);
	float emit_interval = std::max(lookahead_distance / 50.0f, params.ship_beam * 0.5f);
	float next_emit_dist = emit_interval;
	Vector2 prev_pos = sim_pos;

	float min_expected_speed = std::max(std::abs(state.current_speed), params.max_speed * 0.25f);
	float time_for_lookahead = lookahead_distance / std::max(min_expected_speed, 1.0f);
	float effective_max_time = std::max(max_time, time_for_lookahead * 1.2f);

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

		float omega = 0.0f;
		if (params.turning_circle_radius > 0.001f) {
			omega = (effective_speed / params.turning_circle_radius) * (-sim_rudder);
		}

		sim_heading += omega * dt;
		sim_heading = normalize_angle(sim_heading);
		sim_pos.x += std::sin(sim_heading) * effective_speed * dt;
		sim_pos.y += std::cos(sim_heading) * effective_speed * dt;

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

Vector2 ShipNavigator::get_steer_target() const {
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		return current_path.waypoints[current_wp_index];
	}
	if (target.position.length_squared() > 1.0f) {
		return target.position;
	}
	return Vector2(0.0f, 0.0f);
}

std::vector<ArcPoint> ShipNavigator::predict_arc_to_heading(float commanded_rudder, int commanded_throttle,
															Vector2 target_pos, float lookahead_distance,
															float max_time, float dt_scale) const {
	std::vector<ArcPoint> arc;
	arc.reserve(64);

	float sim_rudder = state.current_rudder;
	float sim_speed = state.current_speed;
	float sim_heading = state.heading;
	Vector2 sim_pos = state.position;
	float sim_time = 0.0f;
	float total_distance = 0.0f;

	float target_speed_val = throttle_to_speed(commanded_throttle);

	arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, 0.0f));

	float turning_circle_perimeter = 2.0f * Math_PI * params.turning_circle_radius;
	float max_arc_distance = std::max(lookahead_distance, turning_circle_perimeter);

	const float base_dt = 0.1f * dt_scale;
	const float integration_dt = std::min(
		base_dt * std::max(1.0f, params.rudder_response_time / 4.0f),
		0.5f * dt_scale
	);
	float emit_interval = std::max(max_arc_distance / 50.0f, params.ship_beam * 0.5f) * dt_scale;
	float next_emit_dist = emit_interval;
	Vector2 prev_pos = sim_pos;

	const float alignment_threshold = 0.087f;  // ~5 degrees

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

		if (target_speed_val > sim_speed) {
			float accel_rate = params.max_speed / std::max(params.acceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * accel_rate);
		} else {
			float decel_rate = params.max_speed / std::max(params.deceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * decel_rate);
		}

		float effective_speed = sim_speed * (1.0f - params.turn_speed_loss * std::abs(sim_rudder));

		float omega = 0.0f;
		if (params.turning_circle_radius > 0.001f) {
			omega = (effective_speed / params.turning_circle_radius) * (-sim_rudder);
		}

		sim_heading += omega * dt;
		sim_heading = normalize_angle(sim_heading);
		sim_pos.x += std::sin(sim_heading) * effective_speed * dt;
		sim_pos.y += std::cos(sim_heading) * effective_speed * dt;

		sim_time += dt;

		float step_dist = sim_pos.distance_to(prev_pos);
		total_distance += step_dist;
		prev_pos = sim_pos;

		if (total_distance >= next_emit_dist) {
			arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
			next_emit_dist += emit_interval;
		}

		if (total_distance >= lookahead_distance) {
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

	float first_soft_violation = std::numeric_limits<float>::infinity();
	bool arc_exits_soft_zone = false;
	bool was_in_soft_zone = false;
	int valid_points = 0;

	for (size_t i = 0; i < arc.size(); i++) {
		const auto &pt = arc[i];
		float sdf = map->get_distance(pt.position.x, pt.position.y);

		if (sdf < hard_clearance) {
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

bool ShipNavigator::is_give_way_vessel(const ObstacleCollisionInfo &info) const {
	if (info.is_torpedo) return true;

	float size_ratio = params.ship_length / std::max(info.obstacle_length, 50.0f);
	if (size_ratio > 1.5f) return false;
	if (size_ratio < 0.67f) return true;

	float bearing = info.relative_bearing;
	float abs_bearing = std::abs(bearing);

	if (abs_bearing < 0.175f) {
		return true;
	}

	if (bearing > 0.0f && bearing < Math_PI * 0.75f) {
		return true;
	}

	if (abs_bearing > Math_PI * 0.75f) {
		float our_speed = std::abs(state.current_speed);
		float obs_speed = info.obstacle_velocity.length();
		if (our_speed > obs_speed * 0.8f) {
			return true;
		}
	}

	return false;
}

// ============================================================================
// Steering pipeline helpers
// ============================================================================

float ShipNavigator::compute_rudder_to_position(Vector2 target_pos, bool reverse) const {
	Vector2 to_target = target_pos - state.position;
	float target_angle = std::atan2(to_target.x, to_target.y);

	if (reverse) {
		float stern_desired = normalize_angle(target_angle + Math_PI);
		return -compute_rudder_to_heading(stern_desired);
	}

	return compute_rudder_to_heading(target_angle);
}

float ShipNavigator::compute_rudder_to_heading(float desired_heading) const {
	float angle_diff = angle_difference(state.heading, desired_heading);
	float abs_diff = std::abs(angle_diff);

	float rudder_travel_time = std::abs(0.0f - state.current_rudder) * params.rudder_response_time;
	float heading_drift = state.angular_velocity_y * rudder_travel_time;

	float effective_target = desired_heading - heading_drift * 0.5f;
	float effective_diff = angle_difference(state.heading, effective_target);
	float abs_effective_diff = std::abs(effective_diff);

	float rudder;

	if (abs_effective_diff < 0.02f) {
		rudder = 0.0f;
	} else if (abs_effective_diff > Math_PI * 0.25f) {
		rudder = (effective_diff > 0.0f) ? -1.0f : 1.0f;
	} else {
		float t = (abs_effective_diff - 0.02f) / (Math_PI * 0.25f - 0.02f);
		rudder = lerp_f(0.1f, 1.0f, t);
		if (effective_diff < 0.0f) rudder = -rudder;
		rudder = -rudder;
	}

	if (abs_diff < std::abs(state.angular_velocity_y * params.rudder_response_time * 0.5f)) {
		float lead_factor = abs_diff / std::max(0.01f, std::abs(state.angular_velocity_y * params.rudder_response_time * 0.5f));
		rudder *= lead_factor;
	}

	return clamp_f(rudder, -1.0f, 1.0f);
}

int ShipNavigator::compute_throttle_for_approach(float distance_to_target) const {
	float stopping_dist = get_stopping_distance();
	float safety_margin = params.turning_circle_radius * 0.5f;

	if (distance_to_target < stopping_dist + safety_margin) {
		return 1;
	}
	if (distance_to_target < stopping_dist * 2.0f + safety_margin) {
		return 2;
	}
	if (distance_to_target < stopping_dist * 4.0f + safety_margin) {
		return 3;
	}
	return 4;
}

float ShipNavigator::select_safe_rudder(float desired_rudder, int desired_throttle,
										 float &out_ttc, bool &out_collision) {
	float hard_clearance = get_ship_clearance();
	float soft_clearance = get_soft_clearance();
	float lookahead = get_lookahead_distance();

	// Test the desired trajectory first
	auto desired_arc = predict_arc_internal(desired_rudder, desired_throttle, lookahead);
	float ttc_terrain = check_arc_collision(desired_arc, hard_clearance, soft_clearance);
	ObstacleCollisionInfo obs_info = check_arc_obstacles_detailed(desired_arc);
	float ttc_obstacles = obs_info.time_to_collision;
	float ttc = std::min(ttc_terrain, ttc_obstacles);

	out_ttc = ttc;

	float arc_total_time = desired_arc.empty() ? 0.0f : desired_arc.back().time;

	// If no collision on desired path, accept it
	if (ttc >= arc_total_time * 0.95f) {
		out_collision = false;
		if (avoidance.active && !obs_info.has_collision) {
			bool still_threatening = false;
			auto it = obstacles.find(avoidance.avoid_obstacle_id);
			if (it != obstacles.end()) {
				float dist = state.position.distance_to(it->second.position);
				if (dist < hard_clearance + it->second.radius + params.ship_length) {
					still_threatening = true;
				}
			}
			if (!still_threatening) {
				avoidance.clear();
			}
		}
		return desired_rudder;
	}

	out_collision = true;

	// =====================================================================
	// TORPEDO avoidance — fast-path, no commit timer
	// =====================================================================
	bool obstacle_is_primary_threat = (ttc_obstacles <= ttc_terrain);

	if (obstacle_is_primary_threat && obs_info.has_collision && obs_info.is_torpedo) {
		Vector2 torpedo_dir = obs_info.obstacle_velocity;
		float torp_speed = torpedo_dir.length();
		float dodge_bias = 0.0f;
		if (torp_speed > 1.0f) {
			torpedo_dir /= torp_speed;
			Vector2 ship_side = state.position - obs_info.obstacle_position;
			float cross = torpedo_dir.x * ship_side.y - torpedo_dir.y * ship_side.x;
			dodge_bias = (cross >= 0.0f) ? -1.0f : 1.0f;
		}

		const float torp_offsets_primary[]   = { 0.25f, 0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f };
		const float torp_offsets_secondary[] = {-0.25f,-0.5f,-0.75f,-1.0f,-1.25f,-1.5f,-1.75f,-2.0f };

		float best_rudder  = desired_rudder;
		float best_ttc     = ttc;
		int   best_throttle = desired_throttle;

		auto try_torpedo_candidates = [&](const float* offsets, int count, int throttle_level) {
			float last_torp_candidate = desired_rudder;
			for (int ci = 0; ci < count; ++ci) {
				float signed_offset = offsets[ci] * dodge_bias;
				float candidate = clamp_f(desired_rudder + signed_offset, -1.0f, 1.0f);
				if (candidate == desired_rudder || candidate == last_torp_candidate) continue;
				last_torp_candidate = candidate;
				auto arc = predict_arc_internal(candidate, throttle_level, lookahead);
				float cand_arc_time   = arc.empty() ? 0.0f : arc.back().time;
				float cand_ttc_terrain  = check_arc_collision(arc, hard_clearance, soft_clearance);
				float cand_ttc_obstacles = check_arc_obstacles(arc);
				float cand_ttc = std::min(cand_ttc_terrain, cand_ttc_obstacles);

				if (cand_ttc > best_ttc) {
					best_ttc      = cand_ttc;
					best_rudder   = candidate;
					best_throttle = throttle_level;
					if (best_ttc >= cand_arc_time * 0.95f) {
						return true;
					}
				}
			}
			return false;
		};

		constexpr int primary_count   = 8;
		constexpr int secondary_count = 8;

		if (!try_torpedo_candidates(torp_offsets_primary, primary_count, desired_throttle)) {
			if (!try_torpedo_candidates(torp_offsets_secondary, secondary_count, desired_throttle)) {
				int flank = std::min(desired_throttle + 2, 4);
				if (!try_torpedo_candidates(torp_offsets_primary, primary_count, flank)) {
					int slow = std::max(1, desired_throttle - 1);
					try_torpedo_candidates(torp_offsets_primary, primary_count, slow);
				}
			}
		}

		if (best_throttle != desired_throttle) {
			out_throttle = best_throttle;
		}

		if (best_ttc < 3.0f) {
			nav_state = NavState::EMERGENCY;
			best_rudder = -dodge_bias;
			out_throttle = std::min(desired_throttle + 1, 4);
		}

		out_ttc = best_ttc;
		out_collision = (best_ttc < arc_total_time * 0.95f);
		return best_rudder;
	}

	// =====================================================================
	// COLREGS-inspired asymmetric ship avoidance with size priority
	// =====================================================================
	if (avoidance.active && avoidance.commit_timer > 0.0f) {
		auto committed_arc = predict_arc_internal(avoidance.committed_rudder, desired_throttle, lookahead);
		float committed_ttc_terrain = check_arc_collision(committed_arc, hard_clearance, soft_clearance);
		float committed_total_time = committed_arc.empty() ? 0.0f : committed_arc.back().time;

		if (committed_ttc_terrain >= committed_total_time * 0.5f) {
			out_ttc = std::min(committed_ttc_terrain, check_arc_obstacles(committed_arc));
			return avoidance.committed_rudder;
		}
		avoidance.clear();
	}

	if (obstacle_is_primary_threat && obs_info.has_collision) {
		bool give_way = is_give_way_vessel(obs_info);

		if (!give_way) {
			if (ttc > AvoidanceState::STAND_ON_TTC_THRESHOLD) {
				out_collision = false;
				return desired_rudder;
			}
		}

		const float starboard_offsets[] = {
			-0.25f, -0.5f, -0.75f, -1.0f, -1.25f, -1.5f, -1.75f, -2.0f,
			 0.25f,  0.5f,  0.75f,  1.0f,  1.25f,  1.5f,  1.75f,  2.0f
		};

		float best_rudder = desired_rudder;
		float best_ttc = ttc;

		Vector2 steer_tgt = get_steer_target();
		bool have_steer_target = (steer_tgt.length_squared() > 1.0f);
		float last_candidate = desired_rudder;

		for (float offset : starboard_offsets) {
			float candidate = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
			if (candidate == desired_rudder || candidate == last_candidate) continue;
			last_candidate = candidate;
			std::vector<ArcPoint> arc;
			if (have_steer_target) {
				arc = predict_arc_to_heading(candidate, desired_throttle, steer_tgt, lookahead);
			} else {
				arc = predict_arc_internal(candidate, desired_throttle, lookahead);
			}
			float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
			float cand_ttc_terrain = check_arc_collision(arc, hard_clearance, soft_clearance);
			float cand_ttc_obstacles = check_arc_obstacles(arc);
			float cand_ttc = std::min(cand_ttc_terrain, cand_ttc_obstacles);

			if (cand_ttc > best_ttc) {
				best_ttc = cand_ttc;
				best_rudder = candidate;
				if (best_ttc >= cand_arc_time * 0.95f) {
					avoidance.begin(give_way, obs_info.obstacle_id, best_rudder);
					out_ttc = best_ttc;
					out_collision = false;
					return best_rudder;
				}
			}
		}

		if (best_ttc < arc_total_time * 0.5f) {
			int reduced_throttle = std::max(1, desired_throttle - 2);
			float last_candidate_rt = desired_rudder;
			for (float offset : starboard_offsets) {
				float candidate = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
				if (candidate == desired_rudder || candidate == last_candidate_rt) continue;
				last_candidate_rt = candidate;
				std::vector<ArcPoint> arc;
				if (have_steer_target) {
					arc = predict_arc_to_heading(candidate, reduced_throttle, steer_tgt, lookahead);
				} else {
					arc = predict_arc_internal(candidate, reduced_throttle, lookahead);
				}
				float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
				float cand_ttc = std::min(check_arc_collision(arc, hard_clearance, soft_clearance),
										  check_arc_obstacles(arc));

				if (cand_ttc > best_ttc) {
					best_ttc = cand_ttc;
					best_rudder = candidate;
					out_throttle = reduced_throttle;
					if (best_ttc >= cand_arc_time * 0.95f) {
						avoidance.begin(give_way, obs_info.obstacle_id, best_rudder);
						out_ttc = best_ttc;
						return best_rudder;
					}
				}
			}
		}

		if (best_ttc > ttc) {
			avoidance.begin(give_way, obs_info.obstacle_id, best_rudder);
		}

		if (best_ttc < 3.0f) {
			nav_state = NavState::EMERGENCY;
			out_throttle = -1;
			best_rudder = (state.angular_velocity_y > 0.0f) ? 1.0f : -1.0f;
			avoidance.begin(give_way, obs_info.obstacle_id, best_rudder);
		}

		out_ttc = best_ttc;
		return best_rudder;
	}

	// =====================================================================
	// Terrain-only avoidance
	// =====================================================================
	const float offsets[] = {
		0.25f, -0.25f, 0.5f, -0.5f, 0.75f, -0.75f, 1.0f, -1.0f,
		1.25f, -1.25f, 1.5f, -1.5f, 1.75f, -1.75f, 2.0f, -2.0f
	};
	float best_rudder = desired_rudder;
	float best_ttc = ttc;
	int best_throttle = desired_throttle;

	Vector2 steer_tgt = get_steer_target();
	bool have_steer_target = (steer_tgt.length_squared() > 1.0f);

	// Phase 1: Rudder-only — tangential alignment arcs (coarse resolution)
	// Test all candidates and pick the best; use extended lookahead for gentle rudder (<0.5)
	constexpr float terrain_dt_scale = 2.0f;
	bool tested_pos_clamp = (desired_rudder == 1.0f);
	bool tested_neg_clamp = (desired_rudder == -1.0f);
	for (float offset : offsets) {
		float candidate = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
		if (candidate == desired_rudder) continue;
		if (candidate == 1.0f && tested_pos_clamp) continue;
		if (candidate == -1.0f && tested_neg_clamp) continue;
		if (candidate == 1.0f) tested_pos_clamp = true;
		if (candidate == -1.0f) tested_neg_clamp = true;
		float cand_lookahead = (std::abs(candidate) < 0.5f) ? lookahead * 2.0f : lookahead;
		std::vector<ArcPoint> arc;
		if (have_steer_target) {
			arc = predict_arc_to_heading(candidate, desired_throttle, steer_tgt, cand_lookahead, 60.0f, terrain_dt_scale);
		} else {
			arc = predict_arc_internal(candidate, desired_throttle, cand_lookahead);
		}
		float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
		float cand_ttc_terrain = check_arc_collision(arc, hard_clearance, soft_clearance);
		float cand_ttc_obstacles = check_arc_obstacles(arc);
		float cand_ttc = std::min(cand_ttc_terrain, cand_ttc_obstacles);

		if (cand_ttc > best_ttc) {
			best_ttc = cand_ttc;
			best_rudder = candidate;
			best_throttle = desired_throttle;
		}
	}

	// If phase 1 found a clear path, return it
	if (best_ttc >= arc_total_time * 0.95f && best_rudder != desired_rudder) {
		out_ttc = best_ttc;
		out_collision = false;
		return best_rudder;
	}

	// Phase 2: Reduce throttle
	if (best_ttc < arc_total_time * 0.5f) {
		int reduced_throttle = std::max(1, desired_throttle - 2);
		tested_pos_clamp = (desired_rudder == 1.0f);
		tested_neg_clamp = (desired_rudder == -1.0f);
		for (float offset : offsets) {
			float test_rudder = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
			if (test_rudder == desired_rudder) continue;
			if (test_rudder == 1.0f && tested_pos_clamp) continue;
			if (test_rudder == -1.0f && tested_neg_clamp) continue;
			if (test_rudder == 1.0f) tested_pos_clamp = true;
			if (test_rudder == -1.0f) tested_neg_clamp = true;
			float cand_lookahead = (std::abs(test_rudder) < 0.5f) ? lookahead * 2.0f : lookahead;
			std::vector<ArcPoint> arc;
			if (have_steer_target) {
				arc = predict_arc_to_heading(test_rudder, reduced_throttle, steer_tgt, cand_lookahead, 60.0f, terrain_dt_scale);
			} else {
				arc = predict_arc_internal(test_rudder, reduced_throttle, cand_lookahead);
			}
			float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
			float cand_ttc = std::min(check_arc_collision(arc, hard_clearance, soft_clearance),
									  check_arc_obstacles(arc));

			if (cand_ttc > best_ttc) {
				best_ttc = cand_ttc;
				best_rudder = test_rudder;
				best_throttle = reduced_throttle;
			}
		}

		if (best_throttle == reduced_throttle && best_ttc >= arc_total_time * 0.95f) {
			out_throttle = best_throttle;
			out_ttc = best_ttc;
			return best_rudder;
		}
	}

	// Phase 3: Increase throttle with full rudder
	if (best_ttc < arc_total_time * 0.5f && std::abs(state.current_speed) < params.max_speed * 0.3f) {
		int boost_throttle = std::min(desired_throttle + 2, 4);
		tested_pos_clamp = (desired_rudder == 1.0f);
		tested_neg_clamp = (desired_rudder == -1.0f);
		for (float offset : offsets) {
			float test_rudder = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
			if (test_rudder == desired_rudder) continue;
			if (test_rudder == 1.0f && tested_pos_clamp) continue;
			if (test_rudder == -1.0f && tested_neg_clamp) continue;
			if (test_rudder == 1.0f) tested_pos_clamp = true;
			if (test_rudder == -1.0f) tested_neg_clamp = true;
			float cand_lookahead = (std::abs(test_rudder) < 0.5f) ? lookahead * 2.0f : lookahead;
			std::vector<ArcPoint> arc;
			if (have_steer_target) {
				arc = predict_arc_to_heading(test_rudder, boost_throttle, steer_tgt, cand_lookahead, 60.0f, terrain_dt_scale);
			} else {
				arc = predict_arc_internal(test_rudder, boost_throttle, cand_lookahead);
			}
			float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
			float cand_ttc = std::min(check_arc_collision(arc, hard_clearance, soft_clearance),
									  check_arc_obstacles(arc));

			if (cand_ttc > best_ttc) {
				best_ttc = cand_ttc;
				best_rudder = test_rudder;
				best_throttle = boost_throttle;
			}
		}
	}

	if (best_throttle != desired_throttle) {
		out_throttle = best_throttle;
	}

	// Emergency: gradient-based escape
	if (best_ttc < 3.0f) {
		nav_state = NavState::EMERGENCY;

		if (map.is_valid() && map->is_built()) {
			Vector2 grad = map->get_gradient(state.position.x, state.position.y);
			float escape_heading = std::atan2(grad.x, grad.y);
			best_rudder = compute_rudder_to_heading(escape_heading);

			float angle_to_escape = std::abs(angle_difference(state.heading, escape_heading));
			if (angle_to_escape < Math_PI * 0.5f) {
				out_throttle = 2;
			} else {
				out_throttle = -1;
			}
		} else {
			best_rudder = (state.angular_velocity_y > 0.0f) ? 1.0f : -1.0f;
			out_throttle = -1;
		}
	}

	out_ttc = best_ttc;
	return best_rudder;
}

// ============================================================================
// Waypoint following
// ============================================================================

void ShipNavigator::advance_waypoint() {
	if (!path_valid || current_path.waypoints.empty()) return;

	// Phase 1: Skip waypoints we've already reached
	while (current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		if (is_waypoint_reached(current_path.waypoints[current_wp_index])) {
			current_wp_index++;
		} else {
			break;
		}
	}

	// Phase 2: Skip waypoints in turning dead zone (except final destination)
	int last_wp = static_cast<int>(current_path.waypoints.size()) - 1;
	while (current_wp_index < last_wp) {
		if (is_waypoint_in_turning_dead_zone(current_path.waypoints[current_wp_index])) {
			current_wp_index++;
		} else {
			break;
		}
	}

	// If final destination is in dead zone, request replan via check_replan_needed
	// (respects cooldown to prevent oscillation). Don't force PLANNING directly.
	// The check_replan_needed() dead-zone check at the end of update_navigating
	// will trigger the replan when the cooldown expires.

	// Clamp to last valid waypoint
	if (current_wp_index >= static_cast<int>(current_path.waypoints.size())) {
		current_wp_index = static_cast<int>(current_path.waypoints.size()) - 1;
		if (current_wp_index < 0) current_wp_index = 0;
	}
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
