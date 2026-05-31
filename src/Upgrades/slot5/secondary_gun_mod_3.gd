extends Upgrade
class_name SecondaryGunMod3

const RELOAD_MOD: float = 0.80

func _init() -> void:
	upgrade_id = "sec_gun_3"
	name = "Secondary Battery Mod 3"
	description = "Reduces secondary battery reload time by 20%."
	tier = 5
	icon = preload("res://icons/auto-repair (1).png")
	flavor_text = "Pre-loaded magazines and optimised shell handling keep the secondary batteries blazing."
	tooltip_stats = [
		{"stat": "Secondary Reload", "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		(sec.params.static_mod as GunParams).reload_time *= RELOAD_MOD
