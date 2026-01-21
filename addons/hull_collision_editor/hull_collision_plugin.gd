# addons/hull_collision_editor/hull_collision_plugin.gd
@tool
extends EditorPlugin

var editor_panel: Control
var current_ship: Node
var gizmo_plugin: EditorNode3DGizmoPlugin

func _enter_tree():
	# Register gizmo plugin for collision visualization
	gizmo_plugin = preload("res://addons/hull_collision_editor/hull_collision_gizmo.gd").new()
	add_node_3d_gizmo_plugin(gizmo_plugin)

	# Defer panel creation to ensure resources are loaded
	call_deferred("_setup_panel")

func _setup_panel():
	# Create editor panel with error handling
	var panel_scene = load("res://addons/hull_collision_editor/hull_collision_panel.tscn")
	if panel_scene == null:
		push_error("Hull Collision Editor: Could not load panel scene")
		return

	editor_panel = panel_scene.instantiate()
	if editor_panel == null:
		push_error("Hull Collision Editor: Could not instantiate panel")
		return

	editor_panel.plugin = self

	# Add panel to editor
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, editor_panel)

	# Hide panel by default until a ship is selected
	editor_panel.hide()

func _exit_tree():
	# Clean up gizmo plugin
	if gizmo_plugin:
		remove_node_3d_gizmo_plugin(gizmo_plugin)
		gizmo_plugin = null

	# Clean up panel
	if editor_panel and is_instance_valid(editor_panel):
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, editor_panel)
		editor_panel.queue_free()
		editor_panel = null

func _handles(object) -> bool:
	# Detect if the selected object is a Ship (RigidBody3D with ship_name property)
	if object is RigidBody3D:
		# Check if it has ship-related properties
		if "ship_name" in object:
			return true
		# Also check by script class name
		var script = object.get_script()
		if script and script.get_global_name() == "Ship":
			return true
	return false

func _edit(object):
	current_ship = object

	# Update the editor panel with the selected ship
	if editor_panel and is_instance_valid(editor_panel):
		editor_panel.set_ship(current_ship)
		editor_panel.show()

	# Force gizmo redraw
	update_overlays()

func _make_visible(visible: bool):
	# Show or hide the editor panel
	if editor_panel and is_instance_valid(editor_panel):
		if visible and current_ship:
			editor_panel.show()
		else:
			editor_panel.hide()
