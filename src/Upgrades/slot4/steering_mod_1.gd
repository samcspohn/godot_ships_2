extends Upgrade
class_name SteeringMod1

const RUDDER_MOD: float = 0.80

func _init() -> void:
	upgrade_id = "steer_mod_1"
	name = "Steering Mod 1"
	description = "Reduces rudder shift time by 20%."
	tier = 4
	icon = preload("res://icons/auto-repair (1).png")
	flavor_text = "Hydraulic assist and tightened linkage make the rudder respond instantly."
	tooltip_stats = [
		{"stat": "Rudder Shift Time", "value": fmt_mult_pct(0.80), "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.movement_controller.params.static_mod as MovementParams).rudder_response_time *= RUDDER_MOD
