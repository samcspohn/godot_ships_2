extends Skill

## Improved Fighter/Spotter — all classes, Tier 2.
## Placeholder: no mechanical effect yet.

func _init() -> void:
	skill_id = "ifs"
	name = "Improved Fighter/Spotter"
	tier = 2
	cost = 2
	flavor_text = "Enhanced aircraft maintenance and observer training."
	tooltip_stats = [
		{"stat": "Fighter/Spotter Range",    "value": "+20% (placeholder)"},
		{"stat": "Cooldown",                 "value": "-20% (placeholder)"},
		{"stat": "Speed",                    "value": "+10% (placeholder)"},
	]
