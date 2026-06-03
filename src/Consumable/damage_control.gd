# src/consumables/damage_control_party.gd
extends ConsumableItem
class_name DamageControl
@export var duration_reduction = 1.0 - 0.65
@export var damage_reduction = 1.0 - 0.65

func _init():
	type = ConsumableType.DAMAGE_CONTROL

func _ready() -> void:
	# Initialize any necessary variables or states
	pass

func effect(ship: Ship) -> void:
	var p := self.p() as DamageControl
	var fire_params := ship.fire_manager.fparams.static_mod as DOTParams
	var resist_params := ship.fire_manager.rparams.static_mod as ResistanceParams
	fire_params.dur *= p.duration_reduction
	fire_params.dmg_rate *= p.damage_reduction
	resist_params.buildup_reduction_rate *= 10.0
	resist_params.reduction_block_rate *= 0.1

	var flood_params := ship.flood_manager.dot_params.static_mod as DOTParams
	var flood_rparams := ship.flood_manager.rparams.static_mod as ResistanceParams
	flood_params.dur *= p.duration_reduction
	flood_params.dmg_rate *= p.damage_reduction
	flood_rparams.buildup_reduction_rate *= 10.0
	flood_rparams.reduction_block_rate *= 0.1

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

func _get_stat_lines(_ship: Ship = null) -> Array[String]:
	var p := self.p() as DamageControl
	return [
		"Fire/flood duration: -%.0f%%" % ((1 - p.duration_reduction) * 100.0),
		"Fire/flood damage: -%.0f%%" % ((1 - p.damage_reduction) * 100.0),
		"Buildup reduction: 10x",
	]
