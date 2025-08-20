extends Resource
class_name ShellParams

@export var speed: float
@export var drag: float
@export var damage: float
@export var size: float  # Visual rendering size
@export var caliber: float  # Shell caliber in mm for penetration calculations
@export var mass: float  # Shell mass in kg for penetration calculations
@export var fire_buildup: float
@export var fuze_delay: float = 0.035  # Fuse delay in seconds after impact
@export var type: int = 0 # 0 = HE, 1 = AP
@export var penetration_modifier: float = 1.0 # Multiplier for penetration calculations
@export var auto_bounce: float = deg_to_rad(60)  # Angle at which shells automatically bounce
var id: int = -1

func _init() -> void:
	speed = 820
	drag = 0.00895
	damage = 10000
	size = 3
	caliber = 380.0  # Default 380mm caliber
	mass = 530.0  # Default mass for 380mm AP shell in kg
	fuze_delay = 0.035  # Default 3.5ms fuse delay (typical for naval shells)
	type = 0
	penetration_modifier = 1.0
	auto_bounce = deg_to_rad(60)  # Default auto-bounce angle
