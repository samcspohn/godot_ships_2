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
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	
	# Cache constants
	const TURRET_ROT_SPEED_DEG: float = 40.0
	
	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(TURRET_ROT_SPEED_DEG)
	var max_turret_angle: float = turret_rot_speed_rad * delta
	var local_target: Vector3 = to_local(aim_point)

	# Calculate desired rotation angle in the horizontal plane
	var desired_angle: float = atan2(local_target.x, local_target.z)

	var result = rotation_degrees.y + rad_to_deg(desired_angle)
#
	if result > 180 and rotation_degrees.y <= 150 or result < -180 and rotation_degrees.y >= -150:
		desired_angle = -desired_angle
		
	#if gun_id == 0:
		#print("rotation", rotation_degrees.y)
		#print("angle", desired_angle)

	# Apply proportional control with a dampening factor
	var turret_angle: float = clamp(desired_angle, -max_turret_angle, max_turret_angle)

	# Apply rotation
	rotate(Vector3.UP, turret_angle)
	rotation_degrees.y = clamp(rotation_degrees.y, -150, 150)
	#$ArtilleryPlotter._elavate(aim_point, 40, delta)
	# var sol = AnalyticalProjectileSystem.calculate_launch_vector_gravity_only($ArtilleryPlotter.muzzle.global_position,aim_point,Shell.shell_speed)
	var sol = ProjectilePhysicsWithDrag.calculate_launch_vector($ArtilleryPlotter.muzzle.global_position,aim_point, Shell.shell_speed)
	var elevation_delta: float = max_turret_angle
	if sol[1] != -1:
		var barrel_dir = sol[0]
		var elevation = Vector2(sqrt(barrel_dir.x * barrel_dir.x + barrel_dir.z * barrel_dir.z), barrel_dir.y)
		var curr_elevation = Vector2(sqrt(barrel.global_basis.z.x * barrel.global_basis.z.x + barrel.global_basis.z.z * barrel.global_basis.z.z), barrel.global_basis.z.y)
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
		can_fire = true

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
