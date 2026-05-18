extends Upgrade

## Main Battery Mod 3 — Rank 3.
## DPM at the cost of traverse: meaningful for stationary brawls, painful when
## you have to chase a flanker.

const reload_mod   = 0.92   # -8% main reload
const traverse_mod = 0.90   # -10% turret traverse

func _init():
	upgrade_id = "mb_mod_3"
	name = "Main Battery Mod 3"
	description = "Reduces main reload by 8%; reduces turret traverse speed by 10%."
	icon = preload("res://icons/auto-repair.png")
	tier = 3

func _a(_ship: Ship) -> void:
	var main := _ship.artillery_controller.params.static_mod as GunParams
	main.reload_time    *= reload_mod
	main.traverse_speed *= traverse_mod
