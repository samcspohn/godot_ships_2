extends Node
class_name _WaveManager

const TILE_RES := 256
const TILE_WORLD := 1000.0
const POOL := 64
const GRID := 64
const GRID_ORIGIN := 32
const TILE_LIFETIME := 30.0
const STAMP_RADIUS := 0.02
const STAMP_STRENGTH := 0.5

@export var ocean_material: ShaderMaterial
const SHADER_FILE := preload("res://src/Maps/wave.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex: Array[RID] = [RID(), RID()]
var _uset: Array[RID] = [RID(), RID()]
var _buf: RID
var _wrap: Array = [null, null]
var _initialized := false
var _parity := 0
var _time := 0.0

var _index_img: Image
var _index_tex: ImageTexture

var _cell_slot := {}
var _slot_cell: Array = []
var _slot_active: Array = []
var _free_slots: Array = []
var _clear_queue: Array = []

var _ships: Array[Node3D] = []
var _tiles_bytes := PackedByteArray()

func register_ship(s: Node3D) -> void:
	if s not in _ships: _ships.append(s)

func unregister_ship(s: Node3D) -> void:
	_ships.erase(s)

func _ready() -> void:

	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		queue_free(); return

	_slot_cell.resize(POOL); _slot_active.resize(POOL)
	for i in POOL:
		_slot_cell[i] = null; _slot_active[i] = -1000.0; _free_slots.append(i)
	_index_img = Image.create(GRID, GRID, false, Image.FORMAT_RF)
	_index_img.fill(Color(-1, 0, 0))
	_index_tex = ImageTexture.create_from_image(_index_img)
	_tiles_bytes.resize(POOL * 32)
	if ocean_material:
		ocean_material.set_shader_parameter("index_tex", _index_tex)
		ocean_material.set_shader_parameter("tile_world", TILE_WORLD)
		ocean_material.set_shader_parameter("grid_origin", GRID_ORIGIN)
		ocean_material.set_shader_parameter("tiles_on", false)
		ocean_material.render_priority = -1

func get_ocean_material() -> ShaderMaterial:
	return ocean_material

func _world_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / TILE_WORLD), floori(p.z / TILE_WORLD))

func _evict_oldest() -> void:
	var oldest_slot := -1
	var oldest_time := INF
	for i in POOL:
		if _slot_cell[i] != null and _slot_active[i] < oldest_time:
			oldest_time = _slot_active[i]
			oldest_slot = i
	if oldest_slot >= 0:
		_free(oldest_slot)

func _alloc(cell: Vector2i) -> int:
	if _cell_slot.has(cell): return _cell_slot[cell]
	if _free_slots.is_empty(): _evict_oldest()
	if _free_slots.is_empty(): return -1
	var slot: int = _free_slots.pop_back()
	_cell_slot[cell] = slot; _slot_cell[slot] = cell; _clear_queue.append(slot)
	var ix := cell.x + GRID_ORIGIN; var iy := cell.y + GRID_ORIGIN
	if ix >= 0 and ix < GRID and iy >= 0 and iy < GRID:
		_index_img.set_pixel(ix, iy, Color(float(slot), 0, 0))
	return slot

func _free(slot: int) -> void:
	var cell = _slot_cell[slot]
	if cell != null:
		var ix: float = cell.x + GRID_ORIGIN; var iy: float = cell.y + GRID_ORIGIN
		if ix >= 0 and ix < GRID and iy >= 0 and iy < GRID:
			_index_img.set_pixel(ix, iy, Color(-1, 0, 0))
		_cell_slot.erase(cell)
	_slot_cell[slot] = null; _free_slots.append(slot)

func _process(delta: float) -> void:
	_time += delta
	for s in _ships:
		if not is_instance_valid(s): continue
		var slot := _alloc(_world_cell(s.global_position))
		if slot >= 0: _slot_active[slot] = _time
	for slot in POOL:
		if _slot_cell[slot] != null and _time - _slot_active[slot] > TILE_LIFETIME:
			_free(slot)
	for slot in POOL:
		var base := slot * 32
		var cell = _slot_cell[slot]
		if cell == null:
			_tiles_bytes.encode_float(base + 8, 0.0); continue
		var ox: float = cell.x * TILE_WORLD; var oz: float = cell.y * TILE_WORLD
		_tiles_bytes.encode_float(base + 0, ox)
		_tiles_bytes.encode_float(base + 4, oz)
		_tiles_bytes.encode_float(base + 8, 1.0)
		_tiles_bytes.encode_float(base + 12, 0.0)
		var su := Vector2(-1, -1)
		for s in _ships:
			if is_instance_valid(s) and _world_cell(s.global_position) == cell:
				su = Vector2((s.global_position.x - ox) / TILE_WORLD,
							 (s.global_position.z - oz) / TILE_WORLD)
				break
		_tiles_bytes.encode_float(base + 16, su.x)
		_tiles_bytes.encode_float(base + 20, su.y)
		_tiles_bytes.encode_float(base + 24, STAMP_STRENGTH)
		_tiles_bytes.encode_float(base + 28, STAMP_RADIUS)
	_index_tex.update(_index_img)
	if _initialized and ocean_material:
		ocean_material.set_shader_parameter("wave_array", _wrap[1 - _parity])
		ocean_material.set_shader_parameter("tiles_on", true)
	RenderingServer.call_on_render_thread(
		_render_update.bind(_parity, _tiles_bytes.duplicate(), _clear_queue.duplicate()))
	_clear_queue.clear()
	_parity = 1 - _parity

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
		_rd.texture_clear(_tex[i], Color(0,0,0,0), 0, 1, 0, POOL)
	_buf = _rd.storage_buffer_create(_tiles_bytes.size())
	for p in 2:
		var a := RDUniform.new(); a.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; a.binding = 0; a.add_id(_tex[p])
		var b := RDUniform.new(); b.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; b.binding = 1; b.add_id(_tex[1 - p])
		var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(_buf)
		_uset[p] = _rd.uniform_set_create([a, b, u], _shader, 0)
	for i in 2:
		var w := Texture2DArrayRD.new(); w.texture_rd_rid = _tex[i]; _wrap[i] = w
	_initialized = true

func _render_update(parity: int, tiles: PackedByteArray, clears: Array) -> void:
	if not _initialized: _init_rd()
	for slot in clears:
		_rd.texture_clear(_tex[0], Color(0,0,0,0), 0, 1, slot, 1)
		_rd.texture_clear(_tex[1], Color(0,0,0,0), 0, 1, slot, 1)
	_rd.buffer_update(_buf, 0, tiles.size(), tiles)
	var pc := PackedByteArray(); pc.resize(16)
	pc.encode_s32(0, TILE_RES)
	pc.encode_float(4, 0.25)     # c2
	pc.encode_float(8, 0.99)     # damp
	pc.encode_float(12, 0.995)   # foam_decay
	var g := (TILE_RES + 7) / 8
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uset[parity], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g, g, POOL)
	_rd.compute_list_end()
