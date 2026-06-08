extends Skill

## Speed Trials — all classes, Tier 2.
## High-performance engine tuning for faster top speed and quicker acceleration.

const SPEED_MOD:  float = 1.05   # +5% max speed
const ACCEL_MOD:  float = 0.95   # -5% acceleration time

func _init() -> void:
	skill_id = "st"
	name = "Speed Trials"
	tier = 2
	cost = 2
	flavor_text = "High-performance engine tuning and crew drills for rapid speed changes."
	tooltip_stats = [
		{"stat": "Max Speed",         "value": fmt_mult_pct(SPEED_MOD), "positive": true},
		{"stat": "Acceleration Time", "value": fmt_mult_pct(ACCEL_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	var m := ship.movement_controller.params.dynamic_mod as MovementParams
	m.max_speed_knots   *= SPEED_MOD
	m.acceleration_time *= ACCEL_MOD
