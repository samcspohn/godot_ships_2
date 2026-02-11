extends Node3D
class_name Map

@export var islands: Array[StaticBody3D]

# Preprocessed edge points for each island
# Dictionary[StaticBody3D, Array[Vector3]]
var island_edge_points: Dictionary = {}

# Grid scanning parameters
const GRID_CELL_SIZE: float = 100.0  # Distance between ray casts
const GRID_MARGIN: float = 100.0  # How far beyond island AABB to scan
const RAY_HEIGHT: float = 10000.0  # Height to cast rays from
const WATER_LEVEL: float = 0.0  # Y level of water

var init = false
#func _ready():
	#call_deferred("preprocess_islands")
	#preprocess_islands()

func _physics_process(delta: float) -> void:
	if !init:
		preprocess_islands()
		init = true

func preprocess_islands():
	"""Scan all islands and find edge points where water meets land."""
	# Ensure we're in a physics frame so raycasting works
	#if not Engine.is_in_physics_frame():
		#call_deferred("preprocess_islands")
		#return

	for island in islands:
		if is_instance_valid(island):
			var edge_points = find_island_edge_points(island)
			island_edge_points[island] = edge_points
			print("Island ", island.name, ": found ", edge_points.size(), " edge points")


func find_island_edge_points(island: StaticBody3D) -> Array[Vector3]:
	"""Find all water/land transition points around an island using grid scanning."""
	var points: Array[Vector3] = []
	var point_set: Dictionary = {}  # Use dict as set to avoid duplicates

	# Get island AABB
	var aabb = get_island_aabb(island)
	if aabb.size == Vector3.ZERO:
		return points

	# Expand AABB by margin
	var scan_min = aabb.position - Vector3(GRID_MARGIN, 0, GRID_MARGIN)
	var scan_max = aabb.end + Vector3(GRID_MARGIN, 0, GRID_MARGIN)

	var space_state = get_world_3d().direct_space_state
	var ray = PhysicsRayQueryParameters3D.new()
	ray.collision_mask = 1  # Terrain layer
	ray.collide_with_bodies = true

	# Scan columns (along Z axis)
	var x = scan_min.x
	while x <= scan_max.x:
		scan_line_for_edges(x, scan_min.z, scan_max.z, true, space_state, ray, point_set)
		x += GRID_CELL_SIZE

	# Scan rows (along X axis)
	var z = scan_min.z
	while z <= scan_max.z:
		scan_line_for_edges(z, scan_min.x, scan_max.x, false, space_state, ray, point_set)
		z += GRID_CELL_SIZE

	# Convert point set to array
	for point in point_set.keys():
		points.append(point)

	return points


func scan_line_for_edges(fixed_coord: float, start: float, end: float, is_column: bool, space_state: PhysicsDirectSpaceState3D, ray: PhysicsRayQueryParameters3D, point_set: Dictionary):
	"""
	Scan a line (column or row) for water/land transitions.
	is_column: if true, fixed_coord is X and we iterate Z; if false, fixed_coord is Z and we iterate X
	"""
	var was_land = false
	var last_water_point = Vector3.ZERO
	var current = start

	while current <= end:
		var test_pos: Vector3
		if is_column:
			test_pos = Vector3(fixed_coord, WATER_LEVEL, current)
		else:
			test_pos = Vector3(current, WATER_LEVEL, fixed_coord)

		var is_land = is_point_on_land(test_pos, space_state, ray)

		if is_land and not was_land:
			# Transition from water to land - record the last water point
			if last_water_point != Vector3.ZERO:
				add_point_to_set(last_water_point, point_set)
		elif not is_land and was_land:
			# Transition from land to water - record this water point
			add_point_to_set(test_pos, point_set)

		was_land = is_land
		if not is_land:
			last_water_point = test_pos

		current += GRID_CELL_SIZE


func is_point_on_land(pos: Vector3, space_state: PhysicsDirectSpaceState3D, ray: PhysicsRayQueryParameters3D) -> bool:
	"""Check if a point is on land by casting a ray down from above."""
	ray.from = Vector3(pos.x, RAY_HEIGHT, pos.z)
	ray.to = Vector3(pos.x, WATER_LEVEL - 1.0, pos.z)

	var result = space_state.intersect_ray(ray)
	if result.is_empty():
		return false

	# Check if hit point is above water level (land)
	return result.position.y > WATER_LEVEL


func add_point_to_set(point: Vector3, point_set: Dictionary):
	"""Add a point to the set, snapping to grid to avoid near-duplicates."""
	# Snap to grid to reduce duplicates
	var snapped_point = Vector3(
		snappedf(point.x, GRID_CELL_SIZE / 2.0),
		WATER_LEVEL,
		snappedf(point.z, GRID_CELL_SIZE / 2.0)
	)
	point_set[snapped_point] = true


func get_island_aabb(island: StaticBody3D) -> AABB:
	"""Get the AABB of an island from its collision shapes or mesh."""
	var combined_aabb = AABB()
	var first = true

	for child in island.get_children():
		if child is CollisionShape3D and child.shape:
			var shape_aabb = get_shape_aabb(child)
			if first:
				combined_aabb = shape_aabb
				first = false
			else:
				combined_aabb = combined_aabb.merge(shape_aabb)
		elif child is MeshInstance3D and child.mesh:
			var mesh_aabb = child.mesh.get_aabb()
			mesh_aabb.position += child.global_position
			if first:
				combined_aabb = mesh_aabb
				first = false
			else:
				combined_aabb = combined_aabb.merge(mesh_aabb)

	return combined_aabb


func get_shape_aabb(collision_shape: CollisionShape3D) -> AABB:
	"""Get AABB from a collision shape."""
	var shape = collision_shape.shape
	var pos = collision_shape.global_position

	if shape is BoxShape3D:
		var half_size = shape.size / 2.0
		return AABB(pos - half_size, shape.size)
	elif shape is SphereShape3D:
		var size = Vector3.ONE * shape.radius * 2.0
		return AABB(pos - Vector3.ONE * shape.radius, size)
	elif shape is CylinderShape3D:
		var half_size = Vector3(shape.radius, shape.height / 2.0, shape.radius)
		return AABB(pos - half_size, half_size * 2.0)
	elif shape is CapsuleShape3D:
		var half_size = Vector3(shape.radius, shape.height / 2.0, shape.radius)
		return AABB(pos - half_size, half_size * 2.0)
	elif shape is ConcavePolygonShape3D:
		# For concave meshes, compute AABB from faces
		var faces = shape.get_faces()
		if faces.size() > 0:
			var min_point = faces[0] + pos
			var max_point = faces[0] + pos
			for face in faces:
				var world_face = face + pos
				min_point = min_point.min(world_face)
				max_point = max_point.max(world_face)
			return AABB(min_point, max_point - min_point)

	# Fallback - return a default sized AABB
	return AABB(pos - Vector3(500, 50, 500), Vector3(1000, 100, 1000))


func get_edge_points_for_island(island: StaticBody3D) -> Array[Vector3]:
	"""Get preprocessed edge points for a specific island."""
	if island_edge_points.has(island):
		return island_edge_points[island]
	return []


func get_closest_island_to_position(pos: Vector3, max_distance: float = INF) -> StaticBody3D:
	"""Find the closest island to a given position."""
	var closest_island: StaticBody3D = null
	var closest_dist = INF

	for island in islands:
		if not is_instance_valid(island):
			continue
		var dist = pos.distance_to(island.global_position)
		if dist < closest_dist and dist < max_distance:
			closest_dist = dist
			closest_island = island

	return closest_island


func get_islands_in_range(pos: Vector3, max_distance: float) -> Array[StaticBody3D]:
	"""Get all islands within a certain distance of a position."""
	var result: Array[StaticBody3D] = []

	for island in islands:
		if not is_instance_valid(island):
			continue
		if pos.distance_to(island.global_position) <= max_distance:
			result.append(island)

	return result
