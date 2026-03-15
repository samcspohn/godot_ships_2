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

	// --- Grounded flag (set by BotControllerV4 from movement controller) ---
	bool grounded_;

	// --- Path data (SINGLE source of truth) ---
	PathResult current_path;          // From NavigationMap::find_path_internal
	int current_wp_index;             // Index into current_path.waypoints
	bool path_valid;

	// --- Pathfinding ---
	static constexpr bool USE_ASYNC_PATHFINDING = true;   // toggle async vs sync
	static constexpr int PLAN_ITER_BUDGET = 20000;        // per-frame budget (async only)
	static constexpr int SYNC_ITER_LIMIT = 50000;         // max iterations (sync only)

	enum class DesiredDirection : int {
		FORWARD = 0,
		BACKWARD = 1,
	};

	enum class PlanPhase : int {
		IDLE = 0,
		FORWARD = 1,
		FALLBACK = 2,
		REVERSE = 3,
		GRID_FALLBACK = 5,
		DONE = 4,
	};

	PlanPhase plan_phase;
	PathSearch path_search;
	PathResult plan_forward_result;
	float plan_min_clearance;
	float plan_comfortable_clearance;

	// --- Replan trigger (event-driven, not timer-based) ---
	bool replan_requested_;

	// --- Constants ---
	static constexpr float PATH_REUSE_ABSOLUTE_THRESHOLD = 500.0f;
	static constexpr float PATH_REUSE_RELATIVE_FRACTION = 0.15f;
	static constexpr float HEADING_TOLERANCE = 0.2618f;
	static constexpr float SPEED_THRESHOLD = 2.0f;

	// --- Steering output ---
	float out_rudder;
	int out_throttle;
	bool out_collision_imminent;
	float out_time_to_collision;

	// --- Timing instrumentation (microseconds, last frame) ---
	float timing_update_us;
	float timing_avoidance_us;
	float timing_plan_us;
	int timing_replan_reason;  // 0=none, 1=requested, 2=no_path, 3=deviated, 4=ticking
	int timing_plan_phase_val; // current PlanPhase as int

	// --- Reactive avoidance ---
	std::vector<ArcPoint> predicted_arc;
	bool predicted_arc_fresh;  // true if predicted_arc was already set this frame

	// --- Dynamic obstacles ---
	std::unordered_map<int, DynamicObstacle> obstacles;

	// --- Avoidance result ---
	struct AvoidanceResult {
		float rudder;         // best avoidance rudder
		float weight;         // 0..1, hard threat only — controls throttle reduction
		float rudder_weight;  // 0..1, includes soft-zone nudge — controls rudder blend
		bool torpedo;         // true if primary threat is a torpedo
		bool reverse;         // true if reversing was chosen as the best avoidance maneuver
	};

	// --- Avoidance throttling ---
	int avoidance_frame_counter;        // counts up each frame
	static constexpr int AVOIDANCE_FULL_INTERVAL = 4;  // full scan every N frames
	AvoidanceResult cached_avoidance;   // last result for reuse between full scans
	bool cached_avoidance_valid;

	// --- Parked-ship obstacle filter ---
	// When true, check_arc_obstacles_detailed skips non-torpedo obstacles.
	// Set at the start of compute_avoidance when the ship is effectively
	// stationary (speed < threshold, desired throttle <= 0).  A parked ship
	// holding position should not dodge approaching friendlies — the moving
	// ship is the give-way vessel.
	bool skip_ship_obstacles_;
	static constexpr float PARKED_SPEED_THRESHOLD = 10.0f;

	// --- Internal methods ---

	float get_ship_clearance() const;
	float get_soft_clearance() const;
	float get_safety_margin() const;
	float get_lookahead_distance() const;
	float get_stopping_distance() const;
	float throttle_to_speed(int throttle) const;
	float get_approach_radius() const;

	// --- Arc prediction ---

	std::vector<ArcPoint> predict_arc_internal(float commanded_rudder, int commanded_throttle,
											   float lookahead_distance, float max_time = 30.0f) const;

	std::vector<ArcPoint> predict_arc_to_heading(float commanded_rudder, int commanded_throttle,
												 Vector2 target_pos, float lookahead_distance,
												 float max_time = 60.0f, float dt_scale = 1.0f) const;

	Vector2 get_steer_target() const;

	float check_arc_collision(const std::vector<ArcPoint> &arc,
							  float hard_clearance, float soft_clearance) const;

	float check_arc_obstacles(const std::vector<ArcPoint> &arc) const;

	ObstacleCollisionInfo check_arc_obstacles_detailed(const std::vector<ArcPoint> &arc) const;

	bool is_give_way_vessel(const ObstacleCollisionInfo &info) const;

	// --- Steering pipeline helpers ---

	float compute_rudder_to_position(Vector2 target_pos, bool reverse = false) const;
	float compute_rudder_to_heading(float desired_heading, bool reverse = false) const;
	int compute_magnitude_for_approach(float distance_to_target) const;
	int resolve_throttle(DesiredDirection dir, int magnitude) const;

	// --- Simplified avoidance (replaces select_safe_rudder) ---
	AvoidanceResult compute_avoidance(float desired_rudder, int desired_throttle);

	// --- Waypoint following ---

	void advance_waypoint();
	bool is_waypoint_reached(Vector2 waypoint) const;
	bool is_waypoint_in_turning_dead_zone(Vector2 waypoint) const;
	float get_reach_radius() const;
	Vector2 find_path_lookahead(float lookahead_dist) const;

	// --- Pure pursuit steering ---
	float compute_pure_pursuit_rudder() const;

	// --- Terrain-aware turn direction selection ---
	// Simulates both turn directions and picks the one that is clear of terrain
	// and reaches alignment with the waypoint. Falls back to pure pursuit if both clear.
	float compute_terrain_aware_rudder() const;

	// --- Direction determination ---
	bool is_target_behind_within_reverse_zone(Vector2 target_pos) const;

	// --- Path management ---

	void accept_plan_result(const PathResult &forward_result);
	bool is_destination_shift_small(Vector2 old_target, Vector2 new_target) const;

	// --- Two-state update methods ---

	void update(float delta);
	void update_normal(float delta);
	void update_emergency(float delta);

	// --- Plan management ---
	void start_plan();       // begins async search (sets plan_phase)
	void tick_plan();        // continues async search
	void run_plan_sync();    // runs full search synchronously

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

	void navigate_to(Vector3 target, float heading, float hold_radius = 0.0f, float heading_tolerance = 0.2618f);
	void stop();

	// --- Grounded state (from movement controller via BotControllerV4) ---
	void set_grounded(bool grounded);
	bool get_grounded() const;

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

	float get_clearance_radius() const { return get_ship_clearance(); }
	float get_soft_clearance_radius() const { return get_soft_clearance(); }

	// --- Timing (microseconds) ---
	float get_timing_update_us() const { return timing_update_us; }
	float get_timing_avoidance_us() const { return timing_avoidance_us; }
	float get_timing_plan_us() const { return timing_plan_us; }
	int get_timing_replan_reason() const { return timing_replan_reason; }
	int get_timing_plan_phase() const { return timing_plan_phase_val; }

	// --- Backward-compatible API stubs ---

	Dictionary validate_destination_pose(Vector3 ship_position, Vector3 candidate);
	PackedVector3Array get_simulated_path() const;
	bool is_simulation_complete() const;

	// --- Kept for BotControllerV4 compat (no-op) ---
	void set_near_terrain(bool enabled);
	bool get_near_terrain() const;
};

} // namespace godot

#endif // SHIP_NAVIGATOR_H
