extends Node3D
class_name SniperView

var current_fov: float = 60
var default_fov: float = 60.0
var min_fov: float = 2.0
var max_fov: float = 60.0
var _ship: Node3D
var free_look: bool = false
var current_zoom: float = 100.0
var min_zoom: float = 20.0
var max_zoom: float = 500.0
var camera_offset: Vector3 = Vector3(0, 0, 0)
var camera_offset_vertical: float = 0.0
var camera_offset_horizontal: float = 0.0
#var sniper_range: float = 0.0
var sniper_height: float = 15.0
var rotation_degrees_horizontal: float = 0.0
#var rotation_degrees_vertical: float = 0.0
var invert_y: bool = false
var mouse_sensitivity: float = 0.1
var target_lock_enabled: bool = false
var locked_target
var sniper_height_mod: float = 200.0
var sniper_angle_x: float = deg_to_rad(-2.0)

func handle_mouse_motion(event):
	# Only handle mouse motion if captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	# Convert mouse motion to rotation (with potential y-inversion)
	var y_factor = -1.0 if invert_y else 1.0
	var ship_position = _ship.global_position
	#var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	var orbit_distance = current_zoom
		
	#var cam_height = ship_position.y + camera_offset.y + cos(vertical_rad) * orbit_distance / 2.0
	#print(cos(vertical_rad))
	#print("-45", cos(-45))
	#print("vert - -45", cos(vertical_rad) - cos(deg_to_rad(-45)))
	#print("1 - cos(-45)", 1.0 - cos(deg_to_rad(-45)))
	#print((cos(vertical_rad) - cos(deg_to_rad(-45))) / (1.0 - cos(-45)))
	#cam_height = 10 + (cos(vertical_rad) - cos(deg_to_rad(-45))) / (1.0 - cos(-45)) * sniper_height_mod
	#print(cam_height)
	#var vert_rad = deg_to_rad(rotation_degrees_vertical)
	
	if target_lock_enabled:
		# When locked on target, mouse movements create offset
		#var vert_rad = deg_to_rad(rotation_degrees_vertical + camera_offset_vertical)
		var offset_sensitivity = mouse_sensitivity * deg_to_rad(current_fov) / deg_to_rad(max_fov)
		camera_offset_vertical -= event.relative.y * offset_sensitivity * y_factor * 0.2
		
		camera_offset_horizontal -= event.relative.x * offset_sensitivity * 0.6
		
	else:
		# Apply horizontal rotation with FOV adjustment
		rotation_degrees_horizontal -= event.relative.x * mouse_sensitivity * 0.6 * deg_to_rad(current_fov)  / deg_to_rad(max_fov)

		sniper_height -= event.relative.y * mouse_sensitivity * y_factor * deg_to_rad(current_fov) / deg_to_rad(max_fov) * 0.1 * sniper_height
		sniper_height = clamp(sniper_height, 0.005, -tan(sniper_angle_x) * _ship.artillery_controller.guns[0].max_range)
		#sniper_range -= event.relative.y * mouse_sensitivity * y_factor * deg_to_rad(current_fov) / deg_to_rad(max_fov) * 0.1 * sniper_range
		#sniper_range = clamp(sniper_range, 10.0, _ship.artillery_controller.guns[0].max_range)
		#
		## Apply vertical rotation with FOV and angle-based sensitivity
		#rotation_degrees_vertical -= event.relative.y * mouse_sensitivity * y_factor * deg_to_rad(current_fov) / deg_to_rad(max_fov) * 0.2
		#
		## Maintain existing clamp
		#rotation_degrees_vertical = clamp(rotation_degrees_vertical, -45, rad_to_deg(tan(-cam_height / _ship.artillery_controller.guns[0].max_range)))
		
		# Clamp vertical rotation to prevent flipping over


var _t = Time.get_unix_time_from_system()
func _print(m):
	pass
	#if _t + 0.3 < Time.get_unix_time_from_system():
		#print(m)

func _update_t():
	pass
	#if _t + 0.3 < Time.get_unix_time_from_system():
		#_t = Time.get_unix_time_from_system()

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

func _update_camera_transform():
	if !_ship:
		return
	
	var ship_position = _ship.global_position
	# var cam_pos = global_position
	#var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	var horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	var orbit_distance = current_zoom
	#var adj = tan(PI / 2.0 + vertical_rad)
	var cam_pos_sniper = ship_position + Vector3(
		0.0,
		max(sniper_height, 15.0),
		0.0
	)

	var cam_pos = cam_pos_sniper
	
	if target_lock_enabled and locked_target and is_instance_valid(locked_target):
		_print("DEBUG")
		# Calculate direction to target
		var target_position = locked_target.global_position
		var direction_to_target = (target_position - cam_pos).normalized()
		
		# Calculate base angle to target (without lerping for responsive movement)
		var target_angle_horizontal = atan2(direction_to_target.x, direction_to_target.z) + PI
		var target_distance = cam_pos.distance_to(target_position)
		var height_diff = target_position.y - cam_pos.y
		var target_angle_vertical = atan2(height_diff, sqrt(pow(direction_to_target.x, 2) + pow(direction_to_target.z, 2)) * target_distance)
		_print(target_angle_vertical)
		
		var max_range_angle = rad_to_deg(tan(-cam_pos.y / _ship.artillery_controller.guns[0].max_range))
		var target_angle_vert_deg = rad_to_deg(target_angle_vertical)
		camera_offset_vertical = clamp(camera_offset_vertical, -30 - target_angle_vert_deg, max_range_angle - target_angle_vert_deg)
		
		# Apply the player's offset to the camera direction - immediately, no lerping
		rotation_degrees_horizontal = rad_to_deg(target_angle_horizontal) + camera_offset_horizontal
		#rotation_degrees_vertical = rad_to_deg(target_angle_vertical) + camera_offset_vertical

		# Clamp vertical rotation to prevent flipping over
		#rotation_degrees_vertical = clamp(rotation_degrees_vertical, -30, max_range_angle)
	# Use the existing camera positioning logic with updated rotation values
	horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	#vertical_rad = deg_to_rad(rotation_degrees_vertical)
	#adj = tan(PI / 2.0 + vertical_rad)
	# var dist = adj * cam_pos.y
	
	#var orbit_pos = Vector3(
			#sin(horizontal_rad) * orbit_distance,
			#camera_offset.y + cos(vertical_rad) * orbit_distance / 2.0,
			#cos(horizontal_rad) * orbit_distance
		#)
	
	
	
	#_print(vertical_rad)
	#_print(adj)
	_print(_ship.artillery_controller.guns[0].max_range)
	_print(deg_to_rad(camera_offset_vertical))
	
	
	var sniper_pos = Vector3(
		0.0,
		max(sniper_height, 15.0) - ship_position.y,
		0.0
	)
	global_position = ship_position + sniper_pos
	rotation.y = horizontal_rad
	rotation.x = sniper_angle_x
	_update_t()
	# Calculate where the ray from camera intersects the ground
	var sniper_range = sniper_height / tan(sniper_angle_x)
	var intersection_point = _ship.global_position + Vector3(sin(horizontal_rad) * sniper_range, -_ship.global_position.y, cos(horizontal_rad) * sniper_range)

	## Look at the intersection point
	look_at(intersection_point)
