extends Skill

## Advanced AA Training — all classes, Tier 2.
## Placeholder: no mechanical effect yet.

func _init() -> void:
	skill_id = "aat"
	name = "Advanced AA Training"
	tier = 2
	cost = 2
	flavor_text = "Advanced tracking systems increase effective anti-aircraft range."
	tooltip_stats = [
		{"stat": "AA Range", "value": "+20% (placeholder)"},
	]
