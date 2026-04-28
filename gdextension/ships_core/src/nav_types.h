#ifndef NAV_TYPES_H
#define NAV_TYPES_H

#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <algorithm>
#include <vector>
#include <queue>
#include <functional>
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
	WP_REVERSE         = 1 << 0,  // Ship should reverse through this segment
	WP_REVERSE_SEGMENT = WP_REVERSE, // Backward-compatible alias
	WP_SMOOTHED        = 1 << 1,  // This waypoint was inserted by Catmull-Rom smoothing
	WP_DEPARTURE       = 1 << 2,  // Departure/recovery waypoint (prepended by planner)
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
	float linear_drag;             // linear drag coefficient

	ShipParams()
		: turning_circle_radius(300.0f), rudder_response_time(5.0f),
		  acceleration_time(20.0f), deceleration_time(10.0f),
		  max_speed(15.0f), reverse_speed_ratio(0.5f),
		  ship_length(200.0f), ship_beam(25.0f),
		  turn_speed_loss(0.2f), linear_drag(0.3f) {}
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

// Dynamic obstacle (other ships or torpedoes)
//
// Torpedoes are identified by two criteria that must both be true:
//   1. id < TORPEDO_ID_THRESHOLD  (negative IDs in the -100000 range, set by BotControllerV4)
//   2. length == 0.0f             (ships always have length > 0)
//
// Using both guards prevents a false positive if a ship somehow gets a low instance ID.
static constexpr int TORPEDO_ID_THRESHOLD = -1000;

struct DynamicObstacle {
	int id;
	Vector2 position;
	Vector2 velocity;
	float radius;
	float length;  // ship length — used for size-based avoidance priority; 0 = torpedo

	DynamicObstacle() : id(-1), position(Vector2()), velocity(Vector2()), radius(0.0f), length(0.0f) {}
	DynamicObstacle(int p_id, Vector2 p_pos, Vector2 p_vel, float p_radius, float p_length = 0.0f)
		: id(p_id), position(p_pos), velocity(p_vel), radius(p_radius), length(p_length) {}

	// Returns true when this obstacle represents a torpedo rather than a ship.
	bool is_torpedo() const {
		return id < TORPEDO_ID_THRESHOLD && length == 0.0f;
	}
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
	bool is_torpedo;           // true when the threatening obstacle is a torpedo (not a ship)

	ObstacleCollisionInfo()
		: has_collision(false),
		  time_to_collision(std::numeric_limits<float>::infinity()),
		  obstacle_id(-1), relative_bearing(0.0f), obstacle_length(0.0f),
		  obstacle_position(Vector2()), obstacle_velocity(Vector2()),
		  is_torpedo(false) {}
};

// Incoming shell threat data (for shell dodging/angling)
struct IncomingShell {
	int id;
	Vector2 landing_pos;    // predicted XZ impact point (center of threat line)
	Vector2 landing_dir;    // normalized XZ direction of shell travel at impact
	float threat_half_len;  // half-length of the threat line (steeper = shorter)
	float time_remaining;   // real seconds until impact
	float caliber;          // mm — for damage-weight prioritisation

	IncomingShell()
		: id(-1), landing_pos(Vector2()), landing_dir(Vector2(1, 0)),
		  threat_half_len(15.0f), time_remaining(0.0f), caliber(0.0f) {}
	IncomingShell(int p_id, Vector2 p_pos, float p_time, float p_cal,
	              Vector2 p_dir, float p_half_len)
		: id(p_id), landing_pos(p_pos), landing_dir(p_dir),
		  threat_half_len(p_half_len), time_remaining(p_time), caliber(p_cal) {}
};

// Navigation state machine — simplified two-state design
enum class NavState {
	NORMAL    = 0,  // Path following + weighted avoidance blending
	EMERGENCY = 1,  // Grounded or critical — SDF gradient escape
};

// Navigation target — the single struct replacing scattered target fields
struct NavTarget {
	Vector2 position;         // Destination XZ
	float heading;            // Desired heading on arrival (radians)
	float hold_radius;        // 0 = arrive and stop, >0 = station-keep within this radius
	float heading_tolerance;  // Acceptable heading error to consider settled (radians)

	NavTarget()
		: position(Vector2()), heading(0.0f), hold_radius(0.0f),
		  heading_tolerance(0.2618f) {}  // default ~15 degrees
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

// Enemy ship detection arc — one of 12 wedges that together replace the
// classic full-circle threat radius.  Each arc represents the radial extent
// of detection in a 30 deg sector, terrain-limited by raycasting the
// underlying SDF.  origin/bearing are world-frame; length is the radial
// reach in metres (already capped to bin radius * decay).
struct ThreatArc {
	int     enemy_id;     // ship instance ID; -1 = unidentified
	Vector2 origin;       // enemy world XZ
	float   bearing;      // sector centre, radians (0 = +X, π/2 = +Z)
	float   half_angle;   // sector half-aperture, radians (15 deg = π/12)
	float   length;       // radial reach in world metres

	ThreatArc()
		: enemy_id(-1), origin(Vector2()), bearing(0.0f),
		  half_angle(0.0f), length(0.0f) {}
	ThreatArc(int p_id, Vector2 p_origin, float p_bearing,
	          float p_half_angle, float p_length)
		: enemy_id(p_id), origin(p_origin), bearing(p_bearing),
		  half_angle(p_half_angle), length(p_length) {}
};

// ============================================================================
// Per-cell binary blocked grid built from a set of ThreatArcs.
//
// Each cell is a single byte (0 = open, 1 = blocked).  An arc stamps every
// cell whose centre falls inside the wedge.  Consumers (D* Lite, destination
// adjustment) check cell membership only — no per-arc geometry test at
// query time.  This trades a small amount of conservative over-blocking at
// cell boundaries for an O(1) point query.
// ============================================================================
struct BlockedGrid {
	std::vector<uint8_t> blocked; // [iz*grid_w + ix] -> 0/1
	int   grid_w    = 0;
	int   grid_h    = 0;
	float cell_size = 1.0f;
	float origin_x  = 0.0f;
	float origin_z  = 0.0f;

	bool empty() const { return blocked.empty(); }

	// Suggested cell size from an arc set: a fraction of the longest arc,
	// clamped to a sensible floor.  ~15 cells across the longest arc gives
	// adequate angular resolution for 30 deg wedges while keeping
	// rasterization cost bounded.  Floor at 200 m so very short arcs do
	// not produce a fine-grained grid.
	static float default_cell_size(const std::vector<ThreatArc>& arcs) {
		float L = 0.0f;
		for (const auto& a : arcs) L = std::max(L, a.length);
		float cs = L / 15.0f;
		if (cs < 200.0f) cs = 200.0f;
		return cs;
	}

	// Build (or rebuild) the grid.  Bounds are derived from arc extents.
	void build(const std::vector<ThreatArc>& arcs, float p_cell_size);

	// O(1) blocked test: returns true if pos lies in a stamped cell.
	bool is_blocked(Vector2 pos) const {
		if (blocked.empty()) return false;
		int ix = cx(pos.x), iz = cz(pos.y);
		if (ix < 0 || ix >= grid_w || iz < 0 || iz >= grid_h) return false;
		return blocked[(size_t)iz * grid_w + ix] != 0;
	}

	// Find the nearest unblocked cell centre to |pos| via BFS over
	// 4-connected cell neighbours.  Returns true and writes |out| if an
	// unblocked cell is reached within max_radius_cells; otherwise returns
	// false and leaves |out| untouched.  The BFS expands along cell
	// boundaries (cardinal moves), which is what callers want when sliding
	// a destination out of a blocked region.
	bool find_nearest_unblocked(Vector2 pos, int max_radius_cells, Vector2& out) const;

private:
	int cx(float wx) const { return (int)std::floor((wx - origin_x) / cell_size); }
	int cz(float wz) const { return (int)std::floor((wz - origin_z) / cell_size); }
};



// Resumable A* search state — one per ship for async pathfinding.
// Buffers are allocated once (matching grid size) and reused via generation counters.
struct PathSearch {
    // Per-cell A* buffers
    std::vector<float> g_cost;
    std::vector<int> parent;
    std::vector<int8_t> parent_dir;
    std::vector<uint32_t> open_gen;
    std::vector<uint32_t> closed_gen;
    uint32_t current_gen = 0;

    // Priority queue
    using PQEntry = std::pair<float, int>;
    std::priority_queue<PQEntry, std::vector<PQEntry>, std::greater<PQEntry>> open_set;

    // Search parameters (set by begin_path_search)
    int sx = 0, sz = 0, ex = 0, ez = 0;
    int start_idx = 0, end_idx = 0;
    int grid_width = 0, grid_height = 0;
    float clearance_world = 0;
    float turning_radius = 0, cell_size = 50;

    // World coords for path reconstruction
    Vector2 from, to;
    float clearance = 0;  // original clearance param (for post-processing)

    // Progress tracking
    int iterations = 0;
    int max_iterations = 200000;
    bool found = false;
    bool active = false;    // search in progress
    bool complete = false;  // search finished (found or exhausted)

    // Immediate result (set by begin if LOS path found)
    PathResult result;

    // --- Enemy threat avoidance overlay ---
    // Stamped at half-resolution (each threat cell covers 2x2 nav cells).
    // Values: 0.0 = no threat, >0 = cost multiplier penalty.
    std::vector<float> threat_cost;
    int threat_grid_width = 0;
    int threat_grid_height = 0;
    float threat_cell_size = 100.0f;   // world units per threat cell
    float threat_min_x = 0.0f;
    float threat_min_z = 0.0f;

    PathSearch() = default;

    void allocate(int total_cells) {
        if ((int)g_cost.size() == total_cells) return;
        g_cost.resize(total_cells);
        parent.resize(total_cells);
        parent_dir.resize(total_cells);
        open_gen.resize(total_cells, 0);
        closed_gen.resize(total_cells, 0);
        current_gen = 0;
    }

    void reset() {
        // Clear PQ (no clear() on std::priority_queue, swap with empty)
        std::priority_queue<PQEntry, std::vector<PQEntry>, std::greater<PQEntry>> empty_pq;
        open_set.swap(empty_pq);
        iterations = 0;
        found = false;
        active = false;
        complete = false;
        result = PathResult();
        // Note: threat_cost is not cleared here — it's rebuilt per-search by stamp_threats()
    }
};

} // namespace godot

#endif // NAV_TYPES_H