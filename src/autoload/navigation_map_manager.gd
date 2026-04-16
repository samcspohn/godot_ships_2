extends Node

## NavigationMapManager — Autoload singleton that manages the shared NavigationMap instance.
## The NavigationMap stores a 2D signed distance field (SDF) of the playable area,
## providing fast terrain queries, pathfinding, island metadata, and cover zone computation
## for the ShipNavigator instances used by bot controllers.
##
## Usage:
##   NavigationMapManager.build_map(island_bodies, map_bounds)  — call once after map loads
##   NavigationMapManager.get_map()                              — returns the shared NavigationMap

var _map: NavigationMap = null
var _waypoint_graph: WaypointGraph = null
var _build_time_ms: float = 0.0
var _is_built: bool = false

## Default minimum ship radius for waypoint graph generation (smallest ship beam / 2).
const DEFAULT_MIN_SHIP_RADIUS := 25.0

## Build the navigation map from island collision shapes.
## island_bodies: Array of StaticBody3D nodes representing islands (with CollisionShape3D children)
## map_bounds: Rect2 defining the playable area in XZ space (position = min corner, size = extent)
## cell_size: SDF grid cell size in meters (default 50.0, matching existing nav mesh cell size)
func build_map(island_bodies: Array[StaticBody3D], map_bounds: Rect2, cell_size: float = 50.0) -> void:
	var start_time = Time.get_ticks_msec()

	_map = NavigationMap.new()
	_map.set_bounds(
		map_bounds.position.x,
		map_bounds.position.y,
		map_bounds.end.x,
		map_bounds.end.y
	)
	_map.set_cell_size(cell_size)

	# Convert typed array to the untyped Array<Node3D> expected by the C++ method
	var bodies_array: Array[Node3D] = []
	for body in island_bodies:
		if is_instance_valid(body):
			bodies_array.append(body)

	_map.build_from_collision_shapes(bodies_array)

	_build_time_ms = Time.get_ticks_msec() - start_time
	_is_built = true

	print("[NavigationMapManager] Map built in %.1f ms — %d islands detected, grid %dx%d (cell_size=%.0fm)" % [
		_build_time_ms,
		_map.get_island_count(),
		_map.get_grid_width(),
		_map.get_grid_height(),
		_map.get_cell_size_value()
	])

	_build_waypoint_graph()


## Build the navigation map using downward raycasts through the physics engine.
## Simpler than collision-shape parsing: casts a vertical ray per grid cell from just
## above the tallest island AABB. If the hit point is above the waterline (Y > 0),
## that cell is marked as land.  Must be called during _physics_process or after
## physics has initialised so the space state is valid.
## island_bodies: Array of StaticBody3D nodes (used only to determine ray height from AABBs)
## map_bounds: Rect2 defining the playable area in XZ space
## cell_size: SDF grid cell size in meters (default 50.0)
## collision_mask: physics layer mask for the raycast (default 1 = terrain)
func build_map_raycast(island_bodies: Array[StaticBody3D], map_bounds: Rect2,
					   cell_size: float = 50.0, collision_mask: int = 1) -> void:
	var start_time = Time.get_ticks_msec()

	_map = NavigationMap.new()
	_map.set_bounds(
		map_bounds.position.x,
		map_bounds.position.y,
		map_bounds.end.x,
		map_bounds.end.y
	)
	_map.set_cell_size(cell_size)

	var space_state := PhysicsServer3D.space_get_direct_state(
		get_viewport().world_3d.space
	)

	var bodies_array: Array[Node3D] = []
	for body in island_bodies:
		if is_instance_valid(body):
			bodies_array.append(body)

	_map.build_from_raycast_scan(space_state, bodies_array, collision_mask)

	_build_time_ms = Time.get_ticks_msec() - start_time
	_is_built = true

	print("[NavigationMapManager] Map built (raycast) in %.1f ms — %d islands detected, grid %dx%d (cell_size=%.0fm)" % [
		_build_time_ms,
		_map.get_island_count(),
		_map.get_grid_width(),
		_map.get_grid_height(),
		_map.get_cell_size_value()
	])

	_build_waypoint_graph()

## Build the shared WaypointGraph from the NavigationMap (called internally after map build).
func _build_waypoint_graph() -> void:
	if _map == null or not _map.is_built():
		return

	var start_time = Time.get_ticks_msec()
	_waypoint_graph = WaypointGraph.new()
	_waypoint_graph.build(_map, DEFAULT_MIN_SHIP_RADIUS)
	var elapsed = Time.get_ticks_msec() - start_time

	print("[NavigationMapManager] WaypointGraph built in %.1f ms — %d nodes, %d edges" % [
		elapsed,
		_waypoint_graph.node_count(),
		_waypoint_graph.get_edge_count()
	])

## Returns the shared NavigationMap instance, or null if not yet built.
func get_map() -> NavigationMap:
	return _map

## Returns the shared WaypointGraph instance, or null if not yet built.
func get_waypoint_graph() -> WaypointGraph:
	return _waypoint_graph

## Returns true if the map has been built and is ready for use.
func is_map_ready() -> bool:
	return _is_built and _map != null and _map.is_built()

## Returns the time in milliseconds that the last build took.
func get_build_time_ms() -> float:
	return _build_time_ms

## Get all detected islands as an array of Dictionaries.
## Each dictionary has keys: id, center (Vector2), radius, area, edge_points (PackedVector2Array)
func get_islands() -> Array:
	if _map == null:
		return []
	return Array(_map.get_islands())

## Get the nearest island to a world XZ position.
## Returns a Dictionary with island data + "valid" key, or {"valid": false} if no islands.
func get_nearest_island(world_position: Vector3) -> Dictionary:
	if _map == null:
		return {"valid": false}
	return _map.get_nearest_island(Vector2(world_position.x, world_position.z))

## Compute a cover zone behind an island relative to a threat position.
## Returns a Dictionary with keys: center, arc_start_angle, arc_end_angle, min_radius,
## max_radius, best_position (Vector2), best_heading, valid (bool)
func compute_cover_zone(island_id: int, threat_position: Vector3, ship_position: Vector3,
						ship_clearance: float, turning_radius: float, max_range: float) -> Dictionary:
	if _map == null:
		return {"valid": false}

	# Compute threat direction as unit vector from island toward threat
	var islands = _map.get_islands()
	if island_id < 0 or island_id >= islands.size():
		return {"valid": false}

	var island_center: Vector2 = islands[island_id]["center"]
	var threat_pos_2d = Vector2(threat_position.x, threat_position.z)
	var threat_direction = (threat_pos_2d - island_center).normalized()

	return _map.compute_cover_zone(island_id, threat_direction, ship_clearance, turning_radius, max_range)

## Check if a world position is navigable with the given clearance.
func is_navigable(world_position: Vector3, clearance: float) -> bool:
	if _map == null:
		return true  # Assume navigable if map not built
	return _map.is_navigable(world_position.x, world_position.z, clearance)

## Get the signed distance to land at a world position.
## Positive = open water, negative = inside land.
func get_distance(world_position: Vector3) -> float:
	if _map == null:
		return 10000.0
	return _map.get_distance(world_position.x, world_position.z)

## Find a path between two world positions maintaining clearance from land.
## Returns a PackedVector2Array of waypoints in XZ space.
func find_path(from: Vector3, to: Vector3, clearance: float) -> PackedVector2Array:
	if _map == null:
		return PackedVector2Array([Vector2(from.x, from.z), Vector2(to.x, to.z)])
	return _map.find_path(Vector2(from.x, from.z), Vector2(to.x, to.z), clearance)


## Return a safe navigation point given a candidate destination.
## If the candidate is inside land or dangerously close to a coastline, the point
## is pushed into open water and slid tangentially along the shore so that the
## ship approaches roughly parallel to the coast rather than head-on.
## ship_position: the ship's current world position (Vector3, uses X/Z)
## candidate: the desired world destination (Vector3, uses X/Z)
## clearance: hard minimum distance from land (meters) — typically beam/2 + safety
## turning_radius: the ship's turning circle radius (meters)
## Returns: Vector3 with Y=0 of the safe destination
func safe_nav_point(ship_position: Vector3, candidate: Vector3, clearance: float, turning_radius: float) -> Vector3:
	if _map == null:
		return candidate
	var result: Vector2 = _map.safe_nav_point(
		Vector2(ship_position.x, ship_position.z),
		Vector2(candidate.x, candidate.z),
		clearance,
		turning_radius
	)["position"]
	return Vector3(result.x, 0.0, result.y)


## Validate that navigating from ship_position to destination won't put the ship
## on a collision course it can't recover from. Checks approach angles relative
## to nearby coastlines and adjusts the destination if needed.
## ship_position: the ship's current world position (Vector3, uses X/Z)
## destination: the desired world destination (Vector3, uses X/Z)
## clearance: hard minimum distance from land (meters)
## turning_radius: the ship's turning circle radius (meters)
## Returns: Vector3 with Y=0 of the validated (possibly adjusted) destination
func validate_destination(ship_position: Vector3, destination: Vector3, clearance: float, turning_radius: float) -> Vector3:
	if _map == null:
		return destination
	var result: Vector2 = _map.validate_destination(
		Vector2(ship_position.x, ship_position.z),
		Vector2(destination.x, destination.z),
		clearance,
		turning_radius
	)["position"]
	return Vector3(result.x, 0.0, result.y)


## Check if line-of-sight between two world positions is blocked by land (an island).
## Uses the SDF raycast with zero clearance — if the ray hits, land is in the way.
## from_pos: world Vector3 (uses X/Z)
## to_pos: world Vector3 (uses X/Z)
## Returns true if an island blocks the straight line between the two points.
func is_los_blocked(from_pos: Vector3, to_pos: Vector3) -> bool:
	if _map == null:
		return false
	var result: Dictionary = _map.raycast(
		Vector2(from_pos.x, from_pos.z),
		Vector2(to_pos.x, to_pos.z),
		0.0
	)
	return result["hit"]


## Check if line-of-sight is blocked, using Vector2 (XZ) positions directly.
func is_los_blocked_2d(from_xz: Vector2, to_xz: Vector2) -> bool:
	if _map == null:
		return false
	var result: Dictionary = _map.raycast(from_xz, to_xz, 0.0)
	return result["hit"]


## SDF-cell-based cover candidate search — walks the actual SDF grid near an island's
## shoreline to find navigable cells where LOS to threats is blocked by land.
## Returns a sorted Array of candidate Dictionaries, ranked by concealment score.
## The caller should iterate through them asynchronously and validate shootability
## via the full ballistic simulation (Gun.sim_can_shoot_over_terrain), since shells
## arc over islands and flat LOS is not a valid shootability check.
##
## island_id:        index from get_islands()
## threat_positions: Array of Vector3 enemy positions to hide from (uses X/Z)
## danger_center:    Vector3 engagement center (uses X/Z, for gun-range filter)
## ship_position:    Vector3 current ship position (uses X/Z, for travel-cost scoring)
## ship_clearance:   minimum distance from land the ship needs
## gun_range:        maximum firing range
## max_results:      how many candidates to return (default 20)
## max_candidates:   performance cap on evaluated cells (default 200)
##
## Returns Array of Dictionaries sorted best-first.  Each entry:
##   position (Vector2 XZ), hidden_count (int), total_threats (int),
##   all_hidden (bool), sdf_distance (float), score (float)
func find_cover_candidates(island_id: int, threat_positions: Array, danger_center: Vector3,
						   ship_position: Vector3, ship_clearance: float, gun_range: float,
						   max_results: int = 20, max_candidates: int = 200) -> Array:
	if _map == null:
		return []

	# Convert threat Vector3 array to PackedVector2Array (XZ)
	var threats_2d := PackedVector2Array()
	for threat in threat_positions:
		threats_2d.append(Vector2(threat.x, threat.z))

	return Array(_map.find_cover_candidates(
		island_id,
		threats_2d,
		Vector2(danger_center.x, danger_center.z),
		Vector2(ship_position.x, ship_position.z),
		ship_clearance,
		gun_range,
		max_results,
		max_candidates
	))


## Test multiple candidate positions against multiple threat positions for LOS coverage.
## candidates: Array of Vector3 world positions to test
## threats: Array of Vector3 world positions (enemies / last-known positions) to hide from
## Returns an Array of Dictionaries, one per candidate:
##   { position: Vector3, hidden_count: int, total_threats: int, all_hidden: bool }
## Candidates are returned sorted best-first (most threats hidden).
func evaluate_cover_candidates(candidates: Array, threats: Array) -> Array:
	if _map == null:
		return []

	var results: Array = []
	for candidate in candidates:
		var cand_2d := Vector2(candidate.x, candidate.z)
		var hidden_count := 0
		for threat in threats:
			var threat_2d := Vector2(threat.x, threat.z)
			var ray: Dictionary = _map.raycast(cand_2d, threat_2d, 0.0)
			if ray["hit"]:
				hidden_count += 1
		results.append({
			"position": candidate,
			"hidden_count": hidden_count,
			"total_threats": threats.size(),
			"all_hidden": hidden_count >= threats.size(),
		})

	# Sort: most threats hidden first, ties broken by position index (stable)
	results.sort_custom(func(a, b): return a["hidden_count"] > b["hidden_count"])
	return results
