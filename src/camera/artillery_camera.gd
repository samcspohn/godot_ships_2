extends Camera3D

class_name ArtilleryCamera

# Ship to follow
@export var target_ship: Node3D
@export var projectile_speed: float = 800.0  # Realistic speed for naval artillery (m/s)
@export var projectile_drag_coefficient: float = ProjectilePhysicsWithDrag.SHELL_380MM_DRAG_COEFFICIENT  # 380mm shell drag

# Camera mode
enum CameraMode { THIRD_PERSON, SNIPER }
var current_mode: int = CameraMode.THIRD_PERSON

# Camera properties
var camera_offset: Vector3 = Vector3(0, 50, 0)  # Height offset above ship
var rotation_degrees_vertical: float = 0.0
var rotation_degrees_horizontal: float = 0.0
var sniper_range: float = 1.0

# Zoom properties - Scaled for a 250m ship
@export var min_zoom_distance: float = 7.0  # Close to the ship
@export var max_zoom_distance: float = 500.0  # Far enough to see full ship and surroundings
@export var zoom_speed: float = 20.0  # Faster zoom for large distances
@export var sniper_threshold: float = 7.0  # Enter sniper mode when closer than this
var current_zoom: float = 200.0  # Default zoom

# Sniper mode properties
@export var default_fov: float = 70.0
@export var min_fov: float = 8.0  # Very narrow for extreme distance aiming
@export var max_fov: float = 60.0  # Wide enough for general aiming
@export var fov_zoom_speed: float = 2.0
var current_fov: float = default_fov

# Mouse settings
@export var mouse_sensitivity: float = 0.3
@export var invert_y: bool = false

# Target information
var time_to_target: float = 0.0
var distance_to_target: float = 0.0
var target_position: Vector3 = Vector3.ZERO
var max_range_reached: bool = false

# UI Elements
var ui_canvas: CanvasLayer
var crosshair_container: Control
var time_label: Label
var distance_label: Label

# Speedometer
var speed_label: Label
var previous_position: Vector3 = Vector3.ZERO
var ship_speed: float = 0.0


func _ready():
	# Initial setup
	current_fov = default_fov
	fov = current_fov
	
	# Make sure we have necessary references
	if not target_ship:
		push_error("ArtilleryCamera requires a target_ship node!")
	
	# Set up UI
	_setup_ui()
	
	# Capture mouse
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _setup_ui():
	# Create CanvasLayer for UI
	ui_canvas = CanvasLayer.new()
	add_child(ui_canvas)

	
	
	# Create Control for UI elements
	crosshair_container = Control.new()
	crosshair_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_canvas.add_child(crosshair_container)
	
	# Add time label
	time_label = Label.new()
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	time_label.position = Vector2(0, 25)
	time_label.add_theme_font_size_override("font_size", 14)
	crosshair_container.add_child(time_label)
	
	# Add distance label
	distance_label = Label.new()
	distance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	distance_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	distance_label.position = Vector2(0, 45)
	distance_label.add_theme_font_size_override("font_size", 14)
	crosshair_container.add_child(distance_label)
	
	# Connect to draw
	crosshair_container.connect("draw", _on_crosshair_container_draw)

	# Add speed label
	speed_label = Label.new()
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	speed_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	speed_label.add_theme_font_size_override("font_size", 16)
	speed_label.add_theme_color_override("font_color", Color(0.2, 0.8, 1.0, 1.0))
	crosshair_container.add_child(speed_label)

func _input(event):
	# Handle mouse movement for rotation
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	
	# Handle zoom with mouse wheel
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_camera(-zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_camera(zoom_speed)
	
	# Toggle camera mode manually with Tab key
	elif event is InputEventKey:
		if event.pressed and event.keycode == KEY_SHIFT:
			toggle_camera_mode()
		# Escape key to release mouse
		elif event.pressed and event.keycode == KEY_ESCAPE:
			if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _process(delta):
	# Update camera position and rotation
	_update_camera_transform()
	
	# Calculate target information
	_calculate_target_info()
	
	 # Calculate ship speed
	if target_ship:
		if previous_position == Vector3.ZERO:
			previous_position = target_ship.global_position

		var velocity = (target_ship.global_position - previous_position) / delta
		ship_speed = velocity.length() * 1.94384  # Convert m/s to knots
		previous_position = target_ship.global_position

	# Update UI
	_update_ui()
	crosshair_container.queue_redraw()

func _zoom_camera(zoom_amount):
	if current_mode == CameraMode.THIRD_PERSON:
		# Adjust zoom in third-person mode
		current_zoom = clamp(current_zoom + zoom_amount, min_zoom_distance, max_zoom_distance)
		
		# Switch to sniper mode if zoomed in enough
		if current_zoom <= sniper_threshold:
			set_camera_mode(CameraMode.SNIPER)
	else:
		# In sniper mode, adjust FOV
		current_fov = clamp(current_fov + zoom_amount * fov_zoom_speed / 10.0, min_fov, max_fov)
		fov = current_fov
		
		# Switch back to third-person if zoomed out enough
		if current_fov >= max_fov:
			set_camera_mode(CameraMode.THIRD_PERSON)
			current_zoom = sniper_threshold + 50.0

func _handle_mouse_motion(event):
	# Only handle mouse motion if captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	# Convert mouse motion to rotation (with potential y-inversion)
	var y_factor = -1.0 if invert_y else 1.0
	if current_mode == CameraMode.THIRD_PERSON: 
		rotation_degrees_horizontal -= event.relative.x * mouse_sensitivity * 0.1
		rotation_degrees_vertical -= event.relative.y * mouse_sensitivity * 0.1 * y_factor
	else:
		#var range_mod = sqrt(sniper_range / 100)
		var range_mod2 = log(sniper_range / 100 + 1) / log(10) + 1
		var range_mod3 = sqrt(sniper_range / 32)
		rotation_degrees_horizontal -= event.relative.x * mouse_sensitivity * 0.1 / range_mod2 * deg_to_rad(current_fov)
		#rotation_degrees_vertical -= event.relative.y * mouse_sensitivity * 0.1 * y_factor
		sniper_range += event.relative.y * mouse_sensitivity * -range_mod3 * deg_to_rad(current_fov)
		sniper_range = clamp(sniper_range, 1, 38280)
	
	# Clamp vertical rotation to prevent flipping over
	rotation_degrees_vertical = clamp(rotation_degrees_vertical, -85.0, 85.0)

func _update_camera_transform():
	if !target_ship:
		return
	
	var ship_position = target_ship.global_position
	var horizontal_rad = deg_to_rad(rotation_degrees_horizontal)
	var vertical_rad = deg_to_rad(rotation_degrees_vertical)
	if current_mode == CameraMode.THIRD_PERSON:
		# Calculate orbit position around the ship
		# Convert spherical coordinates to Cartesian for orbiting

		
		# Calculate camera position in orbit around ship
		var orbit_distance = current_zoom
		var height_offset = camera_offset.y * cos(vertical_rad)
		
		# Calculate the orbit position
		#var orbit_pos = Vector3(
			#sin(horizontal_rad) * orbit_distance * cos(vertical_rad),
			#height_offset + orbit_distance * sin(vertical_rad),
			#cos(horizontal_rad) * orbit_distance * cos(vertical_rad)
		#)
		var orbit_pos = Vector3(
			sin(horizontal_rad) * orbit_distance,
			camera_offset.y + cos(vertical_rad) * orbit_distance / 2.0,
			cos(horizontal_rad) * orbit_distance
		)
		
		# Set camera position relative to ship
		global_position = ship_position + orbit_pos
		
		# Look at the ship while keeping camera upright
		#look_at(ship_position, Vector3.UP)
		#rotate(Vector3.RIGHT, vertical_rad)
		#look_at(basis.z)
		rotation.y = horizontal_rad
		rotation.x = vertical_rad
		
	else: # SNIPER mode
		# In sniper mode, position camera on the ship
		var camera_height = 30.0  # Position camera high enough on large ship
		var forward_offset = 20.0
		
		# Calculate camera position in orbit around ship
		var orbit_distance = current_zoom
		var height_offset = camera_height * cos(vertical_rad)
		
		var max_range = 38000
		var a = sniper_range / 10
		if sniper_range < 100:
			a *= a
		# Calculate the orbit position
		var orbit_pos = Vector3(
			sin(horizontal_rad) * -sniper_range * 0.7,
			camera_height + sniper_range / 15,
			cos(horizontal_rad) * -sniper_range * 0.7
		)
		global_position = ship_position + orbit_pos
		var l = ship_position + Vector3(sin(horizontal_rad) * -sniper_range, 0, cos(horizontal_rad) * -sniper_range)
		look_at(l)

func set_camera_mode(mode):
	current_mode = mode
	
	if mode == CameraMode.THIRD_PERSON:
		# Reset FOV for third-person
		current_fov = default_fov
		fov = current_fov
	else: # SNIPER mode
		
		sniper_range = (target_position - target_ship.global_position).length()
		# Set initial FOV for sniper mode
		current_fov = max_fov
		fov = current_fov

func toggle_camera_mode():
	if current_mode == CameraMode.THIRD_PERSON:
		set_camera_mode(CameraMode.SNIPER)
	else:
		set_camera_mode(CameraMode.THIRD_PERSON)

func _calculate_target_info():
	# Get the direction the camera is facing
	var aim_direction = -global_transform.basis.z.normalized()
	
	# Cast a ray to get target position (could be terrain, enemy, etc.)
	var ray_length = 50000.0  # 50km range for naval artillery
	var space_state = get_world_3d().direct_space_state
	var ray_origin = global_position
	
	var ray_params = PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_origin + aim_direction * ray_length,
		1,  # Set to your proper collision mask
		[]  # Array of objects to exclude
	)
	
	var result = space_state.intersect_ray(ray_params)
	
	if result:
		target_position = result.position
	else:
		# No collision, use a point far in the distance
		target_position = ray_origin + aim_direction * ray_length
	
	# Calculate launch vector using our projectile physics
	var ship_position = target_ship.global_position
	var launch_result = ProjectilePhysicsWithDrag.calculate_launch_vector(
		ship_position, 
		target_position, 
		projectile_speed,
		projectile_drag_coefficient
	)
	
	# Extract results
	var launch_vector = launch_result[0]
	time_to_target = launch_result[1]
	#max_range_reached = launch_result[2]
	max_range_reached = (target_position - ship_position).length() > 38280
	
	# Calculate distance
	distance_to_target = (target_position - ship_position).length() / 1000.0  # Convert to km

func _update_ui():
	# Update info labels
	time_label.text = "%.1f s" % (time_to_target / 2.0)
	distance_label.text = "%.1f km" % distance_to_target
	
	# Center the labels
	var viewport_size = get_viewport().get_visible_rect().size
	var center_x = viewport_size.x / 2.0
	
	time_label.size = Vector2(100, 20)
	distance_label.size = Vector2(100, 20)
	
	time_label.position = Vector2(center_x - 50, viewport_size.y / 2.0 + 25)
	distance_label.position = Vector2(center_x - 50, viewport_size.y / 2.0 + 45)

	speed_label.text = "Speed: %.1f knots" % ship_speed
	speed_label.position = Vector2(20, viewport_size.y - 40)  # Position at bottom left

func _on_crosshair_container_draw():
	var viewport_size = get_viewport().get_visible_rect().size
	var screen_center = viewport_size / 2.0
	
	# Crosshair properties
	var crosshair_size = Vector2(2, 15)
	var crosshair_gap = 5.0
	
	# Use red for out of range, green for in range
	var color = Color(0, 1, 0, 0.8)  # Default to green
	if max_range_reached:
		color = Color(1, 0, 0, 0.8)  # Red for out of range
	
	# Draw crosshair
	var top_rect = Rect2(
		screen_center.x - crosshair_size.x/2,
		screen_center.y - crosshair_size.y - crosshair_gap,
		crosshair_size.x,
		crosshair_size.y
	)
	
	var bottom_rect = Rect2(
		screen_center.x - crosshair_size.x/2,
		screen_center.y + crosshair_gap,
		crosshair_size.x,
		crosshair_size.y
	)
	
	var left_rect = Rect2(
		screen_center.x - crosshair_size.y - crosshair_gap,
		screen_center.y - crosshair_size.x/2,
		crosshair_size.y,
		crosshair_size.x
	)
	
	var right_rect = Rect2(
		screen_center.x + crosshair_gap,
		screen_center.y - crosshair_size.x/2,
		crosshair_size.y,
		crosshair_size.x
	)
	
	crosshair_container.draw_rect(top_rect, color)
	crosshair_container.draw_rect(bottom_rect, color)
	crosshair_container.draw_rect(left_rect, color)
	crosshair_container.draw_rect(right_rect, color)
