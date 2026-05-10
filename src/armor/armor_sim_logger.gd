## ArmorSimLogger — autoload that records AP shell armor interaction data to
## a binary companion file (.armorlog) written alongside each .replay file.
##
## Binary format (.armorlog) — VERSION 7:
##   Header: MAGIC(u32) VERSION(u8)
##           ship_count(u8)
##           for each ship (indexed by ship_id):
##             player_name_len(u8) player_name_bytes[...] ← ship.name (player/node name)
##             ship_name_len(u8)   ship_name_bytes[...]   ← ship.ship_name (class like Wotan)
##             scene_path_len(u8)  scene_path_bytes[...]  ← ship.scene_file_path
##           hit_count(u32)   ← placeholder; patched by end_log()
##   Per hit: timestamp(f64) shell_uid(u32) final_hit_type(u8)
##            attacker_id(u8) victim_id(u8)   ← both index into ship table
##            victim_pos_x(f64) victim_pos_z(f64) victim_rot_y(f64)
##            shell_type(u8)   ← ShellParams.ShellType (0=HE, 1=AP)
##            caliber(f64)
##            step_count(u8) [per-step data...] final_pos(3×f64)
##   Per step: result(u8) is_citadel(u8) armor_mm(f64) effective_mm(f64)
##             impact_angle(f64) pen(f64) integrity(f64) pos(3×f64) vel(3×f64)
##             armor_path_len(u8) armor_path_bytes
##
## All real-valued fields use f64 (store_double / get_double).
extends Node

const MAGIC:   int = 0x41524D4C  # "ARML"
const VERSION: int = 7

var _file:             FileAccess  = null
var _match_start_time: float       = 0.0
var _hit_count:        int         = 0
var _ship_to_id:       Dictionary  = {}   # Ship node → int (ship_id)

## Ship info table indexed by ship_id.
## Each entry: { "name": String, "scene": String }
var _ship_table: Array = []

## Byte offset of the hit_count placeholder so end_log() can seek back and patch it.
var _hit_count_offset: int = 0

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Open a companion .armorlog file alongside the given replay file path.
## ship_to_id is a copy of ReplayRecorder._ship_to_id (Ship → int).
## Must be called from begin_match before any hits are recorded.
func begin_log(replay_path: String, ship_to_id: Dictionary) -> void:
	end_log()   # close any previously open log
	var log_path: String = replay_path.get_basename() + ".armorlog"
	_file = FileAccess.open(log_path, FileAccess.WRITE)
	if _file == null:
		push_error("ArmorSimLogger: failed to open '%s' (error %d)" % [
			log_path, FileAccess.get_open_error()])
		return

	_file.store_32(MAGIC)
	_file.store_8(VERSION)

	# Build ship info table indexed by ship_id so attacker_id/victim_id
	# double as direct table indices — no separate lookup field needed.
	var max_id: int = 0
	for sid in ship_to_id.values():
		max_id = maxi(max_id, sid)
	_ship_table = []
	_ship_table.resize(max_id + 1)
	for i in _ship_table.size():
		_ship_table[i] = {"name": "", "scene": ""}
	for ship_node in ship_to_id.keys():
		if not is_instance_valid(ship_node):
			continue
		var sid: int = ship_to_id[ship_node]
		_ship_table[sid] = {
			"player_name": ship_node.name,            # node/player name (e.g. "1001")
			"ship_name":   ship_node.ship_name,       # ship class name (e.g. "Wotan")
			"scene":       ship_node.scene_file_path,
		}

	# Write table: count then per-entry (player_name + ship_name + scene_path), in ship_id order.
	_file.store_8(mini(_ship_table.size(), 255))
	for entry in _ship_table:
		var pname_bytes: PackedByteArray = (entry["player_name"] as String).to_utf8_buffer()
		if pname_bytes.size() > 255:
			pname_bytes.resize(255)
		_file.store_8(pname_bytes.size())
		_file.store_buffer(pname_bytes)
		var sname_bytes: PackedByteArray = (entry["ship_name"] as String).to_utf8_buffer()
		if sname_bytes.size() > 255:
			sname_bytes.resize(255)
		_file.store_8(sname_bytes.size())
		_file.store_buffer(sname_bytes)
		var scene_bytes: PackedByteArray = (entry["scene"] as String).to_utf8_buffer()
		if scene_bytes.size() > 255:
			scene_bytes.resize(255)
		_file.store_8(scene_bytes.size())
		_file.store_buffer(scene_bytes)

	# hit_count placeholder — remember offset so end_log() can seek back and patch it.
	_hit_count_offset = _file.get_position()
	_file.store_32(0)

	_match_start_time = Time.get_ticks_msec() / 1000.0
	_hit_count        = 0
	_ship_to_id       = ship_to_id.duplicate()

## Flush and close the log, patching the hit_count in the header.
func end_log() -> void:
	if _file == null:
		return
	_file.seek(_hit_count_offset)
	_file.store_32(_hit_count)
	_file.flush()
	_file.close()
	_file             = null
	_hit_count        = 0
	_hit_count_offset = 0
	_ship_to_id       = {}
	_ship_table       = []

## Record one armor hit.  shell_type: ShellParams.ShellType int (0=HE, 1=AP).
func record_hit(
		shell_uid:        int,
		final_hit_type:   int,
		attacker_ship:    Object,
		victim_ship:      Object,
		victim_pos:       Vector3,
		victim_rot_y:     float,
		shell_type:       int,
		caliber:          float,
		steps:            Array,
		final_pos:        Vector3) -> void:
	if _file == null:
		return
	var attacker_id: int = _ship_to_id.get(attacker_ship, 255)
	var victim_id:   int = _ship_to_id.get(victim_ship,   255)
	_file.store_double(Time.get_ticks_msec() / 1000.0 - _match_start_time)
	_file.store_32(shell_uid & 0xFFFFFFFF)
	_file.store_8(final_hit_type & 0xFF)
	_file.store_8(attacker_id   & 0xFF)
	_file.store_8(victim_id     & 0xFF)
	_file.store_double(victim_pos.x)
	_file.store_double(victim_pos.z)
	_file.store_double(victim_rot_y)
	_file.store_8(shell_type & 0xFF)
	_file.store_double(caliber)
	var sc: int = mini(steps.size(), 255)
	_file.store_8(sc)
	for i in range(sc):
		_write_step(steps[i])
	_file.store_double(final_pos.x)
	_file.store_double(final_pos.y)
	_file.store_double(final_pos.z)
	_hit_count += 1

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _write_step(step: Dictionary) -> void:
	_file.store_8(step.get("result",       0) & 0xFF)
	_file.store_8(1 if step.get("is_citadel", false) else 0)
	_file.store_double(step.get("armor_mm",     0.0))
	_file.store_double(step.get("effective_mm", 0.0))
	_file.store_double(step.get("impact_angle", 0.0))
	_file.store_double(step.get("pen",          0.0))
	_file.store_double(step.get("integrity",    1.0))
	var pos: Vector3 = step.get("pos", Vector3.ZERO)
	_file.store_double(pos.x)
	_file.store_double(pos.y)
	_file.store_double(pos.z)
	var vel: Vector3 = step.get("vel", Vector3.ZERO)
	_file.store_double(vel.x)
	_file.store_double(vel.y)
	_file.store_double(vel.z)
	var armor_path: String          = step.get("armor_path", "")
	var path_bytes: PackedByteArray = armor_path.to_utf8_buffer()
	if path_bytes.size() > 63:
		path_bytes.resize(63)
	_file.store_8(path_bytes.size())
	_file.store_buffer(path_bytes)
