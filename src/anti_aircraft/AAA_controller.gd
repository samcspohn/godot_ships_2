extends WeaponController
class_name AAAController

@export var dps: float = 0.0
@export var _range: float = 0.0

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship
