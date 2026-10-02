extends Node3D
class_name Turret

## Slew limits constrain where the mount is physically allowed to point.
## Set slew_limits_enabled = false for unrestricted 360 degree rotation. When
## enabled, slew_min_angle == slew_max_angle is a degenerate empty arc (the
## mount considers no bearing valid) — use that as a sentinel for "this scene
## has not yet had its slew arc configured".
@export var slew_limits_enabled: bool = true
@export var slew_min_angle: float = deg_to_rad(0)
@export var slew_max_angle: float = deg_to_rad(360)

## Optional firing arcs, independent of slew limits. When empty, validity
## checks fall back to the slew arc (preserving original Gun semantics). When
## populated, a target bearing is considered valid only if it lies in at least
## one arc — useful for weapons (e.g. torpedo launchers) that may rotate
## through a full circle but only fire over selected sectors.
@export var fire_arcs: Array[FireArc] = []

# @onready var barrel: Node3D = get_child(0).get_child(0)
# var sound: AudioStreamPlayer3D
# @export var dispersion_calculator: DispersionCalculator
var _aim_point: Vector3
var reload: float = 0.0
var can_fire: bool = false
var _valid_target: bool = false
var muzzles: Array[Node3D] = []
var gun_id: int
var disabled: bool = true
var base_rotation: float

# var max_range: float
# var max_flight: float
var _ship: Ship
var id: int = -1
# @export var params: GunParams
# var my_params: GunParams = GunParams.new()

# Armor system configuration
var armor_system: ArmorSystemV2
@export_file("*.glb") var glb_path: String


# var launch_vector: Vector3 = Vector3.ZERO
# var flight_time: float = 0.0

var controller

# class SimShell:
# 	var start_position: Vector3 = Vector3.ZERO
# 	var position: Vector3 = Vector3.ZERO

# var shell_sim: SimShell = SimShell.new()
# var sim_shell_in_flight: bool = false

# func to_dict() -> Dictionary:
# 	return {
# 		"r": basis,
# 		"e": barrel.basis,
# 		"c": can_fire,
# 		"v": _valid_target,
# 		"rl": reload
# 	}

# func to_bytes(full: bool) -> PackedByteArray:
# 	var writer = StreamPeerBuffer.new()

# 	writer.put_float(rotation.y)

# 	writer.put_float(barrel.rotation.x)

# 	if full:
# 		writer.put_u8(1 if can_fire else 0)
# 		writer.put_u8(1 if _valid_target else 0)

# 		writer.put_float(reload)

# 	return writer.get_data_array()

# func from_dict(d: Dictionary) -> void:
# 	basis = d.r
# 	barrel.basis = d.e
# 	can_fire = d.c
# 	_valid_target = d.v
# 	reload = d.rl

# func from_bytes(b: PackedByteArray, full: bool) -> void:
# 	var reader = StreamPeerBuffer.new()
# 	reader.data_array = b

# 	rotation.y = reader.get_float()

# 	barrel.rotation.x = reader.get_float()

# 	if not full:
# 		return
# 	can_fire = reader.get_u8() == 1
# 	_valid_target = reader.get_u8() == 1

# 	reload = reader.get_float()

func get_params() -> TurretParams:
	return controller.get_params()

# func get_shell() -> ShellParams:
# 	return controller.get_shell_params()



func cleanup():
	# detach from parent for easier management
	var grand_parent = self.get_parent().get_parent()
	var parent = self.get_parent()
	var saved_transform = self.global_transform

	# Remove self from parent first
	parent.remove_child(self)
	# Add self to grandparent
	grand_parent.add_child(self)
	# Now safe to remove and free the old parent
	grand_parent.remove_child(parent)
	parent.queue_free()

	# Restore transform and owner
	self.global_transform = saved_transform
	self.owner = grand_parent

	base_rotation = rotation.y



func _ready() -> void:

	# Set processing mode based on authority
	if _Utils.authority():
		set_physics_process(true)
	else:
		# We still need to receive updates, just not run physics
		set_physics_process(false)

	# print(rad_to_deg(base_rotation))

	#_ship = get_parent().get_parent() as Ship
	initialize_armor_system.call_deferred()
	cleanup.call_deferred()

	process_physics_priority = 2




# # Function to update barrels based on editor properties
# func update_barrels() -> void:
# 	# Clear existing muzzles array
# 	muzzles.clear()

# 	# Check if barrel exists
# 	if not is_node_ready():
# 		# We might be in the editor, just return
# 		return

# 	for muzzle in barrel.get_children():
# 		# if muzzle.name.contains("Muzzle"):
# 		muzzles.append(muzzle)

# 	# print("Muzzles updated: ", muzzles.size())

# func _physics_process(delta: float) -> void:
# 	if _Utils.authority():
# 		if !disabled && reload < 1.0:
# 			reload = min(reload + delta / get_params().reload_time, 1.0)

func return_to_base(delta: float) -> bool:
	return TurretCore.turret_home(self, delta, get_params().traverse_speed)

func is_angle_in_fire_arcs(angle: float) -> bool:
	return TurretCore.in_fire_arcs(self, angle)

func get_angle_to_target(target: Vector3) -> float:
	return TurretCore.angle_to_target(self, target)

func valid_target(target: Vector3) -> bool: # virtual
	return false
	# var sol = ProjectilePhysicsWithDrag.calculate_launch_vector(global_position, target, get_shell().speed, get_shell().drag)
	# if sol[0] != null and (target - global_position).length() < get_params()._range:
	# 	var desired_local_angle_delta: float = get_angle_to_target(target)
	# 	var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
	# 	if a[1]:
	# 		return false
	# 	return true
	# return false

func get_leading_position(target: Vector3, target_velocity: Vector3): # virtual
	return null
	# var sol = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(global_position, target, target_velocity, get_shell().speed, get_shell().drag)
	# if sol[0] != null and (sol[2] - global_position).length() < get_params()._range:
	# 	return sol[2]
	# return null

func get_dist(pos: Vector3) -> float:
	var dist = (pos - _ship.global_position)
	dist.y = 0
	return dist.length() - 0.001

func is_aimpoint_valid(aim_point: Vector3) -> bool:
	var dist = get_dist(aim_point)
	if dist < get_params()._range:
		var desired_local_angle_delta: float = get_angle_to_target(aim_point)
		return !slew_limits_enabled or is_angle_in_fire_arcs(rotation.y + desired_local_angle_delta)
	return false

func valid_target_leading(target: Vector3, target_velocity: Vector3) -> bool: # virtual
	return false
	# var sol = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(global_position, target, target_velocity, get_shell().speed, get_shell().drag)
	# if sol[0] != null and (sol[2] - global_position).length() < get_params()._range:
	# 	var desired_local_angle_delta: float = get_angle_to_target(sol[2])
	# 	var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
	# 	if a[1]:
	# 		return false
	# 	return true
	# return false

func _aim(aim_point: Vector3, delta: float, _return_to_base: bool) -> float:
	return TurretCore.turret_aim(self, aim_point, delta, _return_to_base, get_params().traverse_speed)

func initialize_armor_system() -> void:
	"""Initialize the armor system by loading armor data from the GLB via ArmorRegistry."""
	# Secondary guns (controlled by SecSubController) intentionally have no armor.
	# The GLB-imported StaticBody3D nodes must still be removed so they don't
	# collide with the physics world and cause the ship to sink.
	if controller is SecSubController:
		remove_static_bodies(self)
		return

	var resolved_glb_path = _ship.resolve_glb_path(glb_path)
	if resolved_glb_path.is_empty():
		print("   ❌ Invalid or missing GLB path: ", glb_path)
		return

	armor_system = ArmorSystemV2.new()
	add_child(armor_system)

	var success = armor_system.load_from_glb(resolved_glb_path)
	if not success:
		print("   ❌ Failed to load armor data for: ", resolved_glb_path)

	var parts = enable_backface_collision_recursive(self)

	# Register turret armor parts with PrecisionPhysicsWorld.
	# The ship registered before turret deferred init ran, so these parts
	# were missed.  add_armor_part handles late registration.
	var registered_parts: int = 0
	if _ship != null and PrecisionPhysicsWorld != null:
		for part: ArmorPart in _ship.armor_parts:
			# Only register parts that belong to this turret (children of self)
			if part.get_parent() == self or self.is_ancestor_of(part):
				PrecisionPhysicsWorld.add_armor_part(_ship, part)
				registered_parts += 1
	if registered_parts == 0:
		for part in parts:
			PrecisionPhysicsWorld.add_armor_part(_ship, part)


	print("done")

func remove_static_bodies(node: Node) -> void:
	# Collect first to avoid mutating the tree while iterating children.
	var to_free: Array[StaticBody3D] = []
	collect_static_bodies(node, to_free)
	for body in to_free:
		body.queue_free()

func collect_static_bodies(node: Node, out: Array[StaticBody3D]) -> void:
	if node is StaticBody3D:
		out.append(node as StaticBody3D)
		return  # Don't recurse into the body; its children go with it.
	for child in node.get_children():
		collect_static_bodies(child, out)

func enable_backface_collision_recursive(node: Node) -> Array:
	var out: Array = []
	enable_backface_collision_recursive_collect(node, out)
	return out

func enable_backface_collision_recursive_collect(node: Node, out: Array) -> void:
	var path: String = ""
	var n = node
	while n != self:
		path = n.name + "/" + path
		n = n.get_parent()
	path = path.rstrip("/")
	if armor_system.armor_data.has(path) and node is MeshInstance3D:
		var static_body: StaticBody3D = node.find_child("StaticBody3D", false)
		var collision_shape: CollisionShape3D = static_body.find_child("CollisionShape3D", false)
		static_body.remove_child(collision_shape)
		if collision_shape.shape is ConcavePolygonShape3D:
			collision_shape.shape.backface_collision = true
		static_body.queue_free()

		var armor_part = ArmorPart.new()
		armor_part.add_child(collision_shape)
		armor_part.collision_layer = 1 << 1
		armor_part.collision_mask = 0
		armor_part.armor_system = armor_system
		armor_part.armor_path = path
		armor_part.ship = self._ship
		node.add_child(armor_part)
		out.append(armor_part)
		self._ship.armor_parts.append(armor_part)

	for child in node.get_children():
		enable_backface_collision_recursive_collect(child, out)
