extends Upgrade

func _init():
	name = "Hull Reinforcement"
	description = "Increases ship health by 10%"
	icon = preload("res://icons/health-normal.png")

func _a(_ship: Ship):
	_ship.health_controller.max_hp *= 1.1
	_ship.health_controller.current_hp = _ship.health_controller.max_hp

func apply(_ship: Ship):
	# Apply the upgrade effect to the ship
	_ship.add_static_mod(_a)

func remove(_ship: Ship):
	# Remove the upgrade effect from the ship
	_ship.remove_static_mod(_a)
