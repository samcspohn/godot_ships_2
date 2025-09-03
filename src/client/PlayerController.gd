extends Node
class_name PlayerController

var ship: Ship
#var ship_movement: ShipMovement
#var ship_artillery: ShipArtillery
#var hp_manager: HitPointsManager
var _cameraInput: Vector2
@export var playerName: Label
var cam: BattleCamera
var ray: RayCast3D
var guns: Array[Gun] = []
var selected_weapon: int = 0 # 0 = shell1, 1 = shell2, 2 = torpedo

# Mouse control variables
var mouse_captured: bool = true # True when mouse is controlling camera
var targeting_enabled: bool = false # True when mouse can select targets

# Timing variables
var double_click_timer: float = 0.3 # Maximum time between clicks to register as double click
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var last_click_time: float = 0.0 # Track time of last click for double click detection
var is_holding: bool = false # Track if mouse button is being held
var click_count: int = 0 # Track number of clicks for double click detection
var sequential_fire_timer: float = 0.0 # Timer for sequential firing

# Ship control variables
var throttle_level: int = 0 # -1 = reverse, 0 = stop, 1-4 = forward speeds
var target_rudder_value: float = 0.0
var rudder_mode: String = "continuous" # "continuous" or "discrete"
var discrete_rudder_positions: Array = [-1.0, -0.5, 0.0, 0.5, 1.0]
var discrete_rudder_index: int = 2 # Start at 0.0 (middle index)

var view_port_size: Vector2i = Vector2i(0, 0)

# Flag to check if initialization is needed
var needs_initialization: bool = true

func _ready() -> void:
	# Get reference to the ship components
	#ship = get_node("../..") as Ship
	#ship_movement = ship.get_node("ShipMovement")
	#ship_artillery = ship.get_node("ArtilleryController")
	#hp_manager = ship.get_node("HPManager")
	#secondary_controller = ship.get_node_or_null("Secondaries")
	# Initialize secondary controller if it exists
	if multiplayer.is_server():
		set_process(false)
		set_process_input(false)
		set_physics_process(false)
	else:
		# Capture mouse by default for camera control
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		mouse_captured = true

func setup_artillery_camera() -> void:
	cam = load("res://scenes/player_cam.tscn").instantiate()
	cam._ship = ship
	cam.call_deferred("set_angle", ship.global_position.angle_to(-ship.global_transform.basis.z))
	# cam.aim.rotation_degrees_horizontal = ship.global_position.angle_to(ship.global_transform.basis.z)
	#cam.ship_movement = ship_movement
	#cam.hp_manager = hp_manager
	
	if cam is Camera3D:
		cam.current = true
	if guns.size() > 0:
		cam.projectile_speed = guns[0].params.shell.speed
		cam.projectile_drag_coefficient = guns[0].params.shell.drag
	get_tree().root.add_child(cam)
	
	# Get ray from camera
	self.ray = cam.get_child(0)

func setName(_name: String):
	playerName.text = _name

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if mouse_captured:
			_cameraInput = event.relative
	elif event is InputEventMouseButton:
		if not mouse_captured: # Only handle mouse clicks when cursor is released
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					# Mouse target selection with left click
					var camera = get_viewport().get_camera_3d()
					if camera:
						var mouse_pos = get_viewport().get_mouse_position()
						var from = camera.project_ray_origin(mouse_pos)
						var to = from + camera.project_ray_normal(mouse_pos) * 200000
						

						handle_target_selection.rpc_id(1, from, to)
			
		elif mouse_captured: # Handle normal camera-based shooting
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					# Mouse button pressed
					is_holding = true
					sequential_fire_timer = 0.0
					
					# Handle click counting for double click detection
					var current_time = Time.get_ticks_msec() / 1000.0
					if current_time - last_click_time < double_click_timer:
						click_count = 2
						if selected_weapon == 0 or selected_weapon == 1:
							# Use your existing firing logic for guns
							ship.artillery_controller.fire_all_guns.rpc_id(1)
						elif selected_weapon == 2:
							# Use your existing firing logic for torpedos
							if ship.torpedo_launcher:
								ship.torpedo_launcher.fire.rpc_id(1)
						# ship.artillery_controller.fire_all_guns.rpc_id(1)
					else:
						click_count = 1
						if selected_weapon == 0 or selected_weapon == 1:
							# Use your existing firing logic for guns
							ship.artillery_controller.fire_next_ready_gun.rpc_id(1)
						elif selected_weapon == 2:
							# Use your existing firing logic for torpedos
							if ship.torpedo_launcher:
								ship.torpedo_launcher.fire.rpc_id(1)
						# ship.artillery_controller.fire_next_ready_gun.rpc_id(1)
						# handle_single_click()
					
					last_click_time = current_time
				else:
					# Mouse button released
					is_holding = false

	elif event is InputEventKey:
		 # Control key to toggle mouse capture
		if event.keycode == KEY_CTRL:
			if event.pressed:
				# When pressing control, release mouse and center it
				_center_mouse()
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				mouse_captured = false
			else:
				# When releasing control, capture the mouse again
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_captured = true
		if event.keycode == KEY_T:
			if ship.torpedo_launcher:
				ship.torpedo_launcher.fire.rpc_id(1)
		if event.keycode == KEY_1:
			select_weapon(0)
		elif event.keycode == KEY_2:
			select_weapon(1)
		elif event.keycode == KEY_3:
			select_weapon(2)

# Center the mouse cursor on the screen
func _center_mouse():
	var viewport_size = get_viewport().get_visible_rect().size
	var center = viewport_size / 2
	Input.warp_mouse(center)
	#
#func toggle_mouse_capture() -> void:
	#mouse_captured = not mouse_captured
	#if mouse_captured:
		#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	#else:
		#Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func handle_single_click() -> void:
	if guns.size() > 0:
		for i in range(guns.size()):
			if guns[i].reload >= 1.0:
				ship.artillery_controller.fire_gun.rpc_id(1, i)
				break

@rpc("any_peer", "call_remote", "reliable")
func handle_target_selection(from: Vector3, to: Vector3) -> void:
	print("select target")
	# This uses the mouse cursor position for targeting
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.collision_mask = 1 << 1 | 1 << 2
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var result = space_state.intersect_ray(query)
	
	if result:
		var collider = result.collider
		var target_ship = get_ship_from_collider(collider)
		if target_ship and target_ship != ship && target_ship.health_controller.current_hp > 0.0: # Don't target self
			select_target_ship(target_ship)

func get_ship_from_collider(collider: Object) -> Ship:
	# If the collider itself is a ship
	if collider is Ship:
		return collider
	
	# Check if the collider is part of a ship
	var parent = collider.get_parent()
	while parent:
		if parent is Ship:
			return parent
		parent = parent.get_parent()
	
	return null

func select_target_ship(target_ship: Ship) -> void:
	for secondary_controller in ship.secondary_controllers:
		# Set the target in the secondary controller
		secondary_controller.target = target_ship
		print("Selected target: " + target_ship.name)
		
		# Optional: Add a visual indicator for the selected target
		show_target_indicator(target_ship)
	# else:
	# 	print("Warning: secondary_controller not initialized")
		
func show_target_indicator(_target_ship: Ship) -> void:
	# You can implement visual feedback here
	# For example, create a temporary effect or UI element
	# showing which ship is targeted
	pass

func _process(dt: float) -> void:
	# Check if we need to initialize guns - do it only once
	if needs_initialization:
		needs_initialization = false
		
		# Check if guns are available in ShipArtillery
		if ship.artillery_controller.guns.size() > 0:
			# Copy guns from ship to local array
			guns = ship.artillery_controller.guns
			
			# Setup artillery camera
			setup_artillery_camera()
			
			print("Successfully initialized player guns: ", guns.size())
		else:
			print("Warning: No guns found in ship. This might be an initialization order issue.")
			# Try again next frame if no guns found
			needs_initialization = true
			return # Skip processing until initialized
	
	if guns.size() > 0:
		cam.projectile_speed = guns[0].params.shell.speed
		cam.projectile_drag_coefficient = guns[0].params.shell.drag
		
	# Handle double click timer
	if click_count == 1:
		if Time.get_ticks_msec() / 1000.0 - last_click_time > double_click_timer:
			# Reset click count if double click timer expired
			click_count = 0
	
	# Handle sequential firing when holding
	if is_holding:
		if selected_weapon == 0 or selected_weapon == 1:
			sequential_fire_timer += dt
			var reload = guns[0].params.reload_time
			var min_reload = reload / guns.size() - 0.01
			var adjusted_sequential_fire_delay = min(sequential_fire_delay, min_reload)
			while sequential_fire_timer >= adjusted_sequential_fire_delay:
				sequential_fire_timer -= adjusted_sequential_fire_delay
				ship.artillery_controller.fire_next_ready_gun.rpc_id(1)
		elif selected_weapon == 2:
			# Use your existing firing logic for torpedos
			if ship.torpedo_launcher:
				ship.torpedo_launcher.fire.rpc_id(1)
	
	# Update UI layout if viewport size changes
	if get_viewport().size != view_port_size:
		view_port_size = get_viewport().size
		
	# Handle player input and send to server
	process_player_input()

func process_player_input() -> void:
	# Handle throttle input
	if Input.is_action_just_pressed("move_forward"): # W key
		throttle_level = min(throttle_level + 1, 4) # Max is 4 (full speed)
	elif Input.is_action_just_pressed("move_back"): # S key
		throttle_level = max(throttle_level - 1, -1) # Min is -1 (reverse)
	
	# Handle discrete rudder input with Q and E
	if Input.is_action_just_pressed("ui_q"): # Q key
		rudder_mode = "discrete"
		discrete_rudder_index = max(discrete_rudder_index - 1, 0)
		target_rudder_value = discrete_rudder_positions[discrete_rudder_index]
	elif Input.is_action_just_pressed("ui_e"): # E key
		rudder_mode = "discrete"
		discrete_rudder_index = min(discrete_rudder_index + 1, discrete_rudder_positions.size() - 1)
		target_rudder_value = discrete_rudder_positions[discrete_rudder_index]
	
	# Handle continuous rudder input with A and D
	if Input.is_action_pressed("move_left"): # A key
		rudder_mode = "continuous"
		target_rudder_value = -1.0
		discrete_rudder_index = 2
	elif Input.is_action_pressed("move_right"): # D key
		rudder_mode = "continuous"
		target_rudder_value = 1.0
		discrete_rudder_index = 2
	elif rudder_mode == "continuous":
		target_rudder_value = 0.0
	
	# Create movement input array
	var movement_input = [float(throttle_level), target_rudder_value]
	
	# Get aiming point from ray
	#var aim_point: Vector3
	#if ray.is_colliding():
		#aim_point = ray.get_collision_point()
	#else:
		#aim_point = ray.global_position + Vector3(ray.global_basis.z.x, 0, ray.global_basis.z.z).normalized() * -50000
	
	# Send separated inputs to server
	send_movement_input.rpc_id(1, movement_input)
	send_aim_input.rpc_id(1, cam.aim_position)
	
	#print(cam.aim_position)
	# BattleCamera.draw_debug_sphere(get_tree().root, cam.aim_position, 5, Color(1, 0.5, 0), 1.0 / 61.0)

@rpc("any_peer", "call_remote", "reliable")
func send_movement_input(movement_input: Array) -> void:
	if multiplayer.is_server():
		# Forward movement input to ship movement controller
		ship.movement_controller.set_movement_input(movement_input)

@rpc("any_peer", "call_remote", "reliable")
func send_aim_input(aim_point: Vector3) -> void:
	if multiplayer.is_server():
		# Forward aim input to ship artillery controller
		ship.artillery_controller.set_aim_input(aim_point)

func select_weapon(idx: int) -> void:
	selected_weapon = idx
	if cam:
		cam.ui.set_weapon_button_pressed(idx)
	if idx == 0 or idx == 1:
		ship.artillery_controller.select_shell.rpc_id(1, idx)
	print("Selected weapon: %d" % idx)

# func fire_selected_weapon() -> void:
# 	if selected_weapon == 0:
# 		# Fire shell1 from all guns
# 		if guns.size() > 0:
# 			for i in range(guns.size()):
# 				if guns[i].reload >= 1.0 and guns[i].can_fire:
# 					ship.artillery_controller.fire_gun.rpc_id(1, i)
# 	elif selected_weapon == 1:
# 		# Fire shell2 from all guns (assume shell2 logic is handled in Gun)
# 		if guns.size() > 0:
# 			for i in range(guns.size()):
# 				if guns[i].reload >= 1.0 and guns[i].can_fire:
# 					guns[i].params.shell = guns[i].params.shell2
# 					ship.artillery_controller.fire_gun.rpc_id(1, i)
# 	elif selected_weapon == 2:
# 		# Fire torpedo if available
# 		if ship.torpedo_launcher and ship.torpedo_launcher.reload >= 1.0 and ship.torpedo_launcher.can_fire:
# 			ship.torpedo_launcher.fire.rpc_id(1)
