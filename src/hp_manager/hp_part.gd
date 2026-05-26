extends Moddable

class_name HpPartMod

@export var pool1: float = 100.0
@export var pool2: float = 100.0

var current_pool1: float
var current_pool2: float

var healable_damage: float = 0.0
var healable_pool1: float = 0.0
var healable_pool2: float = 0.0

var hp: HPManager

func instantiate(ship: Ship) -> Moddable:
	var inst = super.instantiate(ship)
	inst.current_pool1 = inst.pool1
	inst.current_pool2 = inst.pool2
	inst.healable_damage = 0.0
	inst.healable_pool1 = 0.0
	inst.healable_pool2 = 0.0
	return inst

## Backward-compat shim — remove once all call sites use instantiate().
func init(_ship: Ship) -> void:
	current_pool1 = pool1
	current_pool2 = pool2
	healable_damage = 0.0
	healable_pool1 = 0.0
	healable_pool2 = 0.0
	super.init(_ship)


func _sync_healable_damage() -> void:
	healable_damage = healable_pool1 + healable_pool2


func apply_damage(dmg: float, rate: float = 0.5, repair_rate: float = 0.0) -> float:
	var dmg1 = dmg * rate
	var dmg2 = dmg * (1.0 - rate)
	var damage_to_pool1 = min(current_pool1, dmg1)
	var damage_to_pool2 = min(current_pool2, dmg2)

	current_pool1 -= damage_to_pool1
	current_pool2 -= damage_to_pool2

	if repair_rate > 0.0:
		healable_pool1 = clamp(healable_pool1 + damage_to_pool1 * repair_rate, 0.0, pool1 - current_pool1)
		healable_pool2 = clamp(healable_pool2 + damage_to_pool2 * repair_rate, 0.0, pool2 - current_pool2)
		_sync_healable_damage()

	return damage_to_pool1 + damage_to_pool2

func heal(amount: float) -> float:
	if amount <= 0.0 or healable_damage <= 0.0:
		return 0.0

	var heal2 = min(amount * 2.0 / 3.0, healable_pool2) # 2/3 goes to the larger pool
	var heal1 = min(amount - heal2, healable_pool1) # remaining amount goes to smaller pool
	var remaining = amount - heal1 - heal2

	if remaining > 0.0 and healable_pool2 > heal2:
		var extra_heal2 = min(remaining, healable_pool2 - heal2)
		heal2 += extra_heal2
		remaining -= extra_heal2
	if remaining > 0.0 and healable_pool1 > heal1:
		var extra_heal1 = min(remaining, healable_pool1 - heal1)
		heal1 += extra_heal1

	current_pool1 = min(current_pool1 + heal1, pool1)
	current_pool2 = min(current_pool2 + heal2, pool2)
	healable_pool1 = max(healable_pool1 - heal1, 0.0)
	healable_pool2 = max(healable_pool2 - heal2, 0.0)
	_sync_healable_damage()

	return heal1 + heal2
