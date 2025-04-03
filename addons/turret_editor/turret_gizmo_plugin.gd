# addons/turret_editor/turret_gizmo_plugin.gd
@tool
class_name TurretGizmoPlugin
extends EditorNode3DGizmoPlugin

const LINE_WIDTH = 0.05  # Width of the quad lines

func _init():
	create_material("main", Color(1, 0.5, 0, 0.8))
	# create_material("restricted", Color(1, 0, 0, 0.4))
	create_material("allowed", Color(1, 0, 0, 0.8))
	create_handle_material("handles")

func _has_gizmo(node):
	return node is Gun

func _get_gizmo_name():
	return "TurretGizmo"

# Get scale factor based on camera distance (similar to transform gizmo)
func _get_scale_factor(camera, global_position):
	var view_position = camera.global_transform.origin
	var distance = view_position.distance_to(global_position)
	
	# Base size that looks good at average distance
	var base_size = 10.0
	
	# Scale based on distance with a minimum size to prevent disappearing when far away
	return max(distance * 0.08, base_size)

# Convert radians to degrees in 0-360 range
func rad_to_deg_0_360(rad_value: float) -> float:
	var deg_value = rad_to_deg(rad_value)
	
	# Normalize to 0-360 range
	while deg_value < 0:
		deg_value += 360
	
	while deg_value >= 360:
		deg_value -= 360
	
	return deg_value

# Convert degrees in 0-360 range to radians
func deg_0_360_to_rad(deg_value: float) -> float:
	# Normalize input to 0-360 range
	while deg_value < 0:
		deg_value += 360
	
	while deg_value >= 360:
		deg_value -= 360
	
	# Convert to radians
	return deg_to_rad(deg_value)

func _redraw(gizmo):
	var turret = gizmo.get_node_3d() as Gun
	
	if not turret:
		return
	
	gizmo.clear()
	
	# Get the current camera
	var camera = get_editor_camera()
	if not camera:
		return
	
	# Calculate appropriate scale based on distance
	var scale_factor = _get_scale_factor(camera, turret.global_position) / turret.scale.length()
	
	# Draw base circle with dynamic scaling
	var base_lines = PackedVector3Array()
	var base_radius = scale_factor
	var segments = 32
	
	for i in range(segments):
		var angle_current = i * TAU / segments
		var angle_next = ((i + 1) % segments) * TAU / segments
		
		# Calculate points in the XZ plane (Z axis is forward for the turret)
		# Fix 90 degree rotation by swapping sin and cos (and flipping sign as needed)
		var current_point = Vector3(sin(angle_current) * base_radius, 0, cos(angle_current) * base_radius)
		var next_point = Vector3(sin(angle_next) * base_radius, 0, cos(angle_next) * base_radius)
		
		# Transform points by turret's transformation
		current_point = turret.transform.basis * current_point
		next_point = turret.transform.basis * next_point
		
		base_lines.append(current_point)
		base_lines.append(next_point)
	
	# Draw base circle with quads
	var base_mesh = _create_quad_mesh_from_lines(base_lines, camera, scale_factor * LINE_WIDTH)
	gizmo.add_mesh(base_mesh, get_material("main", gizmo))
	
	# Draw rotation limits if enabled
	if turret.rotation_limits_enabled:
		var min_angle_rad = turret.min_rotation_angle
		var max_angle_rad = turret.max_rotation_angle
		
		# Convert to 0-360 range
		var min_angle_deg = rad_to_deg_0_360(min_angle_rad)
		var max_angle_deg = rad_to_deg_0_360(max_angle_rad)
		
		# Convert back to radians for use in calculations
		min_angle_rad = deg_to_rad(min_angle_deg)
		max_angle_rad = deg_to_rad(max_angle_deg)
		
		var arc_radius = scale_factor * 4.0
		var height = scale_factor * 0.1
		
		# Draw the arc
		var arc_lines = PackedVector3Array()
		
		# Interpret min->max as clockwise
		# If min == max, no valid rotation
		if abs(min_angle_deg - max_angle_deg) < 0.01:
			# Draw a very small arc to indicate no valid rotation
			_add_arc_segment_transformed(arc_lines, min_angle_rad, min_angle_rad + 0.01, arc_radius, height, 2, turret.transform.basis)
		elif min_angle_deg < max_angle_deg:
			# Standard case: min to max
			_add_arc_segment_transformed(arc_lines, min_angle_rad, max_angle_rad, arc_radius, height, 32, turret.transform.basis)
		else:
			# Wrap-around case: min to 2π then 0 to max
			_add_arc_segment_transformed(arc_lines, min_angle_rad, TAU, arc_radius, height, 16, turret.transform.basis)
			_add_arc_segment_transformed(arc_lines, 0, max_angle_rad, arc_radius, height, 16, turret.transform.basis)
		
		# Add lines to arc ends
		var center = turret.transform.basis * Vector3(0, height, 0)
		# Fix 90 degree rotation by swapping sin and cos
		var min_point = turret.transform.basis * Vector3(sin(min_angle_rad) * arc_radius, height, cos(min_angle_rad) * arc_radius)
		var max_point = turret.transform.basis * Vector3(sin(max_angle_rad) * arc_radius, height, cos(max_angle_rad) * arc_radius)
		
		arc_lines.append(center)
		arc_lines.append(min_point)
		
		arc_lines.append(center)
		arc_lines.append(max_point)
		
		# Check for any vertex issues
		if arc_lines.size() % 2 != 0:
			push_warning("Arc lines has odd count: " + str(arc_lines.size()))
			return
		
		# Draw arc with quads
		var arc_mesh = _create_quad_mesh_from_lines(arc_lines, camera, scale_factor * LINE_WIDTH)
		gizmo.add_mesh(arc_mesh, get_material("allowed", gizmo))
		
		# Add handles
		var handles = PackedVector3Array()
		handles.append(min_point)
		handles.append(max_point)
		
		var ids = PackedInt32Array([0, 1])
		gizmo.add_handles(handles, get_material("handles", gizmo), ids, false, false)

# Get the current editor camera
func get_editor_camera():
	var viewport = EditorInterface.get_editor_viewport_3d()
	if viewport:
		return viewport.get_camera_3d()
	return null

# Add arc segment vertices in pairs
func _add_arc_segment(lines: PackedVector3Array, start_angle: float, end_angle: float, radius: float, height: float, segments: int):
	# This function will be replaced by _add_arc_segment_transformed, but we'll keep it for backward compatibility
	_add_arc_segment_transformed(lines, start_angle, end_angle, radius, height, segments, Basis())

# Add a new function to add transformed arc segments
func _add_arc_segment_transformed(lines: PackedVector3Array, start_angle: float, end_angle: float, 
	radius: float, height: float, segments: int, transform_basis: Basis):
	var angle_step = (end_angle - start_angle) / segments
	
	for i in range(segments):
		var angle = start_angle + i * angle_step
		var next_angle = start_angle + (i + 1) * angle_step
		
		# Fix 90 degree rotation by swapping sin and cos
		var point = transform_basis * Vector3(sin(angle) * radius, height, cos(angle) * radius)
		var next_point = transform_basis * Vector3(sin(next_angle) * radius, height, cos(next_angle) * radius)
		
		# Add points as a pair
		lines.append(point)
		lines.append(next_point)
		
		# Add radial lines (fewer to avoid crowding)
		if i % 8 == 0:
			var center = transform_basis * Vector3(0, height, 0)
			lines.append(center)
			lines.append(point)

func _get_handle_name(gizmo, handle_id, secondary):
	if handle_id == 0:
		return "Min Angle"
	else:
		return "Max Angle"

func _commit_handle(gizmo, handle_id, secondary, restore, cancel):
	var turret = gizmo.get_node_3d() as Gun
	
	if cancel:
		if handle_id == 0:
			turret.min_rotation_angle = restore
		else:
			turret.max_rotation_angle = restore
		return
	
	var undo_redo = EditorInterface.get_editor_undo_redo()
	
	if handle_id == 0:
		undo_redo.create_action("Change Min Angle")
		undo_redo.add_do_property(turret, "min_rotation_angle", turret.min_rotation_angle)
		undo_redo.add_undo_property(turret, "min_rotation_angle", restore)
	else:
		undo_redo.create_action("Change Max Angle")
		undo_redo.add_do_property(turret, "max_rotation_angle", turret.max_rotation_angle)
		undo_redo.add_undo_property(turret, "max_rotation_angle", restore)
	
	undo_redo.commit_action()

func _set_handle(gizmo, handle_id, secondary, camera, screen_pos):
	var turret = gizmo.get_node_3d() as Gun
	
	if not is_instance_valid(turret):
		return 0.0
	
	var ray_origin = camera.project_ray_origin(screen_pos)
	var ray_direction = camera.project_ray_normal(screen_pos)
	
	# Create a plane that matches the gizmo's orientation
	var plane_normal = turret.global_transform.basis.y
	var plane_origin = turret.global_transform.origin + plane_normal * (_get_scale_factor(camera, turret.global_position) * 0.1)
	var plane = Plane(plane_normal, plane_origin.dot(plane_normal))
	
	# Intersect ray with plane
	var intersection = plane.intersects_ray(ray_origin, ray_direction)
	if intersection == null:
		return turret.min_rotation_angle if (handle_id == 0) else turret.max_rotation_angle
	
	# Calculate vector from turret origin to intersection point in global space
	var global_dir = intersection - turret.global_transform.origin
	
	# Convert the direction to the turret's local coordinate system (excluding translation)
	var local_dir = turret.global_transform.basis.inverse() * global_dir
	
	# Calculate the angle in the XZ plane
	var angle = atan2(local_dir.x, local_dir.z) + turret.rotation.y
	
	# Ensure the angle is in the 0 to 2π range
	while angle < 0:
		angle += TAU
	while angle >= TAU:
		angle -= TAU
	
	if handle_id == 0:
		turret.min_rotation_angle = angle
	else:
		turret.max_rotation_angle = angle
	
	# The gizmo will be redrawn automatically after we return from this function
	
	return turret.min_rotation_angle if (handle_id == 0) else turret.max_rotation_angle

# Create a mesh consisting of quads for each line segment
func _create_quad_mesh_from_lines(lines: PackedVector3Array, camera: Camera3D, width: float) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	if lines.size() < 2 or lines.size() % 2 != 0:
		return mesh
	
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	
	var camera_pos = camera.global_transform.origin
	
	# Process each line segment (pairs of points)
	for i in range(0, lines.size(), 2):
		var start = lines[i]
		var end = lines[i+1]
		
		# Direction vector of the line
		var line_dir = (end - start).normalized()
		
		# Vector from camera to the midpoint of the line
		var to_camera = (camera_pos - (start + end) * 0.5).normalized()
		
		# Calculate the right vector (perpendicular to line_dir and to_camera)
		var right = line_dir.cross(to_camera).normalized()
		
		# If the cross product is too small (line points toward/away from camera)
		# use the camera's up vector to create a stable perpendicular
		if right.length() < 0.1:
			right = camera.global_transform.basis.y.cross(line_dir).normalized()
			if right.length() < 0.1:
				right = camera.global_transform.basis.x.normalized()
		
		# Calculate half width
		var half_width = width * 0.5
		
		# Create the quad vertices
		var v0 = start + right * half_width
		var v1 = start - right * half_width
		var v2 = end - right * half_width
		var v3 = end + right * half_width
		
		# Add vertices for this quad
		var base_idx = vertices.size()
		vertices.append(v0)
		vertices.append(v1)
		vertices.append(v2)
		vertices.append(v3)
		
		# Add face normal (for lighting)
		var face_normal = to_camera
		for j in range(4):
			normals.append(face_normal)
		
		# Add UVs
		uvs.append(Vector2(0, 0))
		uvs.append(Vector2(0, 1))
		uvs.append(Vector2(1, 1))
		uvs.append(Vector2(1, 0))
		
		# Add indices for two triangles making the quad
		indices.append(base_idx)
		indices.append(base_idx + 1)
		indices.append(base_idx + 2)
		
		indices.append(base_idx)
		indices.append(base_idx + 2)
		indices.append(base_idx + 3)
	
	# Create surface with all the geometry data
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# Override to force redraw of gizmos on every frame
func _process(_delta):
	# Force redraw every frame regardless of camera movement
	_redraw_all_gizmos()
	
	# Still update the camera position for other functionality that might need it
	var camera = get_editor_camera()
	if camera and is_instance_valid(camera):
		_last_camera_pos = camera.global_position

# Helper to redraw all Gun nodes' gizmos
func _redraw_all_gizmos():
	var edited_scene = EditorInterface.get_edited_scene_root()
	if edited_scene:
		_find_and_redraw_guns(edited_scene)

# Recursively find all Gun nodes and request gizmo redraw
func _find_and_redraw_guns(node: Node):
	if node is Gun:
		# Just mark the node as needing a gizmo redraw
		# The editor will handle the rest
		node.notify_property_list_changed()
	
	for child in node.get_children():
		_find_and_redraw_guns(child)

# Store last camera position to detect movement
var _last_camera_pos = Vector3()
