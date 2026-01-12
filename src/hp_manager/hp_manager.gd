extends Node
class_name HPManager

@export var max_hp: float
var current_hp: float
var sunk: bool = false
@onready var ship: Ship = $"../.."

signal hp_changed(new_hp: float)
signal ship_sunk()

@export var citadel: HpPartMod
@export var casemate: HpPartMod
@export var bow: HpPartMod
@export var stern: HpPartMod
@export var superstructure: HpPartMod

const SHELL_DAMAGE_RADIUS_MOD: float = 12.5


func _ready() -> void:
	current_hp = max_hp
	if ship == null:
		ship = get_parent().get_parent() as Ship
	citadel.init(ship)
	casemate.init(ship)
	bow.init(ship)
	stern.init(ship)
	superstructure.init(ship)

func apply_damage(dmg: float, base_dmg:float, armor_part: ArmorPart, is_pen: bool, shell_cal:float = 0) -> Array:
	if sunk:
		return [0, false]

	var radius_mod = shell_cal / SHELL_DAMAGE_RADIUS_MOD
	var dmg_mod = clamp(ship.beam / radius_mod, 0.0, 1.0)
	dmg *= dmg_mod
	base_dmg *= dmg_mod

	# TODO: how to handle overpenetration/citadel overpen damage?
	var _dmg: float = 0
	match armor_part.type:
		ArmorPart.Type.MODULE:
			_dmg = min(dmg, base_dmg * 0.1)
		ArmorPart.Type.CITADAL:
			_dmg = citadel.apply_damage(dmg)
		ArmorPart.Type.CASEMATE:
			_dmg = casemate.apply_damage(dmg)
		ArmorPart.Type.BOW:
			_dmg = bow.apply_damage(dmg)
		ArmorPart.Type.STERN:
			_dmg = stern.apply_damage(dmg)
		ArmorPart.Type.SUPERSTRUCTURE:
			_dmg = superstructure.apply_damage(dmg)

	if is_pen:
		dmg = max(_dmg, base_dmg * 0.1)


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

func apply_light_damage(dmg: float) -> Array:
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
		HitEffects.sparks_effect(ship.global_transform.origin, 20.0, Vector3.UP)
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
