extends Upgrade
class_name SecondaryGunMod1

const RANGE_MOD: float = 1.05
const SPREAD_MOD: float = 0.95
const RELOAD_MOD: float = 0.95

func _init() -> void:
	# Must match the key this script is registered under in UpgradeRegistry.tscn.
	# create_upgrade() overwrites this field with the registry key, so a wrong
	# value here is invisible at runtime and wrong everywhere else.
	upgrade_id = "sec_mod_1"
	name = "Secondary Battery Mod 1"
	description = "Increases secondary battery range by %s and reduces secondary dispersion and reload time by %s." \
		% [fmt_mult_pct(RANGE_MOD).trim_prefix("+"), fmt_mult_pct(SPREAD_MOD).trim_prefix("-")]
	tier = 1
	icon = preload("res://icons/auto-repair (1).png")
	flavor_text = "Better mountings and a tidier fire-control loop, across the board."
	tooltip_stats = [
		{"stat": "Secondary Range", "value": fmt_mult_pct(RANGE_MOD), "positive": true},
		{"stat": "Secondary Dispersion", "value": fmt_mult_pct(SPREAD_MOD), "positive": true},
		{"stat": "Secondary Reload", "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
	]

func _a(_ship: Ship) -> void:
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		var params := sec.params.static_mod as GunParams
		params._range *= RANGE_MOD
		params.max_h_disp *= SPREAD_MOD
		params.max_v_disp *= SPREAD_MOD
		params.reload_time *= RELOAD_MOD
		#params.grouping += GROUPING_MOD
