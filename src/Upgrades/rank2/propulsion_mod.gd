extends Upgrade

## Propulsion Mod 1 — Tier 2.
## Faster acceleration and deceleration — great for kiting DDs, repositioning
## CAs, and surprisingly useful on a brawling BB trying to close the gap.

const accel_mod = 0.88   # -12% acceleration time
const decel_mod = 0.92   # -8% deceleration time

func _init():
	upgrade_id = "prop_mod_1"
	name = "Propulsion Mod 1"
	description = "Reduces acceleration time by 12% and deceleration time by 8%."
	icon = preload("res://icons/auto-repair (1).png")
	tier = 2

func _a(_ship: Ship) -> void:
	var m := _ship.movement_controller.params.static_mod as MovementParams
	m.acceleration_time *= accel_mod
	m.deceleration_time *= decel_mod
