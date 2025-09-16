extends Moddable
class_name GunParams

@export var reload_time: float
@export var traverse_speed: float
@export var elevation_speed: float
@export var _range: float
@export var shell1: ShellParams
@export var shell2: ShellParams

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
	_range = 20

func from_params(gun_params: GunParams) -> void:
	reload_time = gun_params.reload_time
	traverse_speed = gun_params.traverse_speed
	elevation_speed = gun_params.elevation_speed
	_range = gun_params._range
	shell1 = gun_params.shell1
	shell2 = gun_params.shell2
	hor_dispersion = gun_params.hor_dispersion
	vert_dispersion = gun_params.vert_dispersion
	vert_sigma = gun_params.vert_sigma
	hor_sigma = gun_params.hor_sigma
	hor_dispersion_rate = gun_params.hor_dispersion_rate
	vert_dispersion_rate = gun_params.vert_dispersion_rate

func to_dict() -> Dictionary:
	return {
		"reload_time": reload_time,
		"traverse_speed": traverse_speed,
		"elevation_speed": elevation_speed,
		"range": _range,
		"shell1": {
			"speed": shell1.speed,
			"drag": shell1.drag,
			"damage": shell1.damage
		},
		"shell2": {
			"speed": shell2.speed,
			"drag": shell2.drag,
			"damage": shell2.damage
		},
		"hor_dispersion": hor_dispersion,
		"vert_dispersion": vert_dispersion,
		"vert_sigma": vert_sigma,
		"hor_sigma": hor_sigma,
		"hor_dispersion_rate": hor_dispersion_rate,
		"vert_dispersion_rate": vert_dispersion_rate
	}

func from_dict(d: Dictionary) -> void:
	reload_time = d.get("reload_time", 1)
	traverse_speed = d.get("traverse_speed", deg_to_rad(40))
	elevation_speed = d.get("elevation_speed", deg_to_rad(40))
	_range = d.get("range", 20)
	var s1 = d.get("shell1", {})
	# shell1 = ShellParams.new()
	shell1.speed = s1.get("speed", 820)
	shell1.drag = s1.get("drag", 0.00895)
	shell1.damage = s1.get("damage", 10000)
	var s2 = d.get("shell2", {})
	# shell2 = ShellParams.new()
	shell2.speed = s2.get("speed", 820)
	shell2.drag = s2.get("drag", 0.00895)
	shell2.damage = s2.get("damage", 10000)
	hor_dispersion = d.get("hor_dispersion", 0.001)
	vert_dispersion = d.get("vert_dispersion", 0.001)
	vert_sigma = d.get("vert_sigma", 1.0)
	hor_sigma = d.get("hor_sigma", 1.0)
	hor_dispersion_rate = d.get("hor_dispersion_rate", 0.0)
	vert_dispersion_rate = d.get("vert_dispersion_rate", 0.0)

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
