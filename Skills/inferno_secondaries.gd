extends Skill

## Inferno Secondaries — BB only.
## Replaces secondary ammunition with high-incendiary rounds: dramatically
## higher fire-buildup at the cost of raw damage per hit. shell2 may be null
## on some secondary mounts — those are skipped safely.

const FIRE_MOD:   float = 1.50
const DAMAGE_MOD: float = 0.90

func _init() -> void:
	name = "Inferno Secondaries"
	tier = 3
	cost = 3
	allowed_classes = [Ship.ShipClass.BB]
	flavor_text = "Incendiary rounds sacrifice punch for pyromania."
	tooltip_stats = [
		{"stat": "Secondary Fire Buildup", "value": fmt_mult_pct(FIRE_MOD),   "positive": true},
		{"stat": "Secondary Damage",       "value": fmt_mult_pct(DAMAGE_MOD), "positive": false},
	]

func _a(ship: Ship) -> void:
	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		var params := sec.params.dynamic_mod as GunParams
		if params.shell1 != null:
			params.shell1.fire_buildup *= FIRE_MOD
			params.shell1.damage       *= DAMAGE_MOD
		if params.shell2 != null:
			params.shell2.fire_buildup *= FIRE_MOD
			params.shell2.damage       *= DAMAGE_MOD
