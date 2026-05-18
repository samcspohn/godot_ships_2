extends Upgrade

func _init():
	name = "Main Battery Reload Boost"
	description = "Reduces main artillery reload time by 4%"
	# Set icon if you have one
	icon = preload("res://icons/auto-repair.png")
	tier = 1

func _a(_ship: Ship) -> void:
	_ship.artillery_controller.params.static_mod.reload_time *= 0.96
