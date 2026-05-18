extends Upgrade

## Steering Gears Mod 2 — Rank 3.
## Cuts rudder response time massively. The dodge pick: defining for DDs,
## very strong on CAs trying to wiggle out of incoming salvos.

const rudder_mod = 0.75   # -25% rudder response time

func _init():
	upgrade_id = "steer_mod_2"
	name = "Steering Gears Mod 2"
	description = "Reduces rudder response time by 25%."
	icon = preload("res://icons/auto-repair (1).png")
	tier = 3

func _a(_ship: Ship) -> void:
	var m := _ship.movement_controller.params.static_mod as MovementParams
	m.rudder_response_time *= rudder_mod
