extends Upgrade
class_name MainGunReloadMod1

const RELOAD_MOD: float = 0.97

func _init() -> void:
	upgrade_id = "mg_reload_1"
	name = "Main Battery Reload Mod 1"
	description = "Reduces main battery reload time by 3%."
	tier = 1
	icon = preload("res://icons/auto-repair.png")
	flavor_text = "Precision-balanced breach mechanisms shave critical milliseconds off each reload cycle."
	tooltip_stats = [
		{"stat": "Main Gun Reload", "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.artillery_controller.params.static_mod as GunParams).reload_time *= RELOAD_MOD
