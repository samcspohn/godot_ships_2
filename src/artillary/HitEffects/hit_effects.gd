extends Node
class_name HitEffects_

## Unified hit effects system using the new particle emitter architecture
## Templates are assigned as resource references and register themselves lazily on first use

# Template resource references (assigned in editor or via code)
@export_group("Particle Templates")
@export var splash_template: ParticleTemplate
@export var explosion_template: ParticleTemplate
@export var sparks_template: ParticleTemplate
@export var muzzle_blast_template: ParticleTemplate

# Particle counts per effect type
const SPLASH_PARTICLES: int = 20
const HE_EXPLOSION_PARTICLES: int = 10
const SPARKS_PARTICLES: int = 30
const MUZZLE_BLAST_PARTICLES: int = 20

func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		queue_free()
		return

func splash_effect(pos: Vector3, size: float) -> void:
	if splash_template == null:
		return
	splash_template.emit(pos, Vector3.UP, size, SPLASH_PARTICLES, 4.0 / size)

func he_explosion_effect(pos: Vector3, size: float, dir: Vector3) -> void:
	if explosion_template == null:
		return
	explosion_template.emit(pos, dir, size * 3.0, HE_EXPLOSION_PARTICLES, 3.0 / size)

func sparks_effect(pos: Vector3, size: float, normal: Vector3) -> void:
	if sparks_template == null:
		return
	sparks_template.emit(pos, normal.normalized(), size, SPARKS_PARTICLES, 1.0)

func muzzle_blast_effect(pos: Vector3, basis: Basis, size: float) -> void:
	if muzzle_blast_template == null:
		return
	var direction = (-basis.z).normalized()
	muzzle_blast_template.emit(pos, direction, size, MUZZLE_BLAST_PARTICLES, 2.0 / sqrt(size))

func return_to_pool(effect: Node) -> void:
	pass

func print_status() -> void:
	print("HitEffects: Using UnifiedParticleSystem")
	var templates = [splash_template, explosion_template, sparks_template, muzzle_blast_template]
	var names = ["splash", "explosion", "sparks", "muzzle_blast"]
	for i in templates.size():
		if templates[i]:
			print("  %s: template_id=%d" % [names[i], templates[i].template_id])
		else:
			print("  %s: NOT ASSIGNED" % names[i])
