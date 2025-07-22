# addons/turret_editor/turret_editor_plugin.gd
@tool
extends EditorPlugin

var turret_gizmo_plugin
var editor_panel
var current_turret

func _enter_tree():
	# Register our gizmo plugin
	turret_gizmo_plugin = TurretGizmoPlugin.new()
	add_node_3d_gizmo_plugin(turret_gizmo_plugin)
	
	# Create editor panel
	editor_panel = preload("res://addons/turret_editor/turret_editor_panel.tscn").instantiate()
	editor_panel.plugin = self
	
	# Add panel to editor
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, editor_panel)
	
	# Hide panel by default until a turret is selected
	editor_panel.hide()

func _exit_tree():
	# Clean up
	remove_node_3d_gizmo_plugin(turret_gizmo_plugin)
	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, editor_panel)
	
	# Free memory
	if editor_panel:
		editor_panel.queue_free()

func _handles(object):
	# Detect if the selected object is a turret
	return object is Gun

func _edit(object):
	current_turret = object
	
	# Update the editor panel with the selected turret
	if editor_panel:
		editor_panel.set_turret(current_turret)
		editor_panel.show()

func _make_visible(visible):
	# Show or hide the editor panel
	if editor_panel:
		if visible and current_turret is Gun:
			editor_panel.show()
		else:
			editor_panel.hide()

func update_gizmos():
	# Force gizmo update when something changes
	if current_turret:
		# Request the editor to redraw
		update_overlays()
		
		# Make the gizmo plugin redraw all gizmos
		remove_node_3d_gizmo_plugin(turret_gizmo_plugin)
		add_node_3d_gizmo_plugin(turret_gizmo_plugin)
