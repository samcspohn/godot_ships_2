extends Resource
class_name GunParams

@export var reload_time: float
@export var traverse_speed: float
@export var elevation_speed: float
@export var range: float
@export var shell1: ShellParams
@export var shell2: ShellParams
var shell: ShellParams:
	get:
		return shell
	set(value):
		shell = value
@export var hor_dispersion: float
@export var vert_dispersion: float
@export var vert_sigma: float
@export var hor_sigma: float
@export var hor_dispersion_rate: float
@export var vert_dispersion_rate: float

func _init() -> void:
	reload_time = 1
	traverse_speed = deg_to_rad(40)
	elevation_speed = deg_to_rad(40)
	range = 20
	shell = shell2

func from_params(gun_params: GunParams) -> void:
	reload_time = gun_params.reload_time
	traverse_speed = gun_params.traverse_speed
	elevation_speed = gun_params.elevation_speed
	range = gun_params.range
	shell1 = gun_params.shell1
	shell2 = gun_params.shell2
	shell = gun_params.shell
	hor_dispersion = gun_params.hor_dispersion
	vert_dispersion = gun_params.vert_dispersion
	vert_sigma = gun_params.vert_sigma
	hor_sigma = gun_params.hor_sigma
	hor_dispersion_rate = gun_params.hor_dispersion_rate
	vert_dispersion_rate = gun_params.vert_dispersion_rate

#func set_shell(new_shell: ShellParams) -> void:
	#shell = new_shell
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
