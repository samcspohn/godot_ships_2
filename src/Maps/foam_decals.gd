extends RefCounted
class_name FoamDecals

## Foam events drawn as instanced quads into three camera-following cascades
## (RGBA8: r = signed reveal margin * 0.5 + 0.5, g = bubbles, b = (opacity gain - 1) / 2; max-blended), redrawn each frame.

const CAPACITY := 16384
const FLOATS := 24
const RES := 2048
const TEXELS: Array[float] = [0.5, 2.0, 8.0]
const ZOOM_FOV := 20.0          # narrower than this centres every cascade on the aim point
const AHEAD := 0.35             # cascade centre ahead of the camera, in extents
const SHADER := preload("res://src/Maps/foam_decal.glsl")

var origins: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
var wrap: Texture2DArrayRD

var _mirror := PackedFloat32Array()
var _head := 0
var _written := 0
var _dirty_lo := -1
var _dirty_n := 0

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex: RID
var _buf: RID
var _sampler: RID
var _uset: RID
var _fbs: Array[RID] = []


func _init() -> void:
	_mirror.resize(CAPACITY * FLOATS)

func add(pos: Vector2, r0: float, r1: float, grow: float, life: float, birth: float,
		strength: float, bubbles: float, fade_pow: float, tile_a: float, tile_b: float, hull := Vector4.ZERO, blast := false, opacity := 1.0, fade_in := 0.0, speed := 0.0) -> void:
	var slot := _head
	_head = (_head + 1) % CAPACITY
	_written = mini(_written + 1, CAPACITY)
	var f := slot * FLOATS
	_mirror[f] = pos.x;          _mirror[f + 1] = pos.y
	_mirror[f + 2] = r0;         _mirror[f + 3] = r1
	_mirror[f + 4] = birth;      _mirror[f + 5] = life
	_mirror[f + 6] = grow;       _mirror[f + 7] = randf() * TAU
	_mirror[f + 8] = strength;   _mirror[f + 9] = bubbles
	_mirror[f + 10] = fade_pow;  _mirror[f + 11] = randf()
	_mirror[f + 12] = hull.x;    _mirror[f + 13] = hull.y
	_mirror[f + 14] = hull.z;    _mirror[f + 15] = hull.w
	_mirror[f + 16] = tile_a;    _mirror[f + 17] = tile_b
	_mirror[f + 18] = 1.0 if blast else 0.0
	_mirror[f + 20] = opacity
	_mirror[f + 21] = fade_in;   _mirror[f + 22] = speed
	if _dirty_n == 0: _dirty_lo = slot
	_dirty_n = mini(_dirty_n + 1, CAPACITY)

func extent(level: int) -> float:
	return TEXELS[level] * RES

func place(cam: Camera3D) -> void:
	if not is_instance_valid(cam): return
	var xf := cam.global_transform
	var c := Vector2(xf.origin.x, xf.origin.z)
	var dir := -xf.basis.z
	var flat := Vector2(dir.x, dir.z)
	var fwd := flat.normalized() if flat.length_squared() > 1e-6 else Vector2.ZERO
	var focus_d := INF
	if dir.y < -1e-3:
		focus_d = flat.length() * (xf.origin.y / -dir.y)
	for i in 3:
		var e := extent(i)
		var ahead := focus_d if cam.fov < ZOOM_FOV and focus_d < INF else minf(focus_d, e * AHEAD)
		var centre := c + fwd * ahead
		origins[i] = ((centre - Vector2(e, e) * 0.5) / TEXELS[i]).floor() * TEXELS[i]

## Snapshot for the render thread; clears the pending upload.
func take_frame(time: float, drift: Vector2, churn_scale: float, churn_edge: float) -> Dictionary:
	var ranges := []
	if _dirty_n > 0:
		var first := mini(_dirty_n, CAPACITY - _dirty_lo)
		ranges.append([_dirty_lo, _mirror.slice(_dirty_lo * FLOATS, (_dirty_lo + first) * FLOATS).to_byte_array()])
		if _dirty_n > first:
			ranges.append([0, _mirror.slice(0, (_dirty_n - first) * FLOATS).to_byte_array()])
	_dirty_n = 0
	return {ranges = ranges, count = _written, origins = origins.duplicate(), time = time,
		drift = drift, churn_scale = churn_scale, churn_edge = churn_edge}


# ---------------------------------------------------------------- render thread

func init_rd(rd: RenderingDevice, foam_rd_tex: RID) -> void:
	_rd = rd
	_shader = rd.shader_create_from_spirv(SHADER.get_spirv())
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	tf.width = RES
	tf.height = RES
	tf.array_layers = 3
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_tex = rd.texture_create(tf, RDTextureView.new())
	for i in 3:
		var layer := rd.texture_create_shared_from_slice(RDTextureView.new(), _tex, i, 0)
		_fbs.append(rd.framebuffer_create([layer]))
	_buf = rd.storage_buffer_create(CAPACITY * FLOATS * 4)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.max_lod = 16.0
	_sampler = rd.sampler_create(ss)
	var u_buf := RDUniform.new()
	u_buf.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_buf.binding = 0
	u_buf.add_id(_buf)
	var u_tex := RDUniform.new()
	u_tex.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_tex.binding = 1
	u_tex.add_id(_sampler)
	u_tex.add_id(foam_rd_tex)
	_uset = rd.uniform_set_create([u_buf, u_tex], _shader, 0)

	var blend := RDPipelineColorBlendState.new()
	var att := RDPipelineColorBlendStateAttachment.new()
	att.enable_blend = true
	att.color_blend_op = RenderingDevice.BLEND_OP_MAXIMUM
	att.alpha_blend_op = RenderingDevice.BLEND_OP_MAXIMUM
	blend.attachments = [att]
	_pipeline = rd.render_pipeline_create(_shader, rd.framebuffer_get_format(_fbs[0]), RenderingDevice.INVALID_FORMAT_ID,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLE_STRIPS, RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend)
	wrap = Texture2DArrayRD.new()
	wrap.texture_rd_rid = _tex

func render(f: Dictionary) -> void:
	if _pipeline == RID(): return
	for r in f.ranges:
		_rd.buffer_update(_buf, r[0] * FLOATS * 4, r[1].size(), r[1])
	var pc := PackedByteArray(); pc.resize(32)
	pc.encode_float(12, f.time)
	pc.encode_float(16, f.drift.x)
	pc.encode_float(20, f.drift.y)
	pc.encode_float(24, f.churn_scale)
	pc.encode_float(28, f.churn_edge)
	for i in 3:
		pc.encode_float(0, f.origins[i].x)
		pc.encode_float(4, f.origins[i].y)
		pc.encode_float(8, extent(i))
		var dl := _rd.draw_list_begin(_fbs[i], RenderingDevice.DRAW_CLEAR_COLOR_0, PackedColorArray([Color(0, 0, 0, 0)]))
		if f.count > 0:
			_rd.draw_list_bind_render_pipeline(dl, _pipeline)
			_rd.draw_list_bind_uniform_set(dl, _uset, 0)
			_rd.draw_list_set_push_constant(dl, pc, pc.size())
			_rd.draw_list_draw(dl, false, f.count, 4)
		_rd.draw_list_end()

# Freeing the shader frees the pipeline and uniform set; the base texture frees its slices and framebuffers.
func free_rd() -> void:
	if _rd == null: return
	if wrap: wrap.texture_rd_rid = RID()
	for r: RID in [_tex, _buf, _sampler, _shader]:
		if r.is_valid(): _rd.free_rid(r)
	_fbs.clear()
