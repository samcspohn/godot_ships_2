extends Resource
class_name Skill

var _ship: Ship = null
var description: String = ""
var name: String = ""

func _init() -> void:
	setup_local_to_scene()

func _a(_ship: Ship):
	pass

func apply(ship: Ship):
	_ship = ship
	ship.add_dynamic_mod(_a)

func remove(ship: Ship):
	ship.remove_dynamic_mod(_a)

func _proc(_delta: float):
	pass
