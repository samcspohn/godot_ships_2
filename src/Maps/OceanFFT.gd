extends Node
class_name OceanFFT

const SHADER_BUTTERFLY_PRECOMP := preload("res://src/Maps/ocean_butterfly_precompute.glsl")
const SHADER_SPEC_INITIAL      := preload("res://src/Maps/ocean_spectrum_initial.glsl")
const SHADER_SPEC_UPDATE       := preload("res://src/Maps/ocean_spectrum_update.glsl")
const SHADER_FFT               := preload("res://src/Maps/ocean_fft_shared.glsl")
const SHADER_COMPOSE           := preload("res://src/Maps/ocean_compose.glsl")
const SHADER_MIP               := preload("res://src/Maps/ocean_mip.glsl")

const GRAVITY  := 9.81
const UBO_SIZE := 128
const SLOPE_TABLE := 256

@export var ocean_material: ShaderMaterial
@export var grid_size: int = 256
@export var cascade_count: int = 4
## Near-prime ratios (~4.2) so cascade periods never line up.
@export var patch_sizes: Array[float] = [1531.0, 373.0, 89.0, 21.0]
@export var cascade_strength: Array[float] = [1.0, 1.0, 1.0, 1.0]
## Band edge between cascade i and i+1 sits at this many fundamentals of cascade i+1.
@export var band_split: float = 6.0

@export_group("Wind Sea")
@export var wind: Vector2 = Vector2(8.0, 3.0)
@export var fetch: float = 200000.0
@export var wind_spread: float = 2.0
@export_group("Swell")
@export var swell: Vector2 = Vector2(6.0, 13.0)
@export var swell_fetch: float = 1000000.0
@export var swell_amount: float = 0.008
@export var swell_spread: float = 16.0
@export_group("Sea State")
@export var depth: float = 1000.0
@export var amplitude: float = 0.85
@export var suppress: float = 0.05
@export var wave_seed: int = 0
@export var rebuild_spectrum: bool = false:
	set(v):
		if v: _spectrum_dirty = true

@export_group("Output Tuning")
@export var disp_scale: float = 1.0
@export var slope_scale: float = 1.0

var _initialized    := false
var _material_bound := false
var _spectrum_dirty := true
var _time           := 0.0

var _n:      int
var _c:      int
var _log2n:  int
var _mips:   int

var _rd: RenderingDevice
var _shaders: Array[RID] = []

var _pip_butterfly_precomp: RID
var _pip_spec_initial:      RID
var _pip_spec_update:       RID
var _pip_fft:               RID
var _pip_compose:           RID
var _pip_mip:               RID

var _h0:           RID
var _a: Array[RID] = [RID(), RID(), RID()]
var _b: Array[RID] = [RID(), RID(), RID()]
var _a3:           RID
var _b3:           RID
var _butterfly:    RID
var _displacement: RID
var _derivatives:  RID
var _disp_mipped:  RID
var _deriv_mipped: RID

var _ubo: RID

var _uset_spec_initial: RID
var _uset_spec_update:  RID
var _uset_fft:          RID
var _uset_compose:      RID
var _uset_mip: Array[RID] = []   # index = mip * _c + layer

var _disp_wrap:  Texture2DArrayRD
var _deriv_wrap: Texture2DArrayRD
var _slope_tex:  ImageTexture


func _ready() -> void:
	if RenderingServer.get_rendering_device() == null:
		queue_free()
		return
	RenderingServer.call_on_render_thread(_init_rd.bind(_build_ubo_bytes()))


func _exit_tree() -> void:
	if not _initialized: return
	_initialized = false
	if ocean_material:
		ocean_material.set_shader_parameter("fft_displacement", null)
		ocean_material.set_shader_parameter("fft_derivatives", null)
	_disp_wrap.texture_rd_rid = RID()
	_deriv_wrap.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_free_rd)


# Freeing a base resource also frees its slices, uniform sets and pipelines.
func _free_rd() -> void:
	for t: RID in [_h0, _butterfly, _a[0], _a[1], _a[2], _b[0], _b[1], _b[2], _a3, _b3,
			_displacement, _derivatives, _disp_mipped, _deriv_mipped, _ubo]:
		if t.is_valid(): _rd.free_rid(t)
	for sh in _shaders: _rd.free_rid(sh)
	_shaders.clear()


func _process(delta: float) -> void:
	_time += delta

	if _initialized and ocean_material != null and not _material_bound:
		ocean_material.set_shader_parameter("fft_displacement", _disp_wrap)
		ocean_material.set_shader_parameter("fft_derivatives",  _deriv_wrap)
		_material_bound = true

	var ubo_bytes := PackedByteArray()
	var do_spec   := _spectrum_dirty
	if do_spec:
		ubo_bytes = _build_ubo_bytes()
		_spectrum_dirty = false
		_push_material_params()

	RenderingServer.call_on_render_thread(
		_render_update.bind(_time, ubo_bytes, do_spec, disp_scale, slope_scale))


func _push_material_params() -> void:
	if ocean_material == null: return
	var c := mini(cascade_count, 4)
	ocean_material.set_shader_parameter("cascade_count",    c)
	ocean_material.set_shader_parameter("cascade_scales",   PackedFloat32Array(patch_sizes))
	ocean_material.set_shader_parameter("cascade_strength", PackedFloat32Array(cascade_strength))
	ocean_material.set_shader_parameter("fft_size",         float(grid_size))
	var table := _slope_variance_table()
	var img := Image.create_from_data(SLOPE_TABLE, 1, false, Image.FORMAT_RF, table[0].to_byte_array())
	if _slope_tex == null: _slope_tex = ImageTexture.create_from_image(img)
	else: _slope_tex.update(img)
	ocean_material.set_shader_parameter("slope_var_tex",   _slope_tex)
	ocean_material.set_shader_parameter("slope_var_range", table[1])


func _band(i: int) -> Vector2:
	var lo := 0.0 if i == 0 else TAU / patch_sizes[i] * band_split
	var hi := 1e6 if i == mini(cascade_count, 4) - 1 else TAU / patch_sizes[i + 1] * band_split
	return Vector2(lo, hi)


func _spread_norm(s: float) -> float:
	# 1 / ∫cos^s over the forward half-plane
	var a := s * 0.5 + 0.5
	var b := s * 0.5 + 1.0
	return exp(_lgamma(b) - _lgamma(a)) / sqrt(PI)


func _lgamma(x: float) -> float:
	var r := 0.0
	while x < 7.0:
		r -= log(x); x += 1.0
	var x2 := 1.0 / (x * x)
	return r + (x - 0.5) * log(x) - x + 0.5 * log(TAU) \
		+ (1.0 / 12.0 - x2 * (1.0 / 360.0 - x2 / 1260.0)) / x


# Omnidirectional S(k); must match spectrum() in ocean_spectrum_initial.glsl.
func _jonswap_k(k: float, u: float, f: float, gamma: float) -> float:
	if u < 1e-3 or k < 1e-6: return 0.0
	var om := sqrt(GRAVITY * k)
	var xi := GRAVITY * f / (u * u)
	var om_p := 22.0 * pow(GRAVITY * GRAVITY / (u * f), 1.0 / 3.0)
	var alpha := 0.076 * pow(xi, -0.22)
	var sigma := 0.07 if om <= om_p else 0.09
	var r := exp(-((om - om_p) * (om - om_p)) / (2.0 * sigma * sigma * om_p * om_p))
	var s_om := alpha * GRAVITY * GRAVITY / pow(om, 5.0) * exp(-1.25 * pow(om_p / om, 4.0)) * pow(gamma, r)
	return s_om * GRAVITY / (2.0 * om)


# [cumulative slope variance above k on a log2(k) axis, Vector2(log2 kmin, log2 kmax)].
# Feeds the fragment shader's roughness for detail lost below the pixel footprint.
func _slope_variance_table() -> Array:
	var c := mini(cascade_count, 4)
	var kmin := TAU / patch_sizes[0]
	var kmax := PI * grid_size / patch_sizes[c - 1]
	var l0 := log(kmin) / log(2.0)
	var l1 := log(kmax) / log(2.0)
	var dens := PackedFloat32Array(); dens.resize(SLOPE_TABLE)
	var gain := 2.0 * pow(amplitude * slope_scale, 2.0)
	for i in SLOPE_TABLE:
		var k := pow(2.0, lerpf(l0, l1, (i + 0.5) / SLOPE_TABLE))
		var s := _jonswap_k(k, wind.length(), fetch, 3.3) + swell_amount * _jonswap_k(k, swell.length(), swell_fetch, 7.0)
		s *= exp(-k * k * suppress * suppress)
		var strength := 0.0
		for j in c:
			var band := _band(j)
			if k >= band.x and k < band.y: strength = cascade_strength[j]
		var dk := k * log(2.0) * (l1 - l0) / SLOPE_TABLE
		dens[i] = k * k * s * dk * gain * strength * strength
	var cum := PackedFloat32Array(); cum.resize(SLOPE_TABLE)
	var acc := 0.0
	for i in range(SLOPE_TABLE - 1, -1, -1):
		acc += dens[i]
		cum[i] = acc
	return [cum, Vector2(l0, l1)]


func _build_ubo_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(UBO_SIZE)
	var c := mini(cascade_count, 4)
	for i in 4:
		var band := _band(i) if i < c else Vector2.ZERO
		b.encode_float(i * 4, patch_sizes[i] if i < patch_sizes.size() else 0.0)
		b.encode_float(16 + i * 4, band.x)
		b.encode_float(32 + i * 4, band.y)
	b.encode_float(48, wind.x);  b.encode_float(52, wind.y)
	b.encode_float(56, fetch)
	b.encode_float(60, GRAVITY)
	b.encode_float(64, depth)
	b.encode_float(68, amplitude)
	b.encode_float(72, suppress)
	b.encode_float(76, wind_spread)
	b.encode_float(80, swell.x); b.encode_float(84, swell.y)
	b.encode_float(88, swell_fetch)
	b.encode_float(92, swell_amount)
	b.encode_float(96, swell_spread)
	b.encode_float(100, _spread_norm(wind_spread))
	b.encode_float(104, _spread_norm(swell_spread))
	b.encode_u32(112, wave_seed)
	b.encode_s32(116, grid_size)
	b.encode_s32(120, c)
	return b


func _make_uni(type: RenderingDevice.UniformType, binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	u.add_id(rid)
	return u


func _tex_array(fmt: RenderingDevice.DataFormat, layers: int, n: int, mips := 1) -> RID:
	var tf := RDTextureFormat.new()
	tf.format       = fmt
	tf.width        = n; tf.height = n
	tf.array_layers = layers
	tf.mipmaps      = mips
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	tf.usage_bits   = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if mips > 1:
		tf.usage_bits |= RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var t := _rd.texture_create(tf, RDTextureView.new(), [])
	_rd.texture_clear(t, Color(0, 0, 0, 0), 0, mips, 0, layers)
	return t


func _tex_2d(fmt: RenderingDevice.DataFormat, w: int, h: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.format       = fmt
	tf.width        = w; tf.height = h
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits   = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return _rd.texture_create(tf, RDTextureView.new(), [])


func _slice(tex: RID, layer: int, mip: int) -> RID:
	return _rd.texture_create_shared_from_slice(RDTextureView.new(), tex, layer, mip, 1, RenderingDevice.TEXTURE_SLICE_2D)


func _init_rd(ubo_bytes: PackedByteArray) -> void:
	_rd     = RenderingServer.get_rendering_device()
	_n      = grid_size
	_c      = mini(cascade_count, 4)
	_log2n  = int(round(log(float(_n)) / log(2.0)))
	_mips   = _log2n + 1

	if _n != 256:
		push_error("OceanFFT: ocean_fft_shared.glsl is built for grid_size 256")
	var sh_bp := _rd.shader_create_from_spirv(SHADER_BUTTERFLY_PRECOMP.get_spirv())
	var sh_si := _rd.shader_create_from_spirv(SHADER_SPEC_INITIAL.get_spirv())
	var sh_su := _rd.shader_create_from_spirv(SHADER_SPEC_UPDATE.get_spirv())
	var sh_fb := _rd.shader_create_from_spirv(SHADER_FFT.get_spirv())
	var sh_co := _rd.shader_create_from_spirv(SHADER_COMPOSE.get_spirv())
	var sh_mip := _rd.shader_create_from_spirv(SHADER_MIP.get_spirv())
	_shaders = [sh_bp, sh_si, sh_su, sh_fb, sh_co, sh_mip]
	_pip_butterfly_precomp = _rd.compute_pipeline_create(sh_bp)
	_pip_spec_initial      = _rd.compute_pipeline_create(sh_si)
	_pip_spec_update       = _rd.compute_pipeline_create(sh_su)
	_pip_fft               = _rd.compute_pipeline_create(sh_fb)
	_pip_compose           = _rd.compute_pipeline_create(sh_co)
	_pip_mip               = _rd.compute_pipeline_create(sh_mip)

	var RGBA32F := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var RGBA16F := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var RG32F   := RenderingDevice.DATA_FORMAT_R32G32_SFLOAT

	_h0        = _tex_array(RGBA32F, _c, _n)
	_butterfly = _tex_2d(RGBA32F, _log2n, _n)
	for i in 3:
		_a[i] = _tex_array(RG32F, _c, _n)
		_b[i] = _tex_array(RG32F, _c, _n)
	_a3 = _tex_array(RG32F, _c, _n)
	_b3 = _tex_array(RG32F, _c, _n)
	_displacement = _tex_array(RGBA16F, _c, _n)
	_derivatives  = _tex_array(RGBA16F, _c, _n)
	# Compute writes go to the unmipped textures; the mip pass copies level 0 and
	# downsamples into these, so storage views never span more than one mip.
	_disp_mipped  = _tex_array(RGBA16F, _c, _n, _mips)
	_deriv_mipped = _tex_array(RGBA16F, _c, _n, _mips)

	_ubo = _rd.uniform_buffer_create(UBO_SIZE, ubo_bytes)

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
		_make_uni(IM, 3, _a3),
		_make_uni(IM, 4, _b[0]),
		_make_uni(IM, 5, _b[1]),
		_make_uni(IM, 6, _b[2]),
		_make_uni(IM, 7, _b3),
		_make_uni(IM, 8, _butterfly),
	], sh_fb, 0)

	_uset_compose = _rd.uniform_set_create([
		_make_uni(IM, 0, _a[0]),
		_make_uni(IM, 1, _a[1]),
		_make_uni(IM, 2, _a[2]),
		_make_uni(IM, 3, _displacement),
		_make_uni(IM, 4, _derivatives),
		_make_uni(IM, 5, _a3),
	], sh_co, 0)

	_uset_mip.clear()
	for m in _mips:
		for l in _c:
			var srcs := [_slice(_displacement, l, 0), _slice(_derivatives, l, 0)] if m == 0 \
				else [_slice(_disp_mipped, l, m - 1), _slice(_deriv_mipped, l, m - 1)]
			_uset_mip.append(_rd.uniform_set_create([
				_make_uni(IM, 0, srcs[0]),
				_make_uni(IM, 1, _slice(_disp_mipped, l, m)),
				_make_uni(IM, 2, srcs[1]),
				_make_uni(IM, 3, _slice(_deriv_mipped, l, m)),
			], sh_mip, 0))

	var uset_bp := _rd.uniform_set_create([
		_make_uni(IM, 0, _butterfly),
	], sh_bp, 0)
	var pc_bp := PackedByteArray(); pc_bp.resize(8)
	pc_bp.encode_s32(0, _n); pc_bp.encode_s32(4, _log2n)
	var cl_bp := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_bp, _pip_butterfly_precomp)
	_rd.compute_list_bind_uniform_set(cl_bp, uset_bp, 0)
	_rd.compute_list_set_push_constant(cl_bp, pc_bp, 8)
	_rd.compute_list_dispatch(cl_bp, _log2n, _n >> 4, 1)
	_rd.compute_list_end()

	_disp_wrap = Texture2DArrayRD.new()
	_disp_wrap.texture_rd_rid = _disp_mipped
	_deriv_wrap = Texture2DArrayRD.new()
	_deriv_wrap.texture_rd_rid = _deriv_mipped

	_initialized = true


func _render_update(time: float, ubo_bytes: PackedByteArray,
		do_spec: bool, ds: float, ss: float) -> void:
	if not _initialized:
		_init_rd(ubo_bytes)
		ubo_bytes = PackedByteArray()
		do_spec   = true

	if not ubo_bytes.is_empty():
		_rd.buffer_update(_ubo, 0, UBO_SIZE, ubo_bytes)

	var g := _n >> 4
	var cl := _rd.compute_list_begin()

	if do_spec:
		_rd.compute_list_bind_compute_pipeline(cl, _pip_spec_initial)
		_rd.compute_list_bind_uniform_set(cl, _uset_spec_initial, 0)
		_rd.compute_list_dispatch(cl, g, g, _c)
		_rd.compute_list_add_barrier(cl)

	var pc_su := PackedByteArray(); pc_su.resize(4)
	pc_su.encode_float(0, time)
	_rd.compute_list_bind_compute_pipeline(cl, _pip_spec_update)
	_rd.compute_list_bind_uniform_set(cl, _uset_spec_update, 0)
	_rd.compute_list_set_push_constant(cl, pc_su, 4)
	_rd.compute_list_dispatch(cl, g, g, _c)
	_rd.compute_list_add_barrier(cl)

	var pc_fft := PackedByteArray(); pc_fft.resize(16)
	pc_fft.encode_s32(4, _log2n)
	_rd.compute_list_bind_compute_pipeline(cl, _pip_fft)
	_rd.compute_list_bind_uniform_set(cl, _uset_fft, 0)
	for direction in 2:
		pc_fft.encode_s32(0, direction)
		_rd.compute_list_set_push_constant(cl, pc_fft, 16)
		_rd.compute_list_dispatch(cl, _n, 1, _c)
		_rd.compute_list_add_barrier(cl)

	var pc_co := PackedByteArray(); pc_co.resize(16)
	pc_co.encode_float(0, ds);  pc_co.encode_float(4, ss)
	_rd.compute_list_bind_compute_pipeline(cl, _pip_compose)
	_rd.compute_list_bind_uniform_set(cl, _uset_compose, 0)
	_rd.compute_list_set_push_constant(cl, pc_co, 16)
	_rd.compute_list_dispatch(cl, g, g, _c)
	_rd.compute_list_add_barrier(cl)

	var pc_mip := PackedByteArray(); pc_mip.resize(16)
	_rd.compute_list_bind_compute_pipeline(cl, _pip_mip)
	for m in _mips:
		var size := _n >> m
		pc_mip.encode_s32(0, size)
		pc_mip.encode_s32(4, 1 if m == 0 else 0)
		var groups := maxi((size + 7) / 8, 1)
		for l in _c:
			_rd.compute_list_bind_uniform_set(cl, _uset_mip[m * _c + l], 0)
			_rd.compute_list_set_push_constant(cl, pc_mip, 16)
			_rd.compute_list_dispatch(cl, groups, groups, 1)
		if m + 1 < _mips:
			_rd.compute_list_add_barrier(cl)

	_rd.compute_list_end()
