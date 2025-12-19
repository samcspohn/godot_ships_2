@tool
extends EditorPlugin

var button: Button

func _enter_tree() -> void:
	button = Button.new()
	button.text = "Apply Turrets"
	button.pressed.connect(_on_apply_turrets)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, button)

func _exit_tree() -> void:
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, button)
	button.queue_free()

func _on_apply_turrets() -> void:
	var selection := get_editor_interface().get_selection().get_selected_nodes()
	if selection.is_empty():
		printerr("Select a ship scene root node")
		return
	
	var root := selection[0]
	var count := process_turret_mounts(root)
	print("Applied %d turrets" % count)

func process_turret_mounts(node: Node) -> int:
	var count := 0
	
	for child in node.get_children():
		count += process_turret_mounts(child)
	
	if not node.name.begins_with("TurretMount_"):
		return count
	
	var turret_path := get_turret_path(node)
	if turret_path.is_empty():
		printerr("No turret_scene for: ", node.name)
		return count
	
	if not ResourceLoader.exists(turret_path):
		printerr("Turret scene not found: ", turret_path)
		return count
	
	for child in node.get_children():
		if child.scene_file_path == turret_path:
			return count
	
	var turret_scene: PackedScene = load(turret_path)
	var turret := turret_scene.instantiate()
	turret.name = node.name.replace("TurretMount_", "")
	node.add_child(turret)
	turret.owner = get_scene_root(node)
	
	return count + 1

func get_turret_path(node: Node) -> String:
	if node.has_meta("extras"):
		var extras = node.get_meta("extras")
		if extras is Dictionary and extras.has("turret_scene"):
			return extras["turret_scene"]
	if node.has_meta("turret_scene"):
		return node.get_meta("turret_scene")
	return ""

func get_scene_root(node: Node) -> Node:
	while node.owner != null:
		node = node.owner
	return node
