extends Upgrade

## Propulsion Mod 2 — Rank 4.
## A flat top-speed boost. Strong on every class: faster DDs are harder to
## catch, faster BBs reposition between flanks, faster CAs keep range from
## brawlers.

const speed_mod = 1.04   # +4% max speed (knots)

func _init():
	upgrade_id = "prop_mod_2"
	name = "Propulsion Mod 2"
	description = "Increases maximum ship speed by 4%."
	icon = preload("res://icons/auto-repair (1).png")
	tier = 4

func _a(_ship: Ship) -> void:
	var m := _ship.movement_controller.params.static_mod as MovementParams
	m.max_speed_knots *= speed_mod
