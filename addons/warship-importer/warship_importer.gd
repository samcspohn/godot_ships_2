@tool
extends EditorPlugin

const GUN_SCRIPT_PATH := "res://src/artillary/Guns/Gun.gd"
const TORPEDO_SCRIPT_PATH := "res://src/torpedo/torpedo_launcher.gd"

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

## Creates res://assets/turrets/<turret_name>.tscn as an inherited scene of
## the GLB at res://assets/turrets/glb/<turret_name>.glb, ensuring the GLB
## imports with the matching turret script attached to its root.
## Returns the saved .tscn path, or "" if no GLB was found.
func create_scene_from_glb(turret_name: String) -> String:
	var glb_path := "res://assets/turrets/glb/%s.glb" % turret_name
	if not ResourceLoader.exists(glb_path):
		return ""

	if not ensure_turret_root_import(glb_path, turret_script_path(turret_name)):
		return ""

	# An inherited scene cannot be built with PackedScene.pack() from script:
	# the root's scene_inherited_state (what makes the saver emit
	# `instance=ExtResource(<glb>)`) is editor-internal and not exposed, and a
	# root's scene_file_path is ignored, so pack() always embeds a copy of the
	# GLB node tree. Write the .tscn text directly so the GLB stays referenced
	# and reimporting it updates the turret scene.
	var glb_uid := ResourceLoader.get_resource_uid(glb_path)
	var glb_ref := ResourceUID.id_to_text(glb_uid) if glb_uid != ResourceUID.INVALID_ID else glb_path
	var glb_uid_attr := (' uid="%s"' % glb_ref) if glb_uid != ResourceUID.INVALID_ID else ""
	var scene_uid := ResourceUID.id_to_text(ResourceUID.create_id())

	var text := "\n".join([
		'[gd_scene format=3 uid="%s"]' % scene_uid,
		"",
		'[ext_resource type="PackedScene"%s path="%s" id="1_glb"]' % [glb_uid_attr, glb_path],
		"",
		'[node name="%s" instance=ExtResource("1_glb")]' % turret_name,
		'glb_path = "%s"' % glb_ref,
		"",
	])

	var tscn_path := "res://assets/turrets/%s.tscn" % turret_name
	var file := FileAccess.open(tscn_path, FileAccess.WRITE)
	if file == null:
		printerr("Failed to write turret scene: ", tscn_path, " (error %d)" % FileAccess.get_open_error())
		return ""
	file.store_string(text)
	file.close()

	get_editor_interface().get_resource_filesystem().update_file(tscn_path)
	print("Created turret scene from GLB: ", tscn_path)
	return tscn_path

## Picks the turret script for a GLB from its naming convention: torpedo
## launchers carry a tube-count suffix (e.g. IJN_610mm_5t), guns a barrel
## count (e.g. GER_800mm_2b_rf).
func turret_script_path(turret_name: String) -> String:
	var regex := RegEx.new()
	regex.compile("_\\d+t(_|$)")
	if regex.search(turret_name) != null:
		return TORPEDO_SCRIPT_PATH
	return GUN_SCRIPT_PATH

## Sets the GLB's scene import options so its root node imports with the
## turret script attached (same as picking it as Root Type in the Import
## dock), then reimports it. Scenes inheriting the GLB are then turrets
## without needing a script override. A GLB whose import already has a root
## type or script configured is left untouched.
func ensure_turret_root_import(glb_path: String, script_path: String) -> bool:
	var import_path := glb_path + ".import"
	var config := ConfigFile.new()
	if config.load(import_path) != OK:
		printerr("Failed to read import settings: ", import_path)
		return false

	if config.get_value("params", "nodes/root_script", null) != null:
		return true
	if config.get_value("params", "nodes/root_type", "") != "":
		return true

	config.set_value("params", "nodes/root_type", script_path)
	config.set_value("params", "nodes/root_script", load(script_path))
	if config.save(import_path) != OK:
		printerr("Failed to write import settings: ", import_path)
		return false

	get_editor_interface().get_resource_filesystem().reimport_files(PackedStringArray([glb_path]))
	return true

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
