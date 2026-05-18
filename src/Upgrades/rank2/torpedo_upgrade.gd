extends Upgrade

## Torpedo Reload Boost — Rank 2.
## Sits alongside Hull Mod 2, Concealment, Propulsion, and GFCS as a real
## opportunity-cost choice: faster fish vs durability vs stealth vs reach.

func _init():
	name = "Torpedo Reload Boost"
	description = "Reduces torpedo reload time by 8%"
	icon = preload("res://icons/health-normal (1).png")
	tier = 2

func _a(_ship: Ship):
	if _ship.torpedo_controller:
		(_ship.torpedo_controller.params.static_mod as TorpedoLauncherParams).reload_time *= 0.92
