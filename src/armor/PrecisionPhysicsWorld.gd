extends Node

class_name _PrecisionPhysicsWorld

## Manages per-ship physics spaces via PhysicsServer3D for high floating-point
## precision armor raycasting.  Ships at large world positions (e.g. 15000, 0,
## 12000) suffer float32 degradation.  Each registered ship gets:
##
## 1. A coarse OBB (oriented bounding box) StaticBody3D in the MAIN world for
##    cheap broadphase hit detection (collision layer 1 << 4).
## 2. A dedicated PhysicsServer3D space containing static bodies that mirror the
##    ship's armor parts at their ship-local transforms (i.e. centered at the
##    origin).  Raycasts in this space have maximum float32 precision.
##
## The bodies in the precision space use body_attach_object_instance_id() to
## reference the ORIGINAL ArmorPart nodes — raycast results return real
## ArmorParts directly.  No cloning, no back-mapping.
##
## Usage flow (from ArmorInteraction.process_travel):
## 1. Cast ray in main world against OBB colliders (layer 1 << 4).
## 2. If OBB is hit, identify which ship.
## 3. Transform ray to ship-local space.
## 4. Cast in that ship's precision space — result contains original ArmorPart.
## 5. Transform hit position/normal back to world space.

# Maps Ship instance_id -> {
#   "ship": Ship,
#   "obb_body": StaticBody3D,
#   "space_rid": RID,
#   "static_bodies": Array[Dictionary],   # hull parts — never re-synced
#   "dynamic_bodies": Array[Dictionary],  # turret parts — synced on OBB hit
#   "sync_frame": int,                    # engine frame when dynamic bodies were last synced
# }
var _ship_cache: Dictionary = {}

# Collision layer for OBB broadphase colliders in the main world
const OBB_COLLISION_LAYER: int = 1 << 4

## When true, draw wireframe OBBs for every registered ship each physics tick.
var debug_draw_obb: bool = false
## When true, print to console whenever a shell enters/misses an OBB.
var debug_log_obb: bool = false

# Maps ship instance ID -> hit timestamp (msec).
const OBB_HIT_LINGER_MS: int = 500
var _obb_hit_ships: Dictionary = {}


func _ready() -> void:
	pass


func _physics_process(_delta: float) -> void:
	_sync_obbs()
	# if debug_draw_obb:
	# 	_draw_all_obb_wireframes()
	_expire_obb_hits()


## Called by ArmorInteraction when a shell hits an OBB in the broadphase.
func notify_obb_hit(ship: Ship) -> void:
	_obb_hit_ships[ship.get_instance_id()] = Time.get_ticks_msec()


func _expire_obb_hits() -> void:
	var now := Time.get_ticks_msec()
	var stale: Array = []
	for sid in _obb_hit_ships:
		if now - _obb_hit_ships[sid] > OBB_HIT_LINGER_MS:
			stale.append(sid)
	for sid in stale:
		_obb_hit_ships.erase(sid)


## Draw wireframe boxes for every registered ship's OBB using the Debug API.
func _draw_all_obb_wireframes() -> void:
	for sid in _ship_cache:
		var entry: Dictionary = _ship_cache[sid]
		var ship: Ship = entry["ship"]
		if not is_instance_valid(ship):
			continue
		var obb: StaticBody3D = entry["obb_body"]
		if not is_instance_valid(obb):
			continue
		var col_shape: CollisionShape3D = obb.get_child(0) as CollisionShape3D
		if col_shape == null or not col_shape.shape is BoxShape3D:
			continue
		var box: BoxShape3D = col_shape.shape as BoxShape3D
		var half := box.size / 2.0
		var local_center: Vector3 = col_shape.position
		var world_center: Vector3 = obb.global_transform * local_center
		var basis: Basis = obb.global_transform.basis
		var hx: Vector3 = half.x * basis.x
		var hy: Vector3 = half.y * basis.y
		var hz: Vector3 = half.z * basis.z
		var c: Array[Vector3] = [
			world_center - hx - hy - hz,
			world_center + hx - hy - hz,
			world_center + hx - hy + hz,
			world_center - hx - hy + hz,
			world_center - hx + hy - hz,
			world_center + hx + hy - hz,
			world_center + hx + hy + hz,
			world_center - hx + hy + hz,
		]
		var color := Color.RED if _obb_hit_ships.has(sid) else Color.YELLOW
		Debug.draw_line(c[0], c[1], color)
		Debug.draw_line(c[1], c[2], color)
		Debug.draw_line(c[2], c[3], color)
		Debug.draw_line(c[3], c[0], color)
		Debug.draw_line(c[4], c[5], color)
		Debug.draw_line(c[5], c[6], color)
		Debug.draw_line(c[6], c[7], color)
		Debug.draw_line(c[7], c[4], color)
		Debug.draw_line(c[0], c[4], color)
		Debug.draw_line(c[1], c[5], color)
		Debug.draw_line(c[2], c[6], color)
		Debug.draw_line(c[3], c[7], color)


## Compute the AABB of a Shape3D in shape-local coordinates.
static func _get_shape_aabb(shape: Shape3D) -> AABB:
	if shape is ConcavePolygonShape3D:
		var faces: PackedVector3Array = shape.get_faces()
		if faces.size() == 0:
			return AABB()
		var aabb := AABB(faces[0], Vector3.ZERO)
		for i in range(1, faces.size()):
			aabb = aabb.expand(faces[i])
		return aabb
	elif shape is ConvexPolygonShape3D:
		var points: PackedVector3Array = shape.points
		if points.size() == 0:
			return AABB()
		var aabb := AABB(points[0], Vector3.ZERO)
		for i in range(1, points.size()):
			aabb = aabb.expand(points[i])
		return aabb
	elif shape is BoxShape3D:
		return AABB(-shape.size / 2.0, shape.size)
	elif shape is SphereShape3D:
		var r: float = shape.radius
		return AABB(Vector3(-r, -r, -r), Vector3(r * 2, r * 2, r * 2))
	else:
		return AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))


## Create a static body in the given precision space for a single ArmorPart.
## Returns { "body_rid": RID, "armor_part": ArmorPart }.
## Returns true if the armor part is a descendant of a Turret (i.e. it moves).
static func _is_dynamic_part(armor_part: ArmorPart) -> bool:
	var p := armor_part.get_parent()
	while p != null:
		if p is Turret:
			return true
		p = p.get_parent()
	return false


func _create_precision_body(space_rid: RID, ship_inv: Transform3D, armor_part: ArmorPart) -> Dictionary:
	var local_xform := ship_inv * armor_part.global_transform

	var body_rid := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_space(body_rid, space_rid)
	PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, local_xform)
	PhysicsServer3D.body_set_collision_layer(body_rid, 1 << 1)
	PhysicsServer3D.body_set_collision_mask(body_rid, 0)

	# Attach the ORIGINAL ArmorPart's instance ID so raycast results
	# return the real node as 'collider' — no cloning needed.
	PhysicsServer3D.body_attach_object_instance_id(body_rid, armor_part.get_instance_id())

	# Add all collision shapes from the original ArmorPart
	for child in armor_part.get_children():
		if child is CollisionShape3D and child.shape != null:
			var shape_rid: RID = child.shape.get_rid()
			PhysicsServer3D.body_add_shape(body_rid, shape_rid, child.transform)

	return { "body_rid": body_rid, "armor_part": armor_part }


## Register a ship so its armor geometry is mirrored into a dedicated precision
## physics space via PhysicsServer3D.
## Call this after the ship's armor system is fully initialized.
func register_ship(ship: Ship) -> void:
	var sid := ship.get_instance_id()
	if _ship_cache.has(sid):
		return

	# --- 1. Compute proper AABB from armor collision shapes in ship-local space ---
	var computed_aabb := AABB()
	var first_shape := true
	var ship_inv := ship.global_transform.affine_inverse()
	for armor_part: ArmorPart in ship.armor_parts:
		for child in armor_part.get_children():
			if child is CollisionShape3D and child.shape != null:
				var shape_aabb := _get_shape_aabb(child.shape)
				var shape_to_ship: Transform3D = ship_inv * child.global_transform
				var transformed: AABB = shape_to_ship * shape_aabb
				if first_shape:
					computed_aabb = transformed
					first_shape = false
				else:
					computed_aabb = computed_aabb.merge(transformed)

	var ship_aabb: AABB
	if computed_aabb.size.length() > 1.0:
		ship_aabb = computed_aabb.grow(5.0)
	else:
		ship_aabb = ship.aabb
		if ship_aabb.size.length() < 1.0:
			var col_node = ship.get_node_or_null("CollisionShape3D")
			if col_node and col_node.shape is BoxShape3D:
				ship_aabb = AABB(-col_node.shape.size / 2.0, col_node.shape.size)
			else:
				ship_aabb = AABB(Vector3(-100, -10, -25), Vector3(200, 20, 50))

	# --- 2. Create OBB collider in the main world ---
	var obb_body := StaticBody3D.new()
	obb_body.name = "OBB_%s" % ship.name
	obb_body.collision_layer = OBB_COLLISION_LAYER
	obb_body.collision_mask = 0

	var box_shape := BoxShape3D.new()
	box_shape.size = ship_aabb.size
	var col_shape := CollisionShape3D.new()
	col_shape.shape = box_shape
	col_shape.position = ship_aabb.position + ship_aabb.size / 2.0
	obb_body.add_child(col_shape)
	obb_body.global_transform = ship.global_transform
	obb_body.set_meta("ship", ship)
	obb_body.set_meta("ship_instance_id", sid)
	add_child(obb_body)

	# --- 3. Create a dedicated PhysicsServer3D space for this ship ---
	var space_rid := PhysicsServer3D.space_create()
	PhysicsServer3D.space_set_active(space_rid, true)

	var static_bodies: Array = []
	var dynamic_bodies: Array = []

	for armor_part: ArmorPart in ship.armor_parts:
		var body_info := _create_precision_body(space_rid, ship_inv, armor_part)
		if _is_dynamic_part(armor_part):
			dynamic_bodies.append(body_info)
		else:
			static_bodies.append(body_info)

	_ship_cache[sid] = {
		"ship": ship,
		"obb_body": obb_body,
		"space_rid": space_rid,
		"static_bodies": static_bodies,
		"dynamic_bodies": dynamic_bodies,
		"sync_frame": -1,
	}

	if debug_log_obb:
		print("[PrecisionPhysics] Registered ship '%s' — %d static, %d dynamic bodies" % [
			ship.ship_name, static_bodies.size(), dynamic_bodies.size()])


## Register an individual armor part with an already-registered ship.
## Used by turrets whose armor is initialized via call_deferred() after the
## ship has already been registered.
func add_armor_part(ship: Ship, armor_part: ArmorPart) -> void:
	var sid := ship.get_instance_id()
	if not _ship_cache.has(sid):
		# Ship not registered yet — it will pick up this part when it registers
		return

	var entry: Dictionary = _ship_cache[sid]
	var space_rid: RID = entry["space_rid"]
	var ship_inv := ship.global_transform.affine_inverse()

	var body_info := _create_precision_body(space_rid, ship_inv, armor_part)
	# Turret parts added late are always dynamic
	entry["dynamic_bodies"].append(body_info)
	# Force re-sync on next narrowphase hit
	entry["sync_frame"] = -1

	if debug_log_obb:
		print("[PrecisionPhysics] Added dynamic armor part '%s' to ship '%s' (now %d dynamic bodies)" % [
			armor_part.armor_path, ship.ship_name, entry["dynamic_bodies"].size()])


## Unregister a ship and clean up its OBB and precision space.
func unregister_ship(ship: Ship) -> void:
	var sid := ship.get_instance_id()
	if not _ship_cache.has(sid):
		return

	var entry: Dictionary = _ship_cache[sid]

	# Remove OBB from main world
	var obb: StaticBody3D = entry["obb_body"]
	if is_instance_valid(obb):
		obb.queue_free()

	# Free all bodies in the precision space, then the space itself
	for body_info: Dictionary in entry["static_bodies"]:
		PhysicsServer3D.free_rid(body_info["body_rid"])
	for body_info: Dictionary in entry["dynamic_bodies"]:
		PhysicsServer3D.free_rid(body_info["body_rid"])

	var space_rid: RID = entry["space_rid"]
	PhysicsServer3D.free_rid(space_rid)

	_ship_cache.erase(sid)

	if debug_log_obb:
		print("[PrecisionPhysics] Unregistered ship '%s'" % ship.ship_name)


## Sync OBB transforms with ship positions every physics tick (cheap).
## Precision body transforms are updated lazily via _sync_precision_bodies()
## only when a raycast actually targets that ship's space.
func _sync_obbs() -> void:
	var stale: Array = []
	for sid in _ship_cache:
		var entry: Dictionary = _ship_cache[sid]
		var ship: Ship = entry["ship"]
		if not is_instance_valid(ship):
			stale.append(sid)
			continue
		var obb: StaticBody3D = entry["obb_body"]
		if is_instance_valid(obb):
			obb.global_transform = ship.global_transform

	for sid in stale:
		var entry: Dictionary = _ship_cache[sid]
		var obb: StaticBody3D = entry["obb_body"]
		if is_instance_valid(obb):
			obb.queue_free()
		for body_info: Dictionary in entry["static_bodies"]:
			PhysicsServer3D.free_rid(body_info["body_rid"])
		for body_info: Dictionary in entry["dynamic_bodies"]:
			PhysicsServer3D.free_rid(body_info["body_rid"])
		PhysicsServer3D.free_rid(entry["space_rid"])
		_ship_cache.erase(sid)


## Update dynamic (turret) precision body transforms for a single ship.
## Static hull bodies never move relative to the ship so they are skipped.
## Uses a frame counter so multiple OBB hits in the same frame only sync once.
func _sync_precision_bodies(ship: Ship) -> void:
	var sid := ship.get_instance_id()
	if not _ship_cache.has(sid):
		return
	var entry: Dictionary = _ship_cache[sid]
	var current_frame := Engine.get_physics_frames()
	if entry["sync_frame"] == current_frame:
		return
	entry["sync_frame"] = current_frame
	var dynamic: Array = entry["dynamic_bodies"]
	if dynamic.is_empty():
		return
	var ship_inv := ship.global_transform.affine_inverse()
	for body_info: Dictionary in dynamic:
		var armor_part: ArmorPart = body_info["armor_part"]
		if is_instance_valid(armor_part):
			var local_xform := ship_inv * armor_part.global_transform
			PhysicsServer3D.body_set_state(
				body_info["body_rid"],
				PhysicsServer3D.BODY_STATE_TRANSFORM,
				local_xform)


## Get the PhysicsDirectSpaceState3D for a specific ship's precision space.
## Returns null if the ship is not registered.
func get_ship_space_state(ship: Ship) -> PhysicsDirectSpaceState3D:
	var sid := ship.get_instance_id()
	if not _ship_cache.has(sid):
		return null
	var space_rid: RID = _ship_cache[sid]["space_rid"]
	return PhysicsServer3D.space_get_direct_state(space_rid)


## Transform a world-space ray into a ship's local space for precision casting.
## Returns [local_from, local_to].
func world_ray_to_local(ship: Ship, from: Vector3, to: Vector3) -> Array:
	var inv_xform := ship.global_transform.affine_inverse()
	return [inv_xform * from, inv_xform * to]


## Transform a position from ship-local space back to world space.
func local_to_world(ship: Ship, local_pos: Vector3) -> Vector3:
	return ship.global_transform * local_pos


## Transform a direction from ship-local space back to world space (no translation).
func local_dir_to_world(ship: Ship, local_dir: Vector3) -> Vector3:
	return ship.global_transform.basis * local_dir


## Look up the Ship associated with an OBB StaticBody3D hit.
func get_ship_from_obb(obb_body: Node) -> Ship:
	if obb_body == null or not obb_body.has_meta("ship"):
		return null
	var ship = obb_body.get_meta("ship")
	if is_instance_valid(ship):
		return ship as Ship
	return null


## Check if a world-space point is inside any registered OBB.
## Returns the Ship whose OBB contains the point, or null.
func get_ship_containing_point(world_point: Vector3, excluded_ships: Array = []) -> Ship:
	for sid in _ship_cache:
		if sid in excluded_ships:
			continue
		var entry: Dictionary = _ship_cache[sid]
		var ship: Ship = entry["ship"]
		if not is_instance_valid(ship):
			continue
		var obb: StaticBody3D = entry["obb_body"]
		if not is_instance_valid(obb):
			continue
		var col_shape_node: CollisionShape3D = obb.get_child(0) as CollisionShape3D
		if col_shape_node == null or not col_shape_node.shape is BoxShape3D:
			continue
		var box: BoxShape3D = col_shape_node.shape as BoxShape3D
		var half := box.size / 2.0
		var local_pt: Vector3 = obb.global_transform.affine_inverse() * world_point
		local_pt -= col_shape_node.position
		if absf(local_pt.x) <= half.x and absf(local_pt.y) <= half.y and absf(local_pt.z) <= half.z:
			return ship
	return null


## Perform a narrowphase precision raycast for a ship and return the hit info
## as world-space data, or an empty dict on miss.
## Returns { "armor": ArmorPart, "world_pos": Vector3, "world_normal": Vector3, "face_index": int }
func narrowphase_hit(ship: Ship, world_from: Vector3, world_to: Vector3) -> Dictionary:
	_sync_precision_bodies(ship)
	var local_ray := world_ray_to_local(ship, world_from, world_to)
	var local_from: Vector3 = local_ray[0]
	var local_to: Vector3 = local_ray[1]

	var result := precision_raycast(ship, local_from, local_to)
	if result.is_empty():
		return {}

	var armor_part := result.get('collider') as ArmorPart
	if armor_part == null:
		return {}

	return {
		"armor": armor_part,
		"world_pos": local_to_world(ship, result.get('position')),
		"world_normal": local_dir_to_world(ship, result.get('normal')).normalized(),
		"face_index": result.get('face_index'),
		"local_from": local_from,
		"local_to": local_to,
	}


## Perform a precision raycast in a ship's dedicated precision space.
## from_local and to_local are in ship-local coordinates.
## Returns the same Dictionary format as intersect_ray, with positions/normals
## in local space.  The 'collider' is the ORIGINAL ArmorPart node.
func precision_raycast(ship: Ship, from_local: Vector3, to_local: Vector3,
		hit_back_faces: bool = true, exclude: Array[RID] = []) -> Dictionary:
	var space_state := get_ship_space_state(ship)
	if space_state == null:
		return {}

	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.from = from_local
	ray_query.to = to_local
	ray_query.hit_back_faces = hit_back_faces
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 << 1
	ray_query.exclude = exclude

	return space_state.intersect_ray(ray_query)


## Find the closest armor hit along a ray in ship-local space.
## Returns { 'armor': ArmorPart, 'position': Vector3, 'normal': Vector3,
## 'face_index': int } or empty dict on miss.
## The returned ArmorPart is the ORIGINAL scene-tree node.
func precision_get_next_hit(ship: Ship, from_local: Vector3, to_local: Vector3) -> Dictionary:
	# No _sync_precision_bodies here — callers (e.g. _process_hit) already
	# entered through narrowphase_hit or precision_raycast which synced first.
	var space_state := get_ship_space_state(ship)
	if space_state == null:
		return {}

	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.from = from_local
	ray_query.to = to_local
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 << 1

	var result := space_state.intersect_ray(ray_query)
	if result.is_empty():
		return {}

	var armor: ArmorPart = result.get('collider') as ArmorPart
	if armor != null:
		return {
			'armor': armor,
			'position': result.get('position'),
			'normal': result.get('normal'),
			'face_index': result.get('face_index')
		}
	return {}


## 6-direction raycast to determine which armor part a local-space point is
## inside.  Prefers citadel parts.
## Returns the ORIGINAL ArmorPart the point is inside, or null.
func precision_get_part_hit(ship: Ship, local_pos: Vector3) -> ArmorPart:
	# No _sync_precision_bodies here — callers already synced on the initial
	# narrowphase_hit / precision_raycast that started the hit processing.
	var space_state := get_ship_space_state(ship)
	if space_state == null:
		return null

	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.to = local_pos
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 << 1

	var directions := [
		Vector3.RIGHT, Vector3.LEFT,
		Vector3.UP, Vector3.DOWN,
		Vector3.FORWARD, Vector3.BACK,
	]

	var hits: Array[Array] = []
	var armor_parts := {}
	for dir in directions:
		ray_query.from = local_pos + dir * 400.0
		ray_query.exclude = []
		var side_hits: Array[ArmorPart] = []
		var armor_hit := space_state.intersect_ray(ray_query)
		var ex: Array[RID] = []

		while not armor_hit.is_empty():
			var armor_part := armor_hit.get('collider') as ArmorPart
			if armor_part != null and armor_part.ship == ship:
				side_hits.append(armor_part)
				armor_parts[armor_part] = true
			ex.append(armor_hit.get('rid'))
			ray_query.exclude = ex
			armor_hit = space_state.intersect_ray(ray_query)
		hits.append(side_hits)

	for side_hits in hits:
		if side_hits.size() == 0:
			return null

	var inside_parts := []
	for armor_part in armor_parts.keys():
		var inside := true
		for side_hits in hits:
			if not armor_part in side_hits:
				inside = false
				break
		if inside:
			inside_parts.append(armor_part)

	for part in inside_parts:
		if part.type == ArmorPart.Type.CITADEL:
			return part

	return inside_parts[0] if inside_parts.size() > 0 else null


## Check if a ship is registered.
func is_ship_registered(ship: Ship) -> bool:
	return _ship_cache.has(ship.get_instance_id())


## Get cache entry for a ship (or empty dict if unregistered).
func get_ship_entry(ship: Ship) -> Dictionary:
	var sid := ship.get_instance_id()
	if _ship_cache.has(sid):
		return _ship_cache[sid]
	return {}


## Return the number of precision bodies for a ship (for debug inspection).
func get_precision_body_count(ship: Ship) -> int:
	var sid := ship.get_instance_id()
	if _ship_cache.has(sid):
		return _ship_cache[sid]["static_bodies"].size() + _ship_cache[sid]["dynamic_bodies"].size()
	return 0
