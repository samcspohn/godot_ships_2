extends Node

# Starts well past zero so "0 = never" timestamps read as long ago, as they did on the wall clock.
const EPOCH: float = 1000.0

var _t: float = EPOCH
## --sim-speed N: hold sim time to N times wall time (a --fixed-fps server otherwise runs flat out).
var _pace: float = float(CmdArgs.value("--sim-speed", "0"))
var _wall0: int = -1
var _sim0: float = 0.0
const PACE_SLACK_US: int = 250000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000


func _physics_process(delta: float) -> void:
	_t += delta
	if _pace <= 0.0:
		return
	if _wall0 < 0:
		_wall0 = Time.get_ticks_usec()
		_sim0 = _t
	var ahead: int = int((_t - _sim0) / _pace * 1.0e6) - (Time.get_ticks_usec() - _wall0)
	if ahead > 0:
		OS.delay_usec(ahead)
	elif ahead < -PACE_SLACK_US:
		# Fallen behind: carry on from here rather than sprint to catch up.
		_wall0 = Time.get_ticks_usec()
		_sim0 = _t


func now() -> float:
	return _t


func now_ms() -> int:
	return int(_t * 1000.0)
