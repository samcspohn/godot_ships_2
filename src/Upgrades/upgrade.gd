extends Resource
class_name Upgrade

var upgrade_id: String = ""
var icon: Texture2D
var name: String = ""
var description: String = ""

func _a(_ship: Ship):
	pass

func apply(_ship: Ship):
	_ship.add_static_mod(_a)

func remove(_ship: Ship):
	_ship.remove_static_mod(_a)
