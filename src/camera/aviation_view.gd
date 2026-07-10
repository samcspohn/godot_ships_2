extends CameraView
class_name AviationView
# Aviation sniper view - fixed shallow-angle camera pulled back from a ground aim point.
# Used in place of AimView's sniper view when the active weapon is an AviationController.

var min_zoom_distance: float = 200.0
var max_zoom_distance: float = 10000.0
var zoom_rate: float = 10.0
var default_fov: float = 40.0

var min_ground_distance: float = 500.0

const aviation_angle_x: float = deg_to_rad(-20.0)

# rot_v/locked_rot_v are kept as genuine angles (same unit every other
# CameraView uses) so that battle_camera.gd's generic view-switching code
# (_lock_on_target/_unlock_target/_sync_sniper_view_for_weapon/free-look entry)
# can treat every view uniformly without special-casing aviation view.
#
# This view has no real pitch angle of its own though (the camera always
# looks down at a fixed -20 degree angle) - what it actually needs is a
# linear ground distance from the ship to the aim point. So that distance is
# mapped to/from an angle via an arbitrary but fixed and invertible bijection
# (_distance_to_angle/_angle_to_distance), purely so it can be stored in
# rot_v/locked_rot_v like every other view. Anywhere this view needs the
# actual distance (placing the aim point, scaling mouse sensitivity, ...) it
# converts back with _angle_to_distance().
const ANGLE_DISTANCE_SCALE: float = 1000.0 # reference distance (m) used only for the angle<->distance bijection

static func _distance_to_angle(dist: float) -> float:
	return -atan2(ANGLE_DISTANCE_SCALE, max(dist, 0.01))

static func _angle_to_distance(angle: float) -> float:
	var a = clamp(angle, -PI / 2 + 0.0001, -0.0001)
	return ANGLE_DISTANCE_SCALE / tan(-a)

func _ready():
	current_fov = default_fov
	current_zoom = 1000.0 # Distance from the aim point
	rot_v = _distance_to_angle(1000.0) # Initial ground distance from ship to aim point

func zoom_camera(delta):
	current_zoom += delta * zoom_rate
	current_zoom = clamp(current_zoom, min_zoom_distance, max_zoom_distance)

func handle_mouse_event(event):
	if event is InputEventMouseMotion:
		var curr_range = player_controller.current_weapon_controller.get_max_range()
		if locked_ship == null:
			var dist = _angle_to_distance(rot_v)
			rot_h -= event.relative.x * 0.0001 / (dist / curr_range)  # Scale horizontal rotation by distance to aim point
			# Vertical mouse motion moves the aim point closer to/farther from the
			# ship, treated as a linear ground distance rather than an angle.
			dist -= event.relative.y * 5.0
			dist = clamp(dist, min_ground_distance, curr_range)
			rot_v = _distance_to_angle(dist)
		else:
			var dist = _angle_to_distance(rot_v + locked_rot_v)
			locked_rot_h -= event.relative.x * 0.0001 / (dist / curr_range)
			dist -= event.relative.y * 5.0
			dist = clamp(dist, min_ground_distance, curr_range)
			locked_rot_v = _distance_to_angle(dist) - rot_v

func get_aim_point() -> Vector3:
	if follow_ship == null:
		return Vector3.ZERO
	var ship_position = follow_ship.global_position
	# rot_h follows the same atan2(dx,dz)+PI convention as every other view
	# (needed so free-look/lock-on code can copy rot_h across views
	# uninterpreted); undo the +PI here to get back the ship->aim_point heading.
	var heading = rot_h + locked_rot_h + PI
	var dist = _angle_to_distance(rot_v + locked_rot_v)
	var aim_point = ship_position + Vector3(sin(heading), 0.0, cos(heading)) * dist
	aim_point.y = 0.0
	return aim_point

func update_transform():
	if follow_ship == null:
		return

	var heading = rot_h + locked_rot_h + PI
	var aim_point = get_aim_point()

	# Camera sits current_zoom meters away from the aim point, along the fixed
	# -5 degree viewing angle.
	var direction = Vector3(sin(heading), sin(aviation_angle_x), cos(heading)).normalized()
	global_position = aim_point - direction * current_zoom

	look_at(aim_point, Vector3.UP)

func _calculate_rotation_for_aim(aim_pos: Vector3) -> Vector2:
	var ship_pos = follow_ship.global_position
	var dx = aim_pos.x - ship_pos.x
	var dz = aim_pos.z - ship_pos.z
	var result_rot_h = atan2(dx, dz) + PI
	var curr_range = player_controller.current_weapon_controller.get_max_range()
	var dist = clamp(Vector2(dx, dz).length(), min_ground_distance, curr_range)
	var result_rot_v = _distance_to_angle(dist)
	return Vector2(result_rot_h, result_rot_v)

func set_vh(aim_pos: Vector3):
	var result = _calculate_rotation_for_aim(aim_pos)
	rot_h = result.x
	rot_v = result.y

func set_locked_rot(locked_aim_pos: Vector3):
	var result = _calculate_rotation_for_aim(locked_aim_pos)
	locked_rot_h = CameraView.normalize_angle(result.x - rot_h)
	locked_rot_v = result.y - rot_v
