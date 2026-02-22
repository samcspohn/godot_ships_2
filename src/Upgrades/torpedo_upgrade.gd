extends Upgrade

func _init():
	name = "Torpedo Reload Boost"
	description = "Reduces torpedo reload time by 15%"
	icon = preload("res://icons/health-normal (1).png")

func _a(_ship: Ship):
	if _ship.torpedo_controller:
		(_ship.torpedo_controller.params.static_mod as TorpedoLauncherParams).reload_time *= 0.85
