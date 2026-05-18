extends Upgrade

func _init():
	name = "Secondary Battery Upgrade"
	description = "Reduces secondary reload time by 8% and increases range by 20%"
	# Set icon if you have one
	icon = preload("res://icons/auto-repair (1).png")
	tier = 1

func _a(_ship: Ship):
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		(sec.params.static_mod as GunParams).reload_time *= 0.92
		(sec.params.static_mod as GunParams)._range *= 1.20
