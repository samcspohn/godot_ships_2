extends Node
class_name OceanFFT

# =====================================================================
# OceanFFT — drives the five-pass FFT pipeline described in
# README_fft_ocean.md and exposes fft_displacement / fft_derivatives
# as Texture2DArrayRD objects on the ocean ShaderMaterial.
#
# Dispatch order each frame:
#   spectrum_update  -> 2*log2N fft_butterfly stages -> compose
# On sea-state change (rebuild_spectrum):
#   spectrum_initial runs first (separate compute list, implicit barrier)
# One-time (init):
#   butterfly_precompute
# =====================================================================

const SHADER_BUTTERFLY_PRECOMP := preload("res://src/Maps/ocean_butterfly_precompute.glsl")
const SHADER_SPEC_INITIAL      := preload("res://src/Maps/ocean_spectrum_initial.glsl")
const SHADER_SPEC_UPDATE       := preload("res://src/Maps/ocean_spectrum_update.glsl")
const SHADER_FFT_BUTTERFLY     := preload("res://src/Maps/ocean_fft_butterfly.glsl")
const SHADER_COMPOSE           := preload("res://src/Maps/ocean_compose.glsl")

const GRAVITY  := 9.81
const UBO_SIZE := 96   # OceanParams std140 layout, see README

## Material that receives fft_displacement / fft_derivatives.
## Should be the same ShaderMaterial used by the Ocean node.
@export var ocean_material: ShaderMaterial

## Grid resolution — must be a power of 2.
@export var grid_size: int = 512

## Number of active FFT cascades (≤ 4). Must match ocean.gd cascade_count.
@export var cascade_count: int = 4

## Patch size (m) per cascade, large → fine. patch_sizes[i] feeds cascade_scales[i]
## in the spatial shader. Must have at least cascade_count elements.
@export var patch_sizes: Array[float] = [2501.0, 1953.0, 737.0, 277.0]

## Per-cascade blend weight forwarded to the spatial shader's cascade_strength.
@export var cascade_strength: Array[float] = [0.8, 1.0, 1.2, 1.2]

@export_group("Sea State")
@export var wind: Vector2 = Vector2(10.0, 0.0)   # direction × speed (m/s)
@export var fetch: float = 100000.0               # fetch distance (m)
@export var depth: float = 1000.0                 # water depth (m)
@export var amplitude: float = 1.0               # global spectrum tuning
@export var suppress: float = 0.1                # small-wave suppression (m)
@export var wave_seed: int = 0
@export var rebuild_spectrum: bool = false:
	set(v):
		if v: _spectrum_dirty = true

@export_group("Output Tuning")
@export var disp_scale: float = 1.0
@export var slope_scale: float = 1.0
@export var foam_bias: float = 1.0    # J threshold for whitecap generation (tune up for more foam)
@export var foam_decay: float = 0.985 # per-frame foam fade (~1 s half-life at 60 fps)

## Changing grid_size or cascade_count requires toggling this to true.
@export var reinitialize: bool = false:
	set(v):
		if v: _reinit_pending = true

# ---- runtime state --------------------------------------------------
var _initialized    := false
var _material_bound := false
var _spectrum_dirty := true
var _reinit_pending := false
var _time           := 0.0

# ---- cached at init (read on render thread) -------------------------
var _n:      int
var _c:      int
var _log2n:  int

# ---- RenderingDevice ------------------------------------------------
var _rd: RenderingDevice

# ---- pipelines ------------------------------------------------------
var _pip_butterfly_precomp: RID
var _pip_spec_initial:      RID
var _pip_spec_update:       RID
var _pip_fft:               RID
var _pip_compose:           RID

# ---- textures -------------------------------------------------------
var _h0:           RID                            # h0(k) + conj(h0(-k))
var _a: Array[RID] = [RID(), RID(), RID()]        # ping buffers a0..a2
var _b: Array[RID] = [RID(), RID(), RID()]        # pong buffers b0..b2
var _a3:           RID                            # ping buffer for Jacobian (Jxx+i·Jzz)
var _b3:           RID                            # pong buffer for Jacobian
var _butterfly:    RID                            # twiddle table (2D, log2N × N)
var _displacement: RID                            # output — sampled by spatial shader
var _derivatives:  RID                            # output — sampled by spatial shader
var _foam:         RID                            # whitecap foam accumulation (r32f)

# ---- UBO ------------------------------------------------------------
var _ubo: RID

# ---- uniform sets ---------------------------------------------------
var _uset_spec_initial: RID
var _uset_spec_update:  RID
var _uset_fft:          RID
var _uset_compose:      RID

# ---- material wrappers (set once after init) ------------------------
var _disp_wrap:  Texture2DArrayRD
var _deriv_wrap: Texture2DArrayRD
var _foam_wrap:  Texture2DArrayRD


# =====================================================================
# Main-thread lifecycle
# =====================================================================

func _ready() -> void:
	if RenderingServer.get_rendering_device() == null:
		queue_free()


func _process(delta: float) -> void:
	_time += delta

	if _reinit_pending:
		_reinit_pending = false
		_initialized    = false
		_material_bound = false
		_spectrum_dirty = true

	if _initialized and ocean_material != null:
		# Cascade metadata must stay in sync with patch_sizes every frame.
		# Ocean._ready() re-runs generate() on each scene load and may overwrite
		# these with its own export values; re-asserting here ensures OceanFFT
		# always wins regardless of scene reload order.
		ocean_material.set_shader_parameter("cascade_count",    _c)
		ocean_material.set_shader_parameter("cascade_scales",   PackedFloat32Array(patch_sizes))
		ocean_material.set_shader_parameter("cascade_strength", PackedFloat32Array(cascade_strength))

		# Texture handles only need binding once — they point to stable RD resources.
		if not _material_bound and _disp_wrap != null:
			ocean_material.set_shader_parameter("fft_displacement", _disp_wrap)
			ocean_material.set_shader_parameter("fft_derivatives",  _deriv_wrap)
			ocean_material.set_shader_parameter("fft_foam",         _foam_wrap)
			_material_bound = true

	var ubo_bytes := PackedByteArray()
	var do_spec   := _spectrum_dirty
	if do_spec:
		ubo_bytes = _build_ubo_bytes()
		_spectrum_dirty = false

	RenderingServer.call_on_render_thread(
		_render_update.bind(_time, ubo_bytes, do_spec, disp_scale, slope_scale, foam_bias, foam_decay))


# =====================================================================
# UBO encoding — runs on main thread so exports are safe to read
# =====================================================================

func _build_ubo_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(UBO_SIZE)

	# Band limits: boundary between cascade i and i+1 at k = π / patch_sizes[i+1]
	var cut_low  := [0.0, 0.0, 0.0, 0.0]
	var cut_high := [0.0, 0.0, 0.0, 0.0]
	for i in range(min(cascade_count, 4)):
		cut_low[i]  = 0.0 if i == 0 else PI / patch_sizes[i]
		cut_high[i] = 1e6 if i == cascade_count - 1 else PI / patch_sizes[i + 1]

	# offset  0: vec4 patch_sizes
	for i in 4: b.encode_float(0  + i * 4, patch_sizes[i] if i < patch_sizes.size() else 0.0)
	# offset 16: vec4 cutoff_low
	for i in 4: b.encode_float(16 + i * 4, cut_low[i])
	# offset 32: vec4 cutoff_high
	for i in 4: b.encode_float(32 + i * 4, cut_high[i])
	# offset 48: vec2 wind
	b.encode_float(48, wind.x);  b.encode_float(52, wind.y)
	# offset 56: float fetch
	b.encode_float(56, fetch)
	# offset 60: float gravity
	b.encode_float(60, GRAVITY)
	# offset 64: float depth
	b.encode_float(64, depth)
	# offset 68: float amplitude
	b.encode_float(68, amplitude)
	# offset 72: float suppress
	b.encode_float(72, suppress)
	# offset 76: float _pad0
	b.encode_float(76, 0.0)
	# offset 80: uint seed
	b.encode_u32(80, wave_seed)
	# offset 84: int n
	b.encode_s32(84, grid_size)
	# offset 88: int cascade_count — capped to 4 (UBO uses vec4 arrays)
	b.encode_s32(88, min(cascade_count, 4))
	# offset 92: int _pad1
	b.encode_s32(92, 0)
	return b


# =====================================================================
# Render-thread helpers
# =====================================================================

func _make_uni(type: RenderingDevice.UniformType, binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	u.add_id(rid)
	return u


# 2D array texture (image2DArray). with_sampling adds SAMPLING_BIT so
# Texture2DArrayRD can wrap it for the spatial shader.
func _tex_array(fmt: RenderingDevice.DataFormat, layers: int, n: int, with_sampling: bool) -> RID:
	var tf := RDTextureFormat.new()
	tf.format       = fmt
	tf.width        = n; tf.height = n
	tf.array_layers = layers
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	tf.usage_bits   = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if with_sampling:
		tf.usage_bits |= RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
					   | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return _rd.texture_create(tf, RDTextureView.new(), [])


# Plain 2D texture (image2D) for the butterfly/twiddle table.
func _tex_2d(fmt: RenderingDevice.DataFormat, w: int, h: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.format       = fmt
	tf.width        = w; tf.height = h
	tf.array_layers = 1
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits   = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return _rd.texture_create(tf, RDTextureView.new(), [])


# =====================================================================
# RenderingDevice initialisation — runs on render thread
# =====================================================================

func _init_rd(ubo_bytes: PackedByteArray) -> void:
	_rd     = RenderingServer.get_rendering_device()
	_n      = grid_size
	_c      = min(cascade_count, 4)  # UBO arrays are vec4; >4 cascades need shader changes
	_log2n  = int(round(log(float(_n)) / log(2.0)))

	# --- Shaders & compute pipelines ---
	var sh_bp := _rd.shader_create_from_spirv(SHADER_BUTTERFLY_PRECOMP.get_spirv())
	var sh_si := _rd.shader_create_from_spirv(SHADER_SPEC_INITIAL.get_spirv())
	var sh_su := _rd.shader_create_from_spirv(SHADER_SPEC_UPDATE.get_spirv())
	var sh_fb := _rd.shader_create_from_spirv(SHADER_FFT_BUTTERFLY.get_spirv())
	var sh_co := _rd.shader_create_from_spirv(SHADER_COMPOSE.get_spirv())
	_pip_butterfly_precomp = _rd.compute_pipeline_create(sh_bp)
	_pip_spec_initial      = _rd.compute_pipeline_create(sh_si)
	_pip_spec_update       = _rd.compute_pipeline_create(sh_su)
	_pip_fft               = _rd.compute_pipeline_create(sh_fb)
	_pip_compose           = _rd.compute_pipeline_create(sh_co)

	# --- Textures ---
	var RGBA32F := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var RG32F   := RenderingDevice.DATA_FORMAT_R32G32_SFLOAT

	_h0        = _tex_array(RGBA32F, _c, _n, false)
	_butterfly = _tex_2d(RGBA32F, _log2n, _n)
	for i in 3:
		_a[i] = _tex_array(RG32F, _c, _n, false)
		_b[i] = _tex_array(RG32F, _c, _n, false)
	_a3 = _tex_array(RG32F, _c, _n, false)
	_b3 = _tex_array(RG32F, _c, _n, false)
	_displacement = _tex_array(RGBA32F, _c, _n, true)
	_derivatives  = _tex_array(RGBA32F, _c, _n, true)

	# Foam accumulation texture (r32f, cleared to 0 at startup)
	var foam_fmt := RDTextureFormat.new()
	foam_fmt.format       = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	foam_fmt.width        = _n; foam_fmt.height = _n
	foam_fmt.array_layers = _c
	foam_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	foam_fmt.usage_bits   = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
						| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
						| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
						| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_foam = _rd.texture_create(foam_fmt, RDTextureView.new(), [])
	_rd.texture_clear(_foam, Color(0, 0, 0, 0), 0, 1, 0, _c)

	# --- UBO ---
	_ubo = _rd.uniform_buffer_create(UBO_SIZE, ubo_bytes)

	# --- Uniform sets ---
	var UB := RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	var IM := RenderingDevice.UNIFORM_TYPE_IMAGE

	_uset_spec_initial = _rd.uniform_set_create([
		_make_uni(UB, 0, _ubo),
		_make_uni(IM, 1, _h0),
	], sh_si, 0)

	_uset_spec_update = _rd.uniform_set_create([
		_make_uni(UB, 0, _ubo),
		_make_uni(IM, 1, _h0),
		_make_uni(IM, 2, _a[0]),
		_make_uni(IM, 3, _a[1]),
		_make_uni(IM, 4, _a[2]),
		_make_uni(IM, 5, _a3),
	], sh_su, 0)

	_uset_fft = _rd.uniform_set_create([
		_make_uni(IM, 0, _a[0]),
		_make_uni(IM, 1, _a[1]),
		_make_uni(IM, 2, _a[2]),
		_make_uni(IM, 3, _b[0]),
		_make_uni(IM, 4, _b[1]),
		_make_uni(IM, 5, _b[2]),
		_make_uni(IM, 6, _butterfly),
		_make_uni(IM, 7, _a3),
		_make_uni(IM, 8, _b3),
	], sh_fb, 0)

	_uset_compose = _rd.uniform_set_create([
		_make_uni(IM, 0, _a[0]),
		_make_uni(IM, 1, _a[1]),
		_make_uni(IM, 2, _a[2]),
		_make_uni(IM, 3, _displacement),
		_make_uni(IM, 4, _derivatives),
		_make_uni(IM, 5, _a3),
		_make_uni(IM, 6, _foam),
	], sh_co, 0)

	# --- Butterfly precompute (one-time, its own compute list) ---
	var uset_bp := _rd.uniform_set_create([
		_make_uni(IM, 0, _butterfly),
	], sh_bp, 0)
	var pc_bp := PackedByteArray(); pc_bp.resize(16)
	pc_bp.encode_s32(0, _n); pc_bp.encode_s32(4, _log2n)
	var cl_bp := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_bp, _pip_butterfly_precomp)
	_rd.compute_list_bind_uniform_set(cl_bp, uset_bp, 0)
	_rd.compute_list_set_push_constant(cl_bp, pc_bp, 16)
	_rd.compute_list_dispatch(cl_bp, _log2n, _n >> 4, 1)
	_rd.compute_list_end()

	# --- Texture wrappers for the spatial shader ---
	_disp_wrap = Texture2DArrayRD.new()
	_disp_wrap.texture_rd_rid = _displacement
	_deriv_wrap = Texture2DArrayRD.new()
	_deriv_wrap.texture_rd_rid = _derivatives
	_foam_wrap = Texture2DArrayRD.new()
	_foam_wrap.texture_rd_rid = _foam

	_initialized = true


# =====================================================================
# Per-frame render work — runs on render thread
# =====================================================================

func _render_update(time: float, ubo_bytes: PackedByteArray,
		do_spec: bool, ds: float, ss: float, fb: float, fd: float) -> void:
	if not _initialized:
		_init_rd(ubo_bytes)
		ubo_bytes = PackedByteArray()   # already consumed by _init_rd
		do_spec   = true                # always run spectrum_initial after init

	if not ubo_bytes.is_empty():
		_rd.buffer_update(_ubo, 0, UBO_SIZE, ubo_bytes)

	var g := _n >> 4
	var cl := _rd.compute_list_begin()

	# spectrum_initial — only on sea-state change; must share list with spectrum_update
	# so compute_list_add_barrier() can guarantee h0_tex writes are visible.
	if do_spec:
		_rd.compute_list_bind_compute_pipeline(cl, _pip_spec_initial)
		_rd.compute_list_bind_uniform_set(cl, _uset_spec_initial, 0)
		_rd.compute_list_dispatch(cl, g, g, _c)
		_rd.compute_list_add_barrier(cl)

	# 1. spectrum_update — evolves h(k,t) and packs displacement/slope spectra
	var pc_su := PackedByteArray(); pc_su.resize(16)
	pc_su.encode_float(0, time)
	_rd.compute_list_bind_compute_pipeline(cl, _pip_spec_update)
	_rd.compute_list_bind_uniform_set(cl, _uset_spec_update, 0)
	_rd.compute_list_set_push_constant(cl, pc_su, 16)
	_rd.compute_list_dispatch(cl, g, g, _c)
	_rd.compute_list_add_barrier(cl)

	# 2. FFT butterfly — 2 * log2N stages (horizontal then vertical)
	for step in range(2 * _log2n):
		var direction := 0 if step < _log2n else 1
		var stage_i   := step if step < _log2n else step - _log2n
		var ping_pong := step & 1
		var pc_fft := PackedByteArray(); pc_fft.resize(16)
		pc_fft.encode_s32(0, stage_i)
		pc_fft.encode_s32(4, direction)
		pc_fft.encode_s32(8, ping_pong)
		_rd.compute_list_bind_compute_pipeline(cl, _pip_fft)
		_rd.compute_list_bind_uniform_set(cl, _uset_fft, 0)
		_rd.compute_list_set_push_constant(cl, pc_fft, 16)
		_rd.compute_list_dispatch(cl, g, g, _c)
		_rd.compute_list_add_barrier(cl)

	# 3. compose — unpacks IFFT result, fills derivatives.ba, accumulates foam
	var pc_co := PackedByteArray(); pc_co.resize(16)
	pc_co.encode_float(0, ds);  pc_co.encode_float(4, ss)
	pc_co.encode_float(8, fb);  pc_co.encode_float(12, fd)
	_rd.compute_list_bind_compute_pipeline(cl, _pip_compose)
	_rd.compute_list_bind_uniform_set(cl, _uset_compose, 0)
	_rd.compute_list_set_push_constant(cl, pc_co, 16)
	_rd.compute_list_dispatch(cl, g, g, _c)

	_rd.compute_list_end()
