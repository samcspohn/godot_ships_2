class_name ReplayFileReader

# ---------------------------------------------------------------------------
# Event type constants (must match recorder)
# ---------------------------------------------------------------------------
const EVT_MATCH_START      := 0x00
const EVT_MATCH_END        := 0x01
const EVT_SNAPSHOT         := 0x02
const EVT_SHELL_FIRED      := 0x10
const EVT_SHELL_HIT        := 0x11
const EVT_TORPEDO_FIRED    := 0x20
const EVT_TORPEDO_ARMED    := 0x21
const EVT_TORPEDO_DETECTED := 0x22
const EVT_TORPEDO_DESTROYED := 0x23
const EVT_FIRE_STARTED     := 0x30
const EVT_FIRE_ENDED       := 0x31
const EVT_FLOOD_STARTED    := 0x32
const EVT_FLOOD_ENDED      := 0x33
const EVT_CONSUMABLE_USED  := 0x40
const EVT_CONSUMABLE_ENDED := 0x41
const EVT_DETECTION_CHANGED := 0x50
const EVT_SHIP_SUNK        := 0x60

const MAGIC: int = 0x52455050

# ---------------------------------------------------------------------------
# Public state
# ---------------------------------------------------------------------------
var header: Dictionary = {}          # magic, version, match_ts, map_id, ship_count, index_offset
var ships: Array = []                # Array of Dictionary (ShipManifestEntry data)
var snapshot_index: Array = []       # [{timestamp: float, offset: int}, ...]
var total_duration: float = 0.0
var winning_team: int = -1
var end_stats: Dictionary = {}       # ship_id -> stats dict

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------
var _data: PackedByteArray = PackedByteArray()
var _reader: StreamPeerBuffer = StreamPeerBuffer.new()
var _ship_count: int = 0
var _gun_counts: Array = []          # gun count per ship_id index

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Load a .replay file from disk into memory for random-access parsing.
## Returns OK on success, or an Error code on failure.
func load_file(path: String) -> Error:
	_data = FileAccess.get_file_as_bytes(path)
	if _data.is_empty():
		push_error("ReplayFileReader: file not found or empty: " + path)
		return ERR_FILE_NOT_FOUND

	_reader.data_array = _data
	_reader.seek(0)

	# ---- Header ----
	var magic: int = _reader.get_u32()
	if magic != MAGIC:
		push_error("ReplayFileReader: bad magic 0x%X (expected 0x%X)" % [magic, MAGIC])
		return ERR_FILE_CORRUPT

	var version: int    = _reader.get_u16()
	var match_ts: int   = _reader.get_u32()
	var map_id: int     = _reader.get_u8()
	var ship_count: int = _reader.get_u16()
	var index_offset: int = _reader.get_u32()

	header = {
		"magic":        magic,
		"version":      version,
		"match_ts":     match_ts,
		"map_id":       map_id,
		"ship_count":   ship_count,
		"index_offset": index_offset,
	}
	_ship_count = ship_count

	# ---- Ship manifest ----
	ships.clear()
	_gun_counts.clear()
	_gun_counts.resize(256)   # indexed by ship_id (u8)
	_gun_counts.fill(0)

	for _i in ship_count:
		var entry := _parse_manifest_entry()
		ships.append(entry)
		var sid: int = entry.get("ship_id", 0)
		if sid < 256:
			_gun_counts[sid] = entry.get("gun_count", 0)

	# ---- Index block ----
	snapshot_index.clear()
	if index_offset > 0 and index_offset < _data.size():
		_reader.seek(index_offset)
		var snap_count: int = _reader.get_u32()
		for _i in snap_count:
			var ts: float = _reader.get_float()
			var offset: int = _reader.get_64()
			snapshot_index.append({"timestamp": ts, "offset": offset})

	# ---- Scan for MATCH_END ----
	_scan_for_match_end()

	return OK


## Returns a fully-parsed snapshot dictionary for the last snapshot at or before t.
## Returns an empty dictionary if no snapshot is available.
func read_snapshot_at(t: float) -> Dictionary:
	var idx := _binary_search_snapshot(t)
	if idx < 0 or idx >= snapshot_index.size():
		return {}
	var offset: int = snapshot_index[idx].offset
	_reader.seek(offset)
	# Read event preamble
	var _ts: float = _reader.get_float()   # timestamp (already known)
	var etype: int  = _reader.get_u8()
	if etype != EVT_SNAPSHOT:
		push_warning("ReplayFileReader: expected SNAPSHOT at offset %d, got 0x%X" % [offset, etype])
		return {}
	return _parse_snapshot(_reader)


## Returns snapshot data just before t (the A frame for interpolation).
func get_snapshot_before(t: float) -> Dictionary:
	var idx := _binary_search_snapshot(t)
	if idx < 0 or idx >= snapshot_index.size():
		return {}
	return _read_snapshot_at_index(idx)


## Returns snapshot data just after t (the B frame for interpolation).
func get_snapshot_after(t: float) -> Dictionary:
	var idx := _binary_search_snapshot(t)
	var next := idx + 1
	if next >= snapshot_index.size():
		return _read_snapshot_at_index(idx)   # clamp to last
	return _read_snapshot_at_index(next)


## Returns all parsed events whose timestamps fall in [t_start, t_end].
## Each event is a Dictionary with at minimum {timestamp, type, ...payload fields}.
func read_events_in_range(t_start: float, t_end: float) -> Array:
	var result: Array = []
	if snapshot_index.is_empty():
		return result

	# Find file offset to start reading from
	var snap_idx := _binary_search_snapshot(t_start)
	var start_offset: int
	if snap_idx < 0:
		# Before any snapshot — start after the manifest (end of header block)
		# Seek back to just after the manifest: cheapest is to re-read from there.
		# We'll start at offset 0 and skip to events after manifest.
		start_offset = _find_events_start()
	else:
		start_offset = snapshot_index[snap_idx].offset

	_reader.seek(start_offset)

	# Read events sequentially
	var safe_limit: int = _data.size() - 5   # need at least 5 bytes for a preamble
	while _reader.get_position() < safe_limit:
		var event_offset: int = _reader.get_position()
		var ts: float   = _reader.get_float()
		var etype: int  = _reader.get_u8()

		if ts > t_end:
			# Past the end — stop
			break

		var evt := _parse_event(_reader, ts, etype)
		if ts >= t_start:
			result.append(evt)

		# Safety: if parse consumed nothing (unknown type), break to avoid infinite loop
		if _reader.get_position() == event_offset:
			push_warning("ReplayFileReader: parser made no progress at offset %d (type 0x%X)" % [event_offset, etype])
			break

	return result


# ---------------------------------------------------------------------------
# Private helpers — parsing
# ---------------------------------------------------------------------------

func _read_manifest_string() -> String:
	var len_: int = _reader.get_u8()
	if len_ == 0:
		return ""
	var raw := _reader.get_data(len_)
	if raw[0] != OK:
		return ""
	return (raw[1] as PackedByteArray).get_string_from_utf8()


func _parse_manifest_entry() -> Dictionary:
	var ship_id: int  = _reader.get_u8()
	var team_id: int  = _reader.get_u8()
	var is_bot: int   = _reader.get_u8()
	var player_name: String  = _read_manifest_string()
	var ship_name: String    = _read_manifest_string()
	var scene_path: String   = _read_manifest_string()
	var gun_count: int       = _reader.get_u8()
	var fire_count: int      = _reader.get_u8()
	var flood_count: int     = _reader.get_u8()
	var consumable_count: int = _reader.get_u8()

	var consumables: Array = []
	for _i in consumable_count:
		var slot_id: int = _reader.get_u8()
		var c_type: int  = _reader.get_u8()
		var label: String = _read_manifest_string()
		consumables.append({"slot_id": slot_id, "type": c_type, "label": label})

	return {
		"ship_id":         ship_id,
		"team_id":         team_id,
		"is_bot":          is_bot != 0,
		"player_name":     player_name,
		"ship_name":       ship_name,
		"scene_path":      scene_path,
		"gun_count":       gun_count,
		"fire_count":      fire_count,
		"flood_count":     flood_count,
		"consumable_count": consumable_count,
		"consumables":     consumables,
	}


## Parse one full SNAPSHOT payload (preamble already consumed by caller).
func _parse_snapshot(reader: StreamPeerBuffer) -> Dictionary:
	var snap: Dictionary = {}
	for i in _ship_count:
		var sid: int = i   # ships stored in ship_id order per spec

		# Resolve the actual ship_id from the manifest if available
		if i < ships.size():
			sid = ships[i].get("ship_id", i)

		var pos_x: float  = reader.get_float()
		var pos_z: float  = reader.get_float()
		var rot_y: float  = reader.get_float()
		var vel_x: float  = reader.get_float()
		var vel_y: float  = reader.get_float()
		var vel_z: float  = reader.get_float()
		var hp: float     = reader.get_float()
		var flags: int    = reader.get_u8()
		var throttle_raw: int = reader.get_u8()
		var throttle: int = throttle_raw - 1   # stored as actual + 1
		var rudder: float = reader.get_float()
		var aim_x: float  = reader.get_float()
		var aim_y: float  = reader.get_float()
		var aim_z: float  = reader.get_float()
		var bloom: float  = reader.get_float()
		var shell_idx: int  = reader.get_u8()
		var fire_mask: int  = reader.get_u8()
		var flood_mask: int = reader.get_u8()
		var cons_mask: int  = reader.get_u8()

		var gun_count: int = _gun_counts[sid] if sid < _gun_counts.size() else 0
		var guns: Array = []
		for _g in gun_count:
			var tr_y: float = reader.get_float()
			var br_x: float = reader.get_float()
			var reload: float = reader.get_float()
			guns.append({"rot_y": tr_y, "barrel_rot_x": br_x, "reload": reload})

		snap[sid] = {
			"pos":            Vector3(pos_x, 0.0, pos_z),
			"rot_y":          rot_y,
			"velocity":       Vector3(vel_x, vel_y, vel_z),
			"hp":             hp,
			"flags":          flags,
			"throttle":       throttle,
			"rudder":         rudder,
			"aim_point":      Vector3(aim_x, aim_y, aim_z),
			"bloom_radius":   bloom,
			"shell_index":    shell_idx,
			"fire_mask":      fire_mask,
			"flood_mask":     flood_mask,
			"consumable_mask": cons_mask,
			"guns":           guns,
		}
	return snap


## Parse a single event payload after the preamble has been consumed.
## Returns a Dictionary with {timestamp, type, ...payload}.
func _parse_event(reader: StreamPeerBuffer, timestamp: float, event_type: int) -> Dictionary:
	var d: Dictionary = {"timestamp": timestamp, "type": event_type}

	match event_type:
		EVT_MATCH_START:
			pass   # no payload

		EVT_MATCH_END:
			var winning: int    = reader.get_u8()
			var duration_s: int = reader.get_u16()
			d["winning_team"]     = winning
			d["duration_seconds"] = duration_s
			var per_ship: Array = []
			for _i in _ship_count:
				var ship_id: int         = reader.get_u8()
				var total_dmg: float     = reader.get_float()
				var main_dmg: float      = reader.get_float()
				var torp_dmg: float      = reader.get_float()
				var fire_dmg: float      = reader.get_float()
				var flood_dmg: float     = reader.get_float()
				var frags: int           = reader.get_u32()
				var main_hits: int       = reader.get_u32()
				var citadel_count: int   = reader.get_u32()
				var pen_count: int       = reader.get_u32()
				var overpen_count: int   = reader.get_u32()
				per_ship.append({
					"ship_id":           ship_id,
					"total_damage":      total_dmg,
					"main_damage":       main_dmg,
					"torpedo_damage":    torp_dmg,
					"fire_damage":       fire_dmg,
					"flood_damage":      flood_dmg,
					"frags":             frags,
					"main_hits":         main_hits,
					"citadel_count":     citadel_count,
					"penetration_count": pen_count,
					"overpen_count":     overpen_count,
				})
			d["ship_stats"] = per_ship

		EVT_SNAPSHOT:
			d["ships"] = _parse_snapshot(reader)

		EVT_SHELL_FIRED:
			d["ship_id"]      = reader.get_u8()
			d["gun_index"]    = reader.get_u8()
			d["muzzle_index"] = reader.get_u8()
			d["shell_type"]   = reader.get_u8()
			d["muzzle_pos"]   = Vector3(reader.get_float(), reader.get_float(), reader.get_float())
			d["velocity"]     = Vector3(reader.get_float(), reader.get_float(), reader.get_float())
			# fire_timestamp removed from payload — use d["timestamp"] (preamble) instead.
			d["drag"]         = reader.get_float()
			d["size"]         = reader.get_float()
			d["caliber"]      = reader.get_float()
			d["shell_uid"]    = reader.get_32()

		EVT_SHELL_HIT:
			d["attacker_ship_id"] = reader.get_u8()
			d["victim_ship_id"]   = reader.get_u8()
			d["hit_type"]         = reader.get_u8()
			d["hit_pos"]          = Vector3(reader.get_float(), reader.get_float(), reader.get_float())
			d["shell_uid"]        = reader.get_32()

		EVT_TORPEDO_FIRED:
			d["ship_id"]         = reader.get_u8()
			d["launcher_index"]  = reader.get_u8()
			d["torpedo_id"]      = reader.get_u16()
			d["start_pos"]       = Vector3(reader.get_float(), reader.get_float(), reader.get_float())
			d["direction"]       = Vector3(reader.get_float(), reader.get_float(), reader.get_float())
			# fire_timestamp removed from payload — use d["timestamp"] (preamble) instead.
			d["speed_knts"]      = reader.get_float()
			d["damage"]          = reader.get_float()
			d["range_m"]         = reader.get_float()
			d["detection_range"] = reader.get_float()

		EVT_TORPEDO_ARMED:
			d["torpedo_id"] = reader.get_u16()

		EVT_TORPEDO_DETECTED:
			d["torpedo_id"] = reader.get_u16()

		EVT_TORPEDO_DESTROYED:
			d["torpedo_id"]  = reader.get_u16()
			d["pos"]         = Vector3(reader.get_float(), reader.get_float(), reader.get_float())
			d["hit_ship_id"] = reader.get_u8()

		EVT_FIRE_STARTED, EVT_FIRE_ENDED:
			d["ship_id"]          = reader.get_u8()
			d["zone_index"]       = reader.get_u8()
			d["caused_by_ship_id"] = reader.get_u8()

		EVT_FLOOD_STARTED, EVT_FLOOD_ENDED:
			d["ship_id"]          = reader.get_u8()
			d["zone_index"]       = reader.get_u8()
			d["caused_by_ship_id"] = reader.get_u8()

		EVT_CONSUMABLE_USED, EVT_CONSUMABLE_ENDED:
			d["ship_id"] = reader.get_u8()
			d["slot_id"] = reader.get_u8()

		EVT_DETECTION_CHANGED:
			d["ship_id"]         = reader.get_u8()
			d["detection_type"]  = reader.get_u8()
			d["visible_to_enemy"] = reader.get_u8()

		EVT_SHIP_SUNK:
			d["victim_ship_id"] = reader.get_u8()
			d["sinker_ship_id"] = reader.get_u8()
			d["damage_type"]    = reader.get_u8()
			d["pos"]            = Vector3(reader.get_float(), reader.get_float(), reader.get_float())

		_:
			# Unknown event type — we cannot safely skip because we don't know its size.
			push_warning("ReplayFileReader: unknown event type 0x%X at position %d" % [event_type, reader.get_position()])

	return d


## Binary search: returns the index of the last snapshot with timestamp <= t.
## Returns -1 if t is before the first snapshot.
func _binary_search_snapshot(t: float) -> int:
	if snapshot_index.is_empty():
		return -1
	if t < snapshot_index[0].timestamp:
		return 0   # clamp to first
	var lo := 0
	var hi := snapshot_index.size() - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) >> 1
		if snapshot_index[mid].timestamp <= t:
			lo = mid
		else:
			hi = mid - 1
	return lo


## Read and fully parse the snapshot stored at snapshot_index[idx].
func _read_snapshot_at_index(idx: int) -> Dictionary:
	if idx < 0 or idx >= snapshot_index.size():
		return {}
	var offset: int = snapshot_index[idx].offset
	_reader.seek(offset)
	var _ts: float = _reader.get_float()
	var etype: int  = _reader.get_u8()
	if etype != EVT_SNAPSHOT:
		return {}
	return _parse_snapshot(_reader)


## Scan the event stream for a MATCH_END event and cache its data.
func _scan_for_match_end() -> void:
	# Start scanning from just after the manifest (after the snapshot index offset field).
	# The simplest approach: start from just after the header block.
	# We'll walk every event linearly from the first event after the manifest.
	var start: int = _find_events_start()
	if start <= 0:
		return

	_reader.seek(start)
	var safe_limit: int = _data.size() - 5

	while _reader.get_position() < safe_limit:
		var _event_start: int = _reader.get_position()
		var ts: float   = _reader.get_float()
		var etype: int  = _reader.get_u8()

		if etype == EVT_MATCH_END:
			var evt := _parse_event(_reader, ts, etype)
			total_duration = ts
			winning_team   = evt.get("winning_team", -1)
			end_stats.clear()
			for s in evt.get("ship_stats", []):
				end_stats[s["ship_id"]] = s
			return

		# Skip this event by parsing it (we need to advance the reader past its payload)
		var before: int = _reader.get_position()
		_parse_event(_reader, ts, etype)
		# If parse didn't advance, break to prevent infinite loop
		if _reader.get_position() == before and etype != EVT_MATCH_START:
			break


## Returns the byte offset of the first event after the ship manifest.
## This is the current reader position immediately after parsing the manifest,
## but we may need to re-calculate it. We cache it as a workaround.
var _events_start_offset: int = -1

func _find_events_start() -> int:
	if _events_start_offset >= 0:
		return _events_start_offset

	# Re-read the manifest to find where events start
	# Header is at least 17 bytes; manifest starts at byte 17
	_reader.seek(0)
	_reader.get_u32()  # magic
	_reader.get_u16()  # version
	_reader.get_u32()  # match_ts
	_reader.get_u8()   # map_id
	var sc: int = _reader.get_u16()  # ship_count
	_reader.get_u32()  # index_offset

	for _i in sc:
		_reader.get_u8()   # ship_id
		_reader.get_u8()   # team_id
		_reader.get_u8()   # is_bot
		# player_name
		var plen: int = _reader.get_u8()
		if plen > 0: _reader.get_data(plen)
		# ship_name
		var snlen: int = _reader.get_u8()
		if snlen > 0: _reader.get_data(snlen)
		# scene_path
		var splen: int = _reader.get_u8()
		if splen > 0: _reader.get_data(splen)
		var gc: int = _reader.get_u8()   # gun_count
		_reader.get_u8()  # fire_count
		_reader.get_u8()  # flood_count
		var cc: int = _reader.get_u8()  # consumable_count
		for _c in cc:
			_reader.get_u8()  # slot_id
			_reader.get_u8()  # type
			var clen: int = _reader.get_u8()
			if clen > 0: _reader.get_data(clen)
		# suppress unused warning
		var _gc2 = gc

	_events_start_offset = _reader.get_position()
	return _events_start_offset
