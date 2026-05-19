extends Skill

## Jack of All Trades — all classes.
## Cuts 10 % off every consumable's cooldown. Applied directly to
## cooldown_time on the ConsumableItem instances; removed by the inverse.
## This skill does not use dynamic_mods; apply/remove are fully custom.

const COOLDOWN_MOD: float = 0.90

func _init() -> void:
	name = "Jack of All Trades"
	tier = 2
	cost = 2
	flavor_text = "A well-rounded crew keeps everything running faster."
	tooltip_stats = [
		{"stat": "Consumable Cooldown", "value": fmt_mult_pct(COOLDOWN_MOD), "positive": true},
	]

func apply(ship: Ship) -> void:
	_ship = ship
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		consumable.cooldown_time *= COOLDOWN_MOD

func remove(ship: Ship) -> void:
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		consumable.cooldown_time /= COOLDOWN_MOD
