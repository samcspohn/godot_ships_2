# src/consumables/damage_control_party.gd
extends ConsumableItem
class_name DamageControl

func _init():
	type = ConsumableType.DAMAGE_CONTROL
	duration = 15.0
	cooldown_time = 90.0
	max_stack = -1  # Infinite uses

func _ready() -> void:
	# Initialize any necessary variables or states
	pass

func effect(ship: Ship) -> void:
	# This function can be used to apply immediate effects if needed
	var static_params = ship.fire_manager.params.static_mod as FireParams
	static_params.dur *= (1.0 - 0.65)
	static_params.dmg_rate *= (1.0 - 0.65)
	static_params.buildup_reduction_rate *= 5.0

func apply_effect(ship: Ship) -> void:
	# Create damage control effect that reduces fire duration and damage by 65%
	# var damage_control_effect = DamageControlEffect.new()
	# damage_control_effect.setup_damage_control(ship, duration)
	# ship.add_child(damage_control_effect)
	ship.add_static_mod(effect)

func remove_effect(ship: Ship) -> void:
	# Remove the damage control effect from the ship
	# for child in ship.get_children():
	# 	if child is DamageControlEffect:
	# 		child.queue_free()
	ship.remove_static_mod(effect)

func can_use(_ship: Ship) -> bool:
	# Can always use damage control (it will reduce existing fire damage/duration)
	return true
