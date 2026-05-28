@tool
extends Node
class_name HPManager

@export var params: HPParams
var sunk: bool = false
var ship: Ship

signal hp_changed(new_hp: float)
signal ship_sunk()
var sinking: bool = false
# var sinking_rotation_axis: Vector3 = Vector3.ZERO
var sinking_basis: Basis = Basis.IDENTITY
var current_sinking_basis: Basis = Basis.IDENTITY
var sinking_time: float = 0.0
var sunk_time: float = 0.0

@export var _max_hp: float = 10000.0
var max_hp:
	get:
		return _max_hp * params.p().mult
	# set(value):
	# 	_max_hp = value / params.p().mult
var _current_hp: float = 10000.0
var current_hp:
	get:
		return _current_hp * params.p().mult
	# set(value):
	# 	_current_hp = value / params.p().mult
@export_tool_button("Generate_parts") var generate_parts_button: Callable = _generate_armor_parts
@export var bow_percent: float = 0.35
@export var stern_percent: float = 0.35
@export var superstructure_percent: float = 0.5
@export var casemate_percent: float = 0.8

@export var citadel: HpPartMod
@export var casemate: HpPartMod
@export var bow: HpPartMod
@export var stern: HpPartMod
@export var superstructure: HpPartMod
# @export var module: HpPartMod <- put in artillery/secondary controller/turret params

var healable_damage: float = 0.0
var light_damage: float = 0.0
# const SHELL_DAMAGE_RADIUS_MOD: float = 14.0

func _recalculate_healable_damage() -> void:
	healable_damage = light_damage
	if casemate:
		healable_damage += casemate.healable_damage
	if bow:
		healable_damage += bow.healable_damage
	if stern:
		healable_damage += stern.healable_damage
	if superstructure:
		healable_damage += superstructure.healable_damage
	if citadel:
		healable_damage += citadel.healable_damage

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	if ship.name == "1":
		pass
	writer.put_float(_max_hp * params.p().mult)
	writer.put_float(_current_hp * params.p().mult)
	return writer.get_data_array()

# client side rendering
func from_bytes(data: PackedByteArray):
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	_max_hp = reader.get_float()
	_current_hp = reader.get_float()

enum DAMAGE_TYPE {
	SHELL, # 0
	TORPEDO, # 1
	FIRE, # 2
	FLOOD, # 3
	SECONDARY, # 4
}
enum DAMAGE_LEVEL {
	LIGHT,
	MEDIUM,
	HEAVY,
}

func _generate_armor_parts():
	if !Engine.is_editor_hint():
		return

	if !citadel:
		citadel = HpPartMod.new()
		citadel.resource_local_to_scene = true
	var _ship: Ship = $"../.."
	if _ship.ship_class == Ship.ShipClass.CA:
		citadel.pool1 = _max_hp * 0.3
	else:
		citadel.pool1 = _max_hp  * 3.0
	citadel.pool2 = _max_hp * 3.0
	if !casemate:
		casemate = HpPartMod.new()
		casemate.resource_local_to_scene = true
	casemate.pool1 = _max_hp * casemate_percent / 3.0
	casemate.pool2 = 2.0 * _max_hp * casemate_percent / 3.0
	if !bow:
		bow = HpPartMod.new()
		bow.resource_local_to_scene = true
	bow.pool1 = _max_hp * bow_percent / 3.0
	bow.pool2 = 2.0 * _max_hp * bow_percent / 3.0
	if !stern:
		stern = HpPartMod.new()
		stern.resource_local_to_scene = true
	stern.pool1 = _max_hp * stern_percent / 3.0
	stern.pool2 = 2.0 * _max_hp * stern_percent / 3.0
	if !superstructure:
		superstructure = HpPartMod.new()
		superstructure.resource_local_to_scene = true
	superstructure.pool1 = _max_hp * superstructure_percent / 3.0
	superstructure.pool2 = 2.0 * _max_hp * superstructure_percent / 3.0

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	ship = get_parent().get_parent() as Ship
	if ship == null:
		push_error("HPManager: Could not find Ship in parent hierarchy")
		return
	params = params.instantiate(ship) as HPParams
	_current_hp = _max_hp

	if citadel:
		citadel = citadel.instantiate(ship) as HpPartMod
		citadel.hp = self
	if casemate:
		casemate = casemate.instantiate(ship) as HpPartMod
		casemate.hp = self
	if bow:
		bow = bow.instantiate(ship) as HpPartMod
		bow.hp = self
	if stern:
		stern = stern.instantiate(ship) as HpPartMod
		stern.hp = self
	if superstructure:
		superstructure = superstructure.instantiate(ship) as HpPartMod
		superstructure.hp = self
	_recalculate_healable_damage()

func apply_damage(dmg: float, base_dmg:float, armor_part: ArmorPart, is_pen: bool, damage_type: DAMAGE_TYPE, damage_level: DAMAGE_LEVEL, owner: Ship) -> Array:
	if sunk:
		return [0, false]

	# ship.update_static_mods = true
	# var radius_mod = shell_cal / SHELL_DAMAGE_RADIUS_MOD
	# var dmg_mod = clamp(ship.beam / radius_mod, 0.0, 1.0)
	# dmg *= dmg_mod
	dmg /= params.p().mult
	# base_dmg *= dmg_mod
	base_dmg /= params.p().mult

	if armor_part == null:
		_current_hp -= dmg
		light_damage += dmg * params.p().light_repair
		_recalculate_healable_damage()
		if _current_hp <= 0 && !sunk:
			dmg += _current_hp
			_current_hp = 0
			sink(damage_type, owner)
			ship_sunk.emit()
			hp_changed.emit(_current_hp)
			return [dmg * params.p().mult, true]
		hp_changed.emit(_current_hp)
		return [dmg * params.p().mult, false]

	var pen_repair = params.p().pen_repair
	var citadel_repair = params.p().citadel_repair # heavy
	var light_repair = params.p().light_repair
	var repair_rate = 0.0
	if damage_level == DAMAGE_LEVEL.LIGHT or armor_part.type == ArmorPart.Type.MODULE:
		repair_rate = light_repair
	elif damage_level == DAMAGE_LEVEL.MEDIUM:
		repair_rate = pen_repair
	elif damage_level == DAMAGE_LEVEL.HEAVY:
		repair_rate = citadel_repair

	# # TODO: how to handle overpenetration/citadel overpen damage?
	var _dmg: float = 0
	if armor_part.type == ArmorPart.Type.MODULE:
		_dmg = min(dmg, base_dmg * 0.1)
		# Module hits have no hp_part to track healable; route applied damage to the
		# ship-wide light_damage pool, same as the armor_part==null branch above.
		light_damage += _dmg * repair_rate
	elif armor_part.type == ArmorPart.Type.CITADEL:
		_dmg = citadel.apply_damage(dmg, 0.5, repair_rate)
	elif armor_part.hp_part != null: # handled by module
		_dmg = armor_part.hp_part.apply_damage(dmg, 0.5, repair_rate)

	if is_pen:
		dmg = max(_dmg, base_dmg * 0.1)

	# Spill = HP loss not absorbed by the armor part's pools (overpen floor, pool capped,
	# or split overflow). It must follow the same repair_rate the hit used; otherwise a
	# repair_rate of 1.0 would still produce unhealable damage when spill > 0.
	var spill_healable_damage = max(dmg - _dmg, 0.0) * repair_rate
	if spill_healable_damage > 0.0:
		light_damage += spill_healable_damage
	_recalculate_healable_damage()


	_current_hp -= dmg
	if _current_hp <= 0 && !sunk:
		dmg += _current_hp
		_current_hp = 0
		sink(damage_type, owner)
		ship_sunk.emit()
		hp_changed.emit(_current_hp)
		return [dmg * params.p().mult, true]
	hp_changed.emit(_current_hp)
	return [dmg * params.p().mult, false]


func heal(amount: float) -> float:
	if is_dead():
		return 0.0
	# ship.update_static_mods = true
	amount /= params.p().mult
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
		var light_heal = min(amount * (light_damage / total), light_damage)
		ret += light_heal
		light_damage -= light_heal
		_recalculate_healable_damage()
		_current_hp += ret
		return ret * params.p().mult
	return 0.0

# @rpc("any_peer", "reliable", "call_remote")
func sink(damage_type: DAMAGE_TYPE, sinker: Ship):
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
	var mv = ship.get_node_or_null("Modules/MovementController")
	if mv != null:
		mv.set_physics_process(false)
	ship._disable_weapons()

	ship.sync2.rpc(ship.sync_ship_data2(true,false), false)
	#ship.set_physics_process(false)
	if _Utils.authority():
		sinking = true
		sunk_time = Time.get_ticks_msec() / 1000.0
		# sinking_rotation_axis = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		# sinking_basis = Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU))
		current_sinking_basis = ship.global_basis
		# Extract the current yaw (Y rotation) to preserve it
		var current_euler = current_sinking_basis.get_euler()
		var preserved_yaw = current_euler.y
		# Generate random pitch and roll for sinking
		var random_pitch = (randf() - 0.5) * PI * 0.5  # Random pitch between -45 and 45 degrees
		var random_roll = (randf() - 0.5) * PI * 0.8   # Random roll between -72 and 72 degrees
		# Build the sinking basis with preserved yaw and new pitch/roll
		sinking_basis = Basis.from_euler(Vector3(random_pitch, preserved_yaw, random_roll))
		sinking_time = Time.get_ticks_msec() / 1000.0
		ship.freeze = true
		ship.linear_velocity = Vector3.ZERO
		sink_c.rpc(sinking_basis, damage_type, sinker.name, sinker.team.team_id, sinker.ship_name, ship.ship_name, ship.team.team_id, ship.name)
		_Utils.kill_feed_event.emit(sinker.ship_name, sinker.name, sinker.team.team_id, damage_type, ship.ship_name, ship.name, ship.team.team_id)

@rpc("authority", "reliable", "call_remote")
func sink_c(sink_basis: Basis, damage_type: DAMAGE_TYPE, sinker: String, team: int, sinker_ship_name: String = "", sunk_ship_name: String = "", sunk_team: int = -1, sunk_player_name: String = ""):
	if !(_Utils.authority()):
		sinking_basis = sink_basis
		current_sinking_basis = ship.global_basis
		sinking_time = Time.get_ticks_msec() / 1000.0
		ship.freeze = true
		ship.linear_velocity = Vector3.ZERO
		sinking = true
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
		var mv = ship.get_node_or_null("Modules/MovementController")
		if mv != null:
			mv.set_physics_process(false)
		ship._disable_weapons()
		_Utils.kill_feed_event.emit(sinker_ship_name, sinker, team, damage_type, sunk_ship_name, sunk_player_name, sunk_team)

func _physics_process(delta: float) -> void:
	if sinking and ship.global_position.y > -400.0:
		var elapsed = Time.get_ticks_msec() / 1000.0 - sinking_time
		ship.global_position -= Vector3(0, delta * pow(elapsed, 0.6) * 0.06, 0)
		current_sinking_basis = current_sinking_basis.orthonormalized().slerp(sinking_basis.orthonormalized(), pow(elapsed, 0.3)*0.0002)
		ship.global_basis = current_sinking_basis
		# ship.global_basis = current_sinking_basis.slerp(sinking_rotation, delta * 0.005)


func is_alive() -> bool:
	return _current_hp > 0

func is_dead() -> bool:
	return _current_hp <= 0

func been_dead() -> bool:
	return is_dead() and sunk_time < Time.get_ticks_msec() / 1000.0 - 120.0
