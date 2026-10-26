class_name BotDebugCodec
## BotDebugView state (BotControllerV4.debug_state, BotDebugView.team_state) as chunks of records:
## each record is a fixed sequence of field groups, a group equal to the record before's written as one flag byte.

const CHUNK_RECORDS := 20
const SAME := 1
const NEW := 0
## Stream ids at or above this carry team_state for team (id - TEAM_STREAM); below, a ship's debug_state.
const TEAM_STREAM := 0x80

## UNIT is 0..1 with -1 for none; ANGLE may be INF; POS is whole metres, INF for none; ID is BotDebugView.NO_ID for none.
enum K { ANGLE, UNIT, S8, AGG, METERS, STR, BOOL, U8, U32, F32, F32S, POS, POSLIST, U16LIST, ID, LIST }

const BOT := [
	[["dest", K.ANGLE], ["stance", K.ANGLE], ["stance_t", K.UNIT], ["away", K.ANGLE], ["rudder", K.ANGLE],
		["threat_dir", K.ANGLE], ["threat_w", K.UNIT], ["throttle", K.S8], ["threat", K.UNIT], ["hp", K.S8],
		["torp", K.UNIT], ["tgt_d", K.METERS], ["p_d", K.METERS], ["dmg", K.U32], ["pot", K.U32], ["arc", K.F32S],
		["danger", K.POS], ["dis_axis", K.ANGLE], ["dest_pos", K.POS], ["tgt", K.ID],
		["visible", K.BOOL], ["cover", K.BOOL], ["p_dark", K.BOOL], ["dis_on", K.BOOL]],
	[["length", K.METERS], ["beam", K.METERS], ["clear", K.METERS], ["soft_clear", K.METERS], ["conceal", K.METERS],
		["nav", K.S8], ["agg", K.AGG], ["policy", K.U8], ["apt", K.STR], ["apt_name", K.STR], ["arc_ship", K.F32S]],
	[["skill", K.STR], ["tgt_cls", K.STR], ["tgt_name", K.STR], ["p_name", K.STR], ["dis_text", K.STR],
		["st_kind", K.U8], ["st_pos", K.POS]],
	[["stance_text", K.STR]],
	[["st_text", K.STR]],
	[["rings", K.LIST, [["id", K.ID], ["r", K.METERS], ["trade", K.F32], ["cls", K.U8]]],
		["prio", K.LIST, [["id", K.ID], ["pos", K.POS], ["score", K.F32]]]],
	[["path", K.POSLIST]],
	[["trails", K.LIST, [["pts", K.POSLIST], ["n", K.U16LIST]]]],
]
const TEAM := [
	[["now", K.F32]],
	[["beliefs", K.LIST, [["id", K.ID], ["src", K.U8], ["pos", K.POS], ["spread", K.METERS], ["force", K.METERS]]]],
	[["lkps", K.LIST, [["id", K.ID], ["pos", K.POS], ["seen", K.F32]]]],
]
const NO_ANGLE := -32768
const NONE_U8 := 255
const NONE_U16 := 65535


static func schema(stream: int) -> Array:
	return TEAM if stream >= TEAM_STREAM else BOT


static func _put_pos(out: StreamPeerBuffer, p: Vector2) -> void:
	if not p.is_finite():
		out.put_16(NO_ANGLE)
		out.put_16(0)
		return
	out.put_16(clampi(roundi(p.x), -32767, 32767))
	out.put_16(clampi(roundi(p.y), -32767, 32767))


static func _get_pos(src: StreamPeerBuffer) -> Vector2:
	var x: int = src.get_16()
	var y: int = src.get_16()
	return Vector2.INF if x == NO_ANGLE else Vector2(x, y)


static func _write(out: StreamPeerBuffer, kind: int, v, sub: Array) -> void:
	match kind:
		K.ANGLE: out.put_16(NO_ANGLE if not is_finite(v) else int(round(wrapf(v, -PI, PI) / PI * 32767.0)))
		K.UNIT: out.put_u8(NONE_U8 if v < 0.0 else int(round(clampf(v, 0.0, 1.0) * 254.0)))
		K.S8: out.put_8(clampi(int(v), -128, 127))
		K.AGG: out.put_8(int(round(clampf(v, -1.27, 1.27) * 100.0)))
		K.METERS: out.put_u16(NONE_U16 if v < 0.0 else mini(int(round(v)), NONE_U16 - 1))
		K.STR:
			var b: PackedByteArray = String(v).to_utf8_buffer()
			out.put_u16(mini(b.size(), 65535))
			out.put_data(b.slice(0, 65535))
		K.U8: out.put_u8(int(v) & 255)
		K.ID: out.put_u8(clampi(int(v), 0, 255))
		K.U32: out.put_u32(clampi(int(v), 0, 0xFFFFFFFF))
		K.F32: out.put_float(v)
		K.F32S:
			out.put_u8(v.size())
			for x in v: out.put_float(x)
		K.POS: _put_pos(out, v)
		K.POSLIST:
			out.put_u16(v.size())
			for p in v: _put_pos(out, p)
		K.U16LIST:
			out.put_u16(v.size())
			for x in v: out.put_u16(clampi(x, 0, 65535))
		K.LIST:
			out.put_u8(mini(v.size(), 255))
			for i in mini(v.size(), 255):
				for f in sub:
					_write(out, f[1], v[i][f[0]], [])


static func _read(src: StreamPeerBuffer, kind: int, sub: Array):
	match kind:
		K.ANGLE:
			var a: int = src.get_16()
			return INF if a == NO_ANGLE else a / 32767.0 * PI
		K.UNIT:
			var u: int = src.get_u8()
			return -1.0 if u == NONE_U8 else u / 254.0
		K.S8: return src.get_8()
		K.AGG: return src.get_8() / 100.0
		K.METERS:
			var m: int = src.get_u16()
			return -1.0 if m == NONE_U16 else float(m)
		K.STR: return src.get_data(src.get_u16())[1].get_string_from_utf8()
		K.U8, K.ID: return src.get_u8()
		K.U32: return src.get_u32()
		K.F32: return src.get_float()
		K.F32S:
			var a := PackedFloat32Array()
			for _i in src.get_u8(): a.append(src.get_float())
			return a
		K.POS: return _get_pos(src)
		K.POSLIST:
			var a := PackedVector2Array()
			for _i in src.get_u16(): a.append(_get_pos(src))
			return a
		K.U16LIST:
			var a := PackedInt32Array()
			for _i in src.get_u16(): a.append(src.get_u16())
			return a
		K.LIST:
			var a := []
			for _i in src.get_u8():
				var item := {}
				for f in sub:
					item[f[0]] = _read(src, f[1], [])
				a.append(item)
			return a
	return null


static func _encode_group(group: Array, s: Dictionary) -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	var bits := 0
	var nbits := 0
	for f in group:
		if f[1] == K.BOOL:
			bits |= int(bool(s[f[0]])) << nbits
			nbits += 1
		else:
			_write(out, f[1], s[f[0]], f[2] if f.size() > 2 else [])
	if nbits > 0:
		out.put_u8(bits)
	return out.data_array


static func _decode_group(group: Array, bytes: PackedByteArray, s: Dictionary) -> void:
	var src := StreamPeerBuffer.new()
	src.data_array = bytes
	var bools := []
	for f in group:
		if f[1] == K.BOOL:
			bools.append(f[0])
		else:
			s[f[0]] = _read(src, f[1], f[2] if f.size() > 2 else [])
	if not bools.is_empty():
		var bits: int = src.get_u8()
		for i in bools.size():
			s[bools[i]] = bits & (1 << i) != 0


## Appends one record to out; prev (group index -> bytes) is the record before it, or {} to start a chunk.
static func encode_record(out: StreamPeerBuffer, prev: Dictionary, state: Dictionary, groups: Array) -> void:
	for g in groups.size():
		var bytes := _encode_group(groups[g], state)
		if prev.has(g) and prev[g] == bytes:
			out.put_u8(SAME)
		else:
			out.put_u8(NEW)
			out.put_u32(bytes.size())
			out.put_data(bytes)
		prev[g] = bytes


static func decode_record(src: StreamPeerBuffer, prev: Dictionary, groups: Array) -> Dictionary:
	var s := {}
	for g in groups.size():
		if src.get_u8() == NEW:
			prev[g] = src.get_data(src.get_u32())[1]
		_decode_group(groups[g], prev[g], s)
	return s
