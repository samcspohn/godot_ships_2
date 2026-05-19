extends Upgrade
class_name SecondaryGunMod1

const RANGE_MOD: float = 1.25
const SPREAD_MOD: float = 0.90

func _init() -> void:
	upgrade_id = "sec_gun_1"
	name = "Secondary Battery Mod 1"
	description = "Increases secondary battery range by 25% and reduces dispersion by 20%."
	tier = 3
	icon = preload("res://icons/auto-repair (1).png")
	flavor_text = "Extended barrels and improved sighting give secondaries real reach."
	tooltip_stats = [
		{"stat": "Secondary Range", "value": fmt_mult_pct(RANGE_MOD), "positive": true},
		{"stat": "Secondary Dispersion", "value": fmt_mult_pct(SPREAD_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		var params := sec.params.static_mod as GunParams
		params._range *= RANGE_MOD
		params.base_spread *= SPREAD_MOD
