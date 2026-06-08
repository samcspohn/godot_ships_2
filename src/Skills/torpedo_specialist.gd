extends Skill

## Torpedo Specialist — all classes, Tier 2.
## Expert torpedo crews streamline the loading and firing process.

const RELOAD_MOD: float = 0.90   # -10% torpedo reload time

func _init() -> void:
	skill_id = "ts"
	name = "Torpedo Specialist"
	tier = 2
	cost = 2
	flavor_text = "Expert torpedo crews streamline the loading and firing process."
	tooltip_stats = [
		{"stat": "Torpedo Reload", "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	if ship.torpedo_controller != null:
		(ship.torpedo_controller.params.dynamic_mod as TorpedoLauncherParams).reload_time *= RELOAD_MOD
