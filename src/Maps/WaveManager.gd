extends Node
class_name _WaveManager

const FOAM_TEX := "res://src/Maps/ocean_foam.png"
const TILE_RES := 128
const TILE_WORLD := 500.0
const POOL := 256
const GRID := 64
const GRID_ORIGIN := 32
const TILE_LIFETIME := 40.0
const TILE_MARGIN := 250.0     # water kept simulated beyond the hull so the wake has room to spread
const EXPIRE_SCAN := 16        # slots checked for expiry per frame
const HULL_STRENGTH := 7
const FOAM_DIFFUSE := 0.03

const MAX_SHIPS := 32          # ship mask is one uint
const MAX_IMPULSES := 64       # impulse mask is two uints

# The sim is an explicit finite-difference scheme, stable only below a CFL
# limit, so it runs at a fixed rate with per-step constants.
const SIM_HZ := 60.0
const SIM_DT := 1.0 / SIM_HZ
const MAX_SUBSTEPS := 4

const TILE_BYTES := 32
const SHIP_BYTES := 48
const IMPULSE_BYTES := 32

@export var ocean_material: ShaderMaterial
const SHADER_FILE := preload("res://src/Maps/wave.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex: Array[RID] = [RID(), RID()]
var _uset: Array[RID] = [RID(), RID()]
var _tiles_buf: RID
var _ships_buf: RID
var _impulses_buf: RID
var _masks_buf: RID
var _active_buf: RID
var _wrap: Array = [null, null]
var _initialized := false
var _parity := 0
var _time := 0.0
var _sim_accum := 0.0

var _index_img: Image
var _index_tex: ImageTexture
var _index_dirty := false

var _cell_slot := {}                       # Vector2i -> slot
var _slot_cell: Array[Vector2i] = []
var _slot_used := PackedByteArray()
var _slot_touch := PackedFloat64Array()
var _free_slots := PackedInt32Array()
var _active := PackedInt32Array()          # dense list of used slots, dispatched as z
var _active_pos := PackedInt32Array()      # slot -> index in _active, -1 when free
var _scan := 0
var _clear_queue := PackedInt32Array()
var _tiles_bytes := PackedByteArray()
var _tiles_dirty := true
var _masks := PackedInt32Array()           # per slot: ship mask, impulse mask lo, hi, pad

var _ships: Array[Node3D] = []
var _prev_pos: Dictionary = {}
var _prev_fwd: Dictionary = {}
var _ship_hulls: Dictionary = {}           # Node3D -> Vector3(half_length, half_beam, draft)
var _ship_f := PackedFloat32Array()
var _impulses: Array = []
var _impulse_f := PackedFloat32Array()
var _tiles_on := false


func register_ship(s: Node3D, half_length: float, half_beam: float, draft: float) -> void:
	if s not in _ships: _ships.append(s)
	_ship_hulls[s] = Vector3(half_length, half_beam, draft)

func unregister_ship(s: Node3D) -> void:
	_ships.erase(s)
	_prev_pos.erase(s)
	_prev_fwd.erase(s)
	_ship_hulls.erase(s)

func add_shell_splash(pos: Vector3, radius: float) -> void:
	_add_impulse(pos, pow(radius, 1.2), radius * 0.06, 0.4, 2)

func add_muzzle_blast(pos: Vector3, radius: float) -> void:
	_add_impulse(pos, radius * 5, -0.02, 0.5, 1)

func _add_impulse(pos: Vector3, radius: float, strength: float, foam: float, frames: int) -> void:
	if _impulses.size() >= MAX_IMPULSES:
		return
	var p := Vector2(pos.x, pos.z)
	_touch_rect(p, p, minf(radius * 2.5, TILE_WORLD * 0.5), 0, false)
	_impulses.append({p = p, r = radius, s = strength, f = foam, n = frames})


func _ready() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		queue_free(); return

	_slot_cell.resize(POOL)
	_slot_used.resize(POOL)
	_slot_touch.resize(POOL)
	_active_pos.resize(POOL)
	_active_pos.fill(-1)
	for i in POOL:
		_free_slots.append(POOL - 1 - i)
	_index_img = Image.create(GRID, GRID, false, Image.FORMAT_RF)
	_index_img.fill(Color(-1, 0, 0))
	_index_tex = ImageTexture.create_from_image(_index_img)
	_tiles_bytes.resize(POOL * TILE_BYTES)
	for slot in POOL:
		_write_tile(slot)
	_masks.resize(POOL * 4)
	_ship_f.resize(MAX_SHIPS * SHIP_BYTES / 4)
	_impulse_f.resize(MAX_IMPULSES * IMPULSE_BYTES / 4)
	if ocean_material:
		# Loaded here rather than as an ext_resource so the headless server never pays for it.
		ocean_material.set_shader_parameter("foam_tex", load(FOAM_TEX))
		ocean_material.set_shader_parameter("index_tex", _index_tex)
		ocean_material.set_shader_parameter("tile_world", TILE_WORLD)
		ocean_material.set_shader_parameter("grid_origin", GRID_ORIGIN)
		ocean_material.set_shader_parameter("tiles_on", false)
		ocean_material.render_priority = -1

	get_child(0).ocean_material = ocean_material
	RenderingServer.call_on_render_thread(_init_rd)

func get_ocean_material() -> ShaderMaterial:
	return ocean_material


func _alloc(cell: Vector2i) -> int:
	var existing: int = _cell_slot.get(cell, -1)
	if existing >= 0: return existing
	var ix := cell.x + GRID_ORIGIN
	var iy := cell.y + GRID_ORIGIN
	if ix < 0 or ix >= GRID or iy < 0 or iy >= GRID: return -1
	if _free_slots.is_empty(): _evict_oldest()
	var slot: int = _free_slots[_free_slots.size() - 1]
	_free_slots.resize(_free_slots.size() - 1)
	_cell_slot[cell] = slot
	_slot_cell[slot] = cell
	_slot_used[slot] = 1
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
	_index_img.set_pixel(cell.x + GRID_ORIGIN, cell.y + GRID_ORIGIN, Color(-1, 0, 0))
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
	for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
		var n: int = _cell_slot.get(cell + d, -1)
		if n >= 0: _write_tile(n)
	_tiles_dirty = true

func _write_tile(slot: int) -> void:
	var b := slot * TILE_BYTES
	if _slot_used[slot] == 0:
		_tiles_bytes.encode_float(b + 8, 0.0)
		for k in 4: _tiles_bytes.encode_s32(b + 16 + k * 4, -1)
		return
	var cell := _slot_cell[slot]
	_tiles_bytes.encode_float(b + 0, cell.x * TILE_WORLD)
	_tiles_bytes.encode_float(b + 4, cell.y * TILE_WORLD)
	_tiles_bytes.encode_float(b + 8, 1.0)
	_tiles_bytes.encode_s32(b + 16, _cell_slot.get(cell + Vector2i(-1, 0), -1))
	_tiles_bytes.encode_s32(b + 20, _cell_slot.get(cell + Vector2i(1, 0), -1))
	_tiles_bytes.encode_s32(b + 24, _cell_slot.get(cell + Vector2i(0, -1), -1))
	_tiles_bytes.encode_s32(b + 28, _cell_slot.get(cell + Vector2i(0, 1), -1))


# Allocates and touches every cell the swept circle reaches; mask_word 0 = ships, 1/2 = impulses.
func _touch_rect(a: Vector2, b: Vector2, r: float, mask_word: int, mask: bool, bit := 0) -> void:
	var c0 := Vector2i(floori((minf(a.x, b.x) - r) / TILE_WORLD), floori((minf(a.y, b.y) - r) / TILE_WORLD))
	var c1 := Vector2i(floori((maxf(a.x, b.x) + r) / TILE_WORLD), floori((maxf(a.y, b.y) + r) / TILE_WORLD))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var slot := _alloc(Vector2i(cx, cy))
			if slot < 0: continue
			_slot_touch[slot] = _time
			if mask:
				_masks[slot * 4 + mask_word] |= 1 << bit

# Mask-only variant for impulses whose cells were allocated when they were added.
func _mask_rect(p: Vector2, r: float, mask_word: int, bit: int) -> void:
	var c0 := Vector2i(floori((p.x - r) / TILE_WORLD), floori((p.y - r) / TILE_WORLD))
	var c1 := Vector2i(floori((p.x + r) / TILE_WORLD), floori((p.y + r) / TILE_WORLD))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var slot: int = _cell_slot.get(Vector2i(cx, cy), -1)
			if slot >= 0:
				_masks[slot * 4 + mask_word] |= 1 << bit


func _process(delta: float) -> void:
	_time += delta
	_sim_accum += delta
	var substeps := int(_sim_accum / SIM_DT)
	if substeps > MAX_SUBSTEPS:
		substeps = MAX_SUBSTEPS
		_sim_accum = 0.0
	else:
		_sim_accum -= substeps * SIM_DT
	if substeps == 0:
		return

	_masks.fill(0)
	var ship_count := 0
	for s in _ships:
		if ship_count >= MAX_SHIPS or not is_instance_valid(s) or not s.is_inside_tree(): continue
		var xf := s.global_transform
		var pos := xf.origin
		var prev: Vector3 = _prev_pos.get(s, pos)
		_prev_pos[s] = pos
		var fwd := Vector2(-xf.basis.z.x, -xf.basis.z.z)
		var prev_fwd: Vector2 = _prev_fwd.get(s, fwd)
		_prev_fwd[s] = fwd
		var hull: Vector3 = _ship_hulls[s]
		_touch_rect(Vector2(prev.x, prev.z), Vector2(pos.x, pos.z), hull.x + TILE_MARGIN, 0, true, ship_count)
		var f := ship_count * 12
		_ship_f[f] = pos.x;           _ship_f[f + 1] = pos.z
		_ship_f[f + 2] = prev.x;      _ship_f[f + 3] = prev.z
		_ship_f[f + 4] = fwd.x;       _ship_f[f + 5] = fwd.y
		_ship_f[f + 6] = hull.x;      _ship_f[f + 7] = hull.y
		_ship_f[f + 8] = HULL_STRENGTH
		_ship_f[f + 9] = prev_fwd.x;  _ship_f[f + 10] = prev_fwd.y
		ship_count += 1

	var impulse_count := 0
	var kept: Array = []
	for imp in _impulses:
		var f := impulse_count * 8
		_impulse_f[f] = imp.p.x;  _impulse_f[f + 1] = imp.p.y
		_impulse_f[f + 2] = imp.r; _impulse_f[f + 3] = imp.s
		_impulse_f[f + 4] = imp.f
		_mask_rect(imp.p, imp.r * 2.5, 1 + impulse_count / 32, impulse_count % 32)
		impulse_count += 1
		imp.n -= substeps
		if imp.n > 0: kept.append(imp)
	_impulses = kept

	for k in EXPIRE_SCAN:
		var slot := _scan
		_scan = (_scan + 1) % POOL
		if _slot_used[slot] == 1 and _time - _slot_touch[slot] > TILE_LIFETIME:
			_free(slot)

	if _index_dirty:
		_index_tex.update(_index_img)
		_index_dirty = false
	var tiles := PackedByteArray()
	if _tiles_dirty:
		tiles = _tiles_bytes.duplicate()
		_tiles_dirty = false

	var new_parity := (_parity + substeps) % 2
	if _initialized and ocean_material:
		if new_parity != _parity or not _tiles_on:
			ocean_material.set_shader_parameter("wave_array", _wrap[new_parity])
		if not _tiles_on:
			ocean_material.set_shader_parameter("tiles_on", true)
			_tiles_on = true
	RenderingServer.call_on_render_thread(_render_update.bind(
		_parity, tiles, _ship_f.to_byte_array(), ship_count, _clear_queue.duplicate(),
		_impulse_f.to_byte_array(), impulse_count, _masks.to_byte_array(), _active.duplicate(), substeps))
	_clear_queue.clear()
	_parity = new_parity


func _init_rd() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		queue_free(); return
	_shader = _rd.shader_create_from_spirv(SHADER_FILE.get_spirv())
	_pipeline = _rd.compute_pipeline_create(_shader)
	var fmt := RDTextureFormat.new()
	fmt.width = TILE_RES; fmt.height = TILE_RES; fmt.array_layers = POOL
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	for i in 2:
		_tex[i] = _rd.texture_create(fmt, RDTextureView.new(), [])
		_rd.texture_clear(_tex[i], Color(0, 0, 0, 0), 0, 1, 0, POOL)
	_tiles_buf = _rd.storage_buffer_create(POOL * TILE_BYTES, _tiles_bytes)
	_ships_buf = _rd.storage_buffer_create(MAX_SHIPS * SHIP_BYTES)
	_impulses_buf = _rd.storage_buffer_create(MAX_IMPULSES * IMPULSE_BYTES)
	_masks_buf = _rd.storage_buffer_create(POOL * 16)
	_active_buf = _rd.storage_buffer_create(POOL * 4)
	for p in 2:
		_uset[p] = _rd.uniform_set_create([
			_uni(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, _tex[p]),
			_uni(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, _tex[1 - p]),
			_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, _tiles_buf),
			_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 3, _ships_buf),
			_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, _impulses_buf),
			_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, _masks_buf),
			_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, _active_buf),
		], _shader, 0)
	for i in 2:
		var w := Texture2DArrayRD.new(); w.texture_rd_rid = _tex[i]; _wrap[i] = w
	_initialized = true

func _uni(type: RenderingDevice.UniformType, binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	u.add_id(rid)
	return u

func _render_update(parity: int, tiles: PackedByteArray, ships: PackedByteArray, ship_count: int,
		clears: PackedInt32Array, impulses: PackedByteArray, impulse_count: int,
		masks: PackedByteArray, active: PackedInt32Array, substeps: int) -> void:
	if not _initialized: _init_rd()
	for slot in clears:
		_rd.texture_clear(_tex[0], Color(0, 0, 0, 0), 0, 1, slot, 1)
		_rd.texture_clear(_tex[1], Color(0, 0, 0, 0), 0, 1, slot, 1)
	if not tiles.is_empty():
		_rd.buffer_update(_tiles_buf, 0, tiles.size(), tiles)
	if active.is_empty():
		return
	_rd.buffer_update(_ships_buf, 0, ships.size(), ships)
	_rd.buffer_update(_impulses_buf, 0, impulses.size(), impulses)
	_rd.buffer_update(_masks_buf, 0, masks.size(), masks)
	var active_bytes := active.to_byte_array()
	_rd.buffer_update(_active_buf, 0, active_bytes.size(), active_bytes)
	var pc := PackedByteArray(); pc.resize(48)
	pc.encode_s32(0, TILE_RES)
	pc.encode_float(4, 0.001)    # c2
	pc.encode_float(8, 0.999)    # damp
	pc.encode_float(12, 0.9995)  # foam_decay
	pc.encode_s32(16, ship_count)
	pc.encode_float(20, TILE_WORLD)
	pc.encode_float(24, FOAM_DIFFUSE)
	pc.encode_s32(28, impulse_count)
	var g := (TILE_RES + 7) / 8
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	for i in substeps:
		pc.encode_float(32, float(i) / float(substeps))
		pc.encode_float(36, float(i + 1) / float(substeps))
		_rd.compute_list_bind_uniform_set(cl, _uset[(parity + i) % 2], 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g, g, active.size())
		if i + 1 < substeps:
			_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
