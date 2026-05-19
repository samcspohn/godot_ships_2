extends Skill

## Basic Secondary Training — all classes, Tier 1.
## A foundational investment in secondary-gun crews:
## tighter spread, faster reload, longer reach, and sharper priority-target focus.

const RELOAD_MOD:  float = 0.95   # -5% reload time
const SPREAD_MOD:  float = 0.95   # -5% base spread
const RANGE_MOD:   float = 1.12   # +15% range
# const PT_PERIOD:   float = 5.4    # priority-target dispersion period (default 6.0)

func _init() -> void:
	skill_id = "bst"
	name = "Basic Secondary Training"
	tier = 1
	cost = 1
	flavor_text = "Drilled crews keep the secondaries barking faster, farther, and on-target."
	tooltip_stats = [
		{"stat": "Secondary Reload",            "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
		{"stat": "Secondary Spread",            "value": fmt_mult_pct(SPREAD_MOD), "positive": true},
		{"stat": "Secondary Range",             "value": fmt_mult_pct(RANGE_MOD),  "positive": true},
		{"stat": "Priority Target Spread", "value": "-10%",                   "positive": true},
	]

func _a(ship: Ship) -> void:
	# ship.secondary_controller.priority_target_dispersion.period = PT_PERIOD
	var sec_ctrl: SecondaryController_ = ship.secondary_controller
	(sec_ctrl.target_mod.dynamic_mod as TargetMod).base_spread *= 0.95
	for sec: SecSubController in sec_ctrl.sub_controllers:
		var params := sec.params.dynamic_mod as GunParams
		params.reload_time *= RELOAD_MOD
		params.base_spread *= SPREAD_MOD
		params._range      *= RANGE_MOD
