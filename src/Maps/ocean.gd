@tool
extends MeshInstance3D
class_name Ocean

@export var ring_quads := 256        # quads per side per level (keep divisible by 4)
@export var base_cell := 0.5       # world units / quad at the densest level
# @export var levels := 12            # LOD rings; reach = ring_quads/2 * base_cell * 2^(levels-1)
@export var draw_distance := 65536.0  # max distance at which to draw ocean; also sets LOD count via generate()
@export var skirt_depth := 12.0     # how far seam curtains hang below the surface
@export var max_wave_height := 1.0  # for the cull AABB
var levels := 0
## FFT uniforms set by the spatial shader — owned by OceanFFT, not here.
## choppiness is the only rendering param ocean.gd sets that OceanFFT doesn't touch.
@export var choppiness: float = 1.3
@export var chop_fade_near: float = 150.0
@export var chop_fade_far: float = 1200.0

@export var regenerate := false:
	set(v):
		if v: generate()

const OCEAN_SHADER := preload("res://src/Maps/ocean.gdshader")
const GRAVITY := 9.8
const WATER_Y := 0.0

const _MESH_CACHE_DIR := "user://ocean_cache/"

@export var camera: Camera3D

var waves := [
	Vector4(1.0, 0.0, 0.25, 60.0),
	Vector4(0.7, 0.7, 0.25, 31.0),
	Vector4(-0.8, 0.3, 0.20, 18.0),
]
var wave_time := 0.0
var _material: ShaderMaterial
var _snap := 2.0   # finest cell, set in generate()

var _swaves: Array = []   # height-normalized copy of `waves`

func _normalize_waves() -> Array:
	var sum_amp := 0.0
	for w: Vector4 in waves:
		sum_amp += w.z * w.w / TAU        # amplitude = steepness * wavelength / TAU
	var s := 1.0
	if sum_amp > 0.0:
		s = max_wave_height / sum_amp
	var out: Array = []
	for w: Vector4 in waves:
		out.append(Vector4(w.x, w.y, w.z * s, w.w))   # scale steepness -> scales amplitude
	return out

func _validate_property(property: Dictionary) -> void:
	if property.name in ["mesh", "material_override", "custom_aabb"]:
		property.usage &= ~PROPERTY_USAGE_STORAGE

func _mesh_cache_path() -> String:
	var h := hash(str(ring_quads) + str(base_cell) + str(draw_distance) + str(skirt_depth))
	return _MESH_CACHE_DIR + "ocean_lod_%d.res" % h

func _ready() -> void:
	var _rd = RenderingServer.get_rendering_device()
	if _rd == null:
		queue_free(); return
	# Compute levels first so the cache key and generate() both see the same value.
	levels = int(ceilf(log(draw_distance / ((ring_quads / 2.0) * base_cell)) / log(2)))
	# Skip mesh generation at runtime when a cached mesh exists for these parameters.
	# The cache is written on first game run; editor always regenerates.
	if not Engine.is_editor_hint():
		var cache_path := _mesh_cache_path()
		if FileAccess.file_exists(cache_path):
			var cached := ResourceLoader.load(cache_path) as ArrayMesh
			if cached != null:
				mesh = cached
				_setup_material()
				return
	generate()

func _setup_material() -> void:
	if _material == null:
		_material = WaveManager.get_ocean_material()
	_swaves = _normalize_waves()
	material_override = _material
	_material.set_shader_parameter("choppiness", choppiness)
	_material.set_shader_parameter("chop_fade_near", chop_fade_near)
	_material.set_shader_parameter("chop_fade_far", chop_fade_far)
	_snap = base_cell
	var n := ring_quads
	var reach := (n / 2.0) * base_cell * pow(2.0, levels - 1)
	custom_aabb = AABB(
		Vector3(-reach, -skirt_depth - max_wave_height, -reach),
		Vector3(reach * 2.0, skirt_depth + 2.0 * max_wave_height, reach * 2.0))

func generate() -> void:
	var n := ring_quads

	# Build one task descriptor per grid/skirt section with its global vi_base offset.
	# Tasks are independent and run in parallel; each returns its own packed arrays.
	var task_list: Array = []
	var vi := 0

	for L in range(levels):
		var cell  := base_cell * pow(2.0, L)
		var H     := (n / 2.0) * cell
		var mband := 2.0 * cell
		var morph := L < levels - 1
		if L == 0:
			task_list.append({k="grid", vi=vi, gx0=-n/2, gx1=n/2, gz0=-n/2, gz1=n/2,
					cell=cell, H=H, mband=mband, morph=morph})
			vi += (n + 1) * (n + 1)
		else:
			var h := n / 4
			for sec: Array[float] in [[-n/2, n/2, -n/2, -h], [-n/2, n/2, h, n/2],
					[-n/2, -h, -h, h], [h, n/2, -h, h]]:
				var nx := sec[1] - sec[0]
				var nz := sec[3] - sec[2]
				task_list.append({k="grid", vi=vi, gx0=sec[0], gx1=sec[1], gz0=sec[2], gz1=sec[3],
						cell=cell, H=H, mband=mband, morph=morph})
				vi += (nx + 1) * (nz + 1)
		if L == levels - 1:
			task_list.append({k="skirt", vi=vi, H=H, cell=cell, depth=skirt_depth})
			vi += n * 4 * 4

	var results: Array = []
	results.resize(task_list.size())

	var group_id := WorkerThreadPool.add_group_task(
		func(i: int): results[i] = _run_mesh_task(task_list[i]),
		task_list.size(), -1, true, "OceanGenerate")
	WorkerThreadPool.wait_for_group_task_completion(group_id)

	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs     := PackedVector2Array()
	var indices := PackedInt32Array()

	for r: Array in results:
		verts.append_array(r[0])
		normals.append_array(r[1])
		uvs.append_array(r[2])
		indices.append_array(r[3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am

	# Persist for subsequent runs. Editor runs always regenerate; only game runs cache.
	if not Engine.is_editor_hint():
		var dir := DirAccess.open("user://")
		if dir:
			dir.make_dir_recursive("ocean_cache")
		ResourceSaver.save(am, _mesh_cache_path())

	_setup_material()


func _run_mesh_task(t: Dictionary) -> Array:
	if t.k == "grid":
		return _fill_grid(t.vi, t.gx0, t.gx1, t.gz0, t.gz1, t.cell, t.H, t.mband, t.morph)
	return _fill_skirt(t.vi, t.H, t.cell, t.depth)


# Returns [verts, normals, uvs, indices] for one grid patch.
# vi_base is this task's starting index in the globally-merged vertex array;
# it is baked into the returned index values so the merge step is a plain append.
func _fill_grid(vi_base: int,
		gx0: int, gx1: int, gz0: int, gz1: int,
		cell: float, outer_h: float, mband: float, morph: bool) -> Array:
	var nx := gx1 - gx0
	var nz := gz1 - gz0
	if nx <= 0 or nz <= 0:
		return [PackedVector3Array(), PackedVector3Array(), PackedVector2Array(), PackedInt32Array()]
	var verts   := PackedVector3Array(); verts.resize((nx + 1) * (nz + 1))
	var normals := PackedVector3Array(); normals.resize((nx + 1) * (nz + 1))
	var uvs     := PackedVector2Array(); uvs.resize((nx + 1) * (nz + 1))
	var indices := PackedInt32Array();   indices.resize(nx * nz * 6)
	var lvi := 0
	var lii := 0
	var vrow := nx + 1
	var coarse_cell := cell * 2.0
	for iz in range(nz + 1):
		for ix in range(nx + 1):
			var px := (gx0 + ix) * cell
			var pz := (gz0 + iz) * cell
			verts[lvi]   = Vector3(px, 0.0, pz)
			normals[lvi] = Vector3.UP
			var w := 0.0
			if morph:
				var cheb := maxf(absf(px), absf(pz))
				w = clampf((cheb - (outer_h - mband)) / mband, 0.0, 1.0)
			uvs[lvi] = Vector2(w, coarse_cell)
			lvi += 1
	for iz in range(nz):
		for ix in range(nx):
			var i := vi_base + iz * vrow + ix
			indices[lii] = i;            lii += 1
			indices[lii] = i + 1;        lii += 1
			indices[lii] = i + vrow;     lii += 1
			indices[lii] = i + 1;        lii += 1
			indices[lii] = i + vrow + 1; lii += 1
			indices[lii] = i + vrow;     lii += 1
	return [verts, normals, uvs, indices]


func _fill_skirt(vi_base: int,
		half_extent: float, cell: float, depth: float) -> Array:
	var steps := int(round(2.0 * half_extent / cell))
	if steps <= 0:
		return [PackedVector3Array(), PackedVector3Array(), PackedVector2Array(), PackedInt32Array()]
	var H := half_extent
	var pts := PackedVector2Array()
	for s in range(steps): pts.append(Vector2(-H + s * cell, -H))
	for s in range(steps): pts.append(Vector2(H, -H + s * cell))
	for s in range(steps): pts.append(Vector2(H - s * cell, H))
	for s in range(steps): pts.append(Vector2(-H, H - s * cell))
	var count := pts.size()
	var verts   := PackedVector3Array(); verts.resize(count * 4)
	var normals := PackedVector3Array(); normals.resize(count * 4)
	var uvs     := PackedVector2Array(); uvs.resize(count * 4)
	var indices := PackedInt32Array();   indices.resize(count * 12)
	var uv_val := Vector2(0.0, cell * 2.0)
	var lii := 0
	for s in range(count):
		var p0 := pts[s]
		var p1 := pts[(s + 1) % count]
		var bl := s * 4
		var b  := vi_base + bl
		verts[bl]   = Vector3(p0.x, 0.0,    p0.y)
		verts[bl+1] = Vector3(p1.x, 0.0,    p1.y)
		verts[bl+2] = Vector3(p0.x, -depth, p0.y)
		verts[bl+3] = Vector3(p1.x, -depth, p1.y)
		normals[bl] = Vector3.UP; normals[bl+1] = Vector3.UP
		normals[bl+2] = Vector3.UP; normals[bl+3] = Vector3.UP
		uvs[bl] = uv_val; uvs[bl+1] = uv_val
		uvs[bl+2] = uv_val; uvs[bl+3] = uv_val
		indices[lii] = b;     lii += 1
		indices[lii] = b + 2; lii += 1
		indices[lii] = b + 1; lii += 1
		indices[lii] = b + 1; lii += 1
		indices[lii] = b + 2; lii += 1
		indices[lii] = b + 3; lii += 1
		indices[lii] = b;     lii += 1
		indices[lii] = b + 1; lii += 1
		indices[lii] = b + 2; lii += 1
		indices[lii] = b + 1; lii += 1
		indices[lii] = b + 3; lii += 1
		indices[lii] = b + 2; lii += 1
	return [verts, normals, uvs, indices]


func _process(delta: float) -> void:
	if camera == null:
		camera = get_viewport().get_camera_3d()
		return
	var c := camera.global_position
	global_position = Vector3(snappedf(c.x, _snap), WATER_Y, snappedf(c.z, _snap))
	wave_time += delta

func sample(world_xz: Vector2) -> Vector3:
	var r := Vector3.ZERO
	for w: Vector4 in _swaves:                          # was `waves`
		var dir := Vector2(w.x, w.y).normalized()
		var k := TAU / w.w
		var c := sqrt(GRAVITY / k)
		var f := k * (dir.dot(world_xz) - c * wave_time)
		var a := w.z / k
		r += Vector3(dir.x * a * cos(f), a * sin(f), dir.y * a * cos(f))
	return Vector3(world_xz.x, 0.0, world_xz.y) + r
