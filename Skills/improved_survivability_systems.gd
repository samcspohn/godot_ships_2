extends Skill

## Improved Survivability Systems — all classes, Tier 4.
## Advanced systems extend DC/RP effectiveness and add an extra charge.
## Stats (heal_per_sec, duration) are applied via the dynamic mod layer.
## Max stack is game state — applied directly, reversed on remove.

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

func _a(ship: Ship) -> void:
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			var rp_dyn := consumable.dynamic_mod as RepairParty
			rp_dyn.heal_per_sec *= 1.10
			if rp_dyn.duration > 0.0:
				rp_dyn.duration *= 1.10
				rp_dyn.max_stack += 1
		elif consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			var dc_dyn := consumable.dynamic_mod as ConsumableItem
			if dc_dyn.duration > 0.0:
				dc_dyn.duration *= 1.10
				dc_dyn.max_stack += 1

func apply(ship: Ship) -> void:
	_ship = ship
	ship.add_dynamic_mod(_a)
	# for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
	# 	if consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY or \
	# 			consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
	# 		if consumable.max_stack != -1:
	# 			consumable.max_stack += 1
	# 			consumable.current_stack = mini(consumable.current_stack + 1, consumable.max_stack)

func remove(_s: Ship) -> void:
	_ship.remove_dynamic_mod(_a)
	# for consumable: ConsumableItem in _ship.consumable_manager.equipped_consumables:
	# 	if consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY or \
	# 			consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
	# 		if consumable.max_stack != -1:
	# 			consumable.max_stack -= 1
	# 			consumable.current_stack = mini(consumable.current_stack, consumable.max_stack)
