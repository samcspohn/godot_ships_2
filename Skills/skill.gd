extends Resource
class_name Skill

var _ship: Ship = null

func _a(_ship: Ship):
	pass

func apply(ship: Ship):
	_ship = ship
	ship.add_dynamic_mod(_a)

func remove(ship: Ship):
	ship.remove_dynamic_mod(_a)

func _proc(_delta: float):
	pass
