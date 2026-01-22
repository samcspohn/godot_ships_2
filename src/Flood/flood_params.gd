extends Moddable
class_name FloodParams

@export var dmg_rate: float # per second
@export var dur: float
@export var max_buildup: float
@export var buildup_reduction_rate: float = 0.003 # 3% of max per second (slower than fire)

func _init() -> void:
	dur = 40  # Flooding lasts a bit less than fire
	dmg_rate = .15 / dur # 15% over 40 seconds (more damaging than fire)
	max_buildup = 100
	buildup_reduction_rate = 0.003 # 3% of max per second
