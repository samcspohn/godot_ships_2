class_name TeamState
extends RefCounted

# vel/rot are frozen at observation; reading them live off the Ship leaks concealed motion.
class Contact:
	var pos: Vector3
	var time: float
	var vel: Vector3
	var rot: float
	var source: String

class SensorFix:
	var pos: Vector3
	var time: float
	var in_range: bool

var id: int
var ships: Array[Ship] = []
var valid_targets: Array[Ship] = []
## Enemies this team has a last-known contact on.
var contacts: Dictionary[Ship, Contact] = {}
## Deductions, not sightings; kept out of contacts so they can never become an aim point.
## Ship -> {position: Vector3, time: float, radius: float, source: String}
var inferred_contacts: Dictionary = {}
var hydro: Dictionary[Ship, SensorFix] = {}
var radar: Dictionary[Ship, SensorFix] = {}
var air: Dictionary[Ship, SensorFix] = {}
## Ship -> expiry time
var launch_reveals: Dictionary = {}
var known_enemy_clusters: Array[Dictionary] = []
var presumption: EnemyPresumption = EnemyPresumption.new()
const POINTS_START: int = 300
var points: int = POINTS_START

# Getters hand out Ship->field dicts; rebuilt only after contacts change.
var _views_dirty: bool = true
var _pos_view: Dictionary = {}
var _time_view: Dictionary = {}
var _vel_view: Dictionary = {}
var _rot_view: Dictionary = {}
var _source_view: Dictionary = {}

func _init(team_id: int) -> void:
	id = team_id

func write_contact(ship: Ship, pos: Vector3, time: float, vel: Vector3, rot: float, source: String) -> void:
	var c: Contact = contacts.get(ship)
	if c == null:
		c = Contact.new()
		contacts[ship] = c
	c.pos = pos
	c.time = time
	c.vel = vel
	c.rot = rot
	c.source = source
	_views_dirty = true

func erase_contact(ship: Ship) -> void:
	if contacts.erase(ship):
		_views_dirty = true

func contact_positions() -> Dictionary:
	_refresh_views()
	return _pos_view

func contact_times() -> Dictionary:
	_refresh_views()
	return _time_view

func contact_velocities() -> Dictionary:
	_refresh_views()
	return _vel_view

func contact_rotations() -> Dictionary:
	_refresh_views()
	return _rot_view

func contact_sources() -> Dictionary:
	_refresh_views()
	return _source_view

func _refresh_views() -> void:
	if not _views_dirty:
		return
	_views_dirty = false
	# New dicts, not cleared ones: callers may still hold the previous snapshot.
	_pos_view = {}
	_time_view = {}
	_vel_view = {}
	_rot_view = {}
	_source_view = {}
	for ship in contacts:
		var c: Contact = contacts[ship]
		_pos_view[ship] = c.pos
		_time_view[ship] = c.time
		_vel_view[ship] = c.vel
		_rot_view[ship] = c.rot
		_source_view[ship] = c.source

static func refresh_fix(fixes: Dictionary[Ship, SensorFix], ship: Ship, now: float, interval: float) -> bool:
	var f: SensorFix = fixes.get(ship)
	if f == null:
		f = SensorFix.new()
		f.time = -INF
		fixes[ship] = f
	f.in_range = true
	if now - f.time < interval:
		return false
	f.pos = ship.global_position
	f.time = now
	return true

func clear_in_range() -> void:
	for fixes in [hydro, radar, air]:
		for f: SensorFix in fixes.values():
			f.in_range = false
