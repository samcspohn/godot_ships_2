extends Aircraft
class_name SpottingAircraft

# var aim_point: Vector3
# var _ship: Ship
# var params: AircraftParams
@export var circle_range: float = 2000.0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

func attack_behavior() -> Vector2:
	if attack_point == null:
		return Vector2.ZERO
	var ret = _orbit_target(attack_point, circle_range, params.p().speed, get_physics_process_delta_time())
	fly_toward(Vector3(ret.x, global_position.y, ret.y), get_physics_process_delta_time())
	look_at(global_position + (global_position - global_position))
	return ret

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

# func drop_ordnance(drop_point: Vector3, aim_direction: Vector2, plane_params: AircraftParams):
# 	# spotter has no ordnance. just set spotting position
# 	var disp = drop_point - _ship.global_position
# 	if disp.length_squared() > params.p()._range * params.p()._range:
# 		disp = disp.normalized() * params.p()._range
# 		drop_point = _ship.global_position + disp
# 	aim_point = drop_point

# 	# # spawn ordnance at drop point
# 	# var ordnance_scene = plane_params.ordnance_scene.instantiate() as PackedScene
# 	# if ordnance_scene:
# 	# 	var ordnance_instance = ordnance_scene.instantiate() as Node3D
# 	# 	get_tree().current_scene.add_child(ordnance_instance)
# 	# 	ordnance_instance.global_position = drop_point
# 	# 	if ordnance_instance.has_method("set_aim_direction"):
# 	# 		ordnance_instance.call("set_aim_direction", aim_direction)
