extends Resource
class_name ShellParams

@export var speed: float
@export var drag: float
@export var damage: float

func _init() -> void:
	speed = 820
	drag = 0.00895
	damage = 10000
