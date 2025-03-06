extends CharacterBody3D
@export var speed = 5.0
@export var jump_strength = 4.5
@export var gravity = 9.8
@export var mouse_sensitivity = 0.002  # Controls how fast the camera rotates

# Get the gravity from the project settings to be synced with physics effects
var gravity_value = ProjectSettings.get_setting("physics/3d/default_gravity", gravity)

func _ready():
	# Only enable input for local player
	print(name)
	set_multiplayer_authority(name.to_int())
	
	if not is_multiplayer_authority():
		$Camera.queue_free()
	else:
		get_tree().root.get_node("/root/Server/GameWorld/Camera3D").queue_free()
		# Capture the mouse when the game starts
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

#func _process(delta: float) -> void:
	#if not is_multiplayer_authority():
		#return
	#
	#var cam: Camera3D = $Camera
	#cam.current = true
		
func _physics_process(delta):
	# Only process input for local player
	if not is_multiplayer_authority():
		return
	
	# Add gravity
	if not is_on_floor():
		velocity.y -= gravity_value * delta
	
	# Handle Jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_strength
	
	# Get the input direction
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	
	# Get the forward and right directions relative to the camera
	var forward = -transform.basis.z
	var right = transform.basis.x
	
	# Calculate the movement direction based on camera orientation
	var direction = (right * input_dir.x - forward * input_dir.y).normalized()
	
	# Handle movement
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
	
	move_and_slide()
	
	#if is_multiplayer_authority():
		#var cam: Camera3D = $Camera
		#cam.current = true
	#else:
		## Capture the mouse when the game starts
		#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _input(event):
	# Only process input for local player
	if not is_multiplayer_authority():
		return
		
	# Handle mouse input for rotation
	if event is InputEventMouseMotion:
		# Rotate player left/right (Y-axis)
		rotate_y(-event.relative.x * mouse_sensitivity)
		
		# Rotate camera up/down (X-axis)
		$Camera.rotate_x(-event.relative.y * mouse_sensitivity)
		
		# Clamp the camera's vertical rotation to prevent it from flipping
		$Camera.rotation.x = clamp($Camera.rotation.x, -PI/2, PI/2)
	
	# Add ability to toggle mouse capture with Escape key
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
