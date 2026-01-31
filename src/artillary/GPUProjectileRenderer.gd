extends Node
class_name GPUProjectileRenderer
## GPU-based projectile renderer that reads shell positions from a texture
## The projectile_manager updates positions every frame via update_shell_position()

const MAX_SHELLS: int = 1024  # Maximum concurrent shells
const DATA_WIDTH: int = 2     # 2 pixels per shell for visual data (color, size)

var multi_mesh_instance: MultiMeshInstance3D
var shell_position_image: Image
var shell_position_texture: ImageTexture
var shell_data_image: Image
var shell_data_texture: ImageTexture
var shader_material: ShaderMaterial
var is_ready: bool = false

# Shell state tracking
var shell_slots: Array[bool] = []  # true = slot in use
var free_slots: Array[int] = []    # Reusable slot indices
var next_slot: int = 0
var active_shell_count: int = 0

# Batched update tracking - defer texture upload to _process
var position_texture_dirty: bool = false
var data_texture_dirty: bool = false

# Reference to camera for potential future use
var camera: Camera3D = null

signal shell_destroyed(id: int)

func _ready():
	_setup_position_texture()
	_setup_data_texture()
	_setup_mesh_instance()

	# Initialize slot tracking
	shell_slots.resize(MAX_SHELLS)
	shell_slots.fill(false)
	is_ready = true

func _setup_position_texture():
	# Create image for shell positions (1 pixel per shell, RGBAF format for precision)
	# Format: position.xyz, active (0/1)
	shell_position_image = Image.create(1, MAX_SHELLS, false, Image.FORMAT_RGBAF)

	# Initialize all shells as inactive at origin
	var inactive_color = Color(0, 0, 0, 0)  # position = 0,0,0, active = 0
	for y in range(MAX_SHELLS):
		shell_position_image.set_pixel(0, y, inactive_color)

	# Create texture from image
	shell_position_texture = ImageTexture.create_from_image(shell_position_image)

func _setup_data_texture():
	# Create image for shell visual data (DATA_WIDTH x MAX_SHELLS, RGBAF format)
	# Pixel 0: color.rgba
	# Pixel 1: size, shell_type, reserved, reserved
	shell_data_image = Image.create(DATA_WIDTH, MAX_SHELLS, false, Image.FORMAT_RGBAF)

	# Initialize all shells with default values
	var default_color = Color(1.0, 1.0, 1.0, 1.0)
	var default_params = Color(1.0, 0.0, 0.0, 0.0)  # size=1, type=0
	for y in range(MAX_SHELLS):
		shell_data_image.set_pixel(0, y, default_color)
		shell_data_image.set_pixel(1, y, default_params)

	# Create texture from image
	shell_data_texture = ImageTexture.create_from_image(shell_data_image)

func _setup_mesh_instance():
	# Load the GPU shader
	var shader = load("res://src/artillary/GPUProjectileShader.gdshader")
	shader_material = ShaderMaterial.new()
	shader_material.shader = shader
	shader_material.render_priority = 1

	# Set up shader parameters
	shader_material.set_shader_parameter("shell_position_texture", shell_position_texture)
	shader_material.set_shader_parameter("shell_data_texture", shell_data_texture)
	shader_material.set_shader_parameter("texture_width", DATA_WIDTH)
	shader_material.set_shader_parameter("max_shells", MAX_SHELLS)
	shader_material.set_shader_parameter("albedo", Color(3.29, 3.28, 3.28, 1.0))  # HDR albedo for glow

	# Load particle texture
	var particle_texture = load("res://particle.png")
	if particle_texture:
		shader_material.set_shader_parameter("texture_albedo", particle_texture)

	# Create a quad mesh for shells
	var quad = QuadMesh.new()
	quad.material = shader_material

	# Create MultiMesh for GPU instancing
	var multi_mesh = MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = false
	multi_mesh.use_custom_data = false
	multi_mesh.mesh = quad
	multi_mesh.instance_count = MAX_SHELLS  # Pre-allocate all instances
	multi_mesh.visible_instance_count = MAX_SHELLS  # Make sure they're all visible

	# Set all transforms to identity - shader will position them
	var identity = Transform3D.IDENTITY
	for i in range(MAX_SHELLS):
		multi_mesh.set_instance_transform(i, identity)

	# Create MultiMeshInstance3D directly as child
	multi_mesh_instance = MultiMeshInstance3D.new()
	multi_mesh_instance.multimesh = multi_mesh
	multi_mesh_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	# Set a large custom AABB so it doesn't get culled
	multi_mesh_instance.custom_aabb = AABB(Vector3(-100000, -100000, -100000), Vector3(200000, 200000, 200000))
	multi_mesh_instance.extra_cull_margin = 100000.0
	add_child(multi_mesh_instance)

	print("GPUProjectileRenderer: Setup complete, MultiMesh instance_count=", multi_mesh.instance_count)

func _process(_delta: float):
	if not is_ready:
		return

	# Batch texture updates - only upload once per frame regardless of how many shells changed
	if position_texture_dirty:
		shell_position_texture.update(shell_position_image)
		position_texture_dirty = false

	if data_texture_dirty:
		shell_data_texture.update(shell_data_image)
		data_texture_dirty = false

## Fire a new shell and return its ID
## Returns -1 if no slots available
func fire_shell(start_position: Vector3, _launch_velocity: Vector3, _drag: float,
				shell_size: float, shell_type: int, color: Color) -> int:
	if not is_ready:
		push_warning("GPUProjectileRenderer: fire_shell called before ready!")
		return -1

	var slot = _allocate_slot()
	if slot < 0:
		push_warning("GPUProjectileRenderer: No available shell slots!")
		return -1

	# Write initial position to position texture (active = 1.0)
	shell_position_image.set_pixel(0, slot, Color(start_position.x, start_position.y, start_position.z, 1.0))

	# Write shell visual data to data texture
	# Pixel 0: color.rgba
	shell_data_image.set_pixel(0, slot, color)

	# Pixel 1: size, shell_type, reserved, reserved
	shell_data_image.set_pixel(1, slot, Color(shell_size, float(shell_type), 0.0, 0.0))

	# Mark textures as dirty - will be uploaded in _process (batched)
	position_texture_dirty = true
	data_texture_dirty = true

	active_shell_count += 1
	return slot

## Update the position of a shell (called every frame by projectile_manager)
func update_shell_position(id: int, position: Vector3):
	if id < 0 or id >= MAX_SHELLS:
		return

	if not shell_slots[id]:
		return  # Shell not active

	# Update position in position texture (keep active = 1.0)
	shell_position_image.set_pixel(0, id, Color(position.x, position.y, position.z, 1.0))

	# Mark position texture as dirty
	position_texture_dirty = true

## Destroy a shell by ID
func destroy_shell(id: int):
	if id < 0 or id >= MAX_SHELLS:
		return

	if not shell_slots[id]:
		return  # Already destroyed

	# Mark as inactive in position texture (set active = 0)
	shell_position_image.set_pixel(0, id, Color(0.0, 0.0, 0.0, 0.0))

	# Mark texture as dirty - will be uploaded in _process (batched)
	position_texture_dirty = true

	_free_slot(id)
	active_shell_count -= 1
	shell_destroyed.emit(id)

## Check if a shell slot is active
func is_shell_active(id: int) -> bool:
	if id < 0 or id >= MAX_SHELLS:
		return false
	return shell_slots[id]

## Get count of active shells
func get_active_count() -> int:
	return active_shell_count

## Set shell time multiplier (no longer used, kept for API compatibility)
func set_time_multiplier(_value: float):
	pass

## Set gravity (no longer used, kept for API compatibility)
func set_gravity(_value: float):
	pass

func _allocate_slot() -> int:
	# Try to reuse a freed slot first
	if not free_slots.is_empty():
		var slot = free_slots.pop_back()
		shell_slots[slot] = true
		return slot

	# Allocate a new slot
	if next_slot < MAX_SHELLS:
		var slot = next_slot
		next_slot += 1
		shell_slots[slot] = true
		return slot

	return -1  # No slots available

func _free_slot(slot: int):
	shell_slots[slot] = false
	free_slots.append(slot)
