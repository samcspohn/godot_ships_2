extends Node
class_name HitPointsManager

@export var max_hp: float
var current_hp: float
var sunk: bool = false
@onready var ship: Ship = $"../.."

signal hp_changed(new_hp: float)
signal ship_sunk()

func _ready() -> void:
	current_hp = max_hp

func take_damage(dmg: float, _pos: Vector3) -> Array:
	if sunk:
		return [0, false]
	current_hp -= dmg
	if current_hp <= 0 && !sunk:
		dmg -= current_hp
		current_hp = 0
		sink()
		ship_sunk.emit()
		hp_changed.emit(current_hp)
		return [dmg, true]
	hp_changed.emit(current_hp)
	return [dmg, false]

func heal(amount: float) -> float:
	if sunk:
		return 0.0
	if current_hp + amount > max_hp:
		amount = max_hp - current_hp
	current_hp += amount
	hp_changed.emit(current_hp)
	return amount

@rpc("any_peer", "reliable", "call_remote")
func sink():
	sunk = true
	if !(_Utils.authority()):
		HitEffects.he_explosion_effect(ship.global_transform.origin, 30.0, Vector3.UP)
		HitEffects.sparks_effect(ship.global_transform.origin, 30.0, Vector3.UP)
	#get_parent().queue_free()
	ship.artillery_controller.set_physics_process(false)
	ship.movement_controller.set_physics_process(false)
	#ship.get_node("Secondaries").set_physics_process(false)
	var pc = ship.get_node_or_null("PlayerController")
	if pc != null:
		pc.set_physics_process(false)
		pc.set_process_input(false)
	ship._disable_guns()
	#ship.set_physics_process(false)
	if _Utils.authority():
		sink.rpc()

func is_alive() -> bool:
	return current_hp > 0

func is_dead() -> bool:
	return current_hp <= 0
