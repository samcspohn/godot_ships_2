extends Moddable

class_name HpPartMod

@export var pool: float = 100.0

var current_pool: float
var healable_damage: float = 0.0

var hp: HPManager

static func make(ship: Ship, size: float) -> HpPartMod:
	var t := HpPartMod.new()
	t.pool = size
	return t.instantiate(ship) as HpPartMod

func instantiate(ship: Ship) -> Moddable:
	var inst = super.instantiate(ship)
	inst.current_pool = inst.pool
	inst.healable_damage = 0.0
	return inst

func saturated() -> bool:
	return current_pool <= 0.0

func apply_damage(dmg: float, repair_rate: float = 0.0) -> float:
	var taken: float = clampf(dmg, 0.0, current_pool)
	current_pool -= taken
	if repair_rate > 0.0:
		healable_damage = clampf(healable_damage + taken * repair_rate, 0.0, pool - current_pool)
	return taken

func heal(amount: float) -> float:
	var healed: float = clampf(amount, 0.0, healable_damage)
	current_pool = minf(current_pool + healed, pool)
	healable_damage -= healed
	return healed
