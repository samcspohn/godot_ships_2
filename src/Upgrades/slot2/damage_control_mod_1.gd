extends Upgrade
class_name DamageControlMod1

const COOLDOWN_MOD: float = 0.95
const DOT_DMG_DELTA: float = 0.95
const DOT_DUR_DELTA: float = 0.95

func _init() -> void:
	upgrade_id = "dc_mod_1"
	name = "Damage Control Mod 1"
	description = "Improves damage control effectiveness: reduced cooldown, DOT damage, and DOT duration."
	tier = 2
	icon = preload("res://icons/health-normal.png")
	flavor_text = "Improved DC hardware cuts both the wait between uses and the damage fires deal."
	tooltip_stats = [
		{"stat": "DC/RP Cooldown", "value": fmt_mult_pct(COOLDOWN_MOD), "positive": true},
		{"stat": "DC DOT Damage", "value": "-%.0f%%" % (1.0 -DOT_DMG_DELTA * 100), "positive": true},
		{"stat": "DC DOT Duration", "value": "-%.0f%%" % (1.0 - DOT_DUR_DELTA * 100), "positive": true},
	]

func _a(_ship: Ship) -> void:
	for consumable in _ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			(consumable.static_mod as ConsumableItem).cooldown_time *= COOLDOWN_MOD
			(consumable.static_mod as DamageControl).damage_reduction *= DOT_DMG_DELTA
			(consumable.static_mod as DamageControl).duration_reduction *= DOT_DUR_DELTA
		elif consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			(consumable.static_mod as ConsumableItem).cooldown_time *= COOLDOWN_MOD
