extends Skill

## Advanced Firing Training — DD only, Tier 4.
## Advanced gunnery computing and optics extend main battery effective range.

const RANGE_MOD: float = 1.20   # +20% main gun range

func _init() -> void:
	skill_id = "aft"
	name = "Advanced Firing Training"
	tier = 4
	cost = 4
	allowed_classes = [Ship.ShipClass.DD]
	flavor_text = "Advanced gunnery computing and optics extend main battery effective range."
	tooltip_stats = [
		{"stat": "Main Gun Range", "value": fmt_mult_pct(RANGE_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	(ship.artillery_controller.params.dynamic_mod as GunParams)._range *= RANGE_MOD
