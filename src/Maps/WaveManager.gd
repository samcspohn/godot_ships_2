extends Node
class_name _WaveManager

const FOAM_TEX := "res://src/Maps/ocean_foam.png"
const PLAY_HALF := 17500.0

# Coarse grid carries ship pressure: 6 m cells keep Kelvin wavelengths (~100-250 m)
# inside the kernel's dispersive band. Fine grid carries splashes only.
const COARSE_DX := 6.0
const COARSE_POOL := 176
const COARSE_DAMPING := 0.01
const COARSE_MARGIN := 450.0     # water simulated beyond the hull so the wake has room to spread
const FINE_DX := 2.0
const FINE_POOL := 64
const FINE_DAMPING := 0.15
const FINE_HOLD := 1.5
const FINE_QUIET_H := 0.05
const FINE_LIFETIME := 8.0       # splash rings are invisible by then; their slow decay would hold tiles ~30 s
const HARD_LIFETIME := 60.0
const READBACK_INTERVAL := 0.5

# --- persistent wake map tiles ---
const WAKE_RES := 128
const WAKE_WORLD := 512.0
const WAKE_GRID := 72
const WAKE_ORIGIN := WAKE_GRID / 2
const WAKE_POOL := 176
const WAKE_LIFE := 60.0
const WAKE_REACH := 1.25         # wake tiles claimed around a ship, in half-lengths (spray + stern ribbon)
const SPLASH_FOAM_LIFE := WAKE_LIFE * 0.2   # matches SPLASH_LIFE_FRAC in the wake shaders

const SIM_HZ := 30.0
const SIM_DT := 1.0 / SIM_HZ
const MAX_SUBSTEPS := 2
const GRAVITY := 9.81
# Ships run at 2x real speed; 4x gravity keeps U^2/g, so wake wavelengths and the
# Kelvin angle match real speed (and the wave pattern keeps pace with the ship).
const WAKE_GRAVITY := GRAVITY * 4.0
const STERN_FOAM_AT := 0.7       # stern ribbon origin aft of centre, in half-lengths
const FULL_FOAM_SPEED := 28.0    # m/s (~27 kn at 2x speed)
const TELEPORT_SPEED := 150.0    # m/s; faster frame-to-frame motion is a reposition, not sailing
const BOW_GAIN := 0.1            # stem hump as a fraction of U^2/2g
const HULL_GAIN := 0.25           # hull pressure as metres of head, per metre of draft
const SPONGE_CELLS := 10.0

const MAX_RINGS := 64           # keep in sync with rings[] / ring_hulls[] in ocean.gdshader
const RING_SPEED := 343.0
const RING_BARREL_REACH := 30.0  # muzzle can sit this far outboard of the hull side
const RING_REACH := 6.4          # blast radius -> max shock ring radius

const MAX_SHIPS := 32            # ship mask is one uint
const MAX_IMPULSES := 64         # impulse mask is two uints

const SHIP_FLOATS := 12
const IMPULSE_FLOATS := 8
const STAMP_FLOATS := 16
const MAX_TRAILS := 128
const TRAIL_HALF_WIDTH := 2.0
const TRAIL_STRENGTH := 1.0

@export var ocean_material: ShaderMaterial
const SIM_SHADER := preload("res://src/Maps/wave.glsl")
const STAMP_SHADER := preload("res://src/Maps/wake_stamp.glsl")

var _coarse := WaveSim.new(COARSE_DX, COARSE_POOL, COARSE_DAMPING, HARD_LIFETIME, PLAY_HALF)
var _fine := WaveSim.new(FINE_DX, FINE_POOL, FINE_DAMPING, FINE_LIFETIME, PLAY_HALF)

var _rd: RenderingDevice
var _shaders: Array[RID] = []
var _wake_wrap: Texture2DArrayRD
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
var _w_expire := PackedFloat64Array()   # time after which the tile holds nothing visible
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
var _trails := {}                     # key -> [last stamped point, current point]
var _rings: Array[Vector4] = []
var _ring_hulls: Array[Vector4] = []  # firing ship centerline (stern xz, bow xz)
var _rings_dirty := false


func register_ship(s: Node3D, half_length: float, half_beam: float, draft: float) -> void:
	if s not in _ships: _ships.append(s)
	_ship_hulls[s] = Vector3(half_length, half_beam, draft)

func unregister_ship(s: Node3D) -> void:
	_ships.erase(s)
	_prev_pos.erase(s)
	_prev_fwd.erase(s)
	_ship_hulls.erase(s)

# Bubble track behind a torpedo; call every frame while it runs, end_trail when it dies.
func trail_point(key: Object, pos: Vector3) -> void:
	var p := Vector2(pos.x, pos.z)
	if not _trails.has(key):
		_trails[key] = [p, p]
	else:
		_trails[key][1] = p

func end_trail(key: Object) -> void:
	_trails.erase(key)

func add_shell_splash(pos: Vector3, radius: float) -> void:
	var sigma := radius * 0.85
	# foam grows faster than the wave so big shells get a proportionally bigger patch
	_add_impulse(pos, sigma, radius * 0.255, 0.7, sigma * sqrt(maxf(radius, 1.0) / 5.0))

func add_muzzle_blast(pos: Vector3, radius: float) -> void:
	var ring := Vector4(pos.x, pos.z, _time, maxf(radius * RING_REACH, 8.0))
	if _rings.size() >= MAX_RINGS:
		# Drop whichever ring ends soonest, so rapid small blasts never cut a big
		# blast's long fade short; the new ring itself may be the one dropped.
		var mult := _ring_life_mult()
		var victim := -1
		var soonest := _ring_end(ring, mult)
		for i in _rings.size():
			var e := _ring_end(_rings[i], mult)
			if e < soonest:
				soonest = e
				victim = i
		if victim < 0: return
		_rings.remove_at(victim)
		_ring_hulls.remove_at(victim)
	_rings.append(ring)
	_ring_hulls.append(_hull_under(Vector2(pos.x, pos.z)))
	_rings_dirty = true

func _ring_end(r: Vector4, mult: float) -> float:
	return r.z + r.w / RING_SPEED * mult

# Centerline (stern xz, bow xz) of the ship whose deck the muzzle is over; zero = none.
func _hull_under(p: Vector2) -> Vector4:
	var best := Vector4.ZERO
	var best_d := INF
	for s in _ships:
		if not is_instance_valid(s) or not s.is_inside_tree(): continue
		var xf := s.global_transform
		var c := Vector2(xf.origin.x, xf.origin.z)
		var fwd := Vector2(-xf.basis.z.x, -xf.basis.z.z).normalized()
		var hull: Vector3 = _ship_hulls[s]
		var r := p - c
		var along := absf(r.dot(fwd))
		var side := absf(r.dot(Vector2(-fwd.y, fwd.x)))
		if along > hull.x * 1.2 or side > hull.y + RING_BARREL_REACH: continue
		var d := along / hull.x + side / (hull.y + RING_BARREL_REACH)
		if d < best_d:
			best_d = d
			var a := c - fwd * hull.x * 1.05
			var b := c + fwd * hull.x * 1.05
			best = Vector4(a.x, a.y, b.x, b.y)
	return best

func _add_impulse(pos: Vector3, sigma: float, depth: float, foam: float, foam_sigma := 0.0) -> void:
	if _impulses.size() >= MAX_IMPULSES:
		return
	var p := Vector2(pos.x, pos.z)
	var reach := maxf(sigma, foam_sigma) * 2.5
	_fine.touch_rect(p, p, minf(reach, _fine.tile_world), _time)
	if foam > 0.0: _w_touch_rect(p, reach, SPLASH_FOAM_LIFE)
	_impulses.append({p = p, s = sigma, d = depth, f = foam, fs = maxf(foam_sigma, 0.01), r = reach})


func _ready() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		queue_free(); return
	_fine.hold = FINE_HOLD
	_fine.quiet_h = FINE_QUIET_H
	_coarse.bow_gain = BOW_GAIN

	_w_slot_cell.resize(WAKE_POOL)
	_w_used.resize(WAKE_POOL)
	_w_expire.resize(WAKE_POOL)
	for i in WAKE_POOL: _w_free.append(WAKE_POOL - 1 - i)
	_w_index.resize(WAKE_GRID * WAKE_GRID)
	_w_index.fill(-1)
	_w_index_img = Image.create(WAKE_GRID, WAKE_GRID, false, Image.FORMAT_RF)
	_w_index_img.fill(Color(-1, 0, 0))
	_w_index_tex = ImageTexture.create_from_image(_w_index_img)

	_ship_f.resize(MAX_SHIPS * SHIP_FLOATS)
	_stamp_f.resize((MAX_SHIPS + MAX_TRAILS) * STAMP_FLOATS)
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

func _exit_tree() -> void:
	if not _initialized: return
	_initialized = false
	if ocean_material:
		for p in ["wave_array", "wave_array_c", "wave_lod", "wave_lod_c", "wake_array"]:
			ocean_material.set_shader_parameter(p, null)
	RenderingServer.call_on_render_thread(_free_rd)

# Freeing a base resource also frees its slices, uniform sets and pipelines.
func _free_rd() -> void:
	_coarse.free_rd()
	_fine.free_rd()
	if _wake_wrap: _wake_wrap.texture_rd_rid = RID()
	for r: RID in [_wake_tex, _ships_buf, _impulses_buf, _wake_index_buf, _stamps_buf]:
		if r.is_valid(): _rd.free_rid(r)
	for sh in _shaders: _rd.free_rid(sh)
	_shaders.clear()

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
	_w_expire[slot] = _time
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
		if _w_used[slot] == 1 and _w_expire[slot] < oldest_time:
			oldest_time = _w_expire[slot]
			oldest = slot
	if oldest >= 0:
		_w_release(oldest)

func _w_touch_rect(p: Vector2, r: float, life: float) -> void:
	var c0 := Vector2i(floori((p.x - r) / WAKE_WORLD), floori((p.y - r) / WAKE_WORLD))
	var c1 := Vector2i(floori((p.x + r) / WAKE_WORLD), floori((p.y + r) / WAKE_WORLD))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var slot := _w_alloc(Vector2i(cx, cy))
			if slot >= 0: _w_expire[slot] = maxf(_w_expire[slot], _time + life)

func _expire_wake() -> void:
	for k in 8:
		var slot := _w_scan
		_w_scan = (_w_scan + 1) % WAKE_POOL
		if _w_used[slot] == 1 and _time > _w_expire[slot] + 1.0:
			_w_release(slot)


# ---------------------------------------------------------------- frame

# Ring lifetime lives on the material (ring_fill_life x ring_foam_linger) so
# expiry can never cut the shader's fade short.
func _ring_life_mult() -> float:
	return _mat_param("ring_fill_life") * _mat_param("ring_foam_linger")

func _mat_param(p: String) -> float:
	var v = ocean_material.get_shader_parameter(p)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(ocean_material.shader.get_rid(), p)
	return float(v)

func _update_rings() -> void:
	var mult := _ring_life_mult()
	for i in range(_rings.size() - 1, -1, -1):
		if _time >= _ring_end(_rings[i], mult):
			_rings.remove_at(i)
			_ring_hulls.remove_at(i)
			_rings_dirty = true
	if not _rings_dirty: return
	_rings_dirty = false
	var packed := PackedVector4Array(_rings)
	packed.resize(MAX_RINGS)
	var hulls := PackedVector4Array(_ring_hulls)
	hulls.resize(MAX_RINGS)
	ocean_material.set_shader_parameter("rings", packed)
	ocean_material.set_shader_parameter("ring_hulls", hulls)
	ocean_material.set_shader_parameter("ring_count", _rings.size())
	ocean_material.set_shader_parameter("ring_speed", RING_SPEED)


func _process(delta: float) -> void:
	_time += delta
	_since_step += delta
	if _initialized and ocean_material:
		ocean_material.set_shader_parameter("wake_time", _time)
		_update_rings()
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
		# Spawn placement and re-spotting snap ships across the map; never sweep a wake along the jump.
		if p2.distance_to(q2) > TELEPORT_SPEED * span:
			q2 = p2
			prev_fwd = fwd
		var hull: Vector3 = _ship_hulls[s]
		_coarse.touch_rect(q2, p2, hull.x + COARSE_MARGIN, _time, ship_count)
		_w_touch_rect(p2, hull.x * WAKE_REACH, WAKE_LIFE)
		var f := ship_count * SHIP_FLOATS
		_ship_f[f] = p2.x;           _ship_f[f + 1] = p2.y
		_ship_f[f + 2] = q2.x;       _ship_f[f + 3] = q2.y
		_ship_f[f + 4] = fwd.x;      _ship_f[f + 5] = fwd.y
		_ship_f[f + 6] = prev_fwd.x; _ship_f[f + 7] = prev_fwd.y
		_ship_f[f + 8] = hull.x;     _ship_f[f + 9] = hull.y
		_ship_f[f + 10] = hull.z * HULL_GAIN

		var speed01 := clampf((p2 - q2).length() / (span * FULL_FOAM_SPEED), 0.0, 1.0)
		var stern := p2 - fwd * hull.x * STERN_FOAM_AT
		var prev_stern := q2 - prev_fwd * hull.x * STERN_FOAM_AT
		var g := ship_count * STAMP_FLOATS
		_stamp_f[g] = p2.x;              _stamp_f[g + 1] = p2.y
		_stamp_f[g + 2] = fwd.x;         _stamp_f[g + 3] = fwd.y
		_stamp_f[g + 4] = stern.x;       _stamp_f[g + 5] = stern.y
		_stamp_f[g + 6] = prev_stern.x;  _stamp_f[g + 7] = prev_stern.y
		_stamp_f[g + 8] = hull.x;        _stamp_f[g + 9] = hull.y
		_stamp_f[g + 10] = 0.85 * speed01
		_stamp_f[g + 11] = speed01
		_stamp_f[g + 12] = hull.y * 1.15
		ship_count += 1

	var trail_count := 0
	for key in _trails.keys():
		if trail_count >= MAX_TRAILS: break
		var seg: Array = _trails[key]
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		seg[0] = b
		if a == b: continue
		_w_touch_rect(b, 2.0 * TRAIL_HALF_WIDTH, SPLASH_FOAM_LIFE)
		var g := (MAX_SHIPS + trail_count) * STAMP_FLOATS
		var mid := (a + b) * 0.5
		_stamp_f[g] = mid.x;      _stamp_f[g + 1] = mid.y
		_stamp_f[g + 4] = b.x;    _stamp_f[g + 5] = b.y
		_stamp_f[g + 6] = a.x;    _stamp_f[g + 7] = a.y
		_stamp_f[g + 8] = 1.0;    _stamp_f[g + 9] = 1.0
		_stamp_f[g + 10] = -TRAIL_STRENGTH
		_stamp_f[g + 11] = 0.0
		_stamp_f[g + 12] = TRAIL_HALF_WIDTH
		trail_count += 1

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
		_ship_f.to_byte_array(), _stamp_f.to_byte_array(), ship_count, trail_count,
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
	_shaders = [sim_shader, stamp_shader]
	_sim_pipeline = _rd.compute_pipeline_create(sim_shader)
	_stamp_pipeline = _rd.compute_pipeline_create(stamp_shader)

	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_wake_tex = WaveSim.array_tex(_rd, WAKE_RES, WAKE_POOL, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, usage)
	_ships_buf = _rd.storage_buffer_create(MAX_SHIPS * SHIP_FLOATS * 4)
	_stamps_buf = _rd.storage_buffer_create((MAX_SHIPS + MAX_TRAILS) * STAMP_FLOATS * 4)
	_impulses_buf = _rd.storage_buffer_create(MAX_IMPULSES * IMPULSE_FLOATS * 4)
	_wake_index_buf = _rd.storage_buffer_create(WAKE_GRID * WAKE_GRID * 4, _w_index.to_byte_array())
	_coarse.init_rd(_rd, sim_shader, _ships_buf, _impulses_buf, _wake_index_buf, _wake_tex)
	_fine.init_rd(_rd, sim_shader, _ships_buf, _impulses_buf, _wake_index_buf, _wake_tex)
	var SB := RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	_stamp_uset = _rd.uniform_set_create([
		WaveSim.uni(SB, 0, _stamps_buf), WaveSim.uni(SB, 1, _wake_index_buf),
		WaveSim.uni(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, _wake_tex),
	], stamp_shader, 0)

	_wake_wrap = Texture2DArrayRD.new(); _wake_wrap.texture_rd_rid = _wake_tex
	if ocean_material:
		ocean_material.set_shader_parameter.call_deferred("wake_array", _wake_wrap)
	_initialized = true

func _render_update(parity: int, substeps: int, cf: Dictionary, ff: Dictionary,
		wake_index: PackedByteArray, wake_clears: PackedInt32Array,
		ships: PackedByteArray, stamps: PackedByteArray, ship_count: int, trail_count: int,
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
	_coarse.dispatch(cl, _sim_pipeline, pc, cf, parity, substeps, SIM_DT, WAKE_GRAVITY, false)
	_fine.dispatch(cl, _sim_pipeline, pc, ff, parity, substeps, SIM_DT, GRAVITY, impulse_count > 0)
	if ship_count > 0 or trail_count > 0:
		var spc := PackedByteArray(); spc.resize(32)
		spc.encode_float(0, WAKE_WORLD)
		spc.encode_s32(4, WAKE_GRID)
		spc.encode_s32(8, WAKE_ORIGIN)
		spc.encode_s32(12, WAKE_RES)
		spc.encode_float(16, time)
		spc.encode_float(20, WAKE_LIFE)
		_rd.compute_list_bind_compute_pipeline(cl, _stamp_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _stamp_uset, 0)
		if ship_count > 0:
			spc.encode_s32(24, 0); spc.encode_s32(28, 64)
			_rd.compute_list_set_push_constant(cl, spc, spc.size())
			_rd.compute_list_dispatch(cl, 16, 16, ship_count)
		if trail_count > 0:
			spc.encode_s32(24, MAX_SHIPS); spc.encode_s32(28, 8)
			_rd.compute_list_set_push_constant(cl, spc, spc.size())
			_rd.compute_list_dispatch(cl, 2, 2, trail_count)
	_rd.compute_list_end()
