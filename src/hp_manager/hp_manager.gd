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

var healable_damage: float = 0.0
var light_damage: float = 0.0
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
		citadel.hp = self
	if casemate:
		casemate.init(ship)
		casemate.hp = self
	if bow:
		bow.init(ship)
		bow.hp = self
	if stern:
		stern.init(ship)
		stern.hp = self
	if superstructure:
		superstructure.init(ship)
		superstructure.hp = self

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
		ArmorPart.Type.CITADEL:
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

	match armor_part.type:
		ArmorPart.Type.MODULE:
			light_damage += dmg * 0.5
			healable_damage += dmg * 0.5
		ArmorPart.Type.CITADEL:
			citadel.healable_damage += dmg * 0.2
			healable_damage += dmg * 0.2
		ArmorPart.Type.CASEMATE:
			casemate.healable_damage += dmg * 0.5
			healable_damage += dmg * 0.5
		ArmorPart.Type.BOW:
			bow.healable_damage += dmg * 0.5
			healable_damage += dmg * 0.5
		ArmorPart.Type.STERN:
			stern.healable_damage += dmg * 0.5
			healable_damage += dmg * 0.5
		ArmorPart.Type.SUPERSTRUCTURE:
			superstructure.healable_damage += dmg * 0.5
			healable_damage += dmg * 0.5


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
	light_damage += dmg
	healable_damage += dmg
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
	if is_dead():
		return 0.0
	var casemate_dmg = self.casemate.healable_damage
	var bow_dmg = self.bow.healable_damage
	var stern_dmg = self.stern.healable_damage
	var superstructure_dmg = self.superstructure.healable_damage
	var citadel_dmg = self.citadel.healable_damage

	var total = casemate_dmg + bow_dmg + stern_dmg + superstructure_dmg + citadel_dmg + light_damage
	if total > 0.0001:
		var ret = 0.0
		ret += casemate.heal(amount * (casemate_dmg / total))
		ret += bow.heal(amount * (bow_dmg / total))
		ret += stern.heal(amount * (stern_dmg / total))
		ret += superstructure.heal(amount * (superstructure_dmg / total))
		ret += citadel.heal(amount * (citadel_dmg / total))
		ret += amount * (light_damage / total)
		light_damage -= amount * (light_damage / total)
		healable_damage -= ret
		current_hp += ret
		return ret
	return 0.0

	# 	return 0.0
	# if current_hp + amount > max_hp:
	# 	amount = max_hp - current_hp
	# current_hp += amount
	# hp_changed.emit(current_hp)
	# return amount

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
	if pc == null:
		pc = ship.get_node_or_null("Modules/BotController")
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
