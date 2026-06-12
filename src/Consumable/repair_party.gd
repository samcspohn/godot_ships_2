# src/consumables/repair_party.gd
extends ConsumableItem
class_name RepairParty

@export var heal_per_sec: float = 0.01

func _init():
	type = ConsumableType.REPAIR_PARTY

# func effect(ship: Ship) -> void:
# 	var heal = ship.health_controller.max_hp * heal_percent / duration * ship.get_physics_process_delta_time()
# 	ship.health_controller.heal(heal)

# func apply_effect(ship: Ship) -> void:

	# # Create a healing over time effect
	# var heal_effect = HealEffect.new()
	# # var total_heal = ship.health_controller.max_hp * heal_percent
	# # var heal_per_sec = total_heal / duration
	# heal_effect.setup_heal(ship, heal_percent, duration)
	# ship.add_child(heal_effect)
	# ship.add_dynamic_mod(effect)

func _proc(_delta, ship):
	# @warning_ignore("integer_division")
	# if (Engine.get_physics_frames() + Engine.physics_ticks_per_second / 2) % Engine.physics_ticks_per_second == 0: # tick every second
	var heal = ship.health_controller.max_hp * (self.p() as RepairParty).heal_per_sec
	ship.health_controller.heal(heal)

# func remove_effect(ship: Ship) -> void:
# 	# ship.remove_dynamic_mod(effect)

func can_use(ship: Ship) -> bool:
	return ship.health_controller.current_hp < ship.health_controller.max_hp

func _get_stat_lines(ship: Ship = null) -> Array[String]:
	var p_rp := self.p() as RepairParty
	var p_ci := self.p() as ConsumableItem
	if ship != null:
		var total_heal_hp: float = ship.health_controller.max_hp * p_rp.heal_per_sec * p_ci.duration
		var hp_lines: Array[String] = [
			"Heals %.0f HP over duration" % total_heal_hp,
		]
		if p_ci.duration > 0.0:
			hp_lines.append("Heal rate: %.0f HP/s" % (total_heal_hp / p_ci.duration))
		return hp_lines
	var pct := p_rp.heal_per_sec * p_ci.duration * 100.0
	var pct_lines: Array[String] = [
		"Heals %.0f%% max HP over duration" % pct,
	]
	if p_ci.duration > 0.0:
		pct_lines.append("Heal rate: %.1f%% / s" % (pct / p_ci.duration))
	return pct_lines
