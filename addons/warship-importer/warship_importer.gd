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

	var turret_name := node.name.trim_prefix("TurretMount_")
	var turret_path := resolve_turret_path(node, turret_name)

	if turret_path.is_empty():
		turret_path = create_scene_from_glb(strip_mount_suffix(turret_name))
		if turret_path.is_empty():
			printerr("No turret scene or GLB found for: ", node.name)
			return count

	for child in node.get_children():
		if child.scene_file_path == turret_path:
			return count

	var turret_scene: PackedScene = load(turret_path)
	var turret := turret_scene.instantiate()
	turret.name = turret_name
	node.add_child(turret)
	turret.owner = get_scene_root(node)

	return count + 1

## Creates res://turrets/<turret_name>.tscn as an inherited scene of the GLB
## at res://turrets/glb/<turret_name>.glb with Gun.gd attached to the root.
## Returns the saved .tscn path, or "" if no GLB was found.
func create_scene_from_glb(turret_name: String) -> String:
	var glb_path := "res://assets/turrets/glb/%s.glb" % turret_name
	if not ResourceLoader.exists(glb_path):
		return ""

	var glb_scene: PackedScene = load(glb_path)
	if glb_scene == null:
		printerr("Failed to load GLB: ", glb_path)
		return ""

	# GEN_EDIT_STATE_INSTANCE sets the root's scene_file_path to the GLB so pack()
	# emits `instance=ExtResource(...)` and keeps the link live. MAIN_INHERITED
	# leaves scene_file_path empty, causing pack() to embed the GLB node tree.
	var root := glb_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	root.name = turret_name

	var gun_script: Script = load("res://src/artillary/Guns/Gun.gd")
	root.set_script(gun_script)
	root.set("glb_path", glb_path)

	var new_scene := PackedScene.new()
	new_scene.pack(root)
	root.queue_free()

	var tscn_path := "res://assets/turrets/%s.tscn" % turret_name
	var err := ResourceSaver.save(new_scene, tscn_path)
	if err != OK:
		printerr("Failed to save turret scene: ", tscn_path, " (error %d)" % err)
		return ""

	get_editor_interface().get_resource_filesystem().scan()
	print("Created turret scene from GLB: ", tscn_path)
	return tscn_path

## Resolves the turret .tscn to instance for a mount.
## Order: explicit metadata override, exact-name scene, then the same name
## with a trailing mount index (e.g. `_001`) stripped. Returns "" if none
## of these exist, signalling the caller to build one from a GLB.
func resolve_turret_path(node: Node, turret_name: String) -> String:
	var meta_path := get_turret_meta_path(node)
	if not meta_path.is_empty() and ResourceLoader.exists(meta_path):
		return meta_path

	var exact_path := "res://assets/turrets/%s.tscn" % turret_name
	if ResourceLoader.exists(exact_path):
		return exact_path

	var base_name := strip_mount_suffix(turret_name)
	if base_name != turret_name:
		var base_path := "res://assets/turrets/%s.tscn" % base_name
		if ResourceLoader.exists(base_path):
			return base_path

	return ""

## Removes a trailing duplicate-index suffix such as `_001` that Godot appends
## to repeated node names, leaving the underlying turret name intact.
func strip_mount_suffix(turret_name: String) -> String:
	var regex := RegEx.new()
	regex.compile("_\\d+$")
	return regex.sub(turret_name, "")

func get_turret_meta_path(node: Node) -> String:
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
