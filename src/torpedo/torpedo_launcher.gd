class_name TorpedoLauncher
extends Node3D

# Properties for editor
@export var rotation_limits_enabled: bool = true
@export var min_rotation_angle: float = deg_to_rad(45)
@export var max_rotation_angle: float = deg_to_rad(180 + 45)

var _aim_point: Vector3
var reload: float = 0.0
var can_fire: bool = false
var muzzles: Array[Node3D] = []
var gun_id: int
var disabled: bool = true

var max_range: float
var max_flight: float

@export var params: TorpedoLauncherParams
var my_params: TorpedoLauncherParams = TorpedoLauncherParams.new()

func _ready() -> void:
	my_params.from_params(params)
	max_range = my_params.range
	#var a = ProjectilePhysicsWithDrag.calculate_absolute_max_range(my_params.shell.speed, my_params.shell.drag)
	#max_range = min(a[0], my_params.range)
	#max_flight = a[2]

	#if max_range < a[0]:
		#max_flight = ProjectilePhysicsWithDrag.calculate_launch_vector(Vector3.ZERO, Vector3(0, 0, max_range), my_params.shell.speed, my_params.shell.drag)[1]
		#
#
	#print("max range: ", a)
	
	# Set up muzzles
	update_barrels()
	
	# Set processing mode based on authority
	if multiplayer.is_server():
		process_mode = Node.PROCESS_MODE_INHERIT
	else:
		# We still need to receive updates, just not run physics
		process_mode = Node.PROCESS_MODE_INHERIT
		set_physics_process(false)

	#min_rotation_angle = deg_to_rad(90 - 60)
	#max_rotation_angle = deg_to_rad(270 + 60)

# Function to update barrels based on editor properties
func update_barrels() -> void:
	# Clear existing muzzles array
	muzzles.clear()
	
	# Set up muzzles from existing barrels
	for t in get_children():
		if t.name.contains("Tube"):
				muzzles.append(t)

@rpc("any_peer", "call_remote")
func _set_reload(r):
	reload = r

func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		if !disabled && reload < 1.0:
			reload += delta / params.reload_time
			_set_reload.rpc_id(int(str(get_parent().get_parent().name)), reload)


# Normalize angle to the range [0, 2π]
func normalize_angle_0_2pi(angle: float) -> float:
	while angle < 0:
		angle += TAU
	
	while angle >= TAU:
		angle -= TAU
	
	return angle

# Apply rotation limits to a desired rotation
func apply_rotation_limits(current_angle: float, desired_delta: float) -> float:
	# If rotation limits are not enabled, return the desired delta as is
	if not rotation_limits_enabled or desired_delta == 0:
		return desired_delta
	
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
			if desired_delta > 0:  # Clockwise rotation
				crosses_invalid = normalized_current <= max_rotation_angle + 0.01 and normalized_current + desired_delta > max_rotation_angle + invalid_region
			else:  # Counter-clockwise rotation
				crosses_invalid = normalized_current >= min_rotation_angle - 0.01 and normalized_current + desired_delta < min_rotation_angle - invalid_region
		else:
			# The invalid region is (max, min)
			var invalid_region = min_rotation_angle - max_rotation_angle
			if desired_delta > 0:  # Clockwise rotation
				crosses_invalid = normalized_current <= max_rotation_angle + 0.01 and normalized_current + desired_delta > min_rotation_angle
			else:  # Counter-clockwise rotation
				crosses_invalid = normalized_current >= min_rotation_angle - 0.01 and normalized_current + desired_delta < max_rotation_angle
				
		if crosses_invalid:
			# If we would cross the invalid region, go the other way (inverse of desired delta)
			var a = -sign(desired_delta) * (TAU - abs(desired_delta))
			return a
		else:
			# No invalid region crossed, return the desired delta unchanged
			return desired_delta
	else:
		# Target is in the invalid region, find the nearest valid boundary
		var dist_to_min = min(abs(target_angle - min_rotation_angle), TAU - abs(target_angle - min_rotation_angle))
		var dist_to_max = min(abs(target_angle - max_rotation_angle), TAU - abs(target_angle - max_rotation_angle))
		
		if min_rotation_angle <= max_rotation_angle:
			if dist_to_min <= dist_to_max:
				# Min angle is closer, go to min angle
				return min_rotation_angle - normalized_current
			else:
				# Max angle is closer, go to max angle
				return max_rotation_angle - normalized_current
		else:
			if dist_to_min <= dist_to_max:
				# Min angle is closer, go to min angle
				return -normalize_angle_0_2pi(TAU - (min_rotation_angle - normalized_current))
			else:
				# Max angle is closer, go to max angle
				return normalize_angle_0_2pi(TAU - (max_rotation_angle - normalized_current))
				
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

# Implement on server
func _aim(aim_point: Vector3, delta: float) -> void:
	if disabled:
		return
	# Cache constants
	# const TURRET_ROT_SPEED_DEG: float = 40.0
	
	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(my_params.traverse_speed)
	var max_turret_angle: float = turret_rot_speed_rad * delta
	var local_target: Vector3 = to_local(aim_point)

	# Calculate desired rotation angle in the horizontal plane
	var desired_local_angle: float = atan2(local_target.x, local_target.z)
	
	# Apply rotation limits
	var adjusted_angle = apply_rotation_limits(rotation.y, desired_local_angle)
	var turret_angle: float = clamp(adjusted_angle, -max_turret_angle, max_turret_angle)

	# Apply rotation
	rotate(Vector3.UP, turret_angle)
	
	# Ensure rotation is within limits
	clamp_to_rotation_limits()
	
	## Existing aiming logic for elevation
	#var sol = ProjectilePhysicsWithDrag.calculate_launch_vector(global_position, aim_point, my_params.shell.speed, my_params.shell.drag)
	#if sol[0] != null and (aim_point - global_position).length() < max_range:
		#self._aim_point = aim_point
	#else:
		#var g = Vector3(global_position.x, 0, global_position.z)
		#self._aim_point = g + (Vector3(aim_point.x, 0, aim_point.z) - g).normalized() * (max_range - 500)
		#sol = ProjectilePhysicsWithDrag.calculate_launch_vector(global_position, self._aim_point, my_params.shell.speed, my_params.shell.drag)
	#
	#var turret_elev_speed_rad: float = deg_to_rad(my_params.elevation_speed)
	#var max_elev_angle: float = turret_elev_speed_rad * delta
	#var elevation_delta: float = max_elev_angle
	#if sol[1] != -1:
		#var barrel_dir = sol[0]
		#var elevation = Vector2(Vector2(barrel_dir.x, barrel_dir.z).length(), barrel_dir.y)
		#var curr_elevation = Vector2(Vector2(barrel.global_basis.z.x, barrel.global_basis.z.z).length(), barrel.global_basis.z.y)
		#var elevation_angle = elevation.angle_to(curr_elevation)
		#elevation_delta = clamp(elevation_angle, -max_elev_angle, max_elev_angle)
	#if sol[0] == null:
		#elevation_delta = -max_elev_angle
	#
	#if is_nan(elevation_delta):
		#elevation_delta = 0.0
	#barrel.rotate(Vector3.RIGHT, elevation_delta)
	
	if abs(desired_local_angle) < 0.01:
		can_fire = true
	else:
		can_fire = false

	# # Ensure we stay within allowed elevation range
	# barrel.rotation_degrees.x = clamp(barrel.rotation_degrees.x, -30, 10)

# Normalize angle to the range [-PI, PI]
func normalize_angle(angle: float) -> float:
	return wrapf(angle, -PI, PI)

#func _aim_leading(aim_point: Vector3, vel: Vector3, delta: float):
	#var sol = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(barrel.global_position, aim_point, vel, params.shell.speed, params.shell.drag)
	#if sol[0] == null or (aim_point - barrel.global_position).length() > max_range:
		#can_fire = false
		#return
	#_aim_point = sol[2]
	#var launch_angle = sol[0]
	## Calculate turret rotation
	#var turret_rot_speed_rad: float = deg_to_rad(my_params.traverse_speed)
	#var max_turret_angle: float = turret_rot_speed_rad * delta
	#
	#var local_target: Vector3 = to_local(aim_point)
#
	## Calculate desired rotation angle in the horizontal plane
	#var desired_local_angle: float = atan2(local_target.x, local_target.z)
	#
	## Apply rotation limits
	#var adjusted_angle = apply_rotation_limits(rotation.y, desired_local_angle)
	#
	## Apply proportional control with a dampening factor
	#var turret_angle: float = clamp(adjusted_angle, -max_turret_angle, max_turret_angle)
#
	## Apply rotation
	#rotate(Vector3.UP, turret_angle)
	#
	## Ensure rotation is within limits
	#clamp_to_rotation_limits()
	#
	#var turret_elev_speed_rad: float = deg_to_rad(my_params.elevation_speed)
	#var max_elev_angle: float = turret_elev_speed_rad * delta
	#var elevation_delta: float = max_elev_angle
#
	#var elevation = Vector2(Vector2(launch_angle.x, launch_angle.z).length(), launch_angle.y)
	#var curr_elevation = Vector2(Vector2(barrel.global_basis.z.x, barrel.global_basis.z.z).length(), barrel.global_basis.z.y)
	#var elevation_angle = elevation.angle_to(curr_elevation)
	#elevation_delta = clamp(elevation_angle, -max_elev_angle, max_elev_angle)
#
	#if is_nan(elevation_delta):
		#elevation_delta = 0.0
	#barrel.rotate(Vector3.RIGHT, elevation_delta)
	#
	#if abs(elevation_delta) < 0.01 && abs(desired_local_angle) < 0.01:
		#can_fire = true
	#else:
		#can_fire = false
#
	## # Ensure we stay within allowed elevation range
	## barrel.rotation_degrees.x = clamp(barrel.rotation_degrees.x, -30, 10)

@rpc("any_peer", "call_remote")
func fire() -> void:
	if multiplayer.is_server():
		if !disabled and reload >= 1.0 and can_fire:
			# Fire torpedo
			reload = 0.0
			can_fire = false
			var offset:Vector3 = -muzzles[0].global_basis.x * 0.1
			for m in muzzles:
				#var dispersion_point = dispersion_calculator.calculate_dispersion_point(_aim_point, self.global_position)
				#var aim = ProjectilePhysicsWithDrag.calculate_launch_vector(m.global_position, dispersion_point, my_params.shell.speed, my_params.shell.drag)
				#if aim[0] != null:
				var t = float(Time.get_unix_time_from_system())
				var id = (TorpedoManager as _TorpedoManager).fireTorpedo(m.global_basis.z + offset,m.global_position, params.torpedo_params, t)
				#var id = ProjectileManager1.fireBullet(aim[0], m.global_position, my_params.shell, dispersion_point, aim[1], t)
				for p in multiplayer.get_peers():
					self.fire_client.rpc_id(p, m.global_position, m.global_basis.z + offset, t, id)
				offset += muzzles[0].global_basis.x * 0.05
					#self.fire_client.rpc_id(p, aim[0],m.global_position, t, aim[1], dispersion_point, id)
			reload = 0

@rpc("any_peer","reliable")
func fire_client(pos, vel, t, id):
	(TorpedoManager as _TorpedoManager).fireTorpedoClient(pos, vel, t, id, params.torpedo_params)
