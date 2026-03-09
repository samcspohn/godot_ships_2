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
	NavMode nav_mode;
	NavState nav_state;

	// --- Navigation targets ---
	Vector2 target_position;         // for POSITION, POSE modes
	float target_heading;            // for ANGLE, POSE, STATION_KEEP modes
	Vector3 station_center;          // for STATION_KEEP mode
	float station_radius;            // for STATION_KEEP mode
	float station_preferred_heading; // for STATION_KEEP mode

	// --- Path data (SINGLE source of truth) ---
	PathResult current_path;          // From NavigationMap::find_path_internal
	int current_wp_index;             // Index into current_path.waypoints
	bool path_valid;
	float path_recalc_cooldown;       // Seconds remaining before allowing recalc
	static constexpr float PATH_RECALC_COOLDOWN = 0.5f;

	// --- Path reuse thresholds ---
	static constexpr float PATH_REUSE_ABSOLUTE_THRESHOLD = 500.0f;
	static constexpr float PATH_REUSE_RELATIVE_FRACTION = 0.15f;

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

	// --- Station-keeping timers ---
	float station_settle_timer;
	float station_hold_timer;
	static constexpr float STATION_SETTLE_TIME = 3.0f;
	static constexpr float STATION_HEADING_TOLERANCE = 0.2618f; // ~15 degrees
	static constexpr float STATION_SPEED_THRESHOLD = 2.0f;      // m/s

	// --- Internal methods ---

	// Hard clearance: beam/2 + safety. Ship MUST not violate this.
	float get_ship_clearance() const;

	// Soft clearance: preferred distance from land — turning_circle/2.
	float get_soft_clearance() const;

	// Safety margin for arc prediction
	float get_safety_margin() const;

	// Compute the lookahead distance for arc prediction (in meters).
	// Scales with ship size — always at least 3× ship length.
	float get_lookahead_distance() const;

	// Compute the stopping distance at current speed
	float get_stopping_distance() const;

	// Convert a throttle level to target speed (m/s)
	float throttle_to_speed(int throttle) const;

	// --- Arc prediction ---

	// Forward-simulate the ship trajectory for a given rudder and throttle.
	std::vector<ArcPoint> predict_arc_internal(float commanded_rudder, int commanded_throttle,
											   float lookahead_distance, float max_time = 30.0f) const;

	// Forward-simulate a turn arc at any rudder value until the ship's
	// heading is tangentially aligned toward target_pos (i.e. heading
	// points at the waypoint).  The arc distance is capped at the minimum
	// turning circle perimeter (2*PI*turning_circle_radius) — if alignment
	// hasn't been reached within one full revolution it won't happen.
	// Works with any rudder value; partial rudder traces a wider arc but
	// the perimeter cap keeps simulation bounded.
	std::vector<ArcPoint> predict_arc_to_heading(float commanded_rudder, int commanded_throttle,
												 Vector2 target_pos, float lookahead_distance,
												 float max_time = 60.0f) const;

	// Get the current steer target (waypoint or final destination) for use
	// in tangential-alignment arc prediction.  Returns zero vector if no
	// valid target exists.
	Vector2 get_steer_target() const;

	// Check a predicted arc against the SDF for collisions.
	float check_arc_collision(const std::vector<ArcPoint> &arc,
							  float hard_clearance, float soft_clearance) const;

	// Check a predicted arc against dynamic obstacles (simple version)
	float check_arc_obstacles(const std::vector<ArcPoint> &arc) const;

	// Check a predicted arc against dynamic obstacles (detailed version)
	ObstacleCollisionInfo check_arc_obstacles_detailed(const std::vector<ArcPoint> &arc) const;

	// Determine if we are the give-way vessel (COLREGS + size priority)
	bool is_give_way_vessel(const ObstacleCollisionInfo &info) const;

	// --- Steering pipeline helpers ---

	// Compute desired rudder to steer toward a world XZ position.
	// When reverse=true, computes rudder to back the stern toward the target.
	float compute_rudder_to_position(Vector2 target_pos, bool reverse = false) const;

	// Compute desired rudder to acquire a heading, with rudder lead compensation
	float compute_rudder_to_heading(float desired_heading) const;

	// Compute desired throttle based on distance to destination
	int compute_throttle_for_approach(float distance_to_target) const;

	// Select the best collision-free rudder from candidates.
	// Returns the chosen rudder value, or sets emergency if nothing works.
	float select_safe_rudder(float desired_rudder, int desired_throttle,
							 float &out_ttc, bool &out_collision);

	// Apply SDF gradient repulsion bias to rudder
	float apply_gradient_bias(float rudder) const;

	// --- Waypoint following ---

	// Advance to the next waypoint if we've reached the current one
	void advance_waypoint();

	// Check if a waypoint has been reached (along-track + distance check)
	bool is_waypoint_reached(Vector2 waypoint) const;

	// Check if a waypoint is inside either of the ship's turning circles
	// (port or starboard). A point inside these circles is geometrically
	// unreachable — the ship cannot turn tightly enough to reach it and
	// will orbit indefinitely. The two circle centers sit perpendicular
	// to the ship's heading at ±turning_circle_radius from the ship position.
	bool is_waypoint_in_turning_dead_zone(Vector2 waypoint) const;

	// Get dynamic reach radius based on speed and turning radius
	float get_reach_radius() const;

	// --- Path management ---

	// Request a path recalculation with tiered clearance fallback
	void maybe_recalc_path(Vector2 destination);

	// Check whether a destination shift is small enough to reuse the existing path
	bool is_destination_shift_small(Vector2 old_target, Vector2 new_target) const;

	// --- Navigation mode implementations ---

	// Position navigation: move toward target, follow path
	void update_navigate_to_position();

	// Angle navigation: acquire target heading with rudder lead
	void update_navigate_to_angle();

	// Pose navigation: arrive at position with specific heading
	void update_navigate_to_pose();

	// Station keeping: hold position within zone
	void update_station_keep(float delta);

	// --- Steering output helpers ---

	// Write steering output from computed values
	void set_steering_output(float rudder, int throttle, bool collision, float ttc);

	// Update the predicted arc cache for debug visualization
	void update_predicted_arc();

protected:
	static void _bind_methods();

public:
	ShipNavigator();
	~ShipNavigator();

	// --- Setup ---

	// Set the shared NavigationMap reference
	void set_map(Ref<NavigationMap> p_map);

	// Set ship kinematic parameters (from ShipMovementV4 exported properties)
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

	// Must be called every physics frame before any navigation calls.
	// Runs the full steering pipeline: plan → steer → check → react → speed → output.
	void set_state(
		Vector3 position,
		Vector3 velocity,
		float heading,
		float angular_velocity_y,
		float current_rudder,
		float current_speed
	);

	// --- Navigation commands ---

	// Navigate to a world position (pathfinds around islands)
	void navigate_to_position(Vector3 target);

	// Acquire a specific heading (no position target)
	void navigate_to_angle(float p_target_heading);

	// Arrive at a position facing a specific direction
	void navigate_to_pose(Vector3 target, float p_target_heading);

	// Hold position within a circular zone at a preferred heading
	void station_keep(Vector3 center, float radius, float preferred_heading);

	// Cancel navigation, coast to stop
	void stop();

	// --- Output (read after set_state runs the steering pipeline) ---

	// Get the commanded rudder value [-1.0, 1.0]
	float get_rudder() const;

	// Get the commanded throttle level [-1, 4]
	int get_throttle() const;

	// Get the current navigation state as int (cast from NavState enum)
	int get_nav_state() const;

	// Check if collision avoidance is currently active
	bool is_collision_imminent() const;

	// Get time in seconds until predicted collision (INF if none)
	float get_time_to_collision() const;

	// --- Dynamic obstacles ---

	// Register another ship as a dynamic obstacle
	void register_obstacle(int id, Vector2 position, Vector2 velocity, float radius, float length);

	// Update position/velocity of a registered obstacle
	void update_obstacle(int id, Vector2 position, Vector2 velocity);

	// Remove a registered obstacle
	void remove_obstacle(int id);

	// Remove all obstacles
	void clear_obstacles();

	// --- Path / trajectory info ---

	// Get the current planned path as Vector3 array (Y=0)
	PackedVector3Array get_current_path() const;

	// Get the predicted trajectory from current steering as Vector3 array (Y=0)
	PackedVector3Array get_predicted_trajectory() const;

	// Get the current target waypoint as Vector3 (Y=0)
	Vector3 get_current_waypoint() const;

	// --- Debug info ---

	// Get the heading the navigator is trying to achieve (radians)
	float get_desired_heading() const;

	// Get the straight-line distance to the final destination
	float get_distance_to_destination() const;

	// Get a human-readable debug string with current state info
	String get_debug_info() const;

	// Get the current navigation mode as int
	int get_nav_mode() const;

	// Get the hard clearance radius for debug visualization
	float get_clearance_radius() const { return get_ship_clearance(); }

	// Get the soft clearance radius for debug visualization
	float get_soft_clearance_radius() const { return get_soft_clearance(); }

	// --- Backward-compatible API stubs ---

	// validate_destination_pose: simplified — just ensures destination is navigable.
	// No longer does multi-heading physics simulation. Returns Dictionary with
	// keys: position (Vector3), heading (float), valid (bool), adjusted (bool).
	Dictionary validate_destination_pose(Vector3 ship_position, Vector3 candidate);

	// Get the dense simulated path — returns arc prediction points for debug.
	// (Forward simulation was removed; this returns the short-range predicted arc.)
	PackedVector3Array get_simulated_path() const;

	// Always returns true (no incremental simulation to wait for).
	bool is_simulation_complete() const;
};

} // namespace godot

#endif // SHIP_NAVIGATOR_H