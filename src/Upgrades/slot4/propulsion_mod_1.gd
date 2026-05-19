extends Upgrade
class_name PropulsionMod1

const ACCEL_MOD: float = 0.50

func _init() -> void:
	upgrade_id = "prop_mod_1"
	name = "Propulsion Mod 1"
	description = "Reduces acceleration time by 50%."
	tier = 4
	icon = preload("res://icons/auto-repair (1).png")
	flavor_text = "Direct-drive turbines deliver peak thrust almost instantly."
	tooltip_stats = [
		{"stat": "Acceleration Time", "value": fmt_mult_pct(0.50), "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.movement_controller.params.static_mod as MovementParams).acceleration_time *= ACCEL_MOD
