extends Upgrade

func _init():
	name = "Hull Reinforcement"
	description = "Increases ship health by 10%"
	icon = preload("res://icons/health-normal.png")

func _a(_ship: Ship):
	_ship.health_controller.params.static_mod.mult *= 1.05
	# _ship.health_controller.params.static_mod.current_hp *= 1.1
