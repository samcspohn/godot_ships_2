#ifndef SHIP_NAVIGATOR_H
#define SHIP_NAVIGATOR_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <vector>
#include <unordered_map>
#include <cmath>
#include <limits>

#include "nav_types.h"
#include "navigation_map.h"

namespace godot {

class ShipNavigator : public RefCounted {
	GDCLASS(ShipNavigator, RefCounted)

private:
	// --- References ---
	Ref<NavigationMap> map;

	// --- Ship configuration ---
	ShipParams params;

	// --- Live state (updated each frame) ---
	ShipState state;

	// --- Navigation state ---
	NavState nav_state;
	NavTarget target;

	// --- Path data (SINGLE source of truth) ---
	PathResult current_path;          // From NavigationMap::find_path_internal
	int current_wp_index;             // Index into current_path.waypoints
	bool path_valid;

	// --- Timing ---
	float settle_timer;
	float hold_timer;
	float stuck_timer;                // Time at near-zero speed while NAVIGATING
	int replan_frame_cooldown;        // Frame counter, not float timer

	// --- Constants ---
	static constexpr float PATH_REUSE_ABSOLUTE_THRESHOLD = 500.0f;
	static constexpr float PATH_REUSE_RELATIVE_FRACTION = 0.15f;
	static constexpr int   REPLAN_FRAME_COOLDOWN = 30;         // ~0.5s at 60fps — prevents path oscillation
	static constexpr float HEADING_TOLERANCE = 0.2618f;        // ~15 degrees
	static constexpr float SPEED_THRESHOLD = 2.0f;             // m/s
	static constexpr float STUCK_TIME_THRESHOLD = 2.0f;        // seconds at near-zero speed
	static constexpr float REVERSE_DISTANCE_CAP_FACTOR = 2.5f; // max reverse = turning_radius * this

	// --- Steering output ---
	float out_rudder;                 // [-1, 1]
	int out_throttle;                 // [-1, 4]
	bool out_collision_imminent;
	float out_time_to_collision;

	// --- Reactive avoidance ---
	std::vector<ArcPoint> predicted_arc;  // Short-range (~3-5 ship lengths) arc prediction
	AvoidanceState avoidance;

	// --- Dynamic obstacles ---
	std::unordered_map<int, DynamicObstacle> obstacles;

	// --- Internal methods ---

	// Hard clearance: beam/2 + safety. Ship MUST not violate this.
	float get_ship_clearance() const;

	// Soft clearance: preferred distance from land — turning_circle/2.
	float get_soft_clearance() const;

	// Safety margin for arc prediction
	float get_safety_margin() const;

	// Compute the lookahead distance for arc prediction (in meters).
	float get_lookahead_distance() const;

	// Compute the stopping distance at current speed
	float get_stopping_distance() const;

	// Convert a throttle level to target speed (m/s)
	float throttle_to_speed(int throttle) const;

	// Approach radius: distance at which NAVIGATING transitions to ARRIVING
	float get_approach_radius() const;

	// --- Arc prediction ---

	std::vector<ArcPoint> predict_arc_internal(float commanded_rudder, int commanded_throttle,
											   float lookahead_distance, float max_time = 30.0f) const;

	std::vector<ArcPoint> predict_arc_to_heading(float commanded_rudder, int commanded_throttle,
												 Vector2 target_pos, float lookahead_distance,
												 float max_time = 60.0f) const;

	Vector2 get_steer_target() const;

	float check_arc_collision(const std::vector<ArcPoint> &arc,
							  float hard_clearance, float soft_clearance) const;

	float check_arc_obstacles(const std::vector<ArcPoint> &arc) const;

	ObstacleCollisionInfo check_arc_obstacles_detailed(const std::vector<ArcPoint> &arc) const;

	bool is_give_way_vessel(const ObstacleCollisionInfo &info) const;

	// --- Steering pipeline helpers ---

	float compute_rudder_to_position(Vector2 target_pos, bool reverse = false) const;
	float compute_rudder_to_heading(float desired_heading) const;
	int compute_throttle_for_approach(float distance_to_target) const;
	float select_safe_rudder(float desired_rudder, int desired_throttle,
							 float &out_ttc, bool &out_collision);

	// --- Waypoint following ---

	void advance_waypoint();
	bool is_waypoint_reached(Vector2 waypoint) const;
	bool is_waypoint_in_turning_dead_zone(Vector2 waypoint) const;
	float get_reach_radius() const;

	// --- Path management ---

	// Compute path from current position to target (replaces maybe_recalc_path)
	void compute_path();

	// Check whether a destination shift is small enough to reuse the existing path
	bool is_destination_shift_small(Vector2 old_target, Vector2 new_target) const;

	// --- Unified state machine update methods ---

	void update(float delta);
	void update_planning();
	void update_navigating(float delta);
	void update_arriving(float delta);
	void update_settling(float delta);
	void update_holding(float delta);
	void update_emergency();

	// Heading-correction waypoint generation for SETTLING state
	void plan_heading_correction();

	// Estimate clearance in a given direction (for heading correction planning)
	float estimate_room_in_direction(float heading) const;

	// Check if the path needs recomputation
	bool check_replan_needed();

	// Determine if the current waypoint should be followed in reverse
	bool current_waypoint_is_reverse() const;

	// Flag reverse waypoints on a path based on ship heading
	void flag_reverse_departure(PathResult &path, float ship_heading);

	// --- Steering output helpers ---

	void set_steering_output(float rudder, int throttle, bool collision, float ttc);
	void update_predicted_arc();

protected:
	static void _bind_methods();

public:
	ShipNavigator();
	~ShipNavigator();

	// --- Setup ---

	void set_map(Ref<NavigationMap> p_map);

	void set_ship_params(
		float turning_circle_radius,
		float rudder_response_time,
		float acceleration_time,
		float deceleration_time,
		float max_speed,
		float reverse_speed_ratio,
		float ship_length,
		float ship_beam,
		float turn_speed_loss
	);

	// --- Per-frame state update ---

	void set_state(
		Vector3 position,
		Vector3 velocity,
		float heading,
		float angular_velocity_y,
		float current_rudder,
		float current_speed,
		float delta
	);

	// --- Navigation commands ---

	// The single navigation command.
	// target: world position to reach
	// heading: desired heading on arrival (radians, 0 = +Z)
	// hold_radius: 0 = arrive and stop, >0 = station-keep within radius
	void navigate_to(Vector3 target, float heading, float hold_radius = 0.0f);

	// Cancel navigation, coast to stop
	void stop();

	// --- Output ---

	float get_rudder() const;
	int get_throttle() const;
	int get_nav_state() const;
	bool is_collision_imminent() const;
	float get_time_to_collision() const;

	// --- Dynamic obstacles ---

	void register_obstacle(int id, Vector2 position, Vector2 velocity, float radius, float length);
	void update_obstacle(int id, Vector2 position, Vector2 velocity);
	void remove_obstacle(int id);
	void clear_obstacles();

	// --- Path / trajectory info ---

	PackedVector3Array get_current_path() const;
	PackedVector3Array get_predicted_trajectory() const;
	Vector3 get_current_waypoint() const;

	// --- Debug info ---

	float get_desired_heading() const;
	float get_distance_to_destination() const;
	String get_debug_info() const;

	// Get the hard clearance radius for debug visualization
	float get_clearance_radius() const { return get_ship_clearance(); }
	float get_soft_clearance_radius() const { return get_soft_clearance(); }

	// --- Backward-compatible API stubs ---

	Dictionary validate_destination_pose(Vector3 ship_position, Vector3 candidate);
	PackedVector3Array get_simulated_path() const;
	bool is_simulation_complete() const;
};

} // namespace godot

#endif // SHIP_NAVIGATOR_H
