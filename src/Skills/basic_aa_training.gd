extends Skill

## Basic AA Training — all classes, Tier 1.
## Placeholder: no mechanical effect yet.

func _init() -> void:
	skill_id = "baat"
	name = "Basic AA Training"
	tier = 1
	cost = 1
	flavor_text = "Anti-aircraft crews practice targeting and tracking aircraft."
	tooltip_stats = [
		{"stat": "AA Damage/s",               "value": "+10% (placeholder)"},
		{"stat": "AA Priority Group Damage",  "value": "+10% (placeholder)"},
	]
