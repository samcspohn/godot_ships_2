extends Skill

## Superintendent — all classes.
## Adds one extra charge to every finite consumable. Consumables whose
## max_stack == -1 (infinite use) are left untouched.
## This skill does not use dynamic_mods; apply/remove are fully custom.

func _init() -> void:
	name = "Superintendent"
	tier = 3
	cost = 3
	flavor_text = "Years of service mean one more trick always up the sleeve."
	tooltip_stats = [
		{"stat": "Consumable Charges", "value": "+1 (infinite-use excluded)", "positive": true},
	]

func apply(ship: Ship) -> void:
	_ship = ship
	if ship.consumable_manager.equipped_consumables.is_empty():
		return
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.max_stack == -1:
			continue
		consumable.max_stack += 1
		consumable.current_stack = mini(consumable.current_stack + 1, consumable.max_stack)

func remove(ship: Ship) -> void:
	if ship.consumable_manager.equipped_consumables.is_empty():
		return
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.max_stack == -1:
			continue
		consumable.max_stack -= 1
		consumable.current_stack = mini(consumable.current_stack, consumable.max_stack)
