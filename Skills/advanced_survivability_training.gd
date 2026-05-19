extends Skill

## Advanced Survivability Training — all classes, Tier 3.
## For every 100% of max HP accumulated in potential damage received, gain 1
## tier of DC/RP improvements. Caps at 20 tiers.

const COOLDOWN_PER_TIER: float = 0.005   # -0.5% cooldown per tier
const DURATION_PER_TIER: float = 0.005   # +0.5% duration per tier
const MAX_TIERS: int = 20

var _applied_tiers: int = 0

func _init() -> void:
	skill_id = "advst"
	name = "Advanced Survivability Training"
	tier = 3
	cost = 3
	flavor_text = "Battle experience improves damage control readiness."
	tooltip_stats = [
		{"stat": "Per 100% max HP absorbed",  "value": ""},
		{"stat": "  DC/RP Cooldown",          "value": "-0.5% (stacking)", "positive": true},
		{"stat": "  DC/RP Duration",          "value": "+0.5% (stacking)", "positive": true},
		{"stat": "Max Tiers",                 "value": "20 (-10% cooldown, +10% duration)"},
	]

func _a(ship: Ship) -> void:
	if _applied_tiers == 0:
		return
	var cool_factor := 1.0 - _applied_tiers * COOLDOWN_PER_TIER
	var dur_factor  := 1.0 + _applied_tiers * DURATION_PER_TIER
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			var dm := consumable.dynamic_mod as ConsumableItem
			dm.cooldown_time *= cool_factor
			if dm.duration > 0.0:
				dm.duration *= dur_factor

func apply(ship: Ship) -> void:
	_applied_tiers = 0
	_ship = ship
	ship.add_dynamic_mod(_a)

func _proc(_delta: float) -> void:
	var new_tiers := mini(
		int(_ship.stats.potential_damage / _ship.health_controller.max_hp),
		MAX_TIERS
	)
	if new_tiers != _applied_tiers:
		_applied_tiers = new_tiers
		_ship.update_dynamic_mods = true
