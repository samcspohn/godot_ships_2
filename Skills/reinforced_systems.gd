extends Skill

## Reinforced Systems — all classes, Tier 1.
## Placeholder: no mechanical effect yet.

func _init() -> void:
	skill_id = "rs"
	name = "Reinforced Systems"
	tier = 1
	cost = 1
	flavor_text = "Reinforced armor plating protects vital ship systems."
	tooltip_stats = [
		{"stat": "Module HP", "value": "+50% (placeholder)"},
	]
