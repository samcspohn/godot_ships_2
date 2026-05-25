# addons/turret_editor/turret_gizmo_plugin.gd
@tool
class_name TurretGizmoPlugin
extends EditorNode3DGizmoPlugin

const LINE_WIDTH := 0.05

# Handle ID scheme:
#   0          -> slew_min_angle
#   1          -> slew_max_angle
#   2 + 2*i    -> fire_arcs[i].min_angle
#   3 + 2*i    -> fire_arcs[i].max_angle
const FIRE_ARC_HANDLE_BASE := 2

func _init():
	create_material("main", Color(1, 0.5, 0, 0.8))
	create_material("allowed", Color(1, 0, 0, 0.8))            # slew arc
	create_material("fire_arc", Color(0.1, 0.9, 0.3, 0.8))     # fire arcs (green)
	create_material("rotation_indicator", Color(0.2, 0.6, 1.0, 1.0))  # current rotation (cyan)
	create_handle_material("handles")
	create_handle_material("fire_arc_handles")

func _has_gizmo(node):
	return node is Gun

func _get_gizmo_name():
	return "TurretGizmo"

func _get_scale_factor(camera, global_position):
	var view_position = camera.global_transform.origin
	var distance = view_position.distance_to(global_position)
	var base_size := 10.0
	return max(distance * 0.08, base_size)

func _storage_to_display(rad_value: float) -> float:
	# Storage angles (rotation.y space) map to world-bearing display angles
	# via a 180° offset (Godot's local -Z forward convention).
	var v = rad_value - PI
	while v < 0:
		v += TAU
	while v >= TAU:
		v -= TAU
	return v

func _display_to_storage(rad_value: float) -> float:
	var v = rad_value + PI
	while v < 0:
		v += TAU
	while v >= TAU:
		v -= TAU
	return v

func _redraw(gizmo):
	var turret = gizmo.get_node_3d() as Gun
	if not turret:
		return
	gizmo.clear()

	var camera = get_editor_camera()
	if not camera:
		return

	var scale_factor = _get_scale_factor(camera, turret.global_position) / turret.scale.length()

	_draw_base_circle(gizmo, turret, camera, scale_factor)

	if turret.slew_limits_enabled:
		_draw_slew_arc(gizmo, turret, camera, scale_factor)

	_draw_fire_arcs(gizmo, turret, camera, scale_factor)
	_draw_current_rotation(gizmo, turret, camera, scale_factor)

# --- Drawing helpers ---

func _draw_base_circle(gizmo, turret: Gun, camera: Camera3D, scale_factor: float) -> void:
	var base_lines := PackedVector3Array()
	var base_radius := scale_factor
	var segments := 32
	for i in range(segments):
		var a0 = i * TAU / segments
		var a1 = ((i + 1) % segments) * TAU / segments
		var p0_w = turret.global_position + Vector3(sin(a0) * base_radius, 0, cos(a0) * base_radius)
		var p1_w = turret.global_position + Vector3(sin(a1) * base_radius, 0, cos(a1) * base_radius)
		base_lines.append(turret.global_transform.affine_inverse() * p0_w)
		base_lines.append(turret.global_transform.affine_inverse() * p1_w)
	gizmo.add_mesh(_create_quad_mesh_from_lines(base_lines, camera, scale_factor * LINE_WIDTH), get_material("main", gizmo))

func _draw_slew_arc(gizmo, turret: Gun, camera: Camera3D, scale_factor: float) -> void:
	var min_disp = _storage_to_display(turret.slew_min_angle)
	var max_disp = _storage_to_display(turret.slew_max_angle)
	var radius = scale_factor * 4.0
	var height = scale_factor * 0.1

	var lines := PackedVector3Array()
	if min_disp <= max_disp:
		_add_arc_segment_world_relative(lines, min_disp, max_disp, radius, height, 32, turret)
	else:
		_add_arc_segment_world_relative(lines, min_disp, TAU, radius, height, 16, turret)
		_add_arc_segment_world_relative(lines, 0, max_disp, radius, height, 16, turret)

	var center_world = turret.global_position + Vector3(0, height, 0)
	var min_point_world = turret.global_position + Vector3(sin(min_disp) * radius, height, cos(min_disp) * radius)
	var max_point_world = turret.global_position + Vector3(sin(max_disp) * radius, height, cos(max_disp) * radius)
	var inv = turret.global_transform.affine_inverse()
	var center = inv * center_world
	var min_point = inv * min_point_world
	var max_point = inv * max_point_world
	lines.append(center); lines.append(min_point)
	lines.append(center); lines.append(max_point)

	if lines.size() % 2 != 0:
		push_warning("Slew arc lines odd count: " + str(lines.size()))
		return
	gizmo.add_mesh(_create_quad_mesh_from_lines(lines, camera, scale_factor * LINE_WIDTH), get_material("allowed", gizmo))

	var handles := PackedVector3Array()
	handles.append(min_point)
	handles.append(max_point)
	gizmo.add_handles(handles, get_material("handles", gizmo), PackedInt32Array([0, 1]), false, false)

func _draw_fire_arcs(gizmo, turret: Gun, camera: Camera3D, scale_factor: float) -> void:
	if turret.fire_arcs.is_empty():
		return
	var inv = turret.global_transform.affine_inverse()
	for i in turret.fire_arcs.size():
		var fa: FireArc = turret.fire_arcs[i]
		if fa == null:
			continue
		var min_disp = _storage_to_display(fa.min_angle)
		var max_disp = _storage_to_display(fa.max_angle)
		# Stack fire arcs at increasing height so multiple arcs are visible.
		var radius = scale_factor * (3.0 + 0.4 * i)
		var height = scale_factor * (0.25 + 0.05 * i)

		var lines := PackedVector3Array()
		if fa.min_angle == fa.max_angle:
			# Convention: min == max -> full circle.
			_add_arc_segment_world_relative(lines, 0.0, TAU, radius, height, 32, turret)
		elif min_disp <= max_disp:
			_add_arc_segment_world_relative(lines, min_disp, max_disp, radius, height, 32, turret)
		else:
			_add_arc_segment_world_relative(lines, min_disp, TAU, radius, height, 16, turret)
			_add_arc_segment_world_relative(lines, 0, max_disp, radius, height, 16, turret)

		var center_w = turret.global_position + Vector3(0, height, 0)
		var min_w = turret.global_position + Vector3(sin(min_disp) * radius, height, cos(min_disp) * radius)
		var max_w = turret.global_position + Vector3(sin(max_disp) * radius, height, cos(max_disp) * radius)
		var center = inv * center_w
		var min_p = inv * min_w
		var max_p = inv * max_w
		if fa.min_angle != fa.max_angle:
			lines.append(center); lines.append(min_p)
			lines.append(center); lines.append(max_p)

		if lines.size() % 2 != 0:
			push_warning("Fire arc %d lines odd count" % i)
			continue
		gizmo.add_mesh(_create_quad_mesh_from_lines(lines, camera, scale_factor * LINE_WIDTH), get_material("fire_arc", gizmo))

		if fa.min_angle != fa.max_angle:
			var handles := PackedVector3Array()
			handles.append(min_p)
			handles.append(max_p)
			var ids := PackedInt32Array([FIRE_ARC_HANDLE_BASE + 2 * i, FIRE_ARC_HANDLE_BASE + 2 * i + 1])
			gizmo.add_handles(handles, get_material("fire_arc_handles", gizmo), ids, false, false)

func _draw_current_rotation(gizmo, turret: Gun, camera: Camera3D, scale_factor: float) -> void:
	# Draw a line from the turret center along its actual pointing direction
	# (-global_basis.z projected onto the horizontal plane). Length matches
	# the slew arc so the indicator is easy to relate to the arc.
	var forward = -turret.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 1e-6:
		return
	forward = forward.normalized()
	var radius = scale_factor * 4.5
	var height = scale_factor * 0.05
	var center_w = turret.global_position + Vector3(0, height, 0)
	var tip_w = turret.global_position + forward * radius + Vector3(0, height, 0)
	var inv = turret.global_transform.affine_inverse()
	var lines := PackedVector3Array()
	lines.append(inv * center_w)
	lines.append(inv * tip_w)
	# Arrowhead: two short segments back from tip, ±20° each.
	var head_len = scale_factor * 0.4
	var head_angle = deg_to_rad(20.0)
	var back = -forward
	var left = back.rotated(Vector3.UP, head_angle) * head_len
	var right = back.rotated(Vector3.UP, -head_angle) * head_len
	lines.append(inv * tip_w); lines.append(inv * (tip_w + left))
	lines.append(inv * tip_w); lines.append(inv * (tip_w + right))
	gizmo.add_mesh(_create_quad_mesh_from_lines(lines, camera, scale_factor * LINE_WIDTH * 1.4), get_material("rotation_indicator", gizmo))

# --- Handle dispatch ---

func get_editor_camera():
	var viewport = EditorInterface.get_editor_viewport_3d()
	if viewport:
		return viewport.get_camera_3d()
	return null

func _resolve_handle(turret: Gun, handle_id: int) -> Dictionary:
	# Returns {target, prop, label}, or {} if invalid.
	if handle_id == 0:
		return {"target": turret, "prop": "slew_min_angle", "label": "Slew Min"}
	if handle_id == 1:
		return {"target": turret, "prop": "slew_max_angle", "label": "Slew Max"}
	var idx = (handle_id - FIRE_ARC_HANDLE_BASE) / 2
	var is_max = (handle_id - FIRE_ARC_HANDLE_BASE) % 2 == 1
	if idx < 0 or idx >= turret.fire_arcs.size():
		return {}
	var fa: FireArc = turret.fire_arcs[idx]
	if fa == null:
		return {}
	return {
		"target": fa,
		"prop": "max_angle" if is_max else "min_angle",
		"label": "Fire Arc %d %s" % [idx, "Max" if is_max else "Min"],
	}

func _get_handle_name(_gizmo, handle_id, _secondary):
	var turret = _gizmo.get_node_3d() as Gun
	if not turret:
		return "Handle"
	var info = _resolve_handle(turret, handle_id)
	return info.get("label", "Handle")

func _commit_handle(gizmo, handle_id, _secondary, restore, cancel):
	var turret = gizmo.get_node_3d() as Gun
	if not is_instance_valid(turret):
		return
	var info = _resolve_handle(turret, handle_id)
	if info.is_empty():
		return
	var restore_storage = _display_to_storage(restore)
	var target = info["target"]
	var prop = info["prop"]
	if cancel:
		target.set(prop, restore_storage)
		return
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Change " + info["label"])
	undo_redo.add_do_property(target, prop, target.get(prop))
	undo_redo.add_undo_property(target, prop, restore_storage)
	undo_redo.commit_action()

func _set_handle(gizmo, handle_id, _secondary, camera, screen_pos):
	var turret = gizmo.get_node_3d() as Gun
	if not is_instance_valid(turret):
		return 0.0
	var info = _resolve_handle(turret, handle_id)
	if info.is_empty():
		return 0.0

	var ray_origin = camera.project_ray_origin(screen_pos)
	var ray_direction = camera.project_ray_normal(screen_pos)
	var plane_normal = Vector3.UP
	var plane_origin = turret.global_position + plane_normal * (_get_scale_factor(camera, turret.global_position) * 0.1)
	var plane = Plane(plane_normal, plane_origin.dot(plane_normal))
	var intersection = plane.intersects_ray(ray_origin, ray_direction)
	if intersection == null:
		var stored = info["target"].get(info["prop"]) as float
		return _storage_to_display(stored)

	var world_dir = intersection - turret.global_position
	var display_angle = atan2(world_dir.x, world_dir.z)
	while display_angle < 0:
		display_angle += TAU
	while display_angle >= TAU:
		display_angle -= TAU
	var storage_angle = _display_to_storage(display_angle)
	info["target"].set(info["prop"], storage_angle)
	return display_angle

# --- Geometry helpers ---

func _add_arc_segment_world_relative(lines: PackedVector3Array, start_angle: float, end_angle: float,
	radius: float, height: float, segments: int, turret: Gun):
	var angle_step = (end_angle - start_angle) / segments
	var inv = turret.global_transform.affine_inverse()
	for i in range(segments):
		var a0 = start_angle + i * angle_step
		var a1 = start_angle + (i + 1) * angle_step
		var p0_w = turret.global_position + Vector3(sin(a0) * radius, height, cos(a0) * radius)
		var p1_w = turret.global_position + Vector3(sin(a1) * radius, height, cos(a1) * radius)
		lines.append(inv * p0_w)
		lines.append(inv * p1_w)
		if i % 8 == 0:
			var center_w = turret.global_position + Vector3(0, height, 0)
			lines.append(inv * center_w)
			lines.append(inv * p0_w)

func _create_quad_mesh_from_lines(lines: PackedVector3Array, camera: Camera3D, width: float) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	if lines.size() < 2 or lines.size() % 2 != 0:
		return mesh
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var camera_pos = camera.global_transform.origin
	for i in range(0, lines.size(), 2):
		var start = lines[i]
		var end = lines[i + 1]
		var line_dir = (end - start).normalized()
		var to_camera = (camera_pos - (start + end) * 0.5).normalized()
		var right = line_dir.cross(to_camera).normalized()
		if right.length() < 0.1:
			right = camera.global_transform.basis.y.cross(line_dir).normalized()
			if right.length() < 0.1:
				right = camera.global_transform.basis.x.normalized()
		var hw = width * 0.5
		var v0 = start + right * hw
		var v1 = start - right * hw
		var v2 = end - right * hw
		var v3 = end + right * hw
		var base_idx = vertices.size()
		vertices.append(v0); vertices.append(v1); vertices.append(v2); vertices.append(v3)
		for _j in range(4):
			normals.append(to_camera)
		uvs.append(Vector2(0, 0)); uvs.append(Vector2(0, 1)); uvs.append(Vector2(1, 1)); uvs.append(Vector2(1, 0))
		indices.append(base_idx);     indices.append(base_idx + 1); indices.append(base_idx + 2)
		indices.append(base_idx);     indices.append(base_idx + 2); indices.append(base_idx + 3)
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# Note: this script extends Resource (via EditorNode3DGizmoPlugin), so it does
# NOT receive _process. The per-frame redraw of Gun gizmos lives in
# turret_editor_plugin.gd, which is an EditorPlugin (Node).
