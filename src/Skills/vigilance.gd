extends Skill

## Vigilance — all classes, Tier 2.
## +25% torpedo detection multiplier and a (placeholder) ship detection bonus.

const DETECT_MOD: float = 1.25

func _init() -> void:
	skill_id = "vig"
	name = "Vigilance"
	tier = 2
	cost = 2
	flavor_text = "Trained lookouts and passive sonar give an early-warning edge."
	tooltip_stats = [
		{"stat": "Torpedo Detection Range",   "value": fmt_mult_pct(DETECT_MOD), "positive": true},
		{"stat": "Ship Detection (guaranteed)", "value": "+7% (placeholder)"},
	]

func _a(ship: Ship) -> void:
	(ship.concealment.params.dynamic_mod as ConcealmentParams).torpedo_detection_multiplier *= DETECT_MOD
