extends Skill

## Improved Consumable Usage — all classes, Tier 2.
## Crew efficiency extends the duration of all active consumable effects.
## Applies directly to consumable instances; reversed on remove.

const DURATION_MOD: float = 1.10   # +10% duration

func _init() -> void:
	skill_id = "icu"
	name = "Improved Consumable Usage"
	tier = 2
	cost = 2
	flavor_text = "Crew efficiency extends the duration of all active consumable effects."
	tooltip_stats = [
		{"stat": "All Consumable Duration", "value": fmt_mult_pct(DURATION_MOD), "positive": true},
	]

func apply(ship: Ship) -> void:
	_ship = ship
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		consumable.duration *= DURATION_MOD

func remove(_s: Ship) -> void:
	for consumable: ConsumableItem in _ship.consumable_manager.equipped_consumables:
		consumable.duration /= DURATION_MOD
