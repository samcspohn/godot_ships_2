extends CameraView
class_name ThirdPersonViewV2

@export var height = 30.0
var distance = 100.0
# var current_zoom = 40.0
# var rot_h = 0.0  # Yaw (horizontal rotation around Y axis)
# var rot_v = 0.0  # Pitch (vertical rotation around X axis)
# var locked_rot_h = 0.0
# var locked_rot_v = 0.0
# var ship: Ship
# var player_controller: PlayerController
# var current_fov = 40.0

func _ready():
	current_zoom = 2.0
	current_fov = 40.0

func zoom_camera(delta):
	current_zoom += delta * 0.02
	current_zoom = clamp(current_zoom, 1, 10.0)


func handle_mouse_event(event):
	if event is InputEventMouseMotion:
		if locked_ship == null:
			rot_h -= event.relative.x * 0.001
			rot_v -= event.relative.y * 0.001
		else:
			locked_rot_h -= event.relative.x * 0.001
			locked_rot_v -= event.relative.y * 0.001
		rot_v = clamp(rot_v, -PI / 2 + 0.01, PI / 2 - 0.01)


# Standard spherical coordinate forward direction (Y-up convention)
# rot_h = yaw (0 = looking down +Z axis, positive = clockwise from above)
# rot_v = pitch (0 = horizontal, positive = looking up)
func get_forward_direction() -> Vector3:
	return Vector3(
		sin(rot_h + locked_rot_h) * cos(rot_v + locked_rot_v),
		-sin(rot_v + locked_rot_v),
		cos(rot_h + locked_rot_h) * cos(rot_v + locked_rot_v)
	).normalized()


# Right direction (perpendicular to forward on XZ plane)
func get_right_direction() -> Vector3:
	return Vector3(
		cos(rot_h + locked_rot_h),
		0.0,
		-sin(rot_h + locked_rot_h)
	).normalized()


# Up direction (perpendicular to both forward and right)
func get_up_direction() -> Vector3:
	return Vector3(
		-sin(rot_h + locked_rot_h) * sin(rot_v + locked_rot_v),
		cos(rot_v + locked_rot_v),
		-cos(rot_h + locked_rot_h) * sin(rot_v + locked_rot_v)
	).normalized()


func update_transform():
	height = 10
	distance = 100
	if ship != null:
		# var from_pos = ship.global_position
		# from_pos.y = 60

		global_position = calculate_position()
		# var intersection_point = from_pos + Vector3(sin(rot_h), sin(rot_v), cos(rot_h)).normalized() * player_controller.current_weapon_controller.get_max_range()
		rotation.y = rot_h + locked_rot_h
		rotation.x = rot_v + locked_rot_v

		# look_at(intersection_point)


func calculate_position() -> Vector3:
	var ship_dir = ship.global_basis.z.normalized()
	var angle_diff = ship.global_rotation.y - rot_h
	var cos_val = cos(angle_diff)

	# Smooth factor for camera offset based on angle difference
	# var smooth_factor = sign(cos_val) * pow(abs(cos_val), 0.5)
	var t = (cos_val + 1) / 2
	t = smoothstep(0.01, 0.99, t)
	var smooth_factor = t * 2.0 - 1

	var linear_offset = ship_dir * smooth_factor * 35.0

	# Use standard basis vectors
	var forward = -get_forward_direction()
	var up = get_up_direction()

	# Camera is positioned behind and above the ship
	# -forward moves camera behind where it's looking
	var pos = ship.global_position + linear_offset - forward * distance * current_zoom + up * height * current_zoom + Vector3(0, 25.0, 0)
	pos.y = max(pos.y, 1)
	return pos


# Helper that wraps calculate_position for use with the iterative solver.
# The solver needs a callable that takes (rot_h, rot_v) and returns camera position.
func _calculate_position_for_rotation(h: float, v: float) -> Vector3:
	# Temporarily set rotation values to calculate position
	var old_rot_h = rot_h
	var old_rot_v = rot_v
	rot_h = h
	rot_v = v
	var pos = calculate_position()
	rot_h = old_rot_h
	rot_v = old_rot_v
	return pos


func set_vh(aim_pos: Vector3):
	# Set rot_h and rot_v so the camera looks directly at aim_pos
	var result = CameraView.solve_rotation_iterative(
		aim_pos,
		ship.global_position,
		_calculate_position_for_rotation
	)
	rot_h = result.x
	rot_v = result.y


func set_locked_rot(locked_aim_pos: Vector3):
	# Calculate the locked_rot_h and locked_rot_v offsets needed to look at locked_aim_pos
	# given the current rot_h and rot_v values.
	var original_rot_h = rot_h
	var original_rot_v = rot_v

	var result = CameraView.solve_rotation_iterative(
		locked_aim_pos,
		ship.global_position,
		_calculate_position_for_rotation
	)

	# Calculate locked rotation as offset from original rotation
	locked_rot_h = CameraView.normalize_angle(result.x - original_rot_h)
	locked_rot_v = result.y - original_rot_v
