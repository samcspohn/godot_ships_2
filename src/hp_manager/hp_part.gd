extends Moddable

class_name HpPartMod

@export var pool1: float = 100.0
@export var pool2: float = 100.0

var current_pool1: float
var current_pool2: float

var healable_damage: float = 0.0

var hp: HPManager

func instantiate(ship: Ship) -> Moddable:
	var inst = super.instantiate(ship)
	inst.current_pool1 = inst.pool1
	inst.current_pool2 = inst.pool2
	return inst

## Backward-compat shim — remove once all call sites use instantiate().
func init(_ship: Ship) -> void:
	current_pool1 = pool1
	current_pool2 = pool2
	super.init(_ship)


func apply_damage(dmg: float, rate: float = 0.5) -> float:
	var dmg1 = dmg * rate
	var dmg2 = dmg * (1.0 - rate)

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

	# var healable = (dmg1 + dmg2) * 0.5
	# hp.healable_damage += healable # TODO: account for light/medium/heavy damage
	# healable_damage += healable # TODO: account for light/medium/heavy damage

	return dmg1 + dmg2

func heal(amount: float) -> float:
	var heal1 = amount / 3.0
	var heal2 = amount / 3.0 * 2.0
	var healable1 = healable_damage / 3.0
	var healable2 = healable1 * 2.0
	if healable1 > 0:
		if healable1 >= heal1:
			healable1 -= heal1
		else:
			heal1 = healable1
			healable1 = 0.0
	else:
		heal1 = 0.0
	if healable2 > 0:
		if healable2 >= heal2:
			healable2 -= heal2
		else:
			heal2 = healable2
			healable2 = 0.0
	else:
		heal2 = 0.0

	current_pool1 += heal1
	current_pool2 += heal2
	healable_damage = healable1 + healable2
	return heal1 + heal2
