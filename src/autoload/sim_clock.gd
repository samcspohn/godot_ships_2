extends Node

# Starts well past zero so "0 = never" timestamps read as long ago, as they did on the wall clock.
const EPOCH: float = 1000.0

var _t: float = EPOCH


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000


func _physics_process(delta: float) -> void:
	_t += delta


func now() -> float:
	return _t


func now_ms() -> int:
	return int(_t * 1000.0)
