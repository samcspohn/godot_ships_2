extends Node
class_name GPUProjectileRenderer
## GPU-based projectile renderer that calculates shell positions on the GPU
## Instead of updating a transforms buffer every frame, we only update a data texture
## when shells are created or destroyed. The GPU shader handles all position calculations.

const MAX_SHELLS: int = 1024  # Maximum concurrent shells
const DATA_WIDTH: int = 4     # 4 pixels per shell for data

var multi_mesh_instance: MultiMeshInstance3D
var shell_data_image: Image
var shell_data_texture: ImageTexture
var shader_material: ShaderMaterial
var is_ready: bool = false

# Shell state tracking
var shell_slots: Array[bool] = []  # true = slot in use
var free_slots: Array[int] = []    # Reusable slot indices
var next_slot: int = 0
var active_shell_count: int = 0

# Deferred parameter values (set before _ready)
var _pending_time_multiplier: float = 1.5
var _pending_gravity: float = 9.8

# Time base for relative time (avoids precision loss with large Unix timestamps)
var time_base: float = 0.0

# Reference to camera for potential future use
var camera: Camera3D = null

signal shell_destroyed(id: int)

func _ready():
	# Set time base to current time - all times will be relative to this
	time_base = Time.get_unix_time_from_system()
	
	_setup_data_texture()
	_setup_mesh_instance()
	
	# Initialize slot tracking
	shell_slots.resize(MAX_SHELLS)
	shell_slots.fill(false)
	is_ready = true

func _setup_data_texture():
	# Create image for shell data (DATA_WIDTH x MAX_SHELLS, RGBAF format for precision)
	shell_data_image = Image.create(DATA_WIDTH, MAX_SHELLS, false, Image.FORMAT_RGBAF)
	
	# Initialize all shells as inactive
	var inactive_color = Color(0, 0, 0, 0)
	for y in range(MAX_SHELLS):
		for x in range(DATA_WIDTH):
			shell_data_image.set_pixel(x, y, inactive_color)
	
	# Create texture from image
	shell_data_texture = ImageTexture.create_from_image(shell_data_image)

func _setup_mesh_instance():
	# Load the GPU shader
	var shader = load("res://src/artillary/GPUProjectileShader.gdshader")
	shader_material = ShaderMaterial.new()
	shader_material.shader = shader
	shader_material.render_priority = 1
	
	# Set up shader parameters
	shader_material.set_shader_parameter("shell_data_texture", shell_data_texture)
	shader_material.set_shader_parameter("texture_width", DATA_WIDTH)
	shader_material.set_shader_parameter("max_shells", MAX_SHELLS)
	shader_material.set_shader_parameter("gravity", _pending_gravity)
	shader_material.set_shader_parameter("shell_time_multiplier", _pending_time_multiplier)
	shader_material.set_shader_parameter("albedo", Color(3.29, 3.28, 3.28, 1.0))  # HDR albedo for glow
	
	# Load particle texture
	var particle_texture = load("res://particle.png")
	if particle_texture:
		shader_material.set_shader_parameter("texture_albedo", particle_texture)
	
	# Create a quad mesh for shells
	var quad = QuadMesh.new()
	quad.material = shader_material
	
	# Create MultiMesh for GPU instancing (but we don't update transforms every frame!)
	var multi_mesh = MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = false  # We pass color via data texture
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
	# Set a large custom AABB so it doesn't get culled - AABB(position, size)
	multi_mesh_instance.custom_aabb = AABB(Vector3(-100000, -100000, -100000), Vector3(200000, 200000, 200000))
	multi_mesh_instance.extra_cull_margin = 100000.0  # Extra margin to prevent culling
	add_child(multi_mesh_instance)
	
	print("GPUProjectileRenderer: Setup complete, MultiMesh instance_count=", multi_mesh.instance_count)

func _process(_delta: float):
	if not is_ready:
		return
	# Update current time uniform using relative time (avoids float precision issues)
	var relative_time = Time.get_unix_time_from_system() - time_base
	shader_material.set_shader_parameter("current_time", relative_time)

## Fire a new shell and return its ID
## Returns -1 if no slots available
func fire_shell(start_position: Vector3, launch_velocity: Vector3, drag: float, 
				shell_size: float, shell_type: int, color: Color) -> int:
	if not is_ready:
		push_warning("GPUProjectileRenderer: fire_shell called before ready!")
		return -1
		
	var slot = _allocate_slot()
	if slot < 0:
		push_warning("GPUProjectileRenderer: No available shell slots!")
		return -1
	
	# Use relative time to avoid float precision issues with large Unix timestamps
	var relative_start_time = Time.get_unix_time_from_system() - time_base
	
	# print("GPUProjectileRenderer: Firing shell at slot ", slot, " pos=", start_position, " vel=", launch_velocity, " size=", shell_size, " t=", relative_start_time)
	
	# Write shell data to image
	# Pixel 0: start_position.xyz, start_time (relative)
	shell_data_image.set_pixel(0, slot, Color(start_position.x, start_position.y, start_position.z, relative_start_time))
	
	# Pixel 1: launch_velocity.xyz, drag_coefficient
	shell_data_image.set_pixel(1, slot, Color(launch_velocity.x, launch_velocity.y, launch_velocity.z, drag))
	
	# Pixel 2: color.rgba
	shell_data_image.set_pixel(2, slot, color)
	
	# Pixel 3: size, shell_type, active (1.0), reserved
	shell_data_image.set_pixel(3, slot, Color(shell_size, float(shell_type), 1.0, 0.0))
	
	# Update texture (only the changed row ideally, but ImageTexture requires full update)
	shell_data_texture.update(shell_data_image)
	
	active_shell_count += 1
	return slot

## Destroy a shell by ID
func destroy_shell(id: int):
	if id < 0 or id >= MAX_SHELLS:
		return
	
	if not shell_slots[id]:
		return  # Already destroyed
	
	# Mark as inactive in data texture
	shell_data_image.set_pixel(3, id, Color(0.0, 0.0, 0.0, 0.0))  # active = 0
	shell_data_texture.update(shell_data_image)
	
	_free_slot(id)
	active_shell_count -= 1
	shell_destroyed.emit(id)

## Get the calculated position of a shell (for collision detection on server)
## This replicates the GPU calculation on CPU
func get_shell_position(id: int) -> Vector3:
	if id < 0 or id >= MAX_SHELLS or not shell_slots[id]:
		return Vector3.ZERO
	
	# Read data from image
	var data0 = shell_data_image.get_pixel(0, id)
	var data1 = shell_data_image.get_pixel(1, id)
	
	var start_position = Vector3(data0.r, data0.g, data0.b)
	var start_time = data0.a
	var launch_velocity = Vector3(data1.r, data1.g, data1.b)
	var drag = data1.a
	
	var current_time = Time.get_unix_time_from_system()
	var t = (current_time - start_time) * 1.5  # shell_time_multiplier
	
	return ProjectilePhysicsWithDrag.calculate_position_at_time(start_position, launch_velocity, t, drag)

## Check if a shell slot is active
func is_shell_active(id: int) -> bool:
	if id < 0 or id >= MAX_SHELLS:
		return false
	return shell_slots[id]

## Get count of active shells
func get_active_count() -> int:
	return active_shell_count

## Set shell time multiplier
func set_time_multiplier(value: float):
	_pending_time_multiplier = value
	if shader_material != null:
		shader_material.set_shader_parameter("shell_time_multiplier", value)

## Set gravity
func set_gravity(value: float):
	_pending_gravity = value
	if shader_material != null:
		shader_material.set_shader_parameter("gravity", value)

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
