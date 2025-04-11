extends Node
class_name PlayerController

var ship: Ship
var ship_movement: ShipMovement
var ship_artillery: ShipArtillery
var secondary_controller: SecondaryController
var hp_manager: HitPointsManager
var _cameraInput: Vector2
@export var playerName: Label
var artillery_cam: ArtilleryCamera
var ray: RayCast3D
var guns: Array[Gun] = []
var gun_reloads: Array[ProgressBar] = []

# Mouse control variables
var mouse_captured: bool = true    # True when mouse is controlling camera
var targeting_enabled: bool = false  # True when mouse can select targets

# Timing variables
var double_click_timer: float = 0.3 # Maximum time between clicks to register as double click
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var last_click_time: float = 0.0 # Track time of last click for double click detection
var is_holding: bool = false # Track if mouse button is being held
var click_count: int = 0 # Track number of clicks for double click detection
var sequential_fire_timer: float = 0.0 # Timer for sequential firing

# Ship control variables
var throttle_level: int = 0  # -1 = reverse, 0 = stop, 1-4 = forward speeds
var target_rudder_value: float = 0.0
var rudder_mode: String = "continuous"  # "continuous" or "discrete"
var discrete_rudder_positions: Array = [-1.0, -0.5, 0.0, 0.5, 1.0]
var discrete_rudder_index: int = 2  # Start at 0.0 (middle index)

var view_port_size: Vector2i = Vector2i(0, 0)

# Flag to check if initialization is needed
var needs_initialization: bool = true

func _ready() -> void:
	# Get reference to the ship components
	ship = get_parent() as Ship
	ship_movement = ship.get_node("ShipMovement")
	ship_artillery = ship.get_node("ArtilleryController")
	hp_manager = ship.get_node("HitPointsManager")
	secondary_controller = ship.get_node_or_null("Secondaries")
	
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
	artillery_cam = load("res://scenes/player_cam.tscn").instantiate()
	artillery_cam.target_ship = ship
	artillery_cam.ship_movement = ship_movement
	artillery_cam.hp_manager = hp_manager
	
	if artillery_cam is Camera3D:
		artillery_cam.current = true
	if guns.size() > 0:
		artillery_cam.projectile_speed = guns[0].params.shell.speed
		artillery_cam.projectile_drag_coefficient = guns[0].params.shell.drag
	get_tree().root.add_child(artillery_cam)
	
	# Get ray from camera
	self.ray = artillery_cam.get_child(0)

func setup_gun_reload_ui() -> void:
	var canvas: CanvasLayer = artillery_cam.get_child(1)
	
	for g in guns:
		var progress_bar: ProgressBar = canvas.get_node("ProgressBar").duplicate()
		progress_bar.visible = true
		progress_bar.show_percentage = false
		progress_bar.max_value = 1.0
		canvas.add_child(progress_bar)
		gun_reloads.append(progress_bar)
	
	update_ui_layout()

func update_ui_layout() -> void:
	var num_guns = guns.size()
	var viewport_size = get_viewport().size
	var y_pos = viewport_size.y * 0.75
	var w = 60
	var spc = 10
	var total_width = (w * num_guns) + (spc * (num_guns - 1))
	
	var start = (viewport_size.x - total_width) / 2.0
	
	for p in range(num_guns):
		var x = start + (p * (w + spc))
		gun_reloads[p].position = Vector2(x, y_pos)
		gun_reloads[p].custom_minimum_size = Vector2(w, 8)
		gun_reloads[p].size = Vector2(w, 8)

func setName(_name: String):
	playerName.text = _name

func _input(event: InputEvent) -> void:
		
	if event is InputEventMouseMotion:
		if mouse_captured:
			_cameraInput = event.relative
	elif event is InputEventMouseButton:
		if not mouse_captured:  # Only handle mouse clicks when cursor is released
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					# Mouse target selection with left click
					var camera = get_viewport().get_camera_3d()
					if camera:
						var mouse_pos = get_viewport().get_mouse_position()
						var from = camera.project_ray_origin(mouse_pos)
						var to = from + camera.project_ray_normal(mouse_pos) * 50000
						

						handle_target_selection.rpc_id(1, from, to)
			
		elif mouse_captured:  # Handle normal camera-based shooting
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					# Mouse button pressed
					is_holding = true
					sequential_fire_timer = 0.0
					
					# Handle click counting for double click detection
					var current_time = Time.get_ticks_msec() / 1000.0
					if current_time - last_click_time < double_click_timer:
						click_count = 2
						ship_artillery.fire_all_guns.rpc_id(1)
					else:
						click_count = 1
						handle_single_click()
					
					last_click_time = current_time
				else:
					# Mouse button released
					is_holding = false
		# Toggle camera mode manually with Tab key
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
				ship_artillery.fire_gun.rpc_id(1, i)
				break

@rpc("any_peer","call_remote", "reliable")
func handle_target_selection(from: Vector3, to: Vector3) -> void:
	print("select target")
	# This uses the mouse cursor position for targeting
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var result = space_state.intersect_ray(query)
	
	if result:
		var collider = result.collider
		var target_ship = get_ship_from_collider(collider)
		if target_ship and target_ship != ship:  # Don't target self
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
	if secondary_controller:
		# Set the target in the secondary controller
		secondary_controller.target = target_ship
		print("Selected target: " + target_ship.name)
		
		# Optional: Add a visual indicator for the selected target
		show_target_indicator(target_ship)
	else:
		print("Warning: secondary_controller not initialized")
		
func show_target_indicator(target_ship: Ship) -> void:
	# You can implement visual feedback here
	# For example, create a temporary effect or UI element
	# showing which ship is targeted
	pass

func _process(dt: float) -> void:
	# Check if we need to initialize guns - do it only once
	if needs_initialization:
		needs_initialization = false
		
		# Check if guns are available in ShipArtillery
		if ship_artillery.guns.size() > 0:
			# Copy guns from ship to local array
			guns = ship_artillery.guns
			
			# Setup artillery camera
			setup_artillery_camera()
			
			# Setup UI elements
			setup_gun_reload_ui()
			
			print("Successfully initialized player guns: ", guns.size())
		else:
			print("Warning: No guns found in ship. This might be an initialization order issue.")
			# Try again next frame if no guns found
			needs_initialization = true
			return  # Skip processing until initialized
	
	if guns.size() > 0:
		artillery_cam.projectile_speed = guns[0].params.shell.speed
		artillery_cam.projectile_drag_coefficient = guns[0].params.shell.drag
		
	# Update gun reload UI
	for i in range(guns.size()):
		if i < gun_reloads.size():
			gun_reloads[i].value = guns[i].reload
		
	# Handle double click timer
	if click_count == 1:
		if Time.get_ticks_msec() / 1000.0 - last_click_time > double_click_timer:
			# Reset click count if double click timer expired
			click_count = 0
	
	# Handle sequential firing when holding
	if is_holding:
		sequential_fire_timer += dt
		var reload = guns[0].params.reload_time
		var min_reload = reload / guns.size() - 0.01
		var adjusted_sequential_fire_delay = min(sequential_fire_delay, min_reload)
		while sequential_fire_timer >= adjusted_sequential_fire_delay:
			sequential_fire_timer -= adjusted_sequential_fire_delay
			ship_artillery.fire_next_ready_gun.rpc_id(1)
	
	# Update UI layout if viewport size changes
	if get_viewport().size != view_port_size:
		view_port_size = get_viewport().size
		update_ui_layout()
		
	# Handle player input and send to server
	process_player_input()

func process_player_input() -> void:
	# Handle throttle input
	if Input.is_action_just_pressed("move_forward"):  # W key
		throttle_level = min(throttle_level + 1, 4)  # Max is 4 (full speed)
	elif Input.is_action_just_pressed("move_back"):   # S key
		throttle_level = max(throttle_level - 1, -1)  # Min is -1 (reverse)
	
	# Handle discrete rudder input with Q and E
	if Input.is_action_just_pressed("ui_q"):  # Q key
		rudder_mode = "discrete"
		discrete_rudder_index = max(discrete_rudder_index - 1, 0)
		target_rudder_value = discrete_rudder_positions[discrete_rudder_index]
	elif Input.is_action_just_pressed("ui_e"):  # E key
		rudder_mode = "discrete"
		discrete_rudder_index = min(discrete_rudder_index + 1, discrete_rudder_positions.size() - 1)
		target_rudder_value = discrete_rudder_positions[discrete_rudder_index]
	
	# Handle continuous rudder input with A and D
	if Input.is_action_pressed("move_left"):  # A key
		rudder_mode = "continuous"
		target_rudder_value = -1.0
		discrete_rudder_index = 2
	elif Input.is_action_pressed("move_right"):  # D key
		rudder_mode = "continuous"
		target_rudder_value = 1.0
		discrete_rudder_index = 2
	elif rudder_mode == "continuous":
		target_rudder_value = 0.0
	
	# Create movement input array
	var movement_input = [float(throttle_level), target_rudder_value]
	
	# Get aiming point from ray
	var aim_point: Vector3
	if ray.is_colliding():
		aim_point = ray.get_collision_point()
	else:
		aim_point = ray.global_position + Vector3(ray.global_basis.z.x, 0, ray.global_basis.z.z).normalized() * -50000
	
	# Send separated inputs to server
	send_movement_input.rpc_id(1, movement_input)
	send_aim_input.rpc_id(1, aim_point)

@rpc("any_peer", "call_remote", "reliable")
func send_movement_input(movement_input: Array) -> void:
	if multiplayer.is_server():
		# Forward movement input to ship movement controller
		ship_movement.set_movement_input(movement_input)

@rpc("any_peer", "call_remote", "reliable")
func send_aim_input(aim_point: Vector3) -> void:
	if multiplayer.is_server():
		# Forward aim input to ship artillery controller
		ship_artillery.set_aim_input(aim_point)
