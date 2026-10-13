extends RefCounted
class_name WaveSim

# One iWave grid of sparse tiles. WaveManager runs a coarse one for ship wakes
# (long Kelvin waves) and a fine one for splashes.

const RES := 128
const TILE_BYTES := 64
const QUIET_H := 0.02
const QUIET_WINDOWS := 2
const SHIP_HOLD := 3.0
const EXPIRE_SCAN := 32

var dx: float
var tile_world: float
var pool: int
var grid: int
var origin: int
var damping: float
var hard_lifetime: float

var _index_img: Image
var index_tex: ImageTexture
var _index_dirty := false
var _cell_slot := {}
var _slot_cell: Array[Vector2i] = []
var _slot_used := PackedByteArray()
var _slot_touch := PackedFloat64Array()
var _slot_alloc := PackedFloat64Array()
var _slot_quiet := PackedInt32Array()
var _free_slots := PackedInt32Array()
var _active := PackedInt32Array()
var _active_pos := PackedInt32Array()
var _scan := 0
var _clear_queue := PackedInt32Array()
var _tiles_bytes := PackedByteArray()
var _tiles_dirty := true
var _masks := PackedInt32Array()
var _readback_t := 0.0
var _readback_pending := false

# render thread
var _rd: RenderingDevice
var _tex: Array[RID] = [RID(), RID()]
var _lod_tex: RID
var _tiles_buf: RID
var _masks_buf: RID
var _active_buf: RID
var _energy_buf: RID
var _uset: Array[RID] = [RID(), RID()]
var wraps: Array = [null, null]
var lod_wrap: Texture2DArrayRD


func _init(p_dx: float, p_pool: int, p_damping: float, p_hard_lifetime: float, play_half: float) -> void:
	dx = p_dx
	tile_world = RES * dx
	pool = p_pool
	damping = p_damping
	hard_lifetime = p_hard_lifetime
	grid = int(ceil(play_half / tile_world)) * 2 + 2
	origin = grid / 2
	_slot_cell.resize(pool)
	_slot_used.resize(pool)
	_slot_touch.resize(pool)
	_slot_alloc.resize(pool)
	_slot_quiet.resize(pool)
	_active_pos.resize(pool)
	_active_pos.fill(-1)
	for i in pool: _free_slots.append(pool - 1 - i)
	_index_img = Image.create(grid, grid, false, Image.FORMAT_RF)
	_index_img.fill(Color(-1, 0, 0))
	index_tex = ImageTexture.create_from_image(_index_img)
	_tiles_bytes.resize(pool * TILE_BYTES)
	for slot in pool: _write_tile(slot)
	_masks.resize(pool * 4)


func _alloc(cell: Vector2i, time: float) -> int:
	var existing: int = _cell_slot.get(cell, -1)
	if existing >= 0: return existing
	var ix := cell.x + origin
	var iy := cell.y + origin
	if ix < 0 or ix >= grid or iy < 0 or iy >= grid: return -1
	if _free_slots.is_empty(): _evict_oldest()
	if _free_slots.is_empty(): return -1
	var slot: int = _free_slots[_free_slots.size() - 1]
	_free_slots.resize(_free_slots.size() - 1)
	_cell_slot[cell] = slot
	_slot_cell[slot] = cell
	_slot_used[slot] = 1
	_slot_alloc[slot] = time
	_slot_touch[slot] = time
	_slot_quiet[slot] = 0
	_active_pos[slot] = _active.size()
	_active.append(slot)
	_clear_queue.append(slot)
	_index_img.set_pixel(ix, iy, Color(float(slot), 0, 0))
	_index_dirty = true
	_write_tile_and_neighbours(cell, slot)
	return slot

func _free(slot: int) -> void:
	var cell := _slot_cell[slot]
	_cell_slot.erase(cell)
	_slot_used[slot] = 0
	var i := _active_pos[slot]
	var last := _active[_active.size() - 1]
	_active[i] = last
	_active_pos[last] = i
	_active.resize(_active.size() - 1)
	_active_pos[slot] = -1
	_free_slots.append(slot)
	_index_img.set_pixel(cell.x + origin, cell.y + origin, Color(-1, 0, 0))
	_index_dirty = true
	_write_tile_and_neighbours(cell, slot)

func _evict_oldest() -> void:
	var oldest := -1
	var oldest_time := INF
	for slot in _active:
		if _slot_touch[slot] < oldest_time:
			oldest_time = _slot_touch[slot]
			oldest = slot
	if oldest >= 0:
		_free(oldest)

func _write_tile_and_neighbours(cell: Vector2i, slot: int) -> void:
	_write_tile(slot)
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oy == 0: continue
			var n: int = _cell_slot.get(cell + Vector2i(ox, oy), -1)
			if n >= 0: _write_tile(n)
	_tiles_dirty = true

func _write_tile(slot: int) -> void:
	var b := slot * TILE_BYTES
	if _slot_used[slot] == 0:
		_tiles_bytes.encode_float(b + 8, 0.0)
		for k in 9: _tiles_bytes.encode_s32(b + 16 + k * 4, -1)
		return
	var cell := _slot_cell[slot]
	_tiles_bytes.encode_float(b + 0, cell.x * tile_world)
	_tiles_bytes.encode_float(b + 4, cell.y * tile_world)
	_tiles_bytes.encode_float(b + 8, 1.0)
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			_tiles_bytes.encode_s32(b + 16 + ((oy + 1) * 3 + ox + 1) * 4, _cell_slot.get(cell + Vector2i(ox, oy), -1))


func begin_frame() -> void:
	_masks.fill(0)

# Allocates and touches every cell the swept circle reaches; ship >= 0 also sets its mask bit.
func touch_rect(a: Vector2, b: Vector2, r: float, time: float, ship := -1) -> void:
	var c0 := Vector2i(floori((minf(a.x, b.x) - r) / tile_world), floori((minf(a.y, b.y) - r) / tile_world))
	var c1 := Vector2i(floori((maxf(a.x, b.x) + r) / tile_world), floori((maxf(a.y, b.y) + r) / tile_world))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var slot := _alloc(Vector2i(cx, cy), time)
			if slot < 0: continue
			_slot_touch[slot] = time
			if ship >= 0:
				_masks[slot * 4] |= 1 << ship

func mask_impulse(p: Vector2, r: float, bit: int) -> void:
	var c0 := Vector2i(floori((p.x - r) / tile_world), floori((p.y - r) / tile_world))
	var c1 := Vector2i(floori((p.x + r) / tile_world), floori((p.y + r) / tile_world))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var slot: int = _cell_slot.get(Vector2i(cx, cy), -1)
			if slot >= 0:
				_masks[slot * 4 + 1 + bit / 32] |= 1 << (bit % 32)

func expire(time: float) -> void:
	for k in EXPIRE_SCAN:
		var slot := _scan
		_scan = (_scan + 1) % pool
		if _slot_used[slot] == 0: continue
		var idle := time - _slot_touch[slot]
		if idle > SHIP_HOLD and (_slot_quiet[slot] >= QUIET_WINDOWS or idle > hard_lifetime):
			_free(slot)

func _on_energy(data: PackedByteArray, window_start: float) -> void:
	_readback_pending = false
	if data.size() < pool * 4: return
	for slot in _active:
		if _slot_alloc[slot] > window_start: continue
		if data.decode_float(slot * 4) < QUIET_H: _slot_quiet[slot] += 1
		else: _slot_quiet[slot] = 0

# Main-thread snapshot handed to dispatch() on the render thread.
func take_frame(time: float, readback_interval: float) -> Dictionary:
	if _index_dirty:
		index_tex.update(_index_img)
		_index_dirty = false
	var tiles := PackedByteArray()
	if _tiles_dirty:
		tiles = _tiles_bytes.duplicate()
		_tiles_dirty = false
	var request := time - _readback_t > readback_interval and not _readback_pending
	var window_start := _readback_t
	if request:
		_readback_pending = true
		_readback_t = time
	var f := {tiles = tiles, clears = _clear_queue.duplicate(), masks = _masks.to_byte_array(),
		active = _active.duplicate(), request = request, window_start = window_start}
	_clear_queue.clear()
	return f


# ---------------------------------------------------------------- render thread

func init_rd(rd: RenderingDevice, shader: RID, ships_buf: RID, impulses_buf: RID, wake_index_buf: RID, wake_tex: RID) -> void:
	_rd = rd
	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	for i in 2:
		_tex[i] = array_tex(rd, RES, pool, RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, usage)
	_lod_tex = array_tex(rd, RES / 4, pool, RenderingDevice.DATA_FORMAT_R16_SFLOAT, usage)
	_tiles_buf = rd.storage_buffer_create(pool * TILE_BYTES, _tiles_bytes)
	_masks_buf = rd.storage_buffer_create(pool * 16)
	_active_buf = rd.storage_buffer_create(pool * 4)
	_energy_buf = rd.storage_buffer_create(pool * 4)
	var IM := RenderingDevice.UNIFORM_TYPE_IMAGE
	var SB := RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	for p in 2:
		_uset[p] = rd.uniform_set_create([
			uni(IM, 0, _tex[p]), uni(IM, 1, _tex[1 - p]),
			uni(SB, 2, _tiles_buf), uni(SB, 3, ships_buf), uni(SB, 4, impulses_buf),
			uni(SB, 5, _masks_buf), uni(SB, 6, _active_buf), uni(SB, 7, _energy_buf),
			uni(IM, 8, _lod_tex), uni(SB, 9, wake_index_buf), uni(IM, 10, wake_tex),
		], shader, 0)
	for i in 2:
		var w := Texture2DArrayRD.new(); w.texture_rd_rid = _tex[i]; wraps[i] = w
	lod_wrap = Texture2DArrayRD.new(); lod_wrap.texture_rd_rid = _lod_tex

func upload(f: Dictionary) -> void:
	for slot in f.clears:
		_rd.texture_clear(_tex[0], Color(0, 0, 0, 0), 0, 1, slot, 1)
		_rd.texture_clear(_tex[1], Color(0, 0, 0, 0), 0, 1, slot, 1)
		_rd.texture_clear(_lod_tex, Color(0, 0, 0, 0), 0, 1, slot, 1)
	if not f.tiles.is_empty():
		_rd.buffer_update(_tiles_buf, 0, f.tiles.size(), f.tiles)
	if f.request:
		var ws: float = f.window_start
		_rd.buffer_get_data_async(_energy_buf, func(data: PackedByteArray): _on_energy.call_deferred(data, ws))
		_rd.buffer_clear(_energy_buf, 0, pool * 4)
	_rd.buffer_update(_masks_buf, 0, f.masks.size(), f.masks)
	if not f.active.is_empty():
		var bytes: PackedByteArray = f.active.to_byte_array()
		_rd.buffer_update(_active_buf, 0, bytes.size(), bytes)

# pc: shared push constants; this fills the per-sim fields.
func dispatch(cl: int, pipeline: RID, pc: PackedByteArray, f: Dictionary, parity: int, substeps: int,
		sim_dt: float, gravity: float, apply_impulses: bool) -> void:
	if f.active.is_empty(): return
	var a := 1.0 + damping * sim_dt
	pc.encode_float(4, dx)
	pc.encode_float(8, (2.0 - damping * sim_dt) / a)
	pc.encode_float(12, 1.0 / a)
	pc.encode_float(16, gravity * sim_dt * sim_dt / dx / a)
	pc.encode_float(32, tile_world)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	for i in substeps:
		pc.encode_float(20, float(i) / float(substeps))
		pc.encode_float(24, float(i + 1) / float(substeps))
		pc.encode_s32(28, 1 if i == 0 and apply_impulses else 0)
		_rd.compute_list_bind_uniform_set(cl, _uset[(parity + i) % 2], 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, RES / 16, RES / 16, f.active.size())
		_rd.compute_list_add_barrier(cl)


static func array_tex(rd: RenderingDevice, size: int, layers: int, format: RenderingDevice.DataFormat, usage: int) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = size; fmt.height = size; fmt.array_layers = layers
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.format = format
	fmt.usage_bits = usage
	var t := rd.texture_create(fmt, RDTextureView.new(), [])
	rd.texture_clear(t, Color(0, 0, 0, 0), 0, 1, 0, layers)
	return t

static func uni(type: RenderingDevice.UniformType, binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	u.add_id(rid)
	return u
