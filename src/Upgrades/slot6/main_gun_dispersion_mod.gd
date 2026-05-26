extends Upgrade
class_name MainGunDispersionMod

const SPREAD_MOD: float = 0.90

func _init() -> void:
	upgrade_id = "mg_disp_mod"
	name = "Main Battery Dispersion Mod"
	description = "Reduces main battery dispersion by 10%."
	tier = 6
	icon = preload("res://icons/auto-repair.png")
	flavor_text = "Precision-machined barrels and stabilised gun directors tighten every salvo."
	tooltip_stats = [
		{"stat": "Main Gun Spread", "value": fmt_mult_pct(SPREAD_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	(_ship.artillery_controller.params.static_mod as GunParams).base_spread *= SPREAD_MOD
