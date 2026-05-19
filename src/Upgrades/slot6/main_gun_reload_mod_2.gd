extends Upgrade
class_name MainGunReloadMod2

const RELOAD_MOD: float = 0.90

func _init() -> void:
	upgrade_id = "mg_reload_2"
	name = "Main Battery Reload Mod 2"
	description = "Reduces main battery reload time by 10%."
	tier = 6
	icon = preload("res://icons/auto-repair.png")
	flavor_text = "Automated ramming gear and polished chamber linings cut reload time dramatically."
	tooltip_stats = [
		{"stat": "Main Gun Reload", "value": fmt_mult_pct(0.90), "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.artillery_controller.params.static_mod as GunParams).reload_time *= RELOAD_MOD
