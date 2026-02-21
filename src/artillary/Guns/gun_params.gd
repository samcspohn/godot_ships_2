# extends Moddable
extends TurretParams
class_name GunParams

# @export var reload_time: float
# @export var traverse_speed: float
@export var elevation_speed: float
# @export var _range: float
@export var shell1: ShellParams
@export var shell2: ShellParams

@export var h_grouping: float = 1.8
@export var v_grouping: float = 1.8
@export var base_spread: float = 0.01

# @export var h_grouping_mod: float = 1.0
# @export var v_grouping_mod: float = 1.0
# @export var base_spread_mod: float = 1.0


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

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()

	writer.put_float(reload_time)
	writer.put_float(traverse_speed)
	writer.put_float(elevation_speed)
	writer.put_float(_range)

	writer.put_float(shell1.speed)
	writer.put_float(shell1.drag)
	writer.put_float(shell1.damage)

	writer.put_float(shell2.speed)
	writer.put_float(shell2.drag)
	writer.put_float(shell2.damage)

	writer.put_float(h_grouping)
	writer.put_float(v_grouping)
	writer.put_float(base_spread)

	return writer.get_data_array()


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

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	reload_time = reader.get_float()
	traverse_speed = reader.get_float()
	elevation_speed = reader.get_float()
	_range = reader.get_float()
	shell1.speed = reader.get_float()
	shell1.drag = reader.get_float()
	shell1.damage = reader.get_float()
	shell2.speed = reader.get_float()
	shell2.drag = reader.get_float()
	shell2.damage = reader.get_float()
	h_grouping = reader.get_float()
	v_grouping = reader.get_float()
	base_spread = reader.get_float()


#func calculate_dispersed_launch(aim_point: Vector3, gun_position: Vector3, shell: ShellParams, target_mod: TargetMod) -> Vector3:
	##var shell: ShellParams = shell1 if shell_index == 0 else shell2
	#return DispersionCalculator.calculate_dispersed_launch(
		#aim_point,
		#gun_position,
		#shell,
		#h_grouping * (target_mod.h_grouping if target_mod else 1.0),
		#v_grouping * (target_mod.v_grouping if target_mod else 1.0),
		#base_spread * (target_mod.base_spread if target_mod else 1.0)
	#)
