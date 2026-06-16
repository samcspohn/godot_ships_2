extends Node
class_name _WaveManager

const TILE_RES := 128
const TILE_WORLD := 500.0
const POOL := 256
const GRID := 64
const GRID_ORIGIN := 32
const TILE_LIFETIME := 40.0
const HULL_STRENGTH := 13.0
const FOAM_DIFFUSE := 0.01   # 0 = no spread, 0.1 = original (too fast)

const MAX_SHIPS := 32
const MAX_IMPULSES := 64

@export var ocean_material: ShaderMaterial
const SHADER_FILE := preload("res://src/Maps/wave.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex: Array[RID] = [RID(), RID()]
var _uset: Array[RID] = [RID(), RID()]
var _buf: RID
var _ships_buf: RID
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
var _prev_pos: Dictionary = {}
var _ship_hulls: Dictionary = {}   # Node3D -> Vector3(half_length, half_beam, draft) world units
var _tiles_bytes := PackedByteArray()
var _ships_bytes := PackedByteArray()
var _impulses: Array = []
var _impulses_buf: RID
var _impulses_bytes := PackedByteArray()

func register_ship(s: Node3D, half_length: float, half_beam: float, draft: float) -> void:
	if s not in _ships: _ships.append(s)
	_ship_hulls[s] = Vector3(half_length, half_beam, draft)

func unregister_ship(s: Node3D) -> void:
	_ships.erase(s)
	_prev_pos.erase(s)
	_ship_hulls.erase(s)

func add_shell_splash(pos: Vector3, radius: float) -> void:
	var strength := clampf(radius * 0.002, 0.000, 2.5)
	_add_impulse(pos, radius, strength, 0.4, 2)

func add_muzzle_blast(pos: Vector3, radius: float) -> void:
	_add_impulse(pos, radius * 3.5, -0.01, 0.4, 1)

func _add_impulse(pos: Vector3, radius: float, strength: float, foam: float, frames: int) -> void:
	if _impulses.size() >= MAX_IMPULSES:
		return
	var cell := _world_cell(pos)
	var slot := _alloc(cell)
	if slot >= 0:
		_slot_active[slot] = _time
	_impulses.append({p = Vector2(pos.x, pos.z), r = radius, s = strength, f = foam, n = frames})

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
	_ships_bytes.resize(MAX_SHIPS * 48)
	_impulses_bytes.resize(MAX_IMPULSES * 32)
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
		var sc := _world_cell(s.global_position)
		var slot := _alloc(sc)
		if slot >= 0: _slot_active[slot] = _time
		# Activate every tile the hull footprint can reach, not just the
		# ship-centre tile.  A fixed border margin misses neighbour tiles
		# when a large ship's bow/stern extends past it.
		var hull_r: Vector3 = _ship_hulls[s]
		var reach := ceili(hull_r.x / TILE_WORLD)
		for dx in range(-reach, reach + 1):
			for dz in range(-reach, reach + 1):
				if dx == 0 and dz == 0: continue
				var ns := _alloc(Vector2i(sc.x + dx, sc.y + dz))
				if ns >= 0: _slot_active[ns] = _time
	for slot in POOL:
		if _slot_cell[slot] != null and _time - _slot_active[slot] > TILE_LIFETIME:
			_free(slot)
	for slot in POOL:
		var base := slot * 32
		var cell = _slot_cell[slot]
		if cell == null:
			_tiles_bytes.encode_float(base + 8, 0.0)
			_tiles_bytes.encode_s32(base + 16, -1)
			_tiles_bytes.encode_s32(base + 20, -1)
			_tiles_bytes.encode_s32(base + 24, -1)
			_tiles_bytes.encode_s32(base + 28, -1)
			continue
		_tiles_bytes.encode_float(base + 0,  cell.x * TILE_WORLD)
		_tiles_bytes.encode_float(base + 4,  cell.y * TILE_WORLD)
		_tiles_bytes.encode_float(base + 8,  1.0)
		_tiles_bytes.encode_float(base + 12, 0.0)
		_tiles_bytes.encode_s32(base + 16, _cell_slot.get(Vector2i(cell.x - 1, cell.y), -1))
		_tiles_bytes.encode_s32(base + 20, _cell_slot.get(Vector2i(cell.x + 1, cell.y), -1))
		_tiles_bytes.encode_s32(base + 24, _cell_slot.get(Vector2i(cell.x, cell.y - 1), -1))
		_tiles_bytes.encode_s32(base + 28, _cell_slot.get(Vector2i(cell.x, cell.y + 1), -1))
	var ship_count := 0
	for s in _ships:
		if not is_instance_valid(s) or ship_count >= MAX_SHIPS: continue
		var prev: Vector3 = _prev_pos.get(s, s.global_position)
		_prev_pos[s] = s.global_position
		var speed := (s.global_position - prev).length()
		# Use the ship's actual transform for heading so the hull stamp always
		# tracks the visual bow regardless of turn rate.
		# Godot's forward convention is -Z, so negate basis.z.
		# If your ship model has its bow on +Z, remove the negation.
		var b := s.global_transform.basis.z
		var fwd_xz := Vector2(-b.x, -b.z)
		var hull = _ship_hulls[s]
		var sbase := ship_count * 48
		_ships_bytes.encode_float(sbase + 0,  s.global_position.x)
		_ships_bytes.encode_float(sbase + 4,  s.global_position.z)
		_ships_bytes.encode_float(sbase + 8,  prev.x)
		_ships_bytes.encode_float(sbase + 12, prev.z)
		_ships_bytes.encode_float(sbase + 16, fwd_xz.x)
		_ships_bytes.encode_float(sbase + 20, fwd_xz.y)
		_ships_bytes.encode_float(sbase + 24, hull.x)
		_ships_bytes.encode_float(sbase + 28, hull.y)
		_ships_bytes.encode_float(sbase + 32, HULL_STRENGTH)
		_ships_bytes.encode_float(sbase + 36, speed)
		_ships_bytes.encode_float(sbase + 40, hull.z)
		_ships_bytes.encode_float(sbase + 44, 0.0)
		ship_count += 1
	var impulse_count := 0
	var next_impulses: Array = []
	for imp in _impulses:
		if impulse_count < MAX_IMPULSES:
			var base := impulse_count * 32
			_impulses_bytes.encode_float(base + 0, imp.p.x)
			_impulses_bytes.encode_float(base + 4, imp.p.y)
			_impulses_bytes.encode_float(base + 8, imp.r)
			_impulses_bytes.encode_float(base + 12, imp.s)
			_impulses_bytes.encode_float(base + 16, imp.f)
			impulse_count += 1
		imp.n -= 1
		if imp.n > 0:
			next_impulses.append(imp)
	_impulses = next_impulses
	_index_tex.update(_index_img)
	if _initialized and ocean_material:
		ocean_material.set_shader_parameter("wave_array", _wrap[1 - _parity])
		ocean_material.set_shader_parameter("tiles_on", true)
	RenderingServer.call_on_render_thread(
		_render_update.bind(_parity, _tiles_bytes.duplicate(), _ships_bytes.duplicate(), ship_count, _clear_queue.duplicate(), _impulses_bytes.duplicate(), impulse_count))
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
	_ships_buf = _rd.storage_buffer_create(_ships_bytes.size())
	_impulses_buf = _rd.storage_buffer_create(_impulses_bytes.size())
	for p in 2:
		var a := RDUniform.new(); a.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; a.binding = 0; a.add_id(_tex[p])
		var b := RDUniform.new(); b.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; b.binding = 1; b.add_id(_tex[1 - p])
		var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(_buf)
		var v := RDUniform.new(); v.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; v.binding = 3; v.add_id(_ships_buf)
		var imp_u := RDUniform.new(); imp_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; imp_u.binding = 4; imp_u.add_id(_impulses_buf)
		_uset[p] = _rd.uniform_set_create([a, b, u, v, imp_u], _shader, 0)
	for i in 2:
		var w := Texture2DArrayRD.new(); w.texture_rd_rid = _tex[i]; _wrap[i] = w
	_initialized = true

func _render_update(parity: int, tiles: PackedByteArray, ships: PackedByteArray, ship_count: int, clears: Array, impulses: PackedByteArray, impulse_count: int) -> void:
	if not _initialized: _init_rd()
	for slot in clears:
		_rd.texture_clear(_tex[0], Color(0,0,0,0), 0, 1, slot, 1)
		_rd.texture_clear(_tex[1], Color(0,0,0,0), 0, 1, slot, 1)
	_rd.buffer_update(_buf, 0, tiles.size(), tiles)
	_rd.buffer_update(_ships_buf, 0, ships.size(), ships)
	_rd.buffer_update(_impulses_buf, 0, impulses.size(), impulses)
	var pc := PackedByteArray(); pc.resize(32)
	pc.encode_s32(0, TILE_RES)
	pc.encode_float(4, 0.001)    # c2: wave speed ~3.7 m/s → 22° wake at 10 m/s (≈Kelvin)
	pc.encode_float(8, 0.999)   # damp: low enough that waves reach 100m with ~78% amplitude
	pc.encode_float(12, 0.998)   # foam_decay
	pc.encode_s32(16, ship_count)
	pc.encode_float(20, TILE_WORLD)
	pc.encode_float(24, FOAM_DIFFUSE)
	pc.encode_s32(28, impulse_count)
	var g := (TILE_RES + 7) / 8
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uset[parity], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g, g, POOL)
	_rd.compute_list_end()
