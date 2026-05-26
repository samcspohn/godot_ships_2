extends Upgrade
class_name MainGunMod2

const TRAVERSE_BONUS: float = 1.0  # deg/s additive

func _init() -> void:
	upgrade_id = "mg_mod_2"
	name = "Main Battery Mod 2"
	description = "Increases main battery turret traverse speed by 5 deg/s."
	tier = 3
	icon = preload("res://icons/auto-repair.png")
	flavor_text = "Upgraded traverse motors let turrets track fast-moving targets with ease."
	tooltip_stats = [
		{"stat": "Turret Traverse Speed", "value": fmt_add(TRAVERSE_BONUS) + " deg/s", "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.artillery_controller.params.static_mod as GunParams).traverse_speed += TRAVERSE_BONUS
