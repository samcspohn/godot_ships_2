extends Moddable
class_name GunParams

@export var reload_time: float
@export var traverse_speed: float
@export var elevation_speed: float
@export var _range: float
@export var shell1: ShellParams
@export var shell2: ShellParams

@export var h_grouping: float = 1.8
@export var v_grouping: float = 1.8
@export var base_spread: float = 0.01

# @export var h_grouping_mod: float = 1.0
# @export var v_grouping_mod: float = 1.0
# @export var base_spread_mod: float = 1.0

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
	h_grouping = gun_params.h_grouping
	v_grouping = gun_params.v_grouping
	base_spread = gun_params.base_spread

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
		"h_grouping": h_grouping,
		"v_grouping": v_grouping,
		"base_spread": base_spread
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
	h_grouping = d.get("h_grouping", 1.8)
	v_grouping = d.get("v_grouping", 1.8)
	base_spread = d.get("base_spread", 0.01)


func calculate_dispersed_launch(aim_point: Vector3, gun_position: Vector3, shell_index: int, target_mod: TargetMod) -> Vector3:
	var shell: ShellParams = shell1 if shell_index == 0 else shell2
	return ArtilleryDispersion.calculate_dispersed_launch(
		aim_point, 
		gun_position, 
		shell.speed, 
		shell.drag, 
		h_grouping * (target_mod.h_grouping if target_mod else 1.0),
		v_grouping * (target_mod.v_grouping if target_mod else 1.0),
		base_spread * (target_mod.base_spread if target_mod else 1.0)
	)
