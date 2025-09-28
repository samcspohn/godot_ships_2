extends Node
class_name SecSubController

@export var p: GunParams
@export var guns: Array[Gun]
var sequential_fire_timer: float = 0.0
var controller: SecondaryController_ = null
var shell_index: int:
	get:
		return controller.shell_index

func init(_ship: Ship) -> void:
	p.reload_time *= 0.5
	p.shell1._secondary = true
	p.shell2._secondary = true
	p.init(_ship)
	for g in guns:
		g._ship = _ship
		g.controller = self

func to_dict() -> Dictionary:
	return p.dynamic_mod.to_dict()

func from_dict(d: Dictionary) -> void:
	p.dynamic_mod.from_dict(d)

func get_params() -> GunParams:
	return p.dynamic_mod as GunParams

func get_shell_params() -> ShellParams:
	if controller.shell_index == 0:
		return p.dynamic_mod.shell1
	return p.dynamic_mod.shell2
