extends Node3D
class_name UnifiedParticleSystem

## Unified particle system that handles all particle types
## Now uses compute shader-based ComputeParticleSystem for GPU-accelerated simulation
## Maintains the same API for backward compatibility

const ComputeParticleSystemClass = preload("res://src/particles/compute_particle_system.gd")

var template_manager: ParticleTemplateManager
var _compute_system: Node3D  # ComputeParticleSystem
var _initialized: bool = false

func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		queue_free()
		return
	
	# Create compute particle system
	_compute_system = ComputeParticleSystemClass.new()
	_compute_system.name = "ComputeParticleSystem"
	add_child(_compute_system)
	
	# Wait for template manager to be assigned
	call_deferred("_deferred_init")

func _deferred_init() -> void:
	if template_manager:
		_compute_system.template_manager = template_manager
		_initialized = true
		print("UnifiedParticleSystem: Initialized with compute shader backend")
	else:
		push_error("UnifiedParticleSystem: No template manager assigned")

func emit_particles(pos: Vector3, direction: Vector3,
					template_id, size_multiplier, count, speed_mod) -> void:
	"""
	Emit particles with a specific template.
	
	This is the primary emission API. All particle requests are batched and
	processed efficiently on the GPU via compute shaders.

	Args:
		pos: World position to emit from
		direction: Direction vector for particle emission
		template_id: The ID of the particle template to use (0-15)
		size_multiplier: Scale multiplier for particles (also affects velocity)
		count: Number of particles to emit
		speed_mod: Time scale multiplier for particle animation
	"""
	if not _initialized or _compute_system == null:
		push_warning("UnifiedParticleSystem: Not initialized, deferring emission")
		call_deferred("emit_particles", pos, direction, template_id, size_multiplier, count, speed_mod)
		return
	
	_compute_system.emit_particles(pos, direction, template_id, size_multiplier, count, speed_mod)


func emit_trail(from_pos: Vector3, to_pos: Vector3, velocity_dir: Vector3,
				template_id: int, size_multiplier: float, step_size: float = 20.0,
				speed_mod: float = 1.0) -> int:
	"""
	Emit trail particles along a path from from_pos to to_pos.
	Used for shell trails and similar velocity-aligned effects.
	
	Args:
		from_pos: Starting position of the trail segment
		to_pos: Ending position of the trail segment
		velocity_dir: Direction vector for velocity alignment (normalized movement direction)
		template_id: The ID of the particle template (should have align_to_velocity enabled)
		size_multiplier: Scale multiplier for particles
		step_size: Distance between trail particles (default 20 units)
		speed_mod: Time scale multiplier
	
	Returns:
		Number of particles emitted
	"""
	if not _initialized or _compute_system == null:
		return 0
	
	return _compute_system.emit_trail(from_pos, to_pos, velocity_dir, template_id, 
									   size_multiplier, step_size, speed_mod)


func update_shader_uniforms() -> void:
	"""Update shader uniforms when templates change"""
	if _compute_system:
		_compute_system.update_shader_uniforms()
		print("UnifiedParticleSystem: Shader uniforms updated")

func clear_all_particles() -> void:
	"""Clear all active particles"""
	if _compute_system:
		_compute_system.clear_all_particles()

func get_active_particle_count() -> int:
	"""Get the number of currently active particles"""
	if _compute_system:
		return _compute_system.get_active_particle_count()
	return 0

func get_particles_emitted_this_frame() -> int:
	"""Get the number of particles emitted this frame"""
	if _compute_system:
		return _compute_system.get_particles_emitted_this_frame()
	return 0
