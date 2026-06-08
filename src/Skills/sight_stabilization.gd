extends Skill

## Sight Stabilization — all classes, Tier 2.
## Rudder response time ×0.70 (-30%), speed loss in turns ×0.90 (-10%).

const RUDDER_MOD    := 0.70
const TURN_LOSS_MOD := 0.90

func _init() -> void:
	name = "Sight Stabilization"
	tier = 2
	cost = 2
	flavor_text = "Gyro-stabilized sighting and hull equipment improve handling."
	tooltip_stats = [
		{"stat": "Rudder Response Time", "value": fmt_mult_pct(RUDDER_MOD),    "positive": true},
		{"stat": "Speed Loss in Turns",  "value": fmt_mult_pct(TURN_LOSS_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	var m := ship.movement_controller.params.dynamic_mod as MovementParams
	m.rudder_response_time *= RUDDER_MOD
	m.turn_speed_loss      *= TURN_LOSS_MOD
