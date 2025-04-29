extends Camera3D

class_name ArtilleryCamera

# Ship to follow
@export var target_ship: Ship
@export var ship_movement: ShipMovement
@export var hp_manager: HitPointsManager  # Add reference to hit points
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
@export var min_fov: float = 2.0  # Very narrow for extreme distance aiming
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

# Ship status indicators
var speed_label: Label
var throttle_label: Label
var rudder_label: Label
var rudder_slider: HSlider
var throttle_slider: VSlider
var previous_position: Vector3 = Vector3.ZERO
var ship_speed: float = 0.0

# FPS counter
var fps_label: Label

# Hit point display
var hp_bar: ProgressBar
var hp_label: Label

# Add these variables near the top with other variable declarations
var tracked_ships = {}  # Dictionary to store ships and their UI elements
var ship_ui_elements = {}  # Dictionary to store UI elements for each ship

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
	#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

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

	# Add ship status labels
	var status_color = Color(0.2, 0.8, 1.0, 1.0)
	var font_size = 16
	
	# Add speed label
	speed_label = Label.new()
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	speed_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	speed_label.add_theme_font_size_override("font_size", font_size)
	speed_label.add_theme_color_override("font_color", status_color)
	crosshair_container.add_child(speed_label)
	
	# Add throttle label
	throttle_label = Label.new()
	throttle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	throttle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	throttle_label.add_theme_font_size_override("font_size", font_size)
	throttle_label.add_theme_color_override("font_color", status_color)
	crosshair_container.add_child(throttle_label)
	
	# Add rudder label
	rudder_label = Label.new()
	rudder_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rudder_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rudder_label.add_theme_font_size_override("font_size", font_size)
	rudder_label.add_theme_color_override("font_color", status_color)
	crosshair_container.add_child(rudder_label)
	
	# Add rudder slider (horizontal)
	rudder_slider = HSlider.new()
	rudder_slider.min_value = -1.0
	rudder_slider.max_value = 1.0
	rudder_slider.step = 0.01
	rudder_slider.value = 0
	rudder_slider.custom_minimum_size = Vector2(150, 20)
	rudder_slider.editable = false  # Read-only display
	crosshair_container.add_child(rudder_slider)
	
	# Add throttle slider (vertical)
	throttle_slider = VSlider.new()
	throttle_slider.min_value = -1.0  # Reverse
	throttle_slider.max_value = 4.0   # Full ahead
	throttle_slider.step = 0.1
	throttle_slider.value = 0
	throttle_slider.custom_minimum_size = Vector2(20, 100)
	throttle_slider.editable = false  # Read-only display
	crosshair_container.add_child(throttle_slider)

	# Add FPS counter in top right
	fps_label = Label.new()
	fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	fps_label.add_theme_font_size_override("font_size", 16)
	fps_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.0, 1.0)) # Yellow for visibility
	crosshair_container.add_child(fps_label)
	
	# Add hit points bar
	hp_bar = ProgressBar.new()
	hp_bar.custom_minimum_size = Vector2(200, 20)
	hp_bar.value = 100
	hp_bar.show_percentage = false
	hp_bar.modulate = Color(0.2, 0.9, 0.2)  # Green color for health
	crosshair_container.add_child(hp_bar)
	
	# Add hit points label overlay
	hp_label = Label.new()
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_label.add_theme_font_size_override("font_size", 14)
	hp_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0)) # White text
	hp_label.text = "100/100"
	crosshair_container.add_child(hp_label)

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


func _process(delta):
	# Update camera position and rotation
	_update_camera_transform()
	
	# Calculate target information
	_calculate_target_info()
	
	 # Calculate ship speed
	if target_ship:
		if previous_position == Vector3.ZERO:
			previous_position = target_ship.global_position

		var velocity = target_ship.linear_velocity
		ship_speed = velocity.length() * 1.94384  # Convert m/s to knots
		previous_position = target_ship.global_position

	# Update UI
	_update_ui()
	_update_fps()
	update_ship_ui()  # Add this line to update ship UI elements
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
		rotation_degrees_horizontal -= event.relative.x * mouse_sensitivity * 0.3 / range_mod2 * deg_to_rad(current_fov)
		#rotation_degrees_vertical -= event.relative.y * mouse_sensitivity * 0.1 * y_factor
		sniper_range += event.relative.y * mouse_sensitivity * sniper_range * -0.02 * deg_to_rad(current_fov)
		sniper_range = clamp(sniper_range, 1, 39900)
	
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
		var orbit_pos = Vector3(
			sin(horizontal_rad) * orbit_distance,
			camera_offset.y + cos(vertical_rad) * orbit_distance / 2.0,
			cos(horizontal_rad) * orbit_distance
		)
		
		# Set camera position relative to ship
		global_position = ship_position + orbit_pos

		rotation.y = horizontal_rad
		rotation.x = vertical_rad
		
	else: # SNIPER mode
		# In sniper mode, position camera on the ship
		var camera_height = 10.0  # Position camera high enough on large ship
		var forward_offset = 20.0
		
		# Calculate camera position in orbit around ship
		var orbit_distance = current_zoom
		var height_offset = camera_height * cos(vertical_rad)
		
		var max_range = 39900
		var a = sniper_range / 10
		if sniper_range < 100:
			a *= a
		# Calculate the orbit position
		var orbit_pos = Vector3(
			sin(horizontal_rad) * -sniper_range * 0.1,
			camera_height + sniper_range / 20,
			cos(horizontal_rad) * -sniper_range * 0.1
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
	max_range_reached = (target_position - ship_position).length() > 39909
	
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

	# Update ship status labels
	speed_label.text = "Speed: %.1f knots" % ship_speed
	
	# Get throttle and rudder information from the ship
	var throttle_text = "Throttle: Stop"
	var rudder_text = "Rudder: Center"
	
	if ship_movement is ShipMovement:
		# Get throttle setting
		var throttle_level = ship_movement.throttle_level
		var throttle_display = ""
		
		match throttle_level:
			-1: throttle_display = "Reverse"
			0: throttle_display = "Stop"
			1: throttle_display = "1/4"
			2: throttle_display = "1/2"
			3: throttle_display = "3/4"
			4: throttle_display = "Full"
		
		throttle_text = "Throttle: " + throttle_display
		throttle_slider.value = throttle_level
		
		# Get rudder setting
		var rudder_value = ship_movement.rudder_value
		var rudder_display = ""
		
		if abs(rudder_value) < 0.1:
			rudder_display = "Center"
		elif rudder_value > 0:
			if rudder_value > 0.75:
				rudder_display = "Hard Port"
			elif rudder_value > 0.25:
				rudder_display = "Port"
			else:
				rudder_display = "Slight Port"
		else:
			if rudder_value < -0.75:
				rudder_display = "Hard Starboard"
			elif rudder_value < -0.25:
				rudder_display = "Starboard"
			else:
				rudder_display = "Slight Starboard"
		
		rudder_text = "Rudder: " + rudder_display
		rudder_slider.value = rudder_value
	
	throttle_label.text = throttle_text
	rudder_label.text = rudder_text
	
	# Position the status labels and sliders in bottom left corner
	var control_panel_x = 20
	var control_panel_y = viewport_size.y - 180  # Moved up to make room for the control layout
	
	# Position labels
	speed_label.position = Vector2(control_panel_x, control_panel_y)
	throttle_label.position = Vector2(control_panel_x, control_panel_y + 25)
	rudder_label.position = Vector2(control_panel_x, control_panel_y + 50)
	
	# Position sliders in a non-overlapping layout
	# Rudder slider (horizontal) at the bottom
	rudder_slider.position = Vector2(control_panel_x, control_panel_y + 75)
	rudder_slider.custom_minimum_size = Vector2(180, 20)
	
	# Throttle slider (vertical) positioned at the right end of the rudder slider
	throttle_slider.position = Vector2(control_panel_x + 180, control_panel_y - 25)  # Position at the right end of rudder slider
	throttle_slider.custom_minimum_size = Vector2(20, 100)  # Keep the same height
	
	# Add custom styling to sliders based on values
	if target_ship is Ship:
		# Set color for rudder slider based on port/starboard
		var rudder_value = rudder_slider.value
		if rudder_value > 0:  # Port (left)
			rudder_slider.modulate = Color(1, 0.5, 0.5)  # Red tint for port
		elif rudder_value < 0:  # Starboard (right)
			rudder_slider.modulate = Color(0.5, 1, 0.5)  # Green tint for starboard
		else:
			rudder_slider.modulate = Color(1, 1, 1)  # White for center
			
		# Set color for throttle slider based on direction
		var throttle_level = throttle_slider.value
		if throttle_level > 0:  # Forward
			throttle_slider.modulate = Color(0.5, 0.8, 1.0)  # Blue for forward
		elif throttle_level < 0:  # Reverse
			throttle_slider.modulate = Color(1.0, 0.8, 0.5)  # Orange for reverse
		else:
			throttle_slider.modulate = Color(1, 1, 1)  # White for stop

	# Update hit points display
	if hp_manager:
		var current_hp = hp_manager.current_hp
		var max_hp = hp_manager.max_hp
		var hp_percent = (float(current_hp) / max_hp) * 100.0
		
		# Update progress bar
		hp_bar.value = hp_percent
		hp_label.text = "%d/%d" % [current_hp, max_hp]
		
		# Change color based on health level
		if hp_percent > 60:
			hp_bar.modulate = Color(0.2, 0.9, 0.2)  # Green for high health
		elif hp_percent > 30:
			hp_bar.modulate = Color(0.9, 0.9, 0.2)  # Yellow for medium health
		else:
			hp_bar.modulate = Color(0.9, 0.2, 0.2)  # Red for low health
			
		# Position the health bar at the bottom center of screen
		hp_bar.position = Vector2(viewport_size.x / 2 - hp_bar.custom_minimum_size.x / 2, 
								 viewport_size.y - hp_bar.custom_minimum_size.y - 20)
		# Position label over the progress bar
		hp_label.size = hp_bar.custom_minimum_size
		hp_label.position = hp_bar.position
	else:
		# Hide if no hp_manager is available
		hp_bar.visible = false
		hp_label.visible = false

func _update_fps():
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	
	# Position in top right corner
	# var viewport_size = get_viewport().get_visible_rect().size
	fps_label.size = Vector2(100, 25)
	fps_label.position = Vector2(10, 10)

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

func setup_ship_ui(ship):
	if ship == target_ship or ship in ship_ui_elements:
		return  # Skip own ship or already tracked ships
	
	# Create a container for the ship's UI
	var ship_container = Control.new()
	ship_container.visible = false  # Start hidden until positioned
	crosshair_container.add_child(ship_container)
	
	# Create ship name label
	var name_label = Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.9))
	name_label.text = ship.name
	ship_container.add_child(name_label)
	
	# Create HP progress bar
	var ship_hp_bar = ProgressBar.new()
	ship_hp_bar.custom_minimum_size = Vector2(90, 10)
	ship_hp_bar.value = 100
	ship_hp_bar.show_percentage = false
	ship_hp_bar.modulate = Color(0.2, 0.9, 0.2)  # Default green
	ship_container.add_child(ship_hp_bar)
	
	# Create HP text label
	var ship_hp_label = Label.new()
	ship_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ship_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ship_hp_label.add_theme_font_size_override("font_size", 10)
	ship_hp_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.9))
	ship_hp_label.text = "100/100"
	ship_container.add_child(ship_hp_label)
	
	# Store the UI elements for this ship
	ship_ui_elements[ship] = {
		"container": ship_container,
		"name_label": name_label,
		"hp_bar": ship_hp_bar,
		"hp_label": ship_hp_label
	}

func update_ship_ui():
	# Find all ships in the scene if not already tracked
	if tracked_ships.is_empty():
		# var ships = get_tree().get_nodes_in_group("ships")
		var ships = get_node("/root/Server/GameWorld/Players").get_children()
		for ship in ships:
			if ship != target_ship and ship is Ship:
				tracked_ships[ship] = true
				setup_ship_ui(ship)
	
	# Update each ship's UI
	for ship in tracked_ships.keys():
		if is_instance_valid(ship) and ship in ship_ui_elements:
			var ui = ship_ui_elements[ship]
			
			# Get ship's HP if it has an HP manager
			var ship_hp_manager = ship.get_node_or_null("HitPointsManager")
			if ship_hp_manager:
				var current_hp = ship_hp_manager.current_hp
				var max_hp = ship_hp_manager.max_hp
				var hp_percent = (float(current_hp) / max_hp) * 100.0
				
					# Determine team color
				var team_color = null
				var my_team_id = -1
				if target_ship.has_node("TeamEntity"):
					var my_team_entity = target_ship.get_node("TeamEntity")
					if my_team_entity.has_method("get_team_info"):
						my_team_id = my_team_entity.get_team_info()["team_id"]
				var ship_team_id = -2
				if ship.has_node("TeamEntity"):
					var ship_team_entity = ship.get_node("TeamEntity")
					if ship_team_entity.has_method("get_team_info"):
						ship_team_id = ship_team_entity.get_team_info()["team_id"]
				if my_team_id != -1 and ship_team_id != -2:
					if my_team_id == ship_team_id:
						team_color = Color(0.2, 0.9, 1.0) # Teal for same team
					else:
						team_color = Color(0.9, 0.2, 0.2) # Red for enemy team
				
				# Update progress bar and label
				ui.hp_bar.value = hp_percent
				ui.hp_label.text = "%d/%d" % [current_hp, max_hp]
				
				# Update color based on health and team
				if team_color:
					ui.hp_bar.modulate = team_color
				else:
					if hp_percent > 60:
						ui.hp_bar.modulate = Color(0.2, 0.9, 0.2)  # Green
					elif hp_percent > 30:
						ui.hp_bar.modulate = Color(0.9, 0.9, 0.2)  # Yellow
					else:
						ui.hp_bar.modulate = Color(0.9, 0.2, 0.2)  # Red
			
			# Position UI above ship in the world
			var ship_position = ship.global_position + Vector3(0, 20, 0)  # Add height offset
			var screen_pos = get_viewport().get_camera_3d().unproject_position(ship_position)
			
			# Check if ship is visible on screen
			var is_visible = is_position_visible_on_screen(ship_position) and ship.visible
			ui.container.visible = is_visible
			
			if is_visible:
				# Position the UI elements
				ui.container.position = screen_pos - Vector2(ui.hp_bar.custom_minimum_size.x / 2, 50)
				ui.name_label.position = Vector2(0, -20)
				ui.hp_bar.position = Vector2(0, 0)
				ui.hp_label.size = ui.hp_bar.custom_minimum_size
				ui.hp_label.position = Vector2(0, -1)
		else:
			# Ship no longer valid, remove it
			if ship in ship_ui_elements:
				for element in ship_ui_elements[ship].values():
					if is_instance_valid(element):
						element.queue_free()
				ship_ui_elements.erase(ship)
			tracked_ships.erase(ship)

func is_position_visible_on_screen(world_position):
	var camera = get_viewport().get_camera_3d()
	
	# Check if position is in front of camera
	var camera_direction = -camera.global_transform.basis.z.normalized()
	var to_position = (world_position - camera.global_position).normalized()
	if camera_direction.dot(to_position) <= 0:
		return false
		
	# Get screen position
	var screen_position = camera.unproject_position(world_position)
	
	# Check if position is on screen
	var viewport_rect = get_viewport().get_visible_rect()
	return viewport_rect.has_point(screen_position)
