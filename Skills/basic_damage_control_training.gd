extends Skill

## Basic Damage Control Training — all classes, Tier 1.
## Trained crews operate damage control faster with better protective gear.

const COOLDOWN_MOD: float = 0.95   # -5% cooldown
const DC_DAMAGE_REDUCTION_BONUS: float = 1.05   # +5% DC damage reduction

func _init() -> void:
	skill_id = "bdct"
	name = "Basic Damage Control Training"
	tier = 1
	cost = 1
	flavor_text = "Trained crews operate damage control faster with better protective gear."
	tooltip_stats = [
		{"stat": "DC/RP Cooldown",        "value": fmt_mult_pct(COOLDOWN_MOD),                      "positive": true},
		{"stat": "DC Damage Reduction",   "value": fmt_mult_pct(DC_DAMAGE_REDUCTION_BONUS), "positive": true},
	]

func _a(ship: Ship) -> void:
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			(consumable.dynamic_mod as ConsumableItem).cooldown_time *= COOLDOWN_MOD
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			(consumable.dynamic_mod as DamageControl).damage_reduction *= DC_DAMAGE_REDUCTION_BONUS
