extends Upgrade
class_name ArmamentsMod1

func _init() -> void:
	upgrade_id = "arm_mod_1"
	name = "Armaments Mod 1"
	description = "Reinforced armament mounts improve module durability and recovery. (Placeholder)"
	tier = 1
	icon = preload("res://icons/health-normal.png")
	flavor_text = "Reinforced gun mounts and faster repair crews keep every weapon in the fight."
	tooltip_stats = [
		{"stat": "Armament HP", "value": "+25% (placeholder)"},
		{"stat": "Armament Recovery Time", "value": "-30% (placeholder)"},
	]

# Placeholder: armament HP +25%, armament recovery time -30% — does nothing yet
func _a(_ship: Ship) -> void:
	pass
