extends Node
class_name _WaveManager

const FOAM_TEX := "res://src/Maps/ocean_foam.png"
const PLAY_HALF := 17500.0

# Coarse grid carries ship pressure: 6 m cells keep Kelvin wavelengths (~100-250 m)
# inside the kernel's dispersive band. Fine grid carries splashes only.
const COARSE_DX := 6.0
const COARSE_POOL := 192
const COARSE_DAMPING := 0.05
const COARSE_MARGIN := 600.0     # water simulated beyond the hull so the wake has room to spread
const FINE_DX := 2.0
const FINE_POOL := 96
const FINE_DAMPING := 0.15
const HARD_LIFETIME := 60.0
const READBACK_INTERVAL := 0.5

# --- persistent wake map tiles ---
const WAKE_RES := 128
const WAKE_WORLD := 512.0
const WAKE_GRID := 72
const WAKE_ORIGIN := WAKE_GRID / 2
const WAKE_POOL := 160
const WAKE_LIFE := 60.0
const WAKE_MARGIN := 300.0

const SIM_HZ := 30.0
const SIM_DT := 1.0 / SIM_HZ
const MAX_SUBSTEPS := 2
const GRAVITY := 9.81
const HULL_GAIN := 0.6           # hull pressure as metres of head, per metre of draft
const SPONGE_CELLS := 10.0

const MAX_SHIPS := 32            # ship mask is one uint
const MAX_IMPULSES := 64         # impulse mask is two uints

const SHIP_FLOATS := 12
const IMPULSE_FLOATS := 8
const STAMP_FLOATS := 12

@export var ocean_material: ShaderMaterial
const SIM_SHADER := preload("res://src/Maps/wave.glsl")
const STAMP_SHADER := preload("res://src/Maps/wake_stamp.glsl")

var _coarse := WaveSim.new(COARSE_DX, COARSE_POOL, COARSE_DAMPING, HARD_LIFETIME, PLAY_HALF)
var _fine := WaveSim.new(FINE_DX, FINE_POOL, FINE_DAMPING, HARD_LIFETIME, PLAY_HALF)

var _rd: RenderingDevice
var _sim_pipeline: RID
var _stamp_pipeline: RID
var _wake_tex: RID
var _stamp_uset: RID
var _ships_buf: RID
var _impulses_buf: RID
var _wake_index_buf: RID
var _stamps_buf: RID
var _initialized := false
var _parity := 0
var _time := 0.0
var _sim_accum := 0.0
var _since_step := 0.0

var _w_index_img: Image
var _w_index_tex: ImageTexture
var _w_index := PackedInt32Array()
var _w_dirty := false
var _w_cell_slot := {}
var _w_slot_cell: Array[Vector2i] = []
var _w_used := PackedByteArray()
var _w_touch := PackedFloat64Array()
var _w_free := PackedInt32Array()
var _w_scan := 0
var _w_clear_queue := PackedInt32Array()

var _ships: Array[Node3D] = []
var _prev_pos: Dictionary = {}
var _prev_fwd: Dictionary = {}
var _ship_hulls: Dictionary = {}   # Node3D -> Vector3(half_length, half_beam, draft)
var _ship_f := PackedFloat32Array()
var _stamp_f := PackedFloat32Array()
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
	var sigma := radius * 0.85
	# foam grows faster than the wave so big shells get a proportionally bigger patch
	_add_impulse(pos, sigma, radius * 0.1275, 0.7, sigma * sqrt(maxf(radius, 1.0) / 5.0))

func add_muzzle_blast(pos: Vector3, radius: float) -> void:
	_add_impulse(pos, clampf(radius * 1.5, 6.0, 40.0), 0.1, 0.0)

func _add_impulse(pos: Vector3, sigma: float, depth: float, foam: float, foam_sigma := 0.0) -> void:
	if _impulses.size() >= MAX_IMPULSES:
		return
	var p := Vector2(pos.x, pos.z)
	var reach := maxf(sigma, foam_sigma) * 2.5
	_fine.touch_rect(p, p, minf(reach, _fine.tile_world), _time)
	if foam > 0.0: _w_touch_rect(p, reach)
	_impulses.append({p = p, s = sigma, d = depth, f = foam, fs = maxf(foam_sigma, 0.01), r = reach})


func _ready() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		queue_free(); return

	_w_slot_cell.resize(WAKE_POOL)
	_w_used.resize(WAKE_POOL)
	_w_touch.resize(WAKE_POOL)
	for i in WAKE_POOL: _w_free.append(WAKE_POOL - 1 - i)
	_w_index.resize(WAKE_GRID * WAKE_GRID)
	_w_index.fill(-1)
	_w_index_img = Image.create(WAKE_GRID, WAKE_GRID, false, Image.FORMAT_RF)
	_w_index_img.fill(Color(-1, 0, 0))
	_w_index_tex = ImageTexture.create_from_image(_w_index_img)

	_ship_f.resize(MAX_SHIPS * SHIP_FLOATS)
	_stamp_f.resize(MAX_SHIPS * STAMP_FLOATS)
	_impulse_f.resize(MAX_IMPULSES * IMPULSE_FLOATS)
	if ocean_material:
		# Loaded here rather than as an ext_resource so the headless server never pays for it.
		ocean_material.set_shader_parameter("foam_tex", load(FOAM_TEX))
		for pair in [[_fine, ""], [_coarse, "_c"]]:
			var sim: WaveSim = pair[0]
			ocean_material.set_shader_parameter("index_tex" + pair[1], sim.index_tex)
			ocean_material.set_shader_parameter("tile_world" + pair[1], sim.tile_world)
			ocean_material.set_shader_parameter("grid_origin" + pair[1], sim.origin)
		ocean_material.set_shader_parameter("wake_index", _w_index_tex)
		ocean_material.set_shader_parameter("wake_world", WAKE_WORLD)
		ocean_material.set_shader_parameter("wake_origin", WAKE_ORIGIN)
		ocean_material.set_shader_parameter("wake_life", WAKE_LIFE)
		ocean_material.set_shader_parameter("tiles_on", false)
		ocean_material.render_priority = -1

	get_child(0).ocean_material = ocean_material
	RenderingServer.call_on_render_thread(_init_rd)

func get_ocean_material() -> ShaderMaterial:
	return ocean_material


# ---------------------------------------------------------------- wake tiles

func _w_alloc(cell: Vector2i) -> int:
	var existing: int = _w_cell_slot.get(cell, -1)
	if existing >= 0: return existing
	var ix := cell.x + WAKE_ORIGIN
	var iy := cell.y + WAKE_ORIGIN
	if ix < 0 or ix >= WAKE_GRID or iy < 0 or iy >= WAKE_GRID: return -1
	if _w_free.is_empty(): _w_evict_oldest()
	if _w_free.is_empty(): return -1
	var slot: int = _w_free[_w_free.size() - 1]
	_w_free.resize(_w_free.size() - 1)
	_w_cell_slot[cell] = slot
	_w_slot_cell[slot] = cell
	_w_used[slot] = 1
	_w_touch[slot] = _time
	_w_clear_queue.append(slot)
	_w_set_index(ix, iy, slot)
	return slot

func _w_release(slot: int) -> void:
	var cell := _w_slot_cell[slot]
	_w_cell_slot.erase(cell)
	_w_used[slot] = 0
	_w_free.append(slot)
	_w_set_index(cell.x + WAKE_ORIGIN, cell.y + WAKE_ORIGIN, -1)

func _w_set_index(ix: int, iy: int, slot: int) -> void:
	_w_index[iy * WAKE_GRID + ix] = slot
	_w_index_img.set_pixel(ix, iy, Color(float(slot), 0, 0))
	_w_dirty = true

func _w_evict_oldest() -> void:
	var oldest := -1
	var oldest_time := INF
	for slot in WAKE_POOL:
		if _w_used[slot] == 1 and _w_touch[slot] < oldest_time:
			oldest_time = _w_touch[slot]
			oldest = slot
	if oldest >= 0:
		_w_release(oldest)

func _w_touch_rect(p: Vector2, r: float) -> void:
	var c0 := Vector2i(floori((p.x - r) / WAKE_WORLD), floori((p.y - r) / WAKE_WORLD))
	var c1 := Vector2i(floori((p.x + r) / WAKE_WORLD), floori((p.y + r) / WAKE_WORLD))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var slot := _w_alloc(Vector2i(cx, cy))
			if slot >= 0: _w_touch[slot] = _time

func _expire_wake() -> void:
	for k in 8:
		var slot := _w_scan
		_w_scan = (_w_scan + 1) % WAKE_POOL
		if _w_used[slot] == 1 and _time - _w_touch[slot] > WAKE_LIFE + 1.0:
			_w_release(slot)


# ---------------------------------------------------------------- frame

func _process(delta: float) -> void:
	_time += delta
	_since_step += delta
	if _initialized and ocean_material:
		ocean_material.set_shader_parameter("wake_time", _time)
	_sim_accum += delta
	var substeps := int(_sim_accum / SIM_DT)
	if substeps > MAX_SUBSTEPS:
		substeps = MAX_SUBSTEPS
		_sim_accum = 0.0
	else:
		_sim_accum -= substeps * SIM_DT
	if substeps == 0:
		return
	# Ship poses below span the time since the previous stepping frame.
	var span := maxf(_since_step, 1e-4)
	_since_step = 0.0

	_coarse.begin_frame()
	_fine.begin_frame()
	var ship_count := 0
	for s in _ships:
		if ship_count >= MAX_SHIPS or not is_instance_valid(s) or not s.is_inside_tree(): continue
		var xf := s.global_transform
		var p2 := Vector2(xf.origin.x, xf.origin.z)
		var q2: Vector2 = _prev_pos.get(s, p2)
		_prev_pos[s] = p2
		var fwd := Vector2(-xf.basis.z.x, -xf.basis.z.z).normalized()
		var prev_fwd: Vector2 = _prev_fwd.get(s, fwd)
		_prev_fwd[s] = fwd
		var hull: Vector3 = _ship_hulls[s]
		_coarse.touch_rect(q2, p2, hull.x + COARSE_MARGIN, _time, ship_count)
		_w_touch_rect(p2, hull.x + WAKE_MARGIN)
		var f := ship_count * SHIP_FLOATS
		_ship_f[f] = p2.x;           _ship_f[f + 1] = p2.y
		_ship_f[f + 2] = q2.x;       _ship_f[f + 3] = q2.y
		_ship_f[f + 4] = fwd.x;      _ship_f[f + 5] = fwd.y
		_ship_f[f + 6] = prev_fwd.x; _ship_f[f + 7] = prev_fwd.y
		_ship_f[f + 8] = hull.x;     _ship_f[f + 9] = hull.y
		_ship_f[f + 10] = hull.z * HULL_GAIN

		var speed01 := clampf((p2 - q2).length() / (span * 8.0), 0.0, 1.0)
		var stern := p2 - fwd * hull.x * 0.95
		var prev_stern := q2 - prev_fwd * hull.x * 0.95
		var g := ship_count * STAMP_FLOATS
		_stamp_f[g] = p2.x;              _stamp_f[g + 1] = p2.y
		_stamp_f[g + 2] = fwd.x;         _stamp_f[g + 3] = fwd.y
		_stamp_f[g + 4] = stern.x;       _stamp_f[g + 5] = stern.y
		_stamp_f[g + 6] = prev_stern.x;  _stamp_f[g + 7] = prev_stern.y
		_stamp_f[g + 8] = hull.x;        _stamp_f[g + 9] = hull.y
		_stamp_f[g + 10] = 0.55 * speed01
		_stamp_f[g + 11] = speed01
		ship_count += 1

	var impulse_count := 0
	for imp in _impulses:
		var f := impulse_count * IMPULSE_FLOATS
		_impulse_f[f] = imp.p.x;   _impulse_f[f + 1] = imp.p.y
		_impulse_f[f + 2] = imp.s; _impulse_f[f + 3] = imp.d
		_impulse_f[f + 4] = imp.f;  _impulse_f[f + 5] = imp.fs
		_fine.mask_impulse(imp.p, imp.r, impulse_count)
		impulse_count += 1
	_impulses.clear()

	_coarse.expire(_time)
	_fine.expire(_time)
	_expire_wake()

	var wake_index := PackedByteArray()
	if _w_dirty:
		_w_index_tex.update(_w_index_img)
		wake_index = _w_index.to_byte_array()
		_w_dirty = false
	var cf := _coarse.take_frame(_time, READBACK_INTERVAL)
	var ff := _fine.take_frame(_time, READBACK_INTERVAL)

	var new_parity := (_parity + substeps) % 2
	if _initialized and ocean_material:
		if new_parity != _parity or not _tiles_on:
			ocean_material.set_shader_parameter("wave_array", _fine.wraps[new_parity])
			ocean_material.set_shader_parameter("wave_array_c", _coarse.wraps[new_parity])
		if not _tiles_on:
			ocean_material.set_shader_parameter("wave_lod", _fine.lod_wrap)
			ocean_material.set_shader_parameter("wave_lod_c", _coarse.lod_wrap)
			ocean_material.set_shader_parameter("tiles_on", true)
			_tiles_on = true
	RenderingServer.call_on_render_thread(_render_update.bind(
		_parity, substeps, cf, ff, wake_index, _w_clear_queue.duplicate(),
		_ship_f.to_byte_array(), _stamp_f.to_byte_array(), ship_count,
		_impulse_f.to_byte_array(), impulse_count, _time, span))
	_w_clear_queue.clear()
	_parity = new_parity


# ---------------------------------------------------------------- render thread

func _init_rd() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		queue_free(); return
	var sim_shader := _rd.shader_create_from_spirv(SIM_SHADER.get_spirv())
	var stamp_shader := _rd.shader_create_from_spirv(STAMP_SHADER.get_spirv())
	_sim_pipeline = _rd.compute_pipeline_create(sim_shader)
	_stamp_pipeline = _rd.compute_pipeline_create(stamp_shader)

	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_wake_tex = WaveSim.array_tex(_rd, WAKE_RES, WAKE_POOL, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, usage)
	_ships_buf = _rd.storage_buffer_create(MAX_SHIPS * SHIP_FLOATS * 4)
	_stamps_buf = _rd.storage_buffer_create(MAX_SHIPS * STAMP_FLOATS * 4)
	_impulses_buf = _rd.storage_buffer_create(MAX_IMPULSES * IMPULSE_FLOATS * 4)
	_wake_index_buf = _rd.storage_buffer_create(WAKE_GRID * WAKE_GRID * 4, _w_index.to_byte_array())
	_coarse.init_rd(_rd, sim_shader, _ships_buf, _impulses_buf, _wake_index_buf, _wake_tex)
	_fine.init_rd(_rd, sim_shader, _ships_buf, _impulses_buf, _wake_index_buf, _wake_tex)
	var SB := RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	_stamp_uset = _rd.uniform_set_create([
		WaveSim.uni(SB, 0, _stamps_buf), WaveSim.uni(SB, 1, _wake_index_buf),
		WaveSim.uni(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, _wake_tex),
	], stamp_shader, 0)

	var wake_wrap := Texture2DArrayRD.new(); wake_wrap.texture_rd_rid = _wake_tex
	if ocean_material:
		ocean_material.set_shader_parameter.call_deferred("wake_array", wake_wrap)
	_initialized = true

func _render_update(parity: int, substeps: int, cf: Dictionary, ff: Dictionary,
		wake_index: PackedByteArray, wake_clears: PackedInt32Array,
		ships: PackedByteArray, stamps: PackedByteArray, ship_count: int,
		impulses: PackedByteArray, impulse_count: int, time: float, span: float) -> void:
	if not _initialized: _init_rd()
	for slot in wake_clears:
		_rd.texture_clear(_wake_tex, Color(0, 0, 0, 0), 0, 1, slot, 1)
	if not wake_index.is_empty():
		_rd.buffer_update(_wake_index_buf, 0, wake_index.size(), wake_index)
	_rd.buffer_update(_ships_buf, 0, ships.size(), ships)
	_rd.buffer_update(_stamps_buf, 0, stamps.size(), stamps)
	_rd.buffer_update(_impulses_buf, 0, impulses.size(), impulses)
	_coarse.upload(cf)
	_fine.upload(ff)

	var pc := PackedByteArray(); pc.resize(80)
	pc.encode_s32(0, WaveSim.RES)
	pc.encode_float(36, time)
	pc.encode_float(40, WAKE_LIFE)
	pc.encode_float(44, span)
	pc.encode_float(48, SIM_DT)
	pc.encode_float(64, WAKE_WORLD)
	pc.encode_s32(68, WAKE_GRID)
	pc.encode_s32(72, WAKE_ORIGIN)
	pc.encode_float(76, SPONGE_CELLS)

	var cl := _rd.compute_list_begin()
	_coarse.dispatch(cl, _sim_pipeline, pc, cf, parity, substeps, SIM_DT, GRAVITY, false)
	_fine.dispatch(cl, _sim_pipeline, pc, ff, parity, substeps, SIM_DT, GRAVITY, impulse_count > 0)
	if ship_count > 0:
		var spc := PackedByteArray(); spc.resize(32)
		spc.encode_float(0, WAKE_WORLD)
		spc.encode_s32(4, WAKE_GRID)
		spc.encode_s32(8, WAKE_ORIGIN)
		spc.encode_s32(12, WAKE_RES)
		spc.encode_float(16, time)
		spc.encode_float(20, WAKE_LIFE)
		_rd.compute_list_bind_compute_pipeline(cl, _stamp_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _stamp_uset, 0)
		_rd.compute_list_set_push_constant(cl, spc, spc.size())
		_rd.compute_list_dispatch(cl, 16, 16, ship_count)
	_rd.compute_list_end()
