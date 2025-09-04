extends Camera3D

class_name CameraUI

# Ship to follow
var camera_controller: BattleCamera
#@export var _ship: Ship
#@export var ship_movement: ShipMovement
#@export var hp_manager: HitPointsManager  # Add reference to hit points
@export var projectile_speed: float = 800.0 # Realistic speed for naval artillery (m/s)
@export var projectile_drag_coefficient: float = ProjectilePhysicsWithDrag.SHELL_380MM_DRAG_COEFFICIENT # 380mm shell drag


# Target information
var time_to_target: float = 0.0
var distance_to_target: float = 0.0
var aim_position: Vector3 = Vector3.ZERO
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
var locked_target = null
var target_lock_enabled: bool = false

# FPS counter
var fps_label: Label

# Hit point display
var hp_bar: ProgressBar
var hp_label: Label

# Camera angle display
var camera_angle_label: Label

# Add these variables near the top with other variable declarations
var tracked_ships = {} # Dictionary to store ships and their UI elements
var ship_ui_elements = {} # Dictionary to store UI elements for each ship

var minimap: Minimap # Reference to the minimap node

# Weapon selection UI
var weapon_buttons: Array[Button] = []
var weapon_names: Array[String] = ["AP", "HE", "Torpedo"]

func _ready():

	
	# Make sure we have necessary references
	if not camera_controller:
		push_error("ArtilleryCamera requires a _ship node!")
	
	# Set up UI
	_setup_ui()
	
	# Capture mouse
	#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(_delta):
	# Update UI
	_update_ui()
	_update_fps()
	update_ship_ui()  # Add this line to update ship UI elements
	crosshair_container.queue_redraw()

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
	rudder_slider.editable = false # Read-only display
	crosshair_container.add_child(rudder_slider)
	
	# Add throttle slider (vertical)
	throttle_slider = VSlider.new()
	throttle_slider.min_value = -1.0 # Reverse
	throttle_slider.max_value = 4.0 # Full ahead
	throttle_slider.step = 0.1
	throttle_slider.value = 0
	throttle_slider.custom_minimum_size = Vector2(20, 100)
	throttle_slider.editable = false # Read-only display
	crosshair_container.add_child(throttle_slider)

	# Add FPS counter in top right
	fps_label = Label.new()
	fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	fps_label.add_theme_font_size_override("font_size", 16)
	fps_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.0, 1.0)) # Yellow for visibility
	crosshair_container.add_child(fps_label)
	
	# Add camera angle display
	camera_angle_label = Label.new()
	camera_angle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	camera_angle_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	camera_angle_label.add_theme_font_size_override("font_size", 14)
	camera_angle_label.add_theme_color_override("font_color", Color(0.8, 0.8, 1.0, 1.0)) # Light blue for visibility
	crosshair_container.add_child(camera_angle_label)
	
	# Add hit points bar
	hp_bar = ProgressBar.new()
	hp_bar.custom_minimum_size = Vector2(200, 20)
	hp_bar.value = 100
	hp_bar.show_percentage = false
	hp_bar.modulate = Color(0.2, 0.9, 0.2) # Green color for health
	crosshair_container.add_child(hp_bar)
	
	# Add hit points label overlay
	hp_label = Label.new()
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_label.add_theme_font_size_override("font_size", 14)
	hp_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0)) # White text
	hp_label.text = "100/100"
	crosshair_container.add_child(hp_label)

	minimap = Minimap.new()
	#minimap.minimap_size = Vector2(300, 300)
	ui_canvas.add_child(minimap)
	minimap.register_player_ship(camera_controller._ship)

	await get_tree().process_frame
	minimap.take_map_snapshot(get_viewport())

	# Add weapon selection buttons
	var button_panel = HBoxContainer.new()
	button_panel.position = Vector2(20, get_viewport().get_visible_rect().size.y - 60)
	ui_canvas.add_child(button_panel)
	for i in range(weapon_names.size()):
		var btn = Button.new()
		btn.text = weapon_names[i]
		btn.toggle_mode = true
		btn.button_pressed = i == 0  # Default to Shell 1
		btn.connect("pressed", Callable(self, "_on_weapon_button_pressed").bind(i))
		weapon_buttons.append(btn)
		button_panel.add_child(btn)


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

# func _calculate_target_info(locked_target: Node3D, target_lock_enabled: bool):
# 	# Get the direction the camera is facing
# 	if target_lock_enabled and locked_target and is_instance_valid(locked_target):
# 		var horizontal_rad = aim.rotation.y
# 		var vertical_rad = aim.rotation.x
# 		# var orbit_distance = current_zoom
# 		# var adj = tan(PI / 2.0 + vertical_rad)
# 		var cam_pos_3rd = _ship.global_position + aim.global_position
# 		aim_position = calculate_ground_intersection(
# 			cam_pos_3rd,
# 			horizontal_rad + PI,
# 			vertical_rad
# 		)
			
# 	else:
# 		var aim_direction = - aim.basis.z.normalized()
# 		# Cast a ray to get target position (could be terrain, enemy, etc.)
# 		var ray_length = 200000.0 # 50km range for naval artillery
# 		var space_state = get_world_3d().direct_space_state
# 		var ray_origin = aim.global_position + _ship.global_position
		
# 		var ray_params = PhysicsRayQueryParameters3D.create(
# 			ray_origin,
# 			ray_origin + aim_direction * ray_length,
# 			1, # Set to your proper collision mask
# 			[] # Array of objects to exclude
# 		)
		
# 		var result = space_state.intersect_ray(ray_params)
		
# 		if result:
# 			aim_position = result.position
# 		else:
# 			# No collision, use a point far in the distance
# 			aim_position = ray_origin + aim_direction * ray_length

# 	minimap.aim_point = aim_position
	
	
# 	# Calculate launch vector using our projectile physics
# 	var ship_position = _ship.global_position
# 	var launch_result = ProjectilePhysicsWithDrag.calculate_launch_vector(
# 		ship_position,
# 		aim_position,
# 		projectile_speed,
# 		projectile_drag_coefficient
# 	)
	
# 	# Extract results
# 	var launch_vector = launch_result[0]
# 	time_to_target = launch_result[1]
# 	#max_range_reached = launch_result[2]
# 	max_range_reached = (aim_position - ship_position).length() > _ship.artillery_controller.guns[0].max_range
	
# 	# Calculate distance
# 	distance_to_target = (aim_position - ship_position).length() / 1000.0 # Convert to km

func _update_ui():
	# Update info labels
	time_label.text = "%.1f s" % (time_to_target / 2.0)
	distance_label.text = "%.2f m" % distance_to_target
	
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
	
	if camera_controller._ship.movement_controller is ShipMovement:
		# Get throttle setting
		var throttle_level = camera_controller._ship.movement_controller.throttle_level
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
		var rudder_value = camera_controller._ship.movement_controller.rudder_value
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
	var control_panel_y = viewport_size.y - 180 # Moved up to make room for the control layout
	
	# Position labels
	speed_label.position = Vector2(control_panel_x, control_panel_y)
	throttle_label.position = Vector2(control_panel_x, control_panel_y + 25)
	rudder_label.position = Vector2(control_panel_x, control_panel_y + 50)
	
	# Position sliders in a non-overlapping layout
	# Rudder slider (horizontal) at the bottom
	rudder_slider.position = Vector2(control_panel_x, control_panel_y + 75)
	rudder_slider.custom_minimum_size = Vector2(180, 20)
	
	# Throttle slider (vertical) positioned at the right end of the rudder slider
	throttle_slider.position = Vector2(control_panel_x + 180, control_panel_y - 25) # Position at the right end of rudder slider
	throttle_slider.custom_minimum_size = Vector2(20, 100) # Keep the same height
	
	# Add custom styling to sliders based on values
	if camera_controller._ship is Ship:
		# Set color for rudder slider based on port/starboard
		var rudder_value = rudder_slider.value
		if rudder_value > 0: # Port (left)
			rudder_slider.modulate = Color(1, 0.5, 0.5) # Red tint for port
		elif rudder_value < 0: # Starboard (right)
			rudder_slider.modulate = Color(0.5, 1, 0.5) # Green tint for starboard
		else:
			rudder_slider.modulate = Color(1, 1, 1) # White for center
			
		# Set color for throttle slider based on direction
		var throttle_level = throttle_slider.value
		if throttle_level > 0: # Forward
			throttle_slider.modulate = Color(0.5, 0.8, 1.0) # Blue for forward
		elif throttle_level < 0: # Reverse
			throttle_slider.modulate = Color(1.0, 0.8, 0.5) # Orange for reverse
		else:
			throttle_slider.modulate = Color(1, 1, 1) # White for stop

	# Update hit points display
	if camera_controller._ship.health_controller:
		var current_hp = camera_controller._ship.health_controller.current_hp
		var max_hp = camera_controller._ship.health_controller.max_hp
		var hp_percent = (float(current_hp) / max_hp) * 100.0
		
		# Update progress bar
		hp_bar.value = hp_percent
		hp_label.text = "%d/%d" % [current_hp, max_hp]
		
		# Change color based on health level
		if hp_percent > 60:
			hp_bar.modulate = Color(0.2, 0.9, 0.2) # Green for high health
		elif hp_percent > 30:
			hp_bar.modulate = Color(0.9, 0.9, 0.2) # Yellow for medium health
		else:
			hp_bar.modulate = Color(0.9, 0.2, 0.2) # Red for low health
			
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

	# Update camera angle display
	_update_camera_angle_display()

func _update_fps():
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	
	# Position in top right corner
	# var viewport_size = get_viewport().get_visible_rect().size
	fps_label.size = Vector2(100, 25)
	fps_label.position = Vector2(10, 10)

func _update_camera_angle_display():
	if camera_controller and camera_controller._ship:
		# Get camera forward vector on XZ plane (ignore Y component)
		var camera_forward = -global_transform.basis.z
		var camera_forward_xz = Vector2(camera_forward.x, camera_forward.z).normalized()
		
		# Get ship forward vector on XZ plane
		var ship_forward = -camera_controller._ship.global_transform.basis.z
		var ship_forward_xz = Vector2(ship_forward.x, ship_forward.z).normalized()
		
		# Calculate angle between the vectors
		var angle_rad = camera_forward_xz.angle_to(ship_forward_xz)
		var angle_deg = abs(rad_to_deg(angle_rad))
			
		if angle_deg > 90.0:
			angle_deg = 180.0 - angle_deg

		# Format the angle
		camera_angle_label.text = "Camera: %.1f°" % angle_deg
		
		# Position in top left corner, below FPS
		camera_angle_label.size = Vector2(120, 25)
		camera_angle_label.position = Vector2(10, 40)

# Modify the existing draw function to show locked target indicator
func _on_crosshair_container_draw():
	var viewport_size = get_viewport().get_visible_rect().size
	var screen_center = viewport_size / 2.0
	
	# Crosshair properties
	var crosshair_size = Vector2(2, 15)
	var crosshair_gap = 5.0
	
	# Use red for out of range, green for in range
	var color = Color(0, 1, 0, 0.8) # Default to green
	if max_range_reached:
		color = Color(1, 0, 0, 0.8) # Red for out of range
	
	# Draw standard crosshair
	var top_rect = Rect2(
		screen_center.x - crosshair_size.x / 2,
		screen_center.y - crosshair_size.y - crosshair_gap,
		crosshair_size.x,
		crosshair_size.y
	)
	
	var bottom_rect = Rect2(
		screen_center.x - crosshair_size.x / 2,
		screen_center.y + crosshair_gap,
		crosshair_size.x,
		crosshair_size.y
	)
	
	var left_rect = Rect2(
		screen_center.x - crosshair_size.y - crosshair_gap,
		screen_center.y - crosshair_size.x / 2,
		crosshair_size.y,
		crosshair_size.x
	)
	
	var right_rect = Rect2(
		screen_center.x + crosshair_gap,
		screen_center.y - crosshair_size.x / 2,
		crosshair_size.y,
		crosshair_size.x
	)
	
	crosshair_container.draw_rect(top_rect, color)
	crosshair_container.draw_rect(bottom_rect, color)
	crosshair_container.draw_rect(left_rect, color)
	crosshair_container.draw_rect(right_rect, color)
	
	# Draw target lock indicator when target is locked
	if target_lock_enabled and locked_target and is_instance_valid(locked_target):
		var target_pos = get_viewport().get_camera_3d().unproject_position(locked_target.global_position)
		if is_position_visible_on_screen(locked_target.global_position):
			# Draw diamond around the target
			var diamond_size = 25.0
			var diamond_points = PackedVector2Array([
				Vector2(target_pos.x, target_pos.y - diamond_size),
				Vector2(target_pos.x + diamond_size, target_pos.y),
				Vector2(target_pos.x, target_pos.y + diamond_size),
				Vector2(target_pos.x - diamond_size, target_pos.y),
				Vector2(target_pos.x, target_pos.y - diamond_size)
			])
			
			# Draw lock indicator
			crosshair_container.draw_polyline(diamond_points, Color.WHITE, 2.0, true)
			
			# Draw "LOCKED" text above diamond
			if not is_position_visible_on_screen(locked_target.global_position):
				target_lock_enabled = false
				locked_target = null

func setup_ship_ui(ship):
	if ship == camera_controller._ship or ship in ship_ui_elements:
		return # Skip own ship or already tracked ships
	
	# Create a container for the ship's UI
	var ship_container = Control.new()
	ship_container.visible = false # Start hidden until positioned
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
	ship_hp_bar.modulate = Color(0.2, 0.9, 0.2) # Default green
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
			if ship != camera_controller._ship and ship is Ship:
				tracked_ships[ship] = true
				setup_ship_ui(ship)
				minimap.register_ship(ship)
	
	# minimap.draw_ship_on_minimap(_ship.global_position,_ship.rotation.y, Color.WHITE)
	# 
	# Update each ship's UI
	for ship in tracked_ships.keys():
		if is_instance_valid(ship) and ship in ship_ui_elements and ship is Ship:
			var ui = ship_ui_elements[ship]
			
			# Get ship's HP if it has an HP manager
			var ship_hp_manager = ship.health_controller
			if ship_hp_manager:
				var current_hp = ship_hp_manager.current_hp
				var max_hp = ship_hp_manager.max_hp
				var hp_percent = (float(current_hp) / max_hp) * 100.0
				
					# Determine team color
				var team_color = null
				var my_team_id = -1
				if camera_controller._ship.team:
					var my_team_entity = camera_controller._ship.team
					if my_team_entity.has_method("get_team_info"):
						my_team_id = my_team_entity.get_team_info()["team_id"]
				var ship_team_id = -2
				if ship.team:
					var ship_team_entity = ship.team
					if ship_team_entity.has_method("get_team_info"):
						ship_team_id = ship_team_entity.get_team_info()["team_id"]
				if my_team_id != -1 and ship_team_id != -2:
					if my_team_id == ship_team_id:
						team_color = Color(0.2, 0.9, 1.0) # Teal for same team
						# minimap.draw_ship_on_minimap(ship.global_position,ship.rotation.y, Color(0.2, 0.9, 1.0))
					else:
						team_color = Color(0.9, 0.2, 0.2) # Red for enemy team
						# minimap.draw_ship_on_minimap(ship.global_position,ship.rotation.y, Color(0.9, 0.2, 0.2))
				
				# Update progress bar and label
				ui.hp_bar.value = hp_percent
				ui.hp_label.text = "%d/%d" % [current_hp, max_hp]
				
				# Update color based on health and team
				if team_color:
					ui.hp_bar.modulate = team_color
				else:
					if hp_percent > 60:
						ui.hp_bar.modulate = Color(0.2, 0.9, 0.2) # Green
					elif hp_percent > 30:
						ui.hp_bar.modulate = Color(0.9, 0.9, 0.2) # Yellow
					else:
						ui.hp_bar.modulate = Color(0.9, 0.2, 0.2) # Red
			
			# Position UI above ship in the world
			var ship_position = ship.global_position + Vector3(0, 20, 0) # Add height offset
			var screen_pos = get_viewport().get_camera_3d().unproject_position(ship_position)
			
			# Check if ship is visible on screen
			var ship_visible = is_position_visible_on_screen(ship_position) and ship.visible
			ui.container.visible = ship_visible
			
			if ship_visible:
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
	var camera_direction = - camera.global_transform.basis.z.normalized()
	var to_position = (world_position - camera.global_position).normalized()
	if camera_direction.dot(to_position) <= 0:
		return false
		
	# Get screen position
	var screen_position = camera.unproject_position(world_position)
	
	# Check if position is on screen
	var viewport_rect = get_viewport().get_visible_rect()
	return viewport_rect.has_point(screen_position)
	
func _on_weapon_button_pressed(idx):
	for i in range(weapon_buttons.size()):
		weapon_buttons[i].button_pressed = (i == idx)
	if camera_controller:
		camera_controller._ship.get_node("Modules").get_node("PlayerControl").select_weapon(idx)

func set_weapon_button_pressed(idx: int):
	for i in range(weapon_buttons.size()):
		weapon_buttons[i].button_pressed = (i == idx)
