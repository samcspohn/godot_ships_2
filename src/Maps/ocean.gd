extends Node3D
class_name Ocean

@export var ring_quads := 256        # quads per level side; divisible by 8
@export var base_cell := 0.5         # metres per quad at level 0
@export var levels := 10
@export var horizon := 120000.0      # apron outer edge distance
@export var max_wave_height := 8.0
@export var max_chop := 8.0
@export var camera: Camera3D

const BLOCKS := 4

var _material: ShaderMaterial
var _block_meshes: Array[ArrayMesh] = []
var _apron_mesh: ArrayMesh
var _inst: Array[RID] = []           # levels * 16, index = L * 16 + bz * 4 + bx
var _apron: RID
var _centers: PackedVector2Array
var _min_level := -1


func _ready() -> void:
	if RenderingServer.get_rendering_device() == null:
		queue_free(); return
	_material = WaveManager.get_ocean_material()
	_material.set_shader_parameter("ring_half", ring_quads / 2.0)
	_build_meshes()
	_create_instances()


func _exit_tree() -> void:
	for r in _inst: RenderingServer.free_rid(r)
	if _apron.is_valid(): RenderingServer.free_rid(_apron)
	_inst.clear()
	_apron = RID()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not _inst.is_empty():
		_min_level = -1


func _build_meshes() -> void:
	var b := ring_quads / BLOCKS
	var half := ring_quads / 2
	var aabb_y := max_wave_height + 2.0
	for bz in BLOCKS:
		for bx in BLOCKS:
			var m := _grid_mesh(bx * b - half, bz * b - half, b)
			m.custom_aabb = AABB(Vector3(bx * b - half, -aabb_y, bz * b - half), Vector3(b, aabb_y * 2.0, b))
			_block_meshes.append(m)
	_apron_mesh = _build_apron()


func _grid_mesh(x0: int, z0: int, n: int) -> ArrayMesh:
	var verts := PackedVector3Array(); verts.resize((n + 1) * (n + 1))
	var idx := PackedInt32Array(); idx.resize(n * n * 6)
	var vi := 0
	for z in n + 1:
		for x in n + 1:
			verts[vi] = Vector3(x0 + x, 0.0, z0 + z); vi += 1
	var ii := 0
	var row := n + 1
	for z in n:
		for x in n:
			var i := z * row + x
			idx[ii] = i; idx[ii + 1] = i + 1; idx[ii + 2] = i + row
			idx[ii + 3] = i + 1; idx[ii + 4] = i + row + 1; idx[ii + 5] = i + row
			ii += 6
	return _array_mesh(verts, idx)


func _build_apron() -> ArrayMesh:
	var half := ring_quads / 2
	var outer := horizon / (base_cell * pow(2.0, levels - 1)) / half
	var ring := PackedVector2Array()
	for s in ring_quads: ring.append(Vector2(-half + s, -half))
	for s in ring_quads: ring.append(Vector2(half, -half + s))
	for s in ring_quads: ring.append(Vector2(half - s, half))
	for s in ring_quads: ring.append(Vector2(-half, half - s))
	var count := ring.size()
	var verts := PackedVector3Array(); verts.resize(count * 2)
	var idx := PackedInt32Array(); idx.resize(count * 6)
	for s in count:
		verts[s] = Vector3(ring[s].x, 0.0, ring[s].y)
		verts[count + s] = Vector3(ring[s].x * outer, 0.0, ring[s].y * outer)
	for s in count:
		var n := (s + 1) % count
		var i := s * 6
		idx[i] = s; idx[i + 1] = count + s; idx[i + 2] = n
		idx[i + 3] = n; idx[i + 4] = count + s; idx[i + 5] = count + n
	var m := _array_mesh(verts, idx)
	var r := half * outer
	m.custom_aabb = AABB(Vector3(-r, -max_wave_height, -r), Vector3(r * 2.0, max_wave_height * 2.0, r * 2.0))
	return m


func _array_mesh(verts: PackedVector3Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _create_instances() -> void:
	var scenario := get_world_3d().scenario
	var mat := _material.get_rid()
	_centers.resize(levels)
	for L in levels:
		var cell := base_cell * pow(2.0, L)
		_centers[L] = Vector2(INF, INF)
		for i in BLOCKS * BLOCKS:
			_inst.append(_make_instance(_block_meshes[i].get_rid(), scenario, mat, cell * 2.0 + max_chop))
	_apron = _make_instance(_apron_mesh.get_rid(), scenario, mat, max_chop)


func _make_instance(mesh: RID, scenario: RID, mat: RID, margin: float) -> RID:
	var r := RenderingServer.instance_create2(mesh, scenario)
	RenderingServer.instance_geometry_set_material_override(r, mat)
	RenderingServer.instance_geometry_set_cast_shadows_setting(r, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_set_extra_visibility_margin(r, margin)
	RenderingServer.instance_set_visible(r, false)
	return r


func _process(_delta: float) -> void:
	if _inst.is_empty(): return
	var cam := camera if is_instance_valid(camera) else get_viewport().get_camera_3d()
	if cam == null: return
	var c := cam.global_position
	_update_min_level(absf(c.y))
	# Each level snaps to its own cell with floor so level L+1's grid is exactly
	# level L's grid decimated by 2 — the shader's morph relies on that identity.
	for L in levels:
		var cell := base_cell * pow(2.0, L)
		var center := Vector2(floorf(c.x / cell) * cell, floorf(c.z / cell) * cell)
		if center == _centers[L]: continue
		_centers[L] = center
		var xf := Transform3D(Basis.from_scale(Vector3(cell, 1.0, cell)), Vector3(center.x, 0.0, center.y))
		for i in BLOCKS * BLOCKS:
			RenderingServer.instance_set_transform(_inst[L * 16 + i], xf)
		if L == levels - 1:
			RenderingServer.instance_set_transform(_apron, xf)


func _update_min_level(height: float) -> void:
	var k := 4.0 / (ring_quads * base_cell)
	var up := int(floor(log(maxf(height * k, 1.0)) / log(2.0)))
	var down := int(floor(log(maxf(height * 1.25 * k, 1.0)) / log(2.0)))
	var lvl := _min_level
	if _min_level < 0 or up > _min_level or down < _min_level:
		lvl = up
	lvl = clampi(lvl, 0, levels - 1)
	if lvl == _min_level: return
	_min_level = lvl
	var vis := is_visible_in_tree()
	for L in levels:
		for i in BLOCKS * BLOCKS:
			var bx := i % BLOCKS
			var bz := i / BLOCKS
			var inner := bx in [1, 2] and bz in [1, 2]
			RenderingServer.instance_set_visible(_inst[L * 16 + i], vis and L >= lvl and (L == lvl or not inner))
	RenderingServer.instance_set_visible(_apron, vis)
