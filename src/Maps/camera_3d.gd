extends Camera3D

# Camera sensitivity and speed settings
@export var mouse_sensitivity := 0.002
@export var speed_normal := 100.0
@export var speed_fast := 500.0
@export var speed_slow := 1.0
@export var acceleration := 4.0
@export var deceleration := 8.0

# Current camera state
var _velocity := Vector3.ZERO
var _current_speed := speed_normal
var _target_velocity := Vector3.ZERO
var _mouse_captured := false

func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true

func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mouse_captured = false

func _input(event) -> void:
	# Toggle mouse capture with Escape key
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _mouse_captured:
			release_mouse()
		else:
			capture_mouse()
			
	# Mouse look (only when mouse is captured)
	if _mouse_captured and event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		var new_rotation = rotation.x - event.relative.y * mouse_sensitivity
		rotation.x = clamp(new_rotation, -PI/2, PI/2)
	
	# Speed control with mouse wheel
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_current_speed = min(_current_speed * 1.1, speed_fast)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_current_speed = max(_current_speed / 1.1, speed_slow)

func _process(delta) -> void:
	# Only process movement when mouse is captured
	if _mouse_captured:
		handle_movement(delta)

func handle_movement(delta) -> void:
	# Get movement input
	var input_dir := Vector3.ZERO
	
	# Forward/backward
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_dir.z -= 1
		
	# Left/right
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_dir.x += 1
		
	# Up/down
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_PAGEUP):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_PAGEDOWN):
		input_dir.y -= 1
	
	# Sprint modifier
	var speed := _current_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed = speed_fast
		
	# Normalize input direction and make relative to camera orientation
	input_dir = input_dir.normalized()
	_target_velocity = Vector3.ZERO
	_target_velocity += -global_transform.basis.z * input_dir.z
	_target_velocity += global_transform.basis.x * input_dir.x
	_target_velocity += global_transform.basis.y * input_dir.y
	_target_velocity = _target_velocity.normalized() * speed
	
	# Smoothly interpolate velocity for acceleration/deceleration
	if _target_velocity.length() > 0:
		_velocity = _velocity.lerp(_target_velocity, acceleration * delta)
	else:
		_velocity = _velocity.lerp(Vector3.ZERO, deceleration * delta)
	
	# Apply movement
	position += _velocity * delta
