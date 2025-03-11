class_name  Gun
extends Node3D

@onready var barrel: Node3D = get_child(1)
var muzzles: Array[Node3D] = []
var reload: float = 0
var reload_time: float = 4

func _ready() -> void:
	for b in barrel.get_children():
		muzzles.append(b.get_child(0))
	pass # Replace with function body.
	
func _physics_process(delta: float) -> void:
	if reload < 1.0:
		reload += delta / reload_time

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
	var dir: Vector3 = ProjectileManager.CalculateLaunchVector(muzzle, aim_point, Shell.shell_speed, -0.981)
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
	if reload >= 1.0:
		#if multiplayer.is_server():
		for m in muzzles:
			ProjectileManager.request_fire.rpc_id(1, m.global_basis.z, m.global_position + m.global_basis.z)
		reload = 0
