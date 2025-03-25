extends Node
class_name PlayerController

var ship_motion: ShipMotion
var _cameraInput: Vector2
@export var playerName: Label
var artillery_cam: ArtilleryCamera
var ray: RayCast3D
var guns: Array[Gun] = []
var gun_reloads: Array[ProgressBar] = []

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
	# Get reference to the ship motion controller (parent node)
	ship_motion = get_parent() as ShipMotion

	if multiplayer.is_server():
		set_process(false)
		set_process_input(false)
		# set_process_unhandled_input(false)
		set_physics_process(false)


func setup_artillery_camera() -> void:
	artillery_cam = load("res://scenes/player_cam.tscn").instantiate()
	artillery_cam.target_ship = ship_motion
	if artillery_cam is Camera3D:
		artillery_cam.current = true
	if guns.size() > 0:
		artillery_cam.projectile_speed = guns[0].shell.speed
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
		_cameraInput = event.relative
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Mouse button pressed
				is_holding = true
				sequential_fire_timer = 0.0
				
				# Handle click counting for double click detection
				var current_time = Time.get_ticks_msec() / 1000.0
				if current_time - last_click_time < double_click_timer:
					click_count = 2
					ship_motion.fire_all_guns.rpc_id(1)
				else:
					click_count = 1
					handle_single_click()
				
				last_click_time = current_time
			else:
				# Mouse button released
				is_holding = false

func handle_single_click() -> void:
	if guns.size() > 0:
		for i in range(guns.size()):
			if guns[i].reload >= 1.0:
				ship_motion.fire_gun.rpc_id(1, i)
				break

func _process(dt: float) -> void:
	# Check if we need to initialize guns - do it only once
	if needs_initialization:
		needs_initialization = false
		
		# Check if guns are available in ShipMotion
		if ship_motion.guns.size() > 0:
			# Copy guns from ship to local array
			guns = ship_motion.guns
			
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
		if sequential_fire_timer >= sequential_fire_delay:
			sequential_fire_timer = 0.0
			ship_motion.fire_next_ready_gun.rpc_id(1)
	
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
	
	# Create input array: [throttle, rudder]
	var input_array = [float(throttle_level), target_rudder_value]
	
	# Get aiming point from ray
	var aim_point: Vector3
	if ray.is_colliding():
		aim_point = ray.get_collision_point()
	else:
		aim_point = ray.global_position + Vector3(ray.global_basis.z.x, 0, ray.global_basis.z.z).normalized() * -50000
	
	# Send input to server
	send_input.rpc_id(1, input_array, aim_point)
	
	# Visualize thrust vector if desired
	if ship_motion.rudder_node and ship_motion._thrust_vector != Vector3.ZERO:
		ship_motion.draw_debug_arrow(
			ship_motion.rudder_node.global_position, 
			ship_motion.rudder_node.global_position + ship_motion._thrust_vector, 
			Color(1,0,0)
		)

@rpc("any_peer", "call_remote", "reliable")
func send_input(input_array: Array, aim_point: Vector3) -> void:
	if multiplayer.is_server():
		# Forward input to ship motion controller
		ship_motion.set_input(input_array, aim_point)
