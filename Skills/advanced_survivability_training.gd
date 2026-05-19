extends Skill

## Advanced Survivability Training — all classes, Tier 3.
## For every 100% of max HP accumulated in potential damage received, gain 1
## tier of DC/RP improvements. Caps at 20 tiers.
## Reads directly from Stats.potential_damage so the counter is authoritative
## and consistent with the battle-end stats screen.

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

func _update_consumable_bonus(new_tiers: int) -> void:
	if new_tiers == _applied_tiers:
		return
	var old_cool := 1.0 - _applied_tiers * COOLDOWN_PER_TIER
	var new_cool := 1.0 - new_tiers * COOLDOWN_PER_TIER
	var old_dur  := 1.0 + _applied_tiers * DURATION_PER_TIER
	var new_dur  := 1.0 + new_tiers * DURATION_PER_TIER
	for consumable: ConsumableItem in _ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			consumable.cooldown_time = consumable.cooldown_time / old_cool * new_cool
			if consumable.duration > 0.0:
				consumable.duration = consumable.duration / old_dur * new_dur
	_applied_tiers = new_tiers

func _proc(_delta: float) -> void:
	var new_tiers := mini(
		int(_ship.stats.potential_damage / _ship.health_controller.max_hp),
		MAX_TIERS
	)
	_update_consumable_bonus(new_tiers)

func apply(ship: Ship) -> void:
	_ship = ship

func remove(_s: Ship) -> void:
	_update_consumable_bonus(0)
