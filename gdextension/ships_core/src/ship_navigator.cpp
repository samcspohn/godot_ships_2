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
		"angular_velocity_y", "current_rudder", "current_speed"),
		&ShipNavigator::set_state);

	// Navigation commands
	ClassDB::bind_method(D_METHOD("navigate_to_position", "target"), &ShipNavigator::navigate_to_position);
	ClassDB::bind_method(D_METHOD("navigate_to_angle", "target_heading"), &ShipNavigator::navigate_to_angle);
	ClassDB::bind_method(D_METHOD("navigate_to_pose", "target", "target_heading"), &ShipNavigator::navigate_to_pose);
	ClassDB::bind_method(D_METHOD("station_keep", "center", "radius", "preferred_heading"), &ShipNavigator::station_keep);
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
	ClassDB::bind_method(D_METHOD("get_nav_mode"), &ShipNavigator::get_nav_mode);
	ClassDB::bind_method(D_METHOD("get_clearance_radius"), &ShipNavigator::get_ship_clearance);
	ClassDB::bind_method(D_METHOD("get_soft_clearance_radius"), &ShipNavigator::get_soft_clearance);

	// Backward-compatible stubs
	ClassDB::bind_method(D_METHOD("validate_destination_pose", "ship_position", "candidate"), &ShipNavigator::validate_destination_pose);
	ClassDB::bind_method(D_METHOD("get_simulated_path"), &ShipNavigator::get_simulated_path);
	ClassDB::bind_method(D_METHOD("is_simulation_complete"), &ShipNavigator::is_simulation_complete);

	// Enum constants for NavState
	BIND_CONSTANT(0);  // IDLE
	BIND_CONSTANT(1);  // NAVIGATING
	BIND_CONSTANT(2);  // ARRIVING
	BIND_CONSTANT(3);  // TURNING
	BIND_CONSTANT(4);  // STATION_APPROACH
	BIND_CONSTANT(5);  // STATION_SETTLE
	BIND_CONSTANT(6);  // STATION_HOLDING
	BIND_CONSTANT(7);  // STATION_RECOVER
	BIND_CONSTANT(8);  // AVOIDING
	BIND_CONSTANT(9);  // EMERGENCY
}

// ============================================================================
// Constructor / Destructor
// ============================================================================

ShipNavigator::ShipNavigator() {
	nav_mode = NavMode::NONE;
	nav_state = NavState::IDLE;
	target_position = Vector2(0, 0);
	target_heading = 0.0f;
	station_center = Vector3(0, 0, 0);
	station_radius = 500.0f;
	station_preferred_heading = 0.0f;
	current_wp_index = 0;
	path_valid = false;
	path_recalc_cooldown = 0.0f;
	out_rudder = 0.0f;
	out_throttle = 0;
	out_collision_imminent = false;
	out_time_to_collision = std::numeric_limits<float>::infinity();
	station_settle_timer = 0.0f;
	station_hold_timer = 0.0f;
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
	float current_speed
) {
	state.position = Vector2(position.x, position.z);
	state.velocity = Vector2(velocity.x, velocity.z);
	state.heading = heading;
	state.angular_velocity_y = angular_velocity_y;
	state.current_rudder = current_rudder;
	state.current_speed = current_speed;

	// Decrease path recalc cooldown (assume ~60fps physics)
	if (path_recalc_cooldown > 0.0f) {
		path_recalc_cooldown -= 1.0f / 60.0f;
		if (path_recalc_cooldown < 0.0f) path_recalc_cooldown = 0.0f;
	}

	// Tick avoidance commit timer
	avoidance.tick(1.0f / 60.0f);

	// Run steering pipeline based on current navigation mode
	switch (nav_mode) {
		case NavMode::POSITION:
			update_navigate_to_position();
			break;
		case NavMode::ANGLE:
			update_navigate_to_angle();
			break;
		case NavMode::POSE:
			update_navigate_to_pose();
			break;
		case NavMode::STATION_KEEP:
			update_station_keep(1.0f / 60.0f);
			break;
		case NavMode::NONE:
		default:
			set_steering_output(0.0f, 0, false, std::numeric_limits<float>::infinity());
			nav_state = NavState::IDLE;
			break;
	}

	// Update the predicted arc cache for debug visualization
	update_predicted_arc();
}

// ============================================================================
// Navigation commands
// ============================================================================

void ShipNavigator::navigate_to_position(Vector3 target) {
	Vector2 new_target(target.x, target.z);
	float dist_change = new_target.distance_to(target_position);

	if (nav_mode != NavMode::POSITION) {
		// Mode switch — full path calculation
		nav_mode = NavMode::POSITION;
		target_position = new_target;
		nav_state = NavState::NAVIGATING;
		maybe_recalc_path(target_position);
	} else if (dist_change > params.turning_circle_radius * 0.5f) {
		if (is_destination_shift_small(target_position, new_target)) {
			// Small shift: keep existing path, just update target
			target_position = new_target;
		} else {
			// Large shift: full recalculation
			target_position = new_target;
			nav_state = NavState::NAVIGATING;
			maybe_recalc_path(target_position);
		}
	}
	// else: destination barely changed — keep current path
}

void ShipNavigator::navigate_to_angle(float p_target_heading) {
	nav_mode = NavMode::ANGLE;
	target_heading = p_target_heading;
	nav_state = NavState::TURNING;
}

void ShipNavigator::navigate_to_pose(Vector3 target, float p_target_heading) {
	Vector2 new_target(target.x, target.z);
	float dist_change = new_target.distance_to(target_position);
	float heading_change = std::abs(angle_difference(target_heading, p_target_heading));

	bool heading_changed = heading_change > 0.35f; // ~20 degrees

	if (nav_mode != NavMode::POSE) {
		nav_mode = NavMode::POSE;
		target_position = new_target;
		target_heading = p_target_heading;
		nav_state = NavState::NAVIGATING;
		maybe_recalc_path(target_position);
	} else if (dist_change > params.turning_circle_radius * 0.5f || heading_changed) {
		if (is_destination_shift_small(target_position, new_target) && !heading_changed) {
			target_position = new_target;
		} else {
			target_position = new_target;
			target_heading = p_target_heading;
			nav_state = NavState::NAVIGATING;
			maybe_recalc_path(target_position);
		}
	} else {
		// Update heading even if position is the same
		target_heading = p_target_heading;
	}
}

void ShipNavigator::station_keep(Vector3 center, float radius, float preferred_heading) {
	Vector2 new_center(center.x, center.z);
	float center_change = new_center.distance_to(Vector2(station_center.x, station_center.z));

	if (nav_mode != NavMode::STATION_KEEP || center_change > radius * 0.5f) {
		nav_mode = NavMode::STATION_KEEP;
		station_center = center;
		station_radius = radius;
		station_preferred_heading = preferred_heading;
		target_heading = preferred_heading;

		float dist_to_center = state.position.distance_to(new_center);
		if (dist_to_center > station_radius) {
			nav_state = NavState::STATION_APPROACH;
			// Path to a point on the zone boundary, not the center
			Vector2 dir_to_center = (new_center - state.position).normalized();
			Vector2 entry_point = new_center - dir_to_center * (station_radius * 0.7f);
			target_position = entry_point;
			maybe_recalc_path(entry_point);
		} else {
			nav_state = NavState::STATION_SETTLE;
			station_settle_timer = 0.0f;
		}
	} else {
		station_preferred_heading = preferred_heading;
		target_heading = preferred_heading;
	}
}

void ShipNavigator::stop() {
	nav_mode = NavMode::NONE;
	nav_state = NavState::IDLE;
	path_valid = false;
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
		result.push_back(Vector3(wp.x, 0.0f, wp.y));
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
	return Vector3(target_position.x, 0.0f, target_position.y);
}

float ShipNavigator::get_desired_heading() const {
	if (nav_mode == NavMode::ANGLE || nav_mode == NavMode::POSE) {
		return target_heading;
	}
	if (nav_mode == NavMode::STATION_KEEP) {
		return station_preferred_heading;
	}
	// For position mode, desired heading is toward the current steer target
	Vector2 steer_target = target_position;
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		steer_target = current_path.waypoints[current_wp_index];
	}
	Vector2 to_target = steer_target - state.position;
	return std::atan2(to_target.x, to_target.y);
}

float ShipNavigator::get_distance_to_destination() const {
	return state.position.distance_to(target_position);
}

String ShipNavigator::get_debug_info() const {
	std::ostringstream oss;

	const char *mode_names[] = {"NONE", "POSITION", "ANGLE", "POSE", "STATION_KEEP"};
	const char *state_names[] = {"IDLE", "NAVIGATING", "ARRIVING", "TURNING",
		"STATION_APPROACH", "STATION_SETTLE", "STATION_HOLDING", "STATION_RECOVER",
		"AVOIDING", "EMERGENCY"};

	int mi = static_cast<int>(nav_mode);
	int si = static_cast<int>(nav_state);

	oss << "mode=" << (mi >= 0 && mi <= 4 ? mode_names[mi] : "?")
		<< " state=" << (si >= 0 && si <= 9 ? state_names[si] : "?")
		<< " rudder=" << out_rudder
		<< " throttle=" << out_throttle
		<< " speed=" << state.current_speed
		<< " dist=" << state.position.distance_to(target_position)
		<< " path_valid=" << path_valid
		<< " wp=" << current_wp_index << "/" << current_path.waypoints.size()
		<< " collision=" << out_collision_imminent
		<< " ttc=" << out_time_to_collision;

	return String(oss.str().c_str());
}

int ShipNavigator::get_nav_mode() const {
	return static_cast<int>(nav_mode);
}

// ============================================================================
// Backward-compatible API stubs
// ============================================================================

Dictionary ShipNavigator::validate_destination_pose(Vector3 ship_position, Vector3 candidate) {
	// Simplified: just ensure destination is navigable, no physics simulation.
	// The turning-aware pathfinder now handles producing safe paths.
	Vector2 ship_pos_2d(ship_position.x, ship_position.z);
	Vector2 cand_2d(candidate.x, candidate.z);
	float clearance = get_ship_clearance();

	Vector2 safe_pos = cand_2d;
	bool adjusted = false;
	float heading = 0.0f;

	if (map.is_valid() && map->is_built()) {
		safe_pos = map->safe_nav_point(ship_pos_2d, cand_2d, clearance, params.turning_circle_radius);
		adjusted = safe_pos.distance_to(cand_2d) > 10.0f;

		// Compute approach heading as the "safe" heading
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
	// No forward simulation — return the predicted arc points instead
	return get_predicted_trajectory();
}

bool ShipNavigator::is_simulation_complete() const {
	// No incremental simulation; always "complete"
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
	// The lookahead must be long enough that the ship can detect land and
	// complete a turn away before reaching it.  Three factors matter:
	//
	//   1. Rudder lag distance: the ship travels straight while the rudder
	//      moves from center to full deflection.
	//   2. Turning arc: once the rudder is fully deflected the ship needs
	//      roughly a quarter-circle (≈ PI/2 × turning_radius) to make a
	//      90° course change away from the obstacle.
	//   3. A safety buffer of at least one ship length beyond that.
	//
	// We take the maximum of this physics-based estimate and the old
	// floor of 3× ship length so that small/agile ships still get a
	// reasonable minimum.

	float speed = std::max(std::abs(state.current_speed), params.max_speed * 0.5f);

	// Distance covered while the rudder travels from center to full lock
	float rudder_lag_dist = speed * params.rudder_response_time;

	// Quarter-turn arc at the turning circle radius
	float turn_arc = params.turning_circle_radius * 1.57f; // PI/2

	// Physics-based minimum: lag + turn + one ship length buffer
	float physics_dist = rudder_lag_dist + turn_arc + params.ship_length;

	// Legacy floor: at least 3 ship lengths
	float legacy_min = params.ship_length * 3.0f;

	// Stopping distance contribution (matters at high speed)
	float stopping = get_stopping_distance();

	float dist = std::max({legacy_min, physics_dist, stopping + params.ship_length * 2.0f});

	// Hard cap to prevent absurdly long (expensive) arcs
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
	// Dynamic reach radius based on speed and turning radius
	float base = params.ship_length;
	float speed_factor = std::abs(state.current_speed) * 2.0f;
	float turn_factor = params.turning_circle_radius * 0.3f;
	return std::max(base, std::min(turn_factor, speed_factor));
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

	// Scale the integration timestep with the ship's sluggishness.
	// A ship with a 14-second rudder response doesn't need 0.1s steps —
	// nothing meaningful changes that fast.  This lets large ships cover
	// the full lookahead distance within the max_time budget without
	// increasing max_time itself.
	//   - Fast destroyer  (rudder_response ~3s)  → dt ≈ 0.1s
	//   - Battleship      (rudder_response ~10s) → dt ≈ 0.25s
	//   - Super-heavy     (rudder_response ~14s) → dt ≈ 0.35s
	const float base_dt = 0.1f;
	const float integration_dt = std::min(
		base_dt * std::max(1.0f, params.rudder_response_time / 4.0f),
		0.5f  // hard cap — larger steps lose too much accuracy
	);
	float emit_interval = std::max(lookahead_distance / 50.0f, params.ship_beam * 0.5f);
	float next_emit_dist = emit_interval;
	Vector2 prev_pos = sim_pos;

	// Compute effective time limit: ensure we have enough sim time to
	// cover the full lookahead distance at the slower of current speed
	// or half max speed (accounts for deceleration / slow starts).
	float min_expected_speed = std::max(std::abs(state.current_speed), params.max_speed * 0.25f);
	float time_for_lookahead = lookahead_distance / std::max(min_expected_speed, 1.0f);
	float effective_max_time = std::max(max_time, time_for_lookahead * 1.2f);

	while (total_distance < lookahead_distance && sim_time < effective_max_time) {
		float dt = integration_dt;
		if (sim_time + dt > effective_max_time) dt = effective_max_time - sim_time;
		if (dt < 0.001f) break;

		// 1. Rudder moves toward commanded position
		if (params.rudder_response_time > 0.001f) {
			sim_rudder = move_toward_f(sim_rudder, commanded_rudder, dt / params.rudder_response_time);
		} else {
			sim_rudder = commanded_rudder;
		}

		// 2. Speed changes toward target
		if (target_speed_val > sim_speed) {
			float accel_rate = params.max_speed / std::max(params.acceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * accel_rate);
		} else {
			float decel_rate = params.max_speed / std::max(params.deceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * decel_rate);
		}

		// 3. Apply turn speed loss
		float effective_speed = sim_speed * (1.0f - params.turn_speed_loss * std::abs(sim_rudder));

		// 4. Compute turn rate
		float omega = 0.0f;
		if (params.turning_circle_radius > 0.001f) {
			omega = (effective_speed / params.turning_circle_radius) * (-sim_rudder);
		}

		// 5. Integrate position and heading
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
	// Return the current waypoint if following a path, otherwise the final target.
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		return current_path.waypoints[current_wp_index];
	}
	if (nav_mode == NavMode::POSITION || nav_mode == NavMode::POSE) {
		return target_position;
	}
	if (nav_mode == NavMode::STATION_KEEP) {
		return Vector2(station_center.x, station_center.z);
	}
	// ANGLE mode or NONE — no spatial target
	return Vector2(0.0f, 0.0f);
}

std::vector<ArcPoint> ShipNavigator::predict_arc_to_heading(float commanded_rudder, int commanded_throttle,
															Vector2 target_pos, float lookahead_distance,
															float max_time) const {
	// Simulates the ship's turn at any rudder value until the heading is
	// tangentially aligned toward target_pos, but never shorter than
	// lookahead_distance (so obstacle detection range is preserved).
	// The maximum arc distance is capped at the turning circle perimeter
	// or lookahead_distance, whichever is larger.

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

	// Distance cap: the larger of the lookahead distance (so we always
	// detect obstacles as far ahead as the old system did) and one full
	// turning circle perimeter (so a complete revolution can be tested).
	float turning_circle_perimeter = 2.0f * Math_PI * params.turning_circle_radius;
	float max_arc_distance = std::max(lookahead_distance, turning_circle_perimeter);

	// Integration timestep — same scaling as predict_arc_internal
	const float base_dt = 0.1f;
	const float integration_dt = std::min(
		base_dt * std::max(1.0f, params.rudder_response_time / 4.0f),
		0.5f
	);
	float emit_interval = std::max(max_arc_distance / 50.0f, params.ship_beam * 0.5f);
	float next_emit_dist = emit_interval;
	Vector2 prev_pos = sim_pos;

	// We consider "aligned" when the heading error to the target is below
	// this threshold.  ~5 degrees is tight enough that the ship can
	// proceed toward the waypoint after the turn.
	const float alignment_threshold = 0.087f;  // ~5 degrees in radians

	// Simulate the turning arc.  Alignment can only terminate the loop
	// after we've covered at least lookahead_distance — this ensures
	// obstacle/terrain checks always see far enough ahead.
	bool aligned = false;
	while (sim_time < max_time && total_distance < max_arc_distance) {
		float dt = integration_dt;
		if (sim_time + dt > max_time) dt = max_time - sim_time;
		if (dt < 0.001f) break;

		// 1. Rudder moves toward commanded position
		if (params.rudder_response_time > 0.001f) {
			sim_rudder = move_toward_f(sim_rudder, commanded_rudder, dt / params.rudder_response_time);
		} else {
			sim_rudder = commanded_rudder;
		}

		// 2. Speed changes toward target
		if (target_speed_val > sim_speed) {
			float accel_rate = params.max_speed / std::max(params.acceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * accel_rate);
		} else {
			float decel_rate = params.max_speed / std::max(params.deceleration_time, 0.1f);
			sim_speed = move_toward_f(sim_speed, target_speed_val, dt * decel_rate);
		}

		// 3. Apply turn speed loss
		float effective_speed = sim_speed * (1.0f - params.turn_speed_loss * std::abs(sim_rudder));

		// 4. Compute turn rate
		float omega = 0.0f;
		if (params.turning_circle_radius > 0.001f) {
			omega = (effective_speed / params.turning_circle_radius) * (-sim_rudder);
		}

		// 5. Integrate position and heading
		sim_heading += omega * dt;
		sim_heading = normalize_angle(sim_heading);
		sim_pos.x += std::sin(sim_heading) * effective_speed * dt;
		sim_pos.y += std::cos(sim_heading) * effective_speed * dt;

		sim_time += dt;

		float step_dist = sim_pos.distance_to(prev_pos);
		total_distance += step_dist;
		prev_pos = sim_pos;

		// Emit point at regular intervals
		if (total_distance >= next_emit_dist) {
			arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
			next_emit_dist += emit_interval;
		}

		// Check tangential alignment: is the sim heading now pointing at target_pos?
		// Only allow early exit once we've covered at least lookahead_distance
		// so that obstacle detection range is never reduced.
		if (total_distance >= lookahead_distance) {
			Vector2 to_target = target_pos - sim_pos;
			float dist_to_target = to_target.length();
			if (dist_to_target > 1.0f) {  // avoid division by near-zero
				float desired_heading = std::atan2(to_target.x, to_target.y);
				float heading_error = std::abs(angle_difference(sim_heading, desired_heading));
				if (heading_error < alignment_threshold) {
					aligned = true;
					// Aligned — emit final point and stop
					arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
					break;
				}
			}
		}
	}

	// Ensure we have at least 2 points and the last emitted point is current
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

		// Hard clearance violation — immediate collision
		if (sdf < hard_clearance) {
			return pt.time;
		}

		// Soft clearance tracking
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

	// If the arc ends in the soft zone and never exits, treat it as a collision
	// (the ship is settling into a position too close to land)
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
			// Project obstacle position forward in time
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
				break; // First collision point for this obstacle
			}
		}
	}

	return result;
}

bool ShipNavigator::is_give_way_vessel(const ObstacleCollisionInfo &info) const {
	// Torpedoes: always give way — there is no right-of-way against a torpedo.
	if (info.is_torpedo) return true;

	// Size priority: larger ships get right-of-way (stand-on)
	// If we are significantly larger, we are stand-on
	float size_ratio = params.ship_length / std::max(info.obstacle_length, 50.0f);
	if (size_ratio > 1.5f) return false;  // We're much bigger → stand-on
	if (size_ratio < 0.67f) return true;  // We're much smaller → give-way

	// Similar size: use COLREGS-like rules
	float bearing = info.relative_bearing;
	float abs_bearing = std::abs(bearing);

	// Rule 14: Head-on — both turn starboard
	if (abs_bearing < 0.175f) { // within ~10°
		return true; // Both give way in head-on
	}

	// Rule 15: Crossing — vessel with the other on her starboard side gives way
	if (bearing > 0.0f && bearing < Math_PI * 0.75f) {
		// Obstacle is on our starboard side — we must give way
		return true;
	}

	// Rule 13: Overtaking — overtaking vessel gives way
	if (abs_bearing > Math_PI * 0.75f) {
		// Obstacle is mostly behind us — we might be overtaking
		float our_speed = std::abs(state.current_speed);
		float obs_speed = info.obstacle_velocity.length();
		if (our_speed > obs_speed * 0.8f) {
			return true; // We're faster, probably overtaking
		}
	}

	return false; // Default: stand-on
}

// ============================================================================
// Steering pipeline helpers
// ============================================================================

float ShipNavigator::compute_rudder_to_position(Vector2 target_pos, bool reverse) const {
	Vector2 to_target = target_pos - state.position;
	float target_angle = std::atan2(to_target.x, to_target.y);

	if (reverse) {
		// In reverse the stern leads. We want the stern to point at the target,
		// so the bow should point at the reciprocal bearing.
		float stern_desired = normalize_angle(target_angle + Math_PI);
		// compute_rudder_to_heading assumes forward motion (negative rudder →
		// starboard / heading increases).  In reverse the same rudder deflection
		// produces the opposite rotation, so we negate the result.
		return -compute_rudder_to_heading(stern_desired);
	}

	return compute_rudder_to_heading(target_angle);
}

float ShipNavigator::compute_rudder_to_heading(float desired_heading) const {
	float angle_diff = angle_difference(state.heading, desired_heading);
	float abs_diff = std::abs(angle_diff);

	// --- Rudder lead compensation ---
	// Model rudder lag: predict heading drift while rudder is traveling
	float rudder_travel_time = std::abs(0.0f - state.current_rudder) * params.rudder_response_time;
	float heading_drift = state.angular_velocity_y * rudder_travel_time;

	// Effective target accounts for drift during rudder travel
	float effective_target = desired_heading - heading_drift * 0.5f;
	float effective_diff = angle_difference(state.heading, effective_target);
	float abs_effective_diff = std::abs(effective_diff);

	float rudder;

	if (abs_effective_diff < 0.02f) {
		// Within ~1 degree: no rudder needed
		rudder = 0.0f;
	} else if (abs_effective_diff > Math_PI * 0.25f) {
		// More than 45 degrees: full rudder
		rudder = (effective_diff > 0.0f) ? -1.0f : 1.0f;
	} else {
		// Proportional: map [0.02, PI/4] to [0.1, 1.0]
		float t = (abs_effective_diff - 0.02f) / (Math_PI * 0.25f - 0.02f);
		rudder = lerp_f(0.1f, 1.0f, t);
		if (effective_diff < 0.0f) rudder = -rudder;
		// angle_diff > 0 means target is clockwise, need negative rudder
		rudder = -rudder;
	}

	// Additional lead: when close to target heading, start centering early
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
		// Clear avoidance if obstacle is no longer threatening
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
	// Torpedoes travel at ~45–90 m/s; the correct dodge direction changes
	// quickly as the intercept geometry evolves, so we must NOT lock in a
	// rudder via the ship-avoidance commit timer.  We also bias the rudder
	// search to start with the side that crosses perpendicular to the
	// torpedo track (minimises time in the danger zone).

	bool obstacle_is_primary_threat = (ttc_obstacles <= ttc_terrain);

	if (obstacle_is_primary_threat && obs_info.has_collision && obs_info.is_torpedo) {
		// --- Compute preferred dodge side ---
		// torpedo_dir  : direction the torpedo is travelling (normalised)
		// ship_side    : vector from torpedo to us
		// cross sign   : positive  → we are to the right of the torpedo track → turn port  (rudder < 0)
		//                negative  → we are to the left  of the torpedo track → turn starboard (rudder > 0)
		Vector2 torpedo_dir = obs_info.obstacle_velocity;
		float torp_speed = torpedo_dir.length();
		float dodge_bias = 0.0f;  // preferred first-search direction: negative = port, positive = starboard
		if (torp_speed > 1.0f) {
			torpedo_dir /= torp_speed;
			Vector2 ship_side = state.position - obs_info.obstacle_position;
			float cross = torpedo_dir.x * ship_side.y - torpedo_dir.y * ship_side.x;
			// cross > 0 → ship is to the right of torpedo heading → dodge further right (starboard, rudder < 0 in our convention)
			// cross < 0 → ship is to the left  of torpedo heading → dodge further left  (port,      rudder > 0)
			dodge_bias = (cross >= 0.0f) ? -1.0f : 1.0f;
		}

		// Build candidate list: preferred-side offsets first, then opposite side
		// Full rudder increments — we want decisive, fast turns.
		const float torp_offsets_primary[]   = { 0.5f, 1.0f, 0.25f, 0.75f };
		const float torp_offsets_secondary[] = {-0.5f,-1.0f,-0.25f,-0.75f };

		float best_rudder  = desired_rudder;
		float best_ttc     = ttc;
		int   best_throttle = desired_throttle;

		auto try_torpedo_candidates = [&](const float* offsets, int count, int throttle_level) {
			for (int ci = 0; ci < count; ++ci) {
				float signed_offset = offsets[ci] * dodge_bias;  // apply preferred side
				float candidate = clamp_f(desired_rudder + signed_offset, -1.0f, 1.0f);
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
						return true;  // clean escape found
					}
				}
			}
			return false;
		};

		constexpr int primary_count   = 4;
		constexpr int secondary_count = 4;

		// Phase 1: preferred side, current throttle
		if (!try_torpedo_candidates(torp_offsets_primary, primary_count, desired_throttle)) {
			// Phase 2: opposite side, current throttle
			if (!try_torpedo_candidates(torp_offsets_secondary, secondary_count, desired_throttle)) {
				// Phase 3: preferred side, flank speed (run across the track)
				int flank = std::min(desired_throttle + 2, 4);
				if (!try_torpedo_candidates(torp_offsets_primary, primary_count, flank)) {
					// Phase 4: preferred side, slow speed (tighter turning circle)
					int slow = std::max(1, desired_throttle - 1);
					try_torpedo_candidates(torp_offsets_primary, primary_count, slow);
				}
			}
		}

		if (best_throttle != desired_throttle) {
			out_throttle = best_throttle;
		}

		// Emergency — nothing cleared the path: hard turn toward dodge side
		if (best_ttc < 3.0f) {
			nav_state = NavState::EMERGENCY;
			best_rudder = -dodge_bias;  // full rudder on preferred dodge side
			out_throttle = std::min(desired_throttle + 1, 4);  // build rudder authority
		}

		// NOTE: deliberately no avoidance.begin() here — torpedoes must be
		// re-evaluated every frame because their intercept geometry changes fast.
		out_ttc = best_ttc;
		out_collision = (best_ttc < arc_total_time * 0.95f);
		return best_rudder;
	}

	// =====================================================================
	// COLREGS-inspired asymmetric ship avoidance with size priority
	// =====================================================================

	// Honor committed avoidance maneuver (ships only — not torpedoes, handled above)
	if (avoidance.active && avoidance.commit_timer > 0.0f) {
		// Don't honour a ship-avoidance commit if the primary threat is now a torpedo —
		// that case was already handled above; reaching here means obstacle is a ship.
		auto committed_arc = predict_arc_internal(avoidance.committed_rudder, desired_throttle, lookahead);
		float committed_ttc_terrain = check_arc_collision(committed_arc, hard_clearance, soft_clearance);
		float committed_total_time = committed_arc.empty() ? 0.0f : committed_arc.back().time;

		if (committed_ttc_terrain >= committed_total_time * 0.5f) {
			out_ttc = std::min(committed_ttc_terrain, check_arc_obstacles(committed_arc));
			return avoidance.committed_rudder;
		}
		avoidance.clear();
	}

	// Obstacle-specific avoidance
	if (obstacle_is_primary_threat && obs_info.has_collision) {
		bool give_way = is_give_way_vessel(obs_info);

		if (!give_way) {
			if (ttc > AvoidanceState::STAND_ON_TTC_THRESHOLD) {
				out_collision = false;
				return desired_rudder;
			}
		}

		// Starboard-biased rudder candidates (COLREGS).
		// Each candidate is simulated until tangentially aligned to the
		// current waypoint, giving a physically accurate turning arc.
		const float starboard_offsets[] = {
			-0.25f, -0.5f, -0.75f, -1.0f,
			 0.25f,  0.5f,  0.75f,  1.0f
		};

		float best_rudder = desired_rudder;
		float best_ttc = ttc;

		// Phase 1: Rudder-only at current speed — tangential alignment arcs
		Vector2 steer_tgt = get_steer_target();
		bool have_steer_target = (steer_tgt.length_squared() > 1.0f);

		for (float offset : starboard_offsets) {
			float candidate = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
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

		// Phase 2: Reduce throttle if rudder alone wasn't enough
		if (best_ttc < arc_total_time * 0.5f) {
			int reduced_throttle = std::max(1, desired_throttle - 2);
			for (float offset : starboard_offsets) {
				float candidate = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
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

		// Emergency: nothing works — full reverse to bleed speed
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
	// Each rudder candidate is simulated until tangentially aligned to the
	// current waypoint, capped at the minimum turning circle perimeter.
	// This gives a physically accurate picture of the actual turn the ship
	// would execute rather than an arbitrary fixed-distance lookahead.
	const float offsets[] = {0.25f, -0.25f, 0.5f, -0.5f, 0.75f, -0.75f, 1.0f, -1.0f};
	float best_rudder = desired_rudder;
	float best_ttc = ttc;
	int best_throttle = desired_throttle;

	Vector2 steer_tgt = get_steer_target();
	bool have_steer_target = (steer_tgt.length_squared() > 1.0f);

	// Phase 1: Rudder-only — tangential alignment arcs
	for (float offset : offsets) {
		float candidate = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
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
			best_throttle = desired_throttle;
			if (best_ttc >= cand_arc_time * 0.95f) {
				out_ttc = best_ttc;
				out_collision = false;
				return best_rudder;
			}
		}
	}

	// Phase 2: Reduce throttle
	if (best_ttc < arc_total_time * 0.5f) {
		int reduced_throttle = std::max(1, desired_throttle - 2);
		for (float offset : offsets) {
			float test_rudder = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
			std::vector<ArcPoint> arc;
			if (have_steer_target) {
				arc = predict_arc_to_heading(test_rudder, reduced_throttle, steer_tgt, lookahead);
			} else {
				arc = predict_arc_internal(test_rudder, reduced_throttle, lookahead);
			}
			float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
			float cand_ttc = std::min(check_arc_collision(arc, hard_clearance, soft_clearance),
									  check_arc_obstacles(arc));

			if (cand_ttc > best_ttc) {
				best_ttc = cand_ttc;
				best_rudder = test_rudder;
				best_throttle = reduced_throttle;
				if (best_ttc >= cand_arc_time * 0.95f) {
					out_throttle = best_throttle;
					out_ttc = best_ttc;
					return best_rudder;
				}
			}
		}
	}

	// Phase 3: Increase throttle with full rudder (build rudder authority)
	if (best_ttc < arc_total_time * 0.5f && std::abs(state.current_speed) < params.max_speed * 0.3f) {
		int boost_throttle = std::min(desired_throttle + 2, 4);
		for (float offset : offsets) {
			float test_rudder = clamp_f(desired_rudder + offset, -1.0f, 1.0f);
			std::vector<ArcPoint> arc;
			if (have_steer_target) {
				arc = predict_arc_to_heading(test_rudder, boost_throttle, steer_tgt, lookahead);
			} else {
				arc = predict_arc_internal(test_rudder, boost_throttle, lookahead);
			}
			float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
			float cand_ttc = std::min(check_arc_collision(arc, hard_clearance, soft_clearance),
									  check_arc_obstacles(arc));

			if (cand_ttc > best_ttc) {
				best_ttc = cand_ttc;
				best_rudder = test_rudder;
				best_throttle = boost_throttle;
				if (best_ttc >= cand_arc_time * 0.95f) {
					out_throttle = best_throttle;
					out_ttc = best_ttc;
					return best_rudder;
				}
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
				out_throttle = 2; // Drive forward to turn out
			} else {
				out_throttle = -1; // Brief reverse
			}
		} else {
			best_rudder = (state.angular_velocity_y > 0.0f) ? 1.0f : -1.0f;
			out_throttle = -1;
		}
	}

	out_ttc = best_ttc;
	return best_rudder;
}

float ShipNavigator::apply_gradient_bias(float rudder) const {
	return rudder;
	if (map.is_null() || !map->is_built()) return rudder;

	float clearance = get_ship_clearance();
	float dist = map->get_distance(state.position.x, state.position.y);

	// Activation threshold accounts for turning circle — the ship needs to
	// start biasing well before it's within hard clearance, because large
	// ships cannot turn away quickly.  Use the larger of 1.5× clearance or
	// the full turning circle radius (which already represents the minimum
	// distance at which the ship can execute a 90° turn).
	float bias_threshold = std::max(clearance * 1.5f, params.turning_circle_radius);
	if (dist >= bias_threshold) return rudder;

	Vector2 grad = map->get_gradient(state.position.x, state.position.y);
	if (grad.length_squared() < 0.0001f) return rudder;

	float escape_heading = std::atan2(grad.x, grad.y);
	float angle_to_escape = angle_difference(state.heading, escape_heading);

	float proximity = 1.0f - (dist / bias_threshold);
	// Ramp up strength: gentle at the outer edge, assertive close in
	float base_strength = 0.4f;
	if (params.ship_length > 200.0f) {
		base_strength *= 200.0f / params.ship_length;
	}
	float bias_strength = proximity * proximity * base_strength;

	float bias_rudder;
	if (angle_to_escape > 0.0f) {
		bias_rudder = -bias_strength;
	} else {
		bias_rudder = bias_strength;
	}

	return clamp_f(rudder + bias_rudder, -1.0f, 1.0f);
}

// ============================================================================
// Waypoint following
// ============================================================================

void ShipNavigator::advance_waypoint() {
	if (!path_valid || current_path.waypoints.empty()) return;

	// Phase 1: Skip waypoints we've already reached (normal advancement)
	while (current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		if (is_waypoint_reached(current_path.waypoints[current_wp_index])) {
			current_wp_index++;
		} else {
			break;
		}
	}

	// Phase 2: Skip waypoints that are inside the turning dead zone.
	// The ship has two turning circles (port and starboard) tangent to its
	// current trajectory. Any waypoint inside either circle is geometrically
	// unreachable — the ship would orbit it forever. Skip past these to the
	// next reachable waypoint, but never skip the final waypoint (destination).
	int last_wp = static_cast<int>(current_path.waypoints.size()) - 1;
	bool skipped_dead_zone = false;
	while (current_wp_index < last_wp) {
		if (is_waypoint_in_turning_dead_zone(current_path.waypoints[current_wp_index])) {
			current_wp_index++;
			skipped_dead_zone = true;
		} else {
			break;
		}
	}

	// If we skipped intermediate waypoints but the final destination itself
	// is in the dead zone, the current path is no longer viable — request a
	// recalculation from our current position so A* can produce a path that
	// the ship can actually follow (approaching from a different angle).
	if (current_wp_index == last_wp && last_wp >= 0 &&
		is_waypoint_in_turning_dead_zone(current_path.waypoints[last_wp])) {
		// Destination is unreachable on current trajectory — recalculate.
		// The new path will originate from where we are now, approaching
		// the target from an angle outside both turning circles.
		maybe_recalc_path(target_position);
		return;
	}

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

	// Distance check
	if (dist < reach_radius) return true;

	// Along-track check: waypoint is "reached" if we've passed it
	// (ship's closest point of approach has already occurred)
	Vector2 forward(std::sin(state.heading), std::cos(state.heading));
	float along_track = to_wp.x * forward.x + to_wp.y * forward.y;

	// We've passed the waypoint if it's behind us and reasonably close
	if (along_track < 0.0f && dist < reach_radius * 2.0f) return true;

	return false;
}

bool ShipNavigator::is_waypoint_in_turning_dead_zone(Vector2 waypoint) const {
	// The ship has two turning circles — one to port, one to starboard —
	// whose centers sit perpendicular to the current heading at a distance
	// of turning_circle_radius from the ship's position.  Any point inside
	// either circle is geometrically unreachable: the ship would need to
	// turn tighter than its minimum radius, resulting in an infinite orbit.
	//
	// This is a purely geometric check — it must not gate on speed, because
	// callers (reverse logic, path recalc) need to know the dead-zone status
	// even when the ship has slowed down or stopped.  The "can the ship
	// maneuver freely at low speed" decision belongs to the caller.

	float r = params.turning_circle_radius;
	if (r < 1.0f) return false;  // negligible turning radius

	// Perpendicular direction to heading (port = left, starboard = right)
	// heading 0 = +Z, so right-perpendicular is (+cos, -sin) in XZ
	float perp_x = std::cos(state.heading);
	float perp_z = -std::sin(state.heading);

	// Starboard circle center (right of ship)
	Vector2 center_starboard(
		state.position.x + perp_x * r,
		state.position.y + perp_z * r
	);
	// Port circle center (left of ship)
	Vector2 center_port(
		state.position.x - perp_x * r,
		state.position.y - perp_z * r
	);

	float dist_starboard = waypoint.distance_to(center_starboard);
	float dist_port = waypoint.distance_to(center_port);

	// Use a slightly reduced radius to avoid false positives at the boundary.
	// A point right on the circle edge is technically reachable (tangent approach),
	// so we shrink by 10% to only catch points clearly inside the dead zone.
	float threshold = r * 0.9f;

	return (dist_starboard < threshold || dist_port < threshold);
}

// ============================================================================
// Path management
// ============================================================================

void ShipNavigator::maybe_recalc_path(Vector2 destination) {
	if (map.is_null() || !map->is_built()) {
		path_valid = false;
		return;
	}

	if (path_recalc_cooldown > 0.0f) return;

	// Tiered clearance path search
	float min_clearance = get_ship_clearance();
	float comfortable_clearance = min_clearance + params.ship_beam * 0.5f;
	comfortable_clearance = std::min(comfortable_clearance, min_clearance * 2.0f);

	// Use turning-radius-aware pathfinding
	float turning_radius = params.turning_circle_radius;

	// Try comfortable clearance first
	current_path = map->find_path_internal(state.position, destination, comfortable_clearance, turning_radius);

	if (!current_path.valid || current_path.waypoints.empty()) {
		// Fallback: minimum clearance
		current_path = map->find_path_internal(state.position, destination, min_clearance, turning_radius);
	}

	if (!current_path.valid || current_path.waypoints.empty()) {
		// Last resort: half minimum clearance, no turning penalty
		float tight_clearance = min_clearance * 0.5f;
		current_path = map->find_path_internal(state.position, destination, tight_clearance, 0.0f);
	}

	if (current_path.valid && !current_path.waypoints.empty()) {
		path_valid = true;
		current_wp_index = 0;
		// Skip the first waypoint if very close (it's our current position)
		if (current_path.waypoints.size() > 1 &&
			state.position.distance_to(current_path.waypoints[0]) < params.turning_circle_radius * 0.25f) {
			current_wp_index = 1;
		}
	} else {
		path_valid = false;
	}

	path_recalc_cooldown = PATH_RECALC_COOLDOWN;
}

bool ShipNavigator::is_destination_shift_small(Vector2 old_target, Vector2 new_target) const {
	float shift = old_target.distance_to(new_target);

	if (shift < PATH_REUSE_ABSOLUTE_THRESHOLD) return true;

	// Check relative to remaining path distance
	float remaining = state.position.distance_to(old_target);
	if (remaining > 100.0f && shift < remaining * PATH_REUSE_RELATIVE_FRACTION) {
		return true;
	}

	return false;
}

// ============================================================================
// Navigation mode: POSITION
// ============================================================================

void ShipNavigator::update_navigate_to_position() {
	float dist = state.position.distance_to(target_position);

	// Arrived?
	if (dist < params.turning_circle_radius * 0.3f) {
		nav_state = NavState::IDLE;
		set_steering_output(0.0f, 0, false, std::numeric_limits<float>::infinity());
		return;
	}

	// --- Reverse support ---
	float bearing_to_target = std::atan2(
		target_position.x - state.position.x,
		target_position.y - state.position.y);
	float angle_to_target = std::abs(angle_difference(state.heading, bearing_to_target));

	float reverse_min_dist = params.turning_circle_radius * 0.5f;

	bool use_reverse = false;
	if (angle_to_target > Math_PI * 0.55f
		// && dist > reverse_min_dist
		&& dist < params.turning_circle_radius * 2.0f
		// && std::abs(state.current_speed) < params.max_speed * 0.3f
	) {

		// Check whether the target (or current waypoint) is inside the
		// turning dead zone.  If it is, the ship can't reach it by turning
		// forward — reversing is the right move.  Also allow reverse when
		// there's no valid path (direct approach to a behind-target).
		bool target_in_dead_zone = is_waypoint_in_turning_dead_zone(target_position);

		// If following a path, also check the current waypoint
		if (!target_in_dead_zone && path_valid &&
			current_wp_index < static_cast<int>(current_path.waypoints.size())) {
			target_in_dead_zone = is_waypoint_in_turning_dead_zone(
				current_path.waypoints[current_wp_index]);
		}

		// Only block reverse if path has multiple waypoints ahead AND
		// the immediate target is NOT in the dead zone — i.e. the path
		// genuinely routes to a reachable waypoint via forward motion.
		bool path_requires_forward = false;
		if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size()) - 1
			&& !target_in_dead_zone) {
			path_requires_forward = true;
		}
		if (!path_requires_forward) {
			use_reverse = true;
		}
	}

	if (use_reverse) {
		UtilityFunctions::print(String("Using Reverse"));
		nav_state = NavState::ARRIVING;
		float desired_rudder = compute_rudder_to_position(target_position, true);
		desired_rudder = apply_gradient_bias(desired_rudder);
		int desired_throttle = -1;

		float ttc;
		bool collision;
		// float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);
		float safe_rudder = desired_rudder; // Don't do obstacle avoidance in reverse mode, it's too complex and risky

		set_steering_output(safe_rudder, collision ? -1 : desired_throttle, collision, ttc);
		return;
	}

	// --- 1. PLAN: Advance waypoints ---
	advance_waypoint();

	// --- 2. STEER: Determine steer target ---
	Vector2 steer_target;
	bool following_path = false;

	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		steer_target = current_path.waypoints[current_wp_index];
		following_path = true;
	} else {
		steer_target = target_position;
	}

	float desired_rudder = compute_rudder_to_position(steer_target);
	desired_rudder = apply_gradient_bias(desired_rudder);

	// --- 5. SPEED: Compute throttle ---
	int desired_throttle = compute_throttle_for_approach(dist);

	// Reduce throttle during tight turns
	float turn_angle = std::abs(angle_difference(state.heading,
		std::atan2(steer_target.x - state.position.x, steer_target.y - state.position.y)));
	if (turn_angle > Math_PI * 0.5f && desired_throttle > 2) {
		desired_throttle = 2;
	}

	// --- 3/4. CHECK + REACT: Select safe rudder ---
	float ttc;
	bool collision;
	float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

	// Determine nav state
	float stopping_dist = get_stopping_distance();
	if (collision) {
		if (nav_state != NavState::EMERGENCY) {
			nav_state = NavState::AVOIDING;
		}
	} else if (dist < stopping_dist + params.turning_circle_radius) {
		nav_state = NavState::ARRIVING;
	} else {
		nav_state = NavState::NAVIGATING;
	}

	// --- 6. OUTPUT ---
	int final_throttle = desired_throttle;
	if (collision) {
		if (nav_state == NavState::EMERGENCY) {
			// Emergency: apply out_throttle directly — allows reverse
			final_throttle = out_throttle;
		} else {
			final_throttle = std::min(desired_throttle, std::max(2, out_throttle));
		}
	}

	set_steering_output(safe_rudder, final_throttle, collision, ttc);

	// Recalculate if we've deviated significantly from the path or if the
	// current waypoint is trapped inside a turning dead zone (the ship would
	// orbit it forever instead of progressing along the path).
	if (following_path) {
		Vector2 nearest_wp = current_path.waypoints[current_wp_index];
		float dist_to_path = state.position.distance_to(nearest_wp);
		if (dist_to_path > params.turning_circle_radius * 2.0f) {
			maybe_recalc_path(target_position);
		} else if (is_waypoint_in_turning_dead_zone(nearest_wp)) {
			// Waypoint is inside a turning circle — advance_waypoint will
			// try to skip it next frame, but if it's the last waypoint the
			// path needs recalculation from our current position/heading.
			maybe_recalc_path(target_position);
		}
	}
}

// ============================================================================
// Navigation mode: ANGLE
// ============================================================================

void ShipNavigator::update_navigate_to_angle() {
	float remaining = angle_difference(state.heading, target_heading);
	float abs_remaining = std::abs(remaining);

	// Heading achieved?
	if (abs_remaining < 0.035f) { // ~2 degrees
		nav_state = NavState::IDLE;
		set_steering_output(0.0f, std::max(out_throttle, 2), false, std::numeric_limits<float>::infinity());
		return;
	}

	nav_state = NavState::TURNING;

	// --- Rudder lead compensation ---
	float omega_current = state.angular_velocity_y;
	float t_rudder = std::abs(state.current_rudder) * params.rudder_response_time;
	float lead_angle = std::abs(omega_current) * t_rudder * 0.5f;

	float desired_rudder;

	if (abs_remaining <= lead_angle + 0.05f) {
		// Within lead angle — start centering rudder
		float lead_ratio = abs_remaining / std::max(0.01f, lead_angle + 0.05f);
		if (remaining > 0) {
			desired_rudder = -lead_ratio;
		} else {
			desired_rudder = lead_ratio;
		}
	} else {
		if (remaining > 0) {
			desired_rudder = -1.0f;
		} else {
			desired_rudder = 1.0f;
		}
	}

	desired_rudder = apply_gradient_bias(desired_rudder);

	// Throttle: maintain half speed during large turns
	int desired_throttle;
	if (abs_remaining > Math_PI * 0.5f) {
		desired_throttle = 2;
	} else {
		desired_throttle = 3;
	}

	// Safety check
	float ttc;
	bool collision;
	float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

	int final_throttle = desired_throttle;
	if (collision) {
		if (nav_state == NavState::EMERGENCY) {
			// Emergency: apply out_throttle directly — allows reverse
			final_throttle = out_throttle;
		} else {
			nav_state = NavState::AVOIDING;
			final_throttle = std::min(desired_throttle, std::max(2, out_throttle));
		}
	}

	set_steering_output(safe_rudder, final_throttle, collision, ttc);
}

// ============================================================================
// Navigation mode: POSE
// ============================================================================

void ShipNavigator::update_navigate_to_pose() {
	float dist = state.position.distance_to(target_position);
	float heading_error = std::abs(angle_difference(state.heading, target_heading));

	float approach_radius = std::max(params.turning_circle_radius * 2.0f, get_stopping_distance() * 1.5f);

	// Arrived?
	if (dist < params.turning_circle_radius * 0.3f && heading_error < 0.1f) {
		nav_state = NavState::IDLE;
		set_steering_output(0.0f, 0, false, std::numeric_limits<float>::infinity());
		return;
	}

	// --- Reverse support ---
	float bearing_to_target = std::atan2(
		target_position.x - state.position.x,
		target_position.y - state.position.y);
	float angle_to_target = std::abs(angle_difference(state.heading, bearing_to_target));

	float reverse_min_dist = params.turning_circle_radius * 0.6f;

	bool use_reverse = false;
	if (angle_to_target > Math_PI * 0.55f
		// && dist > reverse_min_dist
		&& dist < params.turning_circle_radius * 2.0f
		// && std::abs(state.current_speed) < params.max_speed * 0.3f
	) {

		// bool target_in_dead_zone = is_waypoint_in_turning_dead_zone(target_position);

		// if (!target_in_dead_zone && path_valid &&
		// 	current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		// 	target_in_dead_zone = is_waypoint_in_turning_dead_zone(
		// 		current_path.waypoints[current_wp_index]);
		// }

		// bool path_requires_forward = false;
		// if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size()) - 1
		// 	&& !target_in_dead_zone) {
		// 	path_requires_forward = true;
		// }
		// if (!path_requires_forward) {
		// 	use_reverse = true;
		// }
		use_reverse = true;
	}

	if (use_reverse) {
		nav_state = NavState::ARRIVING;
		float desired_rudder = compute_rudder_to_position(target_position, true);
		desired_rudder = apply_gradient_bias(desired_rudder);
		int desired_throttle = -1;

		float ttc;
		bool collision;
		float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

		set_steering_output(safe_rudder, collision ? -1 : desired_throttle, collision, ttc);
		return;
	}

	if (dist > approach_radius) {
		// Phase 1: Approach — follow path like position navigation
		advance_waypoint();

		Vector2 steer_target;
		bool following_path = false;

		if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
			steer_target = current_path.waypoints[current_wp_index];
			following_path = true;
		} else {
			steer_target = target_position;
		}

		float desired_rudder = compute_rudder_to_position(steer_target);
		desired_rudder = apply_gradient_bias(desired_rudder);
		int desired_throttle = compute_throttle_for_approach(dist);

		float ttc;
		bool collision;
		float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

		if (!collision) {
			nav_state = NavState::NAVIGATING;
		} else if (nav_state != NavState::EMERGENCY) {
			nav_state = NavState::AVOIDING;
		}

		// Reduce throttle on tight turns
		float turn_angle = std::abs(angle_difference(state.heading,
			std::atan2(steer_target.x - state.position.x, steer_target.y - state.position.y)));
		if (turn_angle > Math_PI * 0.5f && desired_throttle > 2) {
			desired_throttle = 2;
		}

		int final_throttle;
		if (collision) {
			if (nav_state == NavState::EMERGENCY) {
				// Emergency: apply out_throttle directly — allows reverse
				final_throttle = out_throttle;
			} else {
				nav_state = NavState::AVOIDING;
				final_throttle = std::min(desired_throttle, std::max(2, out_throttle));
			}
		} else {
			final_throttle = desired_throttle;
		}

		set_steering_output(safe_rudder, final_throttle, collision, ttc);

		// Recalculate if deviated from path or waypoint is in turning dead zone
		if (following_path) {
			Vector2 nearest_wp = current_path.waypoints[current_wp_index];
			float dist_to_path = state.position.distance_to(nearest_wp);
			if (dist_to_path > params.turning_circle_radius * 2.0f) {
				maybe_recalc_path(target_position);
			} else if (is_waypoint_in_turning_dead_zone(nearest_wp)) {
				maybe_recalc_path(target_position);
			}
		}
	} else {
		// Phase 2: Terminal maneuver
		nav_state = NavState::ARRIVING;

		if (dist < params.turning_circle_radius * 0.5f) {
			// Close enough in position — correct heading
			float desired_rudder = compute_rudder_to_heading(target_heading);
			desired_rudder = apply_gradient_bias(desired_rudder);

			int desired_throttle = 1;

			float ttc;
			bool collision;
			float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

			int final_throttle;
			if (collision && nav_state == NavState::EMERGENCY) {
				final_throttle = out_throttle; // Emergency: allows reverse
			} else if (collision) {
				final_throttle = std::max(1, out_throttle); // Avoidance: stay moving
			} else {
				final_throttle = desired_throttle;
			}
			set_steering_output(safe_rudder, final_throttle, collision, ttc);
		} else {
			// Blend position and heading targets
			float heading_weight = 1.0f - (dist / approach_radius);
			heading_weight = clamp_f(heading_weight, 0.0f, 0.7f);

			float pos_rudder = compute_rudder_to_position(target_position);
			float heading_rudder = compute_rudder_to_heading(target_heading);

			float blended_rudder = lerp_f(pos_rudder, heading_rudder, heading_weight);
			blended_rudder = apply_gradient_bias(blended_rudder);

			int desired_throttle = compute_throttle_for_approach(dist);
			desired_throttle = std::min(desired_throttle, 2);

			float ttc;
			bool collision;
			float safe_rudder = select_safe_rudder(blended_rudder, desired_throttle, ttc, collision);

			set_steering_output(safe_rudder,
				collision ? std::min(desired_throttle, 1) : desired_throttle,
				collision, ttc);
		}
	}
}

// ============================================================================
// Navigation mode: STATION_KEEP
// ============================================================================

void ShipNavigator::update_station_keep(float delta) {
	Vector2 zone_center(station_center.x, station_center.z);
	float dist_to_center = state.position.distance_to(zone_center);
	bool inside_zone = dist_to_center <= station_radius;
	float heading_error = std::abs(angle_difference(state.heading, station_preferred_heading));
	float speed = std::abs(state.current_speed);

	switch (nav_state) {
		// -------------------------------------------------------
		case NavState::STATION_APPROACH: {
			if (inside_zone) {
				nav_state = NavState::STATION_SETTLE;
				station_settle_timer = 0.0f;
				break;
			}

			// Advance waypoints
			advance_waypoint();

			Vector2 steer_target;
			bool following_path = false;
			if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
				steer_target = current_path.waypoints[current_wp_index];
				following_path = true;
			} else {
				Vector2 dir_to_center = (zone_center - state.position).normalized();
				steer_target = zone_center - dir_to_center * (station_radius * 0.5f);
			}

			float bearing_to_target = std::atan2(
				steer_target.x - state.position.x,
				steer_target.y - state.position.y);
			float turn_angle = std::abs(angle_difference(state.heading, bearing_to_target));

			float dist_to_zone_edge = dist_to_center - station_radius;
			float stopping_dist = get_stopping_distance();

			// Reverse support
			bool use_reverse = false;
			if (turn_angle > Math_PI * 0.65f
				&& dist_to_zone_edge < params.turning_circle_radius * 2.0f
				&& std::abs(state.current_speed) < params.max_speed * 0.3f) {
				use_reverse = true;
			}

			float desired_rudder;
			int desired_throttle;

			if (use_reverse) {
				desired_rudder = compute_rudder_to_position(steer_target, true);
				desired_throttle = -1;
				desired_rudder = apply_gradient_bias(desired_rudder);

				float ttc;
				bool collision;
				float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);
				set_steering_output(safe_rudder, collision ? -1 : desired_throttle, collision, ttc);
			} else {
				desired_rudder = compute_rudder_to_position(steer_target);
				desired_rudder = apply_gradient_bias(desired_rudder);

				desired_throttle = compute_throttle_for_approach(dist_to_zone_edge);
				if (dist_to_zone_edge < stopping_dist * 2.0f) {
					desired_throttle = std::min(desired_throttle, 2);
				}

				float ttc;
				bool collision;
				float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

				int final_throttle;
				if (collision && nav_state == NavState::EMERGENCY) {
					final_throttle = out_throttle;
				} else if (collision) {
					final_throttle = std::min(desired_throttle, 1);
					// Reduce speed on tight turns
					if (turn_angle > Math_PI * 0.5f) {
						final_throttle = std::min(final_throttle, 1);
					}
				} else {
					final_throttle = desired_throttle;
					// Reduce speed on tight turns
					if (turn_angle > Math_PI * 0.5f) {
						final_throttle = std::min(final_throttle, 1);
					}
				}

				set_steering_output(safe_rudder, final_throttle, collision, ttc);
			}

			break;
		}

		// -------------------------------------------------------
		case NavState::STATION_SETTLE: {
			station_settle_timer += delta;

			if (speed < STATION_SPEED_THRESHOLD && heading_error < STATION_HEADING_TOLERANCE) {
				nav_state = NavState::STATION_HOLDING;
				station_hold_timer = 0.0f;
				break;
			}

			// Allow the ship to maneuver within a generous margin around
			// the zone.  During a 3-point turn the ship may briefly exit
			// the zone boundary; only bail to STATION_RECOVER if it
			// drifts significantly outside (50% beyond radius).
			if (dist_to_center > station_radius * 1.5f) {
				nav_state = NavState::STATION_RECOVER;
				break;
			}

			// How much room the ship has in various directions within the zone.
			// Used to modulate throttle so the ship doesn't overshoot.
			float dist_to_zone_edge = station_radius - dist_to_center;
			// When outside the zone boundary, dist_to_zone_edge is negative.
			// Clamp to a small positive value so throttle logic still works.
			float room_ahead = std::max(dist_to_zone_edge, params.ship_beam);

			// Direction from ship toward zone center — used to bias steering
			// so the 3-point turn stays near the middle of the zone.
			Vector2 to_center = zone_center - state.position;

			// 3-point turn: when heading error is large and the ship is
			// nearly stopped, reverse with rudder to swing the bow toward
			// the desired heading.  Once the error drops below the
			// threshold, switch to forward motion to complete the turn.
			bool use_reverse_settle = heading_error > Math_PI * 0.5f
				&& speed < STATION_SPEED_THRESHOLD * 2.0f;

			if (use_reverse_settle) {
				// Reverse leg of the 3-point turn.
				// compute_rudder_to_heading gives the rudder for forward
				// motion; negate it so the reversed rudder effect still
				// swings the bow toward station_preferred_heading.
				float desired_rudder = -compute_rudder_to_heading(station_preferred_heading);

				// Bias toward zone center when getting far from it so the
				// ship doesn't reverse out of the zone.  The stern should
				// aim roughly toward the center.
				if (dist_to_center > station_radius * 0.5f) {
					float center_rudder = compute_rudder_to_position(zone_center, true);
					float proximity = clamp_f(
						(dist_to_center - station_radius * 0.5f) / (station_radius * 0.5f),
						0.0f, 0.8f);
					desired_rudder = lerp_f(desired_rudder, center_rudder, proximity);
				}

				desired_rudder = apply_gradient_bias(desired_rudder);
				int desired_throttle = -1;

				float ttc;
				bool collision;
				float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

				int final_throttle = (collision && nav_state == NavState::EMERGENCY)
					? out_throttle : desired_throttle;
				set_steering_output(safe_rudder, final_throttle, collision, ttc);
			} else {
				// Forward leg of the 3-point turn / normal settle.
				// Steer toward the desired heading, but also bias toward
				// the zone center so the ship stays inside the zone and
				// doesn't just creep in a straight line away from it.
				float heading_rudder = 0.0f;
				if (heading_error > 0.05f) {
					heading_rudder = compute_rudder_to_heading(station_preferred_heading);
				}

				// Blend in a center-seeking component when drifting away
				float center_rudder = compute_rudder_to_position(zone_center);
				float center_weight = clamp_f(dist_to_center / station_radius, 0.0f, 0.5f);
				float desired_rudder = lerp_f(heading_rudder, center_rudder, center_weight);

				desired_rudder = apply_gradient_bias(desired_rudder);

				int desired_throttle;
				if (heading_error > STATION_HEADING_TOLERANCE && speed < STATION_SPEED_THRESHOLD * 2.0f) {
					desired_throttle = 1;
					// Cut throttle when near the zone edge so the ship
					// doesn't overshoot out of the zone on the forward leg.
					if (room_ahead < params.turning_circle_radius) {
						desired_throttle = 0;
					}
				} else {
					desired_throttle = 0;
				}

				float ttc;
				bool collision;
				float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

				int final_throttle = (collision && nav_state == NavState::EMERGENCY)
					? out_throttle : desired_throttle;
				set_steering_output(safe_rudder, final_throttle, collision, ttc);
			}
			break;
		}

		// -------------------------------------------------------
		case NavState::STATION_HOLDING: {
			station_hold_timer += delta;

			if (!inside_zone) {
				// Don't jump straight to recover for minor drift — let
				// settle handle re-alignment within the zone margin.
				if (dist_to_center > station_radius * 1.5f) {
					nav_state = NavState::STATION_RECOVER;
				} else {
					nav_state = NavState::STATION_SETTLE;
					station_settle_timer = 0.0f;
				}
				break;
			}

			float desired_rudder = 0.0f;
			if (heading_error > STATION_HEADING_TOLERANCE * 1.5f) {
				desired_rudder = compute_rudder_to_heading(station_preferred_heading);
				desired_rudder = clamp_f(desired_rudder, -0.3f, 0.3f);
			}

			desired_rudder = apply_gradient_bias(desired_rudder);

			int desired_throttle = 0;
			if (std::abs(desired_rudder) > 0.1f && speed < 1.0f) {
				desired_throttle = 1;
			}

			float ttc;
			bool collision;
			float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

			int final_throttle = (collision && nav_state == NavState::EMERGENCY)
				? out_throttle : desired_throttle;
			set_steering_output(safe_rudder, final_throttle, collision, ttc);
			break;
		}

		// -------------------------------------------------------
		case NavState::STATION_RECOVER: {
			nav_state = NavState::STATION_APPROACH;
			// if (inside_zone) {
			// 	nav_state = NavState::STATION_SETTLE;
			// 	station_settle_timer = 0.0f;
			// 	break;
			// }

			// float desired_rudder = compute_rudder_to_position(zone_center);
			// desired_rudder = apply_gradient_bias(desired_rudder);

			// int desired_throttle = 1;
			// if (dist_to_center > station_radius * 3.0f) {
			// 	desired_throttle = 2;
			// }

			// float ttc;
			// bool collision;
			// float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

			// set_steering_output(safe_rudder,
			// 	collision ? std::min(desired_throttle, 1) : desired_throttle,
			// 	collision, ttc);

			// // Replan if far drift
			// if (dist_to_center > station_radius * 2.0f) {
			// 	Vector2 dir_to_center = (zone_center - state.position).normalized();
			// 	Vector2 entry_point = zone_center - dir_to_center * (station_radius * 0.5f);
			// 	target_position = entry_point;
			// 	maybe_recalc_path(entry_point);
			// 	nav_state = NavState::STATION_APPROACH;
			// }

			// break;
		}

		// -------------------------------------------------------
		default: {
			if (!inside_zone) {
				nav_state = NavState::STATION_APPROACH;
				Vector2 dir_to_center = (zone_center - state.position).normalized();
				Vector2 entry_point = zone_center - dir_to_center * (station_radius * 0.7f);
				target_position = entry_point;
				maybe_recalc_path(entry_point);
			} else if (speed > STATION_SPEED_THRESHOLD || heading_error > STATION_HEADING_TOLERANCE) {
				nav_state = NavState::STATION_SETTLE;
				station_settle_timer = 0.0f;
			} else {
				nav_state = NavState::STATION_HOLDING;
				station_hold_timer = 0.0f;
			}

			set_steering_output(0.0f, 0, false, std::numeric_limits<float>::infinity());
			break;
		}
	}
}
