class_name Gun
extends Node3D

@onready var barrel: Node3D = $Barrels
#@onready var ms: MultiplayerSynchronizer = $MultiplayerSynchronizer

# Mark synchronized properties with @export 
var reload: float = 0.0
	#set(value):
		#reload = value
		## Emit a changed signal if needed
		 #reload_changed.emit(value)

var muzzles: Array[Node3D] = []
var reload_time: float = 1
var gun_id: int

func _ready() -> void:
	# Configure synchronizer
	#var config = ms.replication_config
	
	# The "." prefix is important - it means "this node"
	#if not config.has_property(".:reload"):
		#config.add_property(".:reload")
	
	# Set server as authority
	#get_node("MultiplayerSynchronizer").set_multiplayer_authority(1)
	
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

# implement on server
func _aim(aim_point: Vector3, delta: float) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	
	# Cache constants
	const TURRET_ROT_SPEED_DEG: float = 40.0
	const BARREL_ELEVATION_SPEED_DEG: float = 40.0
	
	# Calculate average muzzle position more efficiently
	var muzzle_count: int = muzzles.size()
	var muzzle: Vector3 = Vector3.ZERO
	for m in muzzles:
		muzzle += m.global_position
	muzzle /= muzzle_count
	
	# Get direction vector for aiming
	var dir = Shell.calculate_launch_vector(muzzle, aim_point, Vector3.ZERO, Shell.shell_speed, Shell.gravity, Shell.drag_coefficient,Shell.mass)
	#var dir = aim_point - global_position
	#var dir: Vector3 = ProjectileManager.CalculateLaunchVector(muzzle, aim_point, Shell.shell_speed, -0.981)
	if dir.is_zero_approx():
		return
	
	dir = dir.normalized()
	
	# Calculate turret rotation
	var turret_rot_speed_rad: float = deg_to_rad(TURRET_ROT_SPEED_DEG)
	var max_turret_angle: float = turret_rot_speed_rad * delta
	var local_target: Vector3 = to_local(global_position + dir)
	var turret_angle: float = sign(local_target.x) * min(abs(local_target.x), max_turret_angle)
	rotate(Vector3.UP, turret_angle)
	
	# Calculate barrel elevation
	var barrel_speed_rad: float = deg_to_rad(BARREL_ELEVATION_SPEED_DEG)
	var max_barrel_angle: float = barrel_speed_rad * delta
	var barrel_local_target: Vector3 = barrel.to_local(barrel.global_position + dir)
	var barrel_angle: float = sign(-barrel_local_target.y) * min(abs(barrel_local_target.y), max_barrel_angle)
	barrel.rotate(Vector3.RIGHT, barrel_angle)
	barrel.rotation_degrees.x = clamp(barrel.rotation_degrees.x, -30, 10)

func fire():
	if multiplayer.is_server():
		if reload >= 1.0:
			for m in muzzles:
			#var id = multiplayer.get_unique_id()
				ProjectileManager.request_fire(m.global_basis.z, m.global_position)
			reload = 0
