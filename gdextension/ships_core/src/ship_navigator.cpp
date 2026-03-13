#include "ship_navigator.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <algorithm>
#include <sstream>
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
	ClassDB::bind_method(D_METHOD("set_near_terrain", "enabled"), &ShipNavigator::set_near_terrain);
	ClassDB::bind_method(D_METHOD("get_near_terrain"), &ShipNavigator::get_near_terrain);
	ClassDB::bind_method(D_METHOD("set_grounded", "grounded"), &ShipNavigator::set_grounded);
	ClassDB::bind_method(D_METHOD("get_grounded"), &ShipNavigator::get_grounded);

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

	// Timing
	ClassDB::bind_method(D_METHOD("get_timing_update_us"), &ShipNavigator::get_timing_update_us);
	ClassDB::bind_method(D_METHOD("get_timing_avoidance_us"), &ShipNavigator::get_timing_avoidance_us);
	ClassDB::bind_method(D_METHOD("get_timing_plan_us"), &ShipNavigator::get_timing_plan_us);
	ClassDB::bind_method(D_METHOD("get_timing_replan_reason"), &ShipNavigator::get_timing_replan_reason);
	ClassDB::bind_method(D_METHOD("get_timing_plan_phase"), &ShipNavigator::get_timing_plan_phase);

	// Backward-compatible stubs
	ClassDB::bind_method(D_METHOD("validate_destination_pose", "ship_position", "candidate"), &ShipNavigator::validate_destination_pose);
	ClassDB::bind_method(D_METHOD("get_simulated_path"), &ShipNavigator::get_simulated_path);
	ClassDB::bind_method(D_METHOD("is_simulation_complete"), &ShipNavigator::is_simulation_complete);
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
	out_time_to_collision = std::numeric_limits<float>::infinity();
	predicted_arc_fresh = false;
	timing_update_us = 0.0f;
	timing_avoidance_us = 0.0f;
	timing_plan_us = 0.0f;
	timing_replan_reason = 0;
	timing_plan_phase_val = 0;
	avoidance_frame_counter = 0;
	cached_avoidance = {0.0f, 0.0f, false};
	cached_avoidance_valid = false;
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
	predicted_arc_fresh = false;

	// Run state machine
	update(delta);

	// Update predicted arc for debug visualization
	// (skipped if compute_avoidance already set it this frame)
	if (!predicted_arc_fresh) {
		update_predicted_arc();
	}
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
		cached_avoidance_valid = false;
	}
}

void ShipNavigator::stop() {
	target.position = state.position;
	target.heading = state.heading;
	target.hold_radius = 0.0f;
	path_valid = false;
	set_steering_output(0.0f, 0, false, std::numeric_limits<float>::infinity());
}

void ShipNavigator::set_near_terrain(bool /*enabled*/) {
	// No-op — avoidance is always weighted in the new system
}

bool ShipNavigator::get_near_terrain() const {
	return false;
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
	return target.heading;
}

float ShipNavigator::get_distance_to_destination() const {
	return state.position.distance_to(target.position);
}

String ShipNavigator::get_debug_info() const {
	std::ostringstream oss;

	const char *state_names[] = {"NORMAL", "EMERGENCY"};
	int si = static_cast<int>(nav_state);

	oss << "state=" << (si >= 0 && si <= 1 ? state_names[si] : "?")
		<< " rudder=" << out_rudder
		<< " throttle=" << out_throttle
		<< " speed=" << state.current_speed
		<< " dist=" << state.position.distance_to(target.position)
		<< " grounded=" << grounded_
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
	float turn_arc = params.turning_circle_radius * 1.57f;
	float physics_dist = rudder_lag_dist + turn_arc + params.ship_length;
	float legacy_min = params.ship_length * 3.0f;
	float stopping = get_stopping_distance();
	float dist = std::max({legacy_min, physics_dist, stopping + params.ship_length * 2.0f});
	float max_dist = std::max(params.ship_length * 8.0f, 3000.0f);
	return std::min(dist, max_dist);
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
	// Use shorter lookahead for debug visualization to reduce sim cost
	float debug_lookahead = std::min(get_lookahead_distance(), params.ship_length * 4.0f);
	predicted_arc = predict_arc_internal(out_rudder, out_throttle, debug_lookahead);
}

// ============================================================================
// Two-state machine
// ============================================================================

void ShipNavigator::update(float delta) {
	auto t0 = std::chrono::steady_clock::now();

	// Transition to EMERGENCY if grounded or SDF indicates on land
	if (nav_state != NavState::EMERGENCY) {
		if (grounded_) {
			nav_state = NavState::EMERGENCY;
		} else if (map.is_valid() && map->is_built()) {
			float sdf = map->get_distance(state.position.x, state.position.y);
			if (sdf <= 0.0f) {
				nav_state = NavState::EMERGENCY;
			}
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
	// --- 1. Path planning (event-driven) ---
	auto plan_t0 = std::chrono::steady_clock::now();

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

	// --- 3. Compute desired rudder + throttle ---
	float desired_rudder = 0.0f;
	int desired_throttle = 4;

	float dist_to_dest = state.position.distance_to(target.position);

	// arrived_radius: close enough — stop seeking position, just hold heading
	float arrived_radius = std::max(target.hold_radius, params.turning_circle_radius * 2.0f);
	// approach_radius: start slowing and blending toward heading
	// Must be strictly larger than arrived_radius by at least 1 TCR
	float approach_radius_inner = std::max(arrived_radius + params.turning_circle_radius,
	                                        get_stopping_distance() * 1.5f);

	bool path_exhausted = !path_valid || current_wp_index >= static_cast<int>(current_path.waypoints.size());

	// Precompute whether destination is ahead or behind
	Vector2 to_dest = target.position - state.position;
	float forward_x = std::sin(state.heading);
	float forward_z = std::cos(state.heading);
	float along = to_dest.x * forward_x + to_dest.y * forward_z;
	bool dest_behind = (along < 0.0f);

	if (path_exhausted && dist_to_dest < approach_radius_inner) {
		// Only slow down / arrive when there are no more waypoints — full speed through intermediate ones
		if (dist_to_dest < arrived_radius) {
			// Arrived: stop and align to desired heading
			desired_rudder = compute_rudder_to_heading(target.heading);
			desired_throttle = 0;
		} else if (dest_behind && dist_to_dest < params.turning_circle_radius * 3.0f
				   && dist_to_dest > params.ship_beam) {
			// Destination behind in approach zone: reverse toward it
			desired_rudder = compute_rudder_to_position(target.position, true);
			desired_throttle = -1;
		} else {
			// Approaching final destination: blend from position-seek to heading as we close in
			float blend_width = std::max(approach_radius_inner - arrived_radius, 1.0f);
			float t = (dist_to_dest - arrived_radius) / blend_width;
			float heading_weight = clamp_f(1.0f - t, 0.0f, 0.8f);

			float pos_rudder = compute_rudder_to_position(target.position);
			float heading_rudder = compute_rudder_to_heading(target.heading);
			desired_rudder = lerp_f(pos_rudder, heading_rudder, heading_weight);
			desired_throttle = compute_throttle_for_approach(dist_to_dest);
		}
	} else if (is_waypoint_behind_no_room()) {
		// Waypoint behind + no room to turn: steer outward at full speed
		desired_rudder = compute_outward_rudder();
		desired_throttle = 4;
	} else if (!path_exhausted) {
		// Pure pursuit toward next waypoint — full speed
		desired_rudder = compute_pure_pursuit_rudder();
		desired_throttle = 4;
	} else {
		// No path or beyond approach zone — steer directly to destination
		if (dest_behind && dist_to_dest < params.turning_circle_radius * 3.0f
			&& dist_to_dest > params.ship_beam) {
			desired_rudder = compute_rudder_to_position(target.position, true);
			desired_throttle = -1;
		} else {
			desired_rudder = compute_rudder_to_position(target.position);
			desired_throttle = 4;
		}
	}

	// --- 4. Avoidance blend ---
	// Throttle avoidance: full scan every AVOIDANCE_FULL_INTERVAL frames,
	// reuse cached result on intermediate frames. Always run full scan if
	// cached result shows a threat (weight > 0) or on torpedo threat.
	auto avoid_t0 = std::chrono::steady_clock::now();

	avoidance_frame_counter++;
	bool run_full_avoidance = !cached_avoidance_valid
		|| (avoidance_frame_counter >= AVOIDANCE_FULL_INTERVAL)
		|| cached_avoidance.weight > 0.1f
		|| cached_avoidance.torpedo;

	AvoidanceResult avoid;
	if (run_full_avoidance) {
		avoid = compute_avoidance(desired_rudder, desired_throttle);
		cached_avoidance = avoid;
		cached_avoidance_valid = true;
		avoidance_frame_counter = 0;
	} else {
		avoid = cached_avoidance;
	}

	auto avoid_t1 = std::chrono::steady_clock::now();
	timing_avoidance_us = std::chrono::duration<float, std::micro>(avoid_t1 - avoid_t0).count();

	// Rudder blend uses rudder_weight (includes soft-zone nudge)
	// Throttle decisions use weight (hard threats only)
	float final_rudder = lerp_f(desired_rudder, avoid.rudder, avoid.rudder_weight);
	int final_throttle = desired_throttle;

	if (avoid.torpedo) {
		// Torpedo: full override, never reduce throttle
		final_throttle = std::max(desired_throttle, 4);
		final_rudder = avoid.rudder;
	} else if (avoid.weight > 0.5f && run_full_avoidance) {
		// Hard threat: check if reduced-throttle arc is clearer (only on full scan frames)
		int reduced = std::max(1, desired_throttle - 2);
		float short_lookahead = get_lookahead_distance() * 0.5f;
		auto reduced_arc = predict_arc_internal(final_rudder, reduced, short_lookahead);
		float reduced_arc_time = reduced_arc.empty() ? 0.0f : reduced_arc.back().time;
		float reduced_ttc = std::min(
			check_arc_collision(reduced_arc, get_ship_clearance() / 2.0f, get_ship_clearance() / 2.0f),
			check_arc_obstacles(reduced_arc));
		if (reduced_ttc > reduced_arc_time * 0.9f) {
			// Reduced throttle is clear — no need to slow down, steering alone works
		} else {
			final_throttle = reduced;
		}
	}

	bool collision = avoid.weight > 0.1f;
	float ttc = collision ? 5.0f : std::numeric_limits<float>::infinity();
	set_steering_output(final_rudder, final_throttle, collision, ttc);
}

// ============================================================================
// EMERGENCY state — grounded or critical collision
// ============================================================================

void ShipNavigator::update_emergency(float delta) {
	(void)delta;

	if (!map.is_valid() || !map->is_built()) {
		float rudder = (state.angular_velocity_y > 0.0f) ? 1.0f : -1.0f;
		set_steering_output(rudder, -1, true, 0.0f);
		return;
	}

	// Exit condition: not grounded AND forward arc is clear
	if (!grounded_) {
		auto forward_arc = predict_arc_internal(0.0f, 2, get_lookahead_distance());
		float arc_time = forward_arc.empty() ? 0.0f : forward_arc.back().time;
		float ttc = check_arc_collision(forward_arc, get_ship_clearance() / 2.0f, get_soft_clearance());

		if (ttc >= arc_time * 0.9f) {
			nav_state = NavState::NORMAL;
			replan_requested_ = true; // force immediate replan
			return;
		}
	}

	// Follow SDF gradient away from land
	Vector2 grad = map->get_gradient(state.position.x, state.position.y);
	float escape_heading = std::atan2(grad.x, grad.y);
	float rudder = compute_rudder_to_heading(escape_heading);
	float angle_to_escape = std::abs(angle_difference(state.heading, escape_heading));

	if (angle_to_escape < Math_PI * 0.5f) {
		set_steering_output(rudder, 4, true, 0.0f);
	} else {
		set_steering_output(rudder, -1, true, 0.0f);
	}
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
// Simplified avoidance (replaces select_safe_rudder)
// ============================================================================

ShipNavigator::AvoidanceResult ShipNavigator::compute_avoidance(float desired_rudder, int desired_throttle) {
	AvoidanceResult result = {desired_rudder, 0.0f, 0.0f, false};

	float hard_clearance = get_ship_clearance() / 2.0f;
	float soft_clearance = get_soft_clearance();
	float lookahead = get_lookahead_distance();

	// --- Fast early-exit: skip arc prediction when clearly safe ---
	// Check terrain: if SDF at current position is much larger than soft clearance,
	// no terrain threat is possible within the lookahead arc.
	bool terrain_safe = false;
	if (map.is_valid() && map->is_built()) {
		float sdf_here = map->get_distance(state.position.x, state.position.y);
		if (sdf_here > soft_clearance + lookahead) {
			terrain_safe = true;
		}
	}

	// Check obstacles: skip if no obstacle is within engagement range
	bool obstacles_safe = true;
	float engagement_range = lookahead + params.max_speed * 30.0f; // max distance an obstacle could interact
	for (const auto &[id, obs] : obstacles) {
		float dist = state.position.distance_to(obs.position);
		if (dist < engagement_range) {
			obstacles_safe = false;
			break;
		}
	}

	if (terrain_safe && obstacles_safe) {
		return result;
	}

	// Test desired trajectory
	auto desired_arc = predict_arc_internal(desired_rudder, desired_throttle, lookahead);
	float arc_time = desired_arc.empty() ? 0.0f : desired_arc.back().time;

	// Cache for debug visualization (avoid recomputing in update_predicted_arc)
	predicted_arc = desired_arc;
	predicted_arc_fresh = true;

	// Terrain collision — split hard vs soft so soft zone only nudges rudder, not throttle
	float ttc_terrain_hard = check_arc_collision(desired_arc, hard_clearance, hard_clearance);
	float ttc_terrain_full = check_arc_collision(desired_arc, hard_clearance, soft_clearance);
	float terrain_weight = 0.0f;       // hard threats only — drives throttle reduction
	float terrain_nudge = 0.0f;        // soft zone — gentle rudder nudge, no throttle impact
	if (ttc_terrain_hard < arc_time * 0.95f) {
		terrain_weight = clamp_f(1.0f - (ttc_terrain_hard / std::max(arc_time, 0.1f)), 0.0f, 1.0f);
	} else if (ttc_terrain_full < arc_time * 0.95f) {
		// Soft zone only: small nudge, capped so it doesn't dominate the rudder
		terrain_nudge = clamp_f((1.0f - (ttc_terrain_full / std::max(arc_time, 0.1f))) * 0.4f, 0.0f, 0.25f);
	}

	// Obstacle collision weight
	ObstacleCollisionInfo obs_info = check_arc_obstacles_detailed(desired_arc);
	float ttc_obstacles = obs_info.time_to_collision;
	float obs_weight = 0.0f;
	bool torpedo_threat = false;

	if (obs_info.has_collision) {
		if (obs_info.is_torpedo) {
			obs_weight = 1.0f;
			torpedo_threat = true;
		} else {
			obs_weight = clamp_f(1.0f - (ttc_obstacles / std::max(arc_time, 0.1f)), 0.0f, 0.8f);
		}
	}

	float total_weight = std::max(terrain_weight, obs_weight);              // hard threats only
	float total_rudder_weight = std::max({total_weight, terrain_nudge});    // includes soft nudge
	if (total_rudder_weight < 0.01f) return result;

	// --- Find best avoidance rudder ---
	float best_ttc = std::min(ttc_terrain_hard, ttc_obstacles);
	float best_rudder = desired_rudder;

	// Torpedo dodge: compute bias toward perpendicular escape
	float dodge_bias = 0.0f;
	if (torpedo_threat && obs_info.has_collision) {
		Vector2 torpedo_dir = obs_info.obstacle_velocity;
		float torp_speed = torpedo_dir.length();
		if (torp_speed > 1.0f) {
			torpedo_dir /= torp_speed;
			Vector2 ship_side = state.position - obs_info.obstacle_position;
			float cross = torpedo_dir.x * ship_side.y - torpedo_dir.y * ship_side.x;
			dodge_bias = (cross >= 0.0f) ? -1.0f : 1.0f;
		}
	}

	// Obstacle ship avoidance: compute COLREGS bias
	float obs_bias = 0.0f;
	if (!torpedo_threat && obs_info.has_collision) {
		float obs_speed = obs_info.obstacle_velocity.length();
		float our_heading_x = std::sin(state.heading);
		float our_heading_z = std::cos(state.heading);
		Vector2 our_dir(our_heading_x, our_heading_z);

		Vector2 obs_dir = (obs_speed > 0.5f)
			? obs_info.obstacle_velocity / obs_speed
			: our_dir;

		float heading_dot = our_dir.dot(obs_dir);
		bool overtaking = (heading_dot > 0.5f);

		if (overtaking) {
			Vector2 to_obs = obs_info.obstacle_position - state.position;
			float cross = our_dir.x * to_obs.y - our_dir.y * to_obs.x;
			obs_bias = (cross >= 0.0f) ? 1.0f : -1.0f;
		} else {
			// Standard COLREGS: starboard turn (negative rudder)
			obs_bias = -1.0f;
		}
	}

	// Scan rudder offsets — use shorter lookahead for candidates (only need near-term clearance)
	float cand_lookahead = std::min(lookahead, lookahead * 0.6f + params.ship_length * 3.0f);
	const float magnitude_steps[] = { 0.3f, 0.6f, 1.0f, 1.5f, 2.0f };
	constexpr int n_steps = 5;

	// Build directional offsets: primary direction first, then secondary
	float bias = torpedo_threat ? dodge_bias : (obs_info.has_collision ? obs_bias : 0.0f);
	if (std::abs(bias) < 0.01f) bias = -1.0f; // default starboard

	float offsets[n_steps * 2];
	for (int i = 0; i < n_steps; ++i) {
		offsets[i]           =  magnitude_steps[i] * bias;
		offsets[i + n_steps] = -magnitude_steps[i] * bias;
	}

	float last_candidate = desired_rudder;
	for (int i = 0; i < n_steps * 2; ++i) {
		float candidate = clamp_f(desired_rudder + offsets[i], -1.0f, 1.0f);
		if (candidate == desired_rudder || candidate == last_candidate) continue;
		last_candidate = candidate;

		auto arc = predict_arc_internal(candidate, desired_throttle, cand_lookahead);
		float cand_arc_time = arc.empty() ? 0.0f : arc.back().time;
		float cand_ttc = std::min(
			check_arc_collision(arc, hard_clearance, soft_clearance),
			check_arc_obstacles(arc));

		if (cand_ttc > best_ttc) {
			best_ttc = cand_ttc;
			best_rudder = candidate;
			if (best_ttc >= cand_arc_time * 0.95f) break;
		}
	}

	result.rudder = best_rudder;
	result.weight = total_weight;
	result.rudder_weight = total_rudder_weight;
	result.torpedo = torpedo_threat;
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
// Waypoint-behind-no-room check
// ============================================================================

bool ShipNavigator::is_waypoint_behind_no_room() const {
	if (!path_valid || current_wp_index >= static_cast<int>(current_path.waypoints.size())) return false;

	Vector2 wp = current_path.waypoints[current_wp_index];
	Vector2 to_wp = wp - state.position;
	float forward_x = std::sin(state.heading);
	float forward_z = std::cos(state.heading);
	float along = to_wp.x * forward_x + to_wp.y * forward_z;

	// Waypoint is not behind
	if (along >= 0.0f) return false;

	// Check if there's room to turn
	if (!map.is_valid() || !map->is_built()) return false;

	// Check SDF in the turn direction — if less than turning radius, no room
	float lateral = to_wp.x * forward_z - to_wp.y * forward_x;
	float turn_dir = (lateral >= 0.0f) ? 1.0f : -1.0f;

	// Sample SDF at the turning circle center
	float perp_x = std::cos(state.heading) * turn_dir;
	float perp_z = -std::sin(state.heading) * turn_dir;
	Vector2 turn_center(
		state.position.x + perp_x * params.turning_circle_radius,
		state.position.y + perp_z * params.turning_circle_radius);
	float sdf = map->get_distance(turn_center.x, turn_center.y);

	return sdf < params.turning_circle_radius * 1.5f;
}

// ============================================================================
// Steer away from land when waypoint is behind
// ============================================================================

float ShipNavigator::compute_outward_rudder() const {
	if (!map.is_valid() || !map->is_built()) return 0.0f;

	// Follow SDF gradient to steer toward open water
	Vector2 grad = map->get_gradient(state.position.x, state.position.y);
	float outward_heading = std::atan2(grad.x, grad.y);
	return compute_rudder_to_heading(outward_heading);
}

// ============================================================================
// Path replan checks
// ============================================================================

// check_replan_needed removed — replans are purely event-driven now
// (triggered by navigate_to when destination/heading changes, or !path_valid)

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

	const float alignment_threshold = 0.087f;

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
		// Desired bow direction: pointing away from target so stern faces target.
		float bow_away = normalize_angle(target_angle + Math_PI);
		float angle_err = angle_difference(state.heading, bow_away);
		// In reverse, rudder effectiveness is sign-inverted vs forward
		// (physics: desired_omega = (speed / R) * -rudder; negative speed flips sign).
		// Bypass the angular_velocity compensation in compute_rudder_to_heading — it
		// assumes forward motion and produces wrong corrections when reversing.
		static constexpr float full = static_cast<float>(Math_PI / 6.0);
		return clamp_f(angle_err / full, -1.0f, 1.0f);
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

	return clamp_f(rudder, -1.0f, 1.0f);
}

int ShipNavigator::compute_throttle_for_approach(float distance_to_target) const {
	float stopping_dist = get_stopping_distance();
	float safety_margin = params.turning_circle_radius * 0.5f;

	// Within ship beam: fully stopped, just hold heading
	if (distance_to_target < params.ship_beam * 2.0f) {
		return 0;
	}
	// Within stopping distance: crawl
	if (distance_to_target < stopping_dist + safety_margin) {
		return 1;
	}
	return 4;
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
