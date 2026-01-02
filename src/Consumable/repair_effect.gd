extends ShipEffect
class_name HealEffect

var heal_percent: float
var duration: float
var heal_accumulated: float = 0.0

signal healing_complete

func setup_heal(target_ship: Ship, _heal_percent: float, _duration: float):
	heal_percent = _heal_percent
	duration = _duration
	setup(target_ship, duration)

func activate_effect():
	if ship and ship.health_controller:
		# Visual/audio feedback for heal start
		print("Repair Party activated on ", ship.name)
		# Could add particle effects or sound here

func _process(delta):
	if effect_active and ship and ship.health_controller:
		# Calculate heal amount for this frame
		var total_heal = ship.health_controller.max_hp * heal_percent
		var heal_per_sec = total_heal / duration
		var heal_this_frame = heal_per_sec * delta
		heal_accumulated += heal_this_frame

		# Apply healing
		var _actual_heal = ship.health_controller.heal(heal_this_frame)

		# Check if duration expired
		remaining_duration -= delta
		if remaining_duration <= 0:
			deactivate_effect()

func deactivate_effect():
	if ship:
		print("Repair Party completed on ", ship.name, " - Total healed: ", heal_accumulated)
	healing_complete.emit()
	super.deactivate_effect()
