extends Skill

## Concealment Expert — all classes, Tier 3.
## -5% detection radius.

const RADIUS_MOD: float = 0.93   # -7% detection radius (cumulative with Concealment Expert)

func _init() -> void:
	skill_id = "ce"
	name = "Concealment Expert"
	tier = 3
	cost = 3
	flavor_text = "Camouflage netting and radio silence — the enemy sweeps right past you."
	tooltip_stats = [
		{"stat": "Detection Radius", "value": fmt_mult_pct(RADIUS_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	(ship.concealment.params.dynamic_mod as ConcealmentParams).radius *= RADIUS_MOD
