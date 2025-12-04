extends GPUParticles3D
class_name HitEffect

enum EffectType {
	SPLASH,
	HE_EXPLOSION,
	SPARKS,
	MUZZLE_BLAST,
}

@export_storage var type: EffectType
# @onready var on_screen: VisibleOnScreenNotifier3D = $"VisibleOnScreenNotifier3D"
var time: float = 0.0
var _on_screen: bool = false
var size: float = 1.0

func _ready() -> void:
	emitting = false
	# visible = false
	# finished.connect(_on_effect_finished)
	# process_thread_group = Node.PROCESS_THREAD_GROUP_SUB_THREAD
	# on_screen.aabb = get_aabb()
	# on_screen.screen_entered.connect(_on_screen_entered)
	# on_screen.screen_exited.connect(_on_screen_exited)

func _on_screen_entered() -> void:
	# print("Effect on screen: ", self)
	if visible:
		_on_screen = true
		var curr_time = Time.get_ticks_msec()
		var elapsed = (curr_time - time) / 1000.0
		var remaining = 1.0 - (lifetime / speed_scale - elapsed) / (lifetime / speed_scale)
		if remaining > 0:
			preprocess = remaining
		else:
			preprocess = 0.0
		restart()

func _on_screen_exited() -> void:
	# print("Effect off screen: ", self)
	if visible:
		_on_screen = false
		# visible = false
		emitting = false
		# preprocess = 0.0

func start_effect() -> void:
# # Keep invisible during reset
# 	visible = false
# 	emitting = false

# 	# Force clear the particle system
# 	restart()

# 	# Wait one frame for GPU buffer to clear
# 	await get_tree().process_frame

# 	# Now safe to show and emit
# 	visible = true
# 	emitting = true

# 	# Set up the return timer based on actual duration
	preprocess = 0.0
	visible = true
	restart()
	time = Time.get_ticks_msec()
	# end_time = Time.get_ticks_msec() + int(lifetime * 1000 / speed_scale)
	get_tree().create_timer(lifetime / speed_scale).timeout.connect(_on_effect_finished)
	emitting = true

# func _process(_delta: float) -> void:
# 	if emitting and Time.get_ticks_msec() >= end_time:
# 		_on_effect_finished()


func _on_effect_finished() -> void:
	# print("Effect finished: ", self)
	visible = false
	emitting = false
	# finished.disconnect(_on_effect_finished)

	HitEffects.return_to_pool(self)
