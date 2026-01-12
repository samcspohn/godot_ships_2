extends Moddable

class_name HpPartMod

@export var pool1: float = 100.0
@export var pool2: float = 100.0

var current_pool1: float
var current_pool2: float

var healable_damage: float = 0.0

func init(_ship: Ship) -> void:
	current_pool1 = pool1
	current_pool2 = pool2
	super.init(_ship)


func apply_damage(dmg: float) -> float:
	var dmg1 = dmg * 0.5
	var dmg2 = dmg * 0.5

	if current_pool1 > 0:
		if current_pool1 >= dmg1:
			current_pool1 -= dmg1
		else:
			dmg1 -= current_pool1
			current_pool1 = 0
	else:
		dmg1 = 0.0
	if current_pool2 > 0:
		if current_pool2 >= dmg2:
			current_pool2 -= dmg2
		else:
			dmg2 -= current_pool2
			current_pool2 = 0
	else:
		dmg2 = 0.0

	healable_damage += (dmg1 + dmg2) * 0.5 # TODO: account for light/medium/heavy damage

	return dmg1 + dmg2
