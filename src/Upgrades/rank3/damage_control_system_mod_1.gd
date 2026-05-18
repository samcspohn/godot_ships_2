extends Upgrade

## Damage Control System Mod 1 — Rank 3.
## Bumps the share of damage that's "healable" (recoverable by Repair Party).
## Sustain pick: ships that can fight long engagements get a bigger HP pool
## back through repairs.

const light_repair_bonus   = 0.03   # +3pp light damage healable
const pen_repair_bonus     = 0.03   # +3pp pen damage healable

func _init():
	upgrade_id = "dcs_mod_1"
	name = "Damage Control System Mod 1"
	description = "Increases healable share of light and penetration damage by 3 percentage points each."
	icon = preload("res://icons/health-normal (1).png")
	tier = 3

func _a(_ship: Ship) -> void:
	var hp := _ship.health_controller.params.static_mod as HPParams
	hp.light_repair += light_repair_bonus
	hp.pen_repair   += pen_repair_bonus
