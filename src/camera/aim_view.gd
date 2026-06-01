extends CameraView
class_name AimView

# var rot_h = 0.0
# var rot_v = 0.0
# var locked_rot_h = 0.0
# var locked_rot_v = 0.0
# var ship = null
# var current_zoom = 1.0
# var current_fov = 40.0
var min_fov = 1.0
var max_fov = 10.0
var height = 60.0
# var player_controller: PlayerController
const angle = 0.022
func _ready():
	current_fov = max_fov
	current_zoom = current_fov

func zoom_camera(delta):
	current_zoom += delta * 0.03
	current_zoom = clamp(current_zoom, min_fov, max_fov)

	current_fov = current_zoom

static func calculate_0_intersection(pos: Vector3, h: float, v: float) -> Vector3:
	# Calculate direction vector from horizontal and vertical rotation
	# h = horizontal rotation (yaw), v = vertical rotation (pitch)
	var direction = Vector3(
		sin(h) * cos(v),
		-sin(v),
		cos(h) * cos(v)
	)

	# Plane equation: 0*x + 1*y + 0*z + 0 = 0, which is y = 0
	# Ray: P = pos + t * direction
	# Intersection: pos.y + t * direction.y = 0
	# Solve for t: t = -pos.y / direction.y

	# Check if ray is parallel to plane (direction.y == 0)
	if abs(direction.y) < 0.0001:
		return Vector3.INF  # No intersection, ray is parallel to plane

	var t = -pos.y / direction.y

	# If t < 0, intersection is behind the ray origin
	if t < 0:
		return Vector3.INF  # No forward intersection

	# Calculate intersection point
	var intersection = pos + direction * t
	return intersection

func _process(_delta):
	var curr_range = player_controller.current_weapon_controller.get_max_range()
	var theta = -asin(clamp(height / curr_range, 0.0, 1.0))
	if locked_ship == null:
		rot_v = clamp(rot_v, -PI / 2, theta)
	else:
		var min_offset = rot_v - PI / 2
		var max_offset = theta - rot_v
		locked_rot_v = clamp(locked_rot_v, min_offset, max_offset)

func handle_mouse_event(event):
	if event is InputEventMouseMotion:
		var curr_range = player_controller.current_weapon_controller.get_max_range()
		var theta = -asin(clamp(height / curr_range, 0.0, 1.0))
		if locked_ship == null:
			rot_h -= event.relative.x * 0.0002 * current_zoom / max_fov
			rot_v -= event.relative.y * 0.0025 * current_zoom / max_fov * -(rot_v)
			rot_v = clamp(rot_v, -PI / 2, theta)
		else:
			locked_rot_h -= event.relative.x * 0.0002 * current_zoom / max_fov
			locked_rot_v -= event.relative.y * 0.0025 * current_zoom / max_fov * -(rot_v + locked_rot_v)
			var min_offset = rot_v - PI / 2
			var max_offset = theta - rot_v
			locked_rot_v = clamp(locked_rot_v, min_offset, max_offset)

func update_transform():
	if follow_ship != null:
		var pos = follow_ship.global_position
		pos.y = height
		var intersection = calculate_0_intersection(pos, rot_h + locked_rot_h + PI, -(rot_v + locked_rot_v))
		if intersection != Vector3.INF:
			var ship_pos = follow_ship.global_position
			ship_pos.y = 0.0
			var dist = intersection.distance_to(ship_pos)
			var h = max(dist * angle, 40)
			global_position = follow_ship.global_position
			global_position.y = h

			look_at(intersection)
		else:
			global_position = follow_ship.global_position
			global_position.y = 100
			rotation.x = rot_v + locked_rot_v
			rotation.y = rot_h + locked_rot_h

# Returns Vector2(rot_h, rot_v) to aim at aim_pos, or null if geometry degenerate.
func _calculate_rotation_for_aim(aim_pos: Vector3) -> Variant:
	var ship_pos = follow_ship.global_position
	var dist_xz = Vector2(aim_pos.x - ship_pos.x, aim_pos.z - ship_pos.z).length()
	var elevated_height = aim_pos.y + dist_xz * tan(angle)
	var elevated_point = Vector3(ship_pos.x, elevated_height, ship_pos.z)
	var direction = aim_pos - elevated_point
	if abs(direction.y) < 0.0001:
		return null
	var t = -elevated_height / direction.y
	if t < 0:
		return null
	var intersection = elevated_point + direction * t
	var camera_pos = Vector3(ship_pos.x, height, ship_pos.z)
	var dist_to_intersection = Vector2(intersection.x - camera_pos.x, intersection.z - camera_pos.z).length()
	var result_rot_v = -atan(height / dist_to_intersection)
	var dx = aim_pos.x - ship_pos.x
	var dz = aim_pos.z - ship_pos.z
	var result_rot_h = atan2(dx, dz) + PI
	return Vector2(result_rot_h, result_rot_v)

func set_vh(aim_pos: Vector3):
	var result = _calculate_rotation_for_aim(aim_pos)
	if result == null:
		return
	rot_h = result.x
	rot_v = result.y

func set_locked_rot(locked_aim_pos: Vector3):
	var result = _calculate_rotation_for_aim(locked_aim_pos)
	if result == null:
		return
	locked_rot_h = CameraView.normalize_angle(result.x - rot_h)
	locked_rot_v = result.y - rot_v
