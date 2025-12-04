extends Node
class_name HitEffects_

## Unified hit effects system using the new particle emitter architecture
## Replaces individual GPUParticles3D with ParticleEmitter-based effects
## Maintains the same API for backward compatibility

# Cached template references for performance
var _templates: Dictionary = {}
var _particle_system: UnifiedParticleSystem = null
var _initialized: bool = false

# Effect type enum (matches HitEffect.EffectType)
enum EffectType {
	SPLASH,
	HE_EXPLOSION,
	SPARKS,
	MUZZLE_BLAST,
}

# Particle counts per effect type
const SPLASH_PARTICLES: int = 15
const HE_EXPLOSION_PARTICLES: int = 10
const SPARKS_PARTICLES: int = 30
const MUZZLE_BLAST_PARTICLES: int = 15

# Size scaling factors for particle velocity and count
const SIZE_VELOCITY_SCALE: float = 1.0
const SIZE_COUNT_SCALE: float = 0.5

func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		queue_free()
		return

	# Wait one frame for ParticleSystemInit to complete
	await get_tree().process_frame
	_initialize()

func _initialize() -> void:
	"""Initialize the particle system and cache templates"""

	# Get reference to unified particle system
	_particle_system = _find_particle_system()

	if _particle_system == null:
		push_error("HitEffects: Could not find UnifiedParticleSystem. Make sure ParticleSystemInit is added as an autoload.")
		return

	# Cache template references
	_cache_templates()

	_initialized = true
	print("HitEffects: Initialized with new particle system")

func _cache_templates() -> void:
	"""Cache template references for fast lookups"""

	if not has_node("/root/ParticleSystemInit"):
		push_error("HitEffects: ParticleSystemInit autoload not found")
		return

	var init = get_node("/root/ParticleSystemInit")

	_templates[EffectType.SPLASH] = init.get_template_by_name("splash")
	_templates[EffectType.HE_EXPLOSION] = init.get_template_by_name("explosion")
	_templates[EffectType.SPARKS] = init.get_template_by_name("sparks")
	_templates[EffectType.MUZZLE_BLAST] = init.get_template_by_name("muzzle_blast")

	# Validate templates
	for type in _templates:
		var template = _templates[type]
		if template == null:
			push_error("HitEffects: Template for effect type %d not found" % type)
		elif template.template_id < 0:
			push_error("HitEffects: Template '%s' not registered (template_id < 0)" % template.template_name)

func _find_particle_system() -> UnifiedParticleSystem:
	"""Find the unified particle system in the scene tree"""

	# Try to get from ParticleSystemInit
	if has_node("/root/ParticleSystemInit"):
		var init = get_node("/root/ParticleSystemInit")
		if init.has_method("get_particle_system"):
			var system = init.get_particle_system()
			if system != null:
				return system

	# Search scene tree
	var root = get_tree().root
	for child in root.get_children():
		if child is UnifiedParticleSystem:
			return child
		# Search one level deeper
		for grandchild in child.get_children():
			if grandchild is UnifiedParticleSystem:
				return grandchild

	return null

func splash_effect(pos: Vector3, size: float) -> void:
	"""
	Create a water splash effect

	Args:
		pos: World position for the splash
		size: Scale multiplier for splash size/intensity
	"""

	if not _initialized or _particle_system == null:
		return

	var template = _templates.get(EffectType.SPLASH)
	if template == null or template.template_id < 0:
		return

	var count = int(SPLASH_PARTICLES)

	# Direction for splash (upward)
	var direction = Vector3(0, 1.0, 0)

	_particle_system.emit_particles(pos, direction, template.template_id, size * 4, count)

func he_explosion_effect(pos: Vector3, size: float) -> void:
	"""
	Create a high-explosive explosion effect

	Args:
		pos: World position for the explosion
		size: Scale multiplier for explosion size/intensity
	"""

	if not _initialized or _particle_system == null:
		return

	var template = _templates.get(EffectType.HE_EXPLOSION)
	if template == null or template.template_id < 0:
		return

	var count = int(HE_EXPLOSION_PARTICLES)

	# No specific direction (explosion radiates outward via template spread)
	var direction = Vector3.ZERO

	_particle_system.emit_particles(pos, direction, template.template_id, size * size * 2.5, count)

func sparks_effect(pos: Vector3, size: float) -> void:
	"""
	Create a metal sparks effect

	Args:
		pos: World position for the sparks
		size: Scale multiplier for spark count/intensity
	"""

	if not _initialized or _particle_system == null:
		return

	var template = _templates.get(EffectType.SPARKS)
	if template == null or template.template_id < 0:
		return

	var count = int(SPARKS_PARTICLES)

	# No specific direction (sparks emit in all directions via template spread)
	var direction = Vector3.ZERO

	_particle_system.emit_particles(pos, direction, template.template_id,  size * 0.5, count)

func muzzle_blast_effect(pos: Vector3, basis: Basis, size: float) -> void:
	"""
	Create a muzzle blast effect with directional orientation

	Args:
		pos: World position for the muzzle blast
		basis: Orientation basis (forward direction of the gun)
		size: Scale multiplier for blast size/intensity
	"""

	if not _initialized or _particle_system == null:
		return

	var template = _templates.get(EffectType.MUZZLE_BLAST)
	if template == null or template.template_id < 0:
		return

	var count = int(MUZZLE_BLAST_PARTICLES )

	# Forward direction based on gun orientation
	var forward = -basis.z  # Gun forward direction
	var direction = forward.normalized()

	_particle_system.emit_particles(pos, direction, template.template_id, size * 1.25, count)

# Legacy compatibility methods (for old pool-based system)
func return_to_pool(effect: Node) -> void:
	"""
	Legacy method for pool-based particle system
	No longer needed with unified particle system
	"""
	pass

func print_status() -> void:
	"""Print diagnostic information about the particle system"""

	if not _initialized:
		print("HitEffects: Not initialized")
		return

	if _particle_system == null:
		print("HitEffects: No particle system found")
		return

	print("HitEffects: Using UnifiedParticleSystem")
	print("  Templates cached: %d" % _templates.size())

	for type in _templates:
		var template = _templates[type]
		if template:
			print("    %s: template_id=%d" % [template.template_name, template.template_id])
		else:
			print("    Effect type %d: MISSING" % type)

# Helper method for direct emission by effect name
func emit_effect(effect_name: String, pos: Vector3, size: float = 1.0, velocity: Vector3 = Vector3.ZERO) -> void:
	"""
	Generic emission method by effect name

	Args:
		effect_name: Name of the effect template ("splash", "explosion", "sparks", "muzzle_blast")
		pos: World position
		size: Size multiplier
		velocity: Base velocity
	"""

	if not _initialized or _particle_system == null:
		return

	# Map effect name to type
	var effect_type: EffectType
	match effect_name.to_lower():
		"splash":
			effect_type = EffectType.SPLASH
		"explosion", "he_explosion":
			effect_type = EffectType.HE_EXPLOSION
		"sparks":
			effect_type = EffectType.SPARKS
		"muzzle_blast", "muzzle":
			effect_type = EffectType.MUZZLE_BLAST
		_:
			push_error("HitEffects: Unknown effect name '%s'" % effect_name)
			return

	var template = _templates.get(effect_type)
	if template == null or template.template_id < 0:
		return

	var count = _get_default_count(effect_type)
	count = int(count * (1.0 + size * SIZE_COUNT_SCALE))

	# velocity parameter is now treated as direction
	var direction = velocity.normalized() if velocity.length() > 0.0 else Vector3.ZERO
	_particle_system.emit_particles(pos, direction, template.template_id, size, count)

func _get_default_count(effect_type: EffectType) -> int:
	"""Get default particle count for effect type"""
	match effect_type:
		EffectType.SPLASH:
			return SPLASH_PARTICLES
		EffectType.HE_EXPLOSION:
			return HE_EXPLOSION_PARTICLES
		EffectType.SPARKS:
			return SPARKS_PARTICLES
		EffectType.MUZZLE_BLAST:
			return MUZZLE_BLAST_PARTICLES
		_:
			return 10
