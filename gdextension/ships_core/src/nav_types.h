#ifndef NAV_TYPES_H
#define NAV_TYPES_H

#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <vector>
#include <cmath>
#include <limits>

namespace godot {

// Forward-simulated ship trajectory point (used by short-range arc prediction)
struct ArcPoint {
	Vector2 position;  // XZ world position
	float heading;     // heading at this point (radians, 0 = +Z, π/2 = +X)
	float speed;       // speed at this point (m/s)
	float time;        // time from simulation start (seconds)

	ArcPoint() : position(Vector2()), heading(0.0f), speed(0.0f), time(0.0f) {}
	ArcPoint(Vector2 p_pos, float p_heading, float p_speed, float p_time)
		: position(p_pos), heading(p_heading), speed(p_speed), time(p_time) {}
};

// Per-waypoint metadata flags
enum WaypointFlags : uint8_t {
	WP_NONE            = 0,
	WP_REVERSE_SEGMENT = 1 << 0,  // Ship should reverse through this segment
	WP_SMOOTHED        = 1 << 1,  // This waypoint was inserted by Catmull-Rom smoothing
};

// Result of pathfinding
struct PathResult {
	std::vector<Vector2> waypoints;
	std::vector<uint8_t> flags;    // Per-waypoint WaypointFlags (parallel to waypoints)
	float total_distance;
	bool valid;

	PathResult() : total_distance(0.0f), valid(false) {}
};

// Island metadata extracted from SDF
struct IslandData {
	int id;
	Vector2 center;                    // average of all land cells
	float radius;                      // max distance from center to any land cell
	float area;                        // land cell count × cell_size²
	std::vector<Vector2> edge_points;  // sampled shoreline points (SDF ≈ 0)

	IslandData() : id(-1), center(Vector2()), radius(0.0f), area(0.0f) {}

	Dictionary to_dictionary() const {
		Dictionary dict;
		dict["id"] = id;
		dict["center"] = center;
		dict["radius"] = radius;
		dict["area"] = area;
		PackedVector2Array edges;
		for (const auto &pt : edge_points) {
			edges.push_back(pt);
		}
		dict["edge_points"] = edges;
		return dict;
	}
};

// Cover zone behind an island relative to a threat direction
struct CoverZone {
	Vector2 center;         // island center
	float arc_start;        // start of safe arc (radians, 0 = +Z)
	float arc_end;          // end of safe arc
	float min_radius;       // minimum distance from island center (island edge + clearance)
	float max_radius;       // maximum useful distance
	Vector2 best_position;  // recommended position within zone
	float best_heading;     // recommended heading (broadside to threat)
	bool valid;             // false if no viable cover exists

	CoverZone()
		: center(Vector2()), arc_start(0.0f), arc_end(0.0f),
		  min_radius(0.0f), max_radius(0.0f),
		  best_position(Vector2()), best_heading(0.0f), valid(false) {}

	Dictionary to_dictionary() const {
		Dictionary dict;
		dict["center"] = center;
		dict["arc_start_angle"] = arc_start;
		dict["arc_end_angle"] = arc_end;
		dict["min_radius"] = min_radius;
		dict["max_radius"] = max_radius;
		dict["best_position"] = best_position;
		dict["best_heading"] = best_heading;
		dict["valid"] = valid;
		return dict;
	}
};

// SDF ray march result
struct RayResult {
	bool hit;
	Vector2 position;    // world XZ of first violation
	float distance;      // distance along ray to violation
	float penetration;   // how far into the unsafe zone

	RayResult() : hit(false), position(Vector2()), distance(0.0f), penetration(0.0f) {}
};

// Ship kinematic parameters (set once from ShipMovementV4)
struct ShipParams {
	float turning_circle_radius;   // meters, at full speed + full rudder
	float rudder_response_time;    // seconds, center to full rudder
	float acceleration_time;       // seconds, 0 to full speed
	float deceleration_time;       // seconds, full speed to 0
	float max_speed;               // m/s (already converted from knots)
	float reverse_speed_ratio;     // fraction of max_speed when reversing
	float ship_length;             // meters
	float ship_beam;               // meters (width)
	float turn_speed_loss;         // fraction of speed lost while turning

	ShipParams()
		: turning_circle_radius(300.0f), rudder_response_time(5.0f),
		  acceleration_time(20.0f), deceleration_time(10.0f),
		  max_speed(15.0f), reverse_speed_ratio(0.5f),
		  ship_length(200.0f), ship_beam(25.0f),
		  turn_speed_loss(0.2f) {}
};

// Live ship state (updated every physics frame)
struct ShipState {
	Vector2 position;           // XZ world position
	Vector2 velocity;           // XZ velocity
	float heading;              // current heading in radians (0 = +Z, π/2 = +X)
	float angular_velocity_y;   // current yaw rate (rad/s)
	float current_rudder;       // current rudder position [-1, 1]
	float current_speed;        // signed forward speed (negative = reversing)

	ShipState()
		: position(Vector2()), velocity(Vector2()),
		  heading(0.0f), angular_velocity_y(0.0f),
		  current_rudder(0.0f), current_speed(0.0f) {}
};

// Steering computation output
struct SteeringResult {
	float rudder;              // [-1, 1]
	int throttle;              // [-1, 4]
	bool collision_imminent;   // true if evasive action was taken
	float time_to_collision;   // seconds until predicted collision (INF if none)

	SteeringResult()
		: rudder(0.0f), throttle(0),
		  collision_imminent(false),
		  time_to_collision(std::numeric_limits<float>::infinity()) {}
};

// Dynamic obstacle (other ships)
struct DynamicObstacle {
	int id;
	Vector2 position;
	Vector2 velocity;
	float radius;
	float length;  // ship length — used for size-based avoidance priority

	DynamicObstacle() : id(-1), position(Vector2()), velocity(Vector2()), radius(0.0f), length(0.0f) {}
	DynamicObstacle(int p_id, Vector2 p_pos, Vector2 p_vel, float p_radius, float p_length = 0.0f)
		: id(p_id), position(p_pos), velocity(p_vel), radius(p_radius), length(p_length) {}
};

// Result of obstacle collision check — identifies which obstacle and its relative geometry
struct ObstacleCollisionInfo {
	bool has_collision;        // true if any obstacle collision was detected
	float time_to_collision;   // time along arc to first obstacle collision
	int obstacle_id;           // id of the threatening obstacle
	float relative_bearing;    // bearing of obstacle relative to our heading (radians, + = starboard)
	float obstacle_length;     // length of the threatening obstacle (for size priority)
	Vector2 obstacle_position; // position of obstacle at collision time
	Vector2 obstacle_velocity; // velocity of the obstacle

	ObstacleCollisionInfo()
		: has_collision(false),
		  time_to_collision(std::numeric_limits<float>::infinity()),
		  obstacle_id(-1), relative_bearing(0.0f), obstacle_length(0.0f),
		  obstacle_position(Vector2()), obstacle_velocity(Vector2()) {}
};

// Avoidance state — tracks committed avoidance maneuvers to prevent oscillation
struct AvoidanceState {
	bool active;               // currently in an avoidance maneuver
	bool is_give_way;          // true = we must maneuver; false = we hold course (stand-on)
	int avoid_obstacle_id;     // which obstacle we're avoiding
	float commit_timer;        // seconds remaining in committed maneuver
	float committed_rudder;    // rudder value we committed to during avoidance

	static constexpr float COMMIT_DURATION = 4.0f;       // minimum seconds to hold an avoidance maneuver
	static constexpr float STAND_ON_TTC_THRESHOLD = 3.0f; // stand-on vessel overrides if TTC drops below this

	AvoidanceState()
		: active(false), is_give_way(false), avoid_obstacle_id(-1),
		  commit_timer(0.0f), committed_rudder(0.0f) {}

	void begin(bool give_way, int obs_id, float rudder) {
		active = true;
		is_give_way = give_way;
		avoid_obstacle_id = obs_id;
		commit_timer = COMMIT_DURATION;
		committed_rudder = rudder;
	}

	void tick(float delta) {
		if (active) {
			commit_timer -= delta;
			if (commit_timer <= 0.0f) {
				active = false;
				commit_timer = 0.0f;
			}
		}
	}

	void clear() {
		active = false;
		is_give_way = false;
		avoid_obstacle_id = -1;
		commit_timer = 0.0f;
		committed_rudder = 0.0f;
	}
};

// Navigation state machine states
enum class NavState {
	IDLE = 0,
	NAVIGATING = 1,       // following path to waypoint
	ARRIVING = 2,         // decelerating near destination
	TURNING = 3,          // executing angle-only navigation
	STATION_APPROACH = 4, // heading to station-keep zone
	STATION_SETTLE = 5,   // slowing down inside zone
	STATION_HOLDING = 6,  // maintaining position in zone
	STATION_RECOVER = 7,  // drifted out of zone, returning
	AVOIDING = 8,         // collision avoidance override active
	EMERGENCY = 9,        // emergency reverse/evasion
};

// Navigation mode (what the navigator is trying to do)
enum class NavMode {
	NONE = 0,
	POSITION = 1,
	ANGLE = 2,
	POSE = 3,
	STATION_KEEP = 4,
};

// --- Math utilities ---

inline float normalize_angle(float angle) {
	// Normalize to [-PI, PI]
	while (angle > Math_PI) angle -= Math_TAU;
	while (angle < -Math_PI) angle += Math_TAU;
	return angle;
}

inline float angle_difference(float from, float to) {
	return normalize_angle(to - from);
}

inline float move_toward_f(float current, float target, float max_delta) {
	if (std::abs(target - current) <= max_delta) {
		return target;
	}
	return current + (target > current ? max_delta : -max_delta);
}

inline float lerp_f(float a, float b, float t) {
	return a + (b - a) * t;
}

inline float clamp_f(float value, float min_val, float max_val) {
	if (value < min_val) return min_val;
	if (value > max_val) return max_val;
	return value;
}

// Convert throttle level [-1, 4] to speed fraction [0, 1] (negative for reverse)
inline float throttle_to_speed_fraction(int throttle) {
	// Matches ShipMovementV4 throttle_settings: [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0]
	switch (throttle) {
		case -1: return -0.5f;
		case 0:  return 0.0f;
		case 1:  return 0.25f;
		case 2:  return 0.5f;
		case 3:  return 0.75f;
		case 4:  return 1.0f;
		default: return 0.0f;
	}
}

} // namespace godot

#endif // NAV_TYPES_H