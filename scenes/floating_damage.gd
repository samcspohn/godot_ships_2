extends Label
class_name FloatingDamage
# Floating damage display that appears above hit points and tracks with world position
# Usage: Instantiate the scene, set damage_amount and world_position, then add to scene

@export var damage_amount: int = 0 : set = set_damage_amount
@export var world_position: Vector3 = Vector3.ZERO : set = set_world_position
@export var lifetime: float = 0.7
@export var fade_start_time: float = 0.3  # When to start fading out

var camera: Camera3D
var tween: Tween
var screen_offset: Vector2  # Random offset applied once at creation

func _ready():
	# Only run if world_position has been set (indicating this is being used, not just preloaded)
	if world_position == Vector3.ZERO:
		return
		
	# Find the camera
	camera = get_viewport().get_camera_3d()
	if not camera:
		print("Warning: No camera found for floating damage display")
		queue_free()
		return
	
	# Generate random offset once at creation
	screen_offset = Vector2(0, -60) + Vector2(randf_range(-35, 35), randf_range(-35, 35))
	
	# Set initial position on screen
	update_screen_position()
	
	# Start the floating animation
	start_floating_animation()

func set_damage_amount(value: int):
	damage_amount = value
	text = str(damage_amount)

func set_world_position(value: Vector3):
	world_position = value
	if is_inside_tree():
		update_screen_position()

func update_screen_position():
	if not camera or world_position == Vector3.ZERO:
		return
	
	# Convert world position to screen position
	var screen_pos = camera.unproject_position(world_position) + screen_offset
	
	# Position the label
	position = screen_pos - size * 0.5  # Center the label on the position

func start_floating_animation():
	# Create tween for smooth animation
	tween = create_tween()
	tween.set_parallel(true)  # Allow multiple animations simultaneously
	
	# Only animate fade out (no position animation - let _process handle position tracking)
	tween.tween_method(update_alpha, 1.0, 0.0, lifetime - fade_start_time).set_delay(fade_start_time)
	
	# Remove after lifetime
	tween.tween_callback(queue_free).set_delay(lifetime)

func update_alpha(alpha: float):
	modulate.a = alpha

func _process(_delta):
	# Continuously update screen position to track with world position
	if camera and world_position != Vector3.ZERO:
		update_screen_position()
