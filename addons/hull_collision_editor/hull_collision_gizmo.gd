# addons/hull_collision_editor/hull_collision_gizmo.gd
@tool
extends EditorNode3DGizmoPlugin

## Gizmo plugin to visualize hull collision shapes for ships in the editor.

const HULL_COLLISION_PREFIX = "HullPhysicsCollision"
const BOW_COLLISION_NAME = "BowPhysicsCollision"
const MID_COLLISION_NAME = "MidshipPhysicsCollision"
const STERN_COLLISION_NAME = "SternPhysicsCollision"

# Colors for different collision shape types
const COLOR_SINGLE_HULL = Color(0.0, 0.8, 1.0, 0.8)  # Cyan
const COLOR_BOW = Color(1.0, 0.3, 0.3, 0.8)  # Red
const COLOR_MIDSHIP = Color(0.3, 1.0, 0.3, 0.8)  # Green
const COLOR_STERN = Color(0.3, 0.3, 1.0, 0.8)  # Blue
const COLOR_BOX = Color(1.0, 0.8, 0.2, 0.5)  # Yellow/Orange


func _init():
	create_material("hull_collision", COLOR_SINGLE_HULL, false, true)
	create_material("bow_collision", COLOR_BOW, false, true)
	create_material("midship_collision", COLOR_MIDSHIP, false, true)
	create_material("stern_collision", COLOR_STERN, false, true)
	create_material("box_collision", COLOR_BOX, false, true)


func _get_gizmo_name() -> String:
	return "HullCollisionGizmo"


func _has_gizmo(node: Node3D) -> bool:
	# Show gizmo for ships (RigidBody3D with ship_name property or Ship script)
	if node is RigidBody3D:
		if "ship_name" in node:
			return true
		var script = node.get_script()
		if script and script.get_global_name() == "Ship":
			return true
	return false


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()

	var node = gizmo.get_node_3d()
	if not node:
		return

	# Find and draw all collision shapes
	for child in node.get_children():
		if child is CollisionShape3D and child.shape:
			_draw_collision_shape(gizmo, child)


func _draw_collision_shape(gizmo: EditorNode3DGizmo, collision_shape: CollisionShape3D) -> void:
	var shape = collision_shape.shape
	var transform = collision_shape.transform

	# Determine material based on shape name
	var material_name = _get_material_for_shape(collision_shape.name, shape)
	var material = get_material(material_name, gizmo)

	if shape is ConvexPolygonShape3D:
		_draw_convex_shape(gizmo, shape as ConvexPolygonShape3D, transform, material)
	elif shape is BoxShape3D:
		_draw_box_shape(gizmo, shape as BoxShape3D, transform, material)


func _get_material_for_shape(shape_name: String, shape: Shape3D) -> String:
	if shape_name == BOW_COLLISION_NAME:
		return "bow_collision"
	elif shape_name == MID_COLLISION_NAME:
		return "midship_collision"
	elif shape_name == STERN_COLLISION_NAME:
		return "stern_collision"
	elif shape_name.begins_with(HULL_COLLISION_PREFIX):
		return "hull_collision"
	elif shape is BoxShape3D:
		return "box_collision"
	else:
		return "hull_collision"


func _draw_convex_shape(gizmo: EditorNode3DGizmo, shape: ConvexPolygonShape3D, transform: Transform3D, material: StandardMaterial3D) -> void:
	var points = shape.points
	if points.size() < 4:
		return

	# Get the debug mesh from the shape and transform it
	var debug_mesh = shape.get_debug_mesh()
	if debug_mesh:
		# Create lines from the mesh
		var lines = PackedVector3Array()

		for surface_idx in range(debug_mesh.get_surface_count()):
			var arrays = debug_mesh.surface_get_arrays(surface_idx)
			if arrays.size() > Mesh.ARRAY_VERTEX:
				var vertices = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
				var indices = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array

				if indices and indices.size() > 0:
					# Draw triangles as lines
					for i in range(0, indices.size(), 3):
						if i + 2 < indices.size():
							var v0 = transform * vertices[indices[i]]
							var v1 = transform * vertices[indices[i + 1]]
							var v2 = transform * vertices[indices[i + 2]]

							lines.append(v0)
							lines.append(v1)
							lines.append(v1)
							lines.append(v2)
							lines.append(v2)
							lines.append(v0)
				else:
					# No indices, assume triangle list
					for i in range(0, vertices.size(), 3):
						if i + 2 < vertices.size():
							var v0 = transform * vertices[i]
							var v1 = transform * vertices[i + 1]
							var v2 = transform * vertices[i + 2]

							lines.append(v0)
							lines.append(v1)
							lines.append(v1)
							lines.append(v2)
							lines.append(v2)
							lines.append(v0)

		if lines.size() > 0:
			gizmo.add_lines(lines, material, false)


func _draw_box_shape(gizmo: EditorNode3DGizmo, shape: BoxShape3D, transform: Transform3D, material: StandardMaterial3D) -> void:
	var size = shape.size
	var half = size / 2.0

	# Define the 8 corners of the box
	var corners = [
		Vector3(-half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, half.z),
		Vector3(-half.x, -half.y, half.z),
		Vector3(-half.x, half.y, -half.z),
		Vector3(half.x, half.y, -half.z),
		Vector3(half.x, half.y, half.z),
		Vector3(-half.x, half.y, half.z),
	]

	# Transform corners
	for i in range(corners.size()):
		corners[i] = transform * corners[i]

	# Define edges as pairs of corner indices
	var edges = [
		# Bottom face
		[0, 1], [1, 2], [2, 3], [3, 0],
		# Top face
		[4, 5], [5, 6], [6, 7], [7, 4],
		# Vertical edges
		[0, 4], [1, 5], [2, 6], [3, 7]
	]

	var lines = PackedVector3Array()
	for edge in edges:
		lines.append(corners[edge[0]])
		lines.append(corners[edge[1]])

	gizmo.add_lines(lines, material, false)


func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> String:
	return ""


func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> Variant:
	return null


func _get_priority() -> int:
	# Lower priority so other gizmos can take precedence
	return -1
