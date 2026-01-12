# src/consumables/repair_party.gd
extends ConsumableItem
class_name RepairParty

@export var heal_percent: float = 0.2

func _init():
	type = ConsumableType.REPAIR_PARTY
	duration = 10.0
	cooldown_time = 90.0
	max_stack = 4

func apply_effect(ship: Ship) -> void:

	# Create a healing over time effect
	var heal_effect = HealEffect.new()
	# var total_heal = ship.health_controller.max_hp * heal_percent
	# var heal_per_sec = total_heal / duration
	heal_effect.setup_heal(ship, heal_percent, duration)
	ship.add_child(heal_effect)

func can_use(ship: Ship) -> bool:
	return ship.health_controller.current_hp < ship.health_controller.max_hp
