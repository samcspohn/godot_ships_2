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

# ---------------------------------------------------------------------------
# Slew-limit math
#
# All checks are framed in offset-from-slew_min space:
#
#   offset(a) = wrapf(a - slew_min_angle, 0, TAU)   in [0, TAU)
#   arc_width = wrapf(slew_max_angle - slew_min_angle, 0, TAU)
#                                                   in [0, TAU)
#
# Valid arc is offset in [0, arc_width]; dead zone is (arc_width, TAU).
# slew_min_angle == slew_max_angle is a degenerate empty arc (arc_width = 0,
# nothing valid). For unrestricted 360 degree rotation set
# slew_limits_enabled = false instead.
# ---------------------------------------------------------------------------

func _arc_width() -> float:
	return wrapf(slew_max_angle - slew_min_angle, 0.0, TAU)

func _offset_from_slew_min(angle: float) -> float:
	#return wrapf(angle - slew_min_angle, 0.0, TAU)
	var a = angle - slew_min_angle
	var b = wrapf(a, 0.0, TAU)
	return b

## Tolerance band around slew boundaries (radians). Larger than typical
## frame-to-frame Euler/quaternion round-trip drift (~1e-7 rad) but
## visually negligible (~0.006°). Used to:
##   1. Bias clamp_to_rotation_limits()'s snap inward so drift can't push the
##      stored rotation back into the dead zone.
##   2. Treat near-boundary `off` values as if they were exactly at the
##      boundary in apply_rotation_limits(), preventing the Case A saturating
##      correction from overshooting in response to sub-µrad drift.
const SLEW_BOUNDARY_EPS: float = 1.0e-4

## Returns [adjusted_delta, blocked, case_label].
##   blocked == true  => requested target lies in the dead zone; delta points
##                       to the nearest reachable boundary along the originally
##                       requested direction.
##   blocked == false => target reachable; delta may differ from input (long
##                       way around) to avoid crossing the dead zone.
## In Case A (current angle inside dead zone — should be unreachable but can
## occur via floating-point drift past a boundary), the returned delta is
## saturated (±TAU) in the chosen exit direction so the caller's per-frame
## clamp to ±max_delta always produces a full-speed self-correcting step
## rather than a sub-epsilon nudge that rounds to zero. Drift within
## SLEW_BOUNDARY_EPS of either boundary is *not* treated as Case A; it
## falls through to the normal B/C/D logic to avoid overshoot oscillation.
func apply_rotation_limits(current_angle: float, desired_delta: float) -> Array:
	# If rotation limits are not enabled, return the desired delta as is
	if not slew_limits_enabled or desired_delta == 0.0:
		return [desired_delta, false, "OFF"]

	var arc: float = _arc_width()
	var off: float = _offset_from_slew_min(current_angle)

	# Case A: current angle is genuinely inside the dead zone (beyond tolerance).
	# Near-boundary drift is absorbed into the valid arc so D_min / D_max can
	# handle the "at boundary, target in dead zone" case without oscillation.
	if off > arc:
		if (off - arc) < SLEW_BOUNDARY_EPS:
			off = arc  # treat as at slew_max boundary
		elif (TAU - off) < SLEW_BOUNDARY_EPS:
			off = 0.0  # treat as at slew_min boundary
		else:
			# Sub-case A1: target lies in the valid arc — slew toward whichever
			# boundary produces the shorter total path (exit + traversal). Return
			# saturated ±TAU in that direction so drift-induced sub-epsilon paths
			# still produce a full-rate corrective step.
			var target_off_w: float = wrapf(off + desired_delta, 0.0, TAU)
			if target_off_w <= arc:
				var path_via_min: float = (TAU - off) + target_off_w           # CCW: -> slew_min -> target
				var path_via_max: float = (off - arc) + (arc - target_off_w)   # CW : -> slew_max -> target
				var dir_a1: float = 1.0 if path_via_min <= path_via_max else -1.0
				return [dir_a1 * TAU, false, "A1"]
			# Sub-case A2: target also in the dead zone — exit via nearest boundary
			# at full rate (caller clamps to max_delta).
			var to_min: float = TAU - off       # CCW distance back to slew_min
			var to_max: float = off - arc       # CW  distance back to slew_max
			var dir_a2: float = 1.0 if to_min <= to_max else -1.0
			return [dir_a2 * TAU, true, "A2"]

	# Case B: current is valid. Try the desired delta as-is.
	var target_off: float = off + desired_delta
	if target_off >= 0.0 and target_off <= arc:
		return [desired_delta, false, "B"]

	# Case C: shortest path leaves the arc — try the long way around.
	var alt_delta: float = desired_delta + (TAU if desired_delta < 0.0 else -TAU)
	var alt_target: float = off + alt_delta
	if alt_target >= 0.0 and alt_target <= arc:
		return [alt_delta, false, "C"]

	# Case D: target is genuinely in the dead zone. Slew toward whichever
	# boundary (slew_min or slew_max) is angularly closer to the target.
	var target_off_wrapped: float = wrapf(target_off, 0.0, TAU)  # in (arc, TAU)
	var target_to_min: float = TAU - target_off_wrapped          # CCW: target -> 0
	var target_to_max: float = target_off_wrapped - arc           # CW : target -> arc
	if target_to_min <= target_to_max:
		return [-off, true, "D_min"]                              # hit slew_min
	else:
		return [arc - off, true, "D_max"]                         # hit slew_max


## Snap rotation.y to the nearest valid boundary if currently in the dead zone.
## Snaps with an inward bias of SLEW_BOUNDARY_EPS so frame-to-frame
## Euler/quaternion round-trip drift can't push the stored value back into
## the dead zone.
func clamp_to_rotation_limits() -> void:
	if not slew_limits_enabled:
		return
	var arc: float = _arc_width()
	var off: float = _offset_from_slew_min(rotation.y)
	if off <= arc:
		return
	var to_min: float = TAU - off
	var to_max: float = off - arc
	if to_min <= to_max:
		rotation.y = slew_min_angle + SLEW_BOUNDARY_EPS
	else:
		rotation.y = slew_max_angle - SLEW_BOUNDARY_EPS


## Returns true if the given world-space yaw lies in any defined fire arc.
## When fire_arcs is empty, falls back to the slew arc (preserving original
## Gun behavior); when slew limits are also disabled, always returns true.
func is_angle_in_fire_arcs(angle: float) -> bool:
	if fire_arcs.is_empty():
		if not slew_limits_enabled:
			return true
		return _offset_from_slew_min(angle) <= _arc_width()
	for a in fire_arcs:
		if a != null and a.contains(angle):
			return true
	return false

# returns true if turning
func return_to_base(delta: float) -> bool:
	# a = apply_rotation_limits(rotation.y, base_rotation - rotation.y)
	if disabled:
		return false
	can_fire = false
	_valid_target = false
	var turret_rot_speed_rad: float = deg_to_rad(get_params().traverse_speed)
	var max_turret_angle_delta: float = turret_rot_speed_rad * delta
	var adjusted_angle = base_rotation - rotation.y
	if abs(adjusted_angle) > PI:
		adjusted_angle = - sign(adjusted_angle) * (TAU - abs(adjusted_angle))
	var turret_angle_delta = clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta)

	if abs(turret_angle_delta) < 0.001:
		# can_fire = false
		return false
	# Apply rotation
	rotate(Vector3.UP, turret_angle_delta)
	# clamp_to_rotation_limits()
	# can_fire = false
	return true

func get_angle_to_target(target: Vector3) -> float:
	var forward: Vector3 = - global_basis.z.normalized()
	var forward_2d: Vector2 = Vector2(forward.x, forward.z).normalized()
	var target_dir: Vector3 = (target - global_position).normalized()
	var target_dir_2d: Vector2 = Vector2(target_dir.x, target_dir.z).normalized()
	var desired_local_angle_delta: float = target_dir_2d.angle_to(forward_2d)
	return desired_local_angle_delta

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
		return is_angle_in_fire_arcs(rotation.y + desired_local_angle_delta)
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
	if disabled:
		return INF
	if name == "GER_150mm_2b_gerat60_009" and _ship.name == "1":
		pass
	# Cache constants
	# const TURRET_ROT_SPEED_DEG: float = 40.0

	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(get_params().traverse_speed)
	var max_turret_angle_delta: float = turret_rot_speed_rad * delta
	# var local_target: Vector3 = to_local(aim_point)

	# # Calculate desired rotation angle in the horizontal plane
	# var desired_local_angle: float = -atan2(local_target.x, local_target.z)

	var desired_local_angle_delta: float = get_angle_to_target(aim_point)

	# Slew clamping: produces a delta the mount may legally rotate by.
	var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
	var adjusted_angle: float = a[0]
	# Firing validity is a separate question: does the *target bearing* lie in
	# any fire arc? (When fire_arcs is empty this falls back to slew arc, which
	# is equivalent to the previous `not a[1]` behavior.)
	_valid_target = is_angle_in_fire_arcs(rotation.y + desired_local_angle_delta)
	var turret_angle_delta: float = clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta)
	if _return_to_base and not _valid_target:
		adjusted_angle = base_rotation - rotation.y
		if abs(adjusted_angle) > PI:
			adjusted_angle = - sign(adjusted_angle) * (TAU - abs(adjusted_angle))
		turret_angle_delta = clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta)

	# Apply rotation
	rotate(Vector3.UP, turret_angle_delta)

	# Ensure rotation is within limits
	# if not _return_to_base:
	clamp_to_rotation_limits()
	return desired_local_angle_delta

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

	enable_backface_collision_recursive(self)

	# Register turret armor parts with PrecisionPhysicsWorld.
	# The ship registered before turret deferred init ran, so these parts
	# were missed.  add_armor_part handles late registration.
	if _ship != null and PrecisionPhysicsWorld != null:
		for part: ArmorPart in _ship.armor_parts:
			# Only register parts that belong to this turret (children of self)
			if part.get_parent() == self or self.is_ancestor_of(part):
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

func enable_backface_collision_recursive(node: Node) -> void:
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
		self._ship.armor_parts.append(armor_part)
		# self.aabb = self.aabb.merge((node as MeshInstance3D).get_aabb())
		# static_body.collision_layer = 1 << 1
		# static_body.collision_mask = 0
		# if node.name == "Hull":
		# 	hull = armor_part
		# 	print("armor_part.collision_layer: ", armor_part.collision_layer)
		# 	print("armor_part.collision_mask: ", armor_part.collision_mask)
		# elif node.name == "Citadel":
		# 	citadel = armor_part

	for child in node.get_children():
		enable_backface_collision_recursive(child)
