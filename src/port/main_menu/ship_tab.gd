# src/client/ship_tab.gd
extends Control

@onready var ship_button_container = $ScrollContainer/HBoxContainer
var ship_scenes = []
var selected_ship = null
var dock_node = null
var armor_view_enabled: bool = false
@onready var armor_view_button: Button = $ArmorViewButton

# Armor tooltip
var armor_tooltip: PanelContainer
var armor_tooltip_label: Label

# Armor part filter panel
var armor_filter_panel: PanelContainer
var armor_filter_buttons: Dictionary = {} # ArmorPart.Type -> Button
var armor_part_visibility: Dictionary = {} # ArmorPart.Type -> bool

# Dual-viewport armor overlay system
var armor_overlay: ArmorViewportOverlay

# Part type display order and labels
const PART_TYPES := [
	ArmorPart.Type.CITADEL,
	ArmorPart.Type.CASEMATE,
	ArmorPart.Type.BOW,
	ArmorPart.Type.STERN,
	ArmorPart.Type.SUPERSTRUCTURE,
	ArmorPart.Type.MODULE,
]

signal ship_selected(ship_node)

func _ready():
	_load_ship_buttons()
	armor_view_button.pressed.connect(_on_armor_view_toggled)
	_create_armor_tooltip()
	_create_armor_filter_panel()
	_init_part_visibility()
	_setup_armor_overlay()

	# If there's a previously selected ship, select it
	if GameSettings.selected_ship != "":
		call_deferred("_on_ship_button_pressed", GameSettings.selected_ship)

	visibility_changed.connect(_on_visibility_changed)

func set_dock_node(dock: Node3D):
	dock_node = dock

func _init_part_visibility():
	for part_type in PART_TYPES:
		armor_part_visibility[part_type] = true

func _setup_armor_overlay():
	# Create and add the ArmorViewportOverlay as a sibling via our parent
	# so it persists independently of this Control's visibility
	armor_overlay = ArmorViewportOverlay.new()
	armor_overlay.name = "ArmorViewportOverlay"
	# Add to the scene tree — we add it to ourselves; the CanvasLayer inside
	# it will handle rendering on top regardless
	add_child(armor_overlay)

func _create_armor_tooltip():
	armor_tooltip = PanelContainer.new()
	armor_tooltip.visible = false
	armor_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	armor_tooltip.z_index = 100

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.85)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	armor_tooltip.add_theme_stylebox_override("panel", style)

	armor_tooltip_label = Label.new()
	armor_tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	armor_tooltip.add_child(armor_tooltip_label)

	add_child(armor_tooltip)

func _create_armor_filter_panel():
	armor_filter_panel = PanelContainer.new()
	armor_filter_panel.visible = false

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.12, 0.9)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	armor_filter_panel.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	armor_filter_panel.add_child(vbox)

	for part_type in PART_TYPES:
		var btn = Button.new()
		btn.text = _get_part_type_name(part_type)
		btn.toggle_mode = true
		btn.button_pressed = true
		btn.custom_minimum_size = Vector2(110, 0)
		btn.pressed.connect(_on_part_filter_toggled.bind(part_type))
		vbox.add_child(btn)
		armor_filter_buttons[part_type] = btn

	# Position below the ArmorViewButton
	armor_filter_panel.layout_mode = 1
	armor_filter_panel.anchors_preset = Control.PRESET_TOP_LEFT
	armor_filter_panel.offset_left = 10.0
	armor_filter_panel.offset_top = 46.0

	add_child(armor_filter_panel)

func _load_ship_buttons():
	# Only allow selection of Bismarck3 and H44
	var available_ships = [
		{"name": "Bismarck3", "path": "res://Ships/Bismarck/Bismarck3.tscn"},
		{"name": "H44", "path": "res://Ships/H44/H44.tscn"},
		{"name": "Yamato", "path": "res://Ships/Yamato/Yamato.tscn"},
		{"name": "Shimakaze", "path": "res://Ships/Shimakaze/Shimakaze.tscn"},
		{"name": "Des Moines", "path": "res://Ships/DesMoines/DesMoines.tscn"},
	]

	for ship_data in available_ships:
		var button = Button.new()
		button.text = ship_data.name
		button.pressed.connect(_on_ship_button_pressed.bind(ship_data.path))
		ship_button_container.add_child(button)

func _scan_directory(path: String):
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir() and file_name != "." and file_name != "..":
				var ship_path = path + file_name + "/" + "ship.tscn"
				ship_scenes.append(ship_path)
				var button = Button.new()
				button.text = file_name.get_basename()
				button.pressed.connect(_on_ship_button_pressed.bind(ship_path))
				ship_button_container.add_child(button)
			file_name = dir.get_next()
		dir.list_dir_end()

func _on_ship_button_pressed(ship_path):
	if selected_ship != null:
		selected_ship.queue_free()
	var ship_asset = load(ship_path)
	if ship_asset == null:
		return
	selected_ship = ship_asset.instantiate()
	GameSettings.selected_ship = ship_path
	if dock_node:
		dock_node.add_child(selected_ship)
		selected_ship.position = Vector3(0,0,0)

	# Hide armor meshes in the main viewport (they start with layers=0 in the scene)
	# and populate the armor overlay viewport if armor view is enabled
	if armor_view_enabled:
		_apply_armor_visibility()

	# Emit signal that ship was selected
	ship_selected.emit(selected_ship)

func _on_armor_view_toggled():
	armor_view_enabled = armor_view_button.button_pressed
	armor_view_button.text = "Hide Armor" if armor_view_enabled else "Show Armor"
	armor_filter_panel.visible = armor_view_enabled
	if armor_view_enabled:
		if selected_ship != null:
			_apply_armor_visibility()
	else:
		armor_overlay.disable()
		if selected_ship != null:
			_set_armor_visibility_main(selected_ship, false)
		armor_tooltip.visible = false

func _on_part_filter_toggled(part_type: ArmorPart.Type):
	armor_part_visibility[part_type] = armor_filter_buttons[part_type].button_pressed
	if selected_ship != null and armor_view_enabled:
		_apply_armor_visibility()

func _on_visibility_changed():
	if selected_ship == null:
		return
	if is_visible_in_tree():
		# Returning to ship tab - restore armor view if it was enabled
		if armor_view_enabled:
			_apply_armor_visibility()
			armor_filter_panel.visible = true
	else:
		# Leaving ship tab - disable armor overlay and hide armor
		armor_overlay.disable()
		_set_armor_visibility_main(selected_ship, false)
		armor_tooltip.visible = false
		armor_filter_panel.visible = false

func _physics_process(_delta: float) -> void:
	if not armor_view_enabled or selected_ship == null or not is_visible_in_tree():
		armor_tooltip.visible = false
		return

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		armor_tooltip.visible = false
		return

	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	var ray_end := ray_origin + ray_dir * 1000.0

	# Raycast in the MAIN world (where the original armor StaticBody3D colliders live)
	var space_state := camera.get_world_3d().direct_space_state
	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.from = ray_origin
	ray_query.to = ray_end
	ray_query.collision_mask = 1 << 1
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false

	var exclude: Array[RID] = []
	var result := space_state.intersect_ray(ray_query)

	while not result.is_empty():
		var armor: ArmorPart = result.get('collider') as ArmorPart
		if armor != null and armor_part_visibility.get(armor.type, true):
			_show_armor_tooltip(mouse_pos, armor, result.get('face_index', -1))
			return
		# Not a visible armor part — exclude and keep casting
		exclude.append(result.get('rid'))
		ray_query.exclude = exclude
		result = space_state.intersect_ray(ray_query)

	armor_tooltip.visible = false

func _show_armor_tooltip(mouse_pos: Vector2, armor: ArmorPart, face_index: int) -> void:
	var thickness := armor.get_armor(face_index)
	var part_name := _get_part_type_name(armor.type)

	armor_tooltip_label.text = "%s\n%d mm" % [part_name, thickness]
	armor_tooltip.visible = true

	# Position tooltip offset from cursor
	var offset := Vector2(16, 16)
	var tooltip_pos := mouse_pos + offset

	# Keep tooltip on screen
	var viewport_size := get_viewport_rect().size
	armor_tooltip.reset_size()
	var tooltip_size := armor_tooltip.size
	if tooltip_pos.x + tooltip_size.x > viewport_size.x:
		tooltip_pos.x = mouse_pos.x - tooltip_size.x - 8
	if tooltip_pos.y + tooltip_size.y > viewport_size.y:
		tooltip_pos.y = mouse_pos.y - tooltip_size.y - 8

	armor_tooltip.global_position = tooltip_pos

func _get_part_type_name(type: ArmorPart.Type) -> String:
	match type:
		ArmorPart.Type.CITADEL:
			return "Citadel"
		ArmorPart.Type.CASEMATE:
			return "Casemate"
		ArmorPart.Type.BOW:
			return "Bow"
		ArmorPart.Type.STERN:
			return "Stern"
		ArmorPart.Type.SUPERSTRUCTURE:
			return "Superstructure"
		ArmorPart.Type.MODULE:
			return "Modules"
	return "Unknown"

func _get_part_type_for_mesh_name(mesh_name: String) -> ArmorPart.Type:
	var lower := mesh_name.to_lower()
	if lower.contains("citadel"):
		return ArmorPart.Type.CITADEL
	elif lower.contains("casemate"):
		return ArmorPart.Type.CASEMATE
	elif lower.contains("bow"):
		return ArmorPart.Type.BOW
	elif lower.contains("stern"):
		return ArmorPart.Type.STERN
	elif lower.contains("superstructure"):
		return ArmorPart.Type.SUPERSTRUCTURE
	else:
		# Barbettes and everything else are modules
		return ArmorPart.Type.MODULE

## Apply armor visibility using the dual-viewport system.
## Armor meshes are hidden in the main viewport and rendered in the armor overlay viewport.
func _apply_armor_visibility() -> void:
	if selected_ship == null:
		return

	# Ensure armor meshes are hidden in the main viewport
	# (they should already have layers=0 from the scene, but ensure it)
	_set_armor_visibility_main(selected_ship, false)

	# Enable the overlay and populate it with the currently visible armor parts
	armor_overlay.enable()
	armor_overlay.populate_armor_meshes(selected_ship, armor_part_visibility)

## Hide or show armor meshes in the MAIN viewport by setting their render layers.
## With the dual-viewport system, armor meshes should always be hidden (layers=0)
## in the main viewport — they are rendered in the armor overlay viewport instead.
func _set_armor_visibility_main(node: Node, enabled: bool) -> void:
	if node is MeshInstance3D and String(node.name).contains("_col"):
		node.layers = 1 if enabled else 0
	for child in node.get_children():
		_set_armor_visibility_main(child, enabled)
