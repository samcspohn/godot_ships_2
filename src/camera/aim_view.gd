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
var max_fov = 20.0
var height = 60.0
# var player_controller: PlayerController
#
func _ready():
	current_zoom = 20.0
	current_fov = 20.0

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
			rot_h -= event.relative.x * 0.001 * current_zoom / max_fov
			rot_v -= event.relative.y * 0.01 * current_zoom / max_fov * -(rot_v)
			rot_v = clamp(rot_v, -PI / 2, theta)
		else:
			locked_rot_h -= event.relative.x * 0.001 * current_zoom / max_fov
			locked_rot_v -= event.relative.y * 0.01 * current_zoom / max_fov * -(rot_v + locked_rot_v)
			var min_offset = rot_v - PI / 2
			var max_offset = theta - rot_v
			locked_rot_v = clamp(locked_rot_v, min_offset, max_offset)

func update_transform():
	if ship != null:
		var pos = ship.global_position
		pos.y = height
		var intersection = calculate_0_intersection(pos, rot_h + locked_rot_h + PI, -(rot_v + locked_rot_v))
		if intersection != Vector3.INF:
			var ship_pos = ship.global_position
			ship_pos.y = 0.0
			var dist = intersection.distance_to(ship_pos)
			var h = max(dist * 0.015, 40)
			global_position = ship.global_position
			global_position.y = h

			look_at(intersection)
		else:
			global_position = ship.global_position
			global_position.y = 100
			rotation.x = rot_v + locked_rot_v
			rotation.y = rot_h + locked_rot_h

func set_vh(aim_pos: Vector3):
	# Step 1: Find the height at (ship.x, h, ship.z) where a line at 0.015 radians
	# passes through aim_pos
	var angle = 0.015
	var ship_pos = ship.global_position

# Calculate horizontal distance from ship to aim_pos in XZ plane
	var dist_xz = Vector2(aim_pos.x - ship_pos.x, aim_pos.z - ship_pos.z).length()

	# Height where line at angle 0.015 from horizontal passes through aim_pos
	# tan(angle) = (h - aim_pos.y) / dist_xz
	# h = aim_pos.y + dist_xz * tan(angle)
	var elevated_height = aim_pos.y + dist_xz * tan(angle)
	var elevated_point = Vector3(ship_pos.x, elevated_height, ship_pos.z)

	# Step 2: Find ground intersection (y=0) for line from elevated_point through aim_pos
	# Line: P = elevated_point + t * (aim_pos - elevated_point)
	# For y = 0: elevated_height + t * (aim_pos.y - elevated_height) = 0
	# t = -elevated_height / (aim_pos.y - elevated_height)
	var direction = aim_pos - elevated_point
	if abs(direction.y) < 0.0001:
		return  # Line is parallel to ground, no intersection

	var t = -elevated_height / direction.y
	if t < 0:
		return  # Intersection is behind

	var intersection = elevated_point + direction * t

	# Step 3: Calculate rot_v as angle from (ship.x, height, ship.z) to intersection
	var camera_pos = Vector3(ship_pos.x, height, ship_pos.z)
	var dist_to_intersection = Vector2(intersection.x - camera_pos.x, intersection.z - camera_pos.z).length()

	# rot_v is negative (looking down) - angle from horizontal to intersection
	rot_v = -atan(height / dist_to_intersection)

	# Step 4: Calculate rot_h to align view horizontally with aim_pos
	# atan2 gives the angle from the positive Z axis towards the positive X axis
	var dx = aim_pos.x - ship_pos.x
	var dz = aim_pos.z - ship_pos.z
	rot_h = atan2(dx, dz) + PI
