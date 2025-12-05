extends GPUParticles3D
class_name UnifiedParticleSystem

## Unified particle system that handles all particle types using emit_particle()
## Particles are emitted with template_id and size encoded in COLOR channel

var template_manager: ParticleTemplateManager
var process_material_shader: ShaderMaterial
var draw_material_shader: ShaderMaterial

func _ready() -> void:
	# Get or create template manager
	# if not has_node("/root/ParticleTemplateManager"):
	# 	template_manager = ParticleTemplateManager.new()
	# 	template_manager.name = "ParticleTemplateManager"
	# 	get_tree().root.add_child(template_manager)
	# else:
	# 	template_manager = get_node("/root/ParticleTemplateManager")

	# Set up particle system properties
	amount = 100000  # Large pool of particles
	lifetime = 100.0  # Max lifetime
	one_shot = false
	explosiveness = 0.0
	randomness = 0.0
	fixed_fps = 30
	interpolate = false
	fract_delta = true

	# Set visibility AABB to be very large
	visibility_aabb = AABB(Vector3(-100000, -100000, -100000), Vector3(200000, 200000, 200000))

	# Configure particle rendering
	draw_order = DRAW_ORDER_VIEW_DEPTH
	transform_align = TRANSFORM_ALIGN_Y_TO_VELOCITY

	# Create and configure shaders
	_setup_shaders()

	# Start emitting (particles will be inactive until emission requests)
	emitting = true

	print("UnifiedParticleSystem: Initialized with %d max particles" % amount)

func _setup_shaders() -> void:
	# Load process shader
	var process_shader = load("res://src/particles/shaders/particle_template_process.gdshader")
	if process_shader == null:
		push_error("UnifiedParticleSystem: Failed to load process shader")
		return

	process_material_shader = ShaderMaterial.new()
	process_material_shader.shader = process_shader

	# Apply shader uniforms from template manager
	var uniforms = template_manager.get_shader_uniforms()
	for key in uniforms:
		process_material_shader.set_shader_parameter(key, uniforms[key])

	process_material = process_material_shader

	# Load and set up draw material shader
	var material_shader = load("res://src/particles/shaders/particle_template_material.gdshader")
	if material_shader == null:
		push_error("UnifiedParticleSystem: Failed to load material shader")
		return

	draw_material_shader = ShaderMaterial.new()
	draw_material_shader.shader = material_shader

	# Apply template properties to draw material
	if uniforms.has("template_properties"):
		draw_material_shader.set_shader_parameter("template_properties", uniforms["template_properties"])

	# Apply texture atlas to draw material
	if uniforms.has("texture_atlas"):
		draw_material_shader.set_shader_parameter("texture_atlas", uniforms["texture_atlas"])

	# Apply color ramp atlas to draw material
	if uniforms.has("color_ramp_atlas"):
		draw_material_shader.set_shader_parameter("color_ramp_atlas", uniforms["color_ramp_atlas"])

	# Apply scale curve atlas to draw material
	if uniforms.has("scale_curve_atlas"):
		draw_material_shader.set_shader_parameter("scale_curve_atlas", uniforms["scale_curve_atlas"])

	# Apply emission curve atlas to draw material
	if uniforms.has("emission_curve_atlas"):
		draw_material_shader.set_shader_parameter("emission_curve_atlas", uniforms["emission_curve_atlas"])

	# Create a quad mesh for particles
	var quad = QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.material = draw_material_shader
	draw_pass_1 = quad

	print("UnifiedParticleSystem: Shaders configured")

func emit_particles(pos: Vector3, direction: Vector3,
					template_id, size_multiplier, count, speed_mod) -> void:
	"""
	Emit particles with a specific template using emit_particle().

	Args:
		pos: World position to emit from
		direction: Direction vector for particle emission (will be used with template velocity and size)
		template_id: The ID of the particle template to use (0-255)
		size_multiplier: Scale multiplier for this particle (0-1 range, also scales velocity)
		count: Number of particles to emit
	"""
	if template_id < 0 or template_id >= ParticleTemplateManager.MAX_TEMPLATES:
		push_error("UnifiedParticleSystem: Invalid template_id %d" % template_id)
		return

	var template = template_manager.get_template_by_id(template_id)
	if template == null:
		push_error("UnifiedParticleSystem: Template %d not found" % template_id)
		return

	# Clamp size multiplier
	# size_multiplier = clampf(size_multiplier, 0.0, 1.0)

	# Encode template_id and size in COLOR
	# COLOR.r = template_id (normalized to 0-1)
	# COLOR.g = size_multiplier (0-1)
	# COLOR.b = speed_scale	(0-1)
	# COLOR.a = unused (set to 1)
	var encoded_color := Color(
		float(template_id) / 255.0,
		size_multiplier,
		speed_mod,
		1.0
	)

	# Emit each particle
	for i in count:
		# Create transform at emission position
		var xform := Transform3D.IDENTITY
		xform.origin = pos

		# Emit the particle
		# The process shader will decode COLOR.r and COLOR.g in start()
		# Direction is passed via the velocity parameter - the shader will calculate actual velocity
		emit_particle(
			xform,           # Transform (position)
			direction,       # Direction vector (shader will calculate velocity from this)
			encoded_color,   # COLOR (encodes template_id and size)
			Color.BLACK,     # CUSTOM (required parameter, not used by our shader)
			EMIT_FLAG_POSITION | EMIT_FLAG_VELOCITY | EMIT_FLAG_COLOR
		)

func update_shader_uniforms() -> void:
	"""Update shader uniforms when templates change"""
	if process_material_shader and template_manager:
		var uniforms = template_manager.get_shader_uniforms()
		for key in uniforms:
			process_material_shader.set_shader_parameter(key, uniforms[key])

		if draw_material_shader:
			if uniforms.has("template_properties"):
				draw_material_shader.set_shader_parameter("template_properties", uniforms["template_properties"])
			if uniforms.has("texture_atlas"):
				draw_material_shader.set_shader_parameter("texture_atlas", uniforms["texture_atlas"])
			if uniforms.has("color_ramp_atlas"):
				draw_material_shader.set_shader_parameter("color_ramp_atlas", uniforms["color_ramp_atlas"])
			if uniforms.has("scale_curve_atlas"):
				draw_material_shader.set_shader_parameter("scale_curve_atlas", uniforms["scale_curve_atlas"])
			if uniforms.has("emission_curve_atlas"):
				draw_material_shader.set_shader_parameter("emission_curve_atlas", uniforms["emission_curve_atlas"])

		print("UnifiedParticleSystem: Shader uniforms updated")

func clear_all_particles() -> void:
	"""Clear all active particles"""
	restart()
