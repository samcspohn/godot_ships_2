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

// Enemy ship threat zone for stealth pathfinding.
// Stamped onto a coarser grid overlay during path search initialization.
struct ThreatZone {
    int id;                // enemy ship ID (for proxy-ring matching; -1 = unidentified)
    Vector2 position;      // world XZ position of the enemy ship
    float hard_radius;     // inner radius — very high cost (our concealment radius)
    float soft_radius;     // outer radius — cost ramps from 0 at soft to max at hard

    ThreatZone() : id(-1), position(Vector2()), hard_radius(0.0f), soft_radius(0.0f) {}
    ThreatZone(Vector2 p_pos, float p_hard, float p_soft)
        : id(-1), position(p_pos), hard_radius(p_hard), soft_radius(p_soft) {}
    ThreatZone(int p_id, Vector2 p_pos, float p_hard, float p_soft)
        : id(p_id), position(p_pos), hard_radius(p_hard), soft_radius(p_soft) {}
};

// ============================================================================
// Spatial acceleration grid for ThreatZone queries.
//
// Threats register into every cell whose bounding box their soft_radius circle
// overlaps.  This makes both hard_radius (blocking) and soft_radius (penalty)
// queries conservative-but-correct: the caller always performs an exact
// distance check on the returned candidates.
//
// Cell size should be approximately the concealment (hard) radius.
// With uniform radii each circle spans at most a 3x3 patch of cells.
// ============================================================================
struct ThreatGrid {
	std::vector<std::vector<int>> cells; // flat [gz * w + gx] -> threat indices
	int   grid_w    = 0;
	int   grid_h    = 0;
	float cell_size = 1.0f;
	float origin_x  = 0.0f;
	float origin_z  = 0.0f;

	bool empty() const { return cells.empty(); }

	// Compute a good cell size from a threat list (max hard_radius, min 1 m).
	static float default_cell_size(const std::vector<ThreatZone>& threats) {
		float r = 1.0f;
		for (const auto& tz : threats) r = std::max(r, tz.hard_radius);
		return r;
	}

	// Build (or rebuild) the grid.  Bounds are derived from the threat circles.
	void build(const std::vector<ThreatZone>& threats, float p_cell_size) {
		cells.clear();
		grid_w = grid_h = 0;
		if (threats.empty() || p_cell_size <= 0.0f) return;

		cell_size = p_cell_size;

		// Tight bounding box of all soft-radius circles
		float mn_x =  std::numeric_limits<float>::infinity();
		float mn_z =  std::numeric_limits<float>::infinity();
		float mx_x = -std::numeric_limits<float>::infinity();
		float mx_z = -std::numeric_limits<float>::infinity();
		for (const auto& tz : threats) {
			float r = tz.soft_radius;
			mn_x = std::min(mn_x, tz.position.x - r);
			mn_z = std::min(mn_z, tz.position.y - r); // Vector2.y == world-Z
			mx_x = std::max(mx_x, tz.position.x + r);
			mx_z = std::max(mx_z, tz.position.y + r);
		}

		origin_x = mn_x;
		origin_z = mn_z;
		grid_w   = (int)std::ceil((mx_x - mn_x) / cell_size) + 1;
		grid_h   = (int)std::ceil((mx_z - mn_z) / cell_size) + 1;
		cells.assign((size_t)grid_w * grid_h, {});

		// Register each threat in all cells its soft_radius bounding box overlaps
		for (int ti = 0; ti < (int)threats.size(); ++ti) {
			const auto& tz = threats[ti];
			float r  = tz.soft_radius;
			int cx0  = std::max(0,          cx(tz.position.x - r));
			int cz0  = std::max(0,          cz(tz.position.y - r));
			int cx1  = std::min(grid_w - 1, cx(tz.position.x + r));
			int cz1  = std::min(grid_h - 1, cz(tz.position.y + r));
			for (int iz = cz0; iz <= cz1; ++iz)
				for (int ix = cx0; ix <= cx1; ++ix)
					cells[(size_t)iz * grid_w + ix].push_back(ti);
		}
	}

	// Single-cell lookup for D* Lite node-blocking checks (hard_radius only).
	// Returns candidates in the cell containing pos; caller checks dist^2.
	const std::vector<int>& query_point(Vector2 pos) const {
		static const std::vector<int> empty_vec;
		if (cells.empty()) return empty_vec;
		int ix = cx(pos.x), iz = cz(pos.y);
		if (ix < 0 || ix >= grid_w || iz < 0 || iz >= grid_h) return empty_vec;
		return cells[(size_t)iz * grid_w + ix];
	}

	// Region query -- appends (possibly duplicate) threat indices from all cells
	// within the axis-aligned square [pos-radius, pos+radius] to |out|.
	// Sort+unique after the call to deduplicate if needed.
	void query_region(Vector2 pos, float radius, std::vector<int>& out) const {
		if (cells.empty()) return;
		int x0 = std::max(0,          cx(pos.x - radius));
		int z0 = std::max(0,          cz(pos.y - radius));
		int x1 = std::min(grid_w - 1, cx(pos.x + radius));
		int z1 = std::min(grid_h - 1, cz(pos.y + radius));
		if (x0 > x1 || z0 > z1) return;
		for (int iz = z0; iz <= z1; ++iz)
			for (int ix = x0; ix <= x1; ++ix)
				for (int ti : cells[(size_t)iz * grid_w + ix])
					out.push_back(ti);
	}

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