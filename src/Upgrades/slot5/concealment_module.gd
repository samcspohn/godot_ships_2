extends Upgrade
class_name ConcealmentModule

const RADIUS_MOD: float = 0.93

func _init() -> void:
	upgrade_id = "conceal_mod"
	name = "Concealment Module"
	description = "Reduces ship concealment radius by 7%."
	tier = 5
	icon = preload("res://icons/health-normal.png")
	flavor_text = "Low-profile radar absorbing materials and exhaust baffles reduce the ship's signature."
	tooltip_stats = [
		{"stat": "Concealment Radius", "value": fmt_mult_pct(RADIUS_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.concealment.params.static_mod as ConcealmentParams).radius *= RADIUS_MOD
