extends Upgrade
class_name RangeMod

const RANGE_MOD: float = 1.15
const RELOAD_MOD: float = 0.96

func _init() -> void:
	upgrade_id = "range_mod"
	name = "Range Mod"
	description = "Increases main battery range by 15% and reduces reload time by 4%."
	tier = 5
	icon = preload("res://icons/auto-repair.png")
	flavor_text = "Extended barrels and improved powder charges push shells to the horizon."
	tooltip_stats = [
		{"stat": "Main Gun Range", "value": fmt_mult_pct(RANGE_MOD), "positive": true},
		{"stat": "Main Gun Reload", "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	var main := _ship.artillery_controller.params.static_mod as GunParams
	main._range *= RANGE_MOD
	main.reload_time *= RELOAD_MOD
