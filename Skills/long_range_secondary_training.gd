extends Skill

## Long Range Secondary Training — all classes, Tier 3.
## Extends secondary effectiveness at distance with range, accuracy, and grouping bonuses.

const RANGE_MOD:   float = 1.25   # +25% secondary range
const SPREAD_MOD:  float = 0.95   # -5% secondary spread
const GROUPING_BONUS: float = 0.1  # +0.1 h/v grouping

func _init() -> void:
	skill_id = "lrst"
	name = "Long Range Secondary Training"
	tier = 3
	cost = 3
	flavor_text = "Long-range battery training extends secondary effectiveness at distance."
	tooltip_stats = [
		{"stat": "Secondary Range",    "value": fmt_mult_pct(RANGE_MOD),  "positive": true},
		{"stat": "Secondary Spread",   "value": fmt_mult_pct(SPREAD_MOD), "positive": true},
		{"stat": "Secondary Grouping", "value": fmt_add(GROUPING_BONUS),  "positive": true},
		{"stat": "Flak Range",         "value": "+20 (placeholder)"},
	]

func _a(ship: Ship) -> void:
	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		var params := sec.params.dynamic_mod as GunParams
		params._range      *= RANGE_MOD
		params.base_spread *= SPREAD_MOD
		params.h_grouping  += GROUPING_BONUS
		params.v_grouping  += GROUPING_BONUS
