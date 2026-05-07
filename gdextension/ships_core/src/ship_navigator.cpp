#include "ship_navigator.h"
#include "godot_cpp/templates/safe_refcount.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

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
	ClassDB::bind_method(D_METHOD("get_timing_steering_us"), &ShipNavigator::get_timing_steering_us);
	ClassDB::bind_method(D_METHOD("get_timing_replan_reason"), &ShipNavigator::get_timing_replan_reason);
	ClassDB::bind_method(D_METHOD("get_timing_plan_phase"), &ShipNavigator::get_timing_plan_phase);
	ClassDB::bind_method(D_METHOD("get_perf_metrics"), &ShipNavigator::get_perf_metrics);
	ClassDB::bind_method(D_METHOD("reset_perf_metrics"), &ShipNavigator::reset_perf_metrics);
	ClassDB::bind_method(D_METHOD("set_perf_spike_threshold_us", "threshold_us"), &ShipNavigator::set_perf_spike_threshold_us);
	ClassDB::bind_method(D_METHOD("get_perf_spike_threshold_us"), &ShipNavigator::get_perf_spike_threshold_us);
	ClassDB::bind_method(D_METHOD("set_perf_tracking_enabled", "enabled"), &ShipNavigator::set_perf_tracking_enabled);
	ClassDB::bind_method(D_METHOD("is_perf_tracking_enabled"), &ShipNavigator::is_perf_tracking_enabled);

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
	out_rudder = 0.0f;
	out_throttle = 0;
	out_collision_imminent = false;
	timing_update_us = 0.0f;
	timing_avoidance_us = 0.0f;
	timing_plan_us = 0.0f;
	timing_steering_us = 0.0f;
	timing_replan_reason = 0;
	timing_plan_phase_val = 0;

	perf_frame_count_ = 0;
	perf_spike_threshold_us_ = 2500.0f;
	perf_report_interval_s_ = 5.0f;
	perf_report_accum_s_ = 0.0f;
	perf_tracking_enabled_ = false;
	for (int i = 0; i < PERF_SPIKE_PHASE_COUNT; ++i) {
		perf_phase_count_[i] = 0;
		perf_phase_avg_update_us_[i] = 0.0f;
		perf_phase_avg_plan_us_[i] = 0.0f;
		perf_phase_avg_avoidance_us_[i] = 0.0f;
		perf_phase_avg_steering_us_[i] = 0.0f;
	}
	perf_window_frame_count_ = 0;
	perf_window_update_sum_us_ = 0.0f;
	perf_window_plan_sum_us_ = 0.0f;
	perf_window_avoidance_sum_us_ = 0.0f;
	perf_window_steering_sum_us_ = 0.0f;
	perf_avg_update_us_ = 0.0f;
	perf_avg_plan_us_ = 0.0f;
	perf_avg_avoidance_us_ = 0.0f;
	perf_avg_steering_us_ = 0.0f;
	perf_max_update_us_ = 0.0f;
	perf_max_plan_us_ = 0.0f;
	perf_max_avoidance_us_ = 0.0f;
	perf_max_steering_us_ = 0.0f;
	perf_update_spike_count_ = 0;
	perf_plan_spike_count_ = 0;
	perf_avoidance_spike_count_ = 0;
	perf_steering_spike_count_ = 0;
	perf_worst_update_spike_us_ = 0.0f;
	perf_worst_plan_spike_us_ = 0.0f;
	perf_worst_avoidance_spike_us_ = 0.0f;
	perf_worst_steering_spike_us_ = 0.0f;
	perf_last_steering_candidates_total_ = 0;
	perf_last_steering_candidates_simulated_ = 0;
	perf_last_steering_terrain_rejects_ = 0;
	perf_last_steering_short_arc_rejects_ = 0;
	perf_last_steering_arc_points_simulated_ = 0;

	skip_ship_obstacles_ = false;
	health_fraction_ = 1.0f;
	dodge_committed_rudder_ = 0.0f;
	dodge_commitment_timer_ = 0.0f;
	direction_conflict_timer_ = 0.0f;
	stuck_override_active_ = false;
	stuck_override_timer_ = 0.0f;
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

	// navigate_to() is the synchronous planning trigger.
	run_plan_sync();
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
	// Use the final waypoint in the path (always target.position after planning)
	// so arrival tracking is consistent with path state.  Falls back to
	// target.position if no path has been planned yet.
	Vector2 final_node = (path_valid && !current_path.waypoints.empty())
		? current_path.waypoints.back()
		: target.position;
	const float arrived_radius = std::max(target.hold_radius, params.ship_beam * 2.0f);
	return state.position.distance_to(final_node) < arrived_radius;
}

Dictionary ShipNavigator::get_perf_metrics() const {
	Dictionary d;
	d["tracking_enabled"] = perf_tracking_enabled_;
	d["frame_count"] = static_cast<int64_t>(perf_frame_count_);
	d["spike_threshold_us"] = perf_spike_threshold_us_;
	d["report_interval_s"] = perf_report_interval_s_;
	d["report_accum_s"] = perf_report_accum_s_;
	int cur_phase = static_cast<int>(perf_frame_count_ % PERF_SPIKE_PHASE_COUNT);
	d["spike_phase_count"] = PERF_SPIKE_PHASE_COUNT;
	d["spike_phase_warmup_samples"] = 3;
	d["current_phase_idx"] = cur_phase;
	d["current_phase_samples"] = static_cast<int64_t>(perf_phase_count_[cur_phase]);
	d["current_phase_avg_update_us"] = perf_phase_avg_update_us_[cur_phase];
	d["current_phase_avg_plan_us"] = perf_phase_avg_plan_us_[cur_phase];
	d["current_phase_avg_avoidance_us"] = perf_phase_avg_avoidance_us_[cur_phase];
	d["current_phase_avg_steering_us"] = perf_phase_avg_steering_us_[cur_phase];

	d["last_update_us"] = timing_update_us;
	d["last_plan_us"] = timing_plan_us;
	d["last_avoidance_us"] = timing_avoidance_us;
	d["last_steering_us"] = timing_steering_us;
	d["last_replan_reason"] = timing_replan_reason;
	d["last_plan_phase"] = timing_plan_phase_val;

	d["avg_update_us"] = perf_avg_update_us_;
	d["avg_plan_us"] = perf_avg_plan_us_;
	d["avg_avoidance_us"] = perf_avg_avoidance_us_;
	d["avg_steering_us"] = perf_avg_steering_us_;
	if (perf_window_frame_count_ > 0) {
		float inv = 1.0f / static_cast<float>(perf_window_frame_count_);
		d["window_avg_update_us"] = perf_window_update_sum_us_ * inv;
		d["window_avg_plan_us"] = perf_window_plan_sum_us_ * inv;
		d["window_avg_avoidance_us"] = perf_window_avoidance_sum_us_ * inv;
		d["window_avg_steering_us"] = perf_window_steering_sum_us_ * inv;
	} else {
		d["window_avg_update_us"] = 0.0f;
		d["window_avg_plan_us"] = 0.0f;
		d["window_avg_avoidance_us"] = 0.0f;
		d["window_avg_steering_us"] = 0.0f;
	}

	d["max_update_us"] = perf_max_update_us_;
	d["max_plan_us"] = perf_max_plan_us_;
	d["max_avoidance_us"] = perf_max_avoidance_us_;
	d["max_steering_us"] = perf_max_steering_us_;

	d["update_spike_count"] = static_cast<int64_t>(perf_update_spike_count_);
	d["plan_spike_count"] = static_cast<int64_t>(perf_plan_spike_count_);
	d["avoidance_spike_count"] = static_cast<int64_t>(perf_avoidance_spike_count_);
	d["steering_spike_count"] = static_cast<int64_t>(perf_steering_spike_count_);

	d["worst_update_spike_us"] = perf_worst_update_spike_us_;
	d["worst_plan_spike_us"] = perf_worst_plan_spike_us_;
	d["worst_avoidance_spike_us"] = perf_worst_avoidance_spike_us_;
	d["worst_steering_spike_us"] = perf_worst_steering_spike_us_;

	d["last_steering_candidates_total"] = perf_last_steering_candidates_total_;
	d["last_steering_candidates_simulated"] = perf_last_steering_candidates_simulated_;
	d["last_steering_terrain_rejects"] = perf_last_steering_terrain_rejects_;
	d["last_steering_short_arc_rejects"] = perf_last_steering_short_arc_rejects_;
	d["last_steering_arc_points_simulated"] = perf_last_steering_arc_points_simulated_;

	return d;
}

void ShipNavigator::reset_perf_metrics() {
	float threshold = perf_spike_threshold_us_;
	float report_interval = perf_report_interval_s_;
	perf_frame_count_ = 0;
	perf_report_accum_s_ = 0.0f;
	for (int i = 0; i < PERF_SPIKE_PHASE_COUNT; ++i) {
		perf_phase_count_[i] = 0;
		perf_phase_avg_update_us_[i] = 0.0f;
		perf_phase_avg_plan_us_[i] = 0.0f;
		perf_phase_avg_avoidance_us_[i] = 0.0f;
		perf_phase_avg_steering_us_[i] = 0.0f;
	}
	perf_window_frame_count_ = 0;
	perf_window_update_sum_us_ = 0.0f;
	perf_window_plan_sum_us_ = 0.0f;
	perf_window_avoidance_sum_us_ = 0.0f;
	perf_window_steering_sum_us_ = 0.0f;
	perf_avg_update_us_ = 0.0f;
	perf_avg_plan_us_ = 0.0f;
	perf_avg_avoidance_us_ = 0.0f;
	perf_avg_steering_us_ = 0.0f;
	perf_max_update_us_ = 0.0f;
	perf_max_plan_us_ = 0.0f;
	perf_max_avoidance_us_ = 0.0f;
	perf_max_steering_us_ = 0.0f;
	perf_update_spike_count_ = 0;
	perf_plan_spike_count_ = 0;
	perf_avoidance_spike_count_ = 0;
	perf_steering_spike_count_ = 0;
	perf_worst_update_spike_us_ = 0.0f;
	perf_worst_plan_spike_us_ = 0.0f;
	perf_worst_avoidance_spike_us_ = 0.0f;
	perf_worst_steering_spike_us_ = 0.0f;
	perf_last_steering_candidates_total_ = 0;
	perf_last_steering_candidates_simulated_ = 0;
	perf_last_steering_terrain_rejects_ = 0;
	perf_last_steering_short_arc_rejects_ = 0;
	perf_last_steering_arc_points_simulated_ = 0;
	perf_spike_threshold_us_ = threshold;
	perf_report_interval_s_ = report_interval;
}

void ShipNavigator::set_perf_spike_threshold_us(float threshold_us) {
	perf_spike_threshold_us_ = std::max(0.0f, threshold_us);
}

float ShipNavigator::get_perf_spike_threshold_us() const {
	return perf_spike_threshold_us_;
}

void ShipNavigator::set_perf_tracking_enabled(bool enabled) {
	perf_tracking_enabled_ = enabled;
}

bool ShipNavigator::is_perf_tracking_enabled() const {
	return perf_tracking_enabled_;
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

		// Line emitted from torpedo nose for debug visualization (3000 m lookahead)
		constexpr float TORP_VIS_DIST = 3000.0f;
		Vector2 line_start  = obs.position;
		Vector2 line_end    = obs.position + torp_dir * TORP_VIS_DIST;
		Vector2 line_center = obs.position + torp_dir * (TORP_VIS_DIST * 0.5f);

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
		d["line_half_len"] = TORP_VIS_DIST * 0.5f;
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
	// float base = params.ship_length;
	// float speed_factor = std::abs(state.current_speed) * 2.0f;
	// float turn_factor = params.turning_circle_radius * 0.3f;
	// return std::max(base, std::min(turn_factor, speed_factor));
	return params.turning_circle_radius;
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

	// Reset stage timings every frame so emergency-mode frames don't retain
	// stale NORMAL-mode values.
	timing_plan_us = 0.0f;
	timing_avoidance_us = 0.0f;
	timing_steering_us = 0.0f;

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

	if (!perf_tracking_enabled_) {
		return;
	}

	int phase_idx = static_cast<int>(perf_frame_count_ % PERF_SPIKE_PHASE_COUNT);
	uint64_t phase_samples = perf_phase_count_[phase_idx];
	const uint64_t phase_warmup_samples = 3;
	float phase_base_update_us = perf_phase_avg_update_us_[phase_idx];
	float phase_base_plan_us = perf_phase_avg_plan_us_[phase_idx];
	float phase_base_avoidance_us = perf_phase_avg_avoidance_us_[phase_idx];
	float phase_base_steering_us = perf_phase_avg_steering_us_[phase_idx];

	perf_frame_count_++;
	auto update_ema = [&](float &ema, float sample) {
		if (perf_frame_count_ <= 1) ema = sample;
		else ema = ema * 0.9f + sample * 0.1f;
	};

	update_ema(perf_avg_update_us_, timing_update_us);
	update_ema(perf_avg_plan_us_, timing_plan_us);
	update_ema(perf_avg_avoidance_us_, timing_avoidance_us);
	update_ema(perf_avg_steering_us_, timing_steering_us);

	perf_max_update_us_ = std::max(perf_max_update_us_, timing_update_us);
	perf_max_plan_us_ = std::max(perf_max_plan_us_, timing_plan_us);
	perf_max_avoidance_us_ = std::max(perf_max_avoidance_us_, timing_avoidance_us);
	perf_max_steering_us_ = std::max(perf_max_steering_us_, timing_steering_us);

	bool spike = false;
	if (phase_samples >= phase_warmup_samples) {
		if (timing_update_us >= phase_base_update_us + perf_spike_threshold_us_) {
			perf_update_spike_count_++;
			perf_worst_update_spike_us_ = std::max(perf_worst_update_spike_us_, timing_update_us);
			spike = true;
		}
		if (timing_plan_us >= phase_base_plan_us + perf_spike_threshold_us_) {
			perf_plan_spike_count_++;
			perf_worst_plan_spike_us_ = std::max(perf_worst_plan_spike_us_, timing_plan_us);
			spike = true;
		}
		if (timing_avoidance_us >= phase_base_avoidance_us + perf_spike_threshold_us_) {
			perf_avoidance_spike_count_++;
			perf_worst_avoidance_spike_us_ = std::max(perf_worst_avoidance_spike_us_, timing_avoidance_us);
			spike = true;
		}
		if (timing_steering_us >= phase_base_steering_us + perf_spike_threshold_us_) {
			perf_steering_spike_count_++;
			perf_worst_steering_spike_us_ = std::max(perf_worst_steering_spike_us_, timing_steering_us);
			spike = true;
		}
	}

	auto update_phase_ema = [&](float &avg, float sample) {
		if (phase_samples == 0) avg = sample;
		else avg = avg * 0.9f + sample * 0.1f;
	};
	update_phase_ema(perf_phase_avg_update_us_[phase_idx], timing_update_us);
	update_phase_ema(perf_phase_avg_plan_us_[phase_idx], timing_plan_us);
	update_phase_ema(perf_phase_avg_avoidance_us_[phase_idx], timing_avoidance_us);
	update_phase_ema(perf_phase_avg_steering_us_[phase_idx], timing_steering_us);
	perf_phase_count_[phase_idx] = phase_samples + 1;

	perf_window_frame_count_++;
	perf_window_update_sum_us_ += timing_update_us;
	perf_window_plan_sum_us_ += timing_plan_us;
	perf_window_avoidance_sum_us_ += timing_avoidance_us;
	perf_window_steering_sum_us_ += timing_steering_us;
	if (delta > 0.0f) {
		perf_report_accum_s_ += delta;
	}

	if (spike) {
		UtilityFunctions::print(
			"[ShipNavigator][SPIKE] bot=", bot_id_,
			" phase=", phase_idx,
			" phase_samples=", static_cast<int64_t>(phase_samples),
			" update_us=", timing_update_us,
			" plan_us=", timing_plan_us,
			" avoid_us=", timing_avoidance_us,
			" steering_us=", timing_steering_us,
			" phase_base(update/plan/avoid/steer)=",
			phase_base_update_us, "/", phase_base_plan_us, "/", phase_base_avoidance_us, "/", phase_base_steering_us,
			" delta_threshold_us=", perf_spike_threshold_us_,
			" cand=", perf_last_steering_candidates_simulated_, "/", perf_last_steering_candidates_total_,
			" terrain_rejects=", perf_last_steering_terrain_rejects_,
			" short_arcs=", perf_last_steering_short_arc_rejects_,
			" arc_pts=", perf_last_steering_arc_points_simulated_,
			" replan_reason=", timing_replan_reason,
			" nav_state=", static_cast<int>(nav_state));
	}

	if (perf_report_accum_s_ >= perf_report_interval_s_ && perf_window_frame_count_ > 0) {
		float inv = 1.0f / static_cast<float>(perf_window_frame_count_);
		float phase_peak_update = 0.0f;
		float phase_peak_plan = 0.0f;
		float phase_peak_avoid = 0.0f;
		float phase_peak_steer = 0.0f;
		for (int i = 0; i < PERF_SPIKE_PHASE_COUNT; ++i) {
			phase_peak_update = std::max(phase_peak_update, perf_phase_avg_update_us_[i]);
			phase_peak_plan = std::max(phase_peak_plan, perf_phase_avg_plan_us_[i]);
			phase_peak_avoid = std::max(phase_peak_avoid, perf_phase_avg_avoidance_us_[i]);
			phase_peak_steer = std::max(phase_peak_steer, perf_phase_avg_steering_us_[i]);
		}
		UtilityFunctions::print(
			"[ShipNavigator][AVG 5s] bot=", bot_id_,
			" frames=", static_cast<int64_t>(perf_window_frame_count_),
			" avg_update_us=", perf_window_update_sum_us_ * inv,
			" avg_plan_us=", perf_window_plan_sum_us_ * inv,
			" avg_avoid_us=", perf_window_avoidance_sum_us_ * inv,
			" avg_steering_us=", perf_window_steering_sum_us_ * inv,
			" phase_peak(update/plan/avoid/steer)=",
			phase_peak_update, "/", phase_peak_plan, "/", phase_peak_avoid, "/", phase_peak_steer,
			" spikes(update/plan/avoid/steer)=",
			static_cast<int64_t>(perf_update_spike_count_), "/",
			static_cast<int64_t>(perf_plan_spike_count_), "/",
			static_cast<int64_t>(perf_avoidance_spike_count_), "/",
			static_cast<int64_t>(perf_steering_spike_count_));

		perf_window_frame_count_ = 0;
		perf_window_update_sum_us_ = 0.0f;
		perf_window_plan_sum_us_ = 0.0f;
		perf_window_avoidance_sum_us_ = 0.0f;
		perf_window_steering_sum_us_ = 0.0f;
		while (perf_report_accum_s_ >= perf_report_interval_s_) {
			perf_report_accum_s_ -= perf_report_interval_s_;
		}
	}
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

	// --- 1. Plan bookkeeping only (no replanning here) ---
	// Replanning is event-driven from navigate_to().  This keeps set_state()
	// lightweight and prevents periodic planning spikes in per-frame updates.
	timing_replan_reason = 0;
	timing_plan_phase_val = 0;
	timing_plan_us = 0.0f;

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
			if (dist_to_dest < arrived_radius) {
				// Inside arrived zone but heading wrong: pure heading alignment.
				desired_rudder = compute_rudder_to_heading(target.heading, reversing);
			} else {
				// Outside arrived zone: steer toward the destination position so a
				// perpendicular or lateral offset is corrected.  Heading alignment
				// happens naturally once the ship is within arrived_radius.
				desired_rudder = compute_rudder_to_position(target.position, reversing);
			}

		} else {
			// Approach zone: decelerate toward destination.
			// Steer toward the destination position (not just the arrival heading)
			// so the ship doesn't sail past a destination that is perpendicular
			// to its current heading.
			desired_rudder = compute_rudder_to_position(target.position);
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
	timing_steering_us = timing_avoidance_us;

	// --- 4.1. Stuck / bow-in detection ---
	// Detect when the navigator wants to reverse (destination is directly behind)
	// but incoming shell threats keep overriding to forward candidates, keeping
	// the ship bow-in toward the target it can't reach.
	//
	// Key insight: a forward turn-around does NOT trigger this — during a u-turn
	// desired_throttle is forward, so nav and steering AGREE.  The conflict only
	// accumulates when nav explicitly wants reverse AND threats keep choosing forward.
	//
	// Once the conflict persists long enough (scaled by the ship's turnaround time),
	// stuck_override_active_ is set: shell threat budget is zeroed so the ship can
	// push through the incoming fire to execute the reverse maneuver.  Torpedo
	// threats still apply — the ship accepts shell risk, not torpedo risk.
	{
		const bool nav_wants_reverse       = (desired_throttle < 0);
		const bool threat_overrode_forward = (choice.throttle >= 0 && nav_wants_reverse);

		// Scale threshold and override duration by the ship's turnaround time
		const float turnaround_time = static_cast<float>(Math_PI)
		                              * params.turning_circle_radius
		                              / std::max(params.max_speed, 1.0f);
		const float stuck_threshold  = std::max(STUCK_MIN_SECS,  turnaround_time * STUCK_TCR_FACTOR);
		const float override_dur     = std::max(STUCK_OVERRIDE_MIN, turnaround_time * STUCK_OVERRIDE_FACTOR);

		// Tick down active override
		if (stuck_override_timer_ > 0.0f) {
			stuck_override_timer_ -= delta;
			if (stuck_override_timer_ <= 0.0f) {
				stuck_override_timer_ = 0.0f;
				stuck_override_active_ = false;
			}
		}

		if (threat_overrode_forward && !stuck_override_active_) {
			direction_conflict_timer_ += delta;
			if (direction_conflict_timer_ >= stuck_threshold) {
				direction_conflict_timer_ = 0.0f;
				stuck_override_active_   = true;
				stuck_override_timer_    = override_dur;
				// Clear dodge commitment — we're breaking through, not dodging
				dodge_committed_rudder_ = 0.0f;
				dodge_commitment_timer_ = 0.0f;
			}
		} else if (!threat_overrode_forward) {
			// Progress being made: decay conflict timer at 2× rate
			direction_conflict_timer_ = std::max(0.0f, direction_conflict_timer_ - delta * 2.0f);
		}
	}

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
			return;
		}
	}

	set_steering_output(rudder, throttle, true);
}

// ============================================================================
// Plan management
// ============================================================================

void ShipNavigator::run_plan_sync() {
	const float plan_min_clearance = get_ship_clearance();

	// -----------------------------------------------------------------------
	// HPA* path (primary): threat-aware hierarchical A*.
	// HpaGraph is shared by many ships; apply this navigator's threat layer
	// immediately before each query so the correct threats are stamped.
	// -----------------------------------------------------------------------
	if (hpa_graph_.is_valid() && hpa_graph_->is_built() &&
		map.is_valid() && map->is_built()) {

		if (threat_bin_) {
			hpa_graph_->stamp_threats(threat_bin_->threats);
			threat_last_version_ = threat_bin_->version;
		} else {
			hpa_graph_->clear_threats();
		}

		PathResult pr = hpa_graph_->find_path(state.position, target.position, plan_min_clearance);
		if (pr.valid && !pr.waypoints.empty()) {
			// Always end at the exact destination — HPA* snaps to grid nodes
			// so the final grid node may not be target.position.
			if (pr.waypoints.back().distance_to(target.position) > 1.0f) {
				pr.waypoints.push_back(target.position);
				pr.flags.push_back(WP_NONE);
			}
			accept_plan_result(pr);
			return;
		}
		// HPA* failed — retain the previous path rather than overwriting it with
		// a straight-line fallback.  The ship continues following its existing
		// route while navigate_to() retries on the next call.
		if (path_valid && !current_path.waypoints.empty()) {
			return;
		}
		// No prior path available — fall through to straight-line fallbacks.
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
			direct.waypoints.push_back(target.position);  // blocked — destination is goal even if unreachable now

		direct.flags.assign(direct.waypoints.size(), WP_NONE);
		direct.valid = true;
		direct.total_distance = 0.0f;
		for (size_t i = 0; i + 1 < direct.waypoints.size(); ++i)
			direct.total_distance += direct.waypoints[i].distance_to(direct.waypoints[i + 1]);
		accept_plan_result(direct);
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

	return 30.0f * size_factor * health_factor;
}

ShipNavigator::ThreatEval ShipNavigator::score_arc_shell_threat(const std::vector<ArcPoint> &arc) const {
	ThreatEval result;
	if (arc.size() < 2) return result;

	// Ship half-extents for OBB test
	const float hsl = params.ship_length * 0.5f;  // half-length (bow/stern)
	const float hsb = params.ship_beam   * 0.5f;  // half-beam  (port/starboard)

	// --- Adaptive time tolerance ---
	// eff_tol is the maximum acceptable gap between a shell's impact time and
	// the nearest arc sample.  It is driven purely by the arc's own sampling
	// density (1.5× the mean inter-point interval) so that shells are only
	// tested when the arc actually covers the relevant time window.  A 2-second
	// floor handles instantaneous arcs (single point, arc_dt_mean == 0).
	const float arc_duration = arc.back().time - arc.front().time;
	const float arc_dt_mean  = (arc.size() > 1) ? arc_duration / float(arc.size() - 1) : 0.0f;
	const float eff_tol = std::max(SHELL_TIME_TOLERANCE, arc_dt_mean * 1.5f);

	// =========================================================
	// SHELLS  —  temporal point intersection
	//
	// For each shell, find the arc point whose simulation time is
	// closest to shell.time_remaining.  If the gap is within the
	// adaptive tolerance, project the shell's landing point into
	// the ship's OBB at that arc point's position/heading.
	// Penalty factor:
	//   • end-on (bow or stern toward incoming shell) → GRAZE_MIN_FACTOR (autobounce)
	//   • broadside                                  → 1.0 (maximum damage)
	//   • bow/stern hull-tip clips                   → further reduced
	// =========================================================
	for (const auto &shell : incoming_shells_) {
		if (shell.time_remaining < 0.5f) continue;  // about to land, no time to dodge

		// Skip shells whose impact time is beyond the arc's simulated range.
		// Without this check, shells landing well after the arc ends could be
		// tested against the arc's endpoint position, which may be far from
		// where the ship would actually be at the shell's impact time.
		if (shell.time_remaining > arc.back().time + eff_tol) continue;

		const float cal_weight = (shell.caliber * shell.caliber) / (200.0f * 200.0f);

		// Find arc point nearest in time to shell impact
		const ArcPoint *best_apt = nullptr;
		float best_dt = std::numeric_limits<float>::infinity();
		for (const auto &apt : arc) {
			const float dt = std::abs(apt.time - shell.time_remaining);
			if (dt < best_dt) { best_dt = dt; best_apt = &apt; }
		}
		if (best_apt == nullptr || best_dt > eff_tol) continue;

		// Ship local frame at this arc point
		const float fx = std::sin(best_apt->heading);
		const float fz = std::cos(best_apt->heading);

		// Shell landing point relative to ship center, in ship local frame
		// along_keel > 0 = toward bow; along_beam > 0 = toward starboard
		const Vector2 rel       = shell.landing_pos - best_apt->position;
		const float along_keel  = rel.x * fx + rel.y * fz;
		const float along_beam  = rel.x * fz - rel.y * fx;

		// OBB check — use exact hull dimensions only.
		// An arc scores a shell hit only when the shell's predicted landing
		// position falls within the ship's actual bounding box at the matched
		// arc point.  No extra keel or beam margin is added: proximity is not
		// a hit.  This prevents dodging shells that would miss the ship.
		if (std::abs(along_keel) > hsl) continue;
		if (std::abs(along_beam) > hsb) continue;

		// Angle factor: shell arriving end-on is partially autobounced.
		//   cos_keel = |cos(angle between shell travel dir and ship keel)|:
		//     1 = bow/stern approach (autobounce) → GRAZE_MIN_FACTOR
		//     0 = broadside hit                   → 1.0
		const float cos_keel = std::abs(shell.landing_dir.x * fx + shell.landing_dir.y * fz);
		const float sin_keel = std::sqrt(std::max(0.0f, 1.0f - cos_keel * cos_keel));
		const float angle_factor = GRAZE_MIN_FACTOR + (1.0f - GRAZE_MIN_FACTOR) * sin_keel;

		// Bow/stern hard cutoff: shells landing in the extreme forward/aft section
		// (beyond BOW_STERN_CLIP_START fraction of the half-length) are rejected
		// entirely.  Angled bow/stern armour bounces these shells regardless of
		// calibre — no gradual falloff.
		const float fwd_frac = std::abs(along_keel) / std::max(hsl, 0.01f);
		if (fwd_frac > BOW_STERN_CLIP_START) continue;

		result.shell_score += cal_weight * angle_factor;
	}

	// =========================================================
	// TORPEDOES  —  temporal point intersection
	//
	// For each torpedo, project its position forward to the time
	// of each arc point and check if it falls within the ship's
	// OBB (extended by the torpedo's radius).  Torpedoes always
	// do full damage regardless of impact angle.
	// Accumulate the worst penalty across all arc points.
	// =========================================================
	for (const auto &[id, obs] : obstacles) {
		if (!obs.is_torpedo()) continue;

		const float torp_speed = obs.velocity.length();
		if (torp_speed < 1.0f) continue;

		const float cal_weight = (TORPEDO_VIRTUAL_CALIBER * TORPEDO_VIRTUAL_CALIBER)
		                         / (200.0f * 200.0f);
		float worst = 0.0f;

		for (const auto &apt : arc) {
			// Project torpedo position to arc time
			const Vector2 torp_pos = obs.position + obs.velocity * apt.time;

			// Ship local frame
			const float fx = std::sin(apt.heading);
			const float fz = std::cos(apt.heading);

			const Vector2 rel      = torp_pos - apt.position;
			const float along_keel = rel.x * fx + rel.y * fz;
			const float along_beam = rel.x * fz - rel.y * fx;

			// Clearance: hull half-extents + torpedo body radius
			if (std::abs(along_keel) > hsl + obs.radius) continue;
			if (std::abs(along_beam) > hsb + obs.radius) continue;

			// Torpedo hit — full damage, no angle discount
			if (cal_weight > worst) worst = cal_weight;
		}

		result.torpedo_score += worst;
	}

	return result;
}

ShipNavigator::SteeringChoice ShipNavigator::select_best_steering(float desired_rudder, int desired_throttle) {
	SteeringChoice result = { desired_rudder, desired_throttle, false };

	int steering_candidates_total = 0;
	int steering_candidates_simulated = 0;
	int steering_terrain_rejects = 0;
	int steering_short_arc_rejects = 0;
	int steering_arc_points_simulated = 0;

	float hard_clearance = get_ship_clearance();
	float soft_clearance  = get_soft_clearance();
	float lookahead       = get_lookahead_distance();

	// Compute current SDF once — reused for adaptive clearance, fast-exit,
	// and soft-terrain penalty tracking inside the candidate loop.
	const float sdf_here = (map.is_valid() && map->is_built())
		? map->get_distance(state.position.x, state.position.y)
		: std::numeric_limits<float>::infinity();

	// --- Adaptive clearance: halve when close to land ---
	// When the SDF at the ship's position is below 1.5 × hard clearance the ship
	// is entering a tight region.  Halving the simulated clearance lets the
	// planner find arcs through the passage instead of disqualifying every
	// candidate and oscillating in place.
	if (sdf_here < hard_clearance * 1.5f) hard_clearance *= 0.75f;
	else if (sdf_here < hard_clearance) hard_clearance *= 0.5f;

	// --- Parked-ship filter ---
	skip_ship_obstacles_ = (std::abs(state.current_speed) < PARKED_SPEED_THRESHOLD
	                         && desired_throttle <= 0);

	// --- Fast early-exit: skip when clearly safe and no threats at all ---
	// Threshold: sdf > lookahead + hard_clearance means no arc of length
	// 'lookahead' can possibly reach the hard-clearance zone.
	// (Using soft_clearance here would make the threshold enormous for large
	// ships — e.g. 1530 m for a battleship — forcing full simulation even in
	// open water hundreds of metres from land.)
	bool terrain_safe = (sdf_here > lookahead + hard_clearance);

	bool obstacles_safe = true;
	float engagement_range = lookahead + params.max_speed * 10.0f;
	for (const auto &[id, obs] : obstacles) {
		if (skip_ship_obstacles_ && !obs.is_torpedo()) continue;
		if (state.position.distance_to(obs.position) < engagement_range) {
			obstacles_safe = false;
			break;
		}
	}

	// shells_safe: true when no shell can possibly intercept the ship before
	// landing.  Quick geometric pre-filter: if the ship's maximum reachable
	// radius in the shell's remaining flight time does not overlap the landing
	// position (padded by half the ship's extents), the shell is guaranteed to
	// miss without any arc simulation.
	bool shells_safe = true;
	if (!incoming_shells_.empty()) {
		const float quick_hsl = params.ship_length * 0.5f;
		const float quick_hsb = params.ship_beam   * 0.5f;
		for (const auto &shell : incoming_shells_) {
			if (shell.time_remaining < 0.5f) continue;
			const float max_reach = params.max_speed * shell.time_remaining + quick_hsl + quick_hsb;
			if (state.position.distance_to(shell.landing_pos) <= max_reach) {
				shells_safe = false;
				break;
			}
		}
	}

	if (terrain_safe && obstacles_safe && shells_safe) {
		float fast_path_lookahead = params.turning_circle_radius * 1.5f;
		winning_arc = predict_arc_internal(desired_rudder, desired_throttle, fast_path_lookahead);
		perf_last_steering_candidates_total_     = 1;
		perf_last_steering_candidates_simulated_ = 1;
		perf_last_steering_terrain_rejects_      = 0;
		perf_last_steering_short_arc_rejects_    = 0;
		perf_last_steering_arc_points_simulated_ = static_cast<int>(winning_arc.size());
		return result;
	}

	// --- Determine waypoint target ---
	Vector2 wp_target = target.position;
	if (path_valid && current_wp_index < static_cast<int>(current_path.waypoints.size())) {
		wp_target = current_path.waypoints[current_wp_index];
	}
	float wp_reach_radius = get_reach_radius();

	// wp_is_virtual: score by heading alignment only when the ship is truly
	// AT the steering target (within arrived_radius ≈ 2 × ship_beam).
	// Using TCR or path_exhausted as the trigger caused heading-only scoring
	// when the destination was still far away and perpendicular, making
	// reverse candidates (half the turn-around time of a forward circle)
	// beat correct forward turns.
	bool wp_is_virtual = false;
	{
		const float arrived_r = std::max(target.hold_radius, params.ship_beam * 2.0f);
		if (state.position.distance_to(wp_target) < arrived_r)
			wp_is_virtual = true;
	}

	// --- Ship forward vector (used for obstacle hitter check) ---
	Vector2 our_fwd(std::sin(state.heading), std::cos(state.heading));

	// --- Build candidate list ---
	struct Candidate { float rudder; int throttle; };

	const float rudder_offsets[] = { 0.0f, 0.3f, -0.3f, 0.6f, -0.6f, -1.0f, 1.0f };
	constexpr int N_OFFSETS = 3;
	Candidate candidates[N_OFFSETS + 8];
	int n_candidates = 0;

	auto add_candidate = [&](float r, int t) {
		r = clamp_f(r, -1.0f, 1.0f);
		for (int j = 0; j < n_candidates; ++j)
			if (std::abs(candidates[j].rudder - r) < 0.05f && candidates[j].throttle == t) return;
		candidates[n_candidates++] = { r, t };
	};

	for (int i = 0; i < N_OFFSETS; ++i)
		add_candidate(desired_rudder + rudder_offsets[i], desired_throttle);

	if (std::abs(desired_rudder) > 0.15f)
		add_candidate((desired_rudder > 0.0f) ? -1.0f : 1.0f, desired_throttle);

	add_candidate( 0.0f, -1);
	add_candidate(-0.3f, -1);
	add_candidate( 0.3f, -1);
	add_candidate(-0.6f, -1);
	add_candidate( 0.6f, -1);
	add_candidate(-1.0f, -1);
	add_candidate( 1.0f, -1);

	steering_candidates_total = n_candidates;

	// --- Simulation parameters ---
	const float turn_circumference = 2.0f * static_cast<float>(Math_PI) * params.turning_circle_radius;
	const float sim_lookahead = std::max(turn_circumference, lookahead * 2.0f);
	const float sim_max_time  = 120.0f;
	constexpr float heading_align_thresh = 0.087f;  // ~5 degrees

	// --- Exit-heading: precompute remaining path context (normal path only) ---
	Vector2 next_goal_after_wp = target.position;
	float desired_exit_heading = 0.0f;
	bool  apply_exit_penalty   = false;
	if (!wp_is_virtual && path_valid) {
		int next_idx = current_wp_index + 1;
		if (next_idx < static_cast<int>(current_path.waypoints.size()))
			next_goal_after_wp = current_path.waypoints[next_idx];
		Vector2 to_next = next_goal_after_wp - wp_target;
		if (to_next.length() > 1.0f) {
			desired_exit_heading = std::atan2(to_next.x, to_next.y);
			apply_exit_penalty   = true;
		}
	}

	// --- Heading-weight mode (normal path only) ---
	bool    has_heading_weight = (target.heading_weight > 0.001f);
	Vector2 heading_vp;
	if (has_heading_weight) {
		float th = target.heading;
		heading_vp = state.position + Vector2(std::sin(th), std::cos(th)) * 10000.0f;
	}

	// =========================================================
	// Two-pass scoring storage
	//   nav_score  = pure navigation cost (no threat penalty)
	//   threats    = shell + torpedo hit scores (dimensionless)
	// Selection: find best_nav; filter to best_nav + budget;
	//            pick the candidate with the lowest effective threat.
	// =========================================================
	struct PassEntry {
		float      rudder;
		int        throttle;
		float      nav_score;
		ThreatEval threats;
		bool       any_obs_collision;
	};
	static constexpr int MAX_PASS_ENTRIES = 24;
	PassEntry pass_data[MAX_PASS_ENTRIES];
	int n_pass = 0;
	bool any_collision = false;

	// =========================================================
	// Per-candidate scoring loop
	// =========================================================
	for (int i = 0; i < n_candidates; ++i) {
		const float cand_rudder   = candidates[i].rudder;
		const int   cand_throttle = candidates[i].throttle;

		if (wp_is_virtual) {
			// ---- At-destination: score by heading alignment time ----
			// predict_arc_internal gives a free-running arc not tied to a waypoint
			// arrival condition, avoiding the symmetric-scoring tie that the old
			// virtual-waypoint approach produced.
			auto arc = predict_arc_internal(cand_rudder, cand_throttle, sim_lookahead);
			if (arc.size() < 2) { steering_short_arc_rejects++; continue; }
			steering_candidates_simulated++;
			steering_arc_points_simulated += static_cast<int>(arc.size());

			// Terrain: check arc points up to the immediate stroke horizon.
			// At destination the ship executes short strokes and re-evaluates
			// every frame, so checking the full 3700+ m arc would falsely block
			// forward candidates that clip terrain only far into a circular arc
			// they will never complete.  Cap the check at 'lookahead' of cumulative
			// arc distance — enough to detect truly imminent terrain without
			// penalising multi-point turns near the coastline.
			bool  terrain_blocked = false;
			float soft_min_sdf    = std::numeric_limits<float>::infinity();
			if (map.is_valid() && map->is_built()) {
				float arc_dist = 0.0f;
				Vector2 prev = arc.front().position;
				for (const auto &pt : arc) {
					arc_dist += pt.position.distance_to(prev);
					prev = pt.position;
					if (arc_dist > lookahead) break;  // beyond immediate re-eval horizon
					const float sdf = map->get_distance(pt.position.x, pt.position.y);
					if (sdf < hard_clearance) { terrain_blocked = true; break; }
					if (sdf < soft_clearance && sdf < soft_min_sdf) soft_min_sdf = sdf;
				}
			}
			if (terrain_blocked) { steering_terrain_rejects++; continue; }

			// Nav score: time until bow (forward) or stern (reverse) aligns with target.heading.
			// For reverse candidates the effective heading is bow + π — the direction
			// the ship will present when it switches back to forward drive.
			float effective_target_h = (cand_throttle < 0)
				? normalize_angle(target.heading + static_cast<float>(Math_PI))
				: target.heading;
			float nav_score = std::numeric_limits<float>::infinity();
			for (const auto &pt : arc) {
				if (std::abs(angle_difference(pt.heading, effective_target_h)) < heading_align_thresh) {
					nav_score = pt.time;
					break;
				}
			}
			if (nav_score == std::numeric_limits<float>::infinity()) {
				// Did not align within arc — penalise by residual heading error
				float h_err = std::abs(angle_difference(arc.back().heading, effective_target_h));
				nav_score = arc.back().time + (h_err / static_cast<float>(Math_PI)) * 60.0f;
			}

			// Obstacle collision penalty (part of nav cost)
			bool obs_col = false;
			ObstacleCollisionInfo obs_info = check_arc_obstacles_detailed(arc);
			if (obs_info.has_collision && !obs_info.is_torpedo) {
				Vector2 to_obs = obs_info.obstacle_position - state.position;
				if (to_obs.length() > 0.1f && our_fwd.dot(to_obs.normalized()) > 0.3f) {
					float urgency = std::min(1.0f, 10.0f / std::max(obs_info.time_to_collision, 1.0f));
					nav_score += urgency * 60.0f;
					obs_col = true;
				}
			}

			ThreatEval threats = score_arc_shell_threat(arc);

			// Soft terrain penalty: prefer arcs that stay outside soft_clearance
			// when the ship is currently outside it.  When already inside
			// (e.g. spawned near terrain), all arcs share the same starting
			// position so suppress the penalty to avoid non-discriminating inflation.
			if (sdf_here >= soft_clearance && soft_min_sdf < soft_clearance) {
				const float pen_t = 1.0f - clamp_f(
					(soft_min_sdf - hard_clearance) / std::max(soft_clearance - hard_clearance, 1.0f),
					0.0f, 1.0f);
				nav_score += pen_t * SOFT_TERRAIN_PENALTY;
			}

			if (n_pass < MAX_PASS_ENTRIES)
				pass_data[n_pass++] = { cand_rudder, cand_throttle, nav_score, threats, obs_col };

		} else {
			// ---- Normal: predict_arc_to_heading + arrival/alignment scoring ----
			auto arc = predict_arc_to_heading(cand_rudder, cand_throttle, wp_target,
			                                   sim_lookahead, sim_max_time);
			if (arc.size() < 2) { steering_short_arc_rejects++; continue; }
			steering_candidates_simulated++;
			steering_arc_points_simulated += static_cast<int>(arc.size());

			// Terrain check with waypoint-arrival early stop.
			// Also track minimum SDF for the soft-terrain penalty below.
			bool  terrain_blocked = false;
			float arrival_time    = -1.0f;
			float soft_min_sdf    = std::numeric_limits<float>::infinity();
			if (map.is_valid() && map->is_built()) {
				for (const auto &pt : arc) {
					if (pt.position.distance_to(wp_target) < wp_reach_radius) {
						arrival_time = pt.time;
						break;
					}
					const float sdf = map->get_distance(pt.position.x, pt.position.y);
					if (sdf < hard_clearance) { terrain_blocked = true; break; }
					if (sdf < soft_clearance && sdf < soft_min_sdf) soft_min_sdf = sdf;
				}
			}
			if (terrain_blocked) { steering_terrain_rejects++; continue; }

			// Nav score: arrival or alignment time + estimated travel
			float nav_score;
			if (arrival_time >= 0.0f) {
				nav_score = arrival_time;
			} else {
				const float alignment_time = arc.back().time;
				// Closest approach to waypoint across the full arc (prevents tie on overshoot)
				float endpoint_dist = arc.back().position.distance_to(wp_target);
				for (const auto &pt : arc) {
					float d = pt.position.distance_to(wp_target);
					if (d < endpoint_dist) endpoint_dist = d;
				}
				// Reverse candidates: score remaining travel at forward speed
				// (ship will switch to forward after bow-alignment).
				const float endpoint_speed = (cand_throttle < 0)
					? throttle_to_speed(3)
					: std::abs(arc.back().speed);
				nav_score = alignment_time + endpoint_dist / std::max(endpoint_speed, 1.0f);
			}

			// Heading-weight blend
			if (has_heading_weight) {
				float heading_align_time = std::numeric_limits<float>::infinity();
				for (const auto &hpt : arc) {
					Vector2 to_hvp = heading_vp - hpt.position;
					if (to_hvp.length() > 1.0f) {
						float desired_h = std::atan2(to_hvp.x, to_hvp.y);
						if (std::abs(angle_difference(hpt.heading, desired_h)) < heading_align_thresh) {
							heading_align_time = hpt.time;
							break;
						}
					}
				}
				if (heading_align_time == std::numeric_limits<float>::infinity()) {
					Vector2 to_hvp = heading_vp - arc.back().position;
					if (to_hvp.length() > 1.0f) {
						float desired_h = std::atan2(to_hvp.x, to_hvp.y);
						float h_err = std::abs(angle_difference(arc.back().heading, desired_h));
						heading_align_time = arc.back().time + (h_err / static_cast<float>(Math_PI)) * 60.0f;
					} else {
						heading_align_time = arc.back().time;
					}
				}
				nav_score = lerp_f(nav_score, heading_align_time, target.heading_weight);
			}

			// Exit-heading penalty
			if (apply_exit_penalty) {
				float arrival_h;
				if (arrival_time >= 0.0f) {
					float h_at_wp = arc.back().heading;
					for (const auto &pt : arc) {
						if (pt.position.distance_to(wp_target) < wp_reach_radius) { h_at_wp = pt.heading; break; }
					}
					arrival_h = (cand_throttle < 0)
						? normalize_angle(h_at_wp + static_cast<float>(Math_PI))
						: h_at_wp;
				} else {
					Vector2 d_wp = wp_target - arc.back().position;
					arrival_h = (d_wp.length() > 1.0f) ? std::atan2(d_wp.x, d_wp.y) : arc.back().heading;
				}
				const float exit_err = std::abs(angle_difference(arrival_h, desired_exit_heading));
				const float fwd_speed = std::max(throttle_to_speed(4), 1.0f);
				const float half_tc = (static_cast<float>(Math_PI) * params.turning_circle_radius) / fwd_speed;
				nav_score += (exit_err / static_cast<float>(Math_PI)) * half_tc;
			}

			// Obstacle collision penalty (part of nav cost)
			bool obs_col = false;
			ObstacleCollisionInfo obs_info = check_arc_obstacles_detailed(arc);
			if (obs_info.has_collision && !obs_info.is_torpedo) {
				Vector2 to_obs = obs_info.obstacle_position - state.position;
				if (to_obs.length() > 0.1f && our_fwd.dot(to_obs.normalized()) > 0.3f) {
					float urgency = std::min(1.0f, 10.0f / std::max(obs_info.time_to_collision, 1.0f));
					nav_score += urgency * 60.0f;
					obs_col = true;
				}
			}

			ThreatEval threats = score_arc_shell_threat(arc);

			// Soft terrain penalty: same logic as the wp_is_virtual branch.
			if (sdf_here >= soft_clearance && soft_min_sdf < soft_clearance) {
				const float pen_t = 1.0f - clamp_f(
					(soft_min_sdf - hard_clearance) / std::max(soft_clearance - hard_clearance, 1.0f),
					0.0f, 1.0f);
				nav_score += pen_t * SOFT_TERRAIN_PENALTY;
			}

			if (n_pass < MAX_PASS_ENTRIES)
				pass_data[n_pass++] = { cand_rudder, cand_throttle, nav_score, threats, obs_col };
		}
	} // end candidate loop

	// =========================================================
	// Terrain-blocked fallback
	// If every candidate was disqualified by terrain, choose the
	// one whose arc reaches the highest minimum SDF.
	// =========================================================
	if (n_pass == 0) {
		float least_bad_sdf = -std::numeric_limits<float>::infinity();
		for (int i = 0; i < n_candidates; ++i) {
			auto arc = predict_arc_internal(candidates[i].rudder, candidates[i].throttle, lookahead);
			if (arc.empty()) continue;
			steering_candidates_simulated++;
			steering_arc_points_simulated += static_cast<int>(arc.size());
			float min_sdf = std::numeric_limits<float>::infinity();
			if (map.is_valid() && map->is_built()) {
				for (const auto &pt : arc) {
					float sdf = map->get_distance(pt.position.x, pt.position.y);
					if (sdf < min_sdf) min_sdf = sdf;
				}
			}
			if (min_sdf > least_bad_sdf) {
				least_bad_sdf   = min_sdf;
				result.rudder   = candidates[i].rudder;
				result.throttle = candidates[i].throttle;
				winning_arc = std::move(arc);
			}
		}
		result.collision_imminent = true;
		perf_last_steering_candidates_total_     = steering_candidates_total;
		perf_last_steering_candidates_simulated_ = steering_candidates_simulated;
		perf_last_steering_terrain_rejects_      = steering_terrain_rejects;
		perf_last_steering_short_arc_rejects_    = steering_short_arc_rejects;
		perf_last_steering_arc_points_simulated_ = steering_arc_points_simulated;
		return result;
	}

	// =========================================================
	// Two-pass selection
	// =========================================================
	// Pass 1: best pure-navigation score
	float best_nav = std::numeric_limits<float>::infinity();
	for (int i = 0; i < n_pass; ++i)
		if (pass_data[i].nav_score < best_nav) best_nav = pass_data[i].nav_score;

	// Pass 2: threat budgets
	// Shell budget: how many extra nav-seconds we accept to get a better shell angle.
	//   Zeroed when stuck_override_active_ (ship pushes through shell fire).
	// Torpedo budget: much larger — surviving a torpedo is worth a major detour.
	bool has_torpedoes = false;
	for (const auto &[id, obs] : obstacles)
		if (obs.is_torpedo()) { has_torpedoes = true; break; }

	const float shell_budget   = (shells_safe || stuck_override_active_) ? 0.0f : SHELL_NAV_BUDGET;
	const float torpedo_budget = has_torpedoes ? TORPEDO_NAV_BUDGET : 0.0f;
	const float budget_threshold = best_nav + shell_budget + torpedo_budget;

	// Pre-compute the minimum raw threat among budget-eligible candidates.
	// Normalising to relative scores means the best-achievable threat = 0.
	// When all arcs are hit equally (min > 0, e.g. ship stationary broadside),
	// every relative score is 0 and nav_score becomes the natural tiebreaker —
	// the arc that gets the ship to the destination wins instead of one that
	// merely presents a slightly different angle to the incoming shell.
	float min_shell_eligible = 0.0f;
	float min_torp_eligible  = 0.0f;
	{
		float ms = std::numeric_limits<float>::infinity();
		float mt = std::numeric_limits<float>::infinity();
		for (int i = 0; i < n_pass; ++i) {
			if (pass_data[i].nav_score > budget_threshold) continue;
			if (!stuck_override_active_)
				ms = std::min(ms, pass_data[i].threats.shell_score);
			mt = std::min(mt, pass_data[i].threats.torpedo_score);
		}
		if (ms < std::numeric_limits<float>::infinity()) min_shell_eligible = ms;
		if (mt < std::numeric_limits<float>::infinity()) min_torp_eligible  = mt;
	}

	// Pass 2: pick lowest relative threat within budget, nav_score as tiebreaker.
	int   best_idx        = -1;
	float best_eff_threat = std::numeric_limits<float>::infinity();
	for (int i = 0; i < n_pass; ++i) {
		if (pass_data[i].nav_score > budget_threshold) continue;
		if (pass_data[i].any_obs_collision) any_collision = true;

		// Shell score: suppressed during stuck override; otherwise normalised to
		// best-achievable so that "equally bad" arcs all score 0 here.
		const float shell_t = stuck_override_active_ ? 0.0f
		                    : (pass_data[i].threats.shell_score - min_shell_eligible);
		float eff_threat = shell_t + (pass_data[i].threats.torpedo_score - min_torp_eligible);

		// Commitment bias: penalise candidates opposing the committed dodge direction,
		// but only when this arc is strictly worse than the minimum-threat arc.
		if (dodge_committed_rudder_ != 0.0f && eff_threat > 0.0f) {
			if (pass_data[i].rudder * dodge_committed_rudder_ < -0.01f)
				eff_threat += DODGE_COMMITMENT_BIAS;
		}

		// Primary criterion: lowest relative threat.
		// Tiebreaker (within floating-point noise): lowest nav_score.
		const bool better_threat = (eff_threat < best_eff_threat);
		const bool equal_threat  = (!better_threat && eff_threat <= best_eff_threat + 1e-4f);
		const bool better_nav    = (best_idx >= 0 && pass_data[i].nav_score < pass_data[best_idx].nav_score);

		if (better_threat || (equal_threat && better_nav)) {
			best_eff_threat = eff_threat;
			best_idx = i;
		}
	}

	// Safety fallback: best_nav is always within budget, so best_idx should
	// never be -1 when n_pass > 0.  Guard anyway.
	if (best_idx == -1) {
		for (int i = 0; i < n_pass; ++i) {
			if (pass_data[i].nav_score <= best_nav + 1e-3f) { best_idx = i; break; }
		}
	}

	// =========================================================
	// Pure-pursuit baseline gate
	// Only deviate from the navigator's desired rudder when the
	// winning arc offers a meaningful reduction in combined threat.
	// If the improvement over pure pursuit is < PURE_PURSUIT_MIN_IMPROVEMENT
	// (15 %), revert to pure pursuit to avoid unnecessary jinking.
	// Disabled when stuck_override_active_ (nav intent must push through).
	// =========================================================
	if (best_idx != -1 && !stuck_override_active_ && !shells_safe) {
		// Find pass_data entry that matches the pure-pursuit candidate
		// (desired_rudder, desired_throttle).  It is always added first as
		// rudder_offsets[0] == 0, so the closest-rudder match at the right
		// throttle will be it.
		int pp_idx = -1;
		float pp_rudder_diff = std::numeric_limits<float>::infinity();
		for (int i = 0; i < n_pass; ++i) {
			if (pass_data[i].throttle != desired_throttle) continue;
			const float diff = std::abs(pass_data[i].rudder - desired_rudder);
			if (diff < pp_rudder_diff) { pp_rudder_diff = diff; pp_idx = i; }
		}
		if (pp_idx != -1 && best_idx != pp_idx) {
			const float pp_threat  = pass_data[pp_idx].threats.combined();
			const float win_threat = pass_data[best_idx].threats.combined();
			// Only gate when pure pursuit actually has a non-trivial threat score.
			// When pp_threat == 0 both arcs are equally safe and nav score already
			// governs, so no gating is needed.
			if (pp_threat > 1e-4f) {
				const float improvement = (pp_threat - win_threat) / pp_threat;
				if (improvement < PURE_PURSUIT_MIN_IMPROVEMENT)
					best_idx = pp_idx;
			}
		}
	}

	result.rudder   = pass_data[best_idx].rudder;
	result.throttle = pass_data[best_idx].throttle;

	// Re-simulate winning arc for visualization
	winning_arc = predict_arc_internal(result.rudder, result.throttle, sim_lookahead);

	result.collision_imminent = any_collision
		|| (result.rudder   != desired_rudder)
		|| (result.throttle != desired_throttle);

	perf_last_steering_candidates_total_     = steering_candidates_total;
	perf_last_steering_candidates_simulated_ = steering_candidates_simulated;
	perf_last_steering_terrain_rejects_      = steering_terrain_rejects;
	perf_last_steering_short_arc_rejects_    = steering_short_arc_rejects;
	perf_last_steering_arc_points_simulated_ = steering_arc_points_simulated;

	// --- Update dodge commitment ---
	// threats_active: mirrors the shells_safe reachability check so that
	// non-threatening shells (landing too far to reach) do not prevent the
	// commitment timer from clearing.
	bool threats_active = !shells_safe;
	if (!threats_active)
		for (const auto &[id, obs] : obstacles)
			if (obs.is_torpedo()) { threats_active = true; break; }

	if (threats_active && std::abs(result.rudder - desired_rudder) > 0.1f) {
		float rudder_sign = (result.rudder > 0.0f) ? 1.0f : -1.0f;
		if (dodge_committed_rudder_ == 0.0f || rudder_sign == dodge_committed_rudder_) {
			dodge_committed_rudder_ = rudder_sign;
			dodge_commitment_timer_ = DODGE_COMMITMENT_DURATION;
		}
	} else if (!threats_active) {
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

	// Simulate at the commanded rudder until the bow aligns with the direction
	// to target_pos, then stop.  Remaining travel is estimated analytically in
	// select_best_steering (endpoint_dist / speed).  The post-alignment straight
	// segment was removed: it rarely passed accurately through the waypoint
	// (5° threshold leaves a residual cross-track error), so both left- and
	// right-turn candidates landed at nearly identical endpoint distances and
	// produced frame-to-frame oscillation.
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

			// Check alignment at emit points only (atan2 is expensive).
			// Stop as soon as the bow points at the target — the scoring in
			// select_best_steering estimates the remaining travel analytically.
			if (rudder_settled) {
				Vector2 to_target = target_pos - sim_pos;
				if (to_target.length() > 1.0f) {
					float desired_heading = std::atan2(to_target.x, to_target.y);
					float heading_error = std::abs(angle_difference(sim_heading, desired_heading));
					if (heading_error < alignment_threshold) {
						break;
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
		// --- Near-180° stability fix ---
		// When abs_effective_diff is near ±π the sign of effective_diff is
		// unreliable: a sub-ULP perturbation in the ship's position flips
		// angle_difference() between +π and −π, causing the rudder to
		// alternate between −1 and +1 every frame (net ≈ 0, so the ship
		// drives straight away from the target).
		// Use state continuity as tiebreaker: current_rudder → angular
		// velocity → deterministic default.
		// Convention: negative rudder = right turn = positive angular_velocity_y.
		constexpr float near_pi_threshold = static_cast<float>(Math_PI * 0.85);
		if (abs_effective_diff > near_pi_threshold) {
			if (std::abs(state.current_rudder) > 0.05f) {
				rudder = (state.current_rudder < 0.0f) ? -1.0f : 1.0f;
			} else if (std::abs(state.angular_velocity_y) > 0.001f) {
				rudder = (state.angular_velocity_y > 0.0f) ? -1.0f : 1.0f;
			} else {
				rudder = -1.0f;  // deterministic default: start a right turn
			}
		} else {
			rudder = (effective_diff > 0.0f) ? -1.0f : 1.0f;
		}
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

	// "Passed" check: waypoint is behind the ship AND we passed close to it.
	// The cross-track distance (perpendicular offset from the ship's track line)
	// must also be within reach_radius.  Without this guard, a waypoint that is
	// far away but almost perpendicular (barely behind the ship's equator) would
	// be wrongly marked as reached — causing the path to be consumed prematurely
	// and leaving the ship with no waypoints to steer toward.
	if (along_track < 0.0f && dist < reach_radius * 2.0f) {
		// cross_track = perpendicular distance from waypoint to ship's heading line
		float cross_track = std::abs(to_wp.x * forward.y - to_wp.y * forward.x);
		return cross_track < reach_radius;
	}

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
