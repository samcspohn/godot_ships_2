# armor_viewport_overlay.gd
# Manages a secondary SubViewport that renders armor meshes opaquely,
# then composites them over the main view with translucency.
extends Node

class_name ArmorViewportOverlay

# The SubViewport that renders only armor geometry
var armor_viewport: SubViewport
# Container that stretches to fill the screen
var viewport_container: SubViewportContainer
# TextureRect that displays the armor viewport output with translucency
var overlay_rect: TextureRect
# ShaderMaterial for the overlay compositing
var overlay_material: ShaderMaterial
# The camera inside the armor viewport that mirrors the main camera
var armor_camera: Camera3D
# Reference to the main camera we're mirroring
var main_camera: Camera3D

# The opaque material used for armor meshes inside the armor viewport
var opaque_armor_material: StandardMaterial3D

# Track which MeshInstance3D nodes we've duplicated into the armor viewport
# Key: original MeshInstance3D instance_id, Value: duplicate MeshInstance3D
var armor_duplicates: Dictionary = {}

# Root node inside the armor viewport where duplicated armor meshes live
var armor_root: Node3D

# Whether the overlay is currently active
var active: bool = false

# Opacity of the armor overlay (0 = invisible, 1 = fully opaque)
var overlay_opacity: float = 0.5

# The CanvasLayer to hold the overlay so it renders on top of everything
var canvas_layer: CanvasLayer

func _ready():
	# Load the opaque armor material
	opaque_armor_material = load("res://Ships/Armor_viewer_opaque.tres") as StandardMaterial3D

	_setup_viewport()

func _setup_viewport():
	# Create a CanvasLayer so the overlay is always on top
	canvas_layer = CanvasLayer.new()
	canvas_layer.layer = -1
	canvas_layer.visible = false
	add_child(canvas_layer)

	# Create the SubViewport for armor rendering
	armor_viewport = SubViewport.new()
	armor_viewport.transparent_bg = true
	armor_viewport.size = Vector2i(1920, 1080) # Will be updated to match main viewport
	armor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	armor_viewport.own_world_3d = true # Separate world so only armor is rendered
	armor_viewport.msaa_3d = Viewport.MSAA_4X

	# Create root node for armor meshes inside the viewport
	armor_root = Node3D.new()
	armor_root.name = "ArmorRoot"
	armor_viewport.add_child(armor_root)

	# Create camera that will mirror the main camera
	armor_camera = Camera3D.new()
	armor_camera.name = "ArmorCamera"
	armor_viewport.add_child(armor_camera)

	# Add a light so unshaded works (it's unshaded so this is optional, but
	# just in case we switch to shaded later)
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	armor_viewport.add_child(light)

	# Add viewport as child of this node (not the canvas layer)
	add_child(armor_viewport)

	# Create the overlay TextureRect
	overlay_rect = TextureRect.new()
	overlay_rect.name = "ArmorOverlay"
	overlay_rect.anchors_preset = Control.PRESET_FULL_RECT
	overlay_rect.anchor_right = 1.0
	overlay_rect.anchor_bottom = 1.0
	overlay_rect.stretch_mode = TextureRect.STRETCH_SCALE
	overlay_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_rect.texture = armor_viewport.get_texture()

	# Load and apply the compositing shader
	var shader = load("res://src/port/main_menu/armor_overlay.gdshader") as Shader
	overlay_material = ShaderMaterial.new()
	overlay_material.shader = shader
	overlay_material.set_shader_parameter("opacity", overlay_opacity)
	overlay_rect.material = overlay_material

	canvas_layer.add_child(overlay_rect)

func set_opacity(value: float):
	overlay_opacity = clamp(value, 0.0, 1.0)
	if overlay_material:
		overlay_material.set_shader_parameter("opacity", overlay_opacity)

func set_main_camera(camera: Camera3D):
	main_camera = camera

func enable():
	if active:
		return
	active = true
	canvas_layer.visible = true
	_sync_viewport_size()

func disable():
	if not active:
		return
	active = false
	canvas_layer.visible = false
	clear_armor_meshes()

func is_active() -> bool:
	return active

func _process(_delta: float):
	if not active:
		return

	_sync_camera()
	_sync_viewport_size()
	_sync_armor_transforms()

func _sync_viewport_size():
	var main_vp = get_viewport()
	if main_vp and armor_viewport:
		var vp_size = main_vp.get_visible_rect().size
		var target_size = Vector2i(int(vp_size.x), int(vp_size.y))
		if armor_viewport.size != target_size:
			armor_viewport.size = target_size

func _sync_camera():
	if main_camera == null or armor_camera == null:
		# Try to find main camera from our viewport
		if main_camera == null:
			var vp = get_viewport()
			if vp:
				main_camera = vp.get_camera_3d()
		if main_camera == null:
			return

	# Copy the main camera's global transform and projection settings
	armor_camera.global_transform = main_camera.global_transform
	armor_camera.fov = main_camera.fov
	armor_camera.near = main_camera.near
	armor_camera.far = main_camera.far
	armor_camera.projection = main_camera.projection

## Populate the armor viewport with duplicates of armor meshes from the ship.
## Call this when armor view is toggled on or when a new ship is selected.
func populate_armor_meshes(ship_node: Node, part_visibility: Dictionary = {}):
	clear_armor_meshes()

	if ship_node == null:
		return

	_collect_armor_meshes(ship_node, ship_node, part_visibility)

func _get_part_type_for_mesh_name(mesh_name: String) -> int:
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
		return ArmorPart.Type.MODULE

func _collect_armor_meshes(node: Node, ship_root: Node, part_visibility: Dictionary):
	if node is MeshInstance3D and String(node.name).contains("_col"):
		var part_type = _get_part_type_for_mesh_name(String(node.name))
		var is_visible = part_visibility.get(part_type, true)

		if is_visible:
			_add_armor_duplicate(node, ship_root)

	for child in node.get_children():
		_collect_armor_meshes(child, ship_root, part_visibility)

func _add_armor_duplicate(original: MeshInstance3D, ship_root: Node):
	# Create a duplicate MeshInstance3D with the same mesh but opaque material
	var dup = MeshInstance3D.new()
	dup.mesh = original.mesh
	dup.material_override = opaque_armor_material
	# Render on all layers inside the armor viewport
	dup.layers = 1
	# Copy the global transform
	dup.global_transform = original.global_transform

	armor_root.add_child(dup)
	armor_duplicates[original.get_instance_id()] = {
		"duplicate": dup,
		"original": original
	}

func _sync_armor_transforms():
	# Keep duplicated armor meshes in sync with originals' global transforms
	for entry in armor_duplicates.values():
		var original: MeshInstance3D = entry["original"] as MeshInstance3D
		var dup: MeshInstance3D = entry["duplicate"] as MeshInstance3D
		if is_instance_valid(original) and is_instance_valid(dup):
			dup.global_transform = original.global_transform
		elif is_instance_valid(dup):
			dup.queue_free()

func clear_armor_meshes():
	for entry in armor_duplicates.values():
		var dup = entry["duplicate"]
		if is_instance_valid(dup):
			dup.queue_free()
	armor_duplicates.clear()

## Update visibility of armor parts by type. Call when filter toggles change.
func update_part_visibility(ship_node: Node, part_visibility: Dictionary):
	if not active or ship_node == null:
		return
	# Easiest approach: repopulate with new visibility settings
	populate_armor_meshes(ship_node, part_visibility)
