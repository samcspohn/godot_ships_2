@tool
extends Node
class_name HPManager

@export var max_hp: float
var current_hp: float
var sunk: bool = false
var ship: Ship

signal hp_changed(new_hp: float)
signal ship_sunk()

@export_tool_button("Generate_parts") var generate_parts_button: Callable = _generate_armor_parts

@export var citadel: HpPartMod
@export var casemate: HpPartMod
@export var bow: HpPartMod
@export var stern: HpPartMod
@export var superstructure: HpPartMod

const SHELL_DAMAGE_RADIUS_MOD: float = 12.5

func _generate_armor_parts():
	if !Engine.is_editor_hint():
		return
	if !citadel:
		citadel = HpPartMod.new()
		citadel.resource_local_to_scene = true
	citadel.pool1 = max_hp * 3.0
	citadel.pool2 = max_hp * 3.0
	if !casemate:
		casemate = HpPartMod.new()
		casemate.resource_local_to_scene = true
	casemate.pool1 = max_hp * 0.9 / 3.0
	casemate.pool2 = 2.0 * max_hp * 0.9 / 3.0
	if !bow:
		bow = HpPartMod.new()
		bow.resource_local_to_scene = true
	bow.pool1 = max_hp * 0.5 / 3.0
	bow.pool2 = 2.0 * max_hp * 0.5 / 3.0
	if !stern:
		stern = HpPartMod.new()
		stern.resource_local_to_scene = true
	stern.pool1 = max_hp * 0.5 / 3.0
	stern.pool2 = 2.0 * max_hp * 0.5 / 3.0
	if !superstructure:
		superstructure = HpPartMod.new()
		superstructure.resource_local_to_scene = true
	superstructure.pool1 = max_hp * 0.4 / 3.0
	superstructure.pool2 = 2.0 * max_hp * 0.4 / 3.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	current_hp = max_hp
	ship = get_parent().get_parent() as Ship
	if ship == null:
		push_error("HPManager: Could not find Ship in parent hierarchy")
		return
	if citadel:
		citadel.init(ship)
	if casemate:
		casemate.init(ship)
	if bow:
		bow.init(ship)
	if stern:
		stern.init(ship)
	if superstructure:
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
	ship._disable_weapons()
	#ship.set_physics_process(false)
	if _Utils.authority():
		sink.rpc()

func is_alive() -> bool:
	return current_hp > 0

func is_dead() -> bool:
	return current_hp <= 0
