#include "ship_navigator.h"
#include "godot_cpp/templates/safe_refcount.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <algorithm>
#include <limits>

#include <chrono>

using namespace godot;

// ============================================================================
// Bind methods
// ============================================================================

void ShipNavigator::_bind_methods() {
	// Setup
	ClassDB::bind_method(D_METHOD("set_map", "map"), &ShipNavigator::set_map);
	ClassDB::bind_method(D_METHOD("set_hpa_graph", "graph"), &ShipNavigator::set_hpa_graph);
	ClassDB::bind_method(D_METHOD("get_hpa_graph"), &ShipNavigator::get_hpa_graph);
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
	ClassDB::bind_method(D_METHOD("navigate_to", "target", "heading", "hold_radius", "heading_tolerance", "heading_weight"),
		&ShipNavigator::navigate_to, DEFVAL(0.0f), DEFVAL(0.2618f), DEFVAL(0.0f));
	ClassDB::bind_method(D_METHOD("stop"), &ShipNavigator::stop);

	ClassDB::bind_method(D_METHOD("set_grounded", "grounded"), &ShipNavigator::set_grounded);
	ClassDB::bind_method(D_METHOD("get_grounded"), &ShipNavigator::get_grounded);

	ClassDB::bind_method(D_METHOD("set_health_fraction", "fraction"), &ShipNavigator::set_health_fraction);

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

	// Incoming shell avoidance
	ClassDB::bind_method(D_METHOD("clear_incoming_shells"), &ShipNavigator::clear_incoming_shells);
	ClassDB::bind_method(D_METHOD("add_incoming_shell", "id", "landing_pos", "time_remaining", "caliber", "landing_dir", "threat_half_len"),
		&ShipNavigator::add_incoming_shell);

	// Enemy threat avoidance (stealth pathfinding)
	ClassDB::bind_method(D_METHOD("set_threat_source", "registry", "team_id", "effective_radius"),
		&ShipNavigator::set_threat_source);
	ClassDB::bind_method(D_METHOD("clear_threat_source"), &ShipNavigator::clear_threat_source);

	// Path info
	ClassDB::bind_method(D_METHOD("get_current_path"), &ShipNavigator::get_current_path);
	ClassDB::bind_method(D_METHOD("get_predicted_trajectory"), &ShipNavigator::get_predicted_trajectory);
	ClassDB::bind_method(D_METHOD("get_current_waypoint"), &ShipNavigator::get_current_waypoint);

	// Debug
	ClassDB::bind_method(D_METHOD("get_desired_heading"), &ShipNavigator::get_desired_heading);
	ClassDB::bind_method(D_METHOD("get_distance_to_destination"), &ShipNavigator::get_distance_to_destination);
	ClassDB::bind_method(D_METHOD("is_arrived"), &ShipNavigator::is_arrived);

	ClassDB::bind_method(D_METHOD("get_clearance_radius"), &ShipNavigator::get_ship_clearance);
	ClassDB::bind_method(D_METHOD("get_soft_clearance_radius"), &ShipNavigator::get_soft_clearance);

	ClassDB::bind_method(D_METHOD("get_debug_torpedo_threat_points"), &ShipNavigator::get_debug_torpedo_threat_points);
	ClassDB::bind_method(D_METHOD("get_debug_threat_clusters"), &ShipNavigator::get_debug_threat_clusters);
	ClassDB::bind_method(D_METHOD("adjust_destination_for_threats", "ship_pos", "dest"),
		&ShipNavigator::adjust_destination_for_threats);

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
	health_fraction_ = 1.0f;
	dodge_committed_rudder_ = 0.0f;
	dodge_commitment_timer_ = 0.0f;
	emergency_grounding_pos = Vector2();
	emergency_initialized = false;
	bot_id_ = 0;
}

ShipNavigator::~ShipNavigator() {
	if (threat_bin_ && threat_registry_.is_valid()) {
		threat_registry_->release_bin(threat_bin_);
	}
	threat_bin_ = nullptr;
	threat_registry_.unref();
}

// ============================================================================
// Setup
// ============================================================================

void ShipNavigator::set_map(Ref<NavigationMap> p_map) {
	map = p_map;
}

void ShipNavigator::set_hpa_graph(Ref<HpaGraph> graph) {
	hpa_graph_ = graph;
}



void ShipNavigator::set_bot_id(int id) {
	bot_id_ = id;
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

void ShipNavigator::navigate_to(Vector3 p_target, float p_heading, float p_hold_radius, float p_heading_tolerance, float p_heading_weight) {
	Vector2 new_pos(p_target.x, p_target.z);
	target.position = new_pos;
	target.heading = p_heading;
	target.hold_radius = p_hold_radius;
	target.heading_tolerance = p_heading_tolerance;
	target.heading_weight = clamp_f(p_heading_weight, 0.0f, 1.0f);
	replan_requested_ = true;
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

void ShipNavigator::set_health_fraction(float fraction) {
	health_fraction_ = std::max(0.0f, std::min(fraction, 1.0f));
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
	// Forward circular obstacle to HPA* for cluster-level blocking.
	// Use only ship_beam as the padding margin (not full ship clearance) since
	// HPA* is a high-level planner and fine-grained avoidance is handled by
	// the arc simulation.  Over-inflating the radius here causes ships to route
	// excessively far around other ships.
	if (hpa_graph_.is_valid() && hpa_graph_->is_built()) {
		float effective_radius = std::max(radius, length * 0.5f) + params.ship_beam;
		hpa_graph_->add_obstacle(id, position, effective_radius);
	}
}

void ShipNavigator::update_obstacle(int id, Vector2 position, Vector2 velocity) {
	auto it = obstacles.find(id);
	if (it != obstacles.end()) {
		it->second.position = position;
		it->second.velocity = velocity;
		// Keep heading updated from velocity; retain last known heading when parked.
		float vlen = std::sqrt(velocity.x * velocity.x + velocity.y * velocity.y);
		if (vlen > 0.5f) {
			it->second.heading = std::atan2(velocity.x, velocity.y);
		}
	}
	// Re-register obstacle at new position in HPA*
	if (hpa_graph_.is_valid() && hpa_graph_->is_built()) {
		// Find the original radius/length for this obstacle
		auto oit = obstacles.find(id);
		if (oit != obstacles.end()) {
			const DynamicObstacle &obs = oit->second;
			float effective_radius = std::max(obs.radius, obs.length * 0.5f) + params.ship_beam;
			hpa_graph_->add_obstacle(id, position, effective_radius);
		}
	}
}

void ShipNavigator::remove_obstacle(int id) {
	obstacles.erase(id);
	if (hpa_graph_.is_valid() && hpa_graph_->is_built()) {
		hpa_graph_->remove_obstacle(id);
	}
}

void ShipNavigator::clear_obstacles() {
	obstacles.clear();
	if (hpa_graph_.is_valid() && hpa_graph_->is_built()) {
		hpa_graph_->clear_obstacles();
	}
}

void ShipNavigator::clear_incoming_shells() {
	incoming_shells_.clear();
}

void ShipNavigator::add_incoming_shell(int id, Vector2 landing_pos, float time_remaining, float caliber, Vector2 landing_dir, float threat_half_len) {
	incoming_shells_.emplace_back(id, landing_pos, time_remaining, caliber, landing_dir, threat_half_len);
}

void ShipNavigator::set_threat_source(Ref<ThreatRegistry> registry, int team_id, float effective_radius) {
	ThreatBin* new_bin = nullptr;
	if (registry.is_valid()) {
		new_bin = registry->acquire_bin(team_id, effective_radius);
	}
	if (new_bin == threat_bin_) {
		// Already pointing at this exact bin — drop the duplicate ref we
		// just acquired and bail.
		if (registry.is_valid() && new_bin) {
			registry->release_bin(new_bin);
		}
		return;
	}
	if (threat_bin_ && threat_registry_.is_valid()) {
		threat_registry_->release_bin(threat_bin_);
	}
	threat_registry_ = registry;
	threat_bin_ = new_bin;
	threat_last_version_ = 0; // force refresh next push
}

void ShipNavigator::clear_threat_source() {
	if (threat_bin_ && threat_registry_.is_valid()) {
		threat_registry_->release_bin(threat_bin_);
	}
	threat_bin_ = nullptr;
	threat_registry_.unref();
	threat_last_version_ = 0;
	// Clear the HPA* cluster-level threat layer immediately so paths are
	// no longer routed around the now-removed detection zones.
	if (hpa_graph_.is_valid() && hpa_graph_->is_built()) {
		hpa_graph_->clear_threats();
	}
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

bool ShipNavigator::is_arrived() const {
	const float dist_to_dest = state.position.distance_to(target.position);
	const float arrived_radius = std::max(target.hold_radius, params.ship_beam * 2.0f);
	return dist_to_dest < arrived_radius;
}

// ============================================================================
// Backward-compatible API stub
// ============================================================================

PackedVector3Array ShipNavigator::get_simulated_path() const {
	return get_predicted_trajectory();
}

Array ShipNavigator::get_debug_torpedo_threat_points() const {
	Array result;

	for (const auto &[id, obs] : obstacles) {
		if (!obs.is_torpedo()) continue;

		float torp_speed = obs.velocity.length();
		if (torp_speed < 1.0f) continue;

		Vector2 torp_dir = obs.velocity / torp_speed;

		// Line emitted from torpedo nose, extending TORPEDO_LOOKAHEAD_DIST ahead
		Vector2 line_start = obs.position;
		Vector2 line_end   = obs.position + torp_dir * TORPEDO_LOOKAHEAD_DIST;
		Vector2 line_center = obs.position + torp_dir * (TORPEDO_LOOKAHEAD_DIST * 0.5f);

		// Time until torpedo reaches closest point to ship
		Vector2 to_ship = state.position - obs.position;
		float t_closest = to_ship.dot(torp_dir) / torp_speed;
		if (t_closest < 0.0f) t_closest = 0.0f;

		Dictionary d;
		d["landing_x"] = line_center.x;
		d["landing_z"] = line_center.y;
		d["time_remaining"] = t_closest;
		d["caliber"] = TORPEDO_VIRTUAL_CALIBER;
		d["line_start_x"] = line_start.x;
		d["line_start_z"] = line_start.y;
		d["line_end_x"] = line_end.x;
		d["line_end_z"] = line_end.y;
		d["line_dir_x"] = torp_dir.x;
		d["line_dir_z"] = torp_dir.y;
		d["line_half_len"] = TORPEDO_LOOKAHEAD_DIST * 0.5f;
		d["is_torpedo"] = true;
		result.push_back(d);
	}

	return result;
}

TypedArray<Dictionary> ShipNavigator::get_debug_threat_clusters() const {
	if (!hpa_graph_.is_valid() || !hpa_graph_->is_built()) return TypedArray<Dictionary>();
	// Use the pure-query path so we always see THIS navigator's threat bin,
	// not whatever ship last stamped the shared cluster_threat_blocked_ array.
	if (!threat_bin_ || threat_bin_->threats.empty()) return TypedArray<Dictionary>();
	return hpa_graph_->compute_debug_threat_clusters(threat_bin_->threats);
}

Dictionary ShipNavigator::adjust_destination_for_threats(Vector2 ship_pos, Vector2 dest) const {
	Dictionary out;
	out["position"] = dest;
	out["adjusted"] = false;
	if (!threat_bin_ || threat_bin_->threats.empty()) return out;
	if (!map.is_valid() || !map->is_built()) return out;

	Vector2 adjusted = dest;
	bool changed = false;

	// Iterative push: run up to 4 passes so a destination surrounded by
	// multiple overlapping threat circles eventually escapes.
	for (int pass = 0; pass < 4; ++pass) {
		bool pushed = false;
		for (const auto &t : threat_bin_->threats) {
			if (t.radius <= 0.0f) continue;
			float dx = adjusted.x - t.origin.x;
			float dz = adjusted.y - t.origin.y;
			float dist_sq = dx * dx + dz * dz;
			if (dist_sq >= t.radius * t.radius) continue;
			// If terrain blocks LOS to this threat, the position is already hidden.
			RayResult ray = map->raycast_internal(adjusted, t.origin, 0.0f);
			if (ray.hit) continue;
			// Push the destination to just outside this threat circle.
			float dist = std::sqrt(dist_sq);
			float nx = (dist > 0.001f) ? dx / dist : 1.0f;
			float nz = (dist > 0.001f) ? dz / dist : 0.0f;
			adjusted = Vector2(t.origin.x + nx * (t.radius + 100.0f),
			                   t.origin.y + nz * (t.radius + 100.0f));
			changed = true;
			pushed = true;
		}
		if (!pushed) break;  // stable — no further passes needed
	}

	if (changed) {
		out["position"] = adjusted;
		out["adjusted"] = true;
	}
	(void)ship_pos;
	return out;
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
	return params.turning_circle_radius * 1.5f;
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
	// --- 0. Tick commitment timers ---
	if (dodge_commitment_timer_ > 0.0f) {
		dodge_commitment_timer_ -= delta;
		if (dodge_commitment_timer_ <= 0.0f) {
			dodge_commitment_timer_ = 0.0f;
			dodge_committed_rudder_ = 0.0f;
		}
	}

	// --- 1. HPA* path planning ---
	auto plan_t0 = std::chrono::steady_clock::now();

	timing_replan_reason = 0;

	if (replan_requested_ || !path_valid) {
		// Full replan — goal changed, first frame, or no valid path yet
		timing_replan_reason = 1;
		start_plan();
		replan_requested_ = false;
	}

	if (plan_phase == PlanPhase::DONE) {
		// HPA* always completes synchronously — accept immediately
		accept_plan_result(plan_forward_result);
		plan_phase = PlanPhase::IDLE;
	} else if (plan_phase == PlanPhase::IDLE && path_valid) {
		// Incremental update: re-stamp threats and replan when version changes
		hpa_incremental_update();
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
	// Always extends at least one TCR beyond arrived_radius so the intermediate
	// moderate-speed zone exists even when hold_radius is large.
	float maneuver_radius = arrived_radius + std::max(params.turning_circle_radius, get_stopping_distance());

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
			align_commit_active_ = false;

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
				// Inside arrived zone but heading not aligned — scale throttle to
				// heading error so the rudder has enough authority to turn quickly.
				// Large misalignment demands more speed; near-aligned ships creep.
				if (heading_error > static_cast<float>(Math_PI / 4.0))
					desired_magnitude = 3;  // >45°: aggressive turn
				else if (heading_error > static_cast<float>(Math_PI / 8.0))
					desired_magnitude = 2;  // >22.5°: moderate turn
				else
					desired_magnitude = 1;  // close to aligned: creep

				// Option A: pick the direction that gives full rudder authority for
				// the needed heading correction, ignoring dest_along.  At tiny
				// distances dest_along is noise and flipping it inverts the rudder,
				// cancelling the turn every frame.
				float rudder_fwd = compute_rudder_to_heading(target.heading, false);
				float rudder_rev = compute_rudder_to_heading(target.heading, true);
				DesiredDirection best_dir =
					(std::abs(rudder_fwd) >= std::abs(rudder_rev))
					? DesiredDirection::FORWARD
					: DesiredDirection::BACKWARD;

				// Option B: commit to that direction until the ship has traveled
				// one bounce radius from where the direction was chosen.  Each
				// stroke of the multi-point turn completes naturally before the
				// direction is reconsidered; sizing to ship_beam gives a distance
				// that scales with the vessel.
				float bounce_radius = std::max(params.turning_circle_radius, ALIGN_BOUNCE_RADIUS_DEFAULT);
				if (!align_commit_active_
				    || state.position.distance_to(align_commit_pos_) >= bounce_radius) {
					align_committed_dir_ = best_dir;
					align_commit_pos_ = state.position;
					align_commit_active_ = true;
				}
				direction = align_committed_dir_;
			} else {
				// Drifted within maneuver zone — head back toward destination
				// at moderate speed while turning.  dest_along is reliable here
				// (ship is meaningfully displaced from the destination).
				desired_magnitude = 2;
				direction = dest_ahead ? DesiredDirection::FORWARD : DesiredDirection::BACKWARD;
				align_commit_active_ = false;  // reset alignment commit when outside arrived zone
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

	// --- 3.5. Heading weight: blend desired_rudder toward target heading ---
	// When heading_weight > 0 the behavior wants the ship to orient at a specific
	// angle (e.g. broadside) rather than simply navigate to the destination.
	// Blending desired_rudder here shifts the candidate distribution in
	// select_best_steering so arcs centered on the heading-pursuit rudder are
	// evaluated first.  At weight = 1 we also ensure the ship keeps enough
	// throttle to maintain steerage way.
	if (target.heading_weight > 0.001f) {
		bool reversing_now = (direction == DesiredDirection::BACKWARD);
		float heading_rudder = compute_rudder_to_heading(target.heading, reversing_now);
		desired_rudder = lerp_f(desired_rudder, heading_rudder, target.heading_weight);
		if (target.heading_weight >= 0.999f) {
			// Full heading pursuit — keep ship moving so the rudder has authority.
			if (desired_magnitude < 2) {
				desired_magnitude = 2;
				direction = DesiredDirection::FORWARD;
			}
			desired_throttle = resolve_throttle(direction, desired_magnitude);
		}
	}

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

	// --- 4.5. Rudder-discrepancy throttle reduction ---
	// When the desired rudder is far from the current physical rudder position,
	// the ship will travel straight (at the old rudder) until the rudder catches
	// up, causing wide overshooting turns.  Reduce throttle proportionally to
	// the rudder discrepancy so the ship slows while the rudder moves into
	// position, giving tighter and more controlled turns.
	// Skip when: reversing or already slow.
	if (final_throttle > 1) {
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
// Plan management
// ============================================================================

// ============================================================================
// start_plan — runs HPA* planning for the current goal
// ============================================================================

void ShipNavigator::start_plan() {
	plan_min_clearance = get_ship_clearance();
	plan_comfortable_clearance = std::min(
		plan_min_clearance + params.ship_beam * 0.5f,
		plan_min_clearance * 2.0f);

	// -----------------------------------------------------------------------
	// HPA* path (primary): threat-aware hierarchical A*.
	// The abstract search runs in microseconds so planning always completes
	// synchronously — no COMPUTING phase is needed.
	//
	// Important: apply this navigator's threat layer immediately before each
	// HPA* query.  HpaGraph is shared by many ships; another ship may have
	// stamped a different threat set (or cleared threats) earlier in the frame.
	// -----------------------------------------------------------------------
	if (hpa_graph_.is_valid() && hpa_graph_->is_built() &&
		map.is_valid() && map->is_built()) {

		if (threat_bin_) {
			hpa_graph_->stamp_threats(threat_bin_->threats);
			threat_last_version_ = threat_bin_->version;
		} else {
			hpa_graph_->clear_threats();
		}

		PathResult pr = hpa_graph_->find_path(state.position, target.position);
		if (pr.valid && !pr.waypoints.empty()) {
			plan_forward_result = pr;
			plan_phase = PlanPhase::DONE;
			return;
		}
		// HPA* failed (e.g. isolated cluster) — fall through to straight-line
	}

	// -----------------------------------------------------------------------
	// Straight-line fallback: only when no active threat subscription and
	// terrain is clear.  When threat_bin_ is set, always let HPA* route so
	// that stealth ships never short-circuit around threat-arc avoidance.
	// -----------------------------------------------------------------------
	if (!threat_bin_ && map.is_valid() && map->is_built()) {
		RayResult los = map->raycast_internal(state.position, target.position, plan_min_clearance);
		if (!los.hit) {
			PathResult direct;
			direct.waypoints.push_back(state.position);
			direct.waypoints.push_back(target.position);
			direct.flags.push_back(WP_NONE);
			direct.flags.push_back(WP_NONE);
			direct.valid = true;
			direct.total_distance = state.position.distance_to(target.position);
			plan_forward_result = direct;
			plan_phase = PlanPhase::DONE;
			return;
		}
	}

	// -----------------------------------------------------------------------
	// Last resort: step along the straight line and stop just before the
	// first terrain / threat obstacle so the ship doesn't drive blindly
	// through land or a detection zone.
	// -----------------------------------------------------------------------
	{
		Vector2 dir = target.position - state.position;
		float total = dir.length();

		PathResult direct;
		direct.waypoints.push_back(state.position);

		if (total > plan_min_clearance && map.is_valid() && map->is_built()) {
			Vector2 dir_n = dir / total;
			float step = std::max(plan_min_clearance, 50.0f);
			float best_dist = 0.0f;
			for (float d = step; ; d += step) {
				float test_d = std::min(d, total);
				Vector2 test = state.position + dir_n * test_d;
				if (map->get_distance(test.x, test.y) < plan_min_clearance) break;
				if (threat_bin_) {
					bool in_threat = false;
					for (const auto &t : threat_bin_->threats) {
						float dx = test.x - t.origin.x, dz = test.y - t.origin.y;
						if (dx*dx + dz*dz < t.radius*t.radius) { in_threat = true; break; }
					}
					if (in_threat) break;
				}
				best_dist = test_d;
				if (test_d >= total) break;
			}
			if (best_dist > plan_min_clearance)
				direct.waypoints.push_back(state.position + dir_n * best_dist);
		}

		if (direct.waypoints.size() < 2)
			direct.waypoints.push_back(state.position);  // stuck — stay put

		direct.flags.assign(direct.waypoints.size(), WP_NONE);
		direct.valid = true;
		direct.total_distance = 0.0f;
		for (size_t i = 0; i + 1 < direct.waypoints.size(); ++i)
			direct.total_distance += direct.waypoints[i].distance_to(direct.waypoints[i + 1]);
		plan_forward_result = direct;
		plan_phase = PlanPhase::DONE;
	}
}

void ShipNavigator::tick_plan() {
	// D* Lite removed — HPA* planning is always synchronous via start_plan().
}

void ShipNavigator::run_plan_sync() {
	plan_min_clearance = get_ship_clearance();
	plan_comfortable_clearance = std::min(
		plan_min_clearance + params.ship_beam * 0.5f,
		plan_min_clearance * 2.0f);

	// -----------------------------------------------------------------------
	// HPA* path (primary)
	// -----------------------------------------------------------------------
	if (hpa_graph_.is_valid() && hpa_graph_->is_built() &&
		map.is_valid() && map->is_built()) {

		if (threat_bin_) {
			hpa_graph_->stamp_threats(threat_bin_->threats);
			threat_last_version_ = threat_bin_->version;
		} else {
			hpa_graph_->clear_threats();
		}

		PathResult pr = hpa_graph_->find_path(state.position, target.position);
		if (pr.valid && !pr.waypoints.empty()) {
			accept_plan_result(pr);
			plan_phase = PlanPhase::IDLE;
			return;
		}
	}

	// -----------------------------------------------------------------------
	// Straight-line fallback (terrain-only, no threats)
	// -----------------------------------------------------------------------
	if (!threat_bin_ && map.is_valid() && map->is_built()) {
		RayResult los = map->raycast_internal(state.position, target.position, plan_min_clearance);
		if (!los.hit) {
			PathResult direct;
			direct.waypoints.push_back(state.position);
			direct.waypoints.push_back(target.position);
			direct.flags.push_back(WP_NONE);
			direct.flags.push_back(WP_NONE);
			direct.valid = true;
			direct.total_distance = state.position.distance_to(target.position);
			accept_plan_result(direct);
			plan_phase = PlanPhase::IDLE;
			return;
		}
	}

	// -----------------------------------------------------------------------
	// Last resort: stop short of terrain/threats along the straight line
	// -----------------------------------------------------------------------
	{
		Vector2 dir = target.position - state.position;
		float total = dir.length();

		PathResult direct;
		direct.waypoints.push_back(state.position);

		if (total > plan_min_clearance && map.is_valid() && map->is_built()) {
			Vector2 dir_n = dir / total;
			float step = std::max(plan_min_clearance, 50.0f);
			float best_dist = 0.0f;
			for (float d = step; ; d += step) {
				float test_d = std::min(d, total);
				Vector2 test = state.position + dir_n * test_d;
				if (map->get_distance(test.x, test.y) < plan_min_clearance) break;
				if (threat_bin_) {
					bool in_threat = false;
					for (const auto &t : threat_bin_->threats) {
						float dx = test.x - t.origin.x, dz = test.y - t.origin.y;
						if (dx*dx + dz*dz < t.radius*t.radius) { in_threat = true; break; }
					}
					if (in_threat) break;
				}
				best_dist = test_d;
				if (test_d >= total) break;
			}
			if (best_dist > plan_min_clearance)
				direct.waypoints.push_back(state.position + dir_n * best_dist);
		}

		if (direct.waypoints.size() < 2)
			direct.waypoints.push_back(state.position);

		direct.flags.assign(direct.waypoints.size(), WP_NONE);
		direct.valid = true;
		direct.total_distance = 0.0f;
		for (size_t i = 0; i + 1 < direct.waypoints.size(); ++i)
			direct.total_distance += direct.waypoints[i].distance_to(direct.waypoints[i + 1]);
		accept_plan_result(direct);
		plan_phase = PlanPhase::IDLE;
	}
}

// ============================================================================
// HPA* incremental repair — runs every frame when path is active
// ============================================================================

void ShipNavigator::hpa_incremental_update() {
	if (!hpa_graph_.is_valid() || !hpa_graph_->is_built()) return;

	// If our bin version changed, schedule an immediate replan.
	if (threat_bin_) {
		uint64_t live_version = threat_bin_->version;
		if (live_version != threat_last_version_) {
			threat_last_version_ = live_version;
			replan_requested_ = true;
		}
	}

	// Re-plan with HPA* when stale or explicitly requested.
	if (replan_requested_ || !path_valid) {
		// Apply this navigator's threat layer right before query time.
		if (threat_bin_) {
			hpa_graph_->stamp_threats(threat_bin_->threats);
			threat_last_version_ = threat_bin_->version;
		} else {
			hpa_graph_->clear_threats();
		}

		PathResult pr = hpa_graph_->find_path(state.position, target.position);
		if (pr.valid && !pr.waypoints.empty()) {
			accept_plan_result(pr);
		}
		replan_requested_ = false;
	}
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

// =============================================================================
// Shell threat scoring — evaluates a candidate arc against all threat lines
// =============================================================================



float ShipNavigator::get_dynamic_threat_weight() const {
	// Ship size factor: smaller ships dodge more aggressively
	// 100m (DD) → size_factor = 1.0, 250m (BB) → size_factor = 0.3
	float size_t = clamp_f((params.ship_length - 100.0f) / 150.0f, 0.0f, 1.0f);
	float size_factor = 1.0f - 0.7f * size_t;  // lerp(1.0, 0.3, size_t)

	// Health factor: lower HP → dodge harder
	// health 1.0 → 1.0, health 0.0 → 2.5
	float health_factor = 2.5f - 1.5f * health_fraction_;  // lerp(2.5, 1.0, health)

	return SHELL_THREAT_WEIGHT_BASE * size_factor * health_factor;
}

float ShipNavigator::score_arc_shell_threat(const std::vector<ArcPoint> &arc) const {
	if (arc.size() < 2) return 0.0f;

	// Collect all threat lines: each has a center, direction, half-length,
	// time of relevance, caliber, and whether it is a torpedo.
	struct ThreatLine {
		Vector2 center;
		Vector2 dir;        // normalized direction
		float half_len;
		float time;         // time_remaining (when it matters)
		float caliber;
		bool is_torpedo;
	};

	std::vector<ThreatLine> threat_lines;
	threat_lines.reserve(incoming_shells_.size() + obstacles.size());

	// --- Shell threat lines ---
	// The landing point is near the TIP of the line. The danger zone trails
	// backward along the shell's travel direction (toward its origin) and
	// extends SHELL_OVERSHOOT_LEN past the impact point.
	for (const auto &shell : incoming_shells_) {
		if (shell.time_remaining <= 0.0f) continue;
		float total_half = shell.threat_half_len + SHELL_OVERSHOOT_LEN * 0.5f;
		ThreatLine tl;
		tl.center = shell.landing_pos - shell.landing_dir * (shell.threat_half_len - SHELL_OVERSHOOT_LEN * 0.5f);
		tl.dir = shell.landing_dir;
		tl.half_len = total_half;
		tl.time = shell.time_remaining;
		tl.caliber = shell.caliber;
		tl.is_torpedo = false;
		threat_lines.push_back(tl);
	}

	// --- Torpedo threat lines (single line per torpedo, not sampled points) ---
	for (const auto &[id, obs] : obstacles) {
		if (!obs.is_torpedo()) continue;

		float torp_speed = obs.velocity.length();
		if (torp_speed < 1.0f) continue;

		Vector2 torp_dir = obs.velocity / torp_speed;

		// Project ship onto torpedo path to find closest approach time
		Vector2 to_ship = state.position - obs.position;
		float t_closest = to_ship.dot(torp_dir) / torp_speed;
		if (t_closest < 0.0f) t_closest = 0.0f;

		ThreatLine tl;
		tl.center = obs.position + torp_dir * (TORPEDO_LOOKAHEAD_DIST * 0.5f);
		tl.dir = torp_dir;
		tl.half_len = TORPEDO_LOOKAHEAD_DIST * 0.5f;
		tl.time = t_closest;
		tl.caliber = TORPEDO_VIRTUAL_CALIBER;
		tl.is_torpedo = true;
		threat_lines.push_back(tl);
	}

	if (threat_lines.empty()) return 0.0f;

	// Ship half-extents for OBB intersection test
	const float hsl = params.ship_length * 0.5f;   // half-length (bow/stern)
	const float hsb = params.ship_beam   * 0.5f;   // half-beam  (port/starboard)

	float total_threat = 0.0f;

	for (const auto &tl : threat_lines) {
		const float cal_weight = (tl.caliber * tl.caliber) / (200.0f * 200.0f);

		// Time window: check arc points from (impact - window) to (impact + window)
		const float t_lo = std::max(0.0f, tl.time - DODGE_THREAT_WINDOW);
		const float t_hi = tl.time + DODGE_THREAT_WINDOW;

		float worst_penalty = 0.0f;
		bool found_window_point = false;

		// Lambda: test the threat line segment against the ship OBB at a given arc point
		// and update worst_penalty if a hit is confirmed.
		auto score_at_point = [&](const ArcPoint &apt) {
			// Ship local axes from heading (forward = (sin h, cos h), starboard = (cos h, -sin h))
			const float fx = std::sin(apt.heading);
			const float fz = std::cos(apt.heading);

			// Threat segment endpoints relative to ship center, projected into ship local frame.
			// Local X = forward (keel), Local Y = starboard.
			const Vector2 rel_a = tl.center - tl.dir * tl.half_len - apt.position;
			const Vector2 rel_b = tl.center + tl.dir * tl.half_len - apt.position;

			const float a_fwd  = rel_a.x * fx + rel_a.y * fz;
			const float a_stbd = rel_a.x * fz - rel_a.y * fx;
			const float b_fwd  = rel_b.x * fx + rel_b.y * fz;
			const float b_stbd = rel_b.x * fz - rel_b.y * fx;

			const float d_fwd  = b_fwd  - a_fwd;
			const float d_stbd = b_stbd - a_stbd;

			// Liang-Barsky clip of segment against AABB [-hsl, hsl] x [-hsb, hsb].
			// For each boundary: p is the "rate of change toward boundary", q is the
			// "signed distance from start to boundary". p<0 → entering (update t0),
			// p>0 → leaving (update t1), p≈0 → parallel (reject if outside).
			float t0 = 0.0f, t1 = 1.0f;
			const float p[4] = { -d_fwd,  d_fwd,  -d_stbd,  d_stbd  };
			const float q[4] = {  a_fwd + hsl,  hsl - a_fwd,  a_stbd + hsb,  hsb - a_stbd };

			for (int k = 0; k < 4; k++) {
				if (std::abs(p[k]) < 1e-6f) {
					if (q[k] < 0.0f) return;   // parallel and outside this boundary → no hit
				} else {
					const float t = q[k] / p[k];
					if (p[k] < 0.0f) t0 = std::max(t0, t);
					else             t1 = std::min(t1, t);
				}
				if (t0 > t1) return;            // clipped out → no hit
			}

			// --- OBB intersection confirmed: compute penalty factor ---
			float penalty_factor = 1.0f;

			if (!tl.is_torpedo) {
				// (a) Angle modifier: smooth gradient across the full approach angle.
				//     cos_keel = 1 → end-on (grazing), 0 → broadside (worst).
				//     sin_keel = 0 → end-on, 1 → broadside.
				//     penalty scales linearly from GRAZE_MIN_FACTOR at end-on to 1.0
				//     at broadside, giving a continuous reward for angling the ship.
				const float cos_keel = std::abs(tl.dir.x * fx + tl.dir.y * fz);
				const float sin_keel = std::sqrt(std::max(0.0f, 1.0f - cos_keel * cos_keel));
				penalty_factor *= GRAZE_MIN_FACTOR + (1.0f - GRAZE_MIN_FACTOR) * sin_keel;

				// (b) Bow/stern clip modifier: if the intersection midpoint along the keel
				//     is in the outermost portion of the hull, reduce the penalty.
				const float hit_mid_fwd = a_fwd + (t0 + t1) * 0.5f * d_fwd;
				const float fwd_frac = std::abs(hit_mid_fwd) / hsl;
				if (fwd_frac > BOW_STERN_CLIP_START) {
					const float ct = std::min((fwd_frac - BOW_STERN_CLIP_START) / (1.0f - BOW_STERN_CLIP_START), 1.0f);
					penalty_factor *= 1.0f - ct * (1.0f - BOW_STERN_MIN_FACTOR);
				}
			}

			const float penalty = cal_weight * penalty_factor;
			if (penalty > worst_penalty) worst_penalty = penalty;
		};

		// Check all arc points within the time window
		for (size_t i = 0; i < arc.size(); i++) {
			if (arc[i].time < t_lo) continue;
			if (arc[i].time > t_hi) break;
			found_window_point = true;
			score_at_point(arc[i]);
		}

		// Fallback: if no arc point fell within the window (arc too short to reach
		// impact time), use the arc point nearest to the impact time.
		if (!found_window_point) {
			const ArcPoint *nearest = &arc.back();
			float best_dt = std::abs(arc.back().time - tl.time);
			for (size_t i = 0; i + 1 < arc.size(); i++) {
				float dt = std::abs(arc[i].time - tl.time);
				if (dt < best_dt) { best_dt = dt; nearest = &arc[i]; }
			}
			score_at_point(*nearest);
		}

		total_threat += worst_penalty;
	}

	return total_threat;
}

ShipNavigator::SteeringChoice ShipNavigator::select_best_steering(float desired_rudder, int desired_throttle) {
	SteeringChoice result = { desired_rudder, desired_throttle, false };

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
		if (sdf_here > lookahead + soft_clearance) {
			terrain_safe = true;
		}
	}

	bool obstacles_safe = true;
	float engagement_range = lookahead + params.max_speed * 10.0f;
	for (const auto &[id, obs] : obstacles) {
		if (skip_ship_obstacles_ && !obs.is_torpedo()) continue;
		float dist = state.position.distance_to(obs.position);
		if (dist < engagement_range) {
			obstacles_safe = false;
			break;
		}
	}

	bool shells_safe = incoming_shells_.empty();

	if (terrain_safe && obstacles_safe && shells_safe) {
		// Cache a debug arc for visualization even on the fast path.
		float fast_path_lookahead = params.turning_circle_radius * 1.5f;
		winning_arc = predict_arc_internal(desired_rudder, desired_throttle, fast_path_lookahead);
		return result;
	}



	// --- Determine waypoint target for alignment scoring ---
	Vector2 wp_target = target.position;
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		wp_target = current_path.waypoints[current_wp_index];
	}
	float wp_reach_radius = get_reach_radius();

	// When at/near destination (path exhausted or already within reach radius),
	// predict_arc_to_heading would target a point essentially underfoot, causing
	// dist_to_target < 1 and skipping the alignment check entirely.  Replace
	// wp_target with a virtual point far along the desired heading so candidates
	// are correctly scored for final bearing alignment.
	bool wp_is_virtual = false;
	{
		bool path_exhausted_here = !path_valid || current_wp_index >= static_cast<int>(current_path.waypoints.size());
		float dist_to_wp = state.position.distance_to(wp_target);
		if (path_exhausted_here || dist_to_wp < wp_reach_radius) {
			float th = target.heading;
			wp_target = state.position + Vector2(std::sin(th), std::cos(th)) * 10000.0f;
			wp_is_virtual = true;
		}
	}

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

	// +1 for full opposite rudder, +5 for reverse candidates (0, ±0.5, ±1.0)
	Candidate candidates[N_OFFSETS + 6];
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

	// Reverse candidates — full rudder spread so the ship can maneuver
	// while backing up.  Reverse is naturally penalised by slower speed
	// producing longer alignment + travel times.
	add_candidate(0.0f, -1);
	add_candidate(-0.5f, -1);
	add_candidate(0.5f, -1);
	add_candidate(-1.0f, -1);
	add_candidate(1.0f, -1);

	// --- Simulation parameters ---
	// Simulate long enough for the ship to complete a full turning circle
	// (the go-around case) plus some margin.
	float turn_circumference = 2.0f * Math_PI * params.turning_circle_radius;
	float sim_lookahead = std::max(turn_circumference, lookahead * 2.0f);
	float sim_max_time = 120.0f;

	// --- Score each candidate: alignment_time + travel_time (lowest wins) ---
	float dynamic_threat_weight = get_dynamic_threat_weight();
	float best_time = std::numeric_limits<float>::infinity();
	float best_rudder = desired_rudder;
	int best_throttle = desired_throttle;
	bool any_collision = false;

	// Heading-weight mode: pre-compute a virtual waypoint 10 km along target.heading.
	// Each arc is scored by how quickly it aligns with this heading; the result is
	// blended with the normal destination-arrival score proportionally to heading_weight.
	bool has_heading_weight = (target.heading_weight > 0.001f);
	Vector2 heading_vp;
	if (has_heading_weight) {
		float th = target.heading;
		heading_vp = state.position + Vector2(std::sin(th), std::cos(th)) * 10000.0f;
	}

	// --- Exit-heading: precompute remaining path context for (b.75) ---
	// Score each candidate by its total cost to destination:
	//   time_to_wp_target  +  turn_time_to_align_with_next_segment
	// The remaining travel from wp_target onward is identical for all candidates
	// and cancels out, so only the arrival-heading mismatch at wp_target matters.
	// wp_is_virtual already handles "destination underfoot" by suppressing the penalty.
	Vector2 next_goal_after_wp = target.position;  // first goal after wp_target
	float desired_exit_heading  = 0.0f;            // heading from wp_target → next_goal
	bool  apply_exit_penalty    = false;
	if (!wp_is_virtual && path_valid) {
		int next_idx = current_wp_index + 1;
		if (next_idx < static_cast<int>(current_path.waypoints.size())) {
			next_goal_after_wp = current_path.waypoints[next_idx];
		}
		Vector2 to_next    = next_goal_after_wp - wp_target;
		float   to_next_len = to_next.length();
		if (to_next_len > 1.0f) {
			desired_exit_heading = std::atan2(to_next.x, to_next.y);
			apply_exit_penalty   = true;
		}
	}




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
		// When wp_target is the virtual heading alignment point, also stop at
		// heading alignment: the ship re-evaluates steering there, so terrain
		// beyond the alignment point is irrelevant (critical for multi-point turns
		// near terrain — the reversing arc aligns before it would reach any shore).
		bool terrain_blocked = false;
		float arrival_time = -1.0f;  // time at which arc reaches the waypoint
		constexpr float heading_align_thresh = 0.087f;  // ~5°, matches predict_arc_to_heading
		if (map.is_valid() && map->is_built()) {
			for (const auto &pt : arc) {
				if (wp_is_virtual) {
					Vector2 to_vp = wp_target - pt.position;
					if (to_vp.length() > 1.0f) {
						float desired_h = std::atan2(to_vp.x, to_vp.y);
						if (std::abs(angle_difference(pt.heading, desired_h)) < heading_align_thresh) {
							arrival_time = pt.time;
							break;
						}
					}
				}
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

			// When a reverse candidate ends with the bow aligned toward the
			// waypoint, the ship will switch to forward throttle on the next
			// frame.  Score the remaining travel using forward speed instead
			// of the slow reverse speed.  This prevents oscillation: without
			// this, reverse candidates are over-penalised by the slow reverse
			// speed, so the ship reverses just far enough to unblock a forward
			// path, drives forward into the shore again, and repeats.
			float endpoint_speed;
			if (cand_throttle < 0) {
				// Bow is aligned with the waypoint — estimate travel at
				// the forward speed the ship will use after switching.
				// Use a moderate forward throttle (magnitude 3) as a
				// reasonable estimate of the speed the navigator will
				// command once it resumes forward travel.
				endpoint_speed = throttle_to_speed(3);
			} else {
				endpoint_speed = std::abs(arc.back().speed);
			}
			if (endpoint_speed < 1.0f) endpoint_speed = 1.0f;
			float travel_time = endpoint_dist / endpoint_speed;
			total_time = alignment_time + travel_time;

			// Penalise residual heading error so arcs that nearly align beat
			// arcs that don't turn at all — matters most when all candidates
			// exhaust max_time without achieving alignment.
			if (wp_is_virtual) {
				Vector2 to_vp = wp_target - arc.back().position;
				if (to_vp.length() > 1.0f) {
					float desired_h = std::atan2(to_vp.x, to_vp.y);
					float final_h_err = std::abs(angle_difference(arc.back().heading, desired_h));
					total_time += (final_h_err / Math_PI) * 60.0f;
				}
			}
		}

		// --- (b.5) Heading-weight blend ---
		// When heading_weight > 0, score this arc by how quickly it aligns with
		// target.heading and blend that score into total_time.  Terrain/obstacle
		// penalties are applied AFTER the blend so they remain equally repulsive
		// regardless of the navigation mode.
		if (has_heading_weight) {
			constexpr float ha_thresh = 0.087f;  // ~5° — mirrors heading_align_thresh above
			float heading_align_time = std::numeric_limits<float>::infinity();
			for (const auto &hpt : arc) {
				Vector2 to_hvp = heading_vp - hpt.position;
				if (to_hvp.length() > 1.0f) {
					float desired_h = std::atan2(to_hvp.x, to_hvp.y);
					if (std::abs(angle_difference(hpt.heading, desired_h)) < ha_thresh) {
						heading_align_time = hpt.time;
						break;
					}
				}
			}
			if (heading_align_time == std::numeric_limits<float>::infinity()) {
				// Heading not achieved within arc — penalise by residual heading error.
				Vector2 to_hvp = heading_vp - arc.back().position;
				if (to_hvp.length() > 1.0f) {
					float desired_h = std::atan2(to_hvp.x, to_hvp.y);
					float h_err = std::abs(angle_difference(arc.back().heading, desired_h));
					heading_align_time = arc.back().time + (h_err / Math_PI) * 60.0f;
				} else {
					heading_align_time = arc.back().time;
				}
			}
			total_time = lerp_f(total_time, heading_align_time, target.heading_weight);
		}

		// --- (b.75) Exit-heading penalty: remaining full-path cost ---
		// Estimate the heading at which the ship will arrive at wp_target.
		//
		// Two cases:
		//   arrival_time >= 0  — an arc point physically reached wp_target.  Use the
		//                        *travel direction* of that point: bow heading for forward
		//                        candidates, -bow (stern direction) for reverse candidates.
		//                        Do NOT use arc.back(): the arc may have continued past
		//                        wp_target hunting for bow-alignment on the other side,
		//                        giving a spurious 180° heading error for a valid forward arc.
		//   arrival_time < 0   — arc terminated at the bow-alignment point.  The ship then
		//                        drives forward from that point to wp_target, so arrival
		//                        heading == direction from alignment endpoint to wp_target.
		//
		// The penalty is scaled by remaining path distance so it vanishes when the
		// destination is close: reversing to a nearby final waypoint is fine and should
		// still win, but reversing past an intermediate waypoint on a long journey is
		// correctly penalised.
		if (apply_exit_penalty) {
			float arrival_h;
			if (arrival_time >= 0.0f) {
				// Find the first arc point within wp_reach_radius of wp_target.
				float h_at_wp = arc.back().heading;  // fallback
				for (const auto &pt : arc) {
					if (pt.position.distance_to(wp_target) < wp_reach_radius) {
						h_at_wp = pt.heading;
						break;
					}
				}
				if (cand_throttle < 0) {
					// Reversing: travel direction is the stern direction = bow + 180°.
					arrival_h = normalize_angle(h_at_wp + static_cast<float>(Math_PI));
				} else {
					// Forward: travel direction equals bow heading.
					arrival_h = h_at_wp;
				}
			} else {
				// Arc stopped at bow-alignment point; ship then drives forward to wp_target.
				// Arrival heading = direction from arc endpoint to wp_target.
				Vector2 d_wp     = wp_target - arc.back().position;
				float   d_wp_len = d_wp.length();
				arrival_h = (d_wp_len > 1.0f)
				          ? std::atan2(d_wp.x, d_wp.y)
				          : arc.back().heading;
			}
			float exit_err = std::abs(angle_difference(arrival_h, desired_exit_heading));
			// Pure turn-time cost: how long does it take to rotate by exit_err
			// at the ship's turning rate?  Half-turning-circle time == 180° rotation.
			// No scaling: the remaining path distance is constant across all candidates
			// so it doesn't affect ordering.  wp_is_virtual already handles the
			// "destination is close" case by setting apply_exit_penalty = false.
			float fwd_speed = throttle_to_speed(4);
			if (fwd_speed < 1.0f) fwd_speed = 1.0f;
			float half_tc_time = (static_cast<float>(Math_PI) * params.turning_circle_radius) / fwd_speed;
			total_time += (exit_err / static_cast<float>(Math_PI)) * half_tc_time;
		}

		// --- (c) Obstacle check ---
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
				// Scale penalty by urgency: imminent collisions (ttc ≤ 10s) get
				// the full penalty; distant ones taper off so the ship doesn't
				// take wild detours to avoid ships that are far away and will
				// likely have re-planned by the time they get close.
				float urgency = std::min(1.0f, 10.0f / std::max(obs_info.time_to_collision, 1.0f));
				total_time += urgency * 60.0f;
				any_collision = true;
			}
		}

		// --- Shell & torpedo threat penalty ---
		// Scores real shells (from incoming_shells_) and virtual shell landings
		// generated procedurally from torpedo obstacle paths.
		{
			float threat_penalty = score_arc_shell_threat(arc);
			total_time += threat_penalty * dynamic_threat_weight;

			// --- Option B: Dodge commitment bias ---
			// If we're committed to a dodge direction, penalize candidates
			// that turn the opposite way.  This prevents frame-to-frame
			// oscillation when symmetric threats produce mirror-image arcs.
			if (threat_penalty > 0.0f && dodge_committed_rudder_ != 0.0f) {
				// Check if this candidate opposes the committed direction
				bool opposes = (cand_rudder * dodge_committed_rudder_ < -0.01f);
				if (opposes) {
					total_time += DODGE_COMMITMENT_BIAS;
				}
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
	result.collision_imminent = any_collision || (best_rudder != desired_rudder) || (best_throttle != desired_throttle);

	// --- Option B: Set dodge commitment when threats caused a rudder change ---
	// If shells/torpedoes are present and the winning rudder differs from
	// the desired rudder, commit to that dodge direction so we don't flip
	// back next frame.
	bool threats_active = !incoming_shells_.empty();
	if (!threats_active) {
		for (const auto &[id, obs] : obstacles) {
			if (obs.is_torpedo()) { threats_active = true; break; }
		}
	}
	if (threats_active && std::abs(best_rudder - desired_rudder) > 0.1f) {
		float rudder_sign = (best_rudder > 0.0f) ? 1.0f : -1.0f;
		// Only set commitment if it's a new direction or reinforcing the same one
		if (dodge_committed_rudder_ == 0.0f || rudder_sign == dodge_committed_rudder_) {
			dodge_committed_rudder_ = rudder_sign;
			dodge_commitment_timer_ = DODGE_COMMITMENT_DURATION;
		}
		// If the best candidate opposes the current commitment, only override
		// if the score difference is decisive (commitment timer expired naturally)
	} else if (!threats_active) {
		// No threats — clear commitment immediately
		dodge_committed_rudder_ = 0.0f;
		dodge_commitment_timer_ = 0.0f;
	}

	return result;
}

// ============================================================================
// Pure pursuit steering
// ============================================================================

float ShipNavigator::compute_pure_pursuit_rudder() const {
	Vector2 wp;
	if (!current_path.waypoints.empty() && current_wp_index < (int)current_path.waypoints.size()) {
		wp = current_path.waypoints[current_wp_index];
	} else {
		wp = target.position;
	}

	Vector2 to_wp = wp - state.position;
	float forward_x = std::sin(state.heading);
	float forward_z = std::cos(state.heading);
	float along = to_wp.x * forward_x + to_wp.y * forward_z;

	if (along < 0.0f) {
		return compute_rudder_to_position(wp, false);
	}

	if (to_wp.length_squared() > 1.0f) {
		float wp_heading = std::atan2(to_wp.x, to_wp.y);
		return compute_rudder_to_heading(wp_heading);
	}
	return 0.0f;
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
		// Path planning came back invalid (no route found or D* Lite not yet
		// converged to a solution).  Prefer keeping the previous path — the
		// ship can continue following a stale-but-valid route while the search
		// retries next frame.  Only fall back to the direct destination line
		// when there is no prior path at all (e.g. very first navigation call).
		if (!path_valid || current_path.waypoints.empty()) {
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
		// else: keep current_path and path_valid unchanged
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

	const float alignment_threshold = 0.087f;
	bool rudder_settled = false;

	// Precompute loop-invariant lateral drag decay factor.
	// dt is integration_dt for every step except possibly the very last
	// (clamped to max_time), so the tiny error on that one step is negligible.
	const float exp_decay = std::exp(-lateral_drag * integration_dt);

	// After the arc aligns with target_pos, switch to straight so the avoidance
	// system can check terrain on the straight segment from alignment to waypoint.
	float effective_rudder = commanded_rudder;
	bool aligned = false;
	while (sim_time < max_time && total_distance < max_arc_distance) {
		float dt = integration_dt;
		if (sim_time + dt > max_time) dt = max_time - sim_time;
		if (dt < 0.001f) break;

		if (params.rudder_response_time > 0.001f) {
			sim_rudder = move_toward_f(sim_rudder, effective_rudder, dt / params.rudder_response_time);
		} else {
			sim_rudder = effective_rudder;
		}

		if (!rudder_settled && std::abs(sim_rudder - effective_rudder) < 0.01f) {
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
		sim_lateral_speed *= exp_decay;

		float cur_fwd_x = std::sin(sim_heading);
		float cur_fwd_z = std::cos(sim_heading);
		float cur_lat_x = cur_fwd_z;
		float cur_lat_z = -cur_fwd_x;
		sim_pos.x += cur_fwd_x * effective_speed * dt + cur_lat_x * sim_lateral_speed * dt;
		sim_pos.y += cur_fwd_z * effective_speed * dt + cur_lat_z * sim_lateral_speed * dt;

		sim_time += dt;

		// step_dist: fwd and lat basis vectors are orthogonal unit vectors so the
		// magnitude of the displacement is exactly dt * hypot(effective_speed, sim_lateral_speed).
		// This avoids tracking prev_pos and calling distance_to (which also does a sqrt).
		float step_dist = dt * std::sqrt(effective_speed * effective_speed
		                               + sim_lateral_speed * sim_lateral_speed);
		total_distance += step_dist;

		if (total_distance >= next_emit_dist) {
			arc.push_back(ArcPoint(sim_pos, sim_heading, sim_speed, sim_time));
			next_emit_dist += emit_interval;

			// Check alignment at emit points only — atan2 is expensive and
			// arc-point granularity is sufficient for avoidance scoring.
			// After alignment, switch to straight (rudder 0) and continue
			// simulating so select_best_steering can check terrain on the
			// straight segment from alignment point to waypoint.
			if (aligned) {
				if (sim_pos.distance_to(target_pos) < emit_interval) {
					break;
				}
			} else if (rudder_settled) {
				Vector2 to_target = target_pos - sim_pos;
				float dist_to_target = to_target.length();
				if (dist_to_target > 1.0f) {
					float desired_heading = std::atan2(to_target.x, to_target.y);
					float heading_error = std::abs(angle_difference(sim_heading, desired_heading));
					if (heading_error < alignment_threshold) {
						aligned = true;
						effective_rudder = 0.0f;
					}
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

// ---------------------------------------------------------------------------
// 2D OBB-OBB separating axis test (SAT).
// Each OBB is defined by a center position, a heading (radians, forward axis
// = (sin h, cos h)), a half-length along the forward axis, and a half-beam
// perpendicular to it.  Returns true when the boxes overlap (collision).
// ---------------------------------------------------------------------------
static inline bool obb_obb_overlap_2d(
	Vector2 a_pos, float a_heading, float a_hl, float a_hb,
	Vector2 b_pos, float b_heading, float b_hl, float b_hb)
{
	// Local axes for each OBB  (forward = (sin h, cos h), right = (cos h, -sin h))
	const float fa_x = std::sin(a_heading), fa_y = std::cos(a_heading);
	const float ra_x = fa_y,               ra_y = -fa_x;
	const float fb_x = std::sin(b_heading), fb_y = std::cos(b_heading);
	const float rb_x = fb_y,               rb_y = -fb_x;

	// Center separation
	const float tx = b_pos.x - a_pos.x;
	const float ty = b_pos.y - a_pos.y;

	// Precompute absolute cross-axis dot products (used across all four axes)
	const float c00 = std::abs(fa_x * fb_x + fa_y * fb_y);  // |fwd_a · fwd_b|
	const float c01 = std::abs(fa_x * rb_x + fa_y * rb_y);  // |fwd_a · rgt_b|
	const float c10 = std::abs(ra_x * fb_x + ra_y * fb_y);  // |rgt_a · fwd_b|
	const float c11 = std::abs(ra_x * rb_x + ra_y * rb_y);  // |rgt_a · rgt_b|

	// Test axis 1: A forward
	if (std::abs(tx * fa_x + ty * fa_y) > a_hl + b_hl * c00 + b_hb * c01) return false;
	// Test axis 2: A right (starboard)
	if (std::abs(tx * ra_x + ty * ra_y) > a_hb + b_hl * c10 + b_hb * c11) return false;
	// Test axis 3: B forward
	if (std::abs(tx * fb_x + ty * fb_y) > b_hl + a_hl * c00 + a_hb * c10) return false;
	// Test axis 4: B right (starboard)
	if (std::abs(tx * rb_x + ty * rb_y) > b_hb + a_hl * c01 + a_hb * c11) return false;

	return true; // no separating axis found — boxes overlap
}

ObstacleCollisionInfo ShipNavigator::check_arc_obstacles_detailed(const std::vector<ArcPoint> &arc) const {
	ObstacleCollisionInfo result;

	// Safety margin added to our OBB on every face so the ship maintains a
	// small buffer beyond hull-to-hull contact.
	const float margin  = params.ship_beam * 0.5f;
	const float our_hl  = params.ship_length * 0.5f + margin;
	const float our_hb  = params.ship_beam   * 0.5f + margin;

	// Fallback circle clearance for torpedo obstacles (no orientation info).
	const float torp_clearance = get_ship_clearance();

	for (const auto &[id, obs] : obstacles) {
		// When parked, skip non-torpedo obstacles — the moving ship should
		// be the one that avoids, not a stationary ship holding position.
		if (skip_ship_obstacles_ && !obs.is_torpedo()) continue;

		for (const auto &pt : arc) {
			Vector2 obs_pos = obs.position + obs.velocity * pt.time;
			bool collision = false;

			if (obs.length > 0.0f) {
				// Ship obstacle: OBB-OBB separating axis test.
				// obs.radius is the obstacle's half-beam; obs.length is its full length.
				// The obstacle heading is kept up-to-date by update_obstacle().
				collision = obb_obb_overlap_2d(
					pt.position, pt.heading, our_hl, our_hb,
					obs_pos, obs.heading, obs.length * 0.5f, obs.radius);
			} else {
				// Torpedo (or unknown circular obstacle): fall back to circle test.
				float dist = pt.position.distance_to(obs_pos);
				collision = (dist < torp_clearance + obs.radius);
			}

			if (collision) {
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

