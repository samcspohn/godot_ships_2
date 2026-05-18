extends Upgrade

## Aiming Systems Mod 1 — Tier 1.
## Trades nothing for tighter main-battery dispersion. The accuracy pick for
## anyone willing to give up an HP / reload / spotting slot.

const dispersion_mod = 0.96   # -4% main gun base spread

func _init():
	upgrade_id = "aim_sys_1"
	name = "Aiming Systems Mod 1"
	description = "Reduces main battery dispersion by 4%."
	icon = preload("res://icons/auto-repair.png")
	tier = 1

func _a(_ship: Ship) -> void:
	var main := _ship.artillery_controller.params.static_mod as GunParams
	main.base_spread *= dispersion_mod
