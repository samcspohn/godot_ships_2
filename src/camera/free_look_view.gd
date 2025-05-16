extends Node3D
class_name FreeLookView

var current_fov: float = 60.0
var free_look: bool = false
var current_zoom: float = 0.0
var min_zoom_distance: float = 20.0
var max_zoom_distance: float = 500.0
var camera_offset: Vector3 = Vector3(0, 10.0, 0)
var rotation_degrees_horizontal: float = 0.0
var rotation_degrees_vertical: float = 0.0
var invert_y: bool = false
var mouse_sensitivity: float = 0.3
var target_lock_enabled: bool = false
var _ship: Node3D
# Camera mode



func handle_mouse_motion(event):
	# Only handle mouse motion if captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	# Convert mouse motion to rotation (with potential y-inversion)
	var y_factor = -1.0 if invert_y else 1.0

	# Normal camera control without target lock

	rotation_degrees_horizontal -= event.relative.x * mouse_sensitivity * 0.1
	rotation_degrees_vertical -= event.relative.y * mouse_sensitivity * 0.1 * y_factor
	rotation_degrees_vertical = clamp(rotation_degrees_vertical, -85.0, 85.0)


func _update_camera_transform():
	if !_ship:
		return
	
	var ship_position = _ship.global_position
	# var cam_pos = global_position
	var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	var horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	var orbit_distance = current_zoom

	# Use the existing camera positioning logic with updated rotation values
	horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	vertical_rad = deg_to_rad(rotation_degrees_vertical)

	# var dist = adj * cam_pos.y
	
	var orbit_pos = Vector3(
			sin(horizontal_rad) * orbit_distance,
			camera_offset.y + cos(vertical_rad) * orbit_distance / 2.0,
			cos(horizontal_rad) * orbit_distance
		)

	global_position = ship_position + orbit_pos
	rotation.y = horizontal_rad
	rotation.x = vertical_rad
