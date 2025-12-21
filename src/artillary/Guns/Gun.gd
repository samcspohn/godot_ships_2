class_name Gun
extends Node3D

# Properties for editor
@export var barrel_count: int = 1
@export var barrel_spacing: float = 0.5
@export var rotation_limits_enabled: bool = true
@export var min_rotation_angle: float = deg_to_rad(90)
@export var max_rotation_angle: float = deg_to_rad(180)

@onready var barrel: Node3D = get_child(0).get_child(0)
# @export var dispersion_calculator: ArtilleryDispersion
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
@export_file("*.glb") var ship_model_glb_path: String
@export var auto_extract_armor: bool = true

# var launch_vector: Vector3 = Vector3.ZERO
# var flight_time: float = 0.0

var controller


class SimShell:
	var start_position: Vector3 = Vector3.ZERO
	var position: Vector3 = Vector3.ZERO

var shell_sim: SimShell = SimShell.new()
var sim_shell_in_flight: bool = false

func to_dict() -> Dictionary:
	return {
		"r": basis,
		"e": barrel.basis,
		"c": can_fire,
		"v": _valid_target,
		"rl": reload
	}

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	
	writer.put_float(rotation.y)

	writer.put_float(barrel.rotation.x)
	
	writer.put_u8(1 if can_fire else 0)
	writer.put_u8(1 if _valid_target else 0)
	
	writer.put_float(reload)
	
	return writer.get_data_array()

func from_dict(d: Dictionary) -> void:
	basis = d.r
	barrel.basis = d.e
	can_fire = d.c
	_valid_target = d.v
	reload = d.rl

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	
	rotation.y = reader.get_float()
	
	barrel.rotation.x = reader.get_float()
	
	can_fire = reader.get_u8() == 1
	_valid_target = reader.get_u8() == 1
	
	reload = reader.get_float()

func get_params() -> GunParams:
	return controller.get_params()

func get_shell() -> ShellParams:
	return controller.get_shell_params()

func notify_gun_updated():
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	if server != null and _Utils.authority():
		server.gun_updated = true

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

	notify_gun_updated.call_deferred()

func _ready() -> void:
	# params.shell = params.shell2
	# my_params.from_params(params)

	#var a = ProjectilePhysicsWithDrag.calculate_absolute_max_range(get_shell().speed, get_shell().drag)
	#max_range = min(a[0], controller.get("_my_gun_params")._range)
	#max_flight = a[2]
#
	#if max_range < a[0]:
		#max_flight = ProjectilePhysicsWithDrag.calculate_launch_vector(Vector3.ZERO, Vector3(0, 0, max_range), get_shell().speed, get_shell().drag)[1]


	#print("max range: ", a)
	
	# Set up muzzles
	update_barrels()
	
	# Set processing mode based on authority
	if _Utils.authority():
		process_mode = Node.PROCESS_MODE_INHERIT
	else:
		# We still need to receive updates, just not run physics
		process_mode = Node.PROCESS_MODE_INHERIT
		set_physics_process(false)

	# print(rad_to_deg(base_rotation))
	
	#_ship = get_parent().get_parent() as Ship
	initialize_armor_system.call_deferred()
	cleanup.call_deferred()
	



# Function to update barrels based on editor properties
func update_barrels() -> void:
	# Clear existing muzzles array
	muzzles.clear()
	
	# Check if barrel exists
	if not is_node_ready():
		# We might be in the editor, just return
		return
	
	for muzzle in barrel.get_children():
		# if muzzle.name.contains("Muzzle"):
		muzzles.append(muzzle)

	# print("Muzzles updated: ", muzzles.size())

func _physics_process(delta: float) -> void:
	if _Utils.authority():
		if !disabled && reload < 1.0:
			reload = min(reload + delta / get_params().reload_time, 1.0)

# Normalize angle to the range [0, 2π]
func normalize_angle_0_2pi(angle: float) -> float:
	while angle < 0:
		angle += TAU
	
	while angle >= TAU:
		angle -= TAU
	
	return angle


# Apply rotation limits to a desired rotation
func apply_rotation_limits(current_angle: float, desired_delta: float) -> Array:
	# If rotation limits are not enabled, return the desired delta as is
	if not rotation_limits_enabled or desired_delta == 0:
		return [desired_delta, false]
	
	# Normalize the current angle to [0, 2π]
	var normalized_current = normalize_angle_0_2pi(current_angle)
	
	# Calculate the target angle after applying the delta
	var target_angle = normalize_angle_0_2pi(normalized_current + desired_delta)
	
	# Check if the target angle is in the valid region
	var is_target_valid = false
	if min_rotation_angle <= max_rotation_angle:
		# Valid region is [min, max]
		is_target_valid = (target_angle >= min_rotation_angle and target_angle <= max_rotation_angle)
	else:
		# Valid region wraps around: [min, 2π] ∪ [0, max]
		is_target_valid = (target_angle >= min_rotation_angle or target_angle <= max_rotation_angle)
	
	# If target is valid, check if the rotation path crosses the invalid region
	if is_target_valid:
		# Check if we're rotating through the invalid region
		var crosses_invalid = false
		
		if min_rotation_angle <= max_rotation_angle:
			# The invalid region is [0, min) ∪ (max, 2π)
			var invalid_region = TAU - (max_rotation_angle - min_rotation_angle)
			if desired_delta > 0: # Clockwise rotation
				crosses_invalid = normalized_current <= max_rotation_angle + 0.01 and normalized_current + desired_delta > max_rotation_angle + invalid_region
			else: # Counter-clockwise rotation
				crosses_invalid = normalized_current >= min_rotation_angle - 0.01 and normalized_current + desired_delta < min_rotation_angle - invalid_region
		else:
			# The invalid region is (max, min)
			if desired_delta > 0: # Clockwise rotation
				# Check if we start in the lower valid region and would end up past the min boundary
				if normalized_current <= max_rotation_angle:
					crosses_invalid = (normalized_current + desired_delta) > min_rotation_angle
				else:
					# Starting in upper valid region, can't cross invalid by going clockwise
					crosses_invalid = false
			else: # Counter-clockwise rotation
				# Check if we start in the upper valid region and would end up below the max boundary
				if normalized_current >= min_rotation_angle:
					crosses_invalid = (normalized_current + desired_delta) < max_rotation_angle
				else:
					# Starting in lower valid region, can't cross invalid by going counter-clockwise
					crosses_invalid = false
			# print("Crosses invalid (wrap): ", crosses_invalid)
				
		if crosses_invalid:
			# If we would cross the invalid region, go the other way around the circle
			if desired_delta > 0:
				# Was going clockwise, now go counter-clockwise
				return [desired_delta - TAU, false]
			else:
				# Was going counter-clockwise, now go clockwise
				return [desired_delta + TAU, false]
		else:
			# No invalid region crossed, return the desired delta unchanged
			return [desired_delta, false]
	else:
		# Target is in the invalid region, find the nearest valid boundary
		var dist_to_min = min(abs(target_angle - min_rotation_angle), TAU - abs(target_angle - min_rotation_angle))
		var dist_to_max = min(abs(target_angle - max_rotation_angle), TAU - abs(target_angle - max_rotation_angle))
		
		if min_rotation_angle <= max_rotation_angle:
			if dist_to_min <= dist_to_max:
				# Min angle is closer, go to min angle
				return [min_rotation_angle - normalized_current, true]
			else:
				# Max angle is closer, go to max angle
				return [max_rotation_angle - normalized_current, true]
		else:
			if dist_to_min <= dist_to_max:
				# Min angle is closer, go to min angle
				return [-normalize_angle_0_2pi(TAU - (min_rotation_angle - normalized_current)), true]
			else:
				# Max angle is closer, go to max angle
				return [normalize_angle_0_2pi(TAU - (max_rotation_angle - normalized_current)), true]

# Ensure rotation is within the valid range
func clamp_to_rotation_limits() -> void:
	if not rotation_limits_enabled:
		return
		
	# Normalize the current angle to [0, 2π]
	var normalized_current = normalize_angle_0_2pi(rotation.y)
	
	# Check if the current angle is in the valid region
	var is_valid = false
	if min_rotation_angle <= max_rotation_angle:
		# Valid region is [min, max]
		is_valid = (normalized_current >= min_rotation_angle and normalized_current <= max_rotation_angle)
	else:
		# Valid region wraps around: [min, 2π] ∪ [0, max]
		is_valid = (normalized_current >= min_rotation_angle or normalized_current <= max_rotation_angle)
	
	# If current angle is not valid, clamp to nearest boundary
	if not is_valid:
		var dist_to_min = min(abs(normalized_current - min_rotation_angle), TAU - abs(normalized_current - min_rotation_angle))
		var dist_to_max = min(abs(normalized_current - max_rotation_angle), TAU - abs(normalized_current - max_rotation_angle))
		
		if dist_to_min <= dist_to_max:
			# Min angle is closer
			rotation.y = min_rotation_angle
		else:
			# Max angle is closer
			rotation.y = max_rotation_angle

# Simplified versions of the rotation functions
func normalize_angle_0_2pi_simple(angle: float) -> float:
	return fmod(angle + TAU * 1000, TAU)

func apply_rotation_limits_simple(current_angle: float, desired_delta: float) -> Array:
	if not rotation_limits_enabled or desired_delta == 0:
		return [desired_delta, false]
	
	var current = normalize_angle_0_2pi_simple(current_angle)
	var target = normalize_angle_0_2pi_simple(current + desired_delta)
	
	# Check if target is in valid range
	var is_valid: bool
	if min_rotation_angle <= max_rotation_angle:
		is_valid = target >= min_rotation_angle and target <= max_rotation_angle
	else:
		is_valid = target >= min_rotation_angle or target <= max_rotation_angle
	
	if is_valid:
		# Check if shortest rotation path crosses invalid region
		var crosses_invalid = false
		
		if min_rotation_angle <= max_rotation_angle:
			# Valid region is [min, max], invalid regions are [0, min) and (max, 2π]
			# Check if we cross through either invalid region
			if desired_delta > 0:
				# Going clockwise - check if we cross from valid region through invalid back to valid
				if current >= min_rotation_angle and current <= max_rotation_angle:
					# We're in valid region, check if we go past max then wrap to target
					var steps_to_max = max_rotation_angle - current
					crosses_invalid = desired_delta > steps_to_max and desired_delta > (TAU - current + target)
			else:
				# Going counter-clockwise - check if we cross from valid region through invalid back to valid  
				if current >= min_rotation_angle and current <= max_rotation_angle:
					# We're in valid region, check if we go below min then wrap to target
					var steps_to_min = current - min_rotation_angle
					crosses_invalid = abs(desired_delta) > steps_to_min and abs(desired_delta) > (current + TAU - target)
		else:
			# Valid region wraps: [min, 2π] ∪ [0, max], invalid region is (max, min)
			if desired_delta > 0 and current <= max_rotation_angle:
				# Starting in lower valid region, check if we cross invalid region to upper valid region
				crosses_invalid = target >= min_rotation_angle and (current + desired_delta) > min_rotation_angle
			elif desired_delta < 0 and current >= min_rotation_angle:
				# Starting in upper valid region, check if we cross invalid region to lower valid region  
				crosses_invalid = target <= max_rotation_angle and (current + desired_delta) < max_rotation_angle
		
		if crosses_invalid:
			# Take the longer path around the circle to avoid invalid region
			return [desired_delta + (TAU if desired_delta < 0 else -TAU), false]
		
		return [desired_delta, false]
	else:
		# Target invalid, find nearest boundary
		var to_min = min_rotation_angle - current
		var to_max = max_rotation_angle - current
		
		# Normalize deltas to shortest path
		if abs(to_min) > PI:
			to_min += TAU if to_min < 0 else -TAU
		if abs(to_max) > PI:
			to_max += TAU if to_max < 0 else -TAU
		
		return [to_min if abs(to_min) <= abs(to_max) else to_max, true]

func clamp_to_rotation_limits_simple() -> void:
	if not rotation_limits_enabled:
		return
	
	var current = normalize_angle_0_2pi_simple(rotation.y)
	var is_valid: bool
	
	if min_rotation_angle <= max_rotation_angle:
		is_valid = current >= min_rotation_angle and current <= max_rotation_angle
	else:
		is_valid = current >= min_rotation_angle or current <= max_rotation_angle
	
	if not is_valid:
		var to_min = abs(current - min_rotation_angle)
		var to_max = abs(current - max_rotation_angle)
		
		# Account for circular distance
		to_min = min(to_min, TAU - to_min)
		to_max = min(to_max, TAU - to_max)
		
		rotation.y = min_rotation_angle if to_min <= to_max else max_rotation_angle

func return_to_base(delta: float) -> void:
	# a = apply_rotation_limits(rotation.y, base_rotation - rotation.y)
	var turret_rot_speed_rad: float = deg_to_rad(get_params().traverse_speed)
	var max_turret_angle_delta: float = turret_rot_speed_rad * delta
	var adjusted_angle = base_rotation - rotation.y
	if abs(adjusted_angle) > PI:
		adjusted_angle = - sign(adjusted_angle) * (TAU - abs(adjusted_angle))
	var turret_angle_delta = clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta)
	# Apply rotation
	rotate(Vector3.UP, turret_angle_delta)
	# clamp_to_rotation_limits()
	can_fire = false

func get_angle_to_target(target: Vector3) -> float:
	var forward: Vector3 = - global_basis.z.normalized()
	var forward_2d: Vector2 = Vector2(forward.x, forward.z).normalized()
	var target_dir: Vector3 = (target - global_position).normalized()
	var target_dir_2d: Vector2 = Vector2(target_dir.x, target_dir.z).normalized()
	var desired_local_angle_delta: float = target_dir_2d.angle_to(forward_2d)
	return desired_local_angle_delta

func valid_target(target: Vector3) -> bool:
	var sol = ProjectilePhysicsWithDrag.calculate_launch_vector(global_position, target, get_shell().speed, get_shell().drag)
	if sol[0] != null and (target - global_position).length() < get_params()._range:
		var desired_local_angle_delta: float = get_angle_to_target(target)
		var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
		if a[1]:
			return false
		return true
	return false

func valid_target_leading(target: Vector3, target_velocity: Vector3) -> bool:
	var sol = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(global_position, target, target_velocity, get_shell().speed, get_shell().drag)
	if sol[0] != null and (sol[2] - global_position).length() < get_params()._range:
		var desired_local_angle_delta: float = get_angle_to_target(sol[2])
		var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
		if a[1]:
			return false
		return true
	return false

func get_muzzles_position() -> Vector3:
	var muzzles_pos: Vector3 = Vector3.ZERO
	for m in muzzles:
		muzzles_pos += m.global_position
	muzzles_pos /= muzzles.size()
	return muzzles_pos

# Implement on server
func _aim(aim_point: Vector3, delta: float, _return_to_base: bool = false) -> void:
	if disabled:
		return
	# Cache constants
	# const TURRET_ROT_SPEED_DEG: float = 40.0
	
	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(get_params().traverse_speed)
	var max_turret_angle_delta: float = turret_rot_speed_rad * delta
	# var local_target: Vector3 = to_local(aim_point)

	# # Calculate desired rotation angle in the horizontal plane
	# var desired_local_angle: float = -atan2(local_target.x, local_target.z)

	var desired_local_angle_delta: float = get_angle_to_target(aim_point)

	# Apply rotation limits
	var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
	var adjusted_angle: float = a[0]
	_valid_target = not a[1]
	# var adjusted_angle = desired_local_angle
	var turret_angle_delta: float = clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta)
	if _return_to_base and not _valid_target:
		# a = apply_rotation_limits(rotation.y, base_rotation - rotation.y)
		adjusted_angle = base_rotation - rotation.y
		if abs(adjusted_angle) > PI:
			adjusted_angle = - sign(adjusted_angle) * (TAU - abs(adjusted_angle))
		_valid_target = not a[1]
		turret_angle_delta = clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta)

	# Apply rotation
	rotate(Vector3.UP, turret_angle_delta)
	
	# Ensure rotation is within limits
	# if not _return_to_base:
	clamp_to_rotation_limits()

	var muzzles_pos = get_muzzles_position()

	# Existing aiming logic for elevation
	var sol = ProjectilePhysicsWithDrag.calculate_launch_vector(muzzles_pos, aim_point, get_shell().speed, get_shell().drag)
	if sol[0] != null and (aim_point - muzzles_pos).length() < get_params()._range:
		self._aim_point = aim_point
	else:
		var g = Vector3(global_position.x, 0, global_position.z)
		self._aim_point = g + (Vector3(aim_point.x, 0, aim_point.z) - g).normalized() * (get_params()._range - 500)
		sol = ProjectilePhysicsWithDrag.calculate_launch_vector(muzzles_pos, self._aim_point, get_shell().speed, get_shell().drag)

	# launch_vector = sol[0]
	# flight_time = sol[1]

	var turret_elev_speed_rad: float = deg_to_rad(get_params().elevation_speed)
	var max_elev_angle: float = turret_elev_speed_rad * delta
	var elevation_delta: float = max_elev_angle
	if sol[1] != -1:
		var barrel_dir = sol[0]
		var elevation = Vector2(Vector2(barrel_dir.x, barrel_dir.z).length(), barrel_dir.y).normalized()
		var curr_elevation = Vector2(Vector2(barrel.global_basis.z.x, barrel.global_basis.z.z).length(), -barrel.global_basis.z.y).normalized()
		var elevation_angle = curr_elevation.angle_to(elevation)
		elevation_delta = clamp(elevation_angle, -max_elev_angle, max_elev_angle)
	if sol[0] == null:
		elevation_delta = - max_elev_angle
	
	if is_nan(elevation_delta):
		elevation_delta = 0.0
	barrel.rotate(Vector3.RIGHT, elevation_delta)
	
	if abs(elevation_delta) < 0.02 && abs(desired_local_angle_delta) < 0.02 and _valid_target:
		can_fire = true
	else:
		can_fire = false


	# # Ensure we stay within allowed elevation range
	# barrel.rotation_degrees.x = clamp(barrel.rotation_degrees.x, -30, 10)

# Normalize angle to the range [-PI, PI]
func normalize_angle(angle: float) -> float:
	return wrapf(angle, -PI, PI)

func _aim_leading(aim_point: Vector3, vel: Vector3, delta: float):
	var muzzles_pos = get_muzzles_position()
	var sol = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(muzzles_pos, aim_point, vel, get_shell().speed, get_shell().drag)
	if sol[0] == null or (aim_point - muzzles_pos).length() > get_params()._range:
		can_fire = false
		return
	_aim(sol[2], delta, true)


func fire(mod: TargetMod = null) -> void:
	if _Utils.authority():
		if !disabled && reload >= 1.0 and can_fire:
			var muzzles_pos = get_muzzles_position()
			for m in muzzles:
				var dispersed_velocity = get_params().calculate_dispersed_launch(_aim_point, muzzles_pos, controller.shell_index, mod)
				# var aim = ProjectilePhysicsWithDrag.calculate_launch_vector(m.global_position, _aim_point, get_shell().speed, get_shell().drag)
				if dispersed_velocity != null:
					var t = Time.get_unix_time_from_system()
					var _id = ProjectileManager.fireBullet(dispersed_velocity, m.global_position, get_shell(), t, _ship)
					TcpThreadPool.send_fire_gun(id, dispersed_velocity, m.global_position, t, _id)
				else:
					pass
					# print(aim)
			reload = 0

# @rpc("authority", "reliable")
func fire_client(vel, pos, t, _id):
	ProjectileManager.fireBulletClient(pos, vel, t, _id, get_shell(), _ship, true, barrel.global_basis)

@rpc("authority", "call_remote", "reliable", 2)
func fire_client2(data: PackedByteArray) -> void:
	if data.size() != 36:
		print("Invalid fire_client2 data size: ", data.size())
		return
	var stream = StreamPeerBuffer.new()
	stream.data_array = data
	var vel = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
	var pos = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
	var t = stream.get_double()
	var _id = stream.get_32()
	ProjectileManager.fireBulletClient(pos, vel, t, _id, get_shell(), _ship, true, barrel.global_basis)




func initialize_armor_system() -> void:
	"""Initialize the armor system - extract and load armor data"""
	# print("🛡️ Initializing armor system for ship...")
	
	# Validate and resolve the GLB path
	var resolved_glb_path = _ship.resolve_glb_path(ship_model_glb_path)
	if resolved_glb_path.is_empty():
		print("   ❌ Invalid or missing GLB path: ", ship_model_glb_path)
		return
	
	# Create armor system instance
	armor_system = ArmorSystemV2.new()
	add_child(armor_system)
	
	# Determine paths
	var model_name = resolved_glb_path.get_file().get_basename()
	var ship_dir = resolved_glb_path.get_base_dir()
	var armor_json_path = ship_dir + "/" + model_name + "_armor.json"
	
	# Check if armor JSON already exists
	if FileAccess.file_exists(armor_json_path):
		# print("   ✅ Found existing armor data, loading...")
		var success = armor_system.load_armor_data(armor_json_path)
		if success:
			pass
			# print("   ✅ Armor system initialized successfully")
		else:
			print("   ❌ Failed to load existing armor data")
	elif auto_extract_armor:
		# print("   🔧 No armor data found, extracting from GLB...")
		extract_and_load_armor_data(resolved_glb_path, armor_json_path)
	else:
		print("   ⚠️ No armor data found and auto-extraction disabled")

	enable_backface_collision_recursive(self)
	print("done")


func extract_and_load_armor_data(glb_path: String, armor_json_path: String) -> void:
	"""Extract armor data from GLB and save it locally"""
	# Load the extractor
	var extractor_script = load("res://src/armor/enhanced_armor_extractor_v2.gd")
	var extractor = extractor_script.new()
	
	# print("      Extracting armor data from GLB...")
	var success = extractor.extract_armor_with_mapping_to_json(glb_path, armor_json_path)
	
	if success:
		# Load the newly extracted data
		success = armor_system.load_armor_data(armor_json_path)
		if success:
			pass
			# print("      ✅ Armor system initialized successfully")
		else:
			print("      ❌ Failed to load extracted armor data")
	else:
		print("      ❌ Armor extraction failed")


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
		self.add_child(armor_part)
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


func sim_can_shoot_over_terrain(aim_point: Vector3) -> bool:
	
	var muzzles_pos = get_muzzles_position()
	var sol = ProjectilePhysicsWithDrag.calculate_launch_vector(muzzles_pos, aim_point, get_shell().speed, get_shell().drag)
	if sol[0] == null:
		return false
	var launch_vector = sol[0]
	var flight_time = sol[1]
	var can_shoot = sim_can_shoot_over_terrain_static(muzzles_pos, launch_vector, flight_time, get_shell().drag, _ship)
	return can_shoot.can_shoot_over_terrain and can_shoot.can_shoot_over_ship
	# shell_sim.start_position = muzzles_pos
	# shell_sim.position = muzzles_pos
	# sim_shell_in_flight = true
	# var sol = ProjectilePhysicsWithDrag.calculate_launch_vector(muzzles_pos, aim_point, get_shell().speed, get_shell().drag)
	# if sol[0] == null:
	# 	return false
	# var launch_vector = sol[0]
	# var flight_time = sol[1]
	# var space_state = get_world_3d().direct_space_state
	# var ray = PhysicsRayQueryParameters3D.new()
	# ray.collide_with_bodies = true
	# ray.collision_mask = 1
	# var t = 1.0
	# while t < flight_time + 1.0:
	# 	ray.from = shell_sim.position
	# 	ray.to = ProjectilePhysicsWithDrag.calculate_position_at_time(
	# 		shell_sim.start_position,
	# 		launch_vector,
	# 		t,
	# 		get_shell().drag,
	# 	)
	# 	# ray.collide_with_bodies = true
	# 	# ray.collide_with_areas = false
	# 	# ray.collision_mask # Collide with terrain only
	# 	var result = space_state.intersect_ray(ray)
	# 	if result.size() > 0 and result["position"].y > 0.00001:
	# 		return false
	# 	shell_sim.position = ray.to
	# 	t += 1.0
	# return true

class ShootOver:
	var can_shoot_over_terrain: bool
	var can_shoot_over_ship: bool

	func _init(_terrain: bool, _ship: bool):
		can_shoot_over_terrain = _terrain
		can_shoot_over_ship = _ship
		
static func sim_can_shoot_over_terrain_static(
	pos: Vector3,
	launch_vector: Vector3,
	flight_time: float,
	drag: float,
	ship: Ship
) -> ShootOver:
	var shell_sim_position: Vector3 = pos
	var space_state = Engine.get_main_loop().get_root().get_world_3d().direct_space_state
	var ray = PhysicsRayQueryParameters3D.new()
	ray.collide_with_bodies = true
	ray.collision_mask = 1 | (1 << 1) # Collide with terrain and armor parts
	var t = 0.5
	while t < flight_time + 0.5:
		ray.from = shell_sim_position
		ray.to = ProjectilePhysicsWithDrag.calculate_position_at_time(
			pos,
			launch_vector,
			t,
			drag,
		)
		var result = space_state.intersect_ray(ray)
		if not result.is_empty():
			if result.has("collider") and result["collider"] is ArmorPart:
				var armor_part: ArmorPart = result["collider"] as ArmorPart
				if armor_part.ship.team.team_id != ship.team.team_id:
					return ShootOver.new(true, true)
				elif armor_part.ship == ship:
					# Hitting own ship, ignore
					pass
				elif armor_part.ship.team.team_id == ship.team.team_id:
					return ShootOver.new(true, false)
					# return false # dont hit friendly ships
				# var armor_part: ArmorPart = result["collider"] as ArmorPart
				# if armor_part.ship.team.team_id != ship.team.team_id:
				# 	return true
				# elif armor_part.ship.team.team_id == ship.team.team_id:
				# 	return false # dont hit friendly ships
				# elif armor_part.ship == ship:
				# 	# Hitting own ship, ignore
				# 	pass
			elif result["position"].y > 0.00001: # Hit terrain
				return ShootOver.new(false, true)
		shell_sim_position = ray.to
		t += 0.5
	return ShootOver.new(true, true)
