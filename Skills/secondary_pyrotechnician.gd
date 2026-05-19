extends Skill

## Secondary Pyrotechnician — all classes, Tier 1.
## Incendiary shell preparation improves secondary fire-starting ability.

const FIRE_BUILDUP_BONUS: float = 2.0

func _init() -> void:
	skill_id = "spyro"
	name = "Secondary Pyrotechnician"
	tier = 1
	cost = 1
	flavor_text = "Incendiary shell preparation improves secondary fire-starting ability."
	tooltip_stats = [
		{"stat": "Secondary Fire Buildup", "value": fmt_add(FIRE_BUILDUP_BONUS), "positive": true},
	]

func _a(ship: Ship) -> void:
	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		var params := sec.params.dynamic_mod as GunParams
		if params.shell1 != null:
			params.shell1.fire_buildup += FIRE_BUILDUP_BONUS
		if params.shell2 != null:
			params.shell2.fire_buildup += FIRE_BUILDUP_BONUS
