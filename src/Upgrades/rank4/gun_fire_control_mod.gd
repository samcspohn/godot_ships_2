extends Upgrade

## Gun Fire Control Mod 1 — Tier 2.
## Trades nothing for extra main-gun range. The reach pick: lets BBs and CAs
## open fire earlier and dictate engagement range from farther out.

const range_mod = 1.15   # +15% main battery range
const shell_speed_mod = 1.05   # +5% shell velocity (both shell types)
const reload_mod = 1.05   # +5% reload time (slower fire)

func _init():
	upgrade_id = "gfcs_mod_1"
	name = "Gun Fire Control Mod 1"
	description = "Increases main battery firing range by 15%."
	icon = preload("res://icons/auto-repair.png")
	tier = 4

func _a(_ship: Ship) -> void:
	var main := _ship.artillery_controller.params.static_mod as GunParams
	main._range *= range_mod
	main.reload_time *= reload_mod
	main.shell1.speed *= shell_speed_mod
	if main.shell1.type == ShellParams.ShellType.AP:
		main.shell1.penetration_modifier *= 0.95
	if main.shell2:
		main.shell2.speed *= shell_speed_mod
