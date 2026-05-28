extends Skill

## Improved Consumable Usage — all classes, Tier 2.
## Crew efficiency extends the duration of all active consumable effects.

const DURATION_MOD: float = 1.10   # +10% duration

func _init() -> void:
	skill_id = "icu"
	name = "Improved Consumable Usage"
	tier = 2
	cost = 2
	flavor_text = "Crew efficiency extends the duration of all active consumable effects.\n\nDoes not affect Damage Control or Repair Party consumables."
	tooltip_stats = [
		{"stat": "All Consumable Duration", "value": fmt_mult_pct(DURATION_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			continue
		var dm := consumable.dynamic_mod as ConsumableItem
		if dm.duration > 0.0:
			dm.duration *= DURATION_MOD
