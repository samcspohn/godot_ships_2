#include "navigation_map.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/sphere_shape3d.hpp>
#include <godot_cpp/classes/cylinder_shape3d.hpp>
#include <godot_cpp/classes/convex_polygon_shape3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstring>
#include <cmath>
#include <algorithm>
#include <queue>
#include <vector>
#include <stack>
#include <limits>
#include <functional>

using namespace godot;

// ============================================================================
// Bind methods
// ============================================================================

void NavigationMap::_bind_methods() {
	// Construction
	ClassDB::bind_method(D_METHOD("set_bounds", "min_x", "min_z", "max_x", "max_z"), &NavigationMap::set_bounds);
	ClassDB::bind_method(D_METHOD("set_cell_size", "size"), &NavigationMap::set_cell_size);
	ClassDB::bind_method(D_METHOD("build_from_collision_shapes", "island_bodies"), &NavigationMap::build_from_collision_shapes);
	ClassDB::bind_method(D_METHOD("build_from_raycast_scan", "space_state", "island_bodies", "collision_mask"), &NavigationMap::build_from_raycast_scan, DEFVAL(1));

	// Core SDF queries
	ClassDB::bind_method(D_METHOD("get_distance", "x", "z"), &NavigationMap::get_distance);
	ClassDB::bind_method(D_METHOD("get_gradient", "x", "z"), &NavigationMap::get_gradient);
	ClassDB::bind_method(D_METHOD("is_navigable", "x", "z", "clearance"), &NavigationMap::is_navigable);

	// Raycasting
	ClassDB::bind_method(D_METHOD("raycast", "from", "to", "clearance"), &NavigationMap::raycast);

	// Pathfinding
	ClassDB::bind_method(D_METHOD("find_path", "from", "to", "clearance", "turning_radius"), &NavigationMap::find_path, DEFVAL(0.0f));

	// Island data
	ClassDB::bind_method(D_METHOD("get_islands"), &NavigationMap::get_islands);
	ClassDB::bind_method(D_METHOD("get_nearest_island", "position"), &NavigationMap::get_nearest_island);
	ClassDB::bind_method(D_METHOD("compute_cover_zone", "island_id", "threat_direction", "ship_clearance", "turning_radius", "max_engagement_range"), &NavigationMap::compute_cover_zone);

	// SDF-cell-based cover search — returns sorted array of candidate positions
	ClassDB::bind_method(D_METHOD("find_cover_candidates", "island_id", "threat_positions", "danger_center", "ship_position", "ship_clearance", "gun_range", "max_results", "max_candidates"), &NavigationMap::find_cover_candidates, DEFVAL(20), DEFVAL(200));

	// Safe destination selection
	ClassDB::bind_method(D_METHOD("safe_nav_point", "ship_position", "candidate", "clearance", "turning_radius"), &NavigationMap::safe_nav_point_dict);
	ClassDB::bind_method(D_METHOD("validate_destination", "ship_position", "destination", "clearance", "turning_radius"), &NavigationMap::validate_destination_dict);

	// Debug
	ClassDB::bind_method(D_METHOD("get_sdf_data"), &NavigationMap::get_sdf_data);
	ClassDB::bind_method(D_METHOD("get_grid_width"), &NavigationMap::get_grid_width);
	ClassDB::bind_method(D_METHOD("get_grid_height"), &NavigationMap::get_grid_height);
	ClassDB::bind_method(D_METHOD("get_cell_size_value"), &NavigationMap::get_cell_size_value);
	ClassDB::bind_method(D_METHOD("is_built"), &NavigationMap::is_built);
	ClassDB::bind_method(D_METHOD("get_island_count"), &NavigationMap::get_island_count);
}

// ============================================================================
// Constructor / Destructor
// ============================================================================

NavigationMap::NavigationMap() {
	grid_width = 0;
	grid_height = 0;
	cell_size = 50.0f;
	min_x = -17500.0f;
	min_z = -17500.0f;
	max_x = 17500.0f;
	max_z = 17500.0f;
	built = false;
	region_count = 0;
}

NavigationMap::~NavigationMap() {
}

// ============================================================================
// Construction
// ============================================================================

void NavigationMap::set_bounds(float p_min_x, float p_min_z, float p_max_x, float p_max_z) {
	min_x = p_min_x;
	min_z = p_min_z;
	max_x = p_max_x;
	max_z = p_max_z;
}

void NavigationMap::set_cell_size(float p_cell_size) {
	if (p_cell_size > 0.0f) {
		cell_size = p_cell_size;
	}
}

void NavigationMap::build_from_collision_shapes(TypedArray<Node3D> island_bodies) {
	// Calculate grid dimensions
	grid_width = static_cast<int>(std::ceil((max_x - min_x) / cell_size)) + 1;
	grid_height = static_cast<int>(std::ceil((max_z - min_z) / cell_size)) + 1;

	int total_cells = grid_width * grid_height;
	UtilityFunctions::print("[NavigationMap] Building SDF: ", grid_width, "x", grid_height,
							" (", total_cells, " cells, cell_size=", cell_size, "m)");

	// Step 1: Create binary land mask
	// NOTE: All rasterization methods now filter by waterline Y > 0.
	// Geometry at or below the waterline (base planes, underwater collision)
	// is NOT marked as land. This prevents rectangular base meshes from
	// inflating island footprints in the SDF.
	std::vector<bool> land_mask(total_cells, false);

	int island_count = island_bodies.size();
	UtilityFunctions::print("[NavigationMap] Processing ", island_count, " island bodies...");

	for (int i = 0; i < island_count; i++) {
		Node3D *body = Object::cast_to<Node3D>(island_bodies[i]);
		if (!body) {
			UtilityFunctions::print("[NavigationMap] Warning: island_bodies[", i, "] is null or not Node3D");
			continue;
		}

		Transform3D body_transform = body->get_global_transform();

		// Iterate children looking for CollisionShape3D
		int child_count = body->get_child_count();
		int shapes_processed = 0;

		for (int c = 0; c < child_count; c++) {
			CollisionShape3D *col_shape = Object::cast_to<CollisionShape3D>(body->get_child(c));
			if (!col_shape) continue;

			Ref<Shape3D> shape = col_shape->get_shape();
			if (shape.is_null()) continue;

			Transform3D shape_transform = body_transform * col_shape->get_transform();

			// Try ConcavePolygonShape3D (most common for island terrain)
			Ref<ConcavePolygonShape3D> concave = shape;
			if (concave.is_valid()) {
				PackedVector3Array faces = concave->get_faces();
				int face_count = faces.size() / 3;
				int above_water_tris = 0;
				for (int f = 0; f < face_count; f++) {
					Vector3 v0 = shape_transform.xform(faces[f * 3 + 0]);
					Vector3 v1 = shape_transform.xform(faces[f * 3 + 1]);
					Vector3 v2 = shape_transform.xform(faces[f * 3 + 2]);
					// rasterize_triangle now internally filters by Y > 0
					if (std::max({v0.y, v1.y, v2.y}) > 0.0f) above_water_tris++;
					rasterize_triangle(v0, v1, v2, land_mask);
				}
				UtilityFunctions::print("[NavigationMap]     ConcavePolygon: ", face_count,
										" tris, ", above_water_tris, " above waterline");
				shapes_processed++;
				continue;
			}

			// Try ConvexPolygonShape3D
			Ref<ConvexPolygonShape3D> convex = shape;
			if (convex.is_valid()) {
				PackedVector3Array points = convex->get_points();
				// Simple approach: create triangles from a fan
				if (points.size() >= 3) {
					// Project to XZ and create a simple triangulation
					for (int p = 1; p < points.size() - 1; p++) {
						Vector3 v0 = shape_transform.xform(points[0]);
						Vector3 v1 = shape_transform.xform(points[p]);
						Vector3 v2 = shape_transform.xform(points[p + 1]);
						rasterize_triangle(v0, v1, v2, land_mask);
					}
				}
				shapes_processed++;
				continue;
			}

			// Try BoxShape3D
			Ref<BoxShape3D> box = shape;
			if (box.is_valid()) {
				Vector3 half_extents = box->get_size() * 0.5f;
				rasterize_box(Vector3(0, 0, 0), half_extents, shape_transform, land_mask);
				shapes_processed++;
				continue;
			}

			// Try SphereShape3D
			Ref<SphereShape3D> sphere = shape;
			if (sphere.is_valid()) {
				float radius = sphere->get_radius();
				rasterize_sphere(Vector3(0, 0, 0), radius, shape_transform, land_mask);
				shapes_processed++;
				continue;
			}

			// Try CylinderShape3D
			Ref<CylinderShape3D> cylinder = shape;
			if (cylinder.is_valid()) {
				float radius = cylinder->get_radius();
				float height = cylinder->get_height();
				rasterize_cylinder(Vector3(0, 0, 0), radius, height, shape_transform, land_mask);
				shapes_processed++;
				continue;
			}
		}

		if (shapes_processed > 0) {
			UtilityFunctions::print("[NavigationMap]   Island '", body->get_name(),
									"': ", shapes_processed, " shapes rasterized");
		}
	}

	// Count land cells
	int land_cells = 0;
	for (int i = 0; i < total_cells; i++) {
		if (land_mask[i]) land_cells++;
	}
	UtilityFunctions::print("[NavigationMap] Land cells: ", land_cells, " / ", total_cells,
							" (", (land_cells * 100.0f / total_cells), "%)");

	// Step 2: Compute signed distance field from land mask
	compute_sdf_from_mask(land_mask);

	// Step 3: Extract island metadata
	extract_islands(land_mask);

	// Step 4: Compute connected water regions for O(1) reachability checks
	compute_regions();

	built = true;
	UtilityFunctions::print("[NavigationMap] Build complete. ", islands.size(), " islands detected, ",
							region_count, " navigable regions.");
}

// ============================================================================
// build_from_raycast_scan — simple downward-ray approach
// ============================================================================

void NavigationMap::build_from_raycast_scan(PhysicsDirectSpaceState3D *space_state,
											TypedArray<Node3D> island_bodies,
											int collision_mask) {
	if (space_state == nullptr) {
		UtilityFunctions::push_error("[NavigationMap] build_from_raycast_scan: space_state is null");
		return;
	}

	// Calculate grid dimensions
	grid_width = static_cast<int>(std::ceil((max_x - min_x) / cell_size)) + 1;
	grid_height = static_cast<int>(std::ceil((max_z - min_z) / cell_size)) + 1;

	int total_cells = grid_width * grid_height;
	UtilityFunctions::print("[NavigationMap] Building SDF via raycast scan: ", grid_width, "x", grid_height,
							" (", total_cells, " cells, cell_size=", cell_size, "m)");

	// --- Determine ray origin height ---
	// Walk every island body's CollisionShape3D children, compute their AABBs in
	// world space, and track the maximum Y coordinate. The ray origin is placed
	// just above this so we never start inside geometry.
	float max_y = 100.0f; // sensible default if no AABBs found

	int island_count = island_bodies.size();
	for (int i = 0; i < island_count; i++) {
		Node3D *body = Object::cast_to<Node3D>(island_bodies[i]);
		if (!body) continue;

		Transform3D body_transform = body->get_global_transform();
		int child_count = body->get_child_count();

		for (int c = 0; c < child_count; c++) {
			CollisionShape3D *col_shape = Object::cast_to<CollisionShape3D>(body->get_child(c));
			if (!col_shape) continue;

			Ref<Shape3D> shape = col_shape->get_shape();
			if (shape.is_null()) continue;

			Transform3D shape_transform = body_transform * col_shape->get_transform();

			// Try each supported shape type for its AABB height
			Ref<ConcavePolygonShape3D> concave = shape;
			if (concave.is_valid()) {
				PackedVector3Array faces = concave->get_faces();
				for (int f = 0; f < faces.size(); f++) {
					Vector3 world_v = shape_transform.xform(faces[f]);
					if (world_v.y > max_y) max_y = world_v.y;
				}
				continue;
			}

			Ref<ConvexPolygonShape3D> convex = shape;
			if (convex.is_valid()) {
				PackedVector3Array points = convex->get_points();
				for (int p = 0; p < points.size(); p++) {
					Vector3 world_v = shape_transform.xform(points[p]);
					if (world_v.y > max_y) max_y = world_v.y;
				}
				continue;
			}

			Ref<BoxShape3D> box = shape;
			if (box.is_valid()) {
				Vector3 half = box->get_size() * 0.5f;
				for (int corner = 0; corner < 8; corner++) {
					Vector3 local(
						(corner & 1) ? half.x : -half.x,
						(corner & 2) ? half.y : -half.y,
						(corner & 4) ? half.z : -half.z);
					Vector3 world_v = shape_transform.xform(local);
					if (world_v.y > max_y) max_y = world_v.y;
				}
				continue;
			}

			Ref<SphereShape3D> sphere = shape;
			if (sphere.is_valid()) {
				float r = sphere->get_radius();
				Vector3 top = shape_transform.xform(Vector3(0, r, 0));
				if (top.y > max_y) max_y = top.y;
				continue;
			}

			Ref<CylinderShape3D> cylinder = shape;
			if (cylinder.is_valid()) {
				float h = cylinder->get_height() * 0.5f;
				Vector3 top = shape_transform.xform(Vector3(0, h, 0));
				if (top.y > max_y) max_y = top.y;
				continue;
			}
		}
	}

	// Place ray origin 10 m above the tallest geometry
	float ray_origin_y = max_y + 10.0f;
	float ray_end_y = -10.0f; // well below the waterline
	UtilityFunctions::print("[NavigationMap] Tallest island geometry Y=", max_y,
							", ray origin Y=", ray_origin_y);

	// --- Set up the reusable ray query ---
	Ref<PhysicsRayQueryParameters3D> ray_query;
	ray_query.instantiate();
	ray_query->set_collision_mask(static_cast<uint32_t>(collision_mask));
	ray_query->set_collide_with_bodies(true);
	ray_query->set_collide_with_areas(false);
	ray_query->set_hit_back_faces(false);

	// --- Cast one ray per grid cell ---
	std::vector<bool> land_mask(total_cells, false);
	int land_cells = 0;

	for (int iz = 0; iz < grid_height; iz++) {
		for (int ix = 0; ix < grid_width; ix++) {
			float wx, wz;
			grid_to_world(ix, iz, wx, wz);

			ray_query->set_from(Vector3(wx, ray_origin_y, wz));
			ray_query->set_to(Vector3(wx, ray_end_y, wz));

			Dictionary result = space_state->intersect_ray(ray_query);

			if (!result.is_empty()) {
				Vector3 hit_pos = result["position"];
				// Hit point above the waterline (Y > 0) means land
				if (hit_pos.y > 0.0f) {
					land_mask[iz * grid_width + ix] = true;
					land_cells++;
				}
			}
		}
	}

	UtilityFunctions::print("[NavigationMap] Raycast scan complete. Land cells: ", land_cells,
							" / ", total_cells, " (", (land_cells * 100.0f / total_cells), "%)");

	// --- Reuse the same SDF pipeline as build_from_collision_shapes ---
	compute_sdf_from_mask(land_mask);
	extract_islands(land_mask);
	compute_regions();

	built = true;
	UtilityFunctions::print("[NavigationMap] Raycast build complete. ", islands.size(), " islands detected, ",
							region_count, " navigable regions.");
}

// ============================================================================
// Rasterization helpers
// ============================================================================

void NavigationMap::rasterize_triangle(const Vector3 &v0, const Vector3 &v1, const Vector3 &v2,
									   std::vector<bool> &land_mask) {
	// Project triangle to XZ plane and rasterize onto the grid.
	// AGGRESSIVE rasterization: mark ANY cell that the triangle touches, even partially.
	// This ensures no land above water is ever treated as empty/navigable.
	// Only mark cells as land where the triangle surface is above the waterline (Y > 0).

	// Quick reject: if all three vertices are at or below the waterline, skip entirely.
	float max_y = std::max({v0.y, v1.y, v2.y});
	if (max_y <= 0.0f) return;

	// Convert to grid coordinates
	float gx0, gz0, gx1, gz1, gx2, gz2;
	world_to_grid(v0.x, v0.z, gx0, gz0);
	world_to_grid(v1.x, v1.z, gx1, gz1);
	world_to_grid(v2.x, v2.z, gx2, gz2);

	// Bounding box in grid space — use floor/ceil to cover all cells the triangle could touch
	int min_gx = std::max(0, static_cast<int>(std::floor(std::min({gx0, gx1, gx2}))));
	int max_gx = std::min(grid_width - 1, static_cast<int>(std::ceil(std::max({gx0, gx1, gx2}))));
	int min_gz = std::max(0, static_cast<int>(std::floor(std::min({gz0, gz1, gz2}))));
	int max_gz = std::min(grid_height - 1, static_cast<int>(std::ceil(std::max({gz0, gz1, gz2}))));

	// Edge function for point-in-triangle test
	auto edge_func = [](float ax, float az, float bx, float bz, float px, float pz) -> float {
		return (bx - ax) * (pz - az) - (bz - az) * (px - ax);
	};

	// Check winding order
	float area_sign = edge_func(gx0, gz0, gx1, gz1, gx2, gz2);
	if (std::abs(area_sign) < 0.0001f) return; // Degenerate triangle

	// If the triangle is entirely above the waterline we can skip per-cell Y checks
	bool all_above = (v0.y > 0.0f && v1.y > 0.0f && v2.y > 0.0f);

	float inv_area = 1.0f / area_sign;

	// Triangle edges as segments in grid space for segment-vs-AABB intersection
	float tri_x[3] = {gx0, gx1, gx2};
	float tri_z[3] = {gz0, gz1, gz2};

	// Helper: test if 1D intervals [a_min, a_max] and [b_min, b_max] overlap
	auto intervals_overlap = [](float a_min, float a_max, float b_min, float b_max) -> bool {
		return a_min <= b_max && b_min <= a_max;
	};

	// Helper: test if a line segment (p0 -> p1) intersects an AABB [box_min, box_max]
	// Using separating axis theorem on 2D AABB vs segment
	auto segment_aabb_intersect = [&](float p0x, float p0z, float p1x, float p1z,
									   float box_min_x, float box_min_z,
									   float box_max_x, float box_max_z) -> bool {
		// First: bounding box overlap test
		float seg_min_x = std::min(p0x, p1x);
		float seg_max_x = std::max(p0x, p1x);
		float seg_min_z = std::min(p0z, p1z);
		float seg_max_z = std::max(p0z, p1z);
		if (!intervals_overlap(seg_min_x, seg_max_x, box_min_x, box_max_x)) return false;
		if (!intervals_overlap(seg_min_z, seg_max_z, box_min_z, box_max_z)) return false;

		// Separating axis from edge normal: n = (dz, -dx) where d = p1 - p0
		float dx = p1x - p0x;
		float dz = p1z - p0z;
		// Project AABB corners onto the edge normal axis
		// edge_func value at a point is: dx * (pz - p0z) - dz * (px - p0x)
		// which equals dot((dz, -dx), (px - p0x, pz - p0z)) ... actually let's just
		// compute the edge function at all 4 box corners
		float c0 = dx * (box_min_z - p0z) - dz * (box_min_x - p0x);
		float c1 = dx * (box_min_z - p0z) - dz * (box_max_x - p0x);
		float c2 = dx * (box_max_z - p0z) - dz * (box_min_x - p0x);
		float c3 = dx * (box_max_z - p0z) - dz * (box_max_x - p0x);
		float cmin = std::min({c0, c1, c2, c3});
		float cmax = std::max({c0, c1, c2, c3});
		// If all corners are on the same side of the line, the segment doesn't cross the box
		if (cmin > 0.0f || cmax < 0.0f) return false;

		return true;
	};

	// Helper: test if a point is inside the triangle
	auto point_in_triangle = [&](float px, float pz) -> bool {
		float e0 = edge_func(gx0, gz0, gx1, gz1, px, pz);
		float e1 = edge_func(gx1, gz1, gx2, gz2, px, pz);
		float e2 = edge_func(gx2, gz2, gx0, gz0, px, pz);
		if (area_sign > 0) {
			return (e0 >= 0 && e1 >= 0 && e2 >= 0);
		} else {
			return (e0 <= 0 && e1 <= 0 && e2 <= 0);
		}
	};

	for (int iz = min_gz; iz <= max_gz; iz++) {
		for (int ix = min_gx; ix <= max_gx; ix++) {
			// Cell AABB in grid space: [ix, iz] to [ix+1, iz+1]
			float cell_min_x = static_cast<float>(ix);
			float cell_min_z = static_cast<float>(iz);
			float cell_max_x = static_cast<float>(ix + 1);
			float cell_max_z = static_cast<float>(iz + 1);

			// Test triangle-vs-cell overlap using three checks:
			// 1) Any cell corner inside the triangle?
			// 2) Any triangle vertex inside the cell?
			// 3) Any triangle edge intersects the cell AABB?
			bool overlaps = false;

			// Check 1: Any of the 4 cell corners inside the triangle?
			if (!overlaps) {
				float corners_x[4] = {cell_min_x, cell_max_x, cell_min_x, cell_max_x};
				float corners_z[4] = {cell_min_z, cell_min_z, cell_max_z, cell_max_z};
				for (int c = 0; c < 4; c++) {
					if (point_in_triangle(corners_x[c], corners_z[c])) {
						overlaps = true;
						break;
					}
				}
			}

			// Check 2: Any triangle vertex inside the cell AABB?
			if (!overlaps) {
				for (int t = 0; t < 3; t++) {
					if (tri_x[t] >= cell_min_x && tri_x[t] <= cell_max_x &&
						tri_z[t] >= cell_min_z && tri_z[t] <= cell_max_z) {
						overlaps = true;
						break;
					}
				}
			}

			// Check 3: Any triangle edge intersects the cell AABB?
			if (!overlaps) {
				for (int e = 0; e < 3; e++) {
					int e_next = (e + 1) % 3;
					if (segment_aabb_intersect(tri_x[e], tri_z[e], tri_x[e_next], tri_z[e_next],
											   cell_min_x, cell_min_z, cell_max_x, cell_max_z)) {
						overlaps = true;
						break;
					}
				}
			}

			if (overlaps) {
				if (all_above) {
					land_mask[iz * grid_width + ix] = true;
				} else {
					// Mixed triangle: interpolate Y at cell center using barycentric coords.
					// If center is outside triangle, use nearest-point clamping to be aggressive:
					// if ANY vertex above water, mark as land.
					float px = static_cast<float>(ix) + 0.5f;
					float pz = static_cast<float>(iz) + 0.5f;

					float e0 = edge_func(gx0, gz0, gx1, gz1, px, pz);
					float e1 = edge_func(gx1, gz1, gx2, gz2, px, pz);
					float e2 = edge_func(gx2, gz2, gx0, gz0, px, pz);

					bool center_inside;
					if (area_sign > 0) {
						center_inside = (e0 >= 0 && e1 >= 0 && e2 >= 0);
					} else {
						center_inside = (e0 <= 0 && e1 <= 0 && e2 <= 0);
					}

					if (center_inside) {
						// Interpolate Y at cell center
						float w0 = e1 * inv_area;
						float w1 = e2 * inv_area;
						float w2 = e0 * inv_area;
						float y_at_cell = w0 * v0.y + w1 * v1.y + w2 * v2.y;
						if (y_at_cell > 0.0f) {
							land_mask[iz * grid_width + ix] = true;
						}
					} else {
						// Cell overlaps triangle but center is outside (edge/corner overlap).
						// Clamp barycentric weights to [0,1] to interpolate Y at the nearest
						// point on the triangle to the cell center. This avoids marking cells
						// that only touch a low-Y (underwater) edge of a mixed triangle.
						float w0 = e1 * inv_area;
						float w1 = e2 * inv_area;
						float w2 = e0 * inv_area;
						// Clamp each weight to [0,1] and renormalize
						w0 = std::max(0.0f, w0);
						w1 = std::max(0.0f, w1);
						w2 = std::max(0.0f, w2);
						float wsum = w0 + w1 + w2;
						if (wsum > 0.0f) {
							float inv_wsum = 1.0f / wsum;
							w0 *= inv_wsum;
							w1 *= inv_wsum;
							w2 *= inv_wsum;
						} else {
							// Degenerate: fall back to equal weights
							w0 = w1 = w2 = 1.0f / 3.0f;
						}
						float y_at_nearest = w0 * v0.y + w1 * v1.y + w2 * v2.y;
						if (y_at_nearest > 0.0f) {
							land_mask[iz * grid_width + ix] = true;
						}
					}
				}
			}
		}
	}
}

void NavigationMap::rasterize_box(const Vector3 &center, const Vector3 &half_extents,
								  const Transform3D &transform, std::vector<bool> &land_mask) {
	// Generate 8 corners of the box, transform to world, project to XZ.
	// Only mark cells as land if the box extends above the waterline (Y > 0).
	Vector3 corners[8];
	float box_max_y = -1e30f;
	for (int i = 0; i < 8; i++) {
		corners[i] = Vector3(
			(i & 1) ? half_extents.x : -half_extents.x,
			(i & 2) ? half_extents.y : -half_extents.y,
			(i & 4) ? half_extents.z : -half_extents.z
		);
		corners[i] = transform.xform(center + corners[i]);
		if (corners[i].y > box_max_y) box_max_y = corners[i].y;
	}

	// If the entire box is at or below the waterline, skip it
	if (box_max_y <= 0.0f) return;

	// Project to XZ and find bounding box
	float min_wx = corners[0].x, max_wx = corners[0].x;
	float min_wz = corners[0].z, max_wz = corners[0].z;
	for (int i = 1; i < 8; i++) {
		min_wx = std::min(min_wx, corners[i].x);
		max_wx = std::max(max_wx, corners[i].x);
		min_wz = std::min(min_wz, corners[i].z);
		max_wz = std::max(max_wz, corners[i].z);
	}

	// Convert to grid coordinates
	float gx_min_f, gz_min_f, gx_max_f, gz_max_f;
	world_to_grid(min_wx, min_wz, gx_min_f, gz_min_f);
	world_to_grid(max_wx, max_wz, gx_max_f, gz_max_f);

	int gx_min = std::max(0, static_cast<int>(std::floor(gx_min_f)));
	int gx_max = std::min(grid_width - 1, static_cast<int>(std::ceil(gx_max_f)));
	int gz_min = std::max(0, static_cast<int>(std::floor(gz_min_f)));
	int gz_max = std::min(grid_height - 1, static_cast<int>(std::ceil(gz_max_f)));

	// For each cell in the bounding box, test if the world point is inside the OBB
	// and whether the box surface at that XZ is above the waterline.
	Transform3D inv_transform = transform.affine_inverse();

	for (int iz = gz_min; iz <= gz_max; iz++) {
		for (int ix = gx_min; ix <= gx_max; ix++) {
			float wx, wz;
			grid_to_world(ix, iz, wx, wz);

			// Transform world point back to local box space (at Y=0 waterline)
			Vector3 local = inv_transform.xform(Vector3(wx, 0, wz));

			// Check if inside box XZ footprint
			if (std::abs(local.x - center.x) <= half_extents.x &&
				std::abs(local.z - center.z) <= half_extents.z) {
				// Check if the top of the box at this column is above the waterline.
				// The highest local Y in the box is center.y + half_extents.y.
				// Transform that point back to world to get the world-space top Y.
				Vector3 local_top(local.x, center.y + half_extents.y, local.z);
				Vector3 world_top = transform.xform(local_top);
				if (world_top.y > 0.0f) {
					land_mask[iz * grid_width + ix] = true;
				}
			}
		}
	}
}

void NavigationMap::rasterize_sphere(const Vector3 &center, float radius,
									 const Transform3D &transform, std::vector<bool> &land_mask) {
	Vector3 world_center = transform.xform(center);

	// Skip if the entire sphere is below the waterline
	if (world_center.y + radius <= 0.0f) return;

	float gx_center, gz_center;
	world_to_grid(world_center.x, world_center.z, gx_center, gz_center);

	// If the sphere only partially extends above the waterline, reduce the
	// effective XZ radius to the cross-section at Y=0.
	// For a sphere centered at (cx, cy, cz) with radius r, the cross-section
	// at Y=0 has radius sqrt(r² - cy²) when |cy| < r.
	float effective_radius = radius;
	if (world_center.y < radius) {
		float dy = world_center.y; // distance from waterline to center (positive = above)
		if (dy < 0.0f) {
			// Center is below water — cross-section at Y=0
			effective_radius = std::sqrt(radius * radius - dy * dy);
		}
		// else center is above water but bottom dips below — full XZ radius is fine
	}

	float grid_radius = effective_radius / cell_size;

	int gx_min = std::max(0, static_cast<int>(std::floor(gx_center - grid_radius)));
	int gx_max = std::min(grid_width - 1, static_cast<int>(std::ceil(gx_center + grid_radius)));
	int gz_min = std::max(0, static_cast<int>(std::floor(gz_center - grid_radius)));
	int gz_max = std::min(grid_height - 1, static_cast<int>(std::ceil(gz_center + grid_radius)));

	for (int iz = gz_min; iz <= gz_max; iz++) {
		for (int ix = gx_min; ix <= gx_max; ix++) {
			float dx = static_cast<float>(ix) - gx_center;
			float dz = static_cast<float>(iz) - gz_center;
			if (dx * dx + dz * dz <= grid_radius * grid_radius) {
				land_mask[iz * grid_width + ix] = true;
			}
		}
	}
}

void NavigationMap::rasterize_cylinder(const Vector3 &center, float radius, float height,
									   const Transform3D &transform, std::vector<bool> &land_mask) {
	// Check if the top of the cylinder is above the waterline
	Vector3 world_top = transform.xform(center + Vector3(0, height * 0.5f, 0));
	if (world_top.y <= 0.0f) return; // Entire cylinder is below water

	// For navigation purposes, a cylinder projects as a circle on XZ.
	// Use the cylinder radius directly (not height-dependent like a sphere).
	Vector3 world_center = transform.xform(center);

	float gx_center, gz_center;
	world_to_grid(world_center.x, world_center.z, gx_center, gz_center);

	float grid_radius = radius / cell_size;

	int gx_min = std::max(0, static_cast<int>(std::floor(gx_center - grid_radius)));
	int gx_max = std::min(grid_width - 1, static_cast<int>(std::ceil(gx_center + grid_radius)));
	int gz_min = std::max(0, static_cast<int>(std::floor(gz_center - grid_radius)));
	int gz_max = std::min(grid_height - 1, static_cast<int>(std::ceil(gz_center + grid_radius)));

	for (int iz = gz_min; iz <= gz_max; iz++) {
		for (int ix = gx_min; ix <= gx_max; ix++) {
			float dx = static_cast<float>(ix) - gx_center;
			float dz = static_cast<float>(iz) - gz_center;
			if (dx * dx + dz * dz <= grid_radius * grid_radius) {
				land_mask[iz * grid_width + ix] = true;
			}
		}
	}
}

// ============================================================================
// SDF computation (from binary land mask)
// ============================================================================

void NavigationMap::compute_sdf_from_mask(const std::vector<bool> &land_mask) {
	int total_cells = grid_width * grid_height;
	sdf_grid.resize(total_cells);

	// We'll use a two-pass distance transform (8SSEDT approximation)
	// For each cell, we store the squared distance to the nearest boundary cell.
	// Then we take the square root and apply the sign.

	const float INF_DIST = static_cast<float>(grid_width + grid_height);

	// Store nearest boundary coordinates for each cell
	std::vector<int> nearest_x(total_cells, -1);
	std::vector<int> nearest_z(total_cells, -1);

	// Initialize: boundary cells get distance 0, others get INF
	// A boundary cell is one where its land status differs from at least one 4-neighbor
	std::vector<float> dist_sq(total_cells, INF_DIST * INF_DIST);

	// Seed with boundary cells (land cells adjacent to water or vice versa)
	std::queue<int> bfs_queue;

	for (int iz = 0; iz < grid_height; iz++) {
		for (int ix = 0; ix < grid_width; ix++) {
			int idx = iz * grid_width + ix;
			bool is_land = land_mask[idx];

			// Check 4-neighbors for a boundary
			bool is_boundary = false;
			const int dx4[] = {1, -1, 0, 0};
			const int dz4[] = {0, 0, 1, -1};
			for (int d = 0; d < 4; d++) {
				int nx = ix + dx4[d];
				int nz = iz + dz4[d];
				if (nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height) {
					if (land_mask[nz * grid_width + nx] != is_land) {
						is_boundary = true;
						break;
					}
				} else {
					// Edge of map is a boundary (treated as water)
					if (is_land) {
						is_boundary = true;
						break;
					}
				}
			}

			if (is_boundary) {
				dist_sq[idx] = 0.0f;
				nearest_x[idx] = ix;
				nearest_z[idx] = iz;
				bfs_queue.push(idx);
			}
		}
	}

	// BFS-based distance transform using 8-connected neighbors
	// This is a multi-source BFS that propagates from all boundary cells simultaneously.
	// We use Chebyshev-ordered BFS with Euclidean distance update.
	// For better accuracy, we do a sequential two-pass 8SSEDT.

	// Forward pass (top-left to bottom-right)
	for (int iz = 0; iz < grid_height; iz++) {
		for (int ix = 0; ix < grid_width; ix++) {
			int idx = iz * grid_width + ix;

			// Check neighbors that have already been processed: (-1,-1),(-1,0),(-1,1),(0,-1)
			const int offsets[][2] = {{-1, -1}, {0, -1}, {1, -1}, {-1, 0}};
			for (int d = 0; d < 4; d++) {
				int nx = ix + offsets[d][0];
				int nz = iz + offsets[d][1];
				if (nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height) {
					int nidx = nz * grid_width + nx;
					if (nearest_x[nidx] >= 0) {
						float ddx = static_cast<float>(ix - nearest_x[nidx]);
						float ddz = static_cast<float>(iz - nearest_z[nidx]);
						float new_dist_sq = ddx * ddx + ddz * ddz;
						if (new_dist_sq < dist_sq[idx]) {
							dist_sq[idx] = new_dist_sq;
							nearest_x[idx] = nearest_x[nidx];
							nearest_z[idx] = nearest_z[nidx];
						}
					}
				}
			}
		}
	}

	// Backward pass (bottom-right to top-left)
	for (int iz = grid_height - 1; iz >= 0; iz--) {
		for (int ix = grid_width - 1; ix >= 0; ix--) {
			int idx = iz * grid_width + ix;

			// Check neighbors that have already been processed: (1,1),(0,1),(-1,1),(1,0)
			const int offsets[][2] = {{1, 1}, {0, 1}, {-1, 1}, {1, 0}};
			for (int d = 0; d < 4; d++) {
				int nx = ix + offsets[d][0];
				int nz = iz + offsets[d][1];
				if (nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height) {
					int nidx = nz * grid_width + nx;
					if (nearest_x[nidx] >= 0) {
						float ddx = static_cast<float>(ix - nearest_x[nidx]);
						float ddz = static_cast<float>(iz - nearest_z[nidx]);
						float new_dist_sq = ddx * ddx + ddz * ddz;
						if (new_dist_sq < dist_sq[idx]) {
							dist_sq[idx] = new_dist_sq;
							nearest_x[idx] = nearest_x[nidx];
							nearest_z[idx] = nearest_z[nidx];
						}
					}
				}
			}
		}
	}

	// Convert squared grid distances to world-space signed distances
	for (int i = 0; i < total_cells; i++) {
		float dist = std::sqrt(dist_sq[i]) * cell_size;
		// Positive = water, Negative = land
		if (land_mask[i]) {
			sdf_grid[i] = -dist;  // Inside land: negative
		} else {
			sdf_grid[i] = dist;   // Open water: positive
		}
	}

	UtilityFunctions::print("[NavigationMap] SDF computed. Distance range: ",
							*std::min_element(sdf_grid.begin(), sdf_grid.end()), " to ",
							*std::max_element(sdf_grid.begin(), sdf_grid.end()), " meters");
}

// ============================================================================
// Island extraction
// ============================================================================

void NavigationMap::extract_islands(const std::vector<bool> &land_mask) {
	islands.clear();

	int total_cells = grid_width * grid_height;
	std::vector<int> visited(total_cells, -1);  // -1 = unvisited, >=0 = island_id

	int island_id = 0;

	// Flood-fill to find connected land regions
	for (int iz = 0; iz < grid_height; iz++) {
		for (int ix = 0; ix < grid_width; ix++) {
			int idx = iz * grid_width + ix;
			if (!land_mask[idx] || visited[idx] >= 0) continue;

			// New island found — BFS flood fill
			IslandData island;
			island.id = island_id;

			std::queue<std::pair<int, int>> queue;
			queue.push({ix, iz});
			visited[idx] = island_id;

			double sum_x = 0, sum_z = 0;
			int cell_count = 0;
			std::vector<std::pair<int, int>> island_cells;

			while (!queue.empty()) {
				auto [cx, cz] = queue.front();
				queue.pop();

				float wx, wz;
				grid_to_world(cx, cz, wx, wz);
				sum_x += wx;
				sum_z += wz;
				cell_count++;
				island_cells.push_back({cx, cz});

				// Check 8-connected neighbors
				const int dx8[] = {-1, 0, 1, -1, 1, -1, 0, 1};
				const int dz8[] = {-1, -1, -1, 0, 0, 1, 1, 1};
				for (int d = 0; d < 8; d++) {
					int nx = cx + dx8[d];
					int nz = cz + dz8[d];
					if (nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height) {
						int nidx = nz * grid_width + nx;
						if (land_mask[nidx] && visited[nidx] < 0) {
							visited[nidx] = island_id;
							queue.push({nx, nz});
						}
					}
				}
			}

			// Skip tiny islands (noise) — fewer than 4 cells at 50m = 10,000 sq meters
			if (cell_count < 4) {
				island_id++;
				continue;
			}

			island.center = Vector2(
				static_cast<float>(sum_x / cell_count),
				static_cast<float>(sum_z / cell_count)
			);
			island.area = static_cast<float>(cell_count) * cell_size * cell_size;

			// Compute radius (max distance from center to any land cell)
			float max_dist_sq = 0.0f;
			for (const auto &[cx, cz] : island_cells) {
				float wx, wz;
				grid_to_world(cx, cz, wx, wz);
				float dx = wx - island.center.x;
				float dz = wz - island.center.y;  // center.y is world Z
				float d = dx * dx + dz * dz;
				if (d > max_dist_sq) max_dist_sq = d;
			}
			island.radius = std::sqrt(max_dist_sq);

			// Extract edge points (cells on the boundary between land and water)
			// Sample every few cells to keep the array manageable
			int edge_sample_stride = std::max(1, cell_count / 64);
			int edge_counter = 0;
			for (const auto &[cx, cz] : island_cells) {
				// Check if this cell has a water neighbor (it's on the edge)
				bool on_edge = false;
				const int dx4[] = {1, -1, 0, 0};
				const int dz4[] = {0, 0, 1, -1};
				for (int d = 0; d < 4; d++) {
					int nx = cx + dx4[d];
					int nz = cz + dz4[d];
					if (nx < 0 || nx >= grid_width || nz < 0 || nz >= grid_height) {
						on_edge = true;
						break;
					}
					if (!land_mask[nz * grid_width + nx]) {
						on_edge = true;
						break;
					}
				}
				if (on_edge) {
					edge_counter++;
					if (edge_counter % edge_sample_stride == 0) {
						float wx, wz;
						grid_to_world(cx, cz, wx, wz);
						island.edge_points.push_back(Vector2(wx, wz));
					}
				}
			}

			UtilityFunctions::print("[NavigationMap]   Island ", island_id,
									": center=(", island.center.x, ", ", island.center.y,
									"), radius=", island.radius, "m, area=", island.area, "m², ",
									island.edge_points.size(), " edge points");

			islands.push_back(island);
			island_id++;
		}
	}
}

// ============================================================================
// Region connectivity (for O(1) reachability checks)
// ============================================================================

void NavigationMap::compute_regions() {
	int total_cells = grid_width * grid_height;
	region_grid.assign(total_cells, -1);
	region_count = 0;

	// BFS flood-fill over all navigable (water) cells — sdf_grid > 0 means water
	for (int iz = 0; iz < grid_height; iz++) {
		for (int ix = 0; ix < grid_width; ix++) {
			int idx = iz * grid_width + ix;
			if (region_grid[idx] >= 0) continue;       // already assigned
			if (sdf_grid[idx] <= 0.0f) continue;       // land cell

			// New region — BFS flood fill
			int rid = region_count++;
			std::queue<int> q;
			region_grid[idx] = rid;
			q.push(idx);

			while (!q.empty()) {
				int ci = q.front();
				q.pop();
				int cz = ci / grid_width;
				int cx = ci % grid_width;

				const int dx4[] = {1, -1, 0, 0};
				const int dz4[] = {0, 0, 1, -1};
				for (int d = 0; d < 4; d++) {
					int nx = cx + dx4[d];
					int nz = cz + dz4[d];
					if (nx < 0 || nx >= grid_width || nz < 0 || nz >= grid_height) continue;
					int nidx = nz * grid_width + nx;
					if (region_grid[nidx] >= 0) continue;
					if (sdf_grid[nidx] <= 0.0f) continue;
					region_grid[nidx] = rid;
					q.push(nidx);
				}
			}
		}
	}

	UtilityFunctions::print("[NavigationMap] Computed ", region_count, " navigable water regions.");
}

// ============================================================================
// Bilinear interpolation
// ============================================================================

float NavigationMap::sample_bilinear(float gx, float gz) const {
	// Clamp to valid range
	gx = std::max(0.0f, std::min(gx, static_cast<float>(grid_width - 1)));
	gz = std::max(0.0f, std::min(gz, static_cast<float>(grid_height - 1)));

	int x0 = static_cast<int>(std::floor(gx));
	int z0 = static_cast<int>(std::floor(gz));
	int x1 = std::min(x0 + 1, grid_width - 1);
	int z1 = std::min(z0 + 1, grid_height - 1);

	float fx = gx - static_cast<float>(x0);
	float fz = gz - static_cast<float>(z0);

	float v00 = get_cell(x0, z0);
	float v10 = get_cell(x1, z0);
	float v01 = get_cell(x0, z1);
	float v11 = get_cell(x1, z1);

	float v0 = v00 * (1.0f - fx) + v10 * fx;
	float v1 = v01 * (1.0f - fx) + v11 * fx;

	return v0 * (1.0f - fz) + v1 * fz;
}

// ============================================================================
// SDF queries
// ============================================================================

float NavigationMap::get_distance(float x, float z) const {
	if (!built) return 10000.0f;  // Unbounded water if not built

	float gx, gz;
	world_to_grid(x, z, gx, gz);

	// Cells outside the map boundary are treated as walls
	if (gx < 0.0f || gx >= static_cast<float>(grid_width) ||
		gz < 0.0f || gz >= static_cast<float>(grid_height)) {
		// Distance to nearest boundary, as a negative value (wall)
		float dx = 0.0f, dz_val = 0.0f;
		if (gx < 0.0f) dx = -gx * cell_size;
		else if (gx >= grid_width) dx = (gx - grid_width + 1) * cell_size;
		if (gz < 0.0f) dz_val = -gz * cell_size;
		else if (gz >= grid_height) dz_val = (gz - grid_height + 1) * cell_size;
		return -std::sqrt(dx * dx + dz_val * dz_val);
	}

	return sample_bilinear(gx, gz);
}

Vector2 NavigationMap::get_gradient(float x, float z) const {
	if (!built) return Vector2(0, 0);

	// Central differences for gradient
	float h = cell_size * 0.5f;
	float dx = get_distance(x + h, z) - get_distance(x - h, z);
	float dz = get_distance(x, z + h) - get_distance(x, z - h);

	Vector2 grad(dx, dz);
	float len = grad.length();
	if (len > 0.0001f) {
		grad /= len;
	}
	return grad;
}

bool NavigationMap::is_navigable(float x, float z, float clearance) const {
	return get_distance(x, z) >= clearance;
}

// ============================================================================
// Raycasting
// ============================================================================

Dictionary NavigationMap::raycast(Vector2 from, Vector2 to, float clearance) const {
	RayResult result = raycast_internal(from, to, clearance);

	Dictionary dict;
	dict["hit"] = result.hit;
	dict["position"] = result.position;
	dict["distance"] = result.distance;
	dict["penetration"] = result.penetration;
	return dict;
}

RayResult NavigationMap::raycast_internal(Vector2 from, Vector2 to, float clearance, float step_size) const {
	RayResult result;

	if (!built) return result;

	Vector2 dir = to - from;
	float total_dist = dir.length();
	if (total_dist < 0.001f) {
		// From == To, just check navigability at that point
		float d = get_distance(from.x, from.y);
		if (d < clearance) {
			result.hit = true;
			result.position = from;
			result.distance = 0.0f;
			result.penetration = clearance - d;
		}
		return result;
	}

	// Use grid-cell DDA traversal to ensure every cell the ray passes through
	// is checked. The previous sphere-tracing approach used bilinear interpolation
	// of the SDF which can overestimate distances near land boundaries, causing
	// the ray to skip over land cells entirely (false negatives for LOS checks).

	// Convert endpoints to grid coordinates
	float gx0, gz0, gx1, gz1;
	world_to_grid(from.x, from.y, gx0, gz0);
	world_to_grid(to.x, to.y, gx1, gz1);

	// Current grid cell
	int cx = static_cast<int>(std::floor(gx0));
	int cz = static_cast<int>(std::floor(gz0));

	// Target grid cell
	int end_cx = static_cast<int>(std::floor(gx1));
	int end_cz = static_cast<int>(std::floor(gz1));

	// DDA direction
	float dx = gx1 - gx0;
	float dz = gz1 - gz0;

	int step_x = (dx >= 0.0f) ? 1 : -1;
	int step_z = (dz >= 0.0f) ? 1 : -1;

	// Distance in world units for one full grid cell step along each axis
	// (how far the ray travels in world units to cross one cell in x or z)
	float t_delta_x = (std::abs(dx) > 1e-8f) ? (total_dist / std::abs(dx)) : 1e30f;
	float t_delta_z = (std::abs(dz) > 1e-8f) ? (total_dist / std::abs(dz)) : 1e30f;

	// Distance to the first grid boundary crossing along each axis
	float t_max_x, t_max_z;
	if (std::abs(dx) > 1e-8f) {
		float next_boundary_x = (step_x > 0) ? (std::floor(gx0) + 1.0f) : std::floor(gx0);
		t_max_x = (next_boundary_x - gx0) / dx * total_dist;
		// Clamp small negative values from floating point
		if (t_max_x < 0.0f) t_max_x = 0.0f;
	} else {
		t_max_x = 1e30f;
	}
	if (std::abs(dz) > 1e-8f) {
		float next_boundary_z = (step_z > 0) ? (std::floor(gz0) + 1.0f) : std::floor(gz0);
		t_max_z = (next_boundary_z - gz0) / dz * total_dist;
		if (t_max_z < 0.0f) t_max_z = 0.0f;
	} else {
		t_max_z = 1e30f;
	}

	// Check the starting cell
	if (in_bounds(cx, cz) && get_cell(cx, cz) < clearance) {
		result.hit = true;
		result.position = from;
		result.distance = 0.0f;
		result.penetration = clearance - get_cell(cx, cz);
		return result;
	}

	// Walk cells along the ray using DDA
	// Track the parametric distance along the ray (in world units) for hit position
	int max_steps = std::abs(end_cx - cx) + std::abs(end_cz - cz) + 2;
	for (int step_count = 0; step_count < max_steps; step_count++) {
		// Advance to the next cell boundary
		float t_cross;
		if (t_max_x < t_max_z) {
			t_cross = t_max_x;
			cx += step_x;
			t_max_x += t_delta_x;
		} else {
			t_cross = t_max_z;
			cz += step_z;
			t_max_z += t_delta_z;
		}

		if (t_cross > total_dist) break;

		// Check this cell using raw SDF (no bilinear interpolation)
		if (!in_bounds(cx, cz) || get_cell(cx, cz) < clearance) {
			// Hit land or obstacle — compute the world-space hit position
			// Use the crossing distance as the approximate hit point
			Vector2 step_dir = dir / total_dist;
			result.hit = true;
			result.position = from + step_dir * t_cross;
			result.distance = t_cross;
			float cell_sdf = in_bounds(cx, cz) ? get_cell(cx, cz) : 0.0f;
			result.penetration = clearance - cell_sdf;
			return result;
		}
	}

	// Also check the endpoint cell explicitly (may differ from last DDA cell due to rounding)
	if (in_bounds(end_cx, end_cz) && get_cell(end_cx, end_cz) < clearance) {
		result.hit = true;
		result.position = to;
		result.distance = total_dist;
		result.penetration = clearance - get_cell(end_cx, end_cz);
		return result;
	}

	return result;
}

// ============================================================================
// Pathfinding (Theta* on SDF grid)
// ============================================================================

bool NavigationMap::line_of_sight(int x0, int z0, int x1, int z1, float clearance) const {
	// Supercover Bresenham — visits every cell the line touches, no gaps.
	// clearance is in the same units as the SDF grid values (world meters).
	int dx = std::abs(x1 - x0);
	int dz = std::abs(z1 - z0);
	int sx = (x0 < x1) ? 1 : -1;
	int sz = (z0 < z1) ? 1 : -1;

	int cx = x0;
	int cz = z0;

	// Check start cell
	if (!in_bounds(cx, cz) || get_cell(cx, cz) < clearance) {
		return false;
	}

	if (dx == 0 && dz == 0) {
		return true;
	}

	int err = dx - dz;

	while (!(cx == x1 && cz == z1)) {
		int e2 = 2 * err;

		// Supercover: use >= and <= to catch exact corner crossings.
		// When the line passes exactly through a grid vertex, both step
		// conditions fire and we visit the diagonal plus both cardinal
		// neighbors — eliminating false negatives from missed cells.
		bool step_x = (e2 > -dz) || (e2 == -dz && dx > 0);
		bool step_z = (e2 < dx)  || (e2 == dx  && dz > 0);

		if (step_x && step_z) {
			// Diagonal step — check both cardinal neighbors for supercover,
			// then move diagonally
			if (!in_bounds(cx + sx, cz) || get_cell(cx + sx, cz) < clearance) return false;
			if (!in_bounds(cx, cz + sz) || get_cell(cx, cz + sz) < clearance) return false;
			err -= dz;
			err += dx;
			cx += sx;
			cz += sz;
		} else if (step_x) {
			// Horizontal step
			err -= dz;
			cx += sx;
		} else {
			// Vertical step
			err += dx;
			cz += sz;
		}

		if (!in_bounds(cx, cz) || get_cell(cx, cz) < clearance) {
			return false;
		}
	}

	return true;
}

bool NavigationMap::find_nearest_navigable(int &ix, int &iz, float clearance, int max_search_radius) const {
	if (in_bounds(ix, iz) && get_cell(ix, iz) >= clearance) {
		return true;  // Already navigable
	}

	// Spiral outward search
	for (int r = 1; r <= max_search_radius; r++) {
		for (int dx = -r; dx <= r; dx++) {
			for (int dz = -r; dz <= r; dz++) {
				if (std::abs(dx) != r && std::abs(dz) != r) continue;  // Only check border of current ring

				int nx = ix + dx;
				int nz = iz + dz;
				if (in_bounds(nx, nz) && get_cell(nx, nz) >= clearance) {
					ix = nx;
					iz = nz;
					return true;
				}
			}
		}
	}
	return false;
}

PackedVector2Array NavigationMap::find_path(Vector2 from, Vector2 to, float clearance,
										   float turning_radius) const {
	PackedVector2Array result;
	PathResult pr = find_path_internal(from, to, clearance, turning_radius);

	if (pr.valid) {
		for (const auto &wp : pr.waypoints) {
			result.push_back(wp);
		}
	}

	return result;
}

PathResult NavigationMap::find_path_internal(Vector2 from, Vector2 to, float clearance,
											 float turning_radius) const {
	PathResult result;
	result.valid = false;
	result.total_distance = 0.0f;

	if (!built) return result;

	// The SDF grid stores world-unit distances (meters), so clearance for
	// cell-level checks stays in world units — no conversion needed.
	float clearance_world = clearance;

	// Convert start/end to grid coordinates
	float gx_start, gz_start, gx_end, gz_end;
	world_to_grid(from.x, from.y, gx_start, gz_start);
	world_to_grid(to.x, to.y, gx_end, gz_end);

	int sx = static_cast<int>(std::round(gx_start));
	int sz = static_cast<int>(std::round(gz_start));
	int ex = static_cast<int>(std::round(gx_end));
	int ez = static_cast<int>(std::round(gz_end));

	// Clamp to grid
	sx = std::max(0, std::min(sx, grid_width - 1));
	sz = std::max(0, std::min(sz, grid_height - 1));
	ex = std::max(0, std::min(ex, grid_width - 1));
	ez = std::max(0, std::min(ez, grid_height - 1));

	// Snap to nearest navigable cells if needed
	if (!find_nearest_navigable(sx, sz, clearance_world, 30)) {
		UtilityFunctions::print("[NavigationMap] find_path: start position is not navigable and no nearby navigable cell found");
		return result;
	}
	if (!find_nearest_navigable(ex, ez, clearance_world, 30)) {
		UtilityFunctions::print("[NavigationMap] find_path: end position is not navigable and no nearby navigable cell found");
		return result;
	}

	// --- O(1) reachability check using precomputed region IDs ---
	// If start and end are in different water regions, no path exists.
	if (!same_region(sx, sz, ex, ez)) {
		UtilityFunctions::print("[NavigationMap] find_path: start and end are in different water regions (unreachable)");
		return result;
	}

	// Trivial case: start == end
	if (sx == ex && sz == ez) {
		float wx, wz;
		grid_to_world(sx, sz, wx, wz);
		result.waypoints.push_back(Vector2(wx, wz));
		result.valid = true;
		result.total_distance = 0.0f;
		return result;
	}

	// Check if direct line-of-sight exists
	if (line_of_sight(sx, sz, ex, ez, clearance_world)) {
		result.waypoints.push_back(from);
		result.waypoints.push_back(to);
		result.total_distance = from.distance_to(to);
		result.valid = true;
		return result;
	}

	// --- A* pathfinding (8-connected grid) with post-process simplification ---
	// When turning_radius > 0, uses a weighted cost function that penalizes:
	//   1. Proximity to land relative to turning circle (pushes paths away from shore)
	//   2. Sharp direction changes relative to turning radius (prefers gentle curves)
	// This produces paths that ships can actually follow without grounding.

	// Convert turning radius to grid cells for cost computation
	float turning_radius_cells = turning_radius / cell_size;
	bool use_curvature_penalty = (turning_radius_cells > 0.0f);

	int total_cells = grid_width * grid_height;

	// Use flat arrays indexed by cell for O(1) lookup
	std::vector<float> g_cost(total_cells, std::numeric_limits<float>::infinity());
	std::vector<int> parent(total_cells, -1);  // parent as flat index, -1 = none
	std::vector<bool> closed(total_cells, false);

	auto cell_idx = [this](int x, int z) -> int {
		return z * grid_width + x;
	};

	// Priority queue: (f_cost, flat_index)
	using PQEntry = std::pair<float, int>;
	std::priority_queue<PQEntry, std::vector<PQEntry>, std::greater<PQEntry>> open;

	int start_idx = cell_idx(sx, sz);
	int end_idx = cell_idx(ex, ez);
	g_cost[start_idx] = 0.0f;
	parent[start_idx] = start_idx;  // self-parent marks start
	float h = heuristic(sx, sz, ex, ez);
	open.push({h, start_idx});

	// 8-connected neighbors
	const int dx8[] = {-1, 0, 1, -1, 1, -1, 0, 1};
	const int dz8[] = {-1, -1, -1, 0, 0, 1, 1, 1};
	const float cost8[] = {1.414f, 1.0f, 1.414f, 1.0f, 1.0f, 1.414f, 1.0f, 1.414f};

	bool found = false;
	int iterations = 0;
	// Safety limit: for a 700x700 grid the straight-line distance is at most ~990 cells,
	// so a reasonable path should never need to expand more than ~50k-100k nodes.
	// We set a generous limit well below total_cells to prevent multi-second stalls.
	const int MAX_ITERATIONS = std::min(total_cells, 200000);

	while (!open.empty() && iterations < MAX_ITERATIONS) {
		iterations++;

		auto [f, ci] = open.top();
		open.pop();

		if (closed[ci]) continue;
		closed[ci] = true;

		// Goal reached
		if (ci == end_idx) {
			found = true;
			break;
		}

		int cx = ci % grid_width;
		int cz = ci / grid_width;
		float cg = g_cost[ci];

		// Get grandparent direction for turn-angle penalty
		int parent_idx = parent[ci];
		int px = -1, pz = -1;
		bool has_parent_dir = false;
		if (use_curvature_penalty && parent_idx >= 0 && parent_idx != ci) {
			px = parent_idx % grid_width;
			pz = parent_idx / grid_width;
			has_parent_dir = true;
		}

		// Expand 8-connected neighbors
		for (int d = 0; d < 8; d++) {
			int nx = cx + dx8[d];
			int nz = cz + dz8[d];

			if (!in_bounds(nx, nz)) continue;

			int nidx = cell_idx(nx, nz);
			if (closed[nidx]) continue;

			// Check navigability with clearance (SDF values are in world units)
			if (get_cell(nx, nz) < clearance_world) continue;

			// For diagonal moves, also check the two cardinal cells to prevent corner-cutting
			if (dx8[d] != 0 && dz8[d] != 0) {
				if (get_cell(cx + dx8[d], cz) < clearance_world) continue;
				if (get_cell(cx, cz + dz8[d]) < clearance_world) continue;
			}

			float base_cost = cost8[d];
			float extra_cost = 0.0f;

			if (use_curvature_penalty) {
				// --- Proximity penalty ---
				// Exponential cost increase as SDF approaches the turning radius.
				// This pushes paths away from land proportional to the ship's turn circle.
				float sdf_value_cells = get_cell(nx, nz) / cell_size;  // convert SDF to grid-cell units
				float proximity_ratio = turning_radius_cells / std::max(sdf_value_cells, 1.0f);
				proximity_ratio = std::min(proximity_ratio, 5.0f);
				extra_cost += base_cost * proximity_ratio * 0.5f;

				// --- Direction-change (turn angle) penalty ---
				// parent→current→neighbor forms an angle; sharper angles cost more.
				if (has_parent_dir) {
					// Direction from parent to current
					float d1x = static_cast<float>(cx - px);
					float d1z = static_cast<float>(cz - pz);
					// Direction from current to neighbor
					float d2x = static_cast<float>(nx - cx);
					float d2z = static_cast<float>(nz - cz);
					// Normalize
					float len1 = std::sqrt(d1x * d1x + d1z * d1z);
					float len2 = std::sqrt(d2x * d2x + d2z * d2z);
					if (len1 > 0.001f && len2 > 0.001f) {
						d1x /= len1; d1z /= len1;
						d2x /= len2; d2z /= len2;
						// Dot product gives cos(angle), cross gives sin(angle)
						float dot = d1x * d2x + d1z * d2z;
						dot = std::max(-1.0f, std::min(1.0f, dot));
						float turn_angle = std::acos(dot);
						// Arc length the turning circle needs for this angle
						float arc_length = turning_radius_cells * std::abs(turn_angle);
						// Penalty scales with how much arc is needed relative to a single cell step.
						// arc_length is already in cell units (turning_radius_cells * angle),
						// so no further division by cell_size is needed.
						extra_cost += arc_length * 0.3f;
					}
				}
			}

			float new_g = cg + base_cost + extra_cost;

			if (new_g < g_cost[nidx]) {
				g_cost[nidx] = new_g;
				parent[nidx] = ci;
				float new_f = new_g + heuristic(nx, nz, ex, ez);
				open.push({new_f, nidx});
			}
		}
	}

	if (!found) {
		UtilityFunctions::print("[NavigationMap] find_path: No path found after ", iterations, " iterations");
		return result;
	}

	// Reconstruct path (grid coords -> world coords)
	std::vector<Vector2> path;
	{
		int ci = end_idx;
		while (ci != start_idx) {
			int cx = ci % grid_width;
			int cz = ci / grid_width;
			float wx, wz;
			grid_to_world(cx, cz, wx, wz);
			path.push_back(Vector2(wx, wz));

			int pi = parent[ci];
			if (pi == ci) break;  // safety: self-parent = start
			ci = pi;
		}
	}

	// Add start
	path.push_back(from);

	// Reverse to get start-to-end order
	std::reverse(path.begin(), path.end());

	// Replace the last point with the exact target
	if (path.size() >= 2) {
		path.back() = to;
	}

	// --- Path simplification using grid-level LOS (fast) ---
	// Greedy funnel: from current waypoint, find the farthest visible waypoint
	// Uses grid-level line_of_sight which is O(max_grid_distance) per check
	if (path.size() > 2) {
		std::vector<Vector2> simplified;
		simplified.push_back(path[0]);

		size_t current = 0;
		while (current < path.size() - 1) {
			size_t farthest = current + 1;

			for (size_t test = path.size() - 1; test > current + 1; test--) {
				// Convert world positions to grid for fast LOS check
				float gx0, gz0, gx1, gz1;
				world_to_grid(path[current].x, path[current].y, gx0, gz0);
				world_to_grid(path[test].x, path[test].y, gx1, gz1);
				int ix0 = static_cast<int>(std::round(gx0));
				int iz0 = static_cast<int>(std::round(gz0));
				int ix1 = static_cast<int>(std::round(gx1));
				int iz1 = static_cast<int>(std::round(gz1));

				if (line_of_sight(ix0, iz0, ix1, iz1, clearance_world)) {
					farthest = test;
					break;  // Found farthest visible; done for this segment
				}
			}

			simplified.push_back(path[farthest]);
			current = farthest;
		}
		path = simplified;
	}

	// --- Catmull-Rom smoothing at sharp waypoints (only when turning-radius-aware) ---
	// Insert intermediate points along curves where the turn angle exceeds what
	// the ship's turning circle can comfortably handle. This gives the ship a
	// smooth trajectory instead of point-to-point segments with sharp bends.
	if (use_curvature_penalty && path.size() >= 3) {
		// Threshold: if the turn angle at a waypoint exceeds this, smooth it
		float clearance_in_cells = clearance_world / cell_size;
		float angle_threshold = Math_PI / std::max(turning_radius_cells / std::max(clearance_in_cells, 1.0f), 1.0f);
		angle_threshold = std::min(angle_threshold, static_cast<float>(Math_PI * 0.5));  // cap at 90°
		angle_threshold = std::max(angle_threshold, 0.3f);  // floor at ~17°

		std::vector<Vector2> smoothed;
		smoothed.push_back(path[0]);

		for (size_t i = 1; i + 1 < path.size(); i++) {
			Vector2 prev = path[i - 1];
			Vector2 curr = path[i];
			Vector2 next = path[i + 1];

			// Compute turn angle at this waypoint
			Vector2 d1 = (curr - prev).normalized();
			Vector2 d2 = (next - curr).normalized();
			float dot_val = d1.x * d2.x + d1.y * d2.y;
			dot_val = std::max(-1.0f, std::min(1.0f, dot_val));
			float turn_angle = std::acos(dot_val);

			if (turn_angle > angle_threshold) {
				// Insert 2-3 Catmull-Rom interpolated points
				// Use the 4 control points: path[i-1], path[i-1], path[i], path[i+1]
				// (duplicate first point if at start)
				Vector2 p0 = (i >= 2) ? path[i - 2] : prev;
				Vector2 p1 = prev;
				Vector2 p2 = curr;
				Vector2 p3 = next;

				int num_inserts = (turn_angle > Math_PI * 0.7f) ? 3 : 2;
				bool all_valid = true;

				std::vector<Vector2> interpolated;
				for (int k = 1; k <= num_inserts; k++) {
					float t = static_cast<float>(k) / static_cast<float>(num_inserts + 1);
					// Catmull-Rom spline: q(t) = 0.5 * ((2*p1) + (-p0+p2)*t + (2*p0-5*p1+4*p2-p3)*t² + (-p0+3*p1-3*p2+p3)*t³)
					float t2 = t * t;
					float t3 = t2 * t;
					Vector2 pt = 0.5f * (
						(p1 * 2.0f) +
						(p2 - p0) * t +
						(p0 * 2.0f - p1 * 5.0f + p2 * 4.0f - p3) * t2 +
						(p1 * 3.0f - p0 - p2 * 3.0f + p3) * t3
					);

					// SDF validation: check if the interpolated point is navigable
					float pt_dist = get_distance(pt.x, pt.y);
					if (pt_dist < clearance) {
						all_valid = false;
						break;
					}
					interpolated.push_back(pt);
				}

				if (all_valid && !interpolated.empty()) {
					// Use the smoothed points instead of the sharp corner
					for (const auto &ipt : interpolated) {
						smoothed.push_back(ipt);
					}
				}
				// Always include the original waypoint (after or instead of interpolated)
				smoothed.push_back(curr);
			} else {
				smoothed.push_back(curr);
			}
		}

		// Add the last point
		smoothed.push_back(path.back());
		path = smoothed;
	}

	// Compute total distance
	float total_dist = 0.0f;
	for (size_t i = 1; i < path.size(); i++) {
		total_dist += path[i - 1].distance_to(path[i]);
	}

	result.waypoints = path;
	result.flags.resize(path.size(), WP_NONE);
	result.total_distance = total_dist;
	result.valid = true;
	return result;
}

// ============================================================================
// Island data queries
// ============================================================================

TypedArray<Dictionary> NavigationMap::get_islands() const {
	TypedArray<Dictionary> result;
	for (const auto &island : islands) {
		result.push_back(island.to_dictionary());
	}
	return result;
}

Dictionary NavigationMap::get_nearest_island(Vector2 position) const {
	Dictionary result;

	if (islands.empty()) {
		result["valid"] = false;
		return result;
	}

	float best_dist_sq = std::numeric_limits<float>::infinity();
	int best_idx = -1;

	for (size_t i = 0; i < islands.size(); i++) {
		float dx = position.x - islands[i].center.x;
		float dz = position.y - islands[i].center.y;  // .y is Z in Vector2
		float dist_sq = dx * dx + dz * dz;
		// Use distance from center minus radius as the effective distance
		float effective_dist = std::sqrt(dist_sq) - islands[i].radius;
		if (effective_dist < best_dist_sq) {
			best_dist_sq = effective_dist;
			best_idx = static_cast<int>(i);
		}
	}

	if (best_idx >= 0) {
		result = islands[best_idx].to_dictionary();
		result["valid"] = true;
	} else {
		result["valid"] = false;
	}

	return result;
}

Dictionary NavigationMap::compute_cover_zone(int island_id, Vector2 threat_direction,
											 float ship_clearance, float turning_radius,
											 float max_engagement_range) const {
	CoverZone cz = compute_cover_zone_internal(island_id, threat_direction,
											   ship_clearance, turning_radius,
											   max_engagement_range);
	return cz.to_dictionary();
}

CoverZone NavigationMap::compute_cover_zone_internal(int island_id, Vector2 threat_direction,
													 float ship_clearance, float turning_radius,
													 float max_engagement_range) const {
	CoverZone result;

	if (island_id < 0 || island_id >= static_cast<int>(islands.size())) {
		return result;
	}

	const IslandData &island = islands[island_id];
	result.center = island.center;

	// Normalize threat direction
	float threat_len = threat_direction.length();
	if (threat_len < 0.0001f) return result;
	Vector2 threat_dir = threat_direction / threat_len;

	// The "cover" direction is opposite to the threat
	// We want to find navigable water on the far side of the island from the threat
	float threat_angle = std::atan2(threat_dir.x, threat_dir.y);  // atan2(x, z) for heading convention
	float cover_angle = normalize_angle(threat_angle + Math_PI);

	// Sweep angles in the hemisphere opposite the threat
	const int SWEEP_SAMPLES = 36;
	const float SWEEP_RANGE = Math_PI * 0.8f;  // Sweep 144 degrees (±72° from cover direction)

	float best_score = -std::numeric_limits<float>::infinity();
	float valid_arc_start = cover_angle;
	float valid_arc_end = cover_angle;
	bool found_any = false;
	bool arc_started = false;

	struct CoverCandidate {
		float angle;
		Vector2 position;
		float dist_from_island;
		float score;
		bool valid;
	};
	std::vector<CoverCandidate> candidates;

	for (int i = 0; i < SWEEP_SAMPLES; i++) {
		float t = static_cast<float>(i) / static_cast<float>(SWEEP_SAMPLES - 1);
		float angle = cover_angle + SWEEP_RANGE * (t - 0.5f);
		angle = normalize_angle(angle);

		// Direction from island center at this angle
		Vector2 dir(std::sin(angle), std::cos(angle));

		// March outward from island edge.  The cover position should be close
		// enough to the island to benefit from concealment, but far enough for
		// the ship to maneuver safely.
		//
		// Use turning_radius * 1.5 as the max buffer from the island edge.
		// This gives the ship enough room to execute a full turn without
		// colliding with the island, while staying close enough to benefit
		// from the island's visual/radar screening.
		float start_dist = island.radius + ship_clearance;
		float max_buffer = turning_radius * 1.5f;
		float end_dist = std::max(start_dist + cell_size, island.radius + max_buffer);
		float step = cell_size;

		CoverCandidate best_at_angle;
		best_at_angle.angle = angle;
		best_at_angle.valid = false;
		best_at_angle.score = -std::numeric_limits<float>::infinity();

		for (float d = start_dist; d <= end_dist; d += step) {
			Vector2 test_pos = island.center + dir * d;

			if (!is_navigable(test_pos.x, test_pos.y, ship_clearance)) {
				continue;
			}

			// Score this position:
			// - Prefer positions farther from the island (more maneuvering room)
			// - Prefer positions closer to cover_angle (more directly behind the island)
			// - Must be at least min_engagement_range from island center in threat direction
			float angular_diff = std::abs(normalize_angle(angle - cover_angle));
			float angular_score = 1.0f - (angular_diff / SWEEP_RANGE);  // 1.0 at center, 0 at edges
			float distance_score = (d - start_dist) / (end_dist - start_dist);  // Prefer some distance

			// Check engagement range: the position must be within weapon range
			// We approximate: position should be within max_engagement_range of where threats would be
			float score = angular_score * 2.0f + distance_score * 1.0f;

			if (score > best_at_angle.score) {
				best_at_angle.position = test_pos;
				best_at_angle.dist_from_island = d;
				best_at_angle.score = score;
				best_at_angle.valid = true;
			}
		}

		if (best_at_angle.valid) {
			candidates.push_back(best_at_angle);

			if (!arc_started) {
				valid_arc_start = angle;
				arc_started = true;
			}
			valid_arc_end = angle;
			found_any = true;

			if (best_at_angle.score > best_score) {
				best_score = best_at_angle.score;
				result.best_position = best_at_angle.position;
				result.min_radius = island.radius + ship_clearance;
				result.max_radius = best_at_angle.dist_from_island;
			}
		}
	}

	if (!found_any) {
		return result;  // valid = false
	}

	result.arc_start = valid_arc_start;
	result.arc_end = valid_arc_end;
	result.valid = true;

	// Best heading: perpendicular to threat direction (broadside)
	// Two options — pick the one closer to the cover direction
	float broadside1 = normalize_angle(threat_angle + Math_PI * 0.5f);
	float broadside2 = normalize_angle(threat_angle - Math_PI * 0.5f);

	// Prefer the broadside heading that keeps the ship roughly facing the threat
	// (so guns can bear)
	float diff1 = std::abs(normalize_angle(broadside1 - cover_angle));
	float diff2 = std::abs(normalize_angle(broadside2 - cover_angle));
	result.best_heading = (diff1 <= diff2) ? broadside1 : broadside2;

	// Compute a zone radius for station-keeping based on the arc extent
	// The zone should be large enough to be comfortable but not so large that
	// the ship drifts out of cover
	if (!candidates.empty()) {
		float avg_dist = 0.0f;
		for (const auto &c : candidates) {
			avg_dist += c.dist_from_island;
		}
		avg_dist /= static_cast<float>(candidates.size());
		result.min_radius = island.radius + ship_clearance;
		result.max_radius = avg_dist;
	}

	return result;
}

// ============================================================================
// Safe destination selection
// ============================================================================

Vector2 NavigationMap::safe_nav_point(Vector2 ship_position, Vector2 candidate,
									  float clearance, float turning_radius) const {
	if (!built) return candidate;

	float dist = get_distance(candidate.x, candidate.y);

	// If the candidate has plenty of room, return it unchanged.
	// The "danger zone" is anything within turning_radius of land — a ship heading
	// straight at a coastline from this distance may not be able to turn away in time.
	float safe_threshold = clearance + turning_radius * 0.75f;
	if (dist >= safe_threshold) {
		return candidate;
	}

	// --- Step 1: If inside land or below hard clearance, push out along SDF gradient ---
	Vector2 adjusted = candidate;
	if (dist < clearance) {
		Vector2 grad = get_gradient(candidate.x, candidate.y);
		if (grad.length_squared() < 0.0001f) {
			// No gradient info — try pushing toward ship position as fallback
			Vector2 to_ship = ship_position - candidate;
			float to_ship_len = to_ship.length();
			if (to_ship_len > 0.1f) {
				grad = to_ship / to_ship_len;
			} else {
				return candidate; // Can't determine direction, bail
			}
		}
		// Push out of land: penetration depth + clearance + a buffer of half the turning radius
		float push_dist = std::abs(dist) + clearance + turning_radius * 0.5f;
		adjusted.x = candidate.x + grad.x * push_dist;
		adjusted.y = candidate.y + grad.y * push_dist;

		// Re-check — if still not navigable, iteratively push further
		float new_dist = get_distance(adjusted.x, adjusted.y);
		if (new_dist < clearance) {
			adjusted.x += grad.x * clearance;
			adjusted.y += grad.y * clearance;
		}
		dist = get_distance(adjusted.x, adjusted.y);
	}

	// --- Step 2: If near a coastline (within safe_threshold), adjust tangentially ---
	// The key insight: when a destination is close to shore, a ship approaching it
	// from far away will often be heading ~perpendicular to the coast. This creates
	// a situation where the ship can't turn away in time. We slide the destination
	// along the coast so the ship approaches more tangentially.
	if (dist < safe_threshold && dist > 0.0f) {
		// Get the coast normal (gradient points away from land = into water)
		Vector2 coast_normal = get_gradient(adjusted.x, adjusted.y);
		if (coast_normal.length_squared() < 0.0001f) {
			return adjusted;
		}

		// Compute approach direction: from ship to candidate
		Vector2 approach_dir = adjusted - ship_position;
		float approach_len = approach_dir.length();
		if (approach_len < 1.0f) {
			return adjusted;
		}
		approach_dir /= approach_len;

		// How perpendicular is the approach to the coastline?
		// dot(approach_dir, coast_normal) = cos(angle between approach and coast normal)
		// If |dot| is high, the ship is heading straight into/away from shore.
		// If |dot| is low, the ship is moving parallel to shore (safe).
		float perpendicularity = std::abs(approach_dir.dot(coast_normal));

		// Only adjust if approach is significantly perpendicular (> ~30 degrees from parallel)
		if (perpendicularity > 0.5f) {
			// Compute the tangent direction along the coast
			// tangent = perpendicular to coast_normal, choosing the direction that
			// most closely aligns with the current approach direction
			Vector2 tangent1(coast_normal.y, -coast_normal.x);  // rotate 90° CW
			Vector2 tangent2(-coast_normal.y, coast_normal.x);  // rotate 90° CCW

			// Pick the tangent that best aligns with approach direction
			Vector2 tangent = (approach_dir.dot(tangent1) > approach_dir.dot(tangent2))
				? tangent1 : tangent2;

			// How much to slide depends on:
			//   - How perpendicular the approach is (more perpendicular → more slide)
			//   - How close to shore (closer → more slide)
			//   - Ship turning radius (larger → more slide needed)
			float proximity = 1.0f - (dist / safe_threshold);  // 0 at threshold, 1 at shore
			float slide_strength = perpendicularity * proximity;

			// Slide distance: up to 1.5× turning radius for the worst case
			float slide_dist = turning_radius * 1.5f * slide_strength;

			// Apply tangential slide
			Vector2 slid = adjusted;
			slid.x += tangent.x * slide_dist;
			slid.y += tangent.y * slide_dist;

			// Also push further away from shore proportional to perpendicularity
			float push_extra = turning_radius * 0.5f * slide_strength;
			slid.x += coast_normal.x * push_extra;
			slid.y += coast_normal.y * push_extra;

			// Verify the slid point is actually navigable
			float slid_dist = get_distance(slid.x, slid.y);
			if (slid_dist >= clearance) {
				adjusted = slid;
			} else {
				// Slid point is worse — just push the original further from shore
				float needed = safe_threshold - dist;
				adjusted.x += coast_normal.x * needed;
				adjusted.y += coast_normal.y * needed;
			}
		} else {
			// Approach is already roughly parallel — just ensure minimum distance
			if (dist < clearance + turning_radius * 0.25f) {
				float needed = (clearance + turning_radius * 0.25f) - dist;
				adjusted.x += coast_normal.x * needed;
				adjusted.y += coast_normal.y * needed;
			}
		}
	}

	return adjusted;
}

Vector2 NavigationMap::validate_destination(Vector2 ship_position, Vector2 destination,
											float clearance, float turning_radius) const {
	if (!built) return destination;

	// First pass: make the destination itself safe
	Vector2 safe_dest = safe_nav_point(ship_position, destination, clearance, turning_radius);

	// Second pass: check if the path from ship to destination passes dangerously
	// close to any land. Use SDF raycast to find the closest land approach.
	RayResult ray = raycast_internal(ship_position, safe_dest, clearance + turning_radius * 0.5f);

	if (!ray.hit) {
		// Clear path — destination is safe
		return safe_dest;
	}

	// The direct line clips land. The A* pathfinder will route around it, but
	// we should check whether the destination itself is in a "pocket" that
	// forces the ship to approach from a dangerous angle.

	// Check: is the destination on the far side of an island from the ship?
	// If so, the pathfinder will route around, and the last segment of the path
	// will approach from a different direction. Re-validate from the midpoint
	// of the ray hit to the destination.
	Vector2 approach_point = ray.position;

	// Get the coast normal at the point where we'd clip land
	Vector2 clip_normal = get_gradient(approach_point.x, approach_point.y);
	if (clip_normal.length_squared() < 0.0001f) {
		return safe_dest;
	}

	// The ship will actually approach the destination from roughly where the
	// path curves around the island. Check if the destination is in a narrow
	// gap or inlet where any approach would be dangerous.
	float dest_dist = get_distance(safe_dest.x, safe_dest.y);
	if (dest_dist < clearance + turning_radius) {
		// Destination is tight — make sure it's approached tangentially
		// by re-running safe_nav_point with the likely approach direction
		// (the direction from the ray hit point, offset by the coast normal)
		Vector2 likely_approach = approach_point + clip_normal * turning_radius;
		safe_dest = safe_nav_point(likely_approach, safe_dest, clearance, turning_radius);
	}

	return safe_dest;
}

Dictionary NavigationMap::safe_nav_point_dict(Vector2 ship_position, Vector2 candidate,
											  float clearance, float turning_radius) const {
	Vector2 result = safe_nav_point(ship_position, candidate, clearance, turning_radius);
	Dictionary dict;
	dict["position"] = result;
	dict["adjusted"] = result.distance_to(candidate) > 1.0f;
	return dict;
}

Dictionary NavigationMap::validate_destination_dict(Vector2 ship_position, Vector2 destination,
													float clearance, float turning_radius) const {
	Vector2 result = validate_destination(ship_position, destination, clearance, turning_radius);
	Dictionary dict;
	dict["position"] = result;
	dict["adjusted"] = result.distance_to(destination) > 1.0f;
	return dict;
}

// ============================================================================
// SDF-cell-based cover candidate search
// ============================================================================

TypedArray<Dictionary> NavigationMap::find_cover_candidates(
		int island_id,
		PackedVector2Array threat_positions,
		Vector2 danger_center,
		Vector2 ship_position,
		float ship_clearance,
		float gun_range,
		int max_results,
		int max_candidates) const {

	TypedArray<Dictionary> output;

	if (!built) return output;
	if (island_id < 0 || island_id >= static_cast<int>(islands.size())) return output;

	const IslandData &island = islands[island_id];
	int threat_count = threat_positions.size();

	if (threat_count == 0) return output;

	// --- Strategy ---
	// Walk a band of SDF cells around the island where:
	//   sdf >= ship_clearance  (navigable)
	//   sdf <= ship_clearance + buffer  (close to shore = good cover)
	//
	// For each cell, test LOS (SDF raycast, clearance=0) to every threat.
	// Score by concealment, shore proximity, travel cost, and opposite-side bias.
	//
	// Shootability is NOT evaluated here — shells travel in parabolic arcs and
	// CAs shoot OVER islands. The GDScript caller validates shootability via
	// the full ballistic simulation (Gun.sim_can_shoot_over_terrain) by
	// iterating through this ranked list asynchronously.

	float search_margin = ship_clearance + cell_size * 6.0f;
	float max_sdf_for_cover = ship_clearance + cell_size * 4.0f;

	float box_min_x = island.center.x - island.radius - search_margin;
	float box_max_x = island.center.x + island.radius + search_margin;
	float box_min_z = island.center.y - island.radius - search_margin;
	float box_max_z = island.center.y + island.radius + search_margin;

	float gx_min_f, gz_min_f, gx_max_f, gz_max_f;
	world_to_grid(box_min_x, box_min_z, gx_min_f, gz_min_f);
	world_to_grid(box_max_x, box_max_z, gx_max_f, gz_max_f);

	int gx_min = std::max(0, static_cast<int>(std::floor(gx_min_f)));
	int gz_min = std::max(0, static_cast<int>(std::floor(gz_min_f)));
	int gx_max = std::min(grid_width - 1, static_cast<int>(std::ceil(gx_max_f)));
	int gz_max = std::min(grid_height - 1, static_cast<int>(std::ceil(gz_max_f)));

	// --- Phase 1: collect navigable cells in the near-shore band ---
	struct CoverCell {
		float wx, wz;
		float sdf_val;
	};
	std::vector<CoverCell> candidates;
	candidates.reserve(max_candidates * 2);

	int area_cells = (gx_max - gx_min + 1) * (gz_max - gz_min + 1);
	int stride = 1;
	if (area_cells > max_candidates * 8)  stride = 2;
	if (area_cells > max_candidates * 32) stride = 3;

	for (int iz = gz_min; iz <= gz_max; iz += stride) {
		for (int ix = gx_min; ix <= gx_max; ix += stride) {
			float sdf_val = get_cell(ix, iz);
			if (sdf_val < ship_clearance) continue;
			if (sdf_val > max_sdf_for_cover) continue;

			float wx, wz;
			grid_to_world(ix, iz, wx, wz);

			float dx_d = wx - danger_center.x;
			float dz_d = wz - danger_center.y;
			if (dx_d * dx_d + dz_d * dz_d > gun_range * gun_range) continue;

			candidates.push_back({wx, wz, sdf_val});
		}
	}

	if (candidates.empty()) return output;

	// Subsample if too many
	if (static_cast<int>(candidates.size()) > max_candidates) {
		int keep_stride = static_cast<int>(candidates.size()) / max_candidates + 1;
		std::vector<CoverCell> sub;
		sub.reserve(max_candidates);
		for (size_t i = 0; i < candidates.size(); i += keep_stride) {
			sub.push_back(candidates[i]);
		}
		candidates.swap(sub);
	}

	// Pre-compute average threat position for opposite-side bias
	float avg_tx = 0.0f, avg_tz = 0.0f;
	for (int ti = 0; ti < threat_count; ti++) {
		avg_tx += threat_positions[ti].x;
		avg_tz += threat_positions[ti].y;
	}
	avg_tx /= threat_count;
	avg_tz /= threat_count;
	float island_to_threat_x = avg_tx - island.center.x;
	float island_to_threat_z = avg_tz - island.center.y;
	float len_t = std::sqrt(island_to_threat_x * island_to_threat_x + island_to_threat_z * island_to_threat_z);

	float proximity_range = max_sdf_for_cover - ship_clearance;

	// --- Phase 2: score each candidate ---
	struct ScoredCell {
		float wx, wz;
		float sdf_val;
		int hidden_count;
		float score;
	};
	std::vector<ScoredCell> scored;
	scored.reserve(candidates.size());

	for (size_t ci = 0; ci < candidates.size(); ci++) {
		const CoverCell &cell = candidates[ci];
		Vector2 cell_pos(cell.wx, cell.wz);

		// Test LOS to each threat
		int hidden_count = 0;
		for (int ti = 0; ti < threat_count; ti++) {
			RayResult ray = raycast_internal(cell_pos, threat_positions[ti], 0.0f);
			if (ray.hit) hidden_count++;
		}

		float score = 0.0f;

		// Primary: threats hidden (1000 per threat)
		score += static_cast<float>(hidden_count) * 1000.0f;

		// Proximity to shore: tighter = better (up to 80 pts)
		if (proximity_range > 0.001f) {
			score += (1.0f - (cell.sdf_val - ship_clearance) / proximity_range) * 80.0f;
		}

		// Travel distance penalty
		float dx_s = cell.wx - ship_position.x;
		float dz_s = cell.wz - ship_position.y;
		score -= std::sqrt(dx_s * dx_s + dz_s * dz_s) * 0.03f;

		// Opposite-side bias
		if (len_t > 0.001f) {
			float ic_x = cell.wx - island.center.x;
			float ic_z = cell.wz - island.center.y;
			float len_c = std::sqrt(ic_x * ic_x + ic_z * ic_z);
			if (len_c > 0.001f) {
				float dot = (ic_x * island_to_threat_x + ic_z * island_to_threat_z) / (len_c * len_t);
				score += (-dot) * 50.0f;
			}
		}

		scored.push_back({cell.wx, cell.wz, cell.sdf_val, hidden_count, score});
	}

	// --- Phase 3: for top coarse candidates, do fine-grained local refinement ---
	// Sort descending by score
	std::sort(scored.begin(), scored.end(),
			  [](const ScoredCell &a, const ScoredCell &b) { return a.score > b.score; });

	// Take the top N coarse winners and refine each with a 5×5 local search
	int refine_count = std::min(static_cast<int>(scored.size()), max_results * 2);
	std::vector<ScoredCell> refined;
	refined.reserve(refine_count * 25);

	for (int ri = 0; ri < refine_count; ri++) {
		const ScoredCell &base = scored[ri];
		// Include the coarse cell itself
		refined.push_back(base);

		float fine_gx, fine_gz;
		world_to_grid(base.wx, base.wz, fine_gx, fine_gz);
		int fine_cx = static_cast<int>(std::round(fine_gx));
		int fine_cz = static_cast<int>(std::round(fine_gz));

		for (int dz = -2; dz <= 2; dz++) {
			for (int dx = -2; dx <= 2; dx++) {
				if (dx == 0 && dz == 0) continue;
				int nx = fine_cx + dx;
				int nz = fine_cz + dz;
				if (!in_bounds(nx, nz)) continue;

				float sdf_val = get_cell(nx, nz);
				if (sdf_val < ship_clearance) continue;
				if (sdf_val > max_sdf_for_cover) continue;

				float wx, wz;
				grid_to_world(nx, nz, wx, wz);

				float dx_d = wx - danger_center.x;
				float dz_d = wz - danger_center.y;
				if (dx_d * dx_d + dz_d * dz_d > gun_range * gun_range) continue;

				Vector2 cell_pos(wx, wz);

				int hidden_count = 0;
				for (int ti = 0; ti < threat_count; ti++) {
					RayResult ray = raycast_internal(cell_pos, threat_positions[ti], 0.0f);
					if (ray.hit) hidden_count++;
				}

				float score = static_cast<float>(hidden_count) * 1000.0f;

				if (proximity_range > 0.001f) {
					score += (1.0f - (sdf_val - ship_clearance) / proximity_range) * 80.0f;
				}

				float dx_s2 = wx - ship_position.x;
				float dz_s2 = wz - ship_position.y;
				score -= std::sqrt(dx_s2 * dx_s2 + dz_s2 * dz_s2) * 0.03f;

				if (len_t > 0.001f) {
					float ic_x = wx - island.center.x;
					float ic_z = wz - island.center.y;
					float len_c = std::sqrt(ic_x * ic_x + ic_z * ic_z);
					if (len_c > 0.001f) {
						float dot = (ic_x * island_to_threat_x + ic_z * island_to_threat_z) / (len_c * len_t);
						score += (-dot) * 50.0f;
					}
				}

				refined.push_back({wx, wz, sdf_val, hidden_count, score});
			}
		}
	}

	// --- Phase 4: sort all refined candidates, deduplicate nearby, and return top N ---
	std::sort(refined.begin(), refined.end(),
			  [](const ScoredCell &a, const ScoredCell &b) { return a.score > b.score; });

	// Deduplicate: skip candidates within 1.5 cells of an already-emitted one
	float dedup_dist_sq = (cell_size * 1.5f) * (cell_size * 1.5f);
	std::vector<ScoredCell> final_list;
	final_list.reserve(max_results);

	for (const auto &c : refined) {
		if (static_cast<int>(final_list.size()) >= max_results) break;

		bool too_close = false;
		for (const auto &existing : final_list) {
			float ddx = c.wx - existing.wx;
			float ddz = c.wz - existing.wz;
			if (ddx * ddx + ddz * ddz < dedup_dist_sq) {
				too_close = true;
				break;
			}
		}
		if (too_close) continue;

		final_list.push_back(c);
	}

	// Build output array
	for (const auto &c : final_list) {
		Dictionary d;
		d["position"] = Vector2(c.wx, c.wz);
		d["hidden_count"] = c.hidden_count;
		d["total_threats"] = threat_count;
		d["all_hidden"] = (c.hidden_count >= threat_count);
		d["sdf_distance"] = c.sdf_val;
		d["score"] = c.score;
		output.push_back(d);
	}

	return output;
}

// ============================================================================
// Debug / Visualization
// ============================================================================

PackedFloat32Array NavigationMap::get_sdf_data() const {
	PackedFloat32Array result;
	result.resize(static_cast<int>(sdf_grid.size()));
	for (size_t i = 0; i < sdf_grid.size(); i++) {
		result[static_cast<int>(i)] = sdf_grid[i];
	}
	return result;
}

int NavigationMap::get_grid_width() const {
	return grid_width;
}

int NavigationMap::get_grid_height() const {
	return grid_height;
}

float NavigationMap::get_cell_size_value() const {
	return cell_size;
}

bool NavigationMap::is_built() const {
	return built;
}

int NavigationMap::get_island_count() const {
	return static_cast<int>(islands.size());
}
