#ifndef SHIP_NAVIGATOR_H
#define SHIP_NAVIGATOR_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <vector>
#include <unordered_map>
#include <cstdint>
#include <cmath>
#include <limits>

#include "nav_types.h"
#include "navigation_map.h"
#include "hpa_graph.h"
#include "threat_registry.h"

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

	// --- Emergency mode state ---
	Vector2 emergency_grounding_pos;   // position when emergency mode was entered
	bool emergency_initialized;        // true once grounding pos has been recorded

	// --- Bot identity (for staggered replanning) ---
	int bot_id_;
	static constexpr int REPLAN_STAGGER_FRAMES = 6;
	uint64_t nav_update_tick_ = 0;

	// --- Path data (SINGLE source of truth) ---
	PathResult current_path;          // From NavigationMap::find_path_internal
	int current_wp_index;             // Index into current_path.waypoints
	bool path_valid;

	// --- HPA* (Hierarchical A*) pathfinding ---
	// When set, strategic path planning uses hierarchical A* for fast
	// threat-aware routing.  Dynamic obstacles are forwarded to hpa_graph_
	// for cluster-level blocking, giving O(clusters) updates instead of O(nodes).
	Ref<HpaGraph> hpa_graph_;







	enum class DesiredDirection : int {
		FORWARD = 0,
		BACKWARD = 1,
	};

	enum class PlanPhase : int {
		IDLE = 0,
		COMPUTING = 1,   // reserved (unused since HPA* is always synchronous)
		DONE = 2,        // result ready, accept on next tick
	};

	PlanPhase plan_phase;
	PathResult plan_forward_result;
	float plan_min_clearance;
	float plan_comfortable_clearance;

	// --- Replan trigger (event-driven, not timer-based) ---
	bool replan_requested_;

	// --- Steering output ---
	float out_rudder;
	int out_throttle;
	bool out_collision_imminent;

	// --- Timing instrumentation (microseconds, last frame) ---
	float timing_update_us;
	float timing_avoidance_us;
	float timing_plan_us;
	float timing_steering_us;
	int timing_replan_reason;  // 0=none, 1=requested, 2=no_path, 3=deviated, 4=ticking, 5=stagger_wait
	int timing_plan_phase_val; // current PlanPhase as int

	// --- Runtime performance aggregates (spike-oriented) ---
	uint64_t perf_frame_count_;
	float perf_spike_threshold_us_;
	float perf_report_interval_s_;
	float perf_report_accum_s_;
	bool perf_tracking_enabled_ = false;

	static constexpr int PERF_SPIKE_PHASE_COUNT = 6;
	uint64_t perf_phase_count_[PERF_SPIKE_PHASE_COUNT];
	float perf_phase_avg_update_us_[PERF_SPIKE_PHASE_COUNT];
	float perf_phase_avg_plan_us_[PERF_SPIKE_PHASE_COUNT];
	float perf_phase_avg_avoidance_us_[PERF_SPIKE_PHASE_COUNT];
	float perf_phase_avg_steering_us_[PERF_SPIKE_PHASE_COUNT];

	uint64_t perf_window_frame_count_;
	float perf_window_update_sum_us_;
	float perf_window_plan_sum_us_;
	float perf_window_avoidance_sum_us_;
	float perf_window_steering_sum_us_;

	float perf_avg_update_us_;
	float perf_avg_plan_us_;
	float perf_avg_avoidance_us_;
	float perf_avg_steering_us_;

	float perf_max_update_us_;
	float perf_max_plan_us_;
	float perf_max_avoidance_us_;
	float perf_max_steering_us_;

	uint64_t perf_update_spike_count_;
	uint64_t perf_plan_spike_count_;
	uint64_t perf_avoidance_spike_count_;
	uint64_t perf_steering_spike_count_;

	float perf_worst_update_spike_us_;
	float perf_worst_plan_spike_us_;
	float perf_worst_avoidance_spike_us_;
	float perf_worst_steering_spike_us_;

	int perf_last_steering_candidates_total_;
	int perf_last_steering_candidates_simulated_;
	int perf_last_steering_terrain_rejects_;
	int perf_last_steering_short_arc_rejects_;
	int perf_last_steering_arc_points_simulated_;

	// --- Debug visualization: the actual simulated arc that won scoring ---
	std::vector<ArcPoint> winning_arc;

	// --- Dynamic obstacles ---
	std::unordered_map<int, DynamicObstacle> obstacles;

	// --- Steering choice (output of select_best_steering) ---
	struct SteeringChoice {
		float rudder;
		int throttle;
		bool collision_imminent; // true if any threat was detected
	};

	// --- Parked-ship obstacle filter ---
	// When true, check_arc_obstacles_detailed skips non-torpedo obstacles.
	// Set at the start of select_best_steering when the ship is effectively
	// stationary (speed < threshold, desired throttle <= 0).  A parked ship
	// holding position should not dodge approaching friendlies — the moving
	// ship is the give-way vessel.
	bool skip_ship_obstacles_;

	// --- Health fraction for dynamic threat weighting ---
	float health_fraction_;  // 0.0 = dead, 1.0 = full HP

	// --- Dodge commitment (hysteresis to prevent oscillation) ---
	// When threats are active and the ship picks a dodge direction, it commits
	// to that direction for a minimum time.  This prevents symmetric threats
	// (shells arriving perpendicular to heading) from causing frame-to-frame
	// rudder oscillation between port and starboard.
	float dodge_committed_rudder_;   // rudder sign of committed dodge (-1/+1), 0 = no commitment
	float dodge_commitment_timer_;   // seconds remaining in commitment
	static constexpr float DODGE_COMMITMENT_DURATION = 0.5f;   // minimum seconds to hold a dodge direction
	static constexpr float DODGE_COMMITMENT_BIAS     = 150.0f;  // threat-score penalty added to candidates opposing committed direction

	// --- Two-pass threat budgets ---
	// Budgets are in navigation-seconds: how many extra seconds of travel time
	// we are willing to accept in order to improve the threat score.
	// Shells nudge heading; torpedoes justify a major detour.
	static constexpr float SHELL_NAV_BUDGET     = 50.0f;   // extra nav-seconds for better shell angle
	static constexpr float TORPEDO_NAV_BUDGET   = 500.0f;  // extra nav-seconds for torpedo evasion
	static constexpr float SHELL_TIME_TOLERANCE = 2.0f;    // floor for eff_tol in score_arc_shell_threat (seconds); arc sampling density drives the real value
	static constexpr float SOFT_TERRAIN_PENALTY = 15.0f;   // nav-seconds added when an arc enters the soft-clearance zone (nudge, not disqualification)

	// --- Stuck / bow-in detection ---
	// Accumulated when the navigator wants reverse (destination is behind) but
	// threat scoring keeps choosing forward candidates.  Once the threshold
	// (scaled by the ship's turning-circle time) is exceeded, a stuck-override
	// activates: shell threats are suppressed in the budget so the ship can
	// push through and execute the needed reverse maneuver.  Torpedo threats
	// still apply during the override — the ship accepts shell risk, not torpedo risk.
	static constexpr float STUCK_TCR_FACTOR      = 0.25f;  // threshold = max(STUCK_MIN, π*TCR/max_speed * this)
	static constexpr float STUCK_MIN_SECS        = 5.0f;   // minimum conflict seconds before override triggers
	static constexpr float STUCK_OVERRIDE_FACTOR = 0.20f;  // override_duration = max(STUCK_OVERRIDE_MIN, π*TCR/max_speed * this)
	static constexpr float STUCK_OVERRIDE_MIN    = 4.0f;   // minimum override duration (seconds)

	float direction_conflict_timer_;   // seconds nav wanted reverse but threat chose forward
	bool  stuck_override_active_;      // when true, shell threat budget is zeroed
	float stuck_override_timer_;       // seconds remaining in the current stuck override

	// --- Heading-align direction commitment ---
	// When the ship is inside arrived_radius and aligning to target heading,
	// lock FORWARD/BACKWARD until the ship has traveled ALIGN_BOUNCE_RADIUS from
	// the position where the direction was chosen.  This lets each stroke of a
	// multi-point turn complete before re-evaluating, without being time-based.
	DesiredDirection align_committed_dir_ = DesiredDirection::FORWARD;
	Vector2 align_commit_pos_;
	bool align_commit_active_ = false;
	// Re-evaluate direction once the ship moves this far from the commit point.
	// Sized to ship_beam at runtime; this constant is a fallback.
	static constexpr float ALIGN_BOUNCE_RADIUS_DEFAULT = 30.0f;

	static constexpr float PARKED_SPEED_THRESHOLD = 10.0f;

	// --- Incoming shell avoidance ---
	std::vector<IncomingShell> incoming_shells_;

	// --- Enemy threat arcs (for stealth pathfinding) ---
	// Registered by GDScript when the bot wants to route around enemy
	// detection coverage.  ShipNavigator references a shared ThreatBin
	// owned by a ThreatRegistry; multiple ships with the same (team,
	// binned effective_radius) share the same threat circle list.
	Ref<ThreatRegistry> threat_registry_;
	ThreatBin* threat_bin_ = nullptr;
	uint64_t threat_last_version_ = 0;



	static constexpr float TORPEDO_VIRTUAL_CALIBER    = 2000.0f; // virtual caliber for torpedo threat (mm equivalent)

	// OBB intersection scoring modifiers
	static constexpr float GRAZE_MIN_FACTOR     = 0.15f;   // minimum penalty factor for a dead end-on hit (autobounce floor)
	static constexpr float BOW_STERN_CLIP_START = 0.80f;   // fwd fraction beyond which bow/stern clip reduction kicks in
	static constexpr float BOW_STERN_MIN_FACTOR = 0.30f;   // minimum penalty factor at the extreme hull tip

	// --- Two-pass threat score (returned by score_arc_shell_threat) ---
	struct ThreatEval {
		float shell_score    = 0.0f;  // dimensionless: sum of cal_weight * angle_factor for hitting shells
		float torpedo_score  = 0.0f;  // dimensionless: cal_weight for any torpedo intersection
		float combined() const { return shell_score + torpedo_score; }
	};

	// Evaluate shell + torpedo threats along an arc.
	// Returns separate shell and torpedo scores so the caller can apply
	// different budgets and suppress shells when stuck_override is active.
	ThreatEval score_arc_shell_threat(const std::vector<ArcPoint> &arc) const;

	float get_dynamic_threat_weight() const;

	// --- Debug: torpedo virtual threat points ---
	Array get_debug_torpedo_threat_points() const;

	// --- Internal methods ---

	float get_ship_clearance() const;
	float get_soft_clearance() const;
	float get_safety_margin() const;
	float get_lookahead_distance() const;
	float get_stopping_distance() const;
	float throttle_to_speed(int throttle) const;

	// --- Arc prediction ---
	// Both functions emit arc sample points spaced by get_ship_clearance().

	std::vector<ArcPoint> predict_arc_internal(float commanded_rudder, int commanded_throttle,
											   float lookahead_distance) const;

	std::vector<ArcPoint> predict_arc_to_heading(float commanded_rudder, int commanded_throttle,
												 Vector2 target_pos, float lookahead_distance,
												 float max_time = 60.0f) const;

	float check_arc_collision(const std::vector<ArcPoint> &arc,
							  float hard_clearance, float soft_clearance) const;

	float check_arc_obstacles(const std::vector<ArcPoint> &arc) const;

	ObstacleCollisionInfo check_arc_obstacles_detailed(const std::vector<ArcPoint> &arc) const;

	// --- Steering pipeline helpers ---

	float compute_rudder_to_position(Vector2 target_pos, bool reverse = false) const;
	float compute_rudder_to_heading(float desired_heading, bool reverse = false) const;
	int compute_magnitude_for_approach(float distance_to_target) const;
	int resolve_throttle(DesiredDirection dir, int magnitude) const;

	// --- Simplified avoidance (replaces select_safe_rudder) ---
	SteeringChoice select_best_steering(float desired_rudder, int desired_throttle);

	// --- Waypoint following ---

	void advance_waypoint();
	bool is_waypoint_reached(Vector2 waypoint) const;
	bool is_waypoint_in_turning_dead_zone(Vector2 waypoint) const;
	float get_reach_radius() const;

	// --- Pure pursuit steering ---
	float compute_pure_pursuit_rudder() const;

	// --- Direction determination ---
	bool is_target_behind_within_reverse_zone(Vector2 target_pos) const;

	// --- Path management ---

	void accept_plan_result(const PathResult &forward_result);

	// --- Two-state update methods ---

	void update(float delta);
	void update_normal(float delta);
	void update_emergency(float delta);

	// --- Plan management ---
	void start_plan();       // runs HPA* planning
	void tick_plan();        // (stub) D* Lite removed
	void run_plan_sync();    // runs HPA* planning synchronously

	// HPA* incremental repair — handles threat changes
	void hpa_incremental_update();

	// --- Steering output helpers ---

	void set_steering_output(float rudder, int throttle, bool collision);

protected:
	static void _bind_methods();

public:
	ShipNavigator();
	~ShipNavigator();

	// --- Setup ---

	void set_map(Ref<NavigationMap> p_map);

	/// Attach a pre-built HpaGraph.  When set, start_plan / run_plan_sync
	/// use hierarchical A*.
	/// Pass an invalid Ref<> to detach.
	void set_hpa_graph(Ref<HpaGraph> graph);
	Ref<HpaGraph> get_hpa_graph() const { return hpa_graph_; }

	void set_ship_params(
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

	void set_bot_id(int id);
	int get_bot_id() const;

	void navigate_to(Vector3 target, float heading, float hold_radius = 0.0f, float heading_tolerance = 0.2618f, float heading_weight = 0.0f);
	void stop();

	// --- Grounded state (from movement controller via BotControllerV4) ---
	void set_grounded(bool grounded);
	bool get_grounded() const;

	void set_health_fraction(float fraction);

	// --- Output ---

	float get_rudder() const;
	int get_throttle() const;
	int get_nav_state() const;
	bool is_collision_imminent() const;

	// --- Dynamic obstacles ---

	void register_obstacle(int id, Vector2 position, Vector2 velocity, float radius, float length);
	void update_obstacle(int id, Vector2 position, Vector2 velocity);
	void remove_obstacle(int id);
	void clear_obstacles();

	// --- Incoming shell avoidance ---
	void clear_incoming_shells();
	void add_incoming_shell(int id, Vector2 landing_pos, float time_remaining, float caliber, Vector2 landing_dir, float threat_half_len);

	// --- Enemy threat avoidance (stealth pathfinding) ---
	// Subscribe this navigator to a (team_id, effective_radius) bin in the
	// shared registry.  Drops any previous subscription.  Pass an invalid
	// Ref<> to unsubscribe (equivalent to clear_threat_source).
	void set_threat_source(Ref<ThreatRegistry> registry, int team_id, float effective_radius);
	void clear_threat_source();

	// --- Path / trajectory info ---

	PackedVector3Array get_current_path() const;
	PackedVector3Array get_predicted_trajectory() const;
	Vector3 get_current_waypoint() const;

	// --- Debug info ---

	float get_desired_heading() const;
	float get_distance_to_destination() const;
	bool is_arrived() const;

	float get_clearance_radius() const { return get_ship_clearance(); }
	float get_soft_clearance_radius() const { return get_soft_clearance(); }

	TypedArray<Dictionary> get_debug_threat_clusters() const;

	// Adjust |dest| away from threat circles (circle+LOS model).
	// Returns Dictionary { position: Vector2, adjusted: bool }.
	// Returns dest unchanged if no bin subscription is active or
	// dest is already outside all threat circles.
	Dictionary adjust_destination_for_threats(Vector2 ship_pos, Vector2 dest) const;

	// --- Timing (microseconds) ---
	float get_timing_update_us() const { return timing_update_us; }
	float get_timing_avoidance_us() const { return timing_avoidance_us; }
	float get_timing_plan_us() const { return timing_plan_us; }
	float get_timing_steering_us() const { return timing_steering_us; }
	int get_timing_replan_reason() const { return timing_replan_reason; }
	int get_timing_plan_phase() const { return timing_plan_phase_val; }

	Dictionary get_perf_metrics() const;
	void reset_perf_metrics();
	void set_perf_spike_threshold_us(float threshold_us);
	float get_perf_spike_threshold_us() const;
	void set_perf_tracking_enabled(bool enabled);
	bool is_perf_tracking_enabled() const;

	// --- Backward-compatible API stubs ---

	PackedVector3Array get_simulated_path() const;
};

} // namespace godot

#endif // SHIP_NAVIGATOR_H
