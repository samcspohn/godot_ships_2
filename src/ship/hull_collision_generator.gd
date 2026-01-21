extends Node

class_name HullCollisionGenerator

## Utility for generating simplified convex hull collision shapes for ship physics.
##
## This creates physics-appropriate convex shapes from the ship's hull meshes,
## separate from the detailed concave armor meshes used for projectile raytracing.
##
## Usage:
##   var collision_shape = HullCollisionGenerator.generate_hull_collision(ship_node)
##   ship_rigid_body.add_child(collision_shape)

## Collision layer for ship-to-ship and ship-to-ground physics (layer 3)
const PHYSICS_COLLISION_LAYER: int = 1 << 2  # Layer 3
## Collision mask - collide with terrain (layer 1) and other ships (layer 3)
const PHYSICS_COLLISION_MASK: int = 1 | (1 << 2)  # Layers 1 and 3

## Threshold for considering a point on the centerline (X = 0)
const CENTERLINE_THRESHOLD: float = 0.5

## Default max vertices for simplification
const DEFAULT_MAX_VERTICES: int = 128


## Generates a convex hull collision shape from the ship's hull meshes.
## Returns a CollisionShape3D node ready to be added to a RigidBody3D.
## If mirror_symmetry is true, enforces port/starboard symmetry by mirroring vertices.
static func generate_hull_collision(ship: Node3D, include_superstructure: bool = false, mirror_symmetry: bool = true) -> CollisionShape3D:
	var all_points: PackedVector3Array = PackedVector3Array()

	# Collect vertices from hull-related meshes
	_collect_hull_vertices(ship, all_points, include_superstructure)

	if all_points.size() < 4:
		push_warning("HullCollisionGenerator: Not enough vertices to create convex hull")
		return null

	# Apply mirror symmetry with integrated simplification if enabled
	if mirror_symmetry:
		all_points = apply_mirror_symmetry_with_simplify(all_points, true, DEFAULT_MAX_VERTICES)
	else:
		all_points = simplify_points(all_points, DEFAULT_MAX_VERTICES)

	# Create convex hull from collected points
	var convex_shape = ConvexPolygonShape3D.new()
	convex_shape.points = all_points

	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = convex_shape
	collision_shape.name = "HullPhysicsCollision"

	return collision_shape


## Generates multiple convex hull shapes for better collision accuracy.
## Splits the hull into bow, midship, and stern sections.
## If mirror_symmetry is true, enforces port/starboard symmetry by mirroring vertices.
static func generate_segmented_hull_collision(ship: Node3D, mirror_symmetry: bool = true) -> Array[CollisionShape3D]:
	var shapes: Array[CollisionShape3D] = []
	var all_points: PackedVector3Array = PackedVector3Array()

	# Collect all hull vertices
	_collect_hull_vertices(ship, all_points, false)

	if all_points.size() < 4:
		push_warning("HullCollisionGenerator: Not enough vertices to create convex hull")
		return shapes

	# Apply mirror symmetry with integrated simplification if enabled
	if mirror_symmetry:
		all_points = apply_mirror_symmetry_with_simplify(all_points, true, DEFAULT_MAX_VERTICES)
	else:
		all_points = simplify_points(all_points, DEFAULT_MAX_VERTICES)

	# Calculate bounding box to determine segmentation
	var min_z: float = INF
	var max_z: float = -INF
	for point in all_points:
		min_z = min(min_z, point.z)
		max_z = max(max_z, point.z)

	var length = max_z - min_z
	var segment_size = length / 3.0

	# Create three segments: bow, midship, stern
	var bow_points: PackedVector3Array = PackedVector3Array()
	var mid_points: PackedVector3Array = PackedVector3Array()
	var stern_points: PackedVector3Array = PackedVector3Array()

	for point in all_points:
		var relative_z = point.z - min_z
		if relative_z < segment_size:
			stern_points.append(point)
		elif relative_z < segment_size * 2:
			mid_points.append(point)
		else:
			bow_points.append(point)

	# Create collision shapes for each segment
	if bow_points.size() >= 4:
		var bow_shape = _create_convex_collision("BowPhysicsCollision", bow_points)
		if bow_shape:
			shapes.append(bow_shape)

	if mid_points.size() >= 4:
		var mid_shape = _create_convex_collision("MidshipPhysicsCollision", mid_points)
		if mid_shape:
			shapes.append(mid_shape)

	if stern_points.size() >= 4:
		var stern_shape = _create_convex_collision("SternPhysicsCollision", stern_points)
		if stern_shape:
			shapes.append(stern_shape)

	return shapes


## Creates a simplified box-based hull approximation for performance.
## Uses the hull's AABB with optional waterline cutoff.
static func generate_box_hull_collision(ship: Node3D, waterline_offset: float = 0.0) -> CollisionShape3D:
	var aabb = _calculate_hull_aabb(ship)

	if aabb.size == Vector3.ZERO:
		push_warning("HullCollisionGenerator: Could not calculate hull AABB")
		return null

	# Adjust for waterline - only include underwater portion for physics
	var adjusted_size = aabb.size
	var adjusted_position = aabb.position + aabb.size / 2.0

	if waterline_offset > 0.0:
		# Reduce height to only include portion below waterline
		var underwater_height = min(aabb.size.y, waterline_offset - aabb.position.y)
		if underwater_height > 0:
			adjusted_size.y = underwater_height
			adjusted_position.y = aabb.position.y + underwater_height / 2.0

	var box_shape = BoxShape3D.new()
	box_shape.size = adjusted_size

	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = box_shape
	collision_shape.position = adjusted_position
	collision_shape.name = "HullBoxCollision"

	return collision_shape


## Generates a hull shape from specific mesh nodes by name pattern.
static func generate_from_mesh_pattern(ship: Node3D, pattern: String) -> CollisionShape3D:
	var points: PackedVector3Array = PackedVector3Array()
	_collect_vertices_by_pattern(ship, pattern, points)

	if points.size() < 4:
		push_warning("HullCollisionGenerator: No meshes matching pattern '%s'" % pattern)
		return null

	return _create_convex_collision("HullPhysicsCollision", points)


## Configures a ship's collision layers for physics interaction.
## Call this after adding the hull collision shape.
static func configure_ship_collision(ship: RigidBody3D) -> void:
	# Layer 3 for ship-to-ship physics
	ship.collision_layer = PHYSICS_COLLISION_LAYER
	# Collide with terrain (layer 1) and other ships (layer 3)
	ship.collision_mask = PHYSICS_COLLISION_MASK

	# Enable contact monitoring for collision detection
	ship.contact_monitor = true
	ship.max_contacts_reported = 4


## Simplifies a point cloud by reducing vertex count.
## Keeps extreme values in each direction per cell to preserve convex hull shape.
## Useful for performance when hull meshes are very detailed.
static func simplify_points(points: PackedVector3Array, target_count: int = 64) -> PackedVector3Array:
	if points.size() <= target_count:
		return points

	# Use spatial hashing to reduce points, keeping extreme values for convex hull
	var cell_size = _calculate_optimal_cell_size(points, target_count)
	var grid: Dictionary = {}  # Maps cell_key to list of points in that cell

	# Step 1: Collect all points into cells
	for point in points:
		var cell_key = Vector3i(
			int(point.x / cell_size) if point.x >= 0 else int(point.x / cell_size) - 1,
			int(point.y / cell_size) if point.y >= 0 else int(point.y / cell_size) - 1,
			int(point.z / cell_size) if point.z >= 0 else int(point.z / cell_size) - 1
		)

		if not grid.has(cell_key):
			grid[cell_key] = []
		grid[cell_key].append(point)

	# Step 2: For each cell, find extreme points from the complete list
	var simplified_set: Dictionary = {}  # Use as set to avoid duplicates
	var simplified = PackedVector3Array()

	for cell_key in grid:
		var cell_points: Array = grid[cell_key]
		if cell_points.is_empty():
			continue

		# Find extremes from the complete list of points in this cell
		var max_x_point = cell_points[0]
		var min_x_point = cell_points[0]
		var max_y_point = cell_points[0]
		var min_y_point = cell_points[0]
		var max_z_point = cell_points[0]
		var min_z_point = cell_points[0]

		var extreme_point = Vector3.ZERO
		for point in cell_points:
			extreme_point += point
			if point.x > max_x_point.x:
				max_x_point = point
			if point.x < min_x_point.x:
				min_x_point = point
			if point.y > max_y_point.y:
				max_y_point = point
			if point.y < min_y_point.y:
				min_y_point = point
			if point.z > max_z_point.z:
				max_z_point = point
			if point.z < min_z_point.z:
				min_z_point = point
		extreme_point /= cell_points.size()

		if abs(extreme_point.x) > abs(extreme_point.y):
			if abs(extreme_point.x) > abs(extreme_point.z):
				if extreme_point.x >= 0.0:
					simplified.append(max_x_point)
				else:
					simplified.append(min_x_point)
			else:
				if extreme_point.z >= 0.0:
					simplified.append(max_z_point)
				else:
					simplified.append(min_z_point)
		else:
			if abs(extreme_point.y) > abs(extreme_point.z):
				if extreme_point.y >= 0.0:
					simplified.append(max_y_point)
				else:
					simplified.append(min_y_point)
			else:
				if extreme_point.z >= 0:
					simplified.append(max_z_point)
				else:
					simplified.append(min_z_point)
	# 	# Add all extreme points (using string key for deduplication)
	# 	for extreme_point in [max_x_point, min_x_point, max_y_point, min_y_point, max_z_point, min_z_point]:
	# 		var key = "%.4f,%.4f,%.4f" % [extreme_point.x, extreme_point.y, extreme_point.z]
	# 		simplified_set[key] = extreme_point

	# var simplified = PackedVector3Array()
	# for point in simplified_set.values():
	# 	simplified.append(point)

	return simplified


# ============================================================================
# Private helper functions
# ============================================================================

static func _collect_hull_vertices(node: Node, points: PackedVector3Array, include_superstructure: bool) -> void:
	var node_name_lower = node.name.to_lower()

	# Check if this is a hull-related mesh
	var is_hull_mesh = (
		node_name_lower.contains("hull") or
		node_name_lower.contains("bow") or
		node_name_lower.contains("stern") or
		node_name_lower.contains("casemate") or
		node_name_lower.contains("citadel")
	)

	if include_superstructure:
		is_hull_mesh = is_hull_mesh or node_name_lower.contains("superstructure")

	# Skip armor collision meshes (they're handled separately for raycasting)
	var is_armor_col = node_name_lower.ends_with("_col")

	if node is MeshInstance3D and is_hull_mesh and not is_armor_col:
		var mesh_instance = node as MeshInstance3D
		_extract_mesh_vertices(mesh_instance, points)

	# Recurse into children
	for child in node.get_children():
		_collect_hull_vertices(child, points, include_superstructure)


static func _collect_vertices_by_pattern(node: Node, pattern: String, points: PackedVector3Array) -> void:
	if node is MeshInstance3D and node.name.matchn(pattern):
		var mesh_instance = node as MeshInstance3D
		_extract_mesh_vertices(mesh_instance, points)

	for child in node.get_children():
		_collect_vertices_by_pattern(child, pattern, points)


static func _extract_mesh_vertices(mesh_instance: MeshInstance3D, points: PackedVector3Array) -> void:
	var mesh = mesh_instance.mesh
	if mesh == null:
		return

	var global_transform = mesh_instance.global_transform

	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		if arrays.size() > Mesh.ARRAY_VERTEX:
			var vertices = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			if vertices:
				for vertex in vertices:
					# Transform to ship-local space
					var world_pos = global_transform * vertex
					# If mesh_instance is child of ship, we want local coords
					var ship = _find_ship_parent(mesh_instance)
					if ship:
						var local_pos = ship.global_transform.affine_inverse() * world_pos
						points.append(local_pos)
					else:
						points.append(world_pos)


static func _find_ship_parent(node: Node) -> Node3D:
	var current = node.get_parent()
	while current:
		if current is RigidBody3D and current.has_method("get_aabb"):
			return current
		current = current.get_parent()
	return null


static func _create_convex_collision(shape_name: String, points: PackedVector3Array) -> CollisionShape3D:
	if points.size() < 4:
		return null

	# Simplify if too many points (Godot has limits on convex shapes)
	var simplified = simplify_points(points, 256)

	var convex_shape = ConvexPolygonShape3D.new()
	convex_shape.points = simplified

	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = convex_shape
	collision_shape.name = shape_name

	return collision_shape


static func _calculate_hull_aabb(ship: Node3D) -> AABB:
	var combined_aabb = AABB()
	var found_any = false

	_collect_aabb_recursive(ship, combined_aabb, found_any)

	return combined_aabb


static func _collect_aabb_recursive(node: Node, combined_aabb: AABB, found_any: bool) -> void:
	var node_name_lower = node.name.to_lower()
	var is_hull_mesh = (
		node_name_lower.contains("hull") or
		node_name_lower.contains("bow") or
		node_name_lower.contains("stern")
	)

	if node is MeshInstance3D and is_hull_mesh:
		var mesh_instance = node as MeshInstance3D
		var mesh_aabb = mesh_instance.get_aabb()
		# Transform AABB to parent space
		var transformed_aabb = mesh_instance.transform * mesh_aabb

		if not found_any:
			combined_aabb.position = transformed_aabb.position
			combined_aabb.size = transformed_aabb.size
			found_any = true
		else:
			combined_aabb = combined_aabb.merge(transformed_aabb)

	for child in node.get_children():
		_collect_aabb_recursive(child, combined_aabb, found_any)


static func _calculate_optimal_cell_size(points: PackedVector3Array, target_count: int) -> float:
	if points.size() == 0:
		return 1.0

	# Calculate bounding box
	var min_pt = points[0]
	var max_pt = points[0]

	for point in points:
		min_pt.x = min(min_pt.x, point.x)
		min_pt.y = min(min_pt.y, point.y)
		min_pt.z = min(min_pt.z, point.z)
		max_pt.x = max(max_pt.x, point.x)
		max_pt.y = max(max_pt.y, point.y)
		max_pt.z = max(max_pt.z, point.z)

	var size = max_pt - min_pt
	var volume = size.x * size.y * size.z

	# Estimate cell size to get approximately target_count cells
	if volume > 0 and target_count > 0:
		return pow(volume / float(target_count), 1.0 / 3.0)

	return max(size.x, max(size.y, size.z)) / 10.0


# ============================================================================
# Symmetry mirroring
# ============================================================================

## Enforces port/starboard symmetry with integrated simplification.
## This is the preferred method as it:
## 1. Extracts and preserves critical centerline vertices (bow tip, stern tip, keel extremes)
## 2. Simplifies starboard vertices first
## 3. Then mirrors to create perfectly symmetric port side
static func apply_mirror_symmetry_with_simplify(points: PackedVector3Array, do_simplify: bool, max_verts: int) -> PackedVector3Array:
	# Step 1: Find the Z extents to identify bow and stern tips
	var min_z: float = INF
	var max_z: float = -INF
	var min_y: float = INF
	var max_y: float = -INF

	for point in points:
		min_z = min(min_z, point.z)
		max_z = max(max_z, point.z)
		min_y = min(min_y, point.y)
		max_y = max(max_y, point.y)

	var z_length = max_z - min_z
	var bow_zone = max_z - z_length * 0.05  # Front 5% is bow tip zone
	var stern_zone = min_z + z_length * 0.05  # Rear 5% is stern tip zone

	# Step 2: Separate vertices into categories
	var critical_centerline: PackedVector3Array = PackedVector3Array()  # Never simplified
	var regular_centerline: PackedVector3Array = PackedVector3Array()  # Can be simplified
	var starboard_points: PackedVector3Array = PackedVector3Array()  # Will be simplified then mirrored

	for point in points:
		var is_centerline = abs(point.x) <= CENTERLINE_THRESHOLD
		var is_bow_tip = point.z >= bow_zone and is_centerline
		var is_stern_tip = point.z <= stern_zone and is_centerline
		var is_keel_extreme = (point.y <= min_y + 1.0 or point.y >= max_y - 1.0) and is_centerline

		if is_bow_tip or is_stern_tip or is_keel_extreme:
			# Critical centerline point - never simplify
			critical_centerline.append(Vector3(0.0, point.y, point.z))  # Snap to exact centerline
		elif is_centerline:
			# Regular centerline point - can be simplified but not mirrored
			regular_centerline.append(Vector3(0.0, point.y, point.z))  # Snap to exact centerline
		elif point.x > 0:
			# Starboard point - will be simplified and mirrored
			starboard_points.append(point)
		# Ignore port side points - they'll be recreated by mirroring

	# Step 3: Simplify starboard and regular centerline if enabled
	if do_simplify and starboard_points.size() > 0:
		# Reserve some vertices for centerline, rest for starboard
		var centerline_budget = min(regular_centerline.size(), max_verts / 4)
		var starboard_budget = max_verts / 2 - critical_centerline.size() / 2 - centerline_budget / 2
		starboard_budget = max(starboard_budget, 16)  # Minimum vertices

		starboard_points = simplify_points(starboard_points, starboard_budget)

		if regular_centerline.size() > centerline_budget:
			regular_centerline = _simplify_centerline(regular_centerline, centerline_budget)

	# Step 4: Deduplicate critical centerline points
	critical_centerline = _deduplicate_points(critical_centerline, 0.5)

	# Step 5: Build final point array
	var result: PackedVector3Array = PackedVector3Array()

	# Add critical centerline points (already at X=0)
	for point in critical_centerline:
		result.append(point)

	# Add regular centerline points (already at X=0)
	for point in regular_centerline:
		result.append(point)

	# Add starboard points and their port mirrors
	for point in starboard_points:
		result.append(point)  # Starboard
		result.append(Vector3(-point.x, point.y, point.z))  # Port mirror

	return result


## Simple mirror symmetry without simplification integration.
## Use apply_mirror_symmetry_with_simplify for better results.
static func apply_mirror_symmetry(points: PackedVector3Array) -> PackedVector3Array:
	return apply_mirror_symmetry_with_simplify(points, false, 0)


## Simplify centerline points while preserving Z distribution.
## Uses 1D simplification along the Z axis.
static func _simplify_centerline(points: PackedVector3Array, target_count: int) -> PackedVector3Array:
	if points.size() <= target_count:
		return points

	# Sort by Z position
	var point_list: Array = []
	for point in points:
		point_list.append(point)

	point_list.sort_custom(func(a, b): return a.z < b.z)

	# Sample evenly along Z
	var result: PackedVector3Array = PackedVector3Array()
	var step = float(point_list.size() - 1) / float(target_count - 1) if target_count > 1 else 1.0

	for i in range(target_count):
		var idx = int(i * step)
		idx = min(idx, point_list.size() - 1)
		result.append(point_list[idx])

	return result


## Remove duplicate points within threshold distance.
static func _deduplicate_points(points: PackedVector3Array, threshold: float) -> PackedVector3Array:
	var result: PackedVector3Array = PackedVector3Array()

	for point in points:
		var is_duplicate = false
		for existing in result:
			if point.distance_to(existing) < threshold:
				is_duplicate = true
				break
		if not is_duplicate:
			result.append(point)

	return result
