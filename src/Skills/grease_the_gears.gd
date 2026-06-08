extends Skill

## Grease the Gears — all classes, Tier 1.
## +2 deg/s turret traverse speed (additive).

const TRAVERSE_BONUS: float = 1.5

func _init() -> void:
	skill_id = "gtg"
	name = "Greased Gears"
	tier = 1
	cost = 1
	flavor_text = "Well-maintained traverse mechanisms respond faster."
	tooltip_stats = [
		{"stat": "Turret Traverse Speed", "value": fmt_add(TRAVERSE_BONUS) + " deg/s", "positive": true},
	]

func _a(ship: Ship) -> void:
	(ship.artillery_controller.params.dynamic_mod as GunParams).traverse_speed += TRAVERSE_BONUS
