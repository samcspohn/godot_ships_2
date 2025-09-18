extends Upgrade

func _init():
	name = "Main Battery Reload Boost"
	description = "Reduces main artillery reload time by 20%"
	# Set icon if you have one
	icon = preload("res://icons/auto-repair.png")

func _a(_ship: Ship) -> void:
	_ship.artillery_controller.params.static_mod.reload_time *= 0.8

func apply(_ship: Ship) -> void:
	# Apply the upgrade effect to the ship
	_ship.add_static_mod(_a)
	
func remove(_ship: Ship) -> void:
	# Remove the upgrade effect from the ship
	_ship.remove_static_mod(_a)
