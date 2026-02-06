extends Node3D
class_name CameraView

var rot_h: float
var rot_v: float
var current_fov: float
var current_zoom: float
var ship: Ship
var player_controller: PlayerController
var locked_ship: Ship
var locked_rot_h: float
var locked_rot_v: float

func zoom_camera(_delta):
	pass

func handle_mouse_event(_event):
	pass

func update_transform():
	pass

func set_vh(_aim_pos: Vector3):
	pass

func set_locked_rot(_locked_aim_pos: Vector3):
	pass


# Calculate the rotation (rot_h, rot_v) needed to look at target_pos from a given camera position.
# Returns Vector2(rot_h, rot_v)
static func calculate_rotation_to_target(cam_pos: Vector3, target_pos: Vector3, h_offset: float = 0.0) -> Vector2:
	var to_target = target_pos - cam_pos
	var dist_xz = Vector2(to_target.x, to_target.z).length()

	var result_rot_h = atan2(to_target.x, to_target.z) + h_offset
	var result_rot_v = -atan2(to_target.y, dist_xz)
	result_rot_v = clamp(result_rot_v, -PI / 2 + 0.01, PI / 2 - 0.01)

	return Vector2(result_rot_h, result_rot_v)


# Normalize an angle to the range [-PI, PI]
static func normalize_angle(angle: float) -> float:
	while angle > PI:
		angle -= TAU
	while angle < -PI:
		angle += TAU
	return angle


# Iterative solver for finding rotation that makes camera look at target.
# Used when camera position depends on rotation (fixed-point iteration).
#
# Parameters:
#   target_pos: The world position to look at
#   ship_pos: The ship's world position (for initial guess)
#   calculate_position_func: Callable(rot_h: float, rot_v: float) -> Vector3
#                            Returns camera position for given rotation
#   h_offset: Offset to add to horizontal rotation (e.g., PI for some camera setups)
#   epsilon: Convergence threshold in radians
#   max_iterations: Maximum iteration count
#
# Returns Vector2(rot_h, rot_v)
static func solve_rotation_iterative(
	target_pos: Vector3,
	ship_pos: Vector3,
	calculate_position_func: Callable,
	h_offset: float = PI,
	epsilon: float = 0.000000001,
	max_iterations: int = 10
) -> Vector2:
	# Initial guess: direction from ship to target
	var to_target = target_pos - ship_pos
	var dist_xz = Vector2(to_target.x, to_target.z).length()

	var current_rot_h = atan2(to_target.x, to_target.z) + h_offset
	var current_rot_v = -atan2(to_target.y, dist_xz)
	current_rot_v = clamp(current_rot_v, -PI / 2 + 0.01, PI / 2 - 0.01)

	# Fixed-point iteration
	for i in range(max_iterations):
		var cam_pos = calculate_position_func.call(current_rot_h, current_rot_v)

		# Calculate rotation needed to look at target from current camera position
		var cam_to_target = target_pos - cam_pos
		var cam_dist_xz = Vector2(cam_to_target.x, cam_to_target.z).length()

		var new_rot_h = atan2(cam_to_target.x, cam_to_target.z) + h_offset
		var new_rot_v = -atan2(-cam_to_target.y, cam_dist_xz)
		new_rot_v = clamp(new_rot_v, -PI / 2 + 0.01, PI / 2 - 0.01)

		# Check convergence
		var delta_h = normalize_angle(new_rot_h - current_rot_h)
		var delta_v = new_rot_v - current_rot_v

		current_rot_h = new_rot_h
		current_rot_v = new_rot_v

		if abs(delta_h) < epsilon and abs(delta_v) < epsilon:
			break

	return Vector2(current_rot_h, current_rot_v)
