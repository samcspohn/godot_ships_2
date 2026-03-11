#ifndef NAVIGATION_MAP_H
#define NAVIGATION_MAP_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <vector>
#include <queue>
#include <unordered_map>
#include <cmath>
#include <algorithm>
#include <limits>

#include "nav_types.h"

namespace godot {

class NavigationMap : public RefCounted {
	GDCLASS(NavigationMap, RefCounted)

private:
	// --- SDF Grid ---
	std::vector<float> sdf_grid;  // Signed distance values; positive = water, negative = land
	int grid_width;
	int grid_height;
	float cell_size;
	float min_x, min_z, max_x, max_z;
	bool built;

	// --- Region connectivity (computed at build time) ---
	// Each navigable cell gets a region ID; cells in the same connected water region share an ID.
	// Non-navigable cells get -1. Used for O(1) reachability checks before pathfinding.
	std::vector<int> region_grid;  // size = grid_width * grid_height, -1 = non-navigable
	int region_count;

	// --- Island data ---
	std::vector<IslandData> islands;

	// --- Reusable A* buffers (mutable for use in const pathfinding methods) ---
	mutable std::vector<float> astar_g_cost_;
	mutable std::vector<int> astar_parent_;        // cell index for path reconstruction
	mutable std::vector<int8_t> astar_parent_dir_; // direction index 0-7, -1 = no parent
	mutable std::vector<uint32_t> astar_open_gen_;  // generation when g_cost was written
	mutable std::vector<uint32_t> astar_closed_gen_; // generation when cell was closed
	mutable uint32_t astar_current_gen_ = 0;

	// Precomputed turn angle (radians) between each pair of 8-connected directions
	float turn_angle_lut_[8][8];

	// Allocate A* buffers to match current grid size (call after grid_width/height are set)
	void allocate_astar_buffers();

	// Map a (dx, dz) offset to direction index 0-7, or -1 if invalid
	static inline int8_t dir_from_offset(int dx, int dz) {
		// Matches dx8/dz8 ordering in find_path_internal
		static const int8_t dir_map[3][3] = {
			{0, 3, 5},   // dx=-1: dz=-1, dz=0, dz=1
			{1, -1, 6},  // dx= 0: dz=-1, (0,0), dz=1
			{2, 4, 7},   // dx=+1: dz=-1, dz=0, dz=1
		};
		if (dx < -1 || dx > 1 || dz < -1 || dz > 1) return -1;
		return dir_map[dx + 1][dz + 1];
	}

	// --- Internal SDF helpers ---

	// Convert world coordinates to grid indices (fractional for interpolation)
	inline void world_to_grid(float wx, float wz, float &gx, float &gz) const {
		gx = (wx - min_x) / cell_size;
		gz = (wz - min_z) / cell_size;
	}

	// Convert grid indices to world coordinates
	inline void grid_to_world(int ix, int iz, float &wx, float &wz) const {
		wx = min_x + ix * cell_size;
		wz = min_z + iz * cell_size;
	}

	// Check if grid indices are in bounds
	inline bool in_bounds(int ix, int iz) const {
		return ix >= 0 && ix < grid_width && iz >= 0 && iz < grid_height;
	}

	// Get raw SDF value at a grid cell (no interpolation)
	inline float get_cell(int ix, int iz) const {
		if (!in_bounds(ix, iz)) return 0.0f;  // Out of bounds = wall
		return sdf_grid[iz * grid_width + ix];
	}

	// Set raw SDF value at a grid cell
	inline void set_cell(int ix, int iz, float value) {
		if (in_bounds(ix, iz)) {
			sdf_grid[iz * grid_width + ix] = value;
		}
	}

	// Bilinear interpolation of SDF at fractional grid coordinates
	float sample_bilinear(float gx, float gz) const;

	// --- SDF construction internals ---

	// Rasterize a triangle onto the binary land/water grid
	void rasterize_triangle(const Vector3 &v0, const Vector3 &v1, const Vector3 &v2,
							std::vector<bool> &land_mask);

	// Rasterize a box shape onto the land mask
	void rasterize_box(const Vector3 &center, const Vector3 &half_extents,
					   const Transform3D &transform, std::vector<bool> &land_mask);

	// Rasterize a sphere shape onto the land mask
	void rasterize_sphere(const Vector3 &center, float radius,
						  const Transform3D &transform, std::vector<bool> &land_mask);

	// Rasterize a cylinder shape onto the land mask
	void rasterize_cylinder(const Vector3 &center, float radius, float height,
							const Transform3D &transform, std::vector<bool> &land_mask);

	// Compute exact signed distances from a binary land mask using jump flood algorithm
	void compute_sdf_from_mask(const std::vector<bool> &land_mask);

	// Extract islands from the land mask via flood fill
	void extract_islands(const std::vector<bool> &land_mask);

	// Compute connected regions of navigable water cells for O(1) reachability checks.
	// Must be called after compute_sdf_from_mask. Uses a minimum clearance of 0 (any water cell).
	void compute_regions();

	// --- Coarse grid for hierarchical pathfinding ---
	static const int SECTOR_SIZE = 8;
	int coarse_width_, coarse_height_;
	std::vector<float> coarse_max_sdf_; // max SDF per sector (passable if >= clearance)
	void build_coarse_grid();

	// --- Pathfinding internals ---

	// Line-of-sight check on the SDF grid with clearance (Bresenham supercover)
	bool line_of_sight(int x0, int z0, int x1, int z1, float clearance) const;

	// Heuristic: Euclidean distance in grid cells
	inline float heuristic(int x0, int z0, int x1, int z1) const {
		float dx = static_cast<float>(x1 - x0);
		float dz = static_cast<float>(z1 - z0);
		return std::sqrt(dx * dx + dz * dz);
	}

	// Find the nearest navigable cell to the given grid position
	bool find_nearest_navigable(int &ix, int &iz, float clearance, int max_search_radius = 20) const;

	// Check if two grid cells are in the same navigable region (O(1) reachability test)
	inline bool same_region(int x0, int z0, int x1, int z1) const {
		if (!in_bounds(x0, z0) || !in_bounds(x1, z1)) return false;
		int r0 = region_grid[z0 * grid_width + x0];
		int r1 = region_grid[z1 * grid_width + x1];
		return r0 >= 0 && r0 == r1;
	}

protected:
	static void _bind_methods();

public:
	NavigationMap();
	~NavigationMap();

	// --- Construction ---

	// Set the world-space bounds of the map (min_x, min_z, max_x, max_z)
	void set_bounds(float p_min_x, float p_min_z, float p_max_x, float p_max_z);

	// Set the cell size in world units (default 50.0)
	void set_cell_size(float p_cell_size);

	// Build SDF from collision shapes of island StaticBody3D nodes
	// island_bodies: Array of Node3D (StaticBody3D) with CollisionShape3D children
	void build_from_collision_shapes(TypedArray<Node3D> island_bodies);

	// Build SDF by casting downward rays through the physics engine.
	// Simpler than collision-shape parsing: for each grid cell, cast a ray straight
	// down from just above the tallest island AABB. If the ray hits geometry and the
	// hit point's Y coordinate is above the waterline (Y > 0), the cell is land.
	// space_state: PhysicsDirectSpaceState3D obtained from get_world_3d().direct_space_state
	// island_bodies: Array of Node3D whose AABBs determine the ray origin height
	// collision_mask: physics collision mask for the ray (default 1 = terrain layer)
	void build_from_raycast_scan(PhysicsDirectSpaceState3D *space_state,
								 TypedArray<Node3D> island_bodies,
								 int collision_mask = 1);

	// --- Core SDF queries ---

	// Get signed distance at world position (positive = water, negative = land)
	// Uses bilinear interpolation for sub-cell accuracy
	float get_distance(float x, float z) const;

	// Get gradient of the SDF at world position (points away from nearest land)
	Vector2 get_gradient(float x, float z) const;

	// Check if a circle of given radius can navigate at this position
	bool is_navigable(float x, float z, float clearance) const;

	// --- Raycasting ---

	// March along a line segment testing clearance at each step
	// Returns Dictionary with keys: hit (bool), position (Vector2), distance (float), penetration (float)
	Dictionary raycast(Vector2 from, Vector2 to, float clearance) const;

	// Internal raycast returning struct (for C++ callers)
	RayResult raycast_internal(Vector2 from, Vector2 to, float clearance, float step_size = -1.0f) const;

	// --- Pathfinding ---

	// Find a path from 'from' to 'to' maintaining 'clearance' from all land
	// Returns array of waypoints in world XZ coordinates
	// When turning_radius > 0, applies curvature-aware cost function that
	// penalizes sharp turns and proximity to land relative to the ship's
	// turning circle, producing paths the ship can actually follow.
	PackedVector2Array find_path(Vector2 from, Vector2 to, float clearance,
								float turning_radius = 0.0f) const;

	// Internal pathfinding returning PathResult struct
	// When turning_radius is 0, behaves identically to the original implementation.
	// When nonzero, applies weighted A* with curvature penalty + Catmull-Rom smoothing.
	PathResult find_path_internal(Vector2 from, Vector2 to, float clearance,
								  float turning_radius = 0.0f) const;

	// Heading-aware overload: seeds A* with a virtual departure point so the
	// curvature penalty kicks in from the first step.
	// start_heading: ship's current heading (radians, 0 = +Z). NAN = legacy behavior.
	// cost_bound: A* aborts if g_cost exceeds this (for early termination of reverse search).
	// soft_clearance: preferred clearance (> clearance). Cells between clearance and
	//   soft_clearance are navigable but penalized, eliminating multi-pass fallback.
	PathResult find_path_internal(Vector2 from, Vector2 to, float clearance,
								  float turning_radius, float start_heading,
								  float cost_bound = std::numeric_limits<float>::infinity(),
								  float soft_clearance = 0.0f) const;

	// --- Island data ---

	// Get all detected islands as an array of Dictionaries
	TypedArray<Dictionary> get_islands() const;

	// Get the island nearest to a world XZ position
	Dictionary get_nearest_island(Vector2 position) const;

	// Compute a cover zone behind an island relative to a threat direction
	// island_id: index from get_islands()
	// threat_direction: unit vector from island toward threat
	// ship_clearance: minimum distance from land the ship needs
	// turning_radius: ship's turning circle radius — used to set max distance from island edge
	// max_engagement_range: must be within gun range of threat (reserved for future filtering)
	Dictionary compute_cover_zone(int island_id, Vector2 threat_direction,
								  float ship_clearance, float turning_radius,
								  float max_engagement_range) const;

	// Internal cover zone computation
	CoverZone compute_cover_zone_internal(int island_id, Vector2 threat_direction,
										  float ship_clearance, float turning_radius,
										  float max_engagement_range) const;

	// -----------------------------------------------------------------------
	// SDF-cell-based cover candidate search (replaces circle approximation)
	// -----------------------------------------------------------------------
	// Walks SDF cells near an island's shoreline to find navigable positions
	// where LOS to threats is blocked by land.  Returns a ranked list of
	// candidates so the GDScript caller can asynchronously validate
	// shootability via the full ballistic simulation (shells arc over islands,
	// so flat LOS is not checked here).
	//
	// island_id:        index from get_islands()
	// threat_positions: PackedVector2Array of enemy XZ positions to hide from
	// danger_center:    XZ position of the engagement center (for gun-range filter)
	// ship_position:    current ship XZ position (used for travel-cost scoring)
	// ship_clearance:   minimum SDF distance the ship needs from land
	// gun_range:        maximum firing range (positions must be within this of danger_center)
	// max_results:      how many candidates to return (default 20)
	// max_candidates:   hard cap on evaluated cells (performance knob, default 200)
	//
	// Returns TypedArray<Dictionary>, sorted best-first.  Each entry:
	//   position     (Vector2) — XZ cover position
	//   hidden_count (int)     — number of threats with LOS blocked at this cell
	//   total_threats(int)     — total threats tested
	//   all_hidden   (bool)    — true if every threat is blocked
	//   sdf_distance (float)   — SDF value at this cell (distance to land)
	//   score        (float)   — composite concealment score used for ranking
	TypedArray<Dictionary> find_cover_candidates(int island_id,
								   PackedVector2Array threat_positions,
								   Vector2 danger_center,
								   Vector2 ship_position,
								   float ship_clearance,
								   float gun_range,
								   int max_results = 20,
								   int max_candidates = 200) const;

	// Safe navigation point — GDScript-facing wrapper
	// Returns a Dictionary with keys: position (Vector2), adjusted (bool)
	Dictionary safe_nav_point_dict(Vector2 ship_position, Vector2 candidate,
								   float clearance, float turning_radius) const;

	// Validate destination — GDScript-facing wrapper
	// Returns a Dictionary with keys: position (Vector2), adjusted (bool)
	Dictionary validate_destination_dict(Vector2 ship_position, Vector2 destination,
										 float clearance, float turning_radius) const;

	// --- Safe destination selection ---

	// Given a candidate navigation target, ensure it is safely reachable:
	//   1. If inside land or too close to shore, push it into open water
	//   2. If near a coastline, slide it tangentially along the shore so that
	//      a ship approaching from `ship_position` arrives roughly parallel
	//      to the coast rather than perpendicular (which causes collisions)
	//   3. Ensures the returned point has at least `clearance` distance from land
	//
	// ship_position: current XZ position of the ship (used to determine approach direction)
	// candidate: the desired XZ target position (may be inside land or dangerously close)
	// clearance: hard minimum distance from land (beam/2 + safety)
	// turning_radius: ship's turning circle radius (used to determine how far from
	//                 shore the tangent adjustment should push the point)
	// Returns: a safe XZ position in open water
	Vector2 safe_nav_point(Vector2 ship_position, Vector2 candidate,
						   float clearance, float turning_radius) const;

	// Validate that navigating from `ship_position` to `destination` won't put
	// the ship on a collision course it can't recover from. Checks:
	//   1. Whether the destination is near land
	//   2. Whether the approach angle is too perpendicular to the nearest coastline
	//   3. If so, adjusts the destination tangentially and/or pushes it further
	//      into open water so the ship's arc naturally curves away from shore
	//
	// Returns a (possibly adjusted) destination that is safe to navigate to.
	// If the original destination is fine, returns it unchanged.
	Vector2 validate_destination(Vector2 ship_position, Vector2 destination,
								float clearance, float turning_radius) const;

	// --- Debug / Visualization ---

	// Get raw SDF data as a flat float array (row-major, for heatmap visualization)
	PackedFloat32Array get_sdf_data() const;

	// Get grid dimensions
	int get_grid_width() const;
	int get_grid_height() const;
	float get_cell_size_value() const;

	// Check if the map has been built
	bool is_built() const;

	// Get the number of detected islands
	int get_island_count() const;
};

} // namespace godot

#endif // NAVIGATION_MAP_H
