extends Resource
class_name ShellParams


enum ShellType {
	HE,
	AP
}

@export var speed: float
@export var time_warp_rate: float = 1.0:
	set(value):
		time_warp_rate = value
		_update_time_warp_k()
@export var time_warp_apex: float = 30.0:
	set(value):
		time_warp_apex = value
		_update_time_warp_k()
@export var drag: float
@export var damage: float
var time_warp_k: float
@export var size: float  # Visual rendering size
@export var caliber: float # Shell caliber in mm for penetration calculations
@export var mass: float  # Shell mass in kg for penetration calculations
@export var fire_buildup: float
@export var fuze_delay: float = 0.035  # Fuse delay in seconds after impact
@export var type: ShellType = ShellType.AP
@export var penetration_modifier: float = 1.0 # Multiplier for penetration calculations
@export var auto_bounce: float = deg_to_rad(60)  # Angle at which shells automatically bounce
@export var ricochet_angle: float = deg_to_rad(45)  # Angle at which shells may ricochet
@export var overmatch: int = 1
@export_storage var _secondary: bool = false # Is this a secondary shell type (for damage tracking)?
@export var arming_threshold: int = 1 # Minimum armor thickness to arm the shell

func _init() -> void:
	speed = 0
	drag = 0.0
	damage = 0
	size = 1
	caliber = 0.0  # Default 380mm caliber
	mass = 0.0  # Default mass for 380mm AP shell in kg
	fuze_delay = 0.035  # Default 3.5ms fuse delay (typical for naval shells)
	type = ShellType.AP
	penetration_modifier = 1.0
	auto_bounce = deg_to_rad(60)  # Default auto-bounce angle
	overmatch = 0
	_secondary = false
	arming_threshold = ceil(caliber * 1.0 / 6.0)
	_update_time_warp_k()

func _update_time_warp_k() -> void:
	if time_warp_apex > 0:
		time_warp_k = (1.0 - time_warp_rate) / pow(time_warp_apex, 2)
	else:
		time_warp_k = 0.0
