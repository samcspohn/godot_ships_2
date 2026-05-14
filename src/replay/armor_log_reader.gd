## ArmorLogReader — parses a binary .armorlog companion file produced by
## ArmorSimLogger during match recording.
##
## After load_file(), use get_hit_by_uid(shell_uid) to retrieve armor
## interaction data for a specific shell.
##
## VERSION 8 format: unified ship table in header (name + scene_path per ship_id);
## attacker_id and victim_id index into that table.  caliber(f64) added per hit.
## Per-hit shell params added: shell_mass(f64) shell_pen_modifier(f64) shell_auto_bounce(f64)
## shell_ricochet_angle(f64) shell_overmatch(u8) shell_arming_threshold(u8) shell_fuze_delay(f64).
## All earlier versions are rejected with ERR_FILE_UNRECOGNIZED.
extends RefCounted
class_name ArmorLogReader

const MAGIC:   int = 0x41524D4C   # "ARML"
const VERSION:     int = 9
const VERSION_MIN: int = 7   ## oldest version still accepted (missing shell param fields)

## All parsed hit records, indexed by shell_uid.
## Each value is a Dictionary with keys:
##   timestamp(float) shell_uid(int) final_hit_type(int)
##   attacker_ship_id(int)  attacker_name(String)        ← ship class (e.g. Wotan)
##                          attacker_player_name(String) ← player name (e.g. 1001)
##   victim_ship_id(int)    victim_name(String)          ← ship class
##                          victim_player_name(String)   ← player name
##                          victim_scene_path(String)
##   victim_pos_x(float) victim_pos_z(float) victim_rot_y(float)
##   shell_type(int)  caliber(float)
##   steps: Array[Dictionary]  — see _parse_step() for per-step keys
##   final_pos: Vector3
var hits_by_uid: Dictionary = {}

## Load and parse a .armorlog file. Returns OK on success.
## Returns ERR_FILE_UNRECOGNIZED for unsupported format versions.
func load_file(path: String) -> Error:
	hits_by_uid.clear()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()

	# Header
	var magic:   int = f.get_32()
	var version: int = f.get_8()
	if magic != MAGIC:
		push_error("ArmorLogReader: bad magic 0x%X in '%s'" % [magic, path])
		return ERR_FILE_CORRUPT
	if version < VERSION_MIN or version > VERSION:
		push_error("ArmorLogReader: version %d not supported (expected %d..%d) in '%s' — re-record to upgrade." % [
			version, VERSION_MIN, VERSION, path])
		return ERR_FILE_UNRECOGNIZED
	if version < VERSION:
		push_warning("ArmorLogReader: version %d log — shell param fields absent, validation will use fallback params." % version)

	# Ship info table: Array[Dictionary] indexed by ship_id.
	# Each entry: { "player_name": String, "ship_name": String, "scene_path": String }
	var ship_count: int  = f.get_8()
	var ship_table: Array = []
	for _i in range(ship_count):
		var pname_len:   int              = f.get_8()
		var pname_bytes: PackedByteArray  = f.get_buffer(pname_len)
		var sname_len:   int              = f.get_8()
		var sname_bytes: PackedByteArray  = f.get_buffer(sname_len)
		var scene_len:   int              = f.get_8()
		var scene_bytes: PackedByteArray  = f.get_buffer(scene_len)
		ship_table.append({
			"player_name": pname_bytes.get_string_from_utf8(),
			"ship_name":   sname_bytes.get_string_from_utf8(),
			"scene_path":  scene_bytes.get_string_from_utf8(),
		})

	var hit_count: int = f.get_32()
	for _i in range(hit_count):
		if f.get_position() >= f.get_length():
			break
		var hit := _parse_hit(f, ship_table, version)
		if hit.is_empty():
			break
		hits_by_uid[hit["shell_uid"]] = hit

	return OK

## Return the hit record for a given shell_uid, or empty dict if not found.
func get_hit_by_uid(shell_uid: int) -> Dictionary:
	return hits_by_uid.get(shell_uid, {})

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _parse_hit(f: FileAccess, ship_table: Array, version: int = VERSION) -> Dictionary:
	var d: Dictionary = {}
	d["timestamp"]        = f.get_double()
	d["shell_uid"]        = f.get_32()
	d["final_hit_type"]   = f.get_8()
	var att_id: int       = f.get_8()
	var vic_id: int       = f.get_8()
	d["attacker_ship_id"]     = att_id
	d["victim_ship_id"]       = vic_id
	d["attacker_name"]        = ship_table[att_id]["ship_name"]    if att_id < ship_table.size() else ""
	d["attacker_player_name"] = ship_table[att_id]["player_name"]  if att_id < ship_table.size() else ""
	d["victim_name"]          = ship_table[vic_id]["ship_name"]    if vic_id < ship_table.size() else ""
	d["victim_player_name"]   = ship_table[vic_id]["player_name"]  if vic_id < ship_table.size() else ""
	d["victim_scene_path"]    = ship_table[vic_id]["scene_path"]   if vic_id < ship_table.size() else ""
	d["victim_pos_x"]     = f.get_double()
	d["victim_pos_z"]     = f.get_double()
	d["victim_rot_y"]     = f.get_double()
	d["shell_type"] = f.get_8()
	d["caliber"]    = f.get_double()
	if version >= 8:
		d["shell_mass"]             = f.get_double()
		d["shell_pen_modifier"]     = f.get_double()
		d["shell_auto_bounce"]      = f.get_double()
		d["shell_ricochet_angle"]   = f.get_double()
		d["shell_overmatch"]        = f.get_8()
		d["shell_arming_threshold"] = f.get_8()
		d["shell_fuze_delay"]       = f.get_double()
	# v7 and below: shell param keys intentionally absent — caller uses fallback
	var step_count: int   = f.get_8()
	var steps: Array      = []
	for _i in range(step_count):
		steps.append(_parse_step(f, version))
	d["steps"]     = steps
	d["final_pos"] = Vector3(f.get_double(), f.get_double(), f.get_double())
	return d

func _parse_step(f: FileAccess, version: int = VERSION) -> Dictionary:
	var s: Dictionary = {}
	s["result"]       = f.get_8()
	s["is_citadel"]   = f.get_8() != 0
	s["armor_mm"]     = f.get_double()
	s["effective_mm"] = f.get_double()
	s["impact_angle"] = f.get_double()
	s["pen"]          = f.get_double()
	s["integrity"]    = f.get_double()
	s["pos"]          = Vector3(f.get_double(), f.get_double(), f.get_double())
	s["vel"]          = Vector3(f.get_double(), f.get_double(), f.get_double())
	if version >= 9:
		s["impact_vel"] = Vector3(f.get_double(), f.get_double(), f.get_double())
	# v8 and below: impact_vel absent — caller uses steps[i-1].vel as approximation
	var path_len: int               = f.get_8()
	var path_bytes: PackedByteArray = f.get_buffer(path_len)
	s["armor_path"]   = path_bytes.get_string_from_utf8()
	return s
