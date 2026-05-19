extends Skill

## Improved Survivability Systems — all classes, Tier 4.
## Advanced systems extend DC/RP effectiveness and add an extra charge.
## Applied directly to consumable instances; reversed on remove.

func _init() -> void:
	skill_id = "iss"
	name = "Improved Survivability Systems"
	tier = 4
	cost = 4
	flavor_text = "Advanced systems extend DC/RP effectiveness and add an extra charge."
	tooltip_stats = [
		{"stat": "DC/RP Duration",      "value": "+10%",  "positive": true},
		{"stat": "HP Restored/sec",     "value": "+10%",  "positive": true},
		{"stat": "DC DOT Duration",     "value": "-10%",  "positive": true},
		{"stat": "DC DOT Damage/sec",   "value": "-10%",  "positive": true},
		{"stat": "DC/RP Charges",       "value": "+1",    "positive": true},
	]

func apply(ship: Ship) -> void:
	_ship = ship
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			var rp := consumable as RepairParty
			rp.heal_per_sec *= 1.10
			if consumable.duration > 0.0:
				consumable.duration *= 1.10
			if rp.max_stack != -1:
				rp.max_stack += 1
				rp.current_stack = mini(rp.current_stack + 1, rp.max_stack)
		elif consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			var dc := consumable as DamageControl
			dc.duration_reduction *= 1.10
			dc.damage_reduction   *= 1.10
			if consumable.duration > 0.0:
				consumable.duration *= 1.10
			if dc.max_stack != -1:
				dc.max_stack += 1
				dc.current_stack = mini(dc.current_stack + 1, dc.max_stack)

func remove(_s: Ship) -> void:
	for consumable: ConsumableItem in _ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			var rp := consumable as RepairParty
			rp.heal_percent /= 1.10
			if consumable.duration > 0.0:
				consumable.duration /= 1.10
			if rp.max_stack != -1:
				rp.max_stack -= 1
				rp.current_stack = mini(rp.current_stack, rp.max_stack)
		elif consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			var dc := consumable as DamageControl
			dc.duration_reduction -= 0.10
			dc.damage_reduction   -= 0.10
			if consumable.duration > 0.0:
				consumable.duration /= 1.10
			if dc.max_stack != -1:
				dc.max_stack -= 1
				dc.current_stack = mini(dc.current_stack, dc.max_stack)
