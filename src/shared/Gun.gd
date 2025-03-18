class_name Gun
extends Node3D

@onready var barrel: Node3D = $Barrels
#@onready var ms: MultiplayerSynchronizer = $MultiplayerSynchronizer

# Mark synchronized properties with @export 
var reload: float = 0.0
var can_fire: bool = false
var muzzles: Array[Node3D] = []
var reload_time: float = 1
var gun_id: int
var prev_offset: Vector2

func calculate_max_range() -> float:
	# Get the shell's initial speed
	var initial_speed = Shell.shell_speed
	var gravity = Shell.gravity
	var drag_factor = Shell.drag_factor
	var mass = Shell.mass
	
	# For maximum range in a vacuum (no drag), we use the 45-degree angle formula
	var theoretical_vacuum_range = (initial_speed * initial_speed) / gravity
	
	# But with drag, we need to simulate the trajectory
	
	# Start with the optimal launch angle (usually around 45° without drag,
	# but lower with drag - typically 30-40° depending on drag amount)
	var optimal_angles = [deg_to_rad(30)]
	var max_range = 0.0
	
	for test_angle in optimal_angles:
		# Initialize simulation variables
		var sim_pos = Vector2(0, 0)
		var sim_vel = Vector2(cos(test_angle), sin(test_angle)) * initial_speed
		var shell_drag = drag_factor / mass
		var time_step = 0.05
		var max_sim_time = 120.0  # Maximum simulation time in seconds
		var sim_time = 0.0
		var highest_range = 0.0
		
		# Simulate until shell hits ground or max time reached
		while sim_pos.y >= 0 && sim_time < max_sim_time:
			var speed = sim_vel.length()
			var drag_force = sim_vel.normalized() * shell_drag * speed * speed
			
			sim_vel -= drag_force * time_step
			sim_vel.y -= gravity * time_step
			
			sim_pos += sim_vel * time_step
			sim_time += time_step
			
			# Update highest range if shell is still flying
			if sim_pos.y >= 0 && sim_pos.x > highest_range:
				highest_range = sim_pos.x
		
		# Keep track of the best range across different angles
		if highest_range > max_range:
			max_range = highest_range
	
	return max_range
	
var max_range
func _ready() -> void:
	# Configure synchronizer
	#var config = ms.replication_config
	
	# The "." prefix is important - it means "this node"
	#if not config.has_property(".:reload"):
		#config.add_property(".:reload")
	
	# Set server as authority
	#get_node("MultiplayerSynchronizer").set_multiplayer_authority(1)
	max_range = calculate_max_range()
	# Set up muzzles
	for b in barrel.get_children():
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


func _elavation(aim_point: Vector3, delta: float) -> float:
	
	# Cache constants
	const BARREL_ELEVATION_SPEED_DEG: float = 40.0
	
	# Calculate average muzzle position more efficiently
	var muzzle_count: int = muzzles.size()
	var muzzle: Vector3 = Vector3.ZERO
	for m in muzzles:
		muzzle += m.global_position
	muzzle /= muzzle_count
	var ap1 = aim_point - muzzle
	var ap: Vector2 = Vector2(sqrt(ap1.x * ap1.x + ap1.z * ap1.z), ap1.y)
	if ap.x > max_range:
		ap = Vector2(max_range, 0)
	
	var dir = self.barrel.global_basis.z
	var sim_shell = Vector2(0,0)
	var sim_time = 0.0
	var sim_vel = Vector2(sqrt(dir.x * dir.x + dir.z * dir.z), dir.y) * Shell.shell_speed
	var diff = ap
	var prev_diff = diff
	var shell_drag = Shell.drag_factor / Shell.mass
	
	var time_step2 = ap.length() / Shell.shell_speed * 0.7 / 2
	var min_time_step2 = time_step2 / 5
	var time_step = time_step2 / 15
	var min_time_step = 1.0 / 30
	var speed: float
	var drag_force: Vector2
	var sim_vel2: Vector2
	
	while true:
		speed = sim_vel.length()
		drag_force = sim_vel.normalized() * shell_drag * speed * speed
		
		sim_vel2 = sim_vel - drag_force * time_step
		sim_vel2.y -= Shell.gravity * time_step
		var sim_shell2 = sim_shell + sim_vel2 * time_step
		if sim_shell2.x > ap.x or sim_shell2.y < 0:
			break
		
		sim_vel = sim_vel2
		sim_shell = sim_shell2
		sim_time += time_step2
		if time_step2 > min_time_step2:
			time_step2 /= 2
		
	diff = ap - sim_shell
	prev_diff = diff
	
	while diff.length_squared() <= prev_diff.length_squared():
		speed = sim_vel.length()
		drag_force = sim_vel.normalized() * shell_drag * speed * speed
		sim_vel -= drag_force * time_step
		sim_vel.y -= Shell.gravity * time_step
		sim_shell += sim_vel * time_step
		sim_time += time_step
		if time_step > min_time_step:
			time_step /= 2
		prev_diff = diff
		diff = ap - sim_shell
		
		if sim_time > 120:
			break
		
	
	# Calculate barrel elevation - IMPROVED SECTION
	var barrel_speed_rad: float = deg_to_rad(BARREL_ELEVATION_SPEED_DEG)
	var max_barrel_angle: float = barrel_speed_rad * delta

	# Use a weighted combination of x and y error components with proportional control
	#var adjustment_factor: float = 0.5 # Adjustment sensitivity factor
	var adjustment_factor: float = prev_diff.length() / ap.length()
	var error_y_weight: float = 0.7 # Weight for vertical error (higher priority)
	var error_x_weight: float = 0.3 # Weight for horizontal error

	# Calculate weighted error
	var weighted_error: float = (-prev_diff.y * error_y_weight) + (-prev_diff.x * error_x_weight)


	# Calculate vectors from the aim point to both error positions
	var vector_to_prev_offset = prev_offset - ap
	var vector_to_prev_diff = prev_diff - ap

	# Check if they're pointing in opposite directions using dot product
	var dot_product = vector_to_prev_offset.dot(vector_to_prev_diff)

	var desired_angle: float
	# If dot product is negative, vectors are pointing in opposite directions
	var is_oscillating = dot_product < 0
	if is_oscillating:
		desired_angle = clamp(weighted_error * adjustment_factor, -max_barrel_angle, max_barrel_angle) * vector_to_prev_diff.length() / prev_offset.length()
	else:
		desired_angle = clamp(weighted_error * adjustment_factor, -max_barrel_angle, max_barrel_angle)
	prev_offset = prev_diff
	
	return desired_angle
		
# implement on server
func _aim(aim_point: Vector3, elavation:float, delta: float) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	
	# Cache constants
	const TURRET_ROT_SPEED_DEG: float = 40.0
	# const BARREL_ELEVATION_SPEED_DEG: float = 40.0
	# const BARREL_DEADZONE: float = 0.01  # Deadzone to prevent micro-adjustments
	
	# Calculate average muzzle position more efficiently
	# var muzzle_count: int = muzzles.size()
	# var muzzle: Vector3 = Vector3.ZERO
	# for m in muzzles:
	# 	muzzle += m.global_position
	# muzzle /= muzzle_count
	# var ap1 = aim_point - muzzle
	# var ap: Vector2 = Vector2(sqrt(ap1.x * ap1.x + ap1.z * ap1.z), ap1.y)
	# if ap.x > max_range:
	# 	ap = Vector2(max_range, 0)
	
	# var dir = self.barrel.global_basis.z
	# var sim_shell = Vector2(0,0)
	# var sim_time = 0.0
	# var sim_vel = Vector2(sqrt(dir.x * dir.x + dir.z * dir.z), dir.y) * Shell.shell_speed
	# var diff = ap
	# var prev_diff = diff
	# var shell_drag = Shell.drag_factor / Shell.mass
	# var time_step = 1.0 / 15
	
	# var time_step2 = ap.length() / Shell.shell_speed * 0.7 / 2
	# var min_time_step2 = time_step2 / 5
	# var speed: float
	# var drag_force: Vector2
	# var sim_vel2: Vector2
	
	# while true:
	# 	speed = sim_vel.length()
	# 	drag_force = sim_vel.normalized() * shell_drag * speed * speed
		
	# 	sim_vel2 = sim_vel - drag_force * time_step
	# 	sim_vel2.y -= Shell.gravity * time_step
	# 	var sim_shell2 = sim_shell + sim_vel2 * time_step
	# 	if sim_shell2.x > ap.x or sim_shell2.y < 0:
	# 		break
		
	# 	sim_vel = sim_vel2
	# 	sim_shell = sim_shell2
	# 	sim_time += time_step2
	# 	if time_step2 > min_time_step2:
	# 		time_step2 /= 2
		
	# diff = ap - sim_shell
	# prev_diff = diff
	
	# while diff.length_squared() <= prev_diff.length_squared():
	# 	speed = sim_vel.length()
	# 	drag_force = sim_vel.normalized() * shell_drag * speed * speed
	# 	sim_vel -= drag_force * time_step
	# 	sim_vel.y -= Shell.gravity * time_step
	# 	sim_shell += sim_vel * time_step
	# 	sim_time += time_step
	# 	prev_diff = diff
	# 	diff = ap - sim_shell
		
	# 	if sim_time > 120:
	# 		break
		
	# Set can_fire based on precision threshold
	#if diff.length_squared() < 0.1:
		#can_fire = true
	#else:
		#can_fire = false
	
	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(TURRET_ROT_SPEED_DEG)
	var max_turret_angle: float = turret_rot_speed_rad * delta
	var local_target: Vector3 = to_local(aim_point)

	# Calculate desired rotation angle in the horizontal plane
	var desired_angle: float = atan2(local_target.x, local_target.z)

	# Apply proportional control with a dampening factor
	var rotation_dampening: float = 0.7  # Adjust this value to control responsiveness
	var turret_angle: float = clamp(desired_angle * rotation_dampening, -max_turret_angle, max_turret_angle)

	# Apply rotation
	rotate(Vector3.UP, turret_angle)
	
	# Calculate barrel elevation - IMPROVED SECTION
	# var barrel_speed_rad: float = deg_to_rad(BARREL_ELEVATION_SPEED_DEG)
	# var max_barrel_angle: float = barrel_speed_rad * delta

	# # Use a weighted combination of x and y error components with proportional control
	# #var adjustment_factor: float = 0.5 # Adjustment sensitivity factor
	# var adjustment_factor: float = prev_diff.length() / ap.length()
	# var error_y_weight: float = 0.7 # Weight for vertical error (higher priority)
	# var error_x_weight: float = 0.3 # Weight for horizontal error

	# # Calculate weighted error
	# var weighted_error: float = (-prev_diff.y * error_y_weight) + (-prev_diff.x * error_x_weight)


	# # Calculate vectors from the aim point to both error positions
	# var vector_to_prev_offset = prev_offset - ap
	# var vector_to_prev_diff = prev_diff - ap

	# # Check if they're pointing in opposite directions using dot product
	# var dot_product = vector_to_prev_offset.dot(vector_to_prev_diff)

	# # If dot product is negative, vectors are pointing in opposite directions
	# var is_oscillating = dot_product < 0
	# if is_oscillating:
	# 	desired_angle = clamp(weighted_error * adjustment_factor, -max_barrel_angle, max_barrel_angle) * vector_to_prev_diff.length() / prev_offset.length()
	# else:
	# 	desired_angle = clamp(weighted_error * adjustment_factor, -max_barrel_angle, max_barrel_angle)
	barrel.rotate(Vector3.RIGHT, elavation)
	
	if elavation < 0.01 && abs(turret_angle) < 0.01:
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
			#var id = multiplayer.get_unique_id()
				ProjectileManager.request_fire(m.global_basis.z, m.global_position)
			reload = 0
