extends Skill

## Engine Specialist — DD / CA, Tier 2.
## Acceleration time ×0.80 (-20%), deceleration time ×0.80 (-20%).

const ACCEL_MOD := 0.80
const DECEL_MOD := 0.80

func _init() -> void:
	name = "Engine Specialist"
	tier = 2
	cost = 2
	allowed_classes = [Ship.ShipClass.DD, Ship.ShipClass.CA]
	flavor_text = "Pushed to the limit: faster acceleration and quicker stops."
	tooltip_stats = [
		{"stat": "Acceleration (time)", "value": fmt_mult_pct(ACCEL_MOD), "positive": true},
		{"stat": "Deceleration (time)", "value": fmt_mult_pct(DECEL_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	var m := ship.movement_controller.params.dynamic_mod as MovementParams
	m.acceleration_time *= ACCEL_MOD
	m.deceleration_time *= DECEL_MOD
