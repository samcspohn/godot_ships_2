extends Node3D

class_name NavalThirdPersonCamera


signal processed
# Camera components
@onready var camera: Camera3D = $"./Pitch/Camera3D"
@onready var yaw_node: Node3D = $"."
@onready var pitch_node: Node3D = $"./Pitch"

# Camera view modes
enum ViewMode {NORMAL, SNIPER}
var current_mode: int = ViewMode.NORMAL

# Camera parameters
@export var distance: float = 300.0
@export var min_distance: float = 50.0
@export var max_distance: float = 300.0

# FOV parameters
@export var normal_fov: float = 70.0
@export var sniper_fov: float = 20.0
@export var fov_transition_speed: float = 5.0

# Zoom parameters
@export var zoom_speed: float = 0.5
@export var zoom_step: float = 0.5
@export var distance_zoom_speed: float = 5.0

# Rotation parameters
@export var rotation_speed: float = 0.3
@export var min_pitch: float = -30.0
@export var max_pitch: float = 60.0

# Current state
var target_distance: float = 10.0
var target_fov: float = 70.0
var current_fov: float = 70.0
var target_yaw: float = 0.0
var target_pitch: float = 20.0

# UI elements
var crosshair: Control
var time_to_target_label: Label
var distance_label: Label

# Reference to the ship we're following
var ship_ref: Node3D = null

func _ready():
	# Create camera hierarchy
	_setup_camera()

	# Create UI elements
	_setup_ui()

	# Set initial transforms
	_update_camera_transform(0.0)

	var pm = get_node("/root/ProjectileManager")
	processed.connect(pm.__process)
	var tm = get_node("/root/TorpedoManager")
	processed.connect(tm.__process)

func _setup_camera():
	# Position camera at initial distance
	camera.transform.origin = Vector3(0, 100, distance)
	camera.fov = normal_fov

func _setup_ui():
	# Create a CanvasLayer for UI
	var canvas_layer = $"./CanvasLayer"

	# Create a Control node as the UI root
	var ui_root = Control.new()
	ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas_layer.add_child(ui_root)

	# Create crosshair
	crosshair = Control.new()
	ui_root.add_child(crosshair)

	# Horizontal line
	var h_rect = ColorRect.new()
	h_rect.color = Color(1, 1, 1, 0.8)
	h_rect.size = Vector2(20, 2)
	h_rect.position = Vector2(-10, -1)
	crosshair.add_child(h_rect)

	# Vertical line
	var v_rect = ColorRect.new()
	v_rect.color = Color(1, 1, 1, 0.8)
	v_rect.size = Vector2(2, 20)
	v_rect.position = Vector2(-1, -10)
	crosshair.add_child(v_rect)

	# Circle (optional)
	var circle_rect = ColorRect.new()
	circle_rect.color = Color(1, 1, 1, 0.3)
	circle_rect.size = Vector2(6, 6)
	circle_rect.position = Vector2(-3, -3)
	crosshair.add_child(circle_rect)

	# Time to target label
	time_to_target_label = Label.new()
	time_to_target_label.text = "Time to target: --"
	time_to_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_to_target_label.position = Vector2(0, 30)
	time_to_target_label.add_theme_color_override("font_color", Color(1, 0.8, 0, 1))
	time_to_target_label.add_theme_font_size_override("font_size", 16)
	crosshair.add_child(time_to_target_label)

	# Distance label
	distance_label = Label.new()
	distance_label.text = "Distance: --"
	distance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	distance_label.position = Vector2(0, 50)
	distance_label.add_theme_color_override("font_color", Color(1, 0.8, 0, 1))
	distance_label.add_theme_font_size_override("font_size", 16)
	crosshair.add_child(distance_label)


	# Update UI positions on window resize
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_on_viewport_size_changed()

func _on_viewport_size_changed():
	# Center the crosshair
	if crosshair:
		var viewport_size = get_viewport().get_visible_rect().size
		crosshair.position = viewport_size / 2

func _process(delta):
	# Smooth FOV transitions
	current_fov = lerp(current_fov, target_fov, fov_transition_speed * delta)
	camera.fov = current_fov

	# Smooth distance transitions for normal mode
	if current_mode == ViewMode.NORMAL:
		distance = lerp(distance, target_distance, distance_zoom_speed * delta)

	# Update camera transform
	_update_camera_transform(delta)

	processed.emit(delta)

func _physics_process(delta):
	if ship_ref != null:
		# Only copy the ship's position, not its rotation
		global_position = ship_ref.global_position

func _update_camera_transform(delta: float):
	# Apply rotations directly with no inertia
	yaw_node.rotation.y = target_yaw
	pitch_node.rotation.x = target_pitch

	# Update camera distance
	camera.transform.origin = Vector3(0, distance * 0.5 + 100, distance)

func _input(event):
	if event is InputEventMouseMotion:
		# Rotate camera with mouse freely (no button needed)
		target_yaw -= event.relative.x * rotation_speed * 0.01
		target_pitch -= event.relative.y * rotation_speed * 0.01

		# Clamp pitch to prevent flipping
		target_pitch = clamp(target_pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))

	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			# Zoom in
			if current_mode == ViewMode.NORMAL:
				# In normal mode, adjust camera distance
				target_distance = clamp(target_distance - zoom_step, min_distance, max_distance)
			else: # ViewMode.SNIPER
				# In sniper mode, adjust FOV
				target_fov = clamp(target_fov - zoom_speed, sniper_fov * 0.5, sniper_fov * 1.5)
				target_distance = clamp(target_distance - zoom_step, min_distance, max_distance)


		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# Zoom out
			if current_mode == ViewMode.NORMAL:
				# In normal mode, adjust camera distance
				target_distance = clamp(target_distance + zoom_step, min_distance, max_distance)
			else: # ViewMode.SNIPER
				# In sniper mode, adjust FOV
				target_fov = clamp(target_fov + zoom_speed, sniper_fov * 0.5, sniper_fov * 1.5)
				target_distance = clamp(target_distance + zoom_step, min_distance, max_distance)


	elif event is InputEventKey:
		if event.keycode == KEY_SHIFT and event.pressed:
			# Toggle between normal and sniper modes
			if current_mode == ViewMode.NORMAL:
				# Switch to sniper mode
				current_mode = ViewMode.SNIPER
				target_fov = sniper_fov
				# Store current distance for returning
			else:
				# Switch to normal mode
				current_mode = ViewMode.NORMAL
				target_fov = normal_fov

# Attach this node to your ship
func follow_ship(ship_node: Node3D):
	# Store the ship for position updates but don't make it a child
	# This prevents inheriting the ship's rotation
	self.ship_ref = ship_node

# Update the time to target display
func update_time_to_target(seconds: float):
	if time_to_target_label:
		if seconds < 0:
			time_to_target_label.text = "-- s"
		else:
			time_to_target_label.text = "%.1f s" % seconds

func update_distance(dist: float):
	if distance_label:
		distance_label.text = "%.1f m" % dist
