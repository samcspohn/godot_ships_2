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
	var p := _ship.artillery_controller.params.static_mod as GunParams
	# p.h_spread *= SPREAD_MOD
	# p.v_spread *= SPREAD_MOD
	p.max_dispersion *= SPREAD_MOD
