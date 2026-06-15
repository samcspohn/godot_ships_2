@tool
extends MeshInstance3D
class_name Ocean

@export var ring_quads := 256        # quads per side per level (keep divisible by 4)
@export var base_cell := 2.0        # world units / quad at the densest level
@export var levels := 12            # LOD rings; reach = ring_quads/2 * base_cell * 2^(levels-1)
@export var skirt_depth := 12.0     # how far seam curtains hang below the surface
@export var max_wave_height := 1.0  # for the cull AABB
@export var regenerate := false:
	set(v):
		if v: generate()

const OCEAN_SHADER := preload("res://src/Maps/ocean.gdshader")
const GRAVITY := 9.8
const WATER_Y := 0.0

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
	
func _ready() -> void:
	generate()
func generate() -> void:
	var n := ring_quads
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for L in range(levels):
		var cell := base_cell * pow(2.0, L)
		var H := (n / 2.0) * cell
		var mband := 2.0 * cell                 # morph over the outer one coarse-cell
		var morph := L < levels - 1             # outermost has nothing coarser to match
		if L == 0:
			_add_grid(verts, normals, uvs, indices, -n/2, n/2, -n/2, n/2, cell, H, mband, morph)
		else:
			var h := n / 4
			_add_grid(verts, normals, uvs, indices, -n/2, n/2, -n/2, -h, cell, H, mband, morph)
			_add_grid(verts, normals, uvs, indices, -n/2, n/2,  h,  n/2, cell, H, mband, morph)
			_add_grid(verts, normals, uvs, indices, -n/2, -h,  -h, h,   cell, H, mband, morph)
			_add_grid(verts, normals, uvs, indices,  h,  n/2,  -h, h,   cell, H, mband, morph)
		if L == levels - 1:
			_add_skirt(verts, normals, uvs, indices, H, cell, skirt_depth)  # only the horizon edge

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am

	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = OCEAN_SHADER
		_material.render_priority = -1
	_swaves = _normalize_waves()
	material_override = _material
	_material.set_shader_parameter("waves", _swaves)   # was `waves`

	_snap = base_cell
	var reach := (n / 2.0) * base_cell * pow(2.0, levels - 1)
	custom_aabb = AABB(
		Vector3(-reach, -skirt_depth - max_wave_height, -reach),
		Vector3(reach * 2.0, skirt_depth + 2.0 * max_wave_height, reach * 2.0))

func _add_grid(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		gx0: int, gx1: int, gz0: int, gz1: int,
		cell: float, outer_h: float, mband: float, morph: bool) -> void:
	var nx := gx1 - gx0
	var nz := gz1 - gz0
	if nx <= 0 or nz <= 0:
		return
	var base := verts.size()
	var vrow := nx + 1
	var coarse_cell := cell * 2.0
	for iz in range(nz + 1):
		for ix in range(nx + 1):
			var px := (gx0 + ix) * cell
			var pz := (gz0 + iz) * cell
			verts.append(Vector3(px, 0.0, pz))
			normals.append(Vector3.UP)
			var w := 0.0
			if morph:
				var cheb := maxf(absf(px), absf(pz))   # square-ring distance to center
				w = clampf((cheb - (outer_h - mband)) / mband, 0.0, 1.0)
			uvs.append(Vector2(w, coarse_cell))        # x = morph weight, y = coarse cell
	for iz in range(nz):
		for ix in range(nx):
			var i := base + iz * vrow + ix
			indices.append(i); indices.append(i + 1); indices.append(i + vrow)
			indices.append(i + 1); indices.append(i + vrow + 1); indices.append(i + vrow)

func _add_skirt(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		half_extent: float, cell: float, depth: float) -> void:
	var steps := int(round(2.0 * half_extent / cell))
	if steps <= 0:
		return
	var H := half_extent
	var pts := PackedVector2Array()
	for s in range(steps): pts.append(Vector2(-H + s * cell, -H))
	for s in range(steps): pts.append(Vector2(H, -H + s * cell))
	for s in range(steps): pts.append(Vector2(H - s * cell, H))
	for s in range(steps): pts.append(Vector2(-H, H - s * cell))
	var count := pts.size()
	for s in range(count):
		var p0 := pts[s]
		var p1 := pts[(s + 1) % count]
		var b := verts.size()
		verts.append(Vector3(p0.x, 0.0, p0.y))
		verts.append(Vector3(p1.x, 0.0, p1.y))
		verts.append(Vector3(p0.x, -depth, p0.y))
		verts.append(Vector3(p1.x, -depth, p1.y))
		for _k in range(4):
			normals.append(Vector3.UP)
			uvs.append(Vector2(0.0, cell * 2.0))   # skirts never morph
		indices.append(b); indices.append(b + 2); indices.append(b + 1)
		indices.append(b + 1); indices.append(b + 2); indices.append(b + 3)
		indices.append(b); indices.append(b + 1); indices.append(b + 2)
		indices.append(b + 1); indices.append(b + 3); indices.append(b + 2)
func _process(delta: float) -> void:
	if camera == null:
		camera = get_viewport().get_camera_3d()
		return
	var c := camera.global_position
	global_position = Vector3(snappedf(c.x, _snap), WATER_Y, snappedf(c.z, _snap))
	wave_time += delta
	if _material:
		_material.set_shader_parameter("wave_time", wave_time)

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
