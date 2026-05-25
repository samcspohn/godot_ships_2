extends Skill

## Superintendent — all classes.
## Adds one extra charge to every finite consumable via the dynamic mod layer.

const CHARGES_BONUS: int = 1

func _init() -> void:
	name = "Superintendent"
	tier = 3
	cost = 3
	flavor_text = "Years of service mean one more trick always up the sleeve."
	tooltip_stats = [
		{"stat": "Consumable Charges", "value": "+%d (infinite-use excluded)" % CHARGES_BONUS, "positive": true},
	]

func _a(ship: Ship) -> void:
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		var dm := consumable.dynamic_mod as ConsumableItem
		if dm.max_stack != -1:
			dm.max_stack += CHARGES_BONUS
