extends Skill

## Jack of All Trades — all classes.
## Cuts 10% off every consumable's cooldown via the dynamic mod layer.

const COOLDOWN_MOD: float = 0.90

func _init() -> void:
	name = "Jack of All Trades"
	tier = 2
	cost = 2
	flavor_text = "A well-rounded crew keeps everything running faster."
	tooltip_stats = [
		{"stat": "Consumable Cooldown", "value": fmt_mult_pct(COOLDOWN_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		(consumable.dynamic_mod as ConsumableItem).cooldown_time *= COOLDOWN_MOD
