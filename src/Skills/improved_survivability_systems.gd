extends Skill

## Improved Survivability Systems — all classes, Tier 4.
## Advanced systems extend DC/RP effectiveness and add an extra charge.
## All effects applied via the dynamic mod layer; no custom apply/remove needed.

const DURATION_MOD: float = 1.10
const CHARGES_BONUS: int = 1

func _init() -> void:
	skill_id = "iss"
	name = "Improved Survivability Systems"
	tier = 4
	cost = 4
	flavor_text = "Advanced systems extend DC/RP effectiveness and add an extra charge."
	tooltip_stats = [
		{"stat": "DC/RP Duration",      "value": fmt_mult_pct(DURATION_MOD),  "positive": true},
		{"stat": "DC/RP Charges",       "value": "+%d" % CHARGES_BONUS,       "positive": true},
	]

func _a(ship: Ship) -> void:
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		var dm := consumable.dynamic_mod as ConsumableItem
		if consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			var rp_dyn := consumable.dynamic_mod as RepairParty
			# rp_dyn.heal_per_sec *= DURATION_MOD
			if rp_dyn.duration > 0.0:
				rp_dyn.duration *= DURATION_MOD
			if dm.max_stack != -1:
				dm.max_stack += CHARGES_BONUS
		elif consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			if dm.duration > 0.0:
				dm.duration *= DURATION_MOD
			if dm.max_stack != -1:
				dm.max_stack += CHARGES_BONUS
