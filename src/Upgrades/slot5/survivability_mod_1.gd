extends Upgrade
class_name SurvivabilityMod1

const COOLDOWN_MOD: float = 0.90
const DURATION_MOD: float = 1.10

func _init() -> void:
	upgrade_id = "surv_mod_1"
	name = "Survivability Mod 1"
	description = "Reduces RP/DC cooldown by 10% and increases RP/DC duration by 10%."
	tier = 5
	icon = preload("res://icons/health-normal (1).png")
	flavor_text = "Overhauled damage control systems run longer and reload faster."
	tooltip_stats = [
		{"stat": "RP/DC Cooldown", "value": fmt_mult_pct(0.90), "positive": true},
		{"stat": "RP/DC Duration", "value": fmt_mult_pct(1.10), "positive": true},
	]

func _a(_ship: Ship) -> void:
	for consumable in _ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			(consumable.static_mod as ConsumableItem).cooldown_time *= COOLDOWN_MOD
			if (consumable.static_mod as ConsumableItem).duration > 0.0:
				(consumable.static_mod as ConsumableItem).duration *= DURATION_MOD
