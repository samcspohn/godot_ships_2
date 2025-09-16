extends Moddable
class_name FireParams

@export var dmg_rate: float # per second
@export var dur: float
@export var max_buildup: float
@export var buildup_reduction_rate: float = 0.005 # 5% of max per second

func _init() -> void:
	dur = 50
	dmg_rate = .1 / dur # 10% over 50 seconds
	max_buildup = 100
	buildup_reduction_rate = 0.005 # 5% of max per second
