extends CameraView
class_name AviationView
# Aviation sniper view - fixed shallow-angle camera pulled back from a ground aim point.
# Used in place of AimView's sniper view when the active weapon is an AviationController.

var min_zoom_distance: float = 200.0
var max_zoom_distance: float = 10000.0
var zoom_rate: float = 10.0
var default_fov: float = 40.0

var min_ground_distance: float = 500.0
var camera_offset_vertical: float = 1000.0 # Linear ground distance from ship to aim point

const aviation_angle_x: float = deg_to_rad(-10.0)

func _ready():
	current_fov = default_fov
	current_zoom = 1000.0 # Distance from the aim point

func zoom_camera(delta):
	current_zoom += delta * zoom_rate
	current_zoom = clamp(current_zoom, min_zoom_distance, max_zoom_distance)

func handle_mouse_event(event):
	if event is InputEventMouseMotion:
		var curr_range = player_controller.current_weapon_controller.get_max_range()
		if locked_ship == null:
			rot_h -= event.relative.x * 0.0001 / (camera_offset_vertical / curr_range)  # Scale horizontal rotation by distance to aim point
			# Vertical mouse motion moves the aim point closer to/farther from the
			# ship, treated as a linear ground distance rather than an angle.
			camera_offset_vertical -= event.relative.y * 0.5 * camera_offset_vertical * 0.001
			camera_offset_vertical = clamp(camera_offset_vertical, min_ground_distance, curr_range)
		else:
			locked_rot_h -= event.relative.x * 0.0001 / (camera_offset_vertical / curr_range)
			camera_offset_vertical -= event.relative.y * 0.5 * camera_offset_vertical * 0.001
			camera_offset_vertical = clamp(camera_offset_vertical, min_ground_distance, curr_range)

func update_transform():
	if follow_ship == null:
		return

	var ship_position = follow_ship.global_position
	var heading = rot_h + locked_rot_h

	var aim_point = ship_position + Vector3(sin(heading), 0.0, cos(heading)) * camera_offset_vertical
	aim_point.y = 0.0

	# Camera sits current_zoom meters away from the aim point, along the fixed
	# -5 degree viewing angle.
	var direction = Vector3(sin(heading), sin(aviation_angle_x), cos(heading)).normalized()
	global_position = aim_point - direction * current_zoom

	look_at(aim_point, Vector3.UP)

func _calculate_rotation_for_aim(aim_pos: Vector3) -> Vector2:
	var ship_pos = follow_ship.global_position
	var dx = aim_pos.x - ship_pos.x
	var dz = aim_pos.z - ship_pos.z
	var result_rot_h = atan2(dx, dz)
	var result_distance = Vector2(dx, dz).length()
	return Vector2(result_rot_h, result_distance)

func set_vh(aim_pos: Vector3):
	var result = _calculate_rotation_for_aim(aim_pos)
	rot_h = result.x
	var curr_range = player_controller.current_weapon_controller.get_max_range()
	camera_offset_vertical = clamp(result.y, min_ground_distance, curr_range)

func set_locked_rot(locked_aim_pos: Vector3):
	var result = _calculate_rotation_for_aim(locked_aim_pos)
	locked_rot_h = CameraView.normalize_angle(result.x - rot_h)
