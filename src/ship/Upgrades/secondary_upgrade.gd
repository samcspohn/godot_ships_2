extends Upgrade

func _init():
	name = "Secondary Battery Upgrade"
	description = "Reduces secondary reload time by 20% and doubles range"
	# Set icon if you have one
	icon = preload("res://icons/auto-repair (1).png")

func _a(_ship: Ship):
	for sec: SecondaryController in _ship.secondary_controllers:
		(sec.params.static_mod as GunParams).reload_time *= 0.8
		(sec.params.static_mod as GunParams)._range *= 2.0

func apply(_ship: Ship):
	# Apply the upgrade effect to the ship
	_ship.add_static_mod(_a)

func remove(_ship: Ship):
	# Remove the upgrade effect from the ship
	_ship.remove_static_mod(_a)
