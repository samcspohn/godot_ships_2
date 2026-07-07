extends Aircraft
class_name TorpedoAircraft

# var aim_point: Vector3
# var _ship: Ship
# var params: AircraftParams
@export var torpedo_params: TorpedoParams

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

func attack_behavior() -> bool:
	if attack_point == null:
		return false
	var prev_pos = global_position
	# var ret = _orbit_target(attack_point, circle_range, params.p().speed, get_physics_process_delta_time())
	var pos2d = Vector2(global_position.x, global_position.z)
	var disp = attack_point - pos2d
	var attack_3d = Vector3(attack_point.x, 30.0, attack_point.y) # drop torpedos at 30m altitude
	if disp.length_squared() < 100.0: # drop ordnance when within 300m of target
		# drop ordnance
		drop_ordnance()
		attack_point = null
		return true


	fly_toward(attack_3d, get_physics_process_delta_time())
	look_at(global_position + (global_position - prev_pos))
	return false
	# return

# # Called every frame. 'delta' is the elapsed time since the previous frame.
# func _physics_process(delta: float) -> void:
# 	if not _Utils.authority():
# 		return

# 	var prev_pos = global_position
# 	var disp = aim_point - _ship.global_position
# 	var center = aim_point
# 	if disp.length_squared() > params.p()._range * params.p()._range:
# 		disp = disp.normalized() * params.p()._range
# 		aim_point = _ship.global_position + disp
# 	center.y = 200.0

# 	# Plane's offset from the orbit center, flattened to the horizontal plane.
# 	var from_center = global_position - center
# 	from_center.y = 0.0

# 	# Current angular position around the center, advanced by this frame's step.
# 	var angle = atan2(from_center.z, from_center.x)
# 	angle += (params.p().speed * delta) / circle_range

# 	# Aim for the point on the circle just ahead of the plane. When the plane is
# 	# far away it flies inward toward this point and eases onto the orbit; once on
# 	# the circle it keeps tracking the moving target around it.
# 	var target = center + Vector3(cos(angle), 0.0, sin(angle)) * circle_range

# 	var to_target = target - global_position
# 	var distance = to_target.length()
# 	if distance > 0.001:
# 		var move_distance = min(params.p().speed * delta, distance)
# 		global_position += to_target.normalized() * move_distance

# 	var velocity = global_position - prev_pos
# 	if velocity.length_squared() > 0.0:
# 		look_at(global_position + velocity)

func drop_ordnance():
	if attack_point == null:
		return
	var p = params.p() as AircraftParams
	var torp_vel = Vector3(attack_direction.x, 0.0, attack_direction.y).normalized()
	var t = ProjectileManager.get_current_time()
	var t_id = TorpedoManager.fireTorpedo(torp_vel, global_position, torpedo_params, t, _ship, 1000.0)
	TorpedoManager.notify_fired(t_id, global_position, torp_vel, t, torpedo_params, _ship, false)
	# var ordnance = p.ordnance_scene.instantiate()
	# ordnance.global_position = global_position
	# ordnance.global_rotation = global_rotation
	# ordnance.velocity = -global_transform.basis.z * p.speed
	# ordnance.owner = owner
	# get_tree().current_scene.add_child(ordnance)
