extends Resource
class_name GunParams

@export var reload_time: float
@export var traverse_speed: float
@export var elevation_speed: float
@export var range: float
@export var shell: ShellParams

func _init() -> void:
	reload_time = 1
	traverse_speed = deg_to_rad(40)
	elevation_speed = deg_to_rad(40)
	range = 20


#extends Resource
#class_name ShellParams
#
#@export var speed: float
#@export var drag: float
#@export var damage: float
#
#func _init() -> void:
	#speed = 820
	#drag = 0.00895
	#damage = 10000
