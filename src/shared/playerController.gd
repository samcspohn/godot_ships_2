extends CharacterBody3D
class_name PlayerController

@export var speed: float = 5
@export var rotation_speed: float = 4
var _movementInput: Vector3
var _cameraInput: Vector2
@export var playerName: Label
var artillery_cam: ArtilleryCamera
var previous_position: Vector3
# var cam_boom_pitch: Node3D
#var time_to_target: Label

var yaw: float = 0
var pitch: float = 0

var player_yaw: float = 0

var yaw_sensitivity: float = 0.07
var pitch_sensitivty: float = 0.07
var guns: Array[Gun] = []
var gun_reloads: Array[ProgressBar] = []
var ray: RayCast3D

# Timing variables
var double_click_timer: float = 0.3 # Maximum time between clicks to register as double click
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var last_click_time: float = 0.0 # Track time of last click for double click detection
var is_holding: bool = false # Track if mouse button is being held
var click_count: int = 0 # Track number of clicks for double click detection
var sequential_fire_timer: float = 0.0 # Timer for sequential firing

var view_port_size: Vector2i = Vector2i(0, 0)
func setName(_name: String):
	playerName.text = _name

var _input_dir: Vector2
var _aim_point: Vector3

@export var gravity_value = 9.8
#var gravity_value = ProjectSettings.get_setting("physics/3d/default_gravity", gravity)

func setColor(_color: Color):
	pass
	#CanvasModulate = color
	#modulate = color

func _ready() -> void:
	previous_position = global_position
	var gun_id = 0
	for ch in self.get_child(1).get_children():
		if ch is Gun:
			ch.gun_id = gun_id
			gun_id += 1
			self.guns.append(ch)
	if name.to_int() != multiplayer.get_unique_id():
		return
	artillery_cam = load("res://scenes/player_cam.tscn").instantiate()
	artillery_cam.target_ship = self
	artillery_cam.projectile_speed = Shell.shell_speed
	#artillery_cam.

	get_tree().root.add_child(artillery_cam)
	#add_child(artillery_cam)
	# var c: Node3D = cam_boom_pitch.get_child(0)
	var canvas: CanvasLayer = artillery_cam.get_child(1)
	#time_to_target = canvas.get_node("CenterContainer/VBoxContainer/TimeToTarget")
	for g in guns:
		var progress_bar: ProgressBar = canvas.get_node("ProgressBar").duplicate()
		progress_bar.visible = true
		progress_bar.show_percentage = false
		progress_bar.max_value = 1.0
		canvas.add_child(progress_bar)
		gun_reloads.append(progress_bar)
	self.ray = artillery_cam.get_child(0)
	
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
		
		
func _input(event: InputEvent):
	if name.to_int() == multiplayer.get_unique_id():
		if event is InputEventKey:
			var horizontal = 1 if Input.is_key_pressed(KEY_A) else 0 - 1 if Input.is_key_pressed(KEY_D) else 0
			var vertical = 1 if Input.is_key_pressed(KEY_W) else 0 - 1 if Input.is_key_pressed(KEY_S) else 0
			_movementInput = Vector3(horizontal, 0, vertical).normalized()
		elif event is InputEventMouseMotion:
			_cameraInput = event.relative
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Mouse button pressed
				is_holding = true
				sequential_fire_timer = 0.0
				
				# Handle click counting for double click detection
				var current_time = Time.get_ticks_msec() / 1000.0
				if current_time - last_click_time < double_click_timer:
					click_count = 2
					handle_double_click.rpc_id(1)
				else:
					click_count = 1
					handle_single_click.rpc_id(1)
				
				last_click_time = current_time
			else:
				# Mouse button released
				is_holding = false

@rpc("any_peer", "call_remote")
func send_input(input_dir: Vector2, aim_point: Vector3):
	if multiplayer.is_server():
		_input_dir = input_dir
		_aim_point = aim_point
	
@rpc("any_peer", "call_remote")
func sync(d: Dictionary):
	#print(name)
	#print(d)
	self.global_position = d.position
	self.global_basis = d.basis
	var i = 0
	for g in guns:
		g.basis = d.guns[i].basis
		g.barrel.basis = d.guns[i].barrel
		i += 1
	var _s = get_node("Secondaries")
	i = 0
	for s: Gun in _s.get_children():
		s.basis = d.secondaries[i].basis
		s.barrel.basis = d.secondaries[i].barrel
		i += 1
		

var prev_offset = Vector2(0, 0)
func _physics_process(delta: float) -> void:
	if name.to_int() == multiplayer.get_unique_id():
		for i in range(guns.size()):
			gun_reloads[i].value = guns[i].reload
		var input_dir = Input.get_vector("move_right", "move_left", "move_forward", "move_back")
		var aim_point
		if ray.is_colliding():
			aim_point = ray.get_collision_point()
		else:
			aim_point = ray.global_position + Vector3(ray.global_basis.z.x,0,ray.global_basis.z.z).normalized() * -50000
			#aim_point = ray.global_position + ray.global_basis.z * -100
		send_input.rpc_id(1, input_dir, aim_point)
		
		
	if not multiplayer.is_server():
		return
	previous_position = global_position
		# Add gravity
	if not is_on_floor():
		velocity.y -= gravity_value * delta

	rotate(Vector3.UP, _input_dir.x * rotation_speed * delta)
	
	var dir = global_basis.z * speed * _input_dir.y
	velocity.x = move_toward(velocity.x, 0, speed)
		
			# Handle movement
	if not dir.is_zero_approx():
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		
	
	move_and_slide()

	for g in guns:
		g._aim(_aim_point, delta)
	
	var d = {'basis': global_basis, 'position': global_position, 'guns': [], 'secondaries': []}
	for g in guns:
		d.guns.append({'basis': g.basis, 'barrel': g.barrel.basis})
	var secondaries = get_node("Secondaries")
	for s: Gun in secondaries.get_children():
		d.secondaries.append({'basis': s.basis,'barrel': s.barrel.basis})
		
	
		
	sync.rpc(d)
	

func _process(dt):
	if name.to_int() != multiplayer.get_unique_id():
		return
		
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
			fire_next_gun.rpc_id(1)
	
	if get_viewport().size != view_port_size:
		view_port_size = get_viewport().size
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

@rpc("any_peer", "call_remote")
func handle_single_click() -> void:
	# Fire just one gun
	if multiplayer.is_server():
		if guns.size() > 0:
			for gun in guns:
				# Find first gun that's ready to fire
				if gun.reload >= 1.0:
					gun.fire()
					break

@rpc("any_peer", "call_remote")
func handle_double_click() -> void:
	# Fire all guns that are ready
	if multiplayer.is_server():
		for gun in guns:
			gun.fire()
		#if gun.is_ready_to_fire():
			#gun.fire()
			

@rpc("any_peer", "call_remote")
func fire_next_gun() -> void:
	if multiplayer.is_server():
		for g in guns:
			if g.reload >= 1:
				g.fire()
				return
