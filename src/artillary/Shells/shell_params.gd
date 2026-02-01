extends Resource
class_name ShellParams

const GRAVITY: float = 9.81

enum ShellType {
	HE,
	AP
}

@export var speed: float
@export_range(0.00000,0.0001,0.000001) var drag: float:
	set(value):
		drag = value
		_update_derived_values()
@export_storage var vt: float  # Terminal velocity = sqrt(g / beta)
@export_storage var tau: float  # Time constant = vt / g
@export var damage: float
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
	vt = 0.0
	tau = 0.0
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


func _update_derived_values() -> void:
	if drag > 0.0:
		vt = sqrt(GRAVITY / drag)
		tau = vt / GRAVITY
	else:
		vt = 0.0
		tau = 0.0
