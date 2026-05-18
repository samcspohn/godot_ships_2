extends Upgrade

## Improved Hull Mod — Rank 3, CAs and DDs only.
## Lighter hulls benefit more from reinforced plating: at the cost of a
## Rank 3 slot, cruisers and destroyers get a stronger HP bump than
## battleships get from their Rank 2 Hull Mod 2.

const hp_mult = 1.075   # +7.5% max HP

func _init():
	upgrade_id = "improved_hull_mod"
	name = "Improved Hull Mod"
	description = "Increases ship health by 7.5%. Cruisers and destroyers only."
	icon = preload("res://icons/health-normal.png")
	allowed_classes = [Ship.ShipClass.CA, Ship.ShipClass.DD]
	tier = 3

func _a(_ship: Ship) -> void:
	_ship.health_controller.params.static_mod.mult *= hp_mult
