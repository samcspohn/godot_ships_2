class_name Gun
extends Node3D

@onready var barrel: Node3D = $Barrels
@onready var dispersion_calculator: ArtilleryDispersion = $"../../DispersionCalculator"
var _aim_point: Vector3
@export var shell: ShellParams
@export var shell2: Resource
#@onready var ms: MultiplayerSynchronizer = $MultiplayerSynchronizer

# Mark synchronized properties with @export
var reload: float = 0.0
var can_fire: bool = false
var muzzles: Array[Node3D] = []
@export var reload_time: float = 1
var gun_id: int

var max_range
func _ready() -> void:
	max_range = ProjectilePhysicsWithDrag.calculate_max_range_from_angle(30, shell.speed)
	# Set up muzzles
	for b in barrel.get_children():
		if b.name.contains("Barrel"):
			muzzles.append(b.get_child(0))
	
	# Set processing mode based on authority
	if multiplayer.is_server():
		process_mode = Node.PROCESS_MODE_INHERIT
	else:
		# We still need to receive updates, just not run physics
		process_mode = Node.PROCESS_MODE_INHERIT
		set_physics_process(false)

@rpc("any_peer", "call_remote")
func _set_reload(r):
	reload = r

func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		if reload < 1.0:
			reload += delta / reload_time
			_set_reload.rpc_id(int(str(get_parent().get_parent().name)), reload)
		
# implement on server
func _aim(aim_point: Vector3, delta: float) -> void:
	self._aim_point = aim_point
	#if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		#return
	
	# Cache constants
	const TURRET_ROT_SPEED_DEG: float = 40.0
	
	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(TURRET_ROT_SPEED_DEG)
	var max_turret_angle: float = turret_rot_speed_rad * delta
	var local_target: Vector3 = to_local(aim_point)

	# Calculate desired rotation angle in the horizontal plane
	var desired_angle: float = atan2(local_target.x, local_target.z)

	#var result = rotation_degrees.y + rad_to_deg(desired_angle)
##
	#if result > 180 and rotation_degrees.y <= 150 or result < -180 and rotation_degrees.y >= -150:
		#desired_angle = -desired_angle
		
	#if gun_id == 0:
		#print("rotation", rotation_degrees.y)
		#print("angle", desired_angle)

	# Apply proportional control with a dampening factor
	var turret_angle: float = clamp(desired_angle, -max_turret_angle, max_turret_angle)

	# Apply rotation
	rotate(Vector3.UP, turret_angle)
	#rotation_degrees.y = clamp(rotation_degrees.y, -150, 150)
	var sol = ProjectilePhysicsWithDrag.calculate_launch_vector(global_position,aim_point, shell.speed, shell.drag)
	var elevation_delta: float = max_turret_angle
	if sol[1] != -1:
		var barrel_dir = sol[0]
		var elevation = Vector2(Vector2(barrel_dir.x, barrel_dir.z).length(), barrel_dir.y)
		var curr_elevation = Vector2(Vector2(barrel.global_basis.z.x, barrel.global_basis.z.z).length(), barrel.global_basis.z.y)
		var elevation_angle = elevation.angle_to(curr_elevation)
		elevation_delta = clamp(elevation_angle, -max_turret_angle, max_turret_angle)
	if sol[2]:
		elevation_delta = -max_turret_angle
	
	if is_nan(elevation_delta):
		elevation_delta = 0.0
	barrel.rotate(Vector3.RIGHT, elevation_delta)
	
	# var offset: Vector2 = $ArtilleryPlotter.prev_offset
	# var elevation_delta = $ArtilleryPlotter.elevation_delta
	
	if elevation_delta < 0.01 && abs(turret_angle) < 0.01:
		can_fire = true
	else:
		can_fire = false

	# Ensure we stay within allowed elevation range
	barrel.rotation_degrees.x = clamp(barrel.rotation_degrees.x, -30, 10)

func _aim_leading(aim_point: Vector3, vel: Vector3, delta: float):
	var sol = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(barrel.global_position, aim_point, vel, shell.speed, shell.drag)
	if !sol[2]:
		self._aim_point = sol[3]
	var launch_angle = sol[0]
	const TURRET_ROT_SPEED_DEG: float = 40.0
	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(TURRET_ROT_SPEED_DEG)
	var max_turret_angle: float = turret_rot_speed_rad * delta
	#var local_target: Vector3 = to_local(launch_angle)

	# Calculate desired rotation angle in the horizontal plane
	var desired_angle: float = atan2(launch_angle.x, launch_angle.z)
	var turret_angle: float = global_rotation.y
	var turret_delta: float = desired_angle - global_rotation.y
	if turret_delta > PI:
		turret_delta -= 2 * PI
	elif turret_delta < -PI:
		turret_delta += 2 * PI

	#var result = rotation_degrees.y + rad_to_deg(desired_angle)
##
	#if result > 180 and rotation_degrees.y <= 150 or result < -180 and rotation_degrees.y >= -150:
		#desired_angle = -desired_angle
		
	#if gun_id == 0:
		#print("rotation", rotation_degrees.y)
		#print("angle", desired_angle)

	# Apply proportional control with a dampening factor
	turret_angle = clamp(turret_delta, -max_turret_angle, max_turret_angle)

	# Apply rotation
	rotate(Vector3.UP, turret_angle)
	#rotation_degrees.y = clamp(rotation_degrees.y, -150, 150)
	#$ArtilleryPlotter._elavate(aim_point, 40, delta)
	# var sol = AnalyticalProjectileSystem.calculate_launch_vector_gravity_only($ArtilleryPlotter.muzzle.global_position,aim_point,Shell.shell_speed)
	var elevation_delta: float = max_turret_angle

	var elevation = Vector2(Vector2(launch_angle.x, launch_angle.z).length(), launch_angle.y)
	var curr_elevation = Vector2(Vector2(barrel.global_basis.z.x, barrel.global_basis.z.z).length(), barrel.global_basis.z.y)
	var elevation_angle = elevation.angle_to(curr_elevation)
	elevation_delta = clamp(elevation_angle, -max_turret_angle, max_turret_angle)

	if is_nan(elevation_delta):
		elevation_delta = 0.0
	barrel.rotate(Vector3.RIGHT, elevation_delta)
	
	# var offset: Vector2 = $ArtilleryPlotter.prev_offset
	# var elevation_delta = $ArtilleryPlotter.elevation_delta
	
	if elevation_delta < 0.01 && abs(turret_angle) < 0.01:
		can_fire = true
	else:
		can_fire = false

	# Ensure we stay within allowed elevation range
	barrel.rotation_degrees.x = clamp(barrel.rotation_degrees.x, -30, 10)
	
	# Store current diff for next frame
	# prev_offset = prev_diff

func fire():
	if multiplayer.is_server():
		if reload >= 1.0 and can_fire:
			for m in muzzles:
				var dispersion_point = dispersion_calculator.calculate_dispersion_point(_aim_point, self.global_position)
				var aim = ProjectilePhysicsWithDrag.calculate_launch_vector(m.global_position, dispersion_point, shell.speed, shell.drag)
				ProjectileManager.request_fire(aim[0], m.global_position, shell2.resource_path)
			reload = 0
