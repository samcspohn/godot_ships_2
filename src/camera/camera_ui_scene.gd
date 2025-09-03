extends CanvasLayer

class_name CameraUIScene

# Camera controller reference
var camera_controller: BattleCamera

# Properties that BattleCamera sets directly - these need to match the interface
var time_to_target: float = 0.0 : set = set_time_to_target
var distance_to_target: float = 0.0 : set = set_distance_to_target
var aim_position: Vector3 = Vector3.ZERO : set = set_aim_position
var max_range_reached: bool = false
var ship_speed: float = 0.0 : set = set_ship_speed
var locked_target = null : set = set_locked_target
var target_lock_enabled: bool = false : set = set_target_lock_enabled

# UI node references - these will be populated from the scene
@onready var crosshair_container: Control = $MainContainer/CrosshairContainer
@onready var time_label: Label = $MainContainer/CrosshairContainer/TargetInfo/TimeLabel
@onready var distance_label: Label = $MainContainer/CrosshairContainer/TargetInfo/DistanceLabel

@onready var fps_label: Label = $MainContainer/TopLeftPanel/FPSLabel
@onready var camera_angle_label: Label = $MainContainer/TopLeftPanel/CameraAngleLabel

@onready var speed_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/SpeedLabel
@onready var throttle_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/ThrottleLabel
@onready var rudder_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/RudderLabel
@onready var rudder_slider: HSlider = $MainContainer/BottomLeftPanel/RudderSlider
@onready var throttle_slider: VSlider = $MainContainer/BottomLeftPanel/HBoxContainer/ThrottleSlider

@onready var hp_bar: ProgressBar = $MainContainer/BottomCenterPanel/HPContainer/HPBar
@onready var hp_label: Label = $MainContainer/BottomCenterPanel/HPContainer/HPBar/HPLabel

@onready var gun_reload_container: HBoxContainer = $MainContainer/BottomCenterPanel/HPContainer/GunReloadContainer
@onready var reload_bar_template: ProgressBar = $MainContainer/BottomCenterPanel/HPContainer/GunReloadContainer/ReloadBarTemplate

@onready var bottom_right_panel: Control = $MainContainer/BottomRightPanel

@onready var ship_ui_templates: Control = $MainContainer/ShipUITemplates
@onready var enemy_ship_template: Control = $MainContainer/ShipUITemplates/EnemyShipTemplate
@onready var friendly_ship_template: Control = $MainContainer/ShipUITemplates/FriendlyShipTemplate

@onready var weapon_buttons: Array[Button] = [
	$MainContainer/BottomCenterPanel/WeaponPanel/Shell1Button,
	$MainContainer/BottomCenterPanel/WeaponPanel/Shell2Button,
	$MainContainer/BottomCenterPanel/WeaponPanel/TorpedoButton
]

# Gun reload tracking
var gun_reload_bars: Array[ProgressBar] = []
var guns: Array[Gun] = []

# Minimap
var minimap: Minimap

# Ship tracking
var tracked_ships = {}
var ship_ui_elements = {}
var last_ship_search_time: float = 0.0
var ship_search_interval: float = 2.0  # Search for new ships every 2 seconds

func recurs_set_vis(n: Node):
	if n is CanvasItem:
		n.visibility_layer = 1 << 1
	for child in n.get_children():
		recurs_set_vis(child)

func _ready():
	# Connect weapon button signals
	for i in range(weapon_buttons.size()):
		weapon_buttons[i].connect("pressed", _on_weapon_button_pressed.bind(i))
	
	# Connect crosshair drawing
	crosshair_container.connect("draw", _on_crosshair_container_draw)
	
	# Setup minimap in the bottom right panel with automatic anchoring
	minimap = Minimap.new()
	minimap.set_anchors_preset(Control.PRESET_TOP_LEFT)
	minimap.position = Vector2(0, 0)  # Position at top-left of the panel
	bottom_right_panel.add_child(minimap)
	
	# Hide ship UI templates (they're visible in editor for design purposes)
	ship_ui_templates.visible = false
	
	# Setup gun reload bars (will be called again when camera_controller is set)
	if camera_controller:
		setup_gun_reload_bars()

func initialize_for_ship():
	# Call this after camera_controller is set and ship is available
	if camera_controller and camera_controller._ship:
		minimap.register_player_ship(camera_controller._ship)
		await get_tree().process_frame
		minimap.take_map_snapshot(get_viewport())
		
		# Force an initial search for other ships
		update_ship_ui()

func _process(_delta):
	if not camera_controller:
		return
		
	_update_ui()
	_update_fps()
	_update_camera_angle_display()
	update_ship_ui()
	update_gun_reload_bars()
	crosshair_container.queue_redraw()

func _update_ui():
	# Time and distance are updated by setters, so we only need to update ship-specific UI here
	
	# Update ship status
	speed_label.text = "Speed: %.1f knots" % ship_speed
	
	if camera_controller._ship.movement_controller is ShipMovement:
		# Update throttle display
		var throttle_level = camera_controller._ship.movement_controller.throttle_level
		var throttle_display = ""
		
		match throttle_level:
			-1: throttle_display = "Reverse"
			0: throttle_display = "Stop"
			1: throttle_display = "1/4"
			2: throttle_display = "1/2"
			3: throttle_display = "3/4"
			4: throttle_display = "Full"
		
		throttle_label.text = "Throttle: " + throttle_display
		throttle_slider.value = throttle_level
		
		# Update rudder display
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
		
		rudder_label.text = "Rudder: " + rudder_display
		rudder_slider.value = rudder_value
		
		# Color sliders based on values
		if rudder_value > 0: # Port (left)
			rudder_slider.modulate = Color(1, 0.5, 0.5) # Red tint for port
		elif rudder_value < 0: # Starboard (right)
			rudder_slider.modulate = Color(0.5, 1, 0.5) # Green tint for starboard
		else:
			rudder_slider.modulate = Color(1, 1, 1) # White for center
			
		# Throttle slider color
		if throttle_level > 0: # Forward
			throttle_slider.modulate = Color(0.5, 0.8, 1.0) # Blue for forward
		elif throttle_level < 0: # Reverse
			throttle_slider.modulate = Color(1.0, 0.8, 0.5) # Orange for reverse
		else:
			throttle_slider.modulate = Color(1, 1, 1) # White for stop

	# Update HP display
	if camera_controller._ship.health_controller:
		var current_hp = camera_controller._ship.health_controller.current_hp
		var max_hp = camera_controller._ship.health_controller.max_hp
		var hp_percent = (float(current_hp) / max_hp) * 100.0
		
		hp_bar.value = hp_percent
		hp_label.text = "%d/%d" % [current_hp, max_hp]
		
		# Change HP bar color based on health level
		if hp_percent > 75:
			hp_bar.modulate = Color(0.2, 0.9, 0.2) # Green
		elif hp_percent > 50:
			hp_bar.modulate = Color(1.0, 1.0, 0.2) # Yellow
		elif hp_percent > 25:
			hp_bar.modulate = Color(1.0, 0.6, 0.2) # Orange
		else:
			hp_bar.modulate = Color(0.9, 0.2, 0.2) # Red

func _update_fps():
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

func _update_camera_angle_display():
	if camera_controller and camera_controller._ship:
		# Get camera forward vector on XZ plane (ignore Y component)
		var camera_forward = -camera_controller.global_transform.basis.z
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


func _on_crosshair_container_draw():
	# Draw locked target indicator
	if target_lock_enabled and locked_target and is_instance_valid(locked_target):
		var target_screen_pos = camera_controller.unproject_position(locked_target.global_position)
		var crosshair_pos = crosshair_container.global_position + crosshair_container.size / 2.0
		
		# Draw line to locked target if it's visible
		if is_position_visible_on_screen(locked_target.global_position):
			var relative_target_pos = target_screen_pos - crosshair_pos
			crosshair_container.draw_line(Vector2.ZERO, relative_target_pos, Color(1, 0, 0, 0.8), 2.0)
			crosshair_container.draw_circle(relative_target_pos, 10, Color(1, 0, 0, 0.6), false, 2.0)

func setup_ship_ui(ship):
	if ship == camera_controller._ship or ship in ship_ui_elements:
		return # Skip own ship or already tracked ships
	
	# Determine if ship is friendly or enemy
	var is_enemy = true
	var my_team_id = -1
	var ship_team_id = -2
	
	if camera_controller._ship.team:
		var my_team_entity = camera_controller._ship.team
		if my_team_entity.has_method("get_team_info"):
			my_team_id = my_team_entity.get_team_info()["team_id"]
	
	if ship.team:
		var ship_team_entity = ship.team
		if ship_team_entity.has_method("get_team_info"):
			ship_team_id = ship_team_entity.get_team_info()["team_id"]
	
	if my_team_id != -1 and ship_team_id != -2:
		is_enemy = my_team_id != ship_team_id
	
	# Choose the appropriate template and duplicate it
	var template = enemy_ship_template if is_enemy else friendly_ship_template
	var ship_container = template.duplicate()
	ship_container.visible = false # Start hidden until positioned
	
	# Add to the main canvas layer instead of crosshair container
	add_child(ship_container)
	
	# Get references to the duplicated UI elements
	var name_label: Label
	var ship_hp_bar: ProgressBar
	var ship_hp_label: Label
	
	if is_enemy:
		name_label = ship_container.get_node("EnemyNameLabel")
		ship_hp_bar = ship_container.get_node("EnemyHPBar")
		ship_hp_label = ship_hp_bar.get_node("EnemyHPLabel")
	else:
		name_label = ship_container.get_node("FriendlyNameLabel")
		ship_hp_bar = ship_container.get_node("FriendlyHPBar")
		ship_hp_label = ship_hp_bar.get_node("FriendlyHPLabel")
	
	# Set the ship name
	name_label.text = ship.name
	
	# Store the UI elements for this ship
	ship_ui_elements[ship] = {
		"container": ship_container,
		"name_label": name_label,
		"hp_bar": ship_hp_bar,
		"hp_label": ship_hp_label
	}

func update_ship_ui():
	# Periodically search for new ships
	var current_time = Time.get_ticks_msec() / 1000.0
	var should_search = tracked_ships.is_empty() or (current_time - last_ship_search_time > ship_search_interval)
	
	if should_search:
		last_ship_search_time = current_time
		
		# Try to find ships in different possible locations
		var ships = []
		var possible_paths = [
			"/root/Server/GameWorld/Players",
			"/root/GameWorld/Players", 
			"/root/Main/Players"
		]
		
		for path in possible_paths:
			var players_node = get_node_or_null(path)
			if players_node:
				ships = players_node.get_children()
				# print("Found ships at: ", path, " - Count: ", ships.size())
				break
		
		if ships.is_empty():
			# Fallback: search for all ships in the scene
			ships = get_tree().get_nodes_in_group("ships")
			if ships.is_empty():
				# Last resort: find all Ship nodes in the tree
				ships = []
				var root = get_tree().root
				_find_ships_recursive(root, ships)
		
		for ship in ships:
			if ship != camera_controller._ship and ship is Ship and not tracked_ships.has(ship):
				tracked_ships[ship] = true
				setup_ship_ui(ship)
				minimap.register_ship(ship)
				print("Registered ship for UI and minimap: ", ship.name, " at position: ", ship.global_position)

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
				
				# Update progress bar and label (colors are already set by template)
				ui.hp_bar.value = hp_percent
				ui.hp_label.text = "%d/%d" % [current_hp, max_hp]
			
			# Position UI above ship in the world
			var ship_position = ship.global_position + Vector3(0, 20, 0) # Add height offset
			var screen_pos = get_viewport().get_camera_3d().unproject_position(ship_position)
			
			# Check if ship is visible on screen
			var ship_visible = is_position_visible_on_screen(ship_position) and ship.visible
			ui.container.visible = ship_visible && (ship as Ship).health_controller.is_alive()
			
			if ship_visible:
				# Position the container above the ship, centered
				var container_size = Vector2(90, 40) # Use template size
				ui.container.position = screen_pos - Vector2(container_size.x / 2, container_size.y)
		else:
			# Ship no longer valid, remove it
			if ship in ship_ui_elements:
				for element in ship_ui_elements[ship].values():
					if is_instance_valid(element):
						element.queue_free()
				ship_ui_elements.erase(ship)
			tracked_ships.erase(ship)

func _find_ships_recursive(node: Node, ships: Array):
	if node is Ship:
		ships.append(node)
	for child in node.get_children():
		_find_ships_recursive(child, ships)

func is_position_visible_on_screen(world_position):
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return false
		
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

func _on_weapon_button_pressed(idx: int):
	# Deselect all other weapon buttons
	for i in range(weapon_buttons.size()):
		weapon_buttons[i].button_pressed = (i == idx)
	
	# Notify camera controller or ship of weapon selection
	if camera_controller:
		# This would typically call a method on the ship or player controller
		print("Selected weapon: %d" % idx)

func set_weapon_button_pressed(idx: int):
	if idx >= 0 and idx < weapon_buttons.size():
		for i in range(weapon_buttons.size()):
			weapon_buttons[i].button_pressed = (i == idx)

# Gun reload bar management
func setup_gun_reload_bars():
	# Clear existing reload bars
	for bar in gun_reload_bars:
		if is_instance_valid(bar):
			bar.queue_free()
	gun_reload_bars.clear()
	reload_bar_template.visible = false

	# Get guns from ship artillery controller
	if camera_controller and camera_controller._ship and camera_controller._ship.artillery_controller:
		guns = camera_controller._ship.artillery_controller.guns
		
		for i in range(guns.size()):
			# Duplicate the template progress bar
			var progress_bar = reload_bar_template.duplicate()
			progress_bar.visible = true
			progress_bar.value = guns[i].reload if guns[i] else 1.0
			
			gun_reload_container.add_child(progress_bar)
			gun_reload_bars.append(progress_bar)

func update_gun_reload_bars():
	# Update reload progress for each gun
	for i in range(min(guns.size(), gun_reload_bars.size())):
		if is_instance_valid(guns[i]) and is_instance_valid(gun_reload_bars[i]):
			gun_reload_bars[i].value = guns[i].reload

# Property setters to automatically update UI when values change
func set_time_to_target(value: float):
	time_to_target = value
	if time_label:
		time_label.text = "%.1f s" % (value / 2.0)

func set_distance_to_target(value: float):
	distance_to_target = value
	if distance_label:
		distance_label.text = "%.2f m" % value

func set_aim_position(value: Vector3):
	aim_position = value
	if minimap:
		minimap.aim_point = value

func set_ship_speed(value: float):
	ship_speed = value
	# Ship speed will be updated in _update_ui() along with other ship status

func set_locked_target(value):
	locked_target = value
	# Trigger redraw of crosshair for target indicators
	if crosshair_container:
		crosshair_container.queue_redraw()

func set_target_lock_enabled(value: bool):
	target_lock_enabled = value
	# Trigger redraw of crosshair for target indicators
	if crosshair_container:
		crosshair_container.queue_redraw()
