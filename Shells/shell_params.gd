extends Resource
class_name ShellParams

@export var speed: float
@export var drag: float
@export var damage: float
@export var size: float
var id: int = -1

func _init() -> void:
	speed = 820
	drag = 0.00895
	damage = 10000
	size = 3
