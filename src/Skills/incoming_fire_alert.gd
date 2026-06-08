extends Skill

## Incoming Fire Alert — all classes, Tier 1.
## Placeholder: no mechanical effect yet.

func _init() -> void:
	skill_id = "ifa"
	name = "Incoming Fire Alert"
	tier = 1
	cost = 1
	flavor_text = "Sensors alert the crew when enemy shells are inbound."
	tooltip_stats = [
		{"stat": "Incoming Fire Indicator", "value": "shell flight time > 5s (placeholder)"},
	]
