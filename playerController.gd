extends CharacterBody3D
@export var speed: float = 5
@export var rotation_speed: float = 4
var _movementInput: Vector3
var _cameraInput: Vector2
@export var playerName: Label
# @onready var player_object: Node3D = $"CSGBox3D"
var cam_boom_yaw: Node3D
var cam_boom_pitch: Node3D

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

@export var gravity_value = 9.8
#var gravity_value = ProjectSettings.get_setting("physics/3d/default_gravity", gravity)

func setColor(_color: Color):
	pass
	#CanvasModulate = color
	#modulate = color

func _ready() -> void:
	set_multiplayer_authority(name.to_int())
	
	if is_multiplayer_authority():
		cam_boom_yaw = load("res://player_cam.tscn").instantiate()
		cam_boom_pitch = cam_boom_yaw.get_child(0)
		add_child(cam_boom_yaw)
		var c: Node3D = cam_boom_pitch.get_child(0)
		# var mp: MultiplayerSynchronizer = self.get_child(0)
		var canvas: CanvasLayer = cam_boom_yaw.get_child(1)
		for ch in self.get_child(2).get_children():
			if ch is Gun:
				self.guns.append(ch)
				var progress_bar: ProgressBar = canvas.get_child(1).duplicate()
				progress_bar.visible = true
				progress_bar.show_percentage = false
				progress_bar.max_value = 1.0
				#progress_bar.add_theme_stylebox_override("Fill", load())
				canvas.add_child(progress_bar)
				gun_reloads.append(progress_bar)
				#progress_bar
		self.ray = c.get_child(0)
		
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
		#mp.replication_config.add_property()
		
		
func _input(event: InputEvent):
	if is_multiplayer_authority():
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
					handle_double_click()
				else:
					click_count = 1
					handle_single_click()
				
				last_click_time = current_time
			else:
				# Mouse button released
				is_holding = false

			
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

		# Add gravity
	if not is_on_floor():
		velocity.y -= gravity_value * delta
		
	# Get the input direction
	var input_dir = Input.get_vector("move_right", "move_left", "move_forward", "move_back")
	
	# Get the forward and right directions relative to the camera
	#var forward = -transform.basis.z
	#var right = transform.basis.x
	#
	## Calculate the movement direction based on camera orientation
	#var direction = (right * input_dir.x - forward * input_dir.y).normalized()
	
	# Handle movement
	#if direction:
		#velocity.x = direction.x * speed
	rotate(Vector3.UP, input_dir.x * rotation_speed * delta)
		#velocity.z = direction.z * speed
	#else:
	var dir = global_basis.z * speed * input_dir.y
	velocity.x = move_toward(velocity.x, 0, speed)
	#velocity = global_basis.z * speed * input_dir.y
		#velocity.x = move_toward(global_basis.z.x,0,speed)
		#velocity.z = move_toward(global_basis.z.z,0,speed)
		#velocity.x = move_toward(velocity.x, 0, speed)
		#velocity.z = move_toward(velocity.z, 0, speed)
		
			# Handle movement
	if not dir.is_zero_approx():
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
	
	move_and_slide()

	for i in range(guns.size()):
		gun_reloads[i].value = guns[i].reload
		
	for g in guns:
		g._aim(ray.get_collision_point(), delta)


func _process(dt):
	if not is_multiplayer_authority():
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
			fire_next_gun()
	
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
	
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# player_object.rotate(Vector3.UP, _movementInput.x * rotation_speed * dt)
	# var forw: Vector3 = -player_object.transform.basis.z
	# global_translate(forw * _movementInput.z * speed * dt)
	
	yaw += -_cameraInput.x * yaw_sensitivity
	pitch += -_cameraInput.y * pitch_sensitivty
	cam_boom_yaw.global_rotation_degrees.y = yaw
	cam_boom_pitch.global_rotation_degrees.x = clamp(pitch, -75, 90)
	_cameraInput = Vector2.ZERO


func handle_single_click() -> void:
	# Fire just one gun
	if guns.size() > 0:
		for gun in guns:
			# Find first gun that's ready to fire
			if gun.reload >= 1.0:
				gun.fire()
				break

func handle_double_click() -> void:
	# Fire all guns that are ready
	for gun in guns:
		gun.fire()
		#if gun.is_ready_to_fire():
			#gun.fire()
			
		
func fire_next_gun() -> void:
	for g in guns:
		if g.reload >= 1:
			g.fire()
			return
