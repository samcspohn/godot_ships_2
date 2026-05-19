extends Upgrade
class_name DamageControlMod1

const COOLDOWN_MOD: float = 0.95
const DOT_DMG_DELTA: float = 0.05
const DOT_DUR_DELTA: float = 0.05

func _init() -> void:
	upgrade_id = "dc_mod_1"
	name = "Damage Control Mod 1"
	description = "Improves damage control effectiveness: reduced cooldown, DOT damage, and DOT duration."
	tier = 2
	icon = preload("res://icons/health-normal.png")
	flavor_text = "Improved DC hardware cuts both the wait between uses and the damage fires deal."
	tooltip_stats = [
		{"stat": "DC/RP Cooldown", "value": fmt_mult_pct(0.95), "positive": true},
		{"stat": "DC DOT Damage", "value": "-5%", "positive": true},
		{"stat": "DC DOT Duration", "value": "-5%", "positive": true},
	]

func apply(_ship: Ship) -> void:
	for consumable in _ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			consumable.cooldown_time *= COOLDOWN_MOD
			var dc := consumable as DamageControl
			dc.damage_reduction += DOT_DMG_DELTA
			dc.duration_reduction += DOT_DUR_DELTA
		elif consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			consumable.cooldown_time *= COOLDOWN_MOD

func remove(_ship: Ship) -> void:
	for consumable in _ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			consumable.cooldown_time /= COOLDOWN_MOD
			var dc := consumable as DamageControl
			dc.damage_reduction -= DOT_DMG_DELTA
			dc.duration_reduction -= DOT_DUR_DELTA
		elif consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			consumable.cooldown_time /= COOLDOWN_MOD
