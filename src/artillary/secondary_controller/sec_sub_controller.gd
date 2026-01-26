extends Node
class_name SecSubController

@export var params: GunParams
@export var guns: Array[Gun]
var sequential_fire_timer: float = 0.0
var controller: SecondaryController_ = null

func init(_ship: Ship) -> void:
	params.shell1._secondary = true
	params.shell2._secondary = true
	params.init(_ship)
	guns.sort_custom(func(a, b):
		# sort by side (x) then z
		var _a = a.get_parent()
		var _b = b.get_parent()
		if sign(_a.position.x) == sign(_b.position.x):
			if _a.position.z <= _b.position.z:
				return true
			else:
				return false
		else:
			return sign(_a.position.x) < sign(_b.position.x)
	)
	for g in guns:
		g._ship = _ship
		g.controller = self

func to_dict() -> Dictionary:
	return params.dynamic_mod.to_dict()

func to_bytes() -> PackedByteArray:
	return params.dynamic_mod.to_bytes()

func from_dict(d: Dictionary) -> void:
	params.dynamic_mod.from_dict(d)

func from_bytes(b: PackedByteArray) -> void:
	# var reader = StreamPeerBuffer.new()
	# reader.data_array = b
	params.dynamic_mod.from_bytes(b)

func get_params() -> GunParams:
	return params.dynamic_mod as GunParams

func get_shell_params() -> ShellParams:
	if controller.shell_index == 0:
		return params.dynamic_mod.shell1
	return params.dynamic_mod.shell2
