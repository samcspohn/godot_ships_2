extends Node

class_name _PrecisionPhysicsWorld

## Armour hit detection for ships. Each registered ship gets:
##
## 1. A coarse OBB StaticBody3D in the MAIN world for cheap broadphase hit
##    detection (collision layer 1 << 4).
## 2. Its armour parts' triangles and per-face thickness in the native
##    armour mesh registry (_ProjectileManager.armor_*), which is the
##    narrowphase the armour walk raycasts against, in ship-local space,
##    with no physics server involved. Turret parts are re-placed once per
##    physics frame on first use.
##
## The query functions below are thin wrappers over the native mesh kept for
## GDScript callers (replay, tooling).

# Maps Ship instance_id -> { "ship": Ship, "obb_body": StaticBody3D, "parts": int }
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


## Called by the armour walk when a shell hits an OBB in the broadphase.
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


## True if the armor part is a descendant of a Turret (i.e. it moves).
static func _is_dynamic_part(armor_part: ArmorPart) -> bool:
	var p := armor_part.get_parent()
	while p != null:
		if p is Turret:
			return true
		p = p.get_parent()
	return false


## Register a ship: an OBB in the main world and its armour in the native mesh.
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

	# --- 3. Armour geometry goes to the native mesh registry ---
	_native_register_ship(ship)
	var parts: int = 0
	for armor_part: ArmorPart in ship.armor_parts:
		_native_add_part(ship, armor_part, _is_dynamic_part(armor_part))
		parts += 1

	_ship_cache[sid] = {
		"ship": ship,
		"obb_body": obb_body,
		"parts": parts,
	}

	if debug_log_obb:
		print("[PrecisionPhysics] Registered ship '%s' — %d armour parts" % [ship.ship_name, parts])


## Register an individual armor part with an already-registered ship.
## Used by turrets whose armor is initialized via call_deferred() after the
## ship has already been registered.
func add_armor_part(ship: Ship, armor_part: ArmorPart) -> void:
	var sid := ship.get_instance_id()
	if not _ship_cache.has(sid):
		# Ship not registered yet — it will pick up this part when it registers
		return

	var entry: Dictionary = _ship_cache[sid]
	# Turret parts added late are always dynamic
	_native_add_part(ship, armor_part, true)
	entry["parts"] = int(entry["parts"]) + 1

	if debug_log_obb:
		print("[PrecisionPhysics] Added dynamic armor part '%s' to ship '%s'" % [
			armor_part.armor_path, ship.ship_name])


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

	_ship_cache.erase(sid)
	_native_unregister(sid)

	if debug_log_obb:
		print("[PrecisionPhysics] Unregistered ship '%s'" % ship.ship_name)


## Sync OBB transforms with ship positions every physics tick (cheap).
## Turret parts in the native mesh are re-placed lazily on first use per frame.
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
		_ship_cache.erase(sid)
		_native_unregister(sid)


# ------------------------------------------------ native armour registry

static func _native() -> Object:
	return ProjectileManager.get_raw() if ProjectileManager != null else null


func _native_register_ship(ship: Ship) -> void:
	var pm := _native()
	if pm != null:
		pm.armor_register_ship(ship)


func _native_unregister(sid: int) -> void:
	var pm := _native()
	if pm != null:
		pm.armor_unregister_ship(sid)


## Hand one part's triangles, per-face thickness and placement to the native
## mesh. Face order is ConcavePolygonShape3D.get_faces() order, which is the
## index the armour data is keyed by.
func _native_add_part(ship: Ship, armor_part: ArmorPart, dynamic: bool) -> void:
	var pm := _native()
	if pm == null:
		return
	var col: CollisionShape3D = null
	for child in armor_part.get_children():
		if child is CollisionShape3D and child.shape is ConcavePolygonShape3D:
			col = child
			break
	if col == null:
		push_warning("PrecisionPhysicsWorld: part '%s' has no ConcavePolygonShape3D; not in native mesh" % armor_part.armor_path)
		return
	var raw: PackedVector3Array = (col.shape as ConcavePolygonShape3D).get_faces()
	var faces := PackedVector3Array()
	faces.resize(raw.size())
	for i in raw.size():
		faces[i] = col.transform * raw[i]
	var n: int = raw.size() / 3
	var thickness := PackedFloat32Array()
	thickness.resize(n)
	for i in n:
		thickness[i] = float(armor_part.get_armor(i))
	var local_xform: Transform3D = ship.global_transform.affine_inverse() * armor_part.global_transform
	pm.armor_add_part(ship, armor_part, local_xform, faces, thickness, int(armor_part.type), dynamic)


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
## True when `part` is mounted on a turret rather than on the hull.
##
## Public face of the same parent walk the precision bodies use to decide what
## has to be re-synced every frame: a part on a turret moves with the turret.
## Scoring asks the same question for a different reason - what a shell is worth
## when it goes through one.
func is_turret_part(part: ArmorPart) -> bool:
	return part != null and _is_dynamic_part(part)


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


## Perform a narrowphase precision raycast for a ship and return the hit info.
## Includes BOTH local-space and world-space hit data. Local-space values are
## computed directly in the precision (origin-centered) world and have full
## floating-point precision; world-space values are derived for display/logging
## but should NOT be round-tripped back to local for further computation when
## the ship is far from the world origin (precision will be lost).
## Returns { "armor": ArmorPart, "local_pos": Vector3, "local_normal": Vector3,
##           "world_pos": Vector3, "world_normal": Vector3, "face_index": int,
##           "local_from": Vector3, "local_to": Vector3 }
func narrowphase_hit(ship: Ship, world_from: Vector3, world_to: Vector3) -> Dictionary:
	var local_ray := world_ray_to_local(ship, world_from, world_to)
	var local_from: Vector3 = local_ray[0]
	var local_to: Vector3 = local_ray[1]

	var result := precision_raycast(ship, local_from, local_to)
	if result.is_empty():
		return {}

	var armor_part := result.get('collider') as ArmorPart
	if armor_part == null:
		return {}

	var local_pos: Vector3 = result.get('position')
	var local_normal: Vector3 = (result.get('normal') as Vector3).normalized()
	return {
		"armor": armor_part,
		"local_pos": local_pos,
		"local_normal": local_normal,
		"world_pos": local_to_world(ship, local_pos),
		"world_normal": local_dir_to_world(ship, local_normal).normalized(),
		"face_index": result.get('face_index'),
		"local_from": local_from,
		"local_to": local_to,
	}


## Closest armour hit along a ship-local segment, in the intersect_ray
## Dictionary shape: 'collider' (the ArmorPart), 'position', 'normal',
## 'face_index'. Empty on a miss. `hit_back_faces`/`exclude` are accepted for
## callers written against the physics query and ignored: the mesh is always
## two-sided and has nothing to exclude.
func precision_raycast(ship: Ship, from_local: Vector3, to_local: Vector3,
		_hit_back_faces: bool = true, _exclude: Array[RID] = []) -> Dictionary:
	var pm := _native()
	if pm == null:
		return {}
	var r: Dictionary = pm.armor_raycast(ship, from_local, to_local)
	if r.is_empty():
		return {}
	return {
		"collider": r["armor"],
		"position": r["position"],
		"normal": r["normal"],
		"face_index": r["face_index"],
	}


## Find the closest armor hit along a ray in ship-local space.
## Returns { 'armor': ArmorPart, 'position': Vector3, 'normal': Vector3,
## 'face_index': int } or empty dict on miss.
func precision_get_next_hit(ship: Ship, from_local: Vector3, to_local: Vector3) -> Dictionary:
	var pm := _native()
	if pm == null:
		return {}
	var r: Dictionary = pm.armor_raycast(ship, from_local, to_local)
	if r.is_empty():
		return {}
	return {
		'armor': r["armor"],
		'position': r["position"],
		'normal': r["normal"],
		'face_index': r["face_index"],
	}


## Which armor part a local-space point is inside (six-direction rule in the
## native mesh; prefers citadel parts). Returns the ORIGINAL ArmorPart or null.
func precision_get_part_hit(ship: Ship, local_pos: Vector3) -> ArmorPart:
	var pm := _native()
	if pm == null:
		return null
	return pm.armor_part_at(ship, local_pos) as ArmorPart


## Check if a ship is registered.
func is_ship_registered(ship: Ship) -> bool:
	return _ship_cache.has(ship.get_instance_id())


## Get cache entry for a ship (or empty dict if unregistered).
func get_ship_entry(ship: Ship) -> Dictionary:
	var sid := ship.get_instance_id()
	if _ship_cache.has(sid):
		return _ship_cache[sid]
	return {}


## Number of armour parts registered for a ship (for debug inspection).
func get_precision_body_count(ship: Ship) -> int:
	var sid := ship.get_instance_id()
	if _ship_cache.has(sid):
		return int(_ship_cache[sid]["parts"])
	return 0
