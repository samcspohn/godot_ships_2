extends Upgrade

## Hull Mod 2 — Rank 2, BBs only.
## Battleships get this modest HP boost at Rank 2. Cruisers and destroyers
## have access to the stronger Improved Hull Mod at Rank 3 instead.

const hp_mult = 1.05   # +5% max HP

func _init():
	name = "Hull Mod 2"
	description = "Increases ship health by 5%. Battleships only."
	icon = preload("res://icons/health-normal.png")
	allowed_classes = [Ship.ShipClass.BB]
	tier = 2

func _a(_ship: Ship) -> void:
	_ship.health_controller.params.static_mod.mult *= hp_mult
