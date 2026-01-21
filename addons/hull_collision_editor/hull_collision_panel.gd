# addons/hull_collision_editor/hull_collision_panel.gd
@tool
extends VBoxContainer

## Editor panel for generating and managing hull collision shapes for ships.

var plugin: EditorPlugin
var current_ship: Node3D
var preview_meshes: Array[MeshInstance3D] = []
var _needs_gizmo_refresh: bool = false

# UI References
@onready var ship_info_label: Label = %ShipInfoLabel
@onready var include_superstructure: CheckBox = %IncludeSuperstructure
@onready var segmented_hull: CheckBox = %SegmentedHull
@onready var mirror_symmetry: CheckBox = %MirrorSymmetry
@onready var remove_box_collider: CheckBox = %RemoveBoxCollider
@onready var simplify_vertices: CheckBox = %SimplifyVertices
@onready var max_vertices_spinbox: SpinBox = %MaxVerticesSpinBox
@onready var generate_button: Button = %GenerateButton
@onready var preview_button: Button = %PreviewButton
@onready var remove_button: Button = %RemoveButton
@onready var status_label: Label = %StatusLabel
@onready var collision_list_container: VBoxContainer = %CollisionListContainer

# Collision layer for ship physics (layer 3)
const PHYSICS_COLLISION_LAYER: int = 1 << 2
const PHYSICS_COLLISION_MASK: int = 1 | (1 << 2)

# Names for generated collision shapes
const HULL_COLLISION_PREFIX = "HullPhysicsCollision"
const BOW_COLLISION_NAME = "BowPhysicsCollision"
const MID_COLLISION_NAME = "MidshipPhysicsCollision"
const STERN_COLLISION_NAME = "SternPhysicsCollision"


func _ready():
	generate_button.pressed.connect(_on_generate_pressed)
	preview_button.pressed.connect(_on_preview_pressed)
	remove_button.pressed.connect(_on_remove_pressed)

	# Update UI state
	_update_ui_state()


func set_ship(ship: Node3D) -> void:
	current_ship = ship
	_clear_preview()
	_update_ui_state()
	_update_collision_list()

	if ship:
		var ship_name = ship.get("ship_name") if "ship_name" in ship else ship.name
		ship_info_label.text = "Ship: %s" % ship_name
	else:
		ship_info_label.text = "No ship selected"


func _update_ui_state() -> void:
	var has_ship = current_ship != null
	generate_button.disabled = not has_ship
	preview_button.disabled = not has_ship
	remove_button.disabled = not has_ship or not _has_hull_collision()


func _update_collision_list() -> void:
	# Clear existing list
	for child in collision_list_container.get_children():
		child.queue_free()

	if not current_ship:
		return

	# Find existing collision shapes
	var collision_shapes = _find_collision_shapes()

	# Also find box colliders
	var box_colliders = _find_box_colliders()

	if collision_shapes.is_empty() and box_colliders.is_empty():
		var label = Label.new()
		label.text = "  (none)"
		label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		collision_list_container.add_child(label)
	else:
		for shape in collision_shapes:
			var hbox = HBoxContainer.new()

			var label = Label.new()
			label.text = "  • " + shape.name
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hbox.add_child(label)

			var shape_type = ""
			if shape.shape is ConvexPolygonShape3D:
				var points = (shape.shape as ConvexPolygonShape3D).points
				shape_type = "Convex (%d pts)" % points.size()
			elif shape.shape is BoxShape3D:
				shape_type = "Box"
			else:
				shape_type = "Other"

			var type_label = Label.new()
			type_label.text = shape_type
			type_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
			hbox.add_child(type_label)

			collision_list_container.add_child(hbox)

	# Show box colliders separately
	for box in box_colliders:
		var hbox = HBoxContainer.new()

		var label = Label.new()
		label.text = "  • " + box.name
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(label)

		var box_shape = box.shape as BoxShape3D
		var type_label = Label.new()
		type_label.text = "Box (%.0fx%.0fx%.0f)" % [box_shape.size.x, box_shape.size.y, box_shape.size.z]
		type_label.add_theme_color_override("font_color", Color(0.8, 0.6, 0.4))
		hbox.add_child(type_label)

		collision_list_container.add_child(hbox)


func _find_box_colliders() -> Array[CollisionShape3D]:
	"""Find original box colliders (not our generated hull collisions)."""
	var shapes: Array[CollisionShape3D] = []
	if not current_ship:
		return shapes

	for child in current_ship.get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			# Exclude our generated shapes
			if not child.name.begins_with(HULL_COLLISION_PREFIX) and \
			   child.name != BOW_COLLISION_NAME and \
			   child.name != MID_COLLISION_NAME and \
			   child.name != STERN_COLLISION_NAME:
				shapes.append(child)

	return shapes


func _find_collision_shapes() -> Array[CollisionShape3D]:
	var shapes: Array[CollisionShape3D] = []
	if not current_ship:
		return shapes

	for child in current_ship.get_children():
		if child is CollisionShape3D:
			if child.name.begins_with(HULL_COLLISION_PREFIX) or \
			   child.name == BOW_COLLISION_NAME or \
			   child.name == MID_COLLISION_NAME or \
			   child.name == STERN_COLLISION_NAME:
				shapes.append(child)

	return shapes


func _has_hull_collision() -> bool:
	return not _find_collision_shapes().is_empty()


func _on_generate_pressed() -> void:
	if not current_ship:
		_set_status("No ship selected", Color.RED)
		return

	_clear_preview()

	# Get options
	var include_super = include_superstructure.button_pressed
	var use_segments = segmented_hull.button_pressed
	var use_mirror = mirror_symmetry.button_pressed
	var remove_box = remove_box_collider.button_pressed
	var do_simplify = simplify_vertices.button_pressed
	var max_verts = int(max_vertices_spinbox.value)

	_set_status("Generating hull collision...", Color.YELLOW)

	# Remove existing hull collision shapes first
	_remove_hull_collisions(false)  # Don't update status

	# Remove original box collider if requested
	if remove_box:
		_remove_box_collider()

	# Collect vertices from hull meshes
	var all_points: PackedVector3Array = PackedVector3Array()
	_collect_hull_vertices(current_ship, all_points, include_super)

	if all_points.size() < 4:
		_set_status("Error: Not enough vertices found in hull meshes", Color.RED)
		return

	print("Hull Collision Editor: Found %d vertices" % all_points.size())

	# Apply mirroring with integrated simplification if enabled
	# This simplifies starboard first, preserves centerline, then mirrors
	if use_mirror:
		all_points = _apply_mirror_symmetry_with_simplify(all_points, do_simplify, max_verts)
		print("Hull Collision Editor: After mirror+simplify: %d vertices" % all_points.size())
		# Don't simplify again later since it's already done
		do_simplify = false

	var shapes_created = 0
	var undo_redo = plugin.get_undo_redo()

	if use_segments:
		# Generate segmented hull
		var segments = _generate_segmented_hull(all_points, do_simplify, max_verts)

		undo_redo.create_action("Generate Segmented Hull Collision")
		for segment in segments:
			undo_redo.add_do_method(current_ship, "add_child", segment)
			undo_redo.add_do_method(segment, "set_owner", current_ship.owner if current_ship.owner else current_ship)
			undo_redo.add_do_reference(segment)
			undo_redo.add_undo_method(current_ship, "remove_child", segment)
			shapes_created += 1
		undo_redo.commit_action()
	else:
		# Generate single convex hull
		if do_simplify:
			all_points = _simplify_points(all_points, max_verts)

		var convex_shape = ConvexPolygonShape3D.new()
		convex_shape.points = all_points

		var collision_shape = CollisionShape3D.new()
		collision_shape.shape = convex_shape
		collision_shape.name = HULL_COLLISION_PREFIX

		undo_redo.create_action("Generate Hull Collision")
		undo_redo.add_do_method(current_ship, "add_child", collision_shape)
		undo_redo.add_do_method(collision_shape, "set_owner", current_ship.owner if current_ship.owner else current_ship)
		undo_redo.add_do_reference(collision_shape)
		undo_redo.add_undo_method(current_ship, "remove_child", collision_shape)
		undo_redo.commit_action()

		shapes_created = 1

	# Configure collision layers on the ship
	_configure_ship_collision_layers()

	_update_collision_list()
	_update_ui_state()
	_set_status("Created %d collision shape(s) with %d vertices" % [shapes_created, all_points.size()], Color.GREEN)

	# Mark scene as modified
	if current_ship.owner:
		EditorInterface.mark_scene_as_unsaved()

	# Refresh gizmos to show new collision shapes
	_refresh_gizmos()


func _refresh_gizmos() -> void:
	"""Force the editor to redraw gizmos for the current ship."""
	if plugin:
		plugin.update_overlays()

	# Also request a redraw on the next frame to ensure visibility
	_needs_gizmo_refresh = true


func _process(_delta: float) -> void:
	if _needs_gizmo_refresh and plugin:
		plugin.update_overlays()
		_needs_gizmo_refresh = false


func _remove_box_collider() -> void:
	"""Remove the original BoxShape3D collider from the ship."""
	if not current_ship:
		return

	var undo_redo = plugin.get_undo_redo()

	for child in current_ship.get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			# Don't remove our generated shapes
			if not child.name.begins_with(HULL_COLLISION_PREFIX) and \
			   child.name != BOW_COLLISION_NAME and \
			   child.name != MID_COLLISION_NAME and \
			   child.name != STERN_COLLISION_NAME:
				undo_redo.create_action("Remove Box Collider")
				undo_redo.add_do_method(current_ship, "remove_child", child)
				undo_redo.add_undo_method(current_ship, "add_child", child)
				undo_redo.add_undo_method(child, "set_owner", current_ship.owner if current_ship.owner else current_ship)
				undo_redo.add_undo_reference(child)
				undo_redo.commit_action()
				print("Hull Collision Editor: Removed box collider '%s'" % child.name)
				_refresh_gizmos()
				return  # Only remove first box collider found


func _configure_ship_collision_layers() -> void:
	"""Set the ship's collision layer and mask for physics interaction."""
	if not current_ship or not current_ship is RigidBody3D:
		return

	var rigid_body = current_ship as RigidBody3D

	# Set collision layer to layer 3 (ships)
	rigid_body.collision_layer = PHYSICS_COLLISION_LAYER

	# Set collision mask to collide with terrain (layer 1) and other ships (layer 3)
	rigid_body.collision_mask = PHYSICS_COLLISION_MASK

	# Enable contact monitoring for collision detection
	rigid_body.contact_monitor = true
	rigid_body.max_contacts_reported = 4

	print("Hull Collision Editor: Configured collision layers (layer=%d, mask=%d)" % [
		PHYSICS_COLLISION_LAYER, PHYSICS_COLLISION_MASK])


func _on_preview_pressed() -> void:
	if not current_ship:
		return

	# Toggle preview
	if not preview_meshes.is_empty():
		_clear_preview()
		preview_button.text = "Preview (Wireframe)"
		return

	preview_button.text = "Hide Preview"

	# Get options
	var include_super = include_superstructure.button_pressed
	var use_segments = segmented_hull.button_pressed
	var use_mirror = mirror_symmetry.button_pressed
	var do_simplify = simplify_vertices.button_pressed
	var max_verts = int(max_vertices_spinbox.value)

	# Collect vertices
	var all_points: PackedVector3Array = PackedVector3Array()
	_collect_hull_vertices(current_ship, all_points, include_super)

	# Apply mirroring with integrated simplification if enabled
	if use_mirror:
		all_points = _apply_mirror_symmetry_with_simplify(all_points, do_simplify, max_verts)
		do_simplify = false  # Already simplified

	if all_points.size() < 4:
		_set_status("Not enough vertices for preview", Color.RED)
		return

	if use_segments:
		var segments_data = _get_segmented_points(all_points)
		var colors = [Color.RED, Color.GREEN, Color.BLUE]
		var names = ["Bow", "Midship", "Stern"]

		for i in range(segments_data.size()):
			var points = segments_data[i]
			if points.size() >= 4:
				if do_simplify:
					points = _simplify_points(points, max_verts)
				var mesh = _create_preview_mesh(points, colors[i])
				mesh.name = "Preview_" + names[i]
				current_ship.add_child(mesh)
				preview_meshes.append(mesh)
	else:
		if do_simplify:
			all_points = _simplify_points(all_points, max_verts)
		var mesh = _create_preview_mesh(all_points, Color.CYAN)
		mesh.name = "Preview_Hull"
		current_ship.add_child(mesh)
		preview_meshes.append(mesh)

	_set_status("Showing preview (%d vertices)" % all_points.size(), Color.CYAN)


func _on_remove_pressed() -> void:
	_remove_hull_collisions(true)


func _remove_hull_collisions(update_status: bool) -> void:
	if not current_ship:
		return

	var shapes = _find_collision_shapes()
	if shapes.is_empty():
		if update_status:
			_set_status("No hull collision shapes to remove", Color.YELLOW)
		return

	var undo_redo = plugin.get_undo_redo()
	undo_redo.create_action("Remove Hull Collision")

	for shape in shapes:
		undo_redo.add_do_method(current_ship, "remove_child", shape)
		undo_redo.add_undo_method(current_ship, "add_child", shape)
		undo_redo.add_undo_method(shape, "set_owner", current_ship.owner if current_ship.owner else current_ship)
		undo_redo.add_undo_reference(shape)

	undo_redo.commit_action()

	_update_collision_list()
	_update_ui_state()

	if update_status:
		_set_status("Removed %d collision shape(s)" % shapes.size(), Color.GREEN)
		EditorInterface.mark_scene_as_unsaved()
		_refresh_gizmos()


func _clear_preview() -> void:
	for mesh in preview_meshes:
		if is_instance_valid(mesh):
			mesh.queue_free()
	preview_meshes.clear()
	preview_button.text = "Preview (Wireframe)"


func _set_status(text: String, color: Color) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", color)


# ============================================================================
# Hull vertex collection
# ============================================================================

func _collect_hull_vertices(node: Node, points: PackedVector3Array, include_superstructure: bool) -> void:
	var node_name_lower = node.name.to_lower()

	# Check if this is a hull-related mesh
	var is_hull_mesh = (
		node_name_lower.contains("hull") or
		node_name_lower.contains("bow") or
		node_name_lower.contains("stern") or
		node_name_lower.contains("casemate") or
		node_name_lower.contains("citadel")
	)

	if include_superstructure:
		is_hull_mesh = is_hull_mesh or node_name_lower.contains("superstructure")

	# Skip armor collision meshes (they're handled separately for raycasting)
	var is_armor_col = node_name_lower.ends_with("_col")

	# Skip preview meshes
	var is_preview = node_name_lower.begins_with("preview_")

	if node is MeshInstance3D and is_hull_mesh and not is_armor_col and not is_preview:
		var mesh_instance = node as MeshInstance3D
		_extract_mesh_vertices(mesh_instance, points)

	# Recurse into children
	for child in node.get_children():
		_collect_hull_vertices(child, points, include_superstructure)


func _extract_mesh_vertices(mesh_instance: MeshInstance3D, points: PackedVector3Array) -> void:
	var mesh = mesh_instance.mesh
	if mesh == null:
		return

	var global_transform = mesh_instance.global_transform
	var ship_transform_inv = current_ship.global_transform.affine_inverse()

	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		if arrays.size() > Mesh.ARRAY_VERTEX:
			var vertices = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			if vertices:
				for vertex in vertices:
					# Transform to ship-local space
					var world_pos = global_transform * vertex
					var local_pos = ship_transform_inv * world_pos
					points.append(local_pos)


# ============================================================================
# Symmetry mirroring
# ============================================================================

const CENTERLINE_THRESHOLD: float = 0.5  # Points within this distance of X=0 are considered on centerline

func _apply_mirror_symmetry_with_simplify(points: PackedVector3Array, do_simplify: bool, max_verts: int) -> PackedVector3Array:
	"""
	Enforce port/starboard symmetry with integrated simplification.

	Strategy:
	1. Extract critical centerline vertices (bow tip, stern tip, keel extremes)
	2. Separate starboard (positive X) vertices from centerline
	3. Simplify only the starboard vertices (if enabled)
	4. Recombine with preserved centerline vertices
	5. Mirror starboard to create port side

	This ensures:
	- Perfect symmetry after simplification
	- Critical hull shape points (bow/stern tips) are never lost
	"""

	# Step 1: Find the Z extents to identify bow and stern tips
	var min_z: float = INF
	var max_z: float = -INF
	var min_y: float = INF
	var max_y: float = -INF

	for point in points:
		min_z = min(min_z, point.z)
		max_z = max(max_z, point.z)
		min_y = min(min_y, point.y)
		max_y = max(max_y, point.y)

	var z_length = max_z - min_z
	var bow_zone = max_z - z_length * 0.05  # Front 5% is bow tip zone
	var stern_zone = min_z + z_length * 0.05  # Rear 5% is stern tip zone

	# Step 2: Separate vertices into categories
	var critical_centerline: PackedVector3Array = PackedVector3Array()  # Never simplified
	var regular_centerline: PackedVector3Array = PackedVector3Array()  # Can be simplified
	var starboard_points: PackedVector3Array = PackedVector3Array()  # Will be simplified then mirrored

	for point in points:
		var is_centerline = abs(point.x) <= CENTERLINE_THRESHOLD
		var is_bow_tip = point.z >= bow_zone and is_centerline
		var is_stern_tip = point.z <= stern_zone and is_centerline
		var is_keel_extreme = (point.y <= min_y + 1.0 or point.y >= max_y - 1.0) and is_centerline

		if is_bow_tip or is_stern_tip or is_keel_extreme:
			# Critical centerline point - never simplify
			critical_centerline.append(Vector3(0.0, point.y, point.z))  # Snap to exact centerline
		elif is_centerline:
			# Regular centerline point - can be simplified but not mirrored
			regular_centerline.append(Vector3(0.0, point.y, point.z))  # Snap to exact centerline
		elif point.x > 0:
			# Starboard point - will be simplified and mirrored
			starboard_points.append(point)
		# Ignore port side points - they'll be recreated by mirroring

	print("Hull Collision Editor: Critical centerline: %d, Regular centerline: %d, Starboard: %d" % [
		critical_centerline.size(), regular_centerline.size(), starboard_points.size()])

	# Step 3: Simplify starboard and regular centerline if enabled
	if do_simplify and starboard_points.size() > 0:
		# Reserve some vertices for centerline, rest for starboard
		var centerline_budget = min(regular_centerline.size(), max_verts / 4)
		var starboard_budget = max_verts / 2 - critical_centerline.size() / 2 - centerline_budget / 2
		starboard_budget = max(starboard_budget, 16)  # Minimum vertices

		starboard_points = _simplify_points(starboard_points, starboard_budget)

		if regular_centerline.size() > centerline_budget:
			regular_centerline = _simplify_centerline(regular_centerline, centerline_budget)

	# Step 4: Deduplicate critical centerline points
	critical_centerline = _deduplicate_points(critical_centerline, 0.5)

	# Step 5: Build final point array
	var result: PackedVector3Array = PackedVector3Array()

	# Add critical centerline points (already at X=0)
	for point in critical_centerline:
		result.append(point)

	# Add regular centerline points (already at X=0)
	for point in regular_centerline:
		result.append(point)

	# Add starboard points and their port mirrors
	for point in starboard_points:
		result.append(point)  # Starboard
		result.append(Vector3(-point.x, point.y, point.z))  # Port mirror

	print("Hull Collision Editor: Final vertex count: %d" % result.size())
	return result


func _simplify_centerline(points: PackedVector3Array, target_count: int) -> PackedVector3Array:
	"""
	Simplify centerline points while preserving Z distribution.
	Uses 1D simplification along the Z axis.
	"""
	if points.size() <= target_count:
		return points

	# Sort by Z position
	var point_list: Array = []
	for point in points:
		point_list.append(point)

	point_list.sort_custom(func(a, b): return a.z < b.z)

	# Sample evenly along Z
	var result: PackedVector3Array = PackedVector3Array()
	var step = float(point_list.size() - 1) / float(target_count - 1) if target_count > 1 else 1.0

	for i in range(target_count):
		var idx = int(i * step)
		idx = min(idx, point_list.size() - 1)
		result.append(point_list[idx])

	return result


func _deduplicate_points(points: PackedVector3Array, threshold: float) -> PackedVector3Array:
	"""Remove duplicate points within threshold distance."""
	var result: PackedVector3Array = PackedVector3Array()

	for point in points:
		var is_duplicate = false
		for existing in result:
			if point.distance_to(existing) < threshold:
				is_duplicate = true
				break
		if not is_duplicate:
			result.append(point)

	return result


func _apply_mirror_symmetry(points: PackedVector3Array) -> PackedVector3Array:
	"""
	Simple mirror symmetry without simplification integration.
	Use _apply_mirror_symmetry_with_simplify for better results.
	"""
	return _apply_mirror_symmetry_with_simplify(points, false, 0)


# ============================================================================
# Hull generation
# ============================================================================

func _generate_segmented_hull(all_points: PackedVector3Array, do_simplify: bool, max_verts: int) -> Array[CollisionShape3D]:
	var shapes: Array[CollisionShape3D] = []
	var segments = _get_segmented_points(all_points)
	var names = [STERN_COLLISION_NAME, MID_COLLISION_NAME, BOW_COLLISION_NAME]

	for i in range(segments.size()):
		var points = segments[i]
		if points.size() < 4:
			continue

		if do_simplify:
			points = _simplify_points(points, max_verts)

		var convex_shape = ConvexPolygonShape3D.new()
		convex_shape.points = points

		var collision_shape = CollisionShape3D.new()
		collision_shape.shape = convex_shape
		collision_shape.name = names[i]

		shapes.append(collision_shape)

	return shapes


func _get_segmented_points(all_points: PackedVector3Array) -> Array[PackedVector3Array]:
	# Calculate bounding box to determine segmentation
	var min_z: float = INF
	var max_z: float = -INF
	for point in all_points:
		min_z = min(min_z, point.z)
		max_z = max(max_z, point.z)

	var length = max_z - min_z
	var segment_size = length / 3.0

	# Create three segments: stern, midship, bow
	var stern_points: PackedVector3Array = PackedVector3Array()
	var mid_points: PackedVector3Array = PackedVector3Array()
	var bow_points: PackedVector3Array = PackedVector3Array()

	for point in all_points:
		var relative_z = point.z - min_z
		if relative_z < segment_size:
			stern_points.append(point)
		elif relative_z < segment_size * 2:
			mid_points.append(point)
		else:
			bow_points.append(point)

	return [stern_points, mid_points, bow_points]


func _simplify_points(points: PackedVector3Array, target_count: int) -> PackedVector3Array:
	if points.size() <= target_count:
		return points

	# Use spatial hashing to reduce points, keeping extreme values for convex hull
	var cell_size = _calculate_optimal_cell_size(points, target_count)
	var grid: Dictionary = {}  # Maps cell_key to list of points in that cell

	# Step 1: Collect all points into cells
	for point in points:
		var cell_key = Vector3i(
			int(point.x / cell_size) if point.x >= 0 else int(point.x / cell_size) - 1,
			int(point.y / cell_size) if point.y >= 0 else int(point.y / cell_size) - 1,
			int(point.z / cell_size) if point.z >= 0 else int(point.z / cell_size) - 1
		)

		if not grid.has(cell_key):
			grid[cell_key] = []
		grid[cell_key].append(point)

	# Step 2: For each cell, find extreme points from the complete list
	var simplified_set: Dictionary = {}  # Use as set to avoid duplicates
	var simplified = PackedVector3Array()

	for cell_key in grid:
		var cell_points: Array = grid[cell_key]
		if cell_points.is_empty():
			continue

		var x_dir = 1
		var y_dir = 1
		var z_dir = 1

		var point_avg = cell_points[0]

		# Find extremes from the complete list of points in this cell
		var max_x_point = cell_points[0]
		var min_x_point = cell_points[0]
		var max_y_point = cell_points[0]
		var min_y_point = cell_points[0]
		var max_z_point = cell_points[0]
		var min_z_point = cell_points[0]


		var extreme_point = Vector3.ZERO
		for point in cell_points:
			extreme_point += point
			if point.x > max_x_point.x:
				max_x_point = point
			if point.x < min_x_point.x:
				min_x_point = point
			if point.y > max_y_point.y:
				max_y_point = point
			if point.y < min_y_point.y:
				min_y_point = point
			if point.z > max_z_point.z:
				max_z_point = point
			if point.z < min_z_point.z:
				min_z_point = point
		extreme_point /= cell_points.size()

		if abs(extreme_point.x) > abs(extreme_point.y):
			if abs(extreme_point.x) > abs(extreme_point.z):
				if extreme_point.x >= 0.0:
					simplified.append(max_x_point)
				else:
					simplified.append(min_x_point)
			else:
				if extreme_point.z >= 0.0:
					simplified.append(max_z_point)
				else:
					simplified.append(min_z_point)
		else:
			if abs(extreme_point.y) > abs(extreme_point.z):
				if extreme_point.y >= 0.0:
					simplified.append(max_y_point)
				else:
					simplified.append(min_y_point)
			else:
				if extreme_point.z >= 0:
					simplified.append(max_z_point)
				else:
					simplified.append(min_z_point)

		# # Add all extreme points (using string key for deduplication)
		# for extreme_point in [max_x_point, min_x_point, max_y_point, min_y_point, max_z_point, min_z_point]:
		# 	var key = "%.4f,%.4f,%.4f" % [extreme_point.x, extreme_point.y, extreme_point.z]
		# 	simplified_set[key] = extreme_point

	# for point in simplified_set.values():
	# 	simplified.append(point)

	return simplified


func _calculate_optimal_cell_size(points: PackedVector3Array, target_count: int) -> float:
	if points.size() == 0:
		return 1.0

	# Calculate bounding box
	var min_pt = points[0]
	var max_pt = points[0]

	for point in points:
		min_pt.x = min(min_pt.x, point.x)
		min_pt.y = min(min_pt.y, point.y)
		min_pt.z = min(min_pt.z, point.z)
		max_pt.x = max(max_pt.x, point.x)
		max_pt.y = max(max_pt.y, point.y)
		max_pt.z = max(max_pt.z, point.z)

	var size = max_pt - min_pt
	var volume = size.x * size.y * size.z

	# Estimate cell size to get approximately target_count cells
	if volume > 0 and target_count > 0:
		return pow(volume / float(target_count), 1.0 / 3.0)

	return max(size.x, max(size.y, size.z)) / 10.0


# ============================================================================
# Preview mesh generation
# ============================================================================

func _create_preview_mesh(points: PackedVector3Array, color: Color) -> MeshInstance3D:
	var mesh_instance = MeshInstance3D.new()

	# Create a convex hull and visualize it
	var convex = ConvexPolygonShape3D.new()
	convex.points = points

	# Use ArrayMesh to create wireframe-like visualization
	var array_mesh = ArrayMesh.new()
	var surface_arrays = []
	surface_arrays.resize(Mesh.ARRAY_MAX)

	# For visualization, we'll create a point cloud and edges
	# First, get the convex hull points (Godot may reduce them)
	var hull_points = convex.points

	# Create vertices for visualization
	surface_arrays[Mesh.ARRAY_VERTEX] = hull_points

	# Create a simple material
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color.a = 0.5
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Create a debug mesh from the shape
	var debug_mesh = convex.get_debug_mesh()
	mesh_instance.mesh = debug_mesh
	mesh_instance.material_override = material

	# Don't save this to the scene
	mesh_instance.set_meta("_edit_lock_", true)

	return mesh_instance
