extends Skill

## Basic Damage Control Training — all classes, Tier 1.
## Trained crews operate damage control faster with better protective gear.
## Applies directly to consumable instances; reversed on remove.

const COOLDOWN_MOD: float = 0.95   # -5% cooldown
const DC_DAMAGE_REDUCTION_BONUS: float = 0.05   # +5% DC damage reduction

func _init() -> void:
	skill_id = "bdct"
	name = "Basic Damage Control Training"
	tier = 1
	cost = 1
	flavor_text = "Trained crews operate damage control faster with better protective gear."
	tooltip_stats = [
		{"stat": "DC/RP Cooldown",        "value": fmt_mult_pct(COOLDOWN_MOD),                      "positive": true},
		{"stat": "DC Damage Reduction",   "value": fmt_add(DC_DAMAGE_REDUCTION_BONUS * 100.0) + "%", "positive": true},
	]

func apply(ship: Ship) -> void:
	_ship = ship
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			consumable.cooldown_time *= COOLDOWN_MOD
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			(consumable as DamageControl).damage_reduction += DC_DAMAGE_REDUCTION_BONUS

func remove(_s: Ship) -> void:
	for consumable: ConsumableItem in _ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			consumable.cooldown_time /= COOLDOWN_MOD
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			(consumable as DamageControl).damage_reduction -= DC_DAMAGE_REDUCTION_BONUS
