extends Node
class_name HitEffects_

## Unified hit effects system using the new particle emitter architecture
## Templates are assigned as resource references and registered lazily on first use

# Template resource references (assigned in editor or via code)
@export_group("Particle Templates")
@export var splash_template: ParticleTemplate
@export var explosion_template: ParticleTemplate
@export var sparks_template: ParticleTemplate
@export var muzzle_blast_template: ParticleTemplate

var _particle_system: UParticleSystem = null
var _initialized: bool = false

# Particle counts per effect type
const SPLASH_PARTICLES: int = 20
const HE_EXPLOSION_PARTICLES: int = 10
const SPARKS_PARTICLES: int = 30
const MUZZLE_BLAST_PARTICLES: int = 20

func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		queue_free()
		return

	# Wait one frame for UnifiedParticleSystem autoload to be ready
	await get_tree().process_frame
	_initialize()

func _initialize() -> void:
	_particle_system = _find_particle_system()

	if _particle_system == null:
		push_error("HitEffects: Could not find UnifiedParticleSystem. Make sure it is added as an autoload.")
		return

	# Register templates lazily
	if splash_template:
		_particle_system.ensure_template_registered(splash_template)
	if explosion_template:
		_particle_system.ensure_template_registered(explosion_template)
	if sparks_template:
		_particle_system.ensure_template_registered(sparks_template)
	if muzzle_blast_template:
		_particle_system.ensure_template_registered(muzzle_blast_template)

	_initialized = true
	print("HitEffects: Initialized with %d templates" % [
		int(splash_template != null) + int(explosion_template != null) +
		int(sparks_template != null) + int(muzzle_blast_template != null)
	])

func _find_particle_system() -> UParticleSystem:
	# Try autoload first
	if has_node("/root/UnifiedParticleSystem"):
		return get_node("/root/UnifiedParticleSystem") as UParticleSystem

	# Search scene tree
	var root = get_tree().root
	for child in root.get_children():
		if child is UParticleSystem:
			return child
		for grandchild in child.get_children():
			if grandchild is UParticleSystem:
				return grandchild
	return null

func splash_effect(pos: Vector3, size: float) -> void:
	if not _initialized or _particle_system == null or splash_template == null:
		return
	if splash_template.template_id < 0:
		_particle_system.ensure_template_registered(splash_template)
	if splash_template.template_id < 0:
		return
	var count = int(SPLASH_PARTICLES)
	var direction = Vector3(0, 1.0, 0)
	_particle_system.emit_particles(pos, direction, splash_template.template_id, size, count, 4.0 / size)

func he_explosion_effect(pos: Vector3, size: float, dir: Vector3) -> void:
	if not _initialized or _particle_system == null or explosion_template == null:
		return
	if explosion_template.template_id < 0:
		_particle_system.ensure_template_registered(explosion_template)
	if explosion_template.template_id < 0:
		return
	var count = int(HE_EXPLOSION_PARTICLES)
	_particle_system.emit_particles(pos, dir, explosion_template.template_id, size * 3.0, count, 3.0 / size)

func sparks_effect(pos: Vector3, size: float, normal: Vector3) -> void:
	if not _initialized or _particle_system == null or sparks_template == null:
		return
	if sparks_template.template_id < 0:
		_particle_system.ensure_template_registered(sparks_template)
	if sparks_template.template_id < 0:
		return
	var count = int(SPARKS_PARTICLES)
	var direction = normal.normalized()
	_particle_system.emit_particles(pos, direction, sparks_template.template_id, size, count, 1.0)

func muzzle_blast_effect(pos: Vector3, basis: Basis, size: float) -> void:
	if not _initialized or _particle_system == null or muzzle_blast_template == null:
		return
	if muzzle_blast_template.template_id < 0:
		_particle_system.ensure_template_registered(muzzle_blast_template)
	if muzzle_blast_template.template_id < 0:
		return
	var count = int(MUZZLE_BLAST_PARTICLES)
	var forward = -basis.z
	var direction = forward.normalized()
	_particle_system.emit_particles(pos, direction, muzzle_blast_template.template_id, size, count, 2.0 / sqrt(size))

func return_to_pool(effect: Node) -> void:
	pass

func print_status() -> void:
	if not _initialized:
		print("HitEffects: Not initialized")
		return
	if _particle_system == null:
		print("HitEffects: No particle system found")
		return
	print("HitEffects: Using UnifiedParticleSystem")
	var templates = [splash_template, explosion_template, sparks_template, muzzle_blast_template]
	var names = ["splash", "explosion", "sparks", "muzzle_blast"]
	for i in templates.size():
		if templates[i]:
			print("  %s: template_id=%d" % [names[i], templates[i].template_id])
		else:
			print("  %s: NOT ASSIGNED" % names[i])
