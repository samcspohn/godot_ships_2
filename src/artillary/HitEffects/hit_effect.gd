extends GPUParticles3D
class_name HitEffect

enum EffectType {
	SPLASH,
	HE_EXPLOSION,
	SPARKS,
	MUZZLE_BLAST,
}

@export_storage var type: EffectType

func _ready() -> void:
	emitting = false
	visible = false
	# finished.connect(_on_effect_finished)

func start_effect() -> void:
# Keep invisible during reset
	visible = false
	emitting = false
	
	# Force clear the particle system
	restart()
	
	# Wait one frame for GPU buffer to clear
	await get_tree().process_frame
	
	# Now safe to show and emit
	visible = true
	emitting = true

	# Set up the return timer based on actual duration
	get_tree().create_timer(lifetime / speed_scale).timeout.connect(_on_effect_finished)


func _on_effect_finished() -> void:
	visible = false
	emitting = false
	# finished.disconnect(_on_effect_finished)

	HitEffects.return_to_pool(self)
