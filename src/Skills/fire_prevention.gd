extends Skill

## Fire Prevention — all classes, Tier 4.
## Harder to ignite, less fire damage, shorter burn duration.

const BUILDUP_MOD: float = 1.10   # +10% fire resistance (harder to ignite)
const DMG_MOD:     float = 0.90   # -10% fire damage rate
const DUR_MOD:     float = 0.70   # -30% fire duration

func _init() -> void:
	skill_id = "fp"
	name = "Fire Prevention"
	tier = 4
	cost = 4
	flavor_text = "Fire-retardant coatings and drilled damage-control crews."
	tooltip_stats = [
		{"stat": "Fire Resistance",      "value": fmt_mult_pct(BUILDUP_MOD), "positive": true},
		{"stat": "Fire Damage Rate",     "value": fmt_mult_pct(DMG_MOD),     "positive": true},
		{"stat": "Fire Duration",        "value": fmt_mult_pct(DUR_MOD),     "positive": true},
	]

func _a(ship: Ship) -> void:
	(ship.fire_manager.rparams.dynamic_mod as ResistanceParams).max_buildup *= BUILDUP_MOD
	(ship.fire_manager.fparams.dynamic_mod as DOTParams).dmg_rate          *= DMG_MOD
	(ship.fire_manager.fparams.dynamic_mod as DOTParams).dur               *= DUR_MOD
