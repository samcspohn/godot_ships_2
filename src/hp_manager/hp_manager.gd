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
@export var bow_percent: float = 0.06
@export var stern_percent: float = 0.06
@export var superstructure_percent: float = 0.03
@export var casemate_percent: float = 0.15
@export var hull_percent: float = 0.75

## Share of a pen drawn from the hit section; the rest comes from the hull (WoWS saturation).
const SECTION_SHARE: float = 0.5

var casemate: HpPartMod
var bow: HpPartMod
var stern: HpPartMod
var superstructure: HpPartMod
var hull: HpPartMod

var healable_damage: float = 0.0
var light_damage: float = 0.0
## Who has been hurting this hull lately: Ship -> [decayed damage, time_sec].
var damage_from: Dictionary = {}
const DAMAGE_MEMORY_SEC: float = 60.0

func _note_damage(owner: Ship, dmg: float) -> void:
	if owner == null or owner == ship or dmg <= 0.0:
		return
	var now: float = SimClock.now()
	var rec: Array = damage_from.get(owner, [0.0, now])
	damage_from[owner] = [rec[0] * exp(-(now - rec[1]) / DAMAGE_MEMORY_SEC) + dmg, now]

## Damage `owner` has done here, decayed with DAMAGE_MEMORY_SEC.
func recent_damage_from(owner: Ship) -> float:
	var rec: Array = damage_from.get(owner, [])
	if rec.is_empty():
		return 0.0
	return rec[0] * exp(-(SimClock.now() - rec[1]) / DAMAGE_MEMORY_SEC)
const SHELL_DAMAGE_RADIUS_MOD: float = 17.0
const DMG_MOD_REF_SHIP_PER_CAL_SQ: float = 40000000.0 / (406.0 * 406.0)
const DMG_MOD_SMALL: float = 0.8
const DMG_MOD_SMALL_RATIO: float = 0.1

## Damage share a shell of `caliber` mm does to a hull of `mass` kg: less to a small hull from a big gun.
static func size_mod(mass: float, caliber: float) -> float:
	var size_ratio: float = (mass / maxf(caliber * caliber, 1.0)) / DMG_MOD_REF_SHIP_PER_CAL_SQ
	return minf(remap(size_ratio, DMG_MOD_SMALL_RATIO, 1.0, DMG_MOD_SMALL, 1.0), 1.0)

func parts() -> Array[HpPartMod]:
	return [casemate, bow, stern, superstructure, hull]

func _recalculate_healable_damage() -> void:
	healable_damage = light_damage
	for part in parts():
		healable_damage += part.healable_damage

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

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	ship = get_parent().get_parent() as Ship
	if ship == null:
		push_error("HPManager: Could not find Ship in parent hierarchy")
		return
	params = params.instantiate(ship) as HPParams
	_current_hp = _max_hp

	casemate = HpPartMod.make(ship, _max_hp * casemate_percent)
	bow = HpPartMod.make(ship, _max_hp * bow_percent)
	stern = HpPartMod.make(ship, _max_hp * stern_percent)
	superstructure = HpPartMod.make(ship, _max_hp * superstructure_percent)
	hull = HpPartMod.make(ship, _max_hp * hull_percent)
	for part in parts():
		part.hp = self
	_recalculate_healable_damage()

func _part_damage(part: HpPartMod, dmg: float, repair_rate: float) -> float:
	return part.apply_damage(dmg * SECTION_SHARE, repair_rate) \
		+ hull.apply_damage(dmg * (1.0 - SECTION_SHARE), repair_rate)

func apply_damage(dmg: float, base_dmg:float, armor_part: ArmorPart, is_pen: bool, damage_type: DAMAGE_TYPE, damage_level: DAMAGE_LEVEL, owner: Ship, shell_cal: float) -> Array:
	if sunk:
		return [0, false]

	# ship.update_static_mods = true
	var dmg_mod := size_mod(ship.mass, shell_cal)
	dmg *= dmg_mod
	dmg /= params.p().mult
	base_dmg *= dmg_mod
	base_dmg /= params.p().mult

	if armor_part == null:
		_current_hp -= dmg
		_note_damage(owner, dmg * params.p().mult)
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
	elif !is_pen or armor_part.hp_part == null:
		_dmg = dmg
		light_damage += dmg * repair_rate
	else:
		_dmg = _part_damage(armor_part.hp_part, dmg, repair_rate)

	if is_pen:
		dmg = max(_dmg, base_dmg * 0.1)

	var spill_healable_damage = max(dmg - _dmg, 0.0) * repair_rate
	if spill_healable_damage > 0.0:
		light_damage += spill_healable_damage
	_recalculate_healable_damage()


	_current_hp -= dmg
	_note_damage(owner, dmg * params.p().mult)
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
	var total: float = light_damage
	for part in parts():
		total += part.healable_damage
	if total <= 0.0001:
		return 0.0
	var ret: float = 0.0
	for part in parts():
		ret += part.heal(amount * part.healable_damage / total)
	var light_heal: float = minf(amount * light_damage / total, light_damage)
	ret += light_heal
	light_damage -= light_heal
	_recalculate_healable_damage()
	_current_hp += ret
	hp_changed.emit(_current_hp)
	return ret * params.p().mult

# @rpc("any_peer", "reliable", "call_remote")
func sink(damage_type: DAMAGE_TYPE, sinker: Ship):
	sunk = true
	if !(_Utils.authority()):
		HitEffects.death_blast_effect(ship.global_transform.origin, 30.0)
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
		sunk_time = SimClock.now()
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
		sinking_time = SimClock.now()
		ship.freeze = true
		ship.linear_velocity = Vector3.ZERO
		var server: GameServer = ship.get_node_or_null("/root/Server")
		if server != null:
			server.credit_kill(sinker, ship)
		sink_c.rpc(sinking_basis, damage_type, sinker.name, sinker.team.team_id, sinker.ship_name, ship.ship_name, ship.team.team_id, ship.name)
		_Utils.kill_feed_event.emit(sinker.ship_name, sinker.name, sinker.team.team_id, damage_type, ship.ship_name, ship.name, ship.team.team_id)

@rpc("authority", "reliable", "call_remote")
func sink_c(sink_basis: Basis, damage_type: DAMAGE_TYPE, sinker: String, team: int, sinker_ship_name: String = "", sunk_ship_name: String = "", sunk_team: int = -1, sunk_player_name: String = ""):
	if !(_Utils.authority()):
		sinking_basis = sink_basis
		current_sinking_basis = ship.global_basis
		sinking_time = SimClock.now()
		ship.freeze = true
		ship.linear_velocity = Vector3.ZERO
		sinking = true
		var size = ship.movement_controller.ship_length * (100.0 / 575.0)
		HitEffects.death_blast_effect(ship.global_transform.origin, size)
		HitEffects.sparks_effect(ship.global_transform.origin, size * 0.67, Vector3.UP)
		#get_parent().queue_free()
		ship.artillery_controller.set_physics_process(false)
		ship.movement_controller.set_physics_process(false)
		#ship.get_node("Secondaries").set_physics_process(false)s
		var pc = ship.get_node_or_null("PlayerController")
		if pc == null:
			pc = ship.get_node_or_null("Modules/BotController")
		if pc != null:
			pc.set_physics_process(false)
			pc.set_process_input(false)
		var mv = ship.get_node_or_null("Modules/MovementController")
		if mv != null:
			mv.set_physics_process(false)
		var aaa = ship.get_node_or_null("Modules/AAAController")
		if aaa != null:
			aaa.set_physics_process(false)
		ship._disable_weapons()
		WaveManager.unregister_ship(ship)
		WaveManager.add_muzzle_blast(ship.global_position,ship.movement_controller.ship_length * 0.6)
		WaveManager.add_shell_splash(ship.global_position, ship.movement_controller.ship_length * 0.15)
		_Utils.kill_feed_event.emit(sinker_ship_name, sinker, team, damage_type, sunk_ship_name, sunk_player_name, sunk_team)

func _physics_process(delta: float) -> void:
	if sinking and ship.global_position.y > -400.0:
		var elapsed = SimClock.now() - sinking_time
		ship.global_position -= Vector3(0, delta * pow(elapsed, 0.6) * 0.06, 0)
		current_sinking_basis = current_sinking_basis.orthonormalized().slerp(sinking_basis.orthonormalized(), pow(elapsed, 0.3)*0.0002)
		ship.global_basis = current_sinking_basis
		# ship.global_basis = current_sinking_basis.slerp(sinking_rotation, delta * 0.005)


func is_alive() -> bool:
	return _current_hp > 0

func is_dead() -> bool:
	return _current_hp <= 0

func been_dead() -> bool:
	return is_dead() and sunk_time < SimClock.now() - 120.0
