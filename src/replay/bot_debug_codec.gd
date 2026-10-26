class_name BotDebugCodec
## Debug draw buffers (Dictionary[_Debug.DrawType, PackedByteArray]) as chunks of records:
## each record repeats unchanged commands of the record before it as a single flag byte.

const CHUNK_RECORDS := 20
const MANTISSA_BITS := 13
const SAME := 1
const NEW := 0

const STRIDE := {
	_Debug.DrawType.ARROW: _Debug.STRIDE_ARROW,
	_Debug.DrawType.SPHERE: _Debug.STRIDE_SPHERE,
	_Debug.DrawType.CIRCLE: _Debug.STRIDE_CIRCLE,
	_Debug.DrawType.LINE: _Debug.STRIDE_LINE,
	_Debug.DrawType.SQUARE: _Debug.STRIDE_SQUARE,
	_Debug.DrawType.CONE: _Debug.STRIDE_CONE,
	_Debug.DrawType.ARC: _Debug.STRIDE_ARC,
	_Debug.DrawType.SDF_TILES: _Debug.STRIDE_SDF,
}
enum K { ANGLE, UNIT, S8, AGG, METERS, STR, BOOL, U8, U32, F32S }
## BotControllerV4.debug_state() fields. UNIT is 0..1 with -1 for none; ANGLE may be INF.
const STATE := [
	["dest", K.ANGLE], ["stance", K.ANGLE], ["stance_t", K.UNIT], ["away", K.ANGLE],
	["rudder", K.ANGLE], ["threat_dir", K.ANGLE], ["threat_w", K.UNIT], ["throttle", K.S8],
	["length", K.METERS], ["beam", K.METERS], ["clear", K.METERS], ["soft_clear", K.METERS],
	["nav", K.S8], ["agg", K.AGG], ["apt", K.STR], ["apt_name", K.STR],
	["skill", K.STR], ["threat", K.UNIT], ["visible", K.BOOL], ["cover", K.BOOL],
	["hp", K.S8], ["torp", K.UNIT], ["tgt_cls", K.STR], ["tgt_name", K.STR], ["tgt_d", K.METERS],
	["p_d", K.METERS], ["p_name", K.STR], ["p_dark", K.BOOL], ["policy", K.U8],
	["dmg", K.U32], ["pot", K.U32], ["arc", K.F32S],
]
const NO_ANGLE := -32768
const NONE_U8 := 255
const NONE_U16 := 65535

const PATH_HEADER := 28
const LABEL_HEADER := 40


static func _cmd_size(t: int, buf: PackedByteArray, at: int) -> int:
	if STRIDE.has(t):
		return STRIDE[t]
	if t == _Debug.DrawType.PATH:
		return PATH_HEADER + int(buf.decode_float(at + 24)) * 12
	var n: int = buf.decode_s32(at + 36)
	return LABEL_HEADER + n + (4 - n % 4) % 4


## Bytes of a command that are floats; label text length and text stay exact.
static func _float_bytes(t: int, size: int) -> int:
	return 36 if t == _Debug.DrawType.LABEL else size


static func _split(t: int, buf: PackedByteArray) -> Array:
	var out := []
	var mask: int = ~((1 << (23 - MANTISSA_BITS)) - 1)
	var at := 0
	while at < buf.size():
		var n := _cmd_size(t, buf, at)
		var cmd := buf.slice(at, at + n)
		for i in range(0, _float_bytes(t, n), 4):
			cmd.encode_s32(i, cmd.decode_s32(i) & mask)
		out.append(cmd)
		at += n
	return out


static func encode_state(s: Dictionary) -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	var bits := 0
	var nbits := 0
	for f in STATE:
		var v = s[f[0]]
		match f[1]:
			K.ANGLE: out.put_16(NO_ANGLE if not is_finite(v) else int(round(wrapf(v, -PI, PI) / PI * 32767.0)))
			K.UNIT: out.put_u8(NONE_U8 if v < 0.0 else int(round(clampf(v, 0.0, 1.0) * 254.0)))
			K.S8: out.put_8(clampi(int(v), -128, 127))
			K.AGG: out.put_8(int(round(clampf(v, -1.27, 1.27) * 100.0)))
			K.METERS: out.put_u16(NONE_U16 if v < 0.0 else mini(int(round(v)), NONE_U16 - 1))
			K.STR:
				var b: PackedByteArray = String(v).to_utf8_buffer()
				out.put_u8(mini(b.size(), 255))
				out.put_data(b.slice(0, 255))
			K.BOOL:
				bits |= int(bool(v)) << nbits
				nbits += 1
			K.U8: out.put_u8(int(v) & 255)
			K.U32: out.put_u32(clampi(int(v), 0, 0xFFFFFFFF))
			K.F32S:
				out.put_u8(v.size())
				for x in v: out.put_float(x)
	out.put_u8(bits)
	return out.data_array


static func decode_state(src: StreamPeerBuffer) -> Dictionary:
	var s := {}
	var bools := []
	for f in STATE:
		match f[1]:
			K.ANGLE:
				var a: int = src.get_16()
				s[f[0]] = INF if a == NO_ANGLE else a / 32767.0 * PI
			K.UNIT:
				var u: int = src.get_u8()
				s[f[0]] = -1.0 if u == NONE_U8 else u / 254.0
			K.S8: s[f[0]] = src.get_8()
			K.AGG: s[f[0]] = src.get_8() / 100.0
			K.METERS:
				var m: int = src.get_u16()
				s[f[0]] = -1.0 if m == NONE_U16 else float(m)
			K.STR: s[f[0]] = src.get_data(src.get_u8())[1].get_string_from_utf8()
			K.BOOL: bools.append(f[0])
			K.U8: s[f[0]] = src.get_u8()
			K.U32: s[f[0]] = src.get_u32()
			K.F32S:
				var a := PackedFloat32Array()
				for _i in src.get_u8(): a.append(src.get_float())
				s[f[0]] = a
	var bits: int = src.get_u8()
	for i in bools.size():
		s[bools[i]] = bits & (1 << i) != 0
	return s


## Appends one record to out; prev (type -> Array of commands) is the record before it, or {} to start a chunk.
static func encode_record(out: StreamPeerBuffer, prev: Dictionary, payload: Dictionary, state: Dictionary = {}) -> void:
	var st := encode_state(state) if not state.is_empty() else PackedByteArray()
	if st.is_empty():
		out.put_u8(NEW)
		out.put_u16(0)
	elif st == prev.get(&"state", PackedByteArray()):
		out.put_u8(SAME)
	else:
		out.put_u8(NEW)
		out.put_u16(st.size())
		out.put_data(st)
	prev[&"state"] = st
	out.put_u8(payload.size())
	for t in payload:
		var cmds := _split(t, payload[t])
		var old: Array = prev.get(t, [])
		out.put_u8(t)
		out.put_u16(cmds.size())
		for i in cmds.size():
			if i < old.size() and old[i] == cmds[i]:
				out.put_u8(SAME)
			else:
				out.put_u8(NEW)
				out.put_data(cmds[i])
		prev[t] = cmds
	for t in prev.keys():
		if t is int and not payload.has(t):
			prev.erase(t)


## [payload, state]
static func decode_record(src: StreamPeerBuffer, prev: Dictionary) -> Array:
	var st: PackedByteArray = prev.get(&"state", PackedByteArray())
	if src.get_u8() == NEW:
		st = src.get_data(src.get_u16())[1]
	prev[&"state"] = st
	var state := {}
	if not st.is_empty():
		var sb := StreamPeerBuffer.new()
		sb.data_array = st
		state = decode_state(sb)
	var payload := {}
	var seen := {}
	for _k in src.get_u8():
		var t: int = src.get_u8()
		var old: Array = prev.get(t, [])
		var cmds := []
		var buf := PackedByteArray()
		for i in src.get_u16():
			var cmd: PackedByteArray
			if src.get_u8() == SAME:
				cmd = old[i]
			else:
				var at: int = src.get_position()
				var head: int = PATH_HEADER if t == _Debug.DrawType.PATH else LABEL_HEADER if t == _Debug.DrawType.LABEL else STRIDE[t]
				var n := _cmd_size(t, src.data_array.slice(at, at + head), 0)
				cmd = src.get_data(n)[1]
			cmds.append(cmd)
			buf.append_array(cmd)
		prev[t] = cmds
		payload[t] = buf
		seen[t] = true
	for t in prev.keys():
		if t is int and not seen.has(t):
			prev.erase(t)
	return [payload, state]
