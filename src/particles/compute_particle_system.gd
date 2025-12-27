extends Node3D
class_name ComputeParticleSystem

## Compute shader-based particle system
## Uses RenderingDevice compute shaders for GPU-accelerated particle simulation
## ZERO CPU READBACK: Compute writes to textures that render shader reads directly

const MAX_PARTICLES: int = 100000
const WORKGROUP_SIZE: int = 64

# Texture dimensions for particle data (1024 wide, height = ceil(MAX_PARTICLES / 1024))
const PARTICLE_TEX_WIDTH: int = 1024
const PARTICLE_TEX_HEIGHT: int = 98  # ceil(100000 / 1024)

const EMISSION_REQUEST_STRIDE: int = 64  # 4 vec4s = 16 floats = 64 bytes (includes prefix sum offset)

var template_manager: ParticleTemplateManager:
	set(value):
		template_manager = value
		if _initialized and value != null:
			# Template manager assigned after initialization - update uniforms now
			update_shader_uniforms()

# Rendering device and compute resources
var rd: RenderingDevice
var compute_shader: RID
var compute_pipeline: RID

# Sorting compute resources
var sort_shader: RID
var sort_pipeline: RID
var sort_keys_a: RID
var sort_keys_b: RID
var sort_indices_a: RID
var sort_indices_b: RID
var sort_histogram: RID
var sort_global_prefix: RID
var sorted_indices_tex: RID
var sorted_indices_texture: Texture2DRD
var sort_uniform_set: RID
var sort_sampler: RID
const SORT_WORKGROUP_SIZE: int = 256

# Particle data textures (shared between compute and render)
var particle_position_lifetime_tex: RID
var particle_velocity_template_tex: RID
var particle_custom_tex: RID
var particle_extra_tex: RID

# Godot textures that wrap the RD textures for rendering
var position_lifetime_texture: Texture2DRD
var velocity_template_texture: Texture2DRD
var custom_texture: Texture2DRD
var extra_texture: Texture2DRD

# Emission buffer
var emission_buffer: RID
var emission_buffer_capacity: int = 0  # Current capacity in number of requests
var uniform_set: RID

# Texture resources for compute shader
var template_properties_tex: RID
var velocity_curve_tex: RID
var template_properties_sampler: RID
var velocity_curve_sampler: RID

# Rendering
var multimesh: MultiMesh
var multimesh_instance: MultiMeshInstance3D
var render_material: ShaderMaterial

# State
var _initialized: bool = false
var _next_particle_slot: int = 0
var _pending_emissions: Array[Dictionary] = []
var _total_pending_particles: int = 0
var _frame_random_seed: int = 0

signal system_ready


func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		queue_free()
		return

	# Defer initialization to ensure template manager is ready
	# call_deferred("_initialize")
	RenderingServer.call_on_render_thread(_initialize)


func _initialize() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_error("ComputeParticleSystem: RenderingDevice not available")
		return

	# Initialize random seed
	_frame_random_seed = randi()

	# Set up particle data textures first (compute writes, render reads)
	if not _setup_particle_textures():
		push_error("ComputeParticleSystem: Failed to set up particle textures")
		return

	# Set up compute shader
	if not _setup_compute_shader():
		push_error("ComputeParticleSystem: Failed to set up compute shader")
		return

	# Set up emission buffer
	if not _setup_emission_buffer():
		push_error("ComputeParticleSystem: Failed to set up emission buffer")
		return

	# Set up sorting compute shader
	if not _setup_sort_shader():
		push_error("ComputeParticleSystem: Failed to set up sort shader")
		return

	# Set up rendering
	if not _setup_rendering():
		push_error("ComputeParticleSystem: Failed to set up rendering")
		return

	_initialized = true
	print("ComputeParticleSystem: Initialized with %d max particles (zero-copy GPU rendering)" % MAX_PARTICLES)
	system_ready.emit()


func _setup_particle_textures() -> bool:
	# Create particle data textures that can be written by compute shader
	# and read by render shader - NO CPU READBACK

	var tex_format := RDTextureFormat.new()
	tex_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.width = PARTICLE_TEX_WIDTH
	tex_format.height = PARTICLE_TEX_HEIGHT
	tex_format.depth = 1
	tex_format.mipmaps = 1
	tex_format.array_layers = 1
	tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tex_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |  # Compute shader write (image2D)
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |  # Render shader read (sampler2D)
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT  # CPU clear on init
	)

	var tex_view := RDTextureView.new()

	# Create initial data (all zeros = inactive particles with remaining_lifetime = 0)
	var initial_data := PackedByteArray()
	initial_data.resize(PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT * 16)  # 16 bytes per pixel (RGBA32F)
	initial_data.fill(0)

	# Position + lifetime texture (xyz = position, w = remaining_lifetime)
	particle_position_lifetime_tex = rd.texture_create(tex_format, tex_view, [initial_data])
	if not particle_position_lifetime_tex.is_valid():
		push_error("ComputeParticleSystem: Failed to create position_lifetime texture")
		return false

	# Velocity + template texture (xyz = velocity, w = template_id)
	particle_velocity_template_tex = rd.texture_create(tex_format, tex_view, [initial_data])
	if not particle_velocity_template_tex.is_valid():
		push_error("ComputeParticleSystem: Failed to create velocity_template texture")
		return false

	# Custom data texture (x = angle, y = age, z = initial_scale, w = speed_scale)
	particle_custom_tex = rd.texture_create(tex_format, tex_view, [initial_data])
	if not particle_custom_tex.is_valid():
		push_error("ComputeParticleSystem: Failed to create custom texture")
		return false

	# Extra data texture (x = size_multiplier, yzw = reserved)
	particle_extra_tex = rd.texture_create(tex_format, tex_view, [initial_data])
	if not particle_extra_tex.is_valid():
		push_error("ComputeParticleSystem: Failed to create extra texture")
		return false

	# Create Texture2DRD wrappers for rendering - these let the render shader sample
	# directly from the RenderingDevice textures with zero CPU involvement
	position_lifetime_texture = Texture2DRD.new()
	position_lifetime_texture.texture_rd_rid = particle_position_lifetime_tex

	velocity_template_texture = Texture2DRD.new()
	velocity_template_texture.texture_rd_rid = particle_velocity_template_tex

	custom_texture = Texture2DRD.new()
	custom_texture.texture_rd_rid = particle_custom_tex

	extra_texture = Texture2DRD.new()
	extra_texture.texture_rd_rid = particle_extra_tex

	print("ComputeParticleSystem: Created particle textures (%dx%d = %d particles)" % [PARTICLE_TEX_WIDTH, PARTICLE_TEX_HEIGHT, PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT])
	return true


func _setup_compute_shader() -> bool:
	# Load compute shader
	var shader_file := load("res://src/particles/shaders/compute_particle_simulate.glsl")
	if shader_file == null:
		push_error("ComputeParticleSystem: Failed to load compute shader file")
		return false

	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if shader_spirv == null:
		push_error("ComputeParticleSystem: Failed to get SPIRV from shader")
		return false

	compute_shader = rd.shader_create_from_spirv(shader_spirv)
	if not compute_shader.is_valid():
		push_error("ComputeParticleSystem: Failed to create compute shader")
		return false

	# Single pipeline for both emission and simulation (mode controlled by push constants)
	compute_pipeline = rd.compute_pipeline_create(compute_shader)
	if not compute_pipeline.is_valid():
		push_error("ComputeParticleSystem: Failed to create compute pipeline")
		return false

	return true


func _setup_emission_buffer(capacity: int = 64) -> bool:
	# Create emission buffer for batch emission requests (dynamically sized)
	if emission_buffer.is_valid():
		rd.free_rid(emission_buffer)

	emission_buffer_capacity = capacity
	var emission_data := PackedByteArray()
	emission_data.resize(capacity * EMISSION_REQUEST_STRIDE)
	emission_data.fill(0)

	emission_buffer = rd.storage_buffer_create(emission_data.size(), emission_data)
	if not emission_buffer.is_valid():
		push_error("ComputeParticleSystem: Failed to create emission buffer")
		return false

	return true


func _setup_sort_shader() -> bool:
	# Load sort compute shader
	var shader_file := load("res://src/particles/shaders/compute_particle_sort.glsl")
	if shader_file == null:
		push_error("ComputeParticleSystem: Failed to load sort shader file")
		return false

	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if shader_spirv == null:
		push_error("ComputeParticleSystem: Failed to get SPIRV from sort shader")
		return false

	sort_shader = rd.shader_create_from_spirv(shader_spirv)
	if not sort_shader.is_valid():
		push_error("ComputeParticleSystem: Failed to create sort shader")
		return false

	sort_pipeline = rd.compute_pipeline_create(sort_shader)
	if not sort_pipeline.is_valid():
		push_error("ComputeParticleSystem: Failed to create sort pipeline")
		return false

	# Create sort buffers
	var buffer_size := MAX_PARTICLES * 4  # uint32 per particle
	var empty_data := PackedByteArray()
	empty_data.resize(buffer_size)
	empty_data.fill(0)

	sort_keys_a = rd.storage_buffer_create(buffer_size, empty_data)
	sort_keys_b = rd.storage_buffer_create(buffer_size, empty_data)
	sort_indices_a = rd.storage_buffer_create(buffer_size, empty_data)
	sort_indices_b = rd.storage_buffer_create(buffer_size, empty_data)

	if not sort_keys_a.is_valid() or not sort_keys_b.is_valid() or \
	   not sort_indices_a.is_valid() or not sort_indices_b.is_valid():
		push_error("ComputeParticleSystem: Failed to create sort key/index buffers")
		return false

	# Histogram buffer: 256 bins * num_workgroups
	var num_workgroups := ceili(float(MAX_PARTICLES) / float(SORT_WORKGROUP_SIZE))
	var histogram_size := 256 * num_workgroups * 4
	var histogram_data := PackedByteArray()
	histogram_data.resize(histogram_size)
	histogram_data.fill(0)
	sort_histogram = rd.storage_buffer_create(histogram_size, histogram_data)

	if not sort_histogram.is_valid():
		push_error("ComputeParticleSystem: Failed to create sort histogram buffer")
		return false

	# Global prefix sum buffer: 256 bins
	var prefix_data := PackedByteArray()
	prefix_data.resize(256 * 4)
	prefix_data.fill(0)
	sort_global_prefix = rd.storage_buffer_create(256 * 4, prefix_data)

	if not sort_global_prefix.is_valid():
		push_error("ComputeParticleSystem: Failed to create global prefix buffer")
		return false

	# Create sorted indices texture (R32_SFLOAT format for render shader - uint not supported for sampling)
	var tex_format := RDTextureFormat.new()
	tex_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	tex_format.width = PARTICLE_TEX_WIDTH
	tex_format.height = PARTICLE_TEX_HEIGHT
	tex_format.depth = 1
	tex_format.mipmaps = 1
	tex_format.array_layers = 1
	tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tex_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |  # Compute shader write
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |  # Render shader read
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	var tex_view := RDTextureView.new()

	# Initialize with identity mapping (index i -> i) as floats
	var init_data := PackedByteArray()
	init_data.resize(PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT * 4)
	for i in range(MAX_PARTICLES):
		init_data.encode_float(i * 4, float(i))
	# Fill remaining with zeros
	for i in range(MAX_PARTICLES, PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT):
		init_data.encode_float(i * 4, 0.0)

	sorted_indices_tex = rd.texture_create(tex_format, tex_view, [init_data])
	if not sorted_indices_tex.is_valid():
		push_error("ComputeParticleSystem: Failed to create sorted indices texture")
		return false

	# Create Texture2DRD wrapper for render shader
	sorted_indices_texture = Texture2DRD.new()
	sorted_indices_texture.texture_rd_rid = sorted_indices_tex

	# Create sampler for position texture in sort shader
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sort_sampler = rd.sampler_create(sampler_state)

	print("ComputeParticleSystem: Sort shader initialized with radix sort")
	return true


func _setup_sort_uniform_set() -> bool:
	# Uniform set for sort shader
	# Binding 0: particle_position_lifetime (sampler)
	var uniform_pos := RDUniform.new()
	uniform_pos.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform_pos.binding = 0
	uniform_pos.add_id(sort_sampler)
	uniform_pos.add_id(particle_position_lifetime_tex)

	# Binding 1: sort_keys_a
	var uniform_keys_a := RDUniform.new()
	uniform_keys_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_keys_a.binding = 1
	uniform_keys_a.add_id(sort_keys_a)

	# Binding 2: sort_keys_b
	var uniform_keys_b := RDUniform.new()
	uniform_keys_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_keys_b.binding = 2
	uniform_keys_b.add_id(sort_keys_b)

	# Binding 3: sort_indices_a
	var uniform_indices_a := RDUniform.new()
	uniform_indices_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_indices_a.binding = 3
	uniform_indices_a.add_id(sort_indices_a)

	# Binding 4: sort_indices_b
	var uniform_indices_b := RDUniform.new()
	uniform_indices_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_indices_b.binding = 4
	uniform_indices_b.add_id(sort_indices_b)

	# Binding 5: histogram
	var uniform_histogram := RDUniform.new()
	uniform_histogram.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_histogram.binding = 5
	uniform_histogram.add_id(sort_histogram)

	# Binding 6: global_prefix
	var uniform_prefix := RDUniform.new()
	uniform_prefix.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_prefix.binding = 6
	uniform_prefix.add_id(sort_global_prefix)

	# Binding 7: sorted_indices_tex (image)
	var uniform_sorted_tex := RDUniform.new()
	uniform_sorted_tex.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_sorted_tex.binding = 7
	uniform_sorted_tex.add_id(sorted_indices_tex)

	sort_uniform_set = rd.uniform_set_create(
		[uniform_pos, uniform_keys_a, uniform_keys_b, uniform_indices_a,
		 uniform_indices_b, uniform_histogram, uniform_prefix, uniform_sorted_tex],
		sort_shader, 0
	)

	return sort_uniform_set.is_valid()


func _setup_uniform_set() -> bool:
	if template_manager == null:
		push_error("ComputeParticleSystem: Template manager not set")
		return false

	var uniforms := template_manager.get_shader_uniforms()

	# Create samplers
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	template_properties_sampler = rd.sampler_create(sampler_state)

	var linear_sampler_state := RDSamplerState.new()
	linear_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	velocity_curve_sampler = rd.sampler_create(linear_sampler_state)

	# Get template properties texture
	var props_tex: ImageTexture = uniforms.get("template_properties")
	if props_tex == null:
		push_error("ComputeParticleSystem: No template_properties texture")
		return false

	template_properties_tex = _create_rd_texture_from_image(props_tex.get_image())
	if not template_properties_tex.is_valid():
		push_error("ComputeParticleSystem: Failed to create template properties RD texture")
		return false

	# Get velocity curve atlas
	var vel_tex: ImageTexture = uniforms.get("velocity_curve_atlas")
	if vel_tex and vel_tex.get_image():
		velocity_curve_tex = _create_rd_texture_from_image(vel_tex.get_image())

	# Create placeholder if texture failed or doesn't exist
	if not velocity_curve_tex.is_valid():
		var placeholder := Image.create(256, 16, false, Image.FORMAT_RGBAF)
		placeholder.fill(Color(0, 0, 0, 1))
		velocity_curve_tex = _create_rd_texture_from_image(placeholder)

	if not velocity_curve_tex.is_valid():
		push_error("ComputeParticleSystem: Failed to create velocity curve texture")
		return false

	# Build uniform set with NEW BINDINGS for image-based particle data
	# Binding 0: particle_position_lifetime (image2D for compute write)
	var uniform_pos := RDUniform.new()
	uniform_pos.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_pos.binding = 0
	uniform_pos.add_id(particle_position_lifetime_tex)

	# Binding 1: particle_velocity_template (image2D for compute write)
	var uniform_vel := RDUniform.new()
	uniform_vel.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_vel.binding = 1
	uniform_vel.add_id(particle_velocity_template_tex)

	# Binding 2: particle_custom (image2D for compute write)
	var uniform_custom := RDUniform.new()
	uniform_custom.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_custom.binding = 2
	uniform_custom.add_id(particle_custom_tex)

	# Binding 3: particle_extra (image2D for compute write) - size_multiplier and reserved
	var uniform_extra := RDUniform.new()
	uniform_extra.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_extra.binding = 3
	uniform_extra.add_id(particle_extra_tex)

	# Binding 4: emission_buffer (storage buffer)
	var uniform_emission := RDUniform.new()
	uniform_emission.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_emission.binding = 4
	uniform_emission.add_id(emission_buffer)

	# Binding 5: template_properties (sampler with texture)
	var uniform_props := RDUniform.new()
	uniform_props.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform_props.binding = 5
	uniform_props.add_id(template_properties_sampler)
	uniform_props.add_id(template_properties_tex)

	# Binding 6: velocity_curve_atlas (sampler with texture)
	var uniform_velocity := RDUniform.new()
	uniform_velocity.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform_velocity.binding = 6
	uniform_velocity.add_id(velocity_curve_sampler)
	uniform_velocity.add_id(velocity_curve_tex)

	uniform_set = rd.uniform_set_create(
		[uniform_pos, uniform_vel, uniform_custom, uniform_extra, uniform_emission, uniform_props, uniform_velocity],
		compute_shader, 0
	)

	return uniform_set.is_valid()


func _create_rd_texture_from_image(image: Image) -> RID:
	if image == null:
		push_error("ComputeParticleSystem: Cannot create texture from null image")
		return RID()

	# Make a copy to avoid modifying the original
	var img := image.duplicate() as Image

	# Convert unsupported formats to supported ones
	# R32G32B32_SFLOAT is not supported for sampling, convert to RGBA
	match img.get_format():
		Image.FORMAT_RGBF:
			img.convert(Image.FORMAT_RGBAF)
		Image.FORMAT_RGB8:
			img.convert(Image.FORMAT_RGBA8)

	# Determine RenderingDevice format
	var rd_format := RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	match img.get_format():
		Image.FORMAT_RGBA8:
			rd_format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		Image.FORMAT_RGBAF:
			rd_format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		Image.FORMAT_RF:
			rd_format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		Image.FORMAT_RGF:
			rd_format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
		_:
			# Fallback: convert to RGBA8
			img.convert(Image.FORMAT_RGBA8)
			rd_format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM

	var tex_format := RDTextureFormat.new()
	tex_format.format = rd_format
	tex_format.width = img.get_width()
	tex_format.height = img.get_height()
	tex_format.depth = 1
	tex_format.mipmaps = 1
	tex_format.array_layers = 1
	tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tex_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

	var tex_view := RDTextureView.new()

	var result := rd.texture_create(tex_format, tex_view, [img.get_data()])
	if not result.is_valid():
		push_error("ComputeParticleSystem: Failed to create RD texture (format: %d, size: %dx%d)" % [rd_format, img.get_width(), img.get_height()])
	return result


func _setup_rendering() -> bool:
	# Create MultiMesh for instanced rendering
	# All instances are always "rendered" - the shader handles visibility by discarding inactive particles
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = false  # Not needed - shader reads from particle textures
	multimesh.instance_count = MAX_PARTICLES
	multimesh.visible_instance_count = MAX_PARTICLES  # All instances visible - shader culls inactive

	# Create quad mesh
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	multimesh.mesh = quad

	# Set identity transforms - shader will position particles
	for i in MAX_PARTICLES:
		multimesh.set_instance_transform(i, Transform3D.IDENTITY)

	# Load render shader
	var render_shader := load("res://src/particles/shaders/compute_particle_render.gdshader")
	if render_shader == null:
		push_error("ComputeParticleSystem: Failed to load render shader")
		return false

	render_material = ShaderMaterial.new()
	render_material.shader = render_shader

	# Pass particle data textures to render shader
	# These are Texture2DRD wrappers around the RD textures
	render_material.set_shader_parameter("particle_position_lifetime", position_lifetime_texture)
	render_material.set_shader_parameter("particle_velocity_template", velocity_template_texture)
	render_material.set_shader_parameter("particle_custom", custom_texture)
	render_material.set_shader_parameter("particle_extra", extra_texture)
	render_material.set_shader_parameter("particle_tex_width", float(PARTICLE_TEX_WIDTH))
	render_material.set_shader_parameter("particle_tex_height", float(PARTICLE_TEX_HEIGHT))

	# Apply template uniforms from template manager
	_update_render_uniforms()

	# Assign material to mesh
	quad.material = render_material

	# Create MultiMeshInstance3D
	multimesh_instance = MultiMeshInstance3D.new()
	multimesh_instance.multimesh = multimesh
	multimesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Disable frustum culling - particles are positioned by shader and can be anywhere
	multimesh_instance.custom_aabb = AABB(Vector3(-1e10, -1e10, -1e10), Vector3(2e10, 2e10, 2e10))
	add_child(multimesh_instance)

	return true


func _update_render_uniforms() -> void:
	if template_manager == null or render_material == null:
		push_warning("ComputeParticleSystem: Cannot update render uniforms - template_manager=%s, render_material=%s" % [template_manager, render_material])
		return

	var uniforms := template_manager.get_shader_uniforms()

	if uniforms.has("template_properties"):
		render_material.set_shader_parameter("template_properties", uniforms["template_properties"])
	if uniforms.has("texture_atlas"):
		render_material.set_shader_parameter("texture_atlas", uniforms["texture_atlas"])
		print("ComputeParticleSystem: Set texture_atlas = %s" % uniforms["texture_atlas"])
	if uniforms.has("color_ramp_atlas"):
		render_material.set_shader_parameter("color_ramp_atlas", uniforms["color_ramp_atlas"])
	if uniforms.has("scale_curve_atlas"):
		render_material.set_shader_parameter("scale_curve_atlas", uniforms["scale_curve_atlas"])
	if uniforms.has("emission_curve_atlas"):
		render_material.set_shader_parameter("emission_curve_atlas", uniforms["emission_curve_atlas"])

	# Pass sorted indices texture to render shader
	if sorted_indices_texture != null:
		render_material.set_shader_parameter("sorted_indices", sorted_indices_texture)

	print("ComputeParticleSystem: Render uniforms updated")

var camera_position: Vector3 = Vector3.ZERO
func _render_thread_process(delta: float) -> void:
	if not _initialized:
		return

	_frame_random_seed = randi()

	# Process pending emissions
	if _pending_emissions.size() > 0:
		_process_emissions()

	# Run simulation
	_run_simulation(delta)

	# Run sorting pass for correct Z-order rendering
	_run_particle_sort()
	# NO CPU READBACK - rendering is handled entirely on GPU via Texture2DRD

func _process(delta: float) -> void:
	if not _initialized:
		return

	#camera_position = get_viewport().get_camera_3d().global_transform.origin
	if get_viewport().get_camera_3d():
		camera_position = get_viewport().get_camera_3d().global_transform.origin

	RenderingServer.call_on_render_thread(_render_thread_process.bind(delta))



func emit_particles(pos: Vector3, direction: Vector3, template_id: int,
					size_multiplier: float, count: int, speed_mod: float) -> void:
	"""
	Emit particles with a specific template.
	Batches emission requests for efficient GPU processing.

	Args:
		pos: World position to emit from
		direction: Direction vector for particle emission
		template_id: The ID of the particle template to use
		size_multiplier: Scale multiplier for particles
		count: Number of particles to emit
		speed_mod: Time scale multiplier
	"""
	if not _initialized:
		push_warning("ComputeParticleSystem: Not initialized, queueing emission")
		# Queue for later
		call_deferred("emit_particles", pos, direction, template_id, size_multiplier, count, speed_mod)
		return

	if template_id < 0 or template_id >= ParticleTemplateManager.MAX_TEMPLATES:
		push_error("ComputeParticleSystem: Invalid template_id %d" % template_id)
		return

	# Clamp count to available slots
	var available_slots := MAX_PARTICLES - _next_particle_slot
	if count > available_slots:
		# Wrap around
		_next_particle_slot = 0
		available_slots = MAX_PARTICLES

	count = mini(count, available_slots)
	if count <= 0:
		return

	# Queue emission request
	_pending_emissions.append({
		"position": pos,
		"direction": direction,
		"template_id": template_id,
		"size_multiplier": size_multiplier,
		"count": count,
		"speed_mod": speed_mod,
		"base_particle_index": _next_particle_slot,
		"random_seed": _frame_random_seed + _pending_emissions.size()
	})

	_next_particle_slot += count
	_total_pending_particles += count


func emit_trail(from_pos: Vector3, to_pos: Vector3, velocity_dir: Vector3,
				template_id: int, size_multiplier: float, step_size: float = 20.0,
				speed_mod: float = 1.0) -> int:
	"""
	Emit trail particles along a path from from_pos to to_pos.
	Used for shell trails and similar effects.

	Args:
		from_pos: Starting position of the trail segment
		to_pos: Ending position of the trail segment
		velocity_dir: Direction vector for velocity alignment (usually normalized movement direction)
		template_id: The ID of the particle template (should have align_to_velocity enabled)
		size_multiplier: Scale multiplier for particles
		step_size: Distance between trail particles (default 20 units)
		speed_mod: Time scale multiplier

	Returns:
		Number of particles emitted
	"""
	if not _initialized:
		return 0

	var offset := to_pos - from_pos
	var distance := offset.length()

	if distance < step_size:
		return 0

	# Calculate number of particles to emit
	var count := int(distance / step_size)
	if count <= 0:
		return 0

	# Emit particles spaced along the path
	var step := offset.normalized() * step_size
	var current_pos := from_pos

	for i in range(count):
		emit_particles(current_pos, velocity_dir, template_id, size_multiplier, 1, speed_mod)
		current_pos += step

	return count


func _process_emissions() -> void:
	if _pending_emissions.size() == 0:
		return

	if not uniform_set.is_valid():
		if not _setup_uniform_set():
			_pending_emissions.clear()
			_total_pending_particles = 0
			return

	# Prepass: compute prefix sum offsets for binary search
	var prefix_sum := 0
	for request in _pending_emissions:
		request["prefix_offset"] = prefix_sum
		prefix_sum += request["count"]

	# Resize emission buffer if needed
	var required_capacity := _pending_emissions.size()
	if required_capacity > emission_buffer_capacity:
		# Double the capacity or use required, whichever is larger
		var new_capacity := maxi(required_capacity, emission_buffer_capacity * 2)
		if not _setup_emission_buffer(new_capacity):
			_pending_emissions.clear()
			_total_pending_particles = 0
			return
		# Recreate uniform set with new buffer
		if uniform_set.is_valid():
			rd.free_rid(uniform_set)
			uniform_set = RID()
		if not _setup_uniform_set():
			_pending_emissions.clear()
			_total_pending_particles = 0
			return

	# Build emission buffer data (sized to actual request count)
	var emission_data := PackedByteArray()
	emission_data.resize(required_capacity * EMISSION_REQUEST_STRIDE)

	var offset := 0
	for request in _pending_emissions:
		# position_template: xyz = position, w = template_id
		var pos: Vector3 = request["position"]
		var template_id: int = request["template_id"]
		emission_data.encode_float(offset, pos.x)
		emission_data.encode_float(offset + 4, pos.y)
		emission_data.encode_float(offset + 8, pos.z)
		emission_data.encode_float(offset + 12, float(template_id))

		# direction_size: xyz = direction, w = size_multiplier
		var dir: Vector3 = request["direction"]
		var size: float = request["size_multiplier"]
		emission_data.encode_float(offset + 16, dir.x)
		emission_data.encode_float(offset + 20, dir.y)
		emission_data.encode_float(offset + 24, dir.z)
		emission_data.encode_float(offset + 28, size)

		# params: x = count, y = speed_scale, z = base_particle_index, w = random_seed
		emission_data.encode_float(offset + 32, float(request["count"]))
		emission_data.encode_float(offset + 36, request["speed_mod"])
		emission_data.encode_float(offset + 40, float(request["base_particle_index"]))
		emission_data.encode_float(offset + 44, float(request["random_seed"]))

		# offset_data: x = prefix_sum_offset (exclusive), yzw = reserved
		emission_data.encode_float(offset + 48, float(request["prefix_offset"]))
		emission_data.encode_float(offset + 52, 0.0)
		emission_data.encode_float(offset + 56, 0.0)
		emission_data.encode_float(offset + 60, 0.0)

		offset += EMISSION_REQUEST_STRIDE

	# Upload emission data
	rd.buffer_update(emission_buffer, 0, emission_data.size(), emission_data)

	# Run emission compute shader
	var push_constants := PackedFloat32Array([
		0.0,  # delta_time (unused for emission)
		float(MAX_PARTICLES),
		float(_total_pending_particles),
		1.0,  # mode = emit
		float(_pending_emissions.size()),  # request_count for binary search
		0.0, 0.0, 0.0  # padding for 32-byte alignment
	])

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, compute_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)

	var workgroups := ceili(float(_total_pending_particles) / float(WORKGROUP_SIZE))
	rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
	rd.compute_list_end()

	# Clear pending
	_pending_emissions.clear()
	_total_pending_particles = 0


func _run_simulation(delta: float) -> void:
	if not uniform_set.is_valid():
		if not _setup_uniform_set():
			return

	var push_constants := PackedFloat32Array([
		delta,
		float(MAX_PARTICLES),
		0.0,  # emission_count (unused for simulation)
		0.0,  # mode = simulate
		0.0,  # request_count (unused for simulation)
		0.0, 0.0, 0.0  # padding for 32-byte alignment
	])

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, compute_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)

	var workgroups := ceili(float(MAX_PARTICLES) / float(WORKGROUP_SIZE))
	rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
	rd.compute_list_end()


func _run_particle_sort() -> void:
	# Get camera position for depth calculation
	# var camera := get_viewport().get_camera_3d()
	# if camera == null:
	# 	return

	# var camera_pos := camera.global_position
	var camera_pos := camera_position

	# Set up sort uniform set if needed
	if not sort_uniform_set.is_valid():
		if not _setup_sort_uniform_set():
			return

	var num_workgroups := ceili(float(MAX_PARTICLES) / float(SORT_WORKGROUP_SIZE))

	# Push constants: camera_pos (vec4), particle_count, tex_width, tex_height, pass_number, mode, workgroup_count, padding x2
	# Total: 12 floats = 48 bytes

	# MODE 0: Compute depth keys and initialize indices
	var push_constants := PackedFloat32Array([
		camera_pos.x, camera_pos.y, camera_pos.z, 0.0,  # camera_pos
		float(MAX_PARTICLES),  # particle_count
		float(PARTICLE_TEX_WIDTH),  # tex_width
		float(PARTICLE_TEX_HEIGHT),  # tex_height
		0.0,  # pass_number
		0.0,  # mode = compute_depth
		float(num_workgroups),  # workgroup_count
		0.0, 0.0  # padding
	])

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)
	rd.compute_list_end()

	# Run 4 radix sort passes (8 bits each = 32 bits total)
	# Note: Barriers between compute passes are now automatic in Godot 4.x
	for pass_num in range(4):
		# MODE 1: Build histogram
		push_constants[7] = float(pass_num)  # pass_number
		push_constants[8] = 1.0  # mode = histogram

		compute_list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
		rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
		rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)
		rd.compute_list_end()

		# MODE 2: Compute prefix sum
		push_constants[8] = 2.0  # mode = scan

		compute_list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
		rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
		rd.compute_list_dispatch(compute_list, 1, 1, 1)  # Single workgroup for scan
		rd.compute_list_end()

		# MODE 3: Scatter to sorted positions
		push_constants[8] = 3.0  # mode = scatter

		compute_list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
		rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
		rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)
		rd.compute_list_end()

	# MODE 4: Write sorted indices to texture
	push_constants[8] = 4.0  # mode = write_texture

	compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)
	rd.compute_list_end()


func clear_all_particles() -> void:
	"""Clear all active particles by zeroing texture data"""
	if not _initialized:
		return

	# Clear particle textures on GPU
	var clear_data := PackedByteArray()
	clear_data.resize(PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT * 16)  # 16 bytes per RGBA32F pixel
	clear_data.fill(0)

	rd.texture_update(particle_position_lifetime_tex, 0, clear_data)
	rd.texture_update(particle_velocity_template_tex, 0, clear_data)
	rd.texture_update(particle_custom_tex, 0, clear_data)

	_next_particle_slot = 0
	_pending_emissions.clear()
	_total_pending_particles = 0


func get_active_particle_count() -> int:
	"""Returns max particles - actual count requires GPU readback which we avoid"""
	return MAX_PARTICLES


func update_shader_uniforms() -> void:
	"""Update shader uniforms when templates change"""
	if not _initialized:
		return

	# Update render material
	_update_render_uniforms()

	# Recreate uniform set with new textures
	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
		uniform_set = RID()

	if template_properties_tex.is_valid():
		rd.free_rid(template_properties_tex)
		template_properties_tex = RID()

	if velocity_curve_tex.is_valid():
		rd.free_rid(velocity_curve_tex)
		velocity_curve_tex = RID()

	_setup_uniform_set()

	print("ComputeParticleSystem: Shader uniforms updated")


func _exit_tree() -> void:
	# Clean up RenderingDevice resources
	if rd == null:
		return

	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
	if emission_buffer.is_valid():
		rd.free_rid(emission_buffer)
	if particle_position_lifetime_tex.is_valid():
		rd.free_rid(particle_position_lifetime_tex)
	if particle_velocity_template_tex.is_valid():
		rd.free_rid(particle_velocity_template_tex)
	if particle_custom_tex.is_valid():
		rd.free_rid(particle_custom_tex)
	if template_properties_tex.is_valid():
		rd.free_rid(template_properties_tex)
	if velocity_curve_tex.is_valid():
		rd.free_rid(velocity_curve_tex)
	if template_properties_sampler.is_valid():
		rd.free_rid(template_properties_sampler)
	if velocity_curve_sampler.is_valid():
		rd.free_rid(velocity_curve_sampler)
	if compute_pipeline.is_valid():
		rd.free_rid(compute_pipeline)
	if compute_shader.is_valid():
		rd.free_rid(compute_shader)

	# Clean up sort resources
	if sort_uniform_set.is_valid():
		rd.free_rid(sort_uniform_set)
	if sort_keys_a.is_valid():
		rd.free_rid(sort_keys_a)
	if sort_keys_b.is_valid():
		rd.free_rid(sort_keys_b)
	if sort_indices_a.is_valid():
		rd.free_rid(sort_indices_a)
	if sort_indices_b.is_valid():
		rd.free_rid(sort_indices_b)
	if sort_histogram.is_valid():
		rd.free_rid(sort_histogram)
	if sort_global_prefix.is_valid():
		rd.free_rid(sort_global_prefix)
	if sorted_indices_tex.is_valid():
		rd.free_rid(sorted_indices_tex)
	if sort_sampler.is_valid():
		rd.free_rid(sort_sampler)
	if sort_pipeline.is_valid():
		rd.free_rid(sort_pipeline)
	if sort_shader.is_valid():
		rd.free_rid(sort_shader)
