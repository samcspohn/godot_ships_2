extends Upgrade
class_name DamageControlMod2

const DUR_MOD: float = 0.85

func _init() -> void:
	upgrade_id = "dc_mod_2"
	name = "Damage Control Mod 2"
	description = "Reduces fire and flooding duration by 15%."
	tier = 4
	icon = preload("res://icons/health-normal.png")
	flavor_text = "High-pressure suppression systems extinguish fires and seal floods faster."
	tooltip_stats = [
		{"stat": "Fire Duration", "value": fmt_mult_pct(DUR_MOD), "positive": true},
		{"stat": "Flood Duration", "value": fmt_mult_pct(DUR_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.fire_manager.fparams.static_mod as FireParams).dur *= DUR_MOD
	(_ship.flood_manager.params.static_mod as FloodParams).dur *= DUR_MOD
