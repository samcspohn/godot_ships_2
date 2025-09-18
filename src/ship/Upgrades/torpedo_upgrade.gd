extends Upgrade

func _init():
	name = "Torpedo Reload Boost"
	description = "Reduces torpedo reload time by 15%"
	icon = preload("res://icons/health-normal (1).png")

func _a(_ship: Ship):
	if _ship.torpedo_launcher:
		_ship.torpedo_launcher.reload_time *= 0.85

func apply(_ship: Ship):
	# Apply the upgrade effect to the ship
	_ship.add_static_mod(_a)

func remove(_ship: Ship):
	# Remove the upgrade effect from the ship
	_ship.remove_static_mod(_a)
