extends CameraView
class_name AerialView


# var rot_h = 0.0
# var rot_v = 0.0
# var locked_rot_h = 0.0
# var locked_rot_v = 0.0
# var ship = null
# var current_zoom = 1.0
# var current_fov = 40.0
var min_fov = 1.0
var max_fov = 40.0
var height = 60.0
var zoom_mod = 1.0
# var player_controller: PlayerController
#
func _ready():
	current_zoom = 40.0
	current_fov = 40.0

func zoom_camera(delta):
	current_zoom += delta * 0.03 / zoom_mod
	current_zoom = clamp(current_zoom, min_fov, max_fov)

	current_fov = current_zoom * zoom_mod

static func calculate_0_intersection(pos: Vector3, h: float, v: float) -> Vector3:
	# Calculate direction vector from horizontal and vertical rotation
	# h = horizontal rotation (yaw), v = vertical rotation (pitch)
	# Using standard convention matching CameraView.solve_rotation_iterative:
	#   rot_h = atan2(dir.x, dir.z)
	#   rot_v = -atan2(dir.y, dist_xz)
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

const ANGLE = deg_to_rad(6)
func handle_mouse_event(event):
	if event is InputEventMouseMotion:
		var curr_range = player_controller.current_weapon_controller.get_max_range()
		var theta = -asin(clamp(height / curr_range, 0.0, 1.0))
		if locked_ship == null:
			rot_h -= event.relative.x * 0.001 * current_zoom * zoom_mod/ max_fov
			rot_v -= event.relative.y * 0.003 * current_zoom * zoom_mod / max_fov * -(rot_v)
			rot_v = clamp(rot_v, -PI / 2, theta)
		else:
			locked_rot_h -= event.relative.x * 0.001 * current_zoom * zoom_mod / max_fov
			locked_rot_v -= event.relative.y * 0.003 * current_zoom * zoom_mod / max_fov * -(rot_v + locked_rot_v)
			var min_offset = rot_v - PI / 2
			var max_offset = theta - rot_v
			locked_rot_v = clamp(locked_rot_v, min_offset, max_offset)

func update_transform():
	if ship != null:
		var pos = ship.global_position + Vector3(0, height, 0)
		var intersection = calculate_0_intersection(pos, rot_h + locked_rot_h + PI, -(rot_v + locked_rot_v))
		if intersection != Vector3.INF:
			var ship_pos = ship.global_position
			ship_pos.y = 0.0
			var dist = intersection.distance_to(ship_pos)
			var h = max(dist * pow(dist / 10000.0, 1.5) * ANGLE, 40)
			zoom_mod = max(0.3,  1.0 / h / 2000.0)
			current_fov = min(max(current_zoom * zoom_mod, 1.0), max_fov)
			global_position = ship.global_position
			global_position.y = h
			# rotation.y = rot_h + PI + locked_rot_h
			# rotation.x = -0.015

			look_at(intersection)
		else:
			global_position = ship.global_position
			global_position.y = 100
			rotation.x = rot_v + locked_rot_v
			rotation.y = rot_h + locked_rot_h

# Calculate camera position for a given rotation (used by iterative solver)
# Note: r_h andeeded to look at target_pos using custom iterative solver.
# Returns Vector2(rot_h, rot_v) or null if no valid solution exists.
func _calculate_rotation_for_aim(target_pos: Vector3) -> Variant:
	var ship_pos = ship.global_position
	var ship_pos_y0 = Vector3(ship_pos.x, 0.0, ship_pos.z)

	var dx = target_pos.x - ship_pos.x
	var dz = target_pos.z - ship_pos.z
	var dist_xz = Vector2(dx, dz).length()

	if dist_xz < 0.0001:
		return null  # Target is directly above/below ship

	# rot_h points toward target with +PI offset (matching aim_view convention)
	var result_rot_h = atan2(dx, dz) + PI

	# Iteratively find the intersection point at y=0 such that
	# the line from camera (at dynamic height h) through intersection
	# passes through target_pos

	# Initial guess: project target straight down to y=0
	var intersection = Vector3(target_pos.x, 0.0, target_pos.z)

	const MAX_ITERATIONS = 10
	const TOLERANCE = 0.1

	for i in range(MAX_ITERATIONS):
		# Calculate dynamic height for current intersection guess
		var dist = intersection.distance_to(ship_pos_y0)
		var h = max(dist * pow(dist / 10000.0, 1.5) * ANGLE, 40.0)

		# Camera position at this height
		var cam_pos = Vector3(ship_pos.x, h, ship_pos.z)

		# Find where line from cam_pos through target_pos hits y=0
		var dir_to_target = target_pos - cam_pos
		if abs(dir_to_target.y) < 0.0001:
			break  # Line is horizontal, can't hit y=0

		var t = -cam_pos.y / dir_to_target.y
		if t < 0:
			break  # Intersection is behind camera

		var new_intersection = cam_pos + dir_to_target * t

		# Check convergence
		var error = new_intersection.distance_to(intersection)
		intersection = new_intersection

		if error < TOLERANCE:
			break

	# Calculate rot_v from the converged intersection
	# Camera is at (ship.x, height, ship.z), looking at intersection
	# rot_v is negated in update_transform, so we calculate the positive angle
	var final_dist_xz = Vector2(intersection.x - ship_pos.x, intersection.z - ship_pos.z).length()
	if final_dist_xz < 0.0001:
		return null

	# rot_v = -atan(height / dist) gives negative angle (looking down)
	# But update_transform negates it, so we store positive
	var result_rot_v = -atan(height / final_dist_xz)

	return Vector2(result_rot_h, result_rot_v)


func set_vh(aim_pos: Vector3):
	var result = _calculate_rotation_for_aim(aim_pos)
	if result != null:
		rot_h = result.x
		rot_v = result.y


func set_locked_rot(locked_aim_pos: Vector3):
	# Calculate the locked_rot_h and locked_rot_v offsets needed to look at locked_aim_pos
	# given the current rot_h and rot_v values.
	var result = _calculate_rotation_for_aim(locked_aim_pos)
	if result != null:
		locked_rot_h = CameraView.normalize_angle(result.x - rot_h)
		locked_rot_v = result.y - rot_v
