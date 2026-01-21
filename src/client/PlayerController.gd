extends Node
class_name PlayerController

var ship: Ship
#var ship_movement: ShipMovement
#var ship_artillery: ArtilleryController
#var hp_manager: HPManager
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

# Throttle timing variables
var throttle_timer: float = 0.0
var throttle_repeat_interval: float = 0.25 # Throttle adjustment every 0.25 seconds

var view_port_size: Vector2i = Vector2i(0, 0)

# Flag to check if initialization is needed
var needs_initialization: bool = true

# Pending target selection for physics thread
var _pending_target_selection: Variant = null

var current_weapon_controller: Node = null

func _ready() -> void:
	# Get reference to the ship components
	#ship = get_node("../..") as Ship
	#ship_movement = ship.get_node("ShipMovement")
	#ship_artillery = ship.get_node("ArtilleryController")
	#hp_manager = ship.get_node("HPManager")
	#secondary_controller = ship.get_node_or_null("Secondaries")
	# Initialize secondary controller if it exists
	if _Utils.authority():
		set_process(false)
		set_process_input(false)
		set_physics_process(false)

		# await get_tree().process_frame
		# ship.add_static_mod(secondary_upgrade)

	else:
		# Capture mouse by default for camera control
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		mouse_captured = true
	set_controller.call_deferred()

func set_controller():
	current_weapon_controller = ship.artillery_controller



# func secondary_upgrade(_ship: Ship) -> void:
# 	# Implement secondary upgrade logic here
# 	# For example, you might want to increase the range and reload time of secondary guns
# 	for c in _ship.secondary_controllers:
# 		c.params.static_mod._range *= 2.0
# 		c.params.static_mod.reload_time *= 0.6

#func apply_buff():
	#for c in ship.secondary_controllers:
		#c._my_gun_params._range *= 2.0
		#c._my_gun_params.reload_time *= 0.6

func setup_artillery_camera() -> void:
	cam = load("res://src/camera/player_cam.tscn").instantiate()
	cam._ship = ship
	cam.player_controller = self

	if cam is Camera3D:
		cam.current = true
	if guns.size() > 0:
		cam.projectile_speed = ship.artillery_controller.get_shell_params().speed
		cam.projectile_drag_coefficient = ship.artillery_controller.get_shell_params().drag
	get_tree().root.add_child(cam)
	# cam.physics_interpolation_mode = PhysicsInterpolationMode.PHYSICS_INTERPOLATION_MODE_OFF
	cam.call_deferred("set_angle", rad_to_deg(ship.global_rotation.y))

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
					# Mouse target selection with left click - queue for physics thread
					_pending_target_selection = get_viewport().get_mouse_position()

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
						# if selected_weapon == 0 or selected_weapon == 1:
						# 	# Use your existing firing logic for guns
						# 	ship.artillery_controller.fire_all.rpc_id(1)
						# elif selected_weapon == 2:
						# 	# Use your existing firing logic for torpedos
						# 	if ship.torpedo_controller:
						# 		ship.torpedo_controller.fire_all.rpc_id(1)
						current_weapon_controller.fire_all.rpc_id(1)
					else:
						click_count = 1
						# if selected_weapon == 0 or selected_weapon == 1:
						# 	# Use your existing firing logic for guns
						# 	ship.artillery_controller.fire_next_ready.rpc_id(1)
						# elif selected_weapon == 2:
						# 	# Use your existing firing logic for torpedos
						# 	if ship.torpedo_controller:
						# 		ship.torpedo_controller.fire_next_ready.rpc_id(1)
						current_weapon_controller.fire_next_ready.rpc_id(1)

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
		# if event.keycode == KEY_X:
		# 	# Clear secondary target
		# 	clear_secondary_target()
		if event.keycode == KEY_1:
			select_weapon(0)
		elif event.keycode == KEY_2:
			select_weapon(1)
		elif event.keycode == KEY_3:
			select_weapon(2)
		elif event.keycode == KEY_4:
			select_weapon(3)
		elif event.keycode == KEY_5:
			select_weapon(4)

			# Consumable hotkeys
	if event.is_action_pressed("consumable_1"):
		ship.consumable_manager.use_consumable_rpc.rpc_id(1, 0)
	elif event.is_action_pressed("consumable_2"):
		ship.consumable_manager.use_consumable_rpc.rpc_id(1, 1)
	elif event.is_action_pressed("consumable_3"):
		ship.consumable_manager.use_consumable_rpc.rpc_id(1, 2)

	if event.is_action_pressed("toggle_secondaries"):
		c_toggle_secondaries_enabled.rpc_id(1)

# Center the mouse cursor on the screen
func _center_mouse():
	var viewport_size = get_viewport().get_visible_rect().size
	var center = viewport_size / 2
	Input.warp_mouse(center)

func select_target_at_mouse_position(mouse_pos: Vector2) -> void:
	"""Select a ship target at the given mouse position (client-side selection)"""
	if not cam:
		print("No camera available for target selection")
		return

	var closest_ship: Ship = null
	var closest_distance: float = INF
	var selection_radius: float = 80.0  # Radius in pixels for ship selection

	# Get all ships from the server's player list
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	if not server:
		print("No server found for target selection")
		return

	# Calculate offset point on the ship for targeting
	var space_state = get_tree().root.get_world_3d().direct_space_state
	# Cast a ray from camera through mouse position to find intersection with ship
	var cam_ray = PhysicsRayQueryParameters3D.new()
	var ray_origin = cam.project_ray_origin(mouse_pos)
	var ray_direction = cam.project_ray_normal(mouse_pos)
	cam_ray.from = ray_origin
	cam_ray.to = ray_origin + ray_direction * 100000.0
	cam_ray.exclude = [ship.get_rid()]
	cam_ray.collision_mask = (1 << 1) # | (1 << 2)  # Layer 2 = armor parts, Layer 3 = ships
	var offset_point: Vector3 = Vector3.ZERO
	var result = space_state.intersect_ray(cam_ray)
	if result:
		offset_point = result.position
		var collider = result.collider
		# Check if we hit a Ship directly or an ArmorPart (which has a ship reference)
		if collider is Ship:
			closest_ship = collider
		elif collider is ArmorPart:
			closest_ship = collider.ship

		if closest_ship:
			print("Direct ray hit ship: ", closest_ship.name)
			offset_point = closest_ship.to_local(offset_point)
			# offset_point.x = 0
			set_target_ship.rpc_id(1, closest_ship.get_path(), offset_point)
			return

	# Check each ship to find the closest one to mouse cursor
	for pid in server.players:
		var potential_ship: Ship = server.players[pid][0]
		if not (potential_ship is Ship):
			continue
		if potential_ship == ship:  # Don't target self
			continue
		if potential_ship.health_controller.current_hp <= 0.0:  # Don't target dead ships
			continue
		if potential_ship.team.team_id == ship.team.team_id:  # Don't target friendly ships
			continue
		if not potential_ship.visible_to_enemy:  # Don't target invisible ships
			continue

		# Get ship's screen position using the camera
		var ship_screen_pos = cam.unproject_position(potential_ship.global_position)
		var distance_to_cursor = mouse_pos.distance_to(ship_screen_pos)

		# Debug output
		# print("Ship: ", potential_ship.name, " Screen: ", ship_screen_pos, " Distance: ", distance_to_cursor)

		# Check if this ship is closer to the cursor and within selection radius
		if distance_to_cursor <= selection_radius and distance_to_cursor < closest_distance:
			closest_ship = potential_ship
			closest_distance = distance_to_cursor

	# Send the selected target to the server
	if closest_ship:
		print("Client selected ship: ", closest_ship.name, " at distance: ", closest_distance)
		set_target_ship.rpc_id(1, closest_ship.get_path(), Vector3.ZERO)
	else:
		print("No ship found within selection radius of ", selection_radius, " pixels")

func handle_single_click() -> void:
	ship.artillery_controller.fire_next_ready_gun.rpc_id(1)
	# if guns.size() > 0:
	# 	for i in range(guns.size()):
	# 		if guns[i].reload >= 1.0:
	# 			ship.artillery_controller.fire_gun.rpc_id(1, i)
	# 			break

@rpc("any_peer", "call_remote", "reliable")
func set_target_ship(ship_path: NodePath, offset: Vector3) -> void:
	"""Server-side RPC to set the target ship"""
	if not _Utils.authority():
		return

	var target_ship = get_node_or_null(ship_path)
	if target_ship and target_ship is Ship:
		print("Server setting target ship: ", target_ship.name)
		select_target_ship(target_ship, offset)
		#notify the calling client to set the target visually
		c_set_target_ship.rpc_id(multiplayer.get_remote_sender_id(), ship_path, offset)
	else:
		print("Invalid ship path received: ", ship_path)

@rpc("authority", "call_remote", "reliable")
func c_set_target_ship(ship_path: NodePath, offset: Vector3) -> void:
	"""Client-side RPC to set the target ship"""
	if not _Utils.authority():
		var target_ship = get_node_or_null(ship_path)
		if target_ship and target_ship is Ship:
			print("Client setting target ship: ", target_ship.name)
			select_target_ship(target_ship, offset)
			show_target_indicator(target_ship)
		else:
			print("Invalid ship path received: ", ship_path)


func select_target_ship(target_ship: Ship, offset: Vector3) -> void:
	if ship.secondary_controller.target == target_ship:
		ship.secondary_controller.target_offset = offset
		ship.secondary_controller.target_offset.x = 0.0
	else:
		ship.secondary_controller.target_offset = Vector3.ZERO

	ship.secondary_controller.target = target_ship
	#for secondary_controller in ship.secondary_controller.target:
		## Set the target in the secondary controller
		#secondary_controller.target = target_ship
		#print("Selected target: " + target_ship.name)
		#
		# Add a visual indicator for the selected target
	# else:
	# 	print("Warning: secondary_controller not initialized")

func show_target_indicator(target_ship: Ship) -> void:
	# Update the UI to show the target indicator
	if cam and cam.ui:
		cam.ui.set_secondary_target(target_ship)
		print("showing secondary target indicator")
	else:
		print("Warning: cam.ui not available for target indicator")

func clear_secondary_target() -> void:
	"""Clear the secondary target for all secondary controllers"""
	#for secondary_controller in ship.secondary_controllers:
		#secondary_controller.target = null
		#print("Cleared secondary target")
	ship.secondary_controller.target = null

	# Update the UI to clear the target indicator
	if cam and cam.ui:
		cam.ui.clear_secondary_target()
	else:
		print("Warning: cam.ui not available for clearing target indicator")

@rpc("any_peer", "call_remote", "reliable")
func c_toggle_secondaries_enabled() -> void:
	if not _Utils.authority():
		return
	"""Client tell server to toggle secondaries enabled state"""
	ship.secondary_controller.enabled = not ship.secondary_controller.enabled
	print("Secondaries enabled set to: ", ship.secondary_controller.enabled)
	toggle_secondaries_enabled.rpc_id(multiplayer.get_remote_sender_id(), ship.secondary_controller.enabled)

@rpc("authority", "call_remote", "reliable")
func toggle_secondaries_enabled(enabled: bool) -> void:
	"""Server-side function to notify caller of state"""
	ship.secondary_controller.enabled = enabled

func _physics_process(_delta: float) -> void:
	if _pending_target_selection != null:
		select_target_at_mouse_position(_pending_target_selection)
		_pending_target_selection = null

func _process(dt: float) -> void:
	# Check if we need to initialize guns - do it only once
	if needs_initialization:
		needs_initialization = false

		# Check if guns are available in ArtilleryController
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
		cam.projectile_speed = ship.artillery_controller.get_shell_params().speed
		cam.projectile_drag_coefficient = ship.artillery_controller.get_shell_params().drag

	# Handle double click timer
	if click_count == 1:
		if Time.get_ticks_msec() / 1000.0 - last_click_time > double_click_timer:
			# Reset click count if double click timer expired
			click_count = 0

	# Handle sequential firing when holding
	if is_holding:
		sequential_fire_timer += dt
		var reload = current_weapon_controller.get_params().reload_time
		var min_reload = reload / guns.size() - 0.01
		var adjusted_sequential_fire_delay = min(sequential_fire_delay, min_reload)
		while sequential_fire_timer >= adjusted_sequential_fire_delay:
			sequential_fire_timer -= adjusted_sequential_fire_delay
			current_weapon_controller.fire_next_ready.rpc_id(1)

	# Update UI layout if viewport size changes
	if get_viewport().size != view_port_size:
		view_port_size = get_viewport().size

	# Handle player input and send to server
	process_player_input()

	# # Show floating damage for the ship
	# if ship.stats.damage_events.size() > 0:
	# 	for damage_event in ship.stats.damage_events:
	# 		if cam.ui:
	# 			cam.ui.create_floating_damage(damage_event.damage, damage_event.position)
	# 		else:
	# 			print("Warning: cam.ui not available for floating damage")
	# 	# Note: damage_events are now cleared by the camera UI after processing hit counters

class InputData:
	var throttle_level: int
	var rudder_value: float
	var aim_position: Vector3
	var frustum_planes: Array[Plane]

func process_player_input() -> void:
	# Handle throttle input with continuous adjustment
	var throttle_input_active = false

	if Input.is_action_pressed("move_forward"): # W key held
		throttle_input_active = true
		throttle_timer += get_process_delta_time()

		# Immediate response on first press
		if Input.is_action_just_pressed("move_forward"):
			throttle_level = min(throttle_level + 1, 4) # Max is 4 (full speed)
			throttle_timer = 0.0
		# Continuous adjustment every 0.5 seconds
		elif throttle_timer >= throttle_repeat_interval:
			throttle_level = min(throttle_level + 1, 4) # Max is 4 (full speed)
			throttle_timer = 0.0

	elif Input.is_action_pressed("move_back"): # S key held
		throttle_input_active = true
		throttle_timer += get_process_delta_time()

		# Immediate response on first press
		if Input.is_action_just_pressed("move_back"):
			throttle_level = max(throttle_level - 1, -1) # Min is -1 (reverse)
			throttle_timer = 0.0
		# Continuous adjustment every 0.5 seconds
		elif throttle_timer >= throttle_repeat_interval:
			throttle_level = max(throttle_level - 1, -1) # Min is -1 (reverse)
			throttle_timer = 0.0

	# Reset timer when no throttle input is active
	if not throttle_input_active:
		throttle_timer = 0.0

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

	if Input.is_key_pressed(KEY_K):
		kill.rpc_id(1)
	# Create movement input array
	var input_data = InputData.new()
	input_data.throttle_level = throttle_level
	input_data.rudder_value = target_rudder_value
	input_data.aim_position = cam.aim_position
	input_data.frustum_planes = cam.get_frustum()

	# Get aiming point from ray
	#var aim_point: Vector3
	#if ray.is_colliding():
		#aim_point = ray.get_collision_point()
	#else:
		#aim_point = ray.global_position + Vector3(ray.global_basis.z.x, 0, ray.global_basis.z.z).normalized() * -50000

	# Send separated inputs to server

	# if NetworkManager.is_connected:
	if _Utils.is_multiplayer_active():
		send_input.rpc_id(1, input_data.throttle_level,
								input_data.rudder_value,
								input_data.aim_position,
								input_data.frustum_planes,
								current_weapon_controller == ship.secondary_controller)
	# send_aim_input.rpc_id(1, cam.aim_position)

	#print(cam.aim_position)
	# BattleCamera.draw_debug_sphere(get_tree().root, cam.aim_position, 5, Color(1, 0.5, 0), 1.0 / 61.0)

@rpc("any_peer")
func kill():
	ship.health_controller.apply_damage(10000000,10000000, ship.citadel, false, 1)

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func send_input(_throttle_level: int, rudder_value: float, aim_position: Vector3, frustum_planes: Array[Plane], manual_sec: bool) -> void:
	if _Utils.authority():
		# Forward movement input to ship movement controller
		ship.movement_controller.set_movement_input([_throttle_level, rudder_value])
		ship.artillery_controller.set_aim_input(aim_position)
		if ship.torpedo_controller:
			ship.torpedo_controller.set_aim_input(aim_position)
		if ship.secondary_controller:
			if manual_sec:
				ship.secondary_controller.set_aim_input(aim_position)
			else :
				ship.secondary_controller.set_aim_input(null) # Disable manual aiming for secondaries
		ship.frustum_planes = frustum_planes

func select_weapon(idx: int) -> void:
	selected_weapon = idx
	if cam:
		cam.ui.set_weapon_button_pressed(idx)
	if idx == 0 or idx == 1:
		ship.artillery_controller.select_shell(idx)
		ship.artillery_controller.select_shell.rpc_id(1, idx)
		current_weapon_controller = ship.artillery_controller
	elif idx == 2:
		if ship.torpedo_controller:
			# ship.torpedo_controller.select_torpedo.rpc_id(1)
			current_weapon_controller = ship.torpedo_controller
	elif idx == 3 or idx == 4:
		ship.secondary_controller.select_shell(idx - 3)
		ship.secondary_controller.select_shell.rpc_id(1, idx - 3)
		current_weapon_controller = ship.secondary_controller
	print("Selected weapon: %d" % idx)
