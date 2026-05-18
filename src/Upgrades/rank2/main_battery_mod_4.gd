extends Upgrade

## Main Battery Mod 4 — Rank 4.
## Premier accuracy: stacks multiplicatively with Aiming Systems (Rank 1) for
## the sniper build. No drawback at this tier — Rank 4 is opportunity-cost.

const dispersion_mod = 0.93   # -7% main gun base spread

func _init():
	upgrade_id = "mb_mod_4"
	name = "Main Battery Mod 4"
	description = "Reduces main battery dispersion by 7%."
	icon = preload("res://icons/auto-repair.png")
	tier = 2

func _a(_ship: Ship) -> void:
	var main := _ship.artillery_controller.params.static_mod as GunParams
	main.base_spread *= dispersion_mod
