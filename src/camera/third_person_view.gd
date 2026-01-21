extends Node3D
class_name ThirdPersonView
# Third Person Camera

var current_fov: float = 40
var default_fov: float = 40.0
# var min_fov: float = 2.0
# var max_fov: float = 60.0
# var last_fov: float = 60.0

var horizontal_rot: float = 0.0
var vertical_rot: float = 0.0

var current_zoom: float = 200.0 # Default zoom
var min_zoom_distance: float = 7.0
var max_zoom_distance: float = 1000.0
var zoom_speed: float = 20.0
var camera_offset_vertical:float = 0.0
var camera_offset_horizontal:float = 0.0
var camera_offset: Vector3 = Vector3(0, 10.0, 0)
var rotation_degrees_horizontal: float = 0.0
var rotation_degrees_vertical: float = 0.0
var invert_y: bool = false
var mouse_sensitivity: float = 0.3
var target_lock_enabled: bool = false
var _ship: Node3D
var locked_target
#
#func copy_to_free_look(fl: FreeLookView):
	## Copy camera settings to FreeLookView
	#fl.current_zoom = current_zoom
	#fl.current_fov = current_fov
	#fl.rotation_degrees_horizontal = rotation_degrees_horizontal
	#fl.rotation_degrees_vertical = rotation_degrees_vertical
	#fl.camera_offset = camera_offset
	#fl.invert_y = invert_y
	#fl.mouse_sensitivity = mouse_sensitivity
	#fl.target_lock_enabled = target_lock_enabled

func handle_mouse_motion(event):
	# Only handle mouse motion if captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	# Convert mouse motion to rotation (with potential y-inversion)
	var y_factor = -1.0 if invert_y else 1.0
	# var ship_position = _ship.global_position
	# var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	# var orbit_distance = current_zoom

	# var cam_height = ship_position.y + camera_offset.y + cos(vertical_rad) * orbit_distance / 2.0
	var vert_rad = deg_to_rad(rotation_degrees_vertical)

	if target_lock_enabled:
		# When locked on target, mouse movements create offset
		vert_rad = deg_to_rad(rotation_degrees_vertical) + camera_offset_vertical
		var offset_sensitivity = mouse_sensitivity
		camera_offset_vertical -= event.relative.y * offset_sensitivity * 0.1 * y_factor * sqrt(abs(vert_rad))

		camera_offset_horizontal -= event.relative.x * offset_sensitivity * 0.1

	else:
		# Normal camera control without target lock
		rotation_degrees_horizontal -= event.relative.x * mouse_sensitivity * 0.1
		rotation_degrees_vertical -= event.relative.y * mouse_sensitivity * 0.1 * y_factor
		rotation_degrees_vertical = clamp(rotation_degrees_vertical, -85.0, 85.0)


var _t = Time.get_unix_time_from_system()
func _print(m):
	if _t + 0.3 < Time.get_unix_time_from_system():
		print(m)

func _update_t():
	if _t + 0.3 < Time.get_unix_time_from_system():
		_t = Time.get_unix_time_from_system()

func calculate_ground_intersection(origin_position: Vector3, h_rad: float, v_rad: float) -> Vector3:
	# Create direction vector from angles
	var direction = Vector3(
		sin(h_rad), # x component
		sin(v_rad), # y component
		cos(h_rad) # z component
	).normalized()

	# If direction is parallel to ground or pointing up, no intersection
	if direction.y >= -0.0001:
		# Return a fallback position at maximum visible distance
		return origin_position + Vector3(sin(h_rad), 0, cos(h_rad)) * 10000.0

	# Calculate intersection parameter t using plane equation:
	# For plane at y=0: t = -origin.y / direction.y
	var t = - origin_position.y / direction.y

	# Calculate intersection point
	return origin_position + direction * t

func _get_angles_to_target(cam_pos, target_pos):
	# Calculate direction to target
	var direction_to_target = (target_pos - cam_pos).normalized()

	# Calculate base angle to target (without lerping for responsive movement)
	var target_angle_horizontal = atan2(direction_to_target.x, direction_to_target.z) + PI
	var target_distance = cam_pos.distance_to(target_pos)
	var height_diff = target_pos.y - cam_pos.y
	var target_angle_vertical = atan2(height_diff, sqrt(pow(direction_to_target.x, 2) + pow(direction_to_target.z, 2)) * target_distance)

	return [target_angle_horizontal, target_angle_vertical]

func _get_orbit():
	# var ship_position = _ship.global_position
	# var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	var horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	var orbit_distance = current_zoom
	#var adj = tan(PI / 2.0 + vertical_rad)
	#print("sin vertical ", sin(vertical_rad))
	#print("cos vertical ", cos(vertical_rad))
	#print("sin PI/2 vertical ", sin(PI / 2.0 + vertical_rad))
	#print("cos PI/2 vertical ", cos(PI / 2.0 + vertical_rad))
	var sh = sin(horizontal_rad)
	var ch = cos(horizontal_rad)
	# var sv = sin(vertical_rad)
	# var cv = cos(vertical_rad)
	# var cp2v = cos(PI/2.0 + vertical_rad)
	# var sp2v = sin(PI/2.0 + vertical_rad)
	# var cam_height_offset = orbit_distance / 2.0
	var cam_pos = Vector3(
		sh * (orbit_distance),
		5 + current_zoom * 0.2,
		#max(cam_height_offset / 2.0 + cam_height_offset * cp2v, 1),
		ch * (orbit_distance)
	)
	#var cam_pos = Vector3(
	  		#sin(horizontal_rad) * (orbit_distance * cos(vertical_rad) - cos(PI/2.0 + vertical_rad) * orbit_distance / 2.0),
	  		#camera_offset.y - sin(vertical_rad) * orbit_distance + sin(PI/2.0 + vertical_rad) * orbit_distance / 2.0,
	  		#cos(horizontal_rad) * (orbit_distance * cos(vertical_rad) - cos(PI/2.0 + vertical_rad) * orbit_distance / 2.0)
	  	#)
	return cam_pos

func _get_orbit2():
	# var ship_position = _ship.global_position
	# var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	var horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	var orbit_distance = current_zoom
	#var adj = tan(PI / 2.0 + vertical_rad)
	#print("sin vertical ", sin(vertical_rad))
	#print("cos vertical ", cos(vertical_rad))
	#print("sin PI/2 vertical ", sin(PI / 2.0 + vertical_rad))
	#print("cos PI/2 vertical ", cos(PI / 2.0 + vertical_rad))
	var sh = sin(horizontal_rad)
	var ch = cos(horizontal_rad)
	# var sv = sin(vertical_rad)
	# var cv = cos(vertical_rad)
	# var cp2v = cos(PI/2.0 + vertical_rad)
	# var sp2v = sin(PI/2.0 + vertical_rad)
	var cam_height_offset = orbit_distance * 0.4
	var cam_pos = Vector3(
		sh * orbit_distance,
		cam_height_offset,
		ch * orbit_distance
	)
	#var cam_pos = Vector3(
	  		#sin(horizontal_rad) * (orbit_distance * cos(vertical_rad) - cos(PI/2.0 + vertical_rad) * orbit_distance / 2.0),
	  		#camera_offset.y - sin(vertical_rad) * orbit_distance + sin(PI/2.0 + vertical_rad) * orbit_distance / 2.0,
	  		#cos(horizontal_rad) * (orbit_distance * cos(vertical_rad) - cos(PI/2.0 + vertical_rad) * orbit_distance / 2.0)
	  	#)
	return cam_pos

func _update_camera_transform():
	if !_ship:
		return

	var ship_position = _ship.global_position
	# var cam_pos = global_position
	var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	var horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	# var orbit_distance = current_zoom
	# var adj = tan(PI / 2.0 + vertical_rad)
	var cam_pos_3rd = ship_position + _get_orbit()

	var cam_pos = cam_pos_3rd

	if target_lock_enabled and locked_target and is_instance_valid(locked_target):
		# _print("DEBUG")
		# Calculate direction to target
		var target_position = locked_target.global_position
		var direction_to_target = (target_position - cam_pos).normalized()

		# Calculate base angle to target (without lerping for responsive movement)
		var target_angle_horizontal = atan2(direction_to_target.x, direction_to_target.z) + PI
		var target_distance = cam_pos.distance_to(target_position)
		var height_diff = target_position.y - cam_pos.y
		var target_angle_vertical = atan2(height_diff, sqrt(pow(direction_to_target.x, 2) + pow(direction_to_target.z, 2)) * target_distance)
		# _print(target_angle_vertical)

		var max_range_angle = rad_to_deg(tan(-cam_pos.y / _ship.artillery_controller.get_params()._range))
		var target_angle_vert_deg = rad_to_deg(target_angle_vertical)
		camera_offset_vertical = clamp(camera_offset_vertical, -85 - target_angle_vert_deg, max_range_angle - target_angle_vert_deg)
		# Apply the player's offset to the camera direction - immediately, no lerping
		rotation_degrees_horizontal = rad_to_deg(target_angle_horizontal) + camera_offset_horizontal
		rotation_degrees_vertical = rad_to_deg(target_angle_vertical) + camera_offset_vertical

	else:
		camera_offset_horizontal = 0.0
		camera_offset_vertical = 0.0

		# Clamp vertical rotation to prevent flipping over
	rotation_degrees_vertical = clamp(rotation_degrees_vertical, -85.0, 85)


	# Use the existing camera positioning logic with updated rotation values
	horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	vertical_rad = deg_to_rad(rotation_degrees_vertical)
	# adj = tan(PI / 2.0 + vertical_rad)
	# var dist = adj * cam_pos.y

	var orbit_pos = _get_orbit()

	global_position = ship_position + orbit_pos
	global_position.y = orbit_pos.y
	#if vertical_rad > 0:
	rotation.y = horizontal_rad
	rotation.x = vertical_rad
	#else:
		#var aim_point = calculate_ground_intersection(ship_position + Vector3(orbit_pos.x ,current_zoom * 0.5 - ship_position.y, orbit_pos.z), horizontal_rad + PI,vertical_rad)
		##rotation.y = horizontal_rad
		#look_at(aim_point)
		##rotation.x = vertical_rad
