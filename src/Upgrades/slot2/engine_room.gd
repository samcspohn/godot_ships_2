extends Upgrade
class_name EngineRoom

func _init() -> void:
	upgrade_id = "engine_room"
	name = "Engine Room"
	description = "Improved engine room systems enhance performance. (Placeholder)"
	tier = 2
	icon = preload("res://icons/auto-repair (1).png")
	flavor_text = "Upgraded engine room systems boost overall propulsion efficiency."
	tooltip_stats = [
		{"stat": "Engine Performance", "value": "(placeholder)"},
	]

# Placeholder — does nothing yet
func _a(_ship: Ship) -> void:
	pass
