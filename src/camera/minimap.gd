extends Control

class_name Minimap

# Constants
const SHIP_MARKER_SIZE = 18
const PLAYER_COLOR = Color(1, 1, 1, 1) # White
const FRIENDLY_COLOR = Color(0, 1, 0, 1) # Green
const ENEMY_COLOR = Color(1, 0, 0, 1) # Red
const FOV_ARC_COLOR = Color(0.5, 0.8, 1.0, 0.25) # Translucent light blue
const FOV_ARC_RANGE = 15500.0 # Range of the FOV arc in world units
const FOV_ARC_SEGMENTS = 32 # Number of segments for smooth arc

# Static minimap texture shared across all instances
static var map_texture: ViewportTexture = null
static var is_initialized: bool = false

# Minimap properties
#@export var minimap_size: Vector2 = Vector2(200, 200)
var mm_idx = 2
const minimap_sizes: Array[float] = [100, 200, 300, 400, 500, 600, 700, 800]
var num_sizes: int = minimap_sizes.size()
const w_s: float = 35000.0 / 2.0
@export var world_rect: Rect2 = Rect2(-w_s, -w_s, 2 * w_s, 2 * w_s) # World boundaries

# Node references
var background: TextureRect
var ship_markers_canvas: Control
var player_ship: Node3D = null
var tracked_ships: Array[Dictionary] = []

# Scaling factor between world coordinates and minimap coordinates
var scale_factor: Vector2
var aim_point: Vector3
var battle_camera: Camera3D = null
static var snapshot_camera: Camera3D
static var minimap_viewport: SubViewport

func _ready():
	setup_minimap()

	# Apply existing texture if available
	if map_texture != null:
		background.texture = map_texture

	# Set up parent panel size for proper anchoring
	call_deferred("_setup_parent_panel_size")

func _setup_parent_panel_size():
	# Set up the parent panel size to match minimap size with proper anchoring
	var parent_panel = get_parent()
	if parent_panel:
		var minimap_size = minimap_sizes[mm_idx]
		parent_panel.offset_left = -minimap_size - 10  # 10px margin from right edge
		parent_panel.offset_top = -minimap_size - 10   # 10px margin from bottom edge

# Update setup_minimap to ensure consistent aspect ratio
func setup_minimap():
	# Set the minimap size
	custom_minimum_size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])
	size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])

	# Background texture with gray color for debugging
	background = TextureRect.new()
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])
	background.modulate = Color(1.0, 1.0, 1.0, 0.6)
	add_child(background)

	# Canvas for ship markers (clip_contents ensures all drawing stays within bounds)
	ship_markers_canvas = Control.new()
	ship_markers_canvas.size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])
	ship_markers_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ship_markers_canvas.clip_contents = true
	add_child(ship_markers_canvas)

	# Calculate scale factor (ensure x and y scales are the same)
	var minimap_scale = min(
		minimap_sizes[mm_idx] / world_rect.size.x,
		minimap_sizes[mm_idx] / world_rect.size.y
	)
	scale_factor = Vector2(minimap_scale, minimap_scale)
	print("Minimap scale factor: ", scale_factor)

# Server should call this to take a map snapshot once
static func server_take_map_snapshot(viewport: Viewport) -> void:
	# Create a dedicated viewport for minimap rendering
	minimap_viewport = SubViewport.new()
	minimap_viewport.size = Vector2i(1024, 1024) # Square resolution for 1:1 aspect ratio

	# Make the minimap viewport share the same world as the main viewport
	minimap_viewport.world_3d = viewport.world_3d

	# Create a new camera specifically for taking the snapshot
	snapshot_camera = Camera3D.new()
	snapshot_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	# Set camera to capture the entire world from top-down view
	var center_position = Vector3(
		0.0, # Center X
		1000, # Height above water
		0.0 # Center Z
	)

	# Position camera looking down
	# snapshot_camera.global_transform = Transform3D(
	# 	Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.DOWN),
	# 	center_position
	# )

	# Set aspect ratio to 1:1 for square minimap
	snapshot_camera.keep_aspect = Camera3D.KEEP_WIDTH

	# Use orthogonal projection for map view
	snapshot_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	snapshot_camera.size = 35000.0 # Match the world boundaries
	snapshot_camera.far = 1000.0
	snapshot_camera.far = 100000.0

	# Configure camera to capture all geometry (reset cull mask to default)
	snapshot_camera.cull_mask = 0xFFFFF # Enable all layers initially for testing

	# Add the viewport and camera to the scene temporarily
	viewport.get_tree().root.add_child(minimap_viewport)
	minimap_viewport.add_child(snapshot_camera)
	snapshot_camera.make_current()
	snapshot_camera.global_position = center_position
	snapshot_camera.look_at(Vector3.ZERO, Vector3.FORWARD)

	# Wait multiple frames to ensure rendering is fully updated
	# await viewport.get_tree().process_frame
	# await viewport.get_tree().process_frame
	#await viewport.get_tree().process_frame
	minimap_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	# Force a render update
	RenderingServer.force_sync()

	# Take screenshot from the dedicated viewport
	# var img = minimap_viewport.get_texture().get_image()
	# map_texture = ImageTexture.create_from_image(img)
	map_texture = minimap_viewport.get_texture()
	print("Server captured minimap texture")

	# Mark as initialized
	is_initialized = true
	#await viewport.get_tree().process_frame
	# await viewport.get_tree().process_frame
	# await viewport.get_tree().process_frame

	# Clean up - remove the dedicated viewport (which also removes the camera)
	#minimap_viewport.queue_free()

# Use this instead of the old take_map_snapshot
func take_map_snapshot(viewport: Viewport) -> void:
	# Only take a snapshot if we're on the server and don't have one already
	if map_texture == null:
		server_take_map_snapshot(viewport)
		background.texture = map_texture

# Update world_to_minimap_position to ensure correct scaling
func world_to_minimap_position(world_pos: Vector3) -> Vector2:
	# For naval games, we typically use X and Z coordinates for the map
	var map_pos = Vector2(world_pos.x, world_pos.z)

	# Calculate position relative to world boundaries
	var normalized_x = (map_pos.x - world_rect.position.x) / world_rect.size.x
	var normalized_y = (map_pos.y - world_rect.position.y) / world_rect.size.y

	# Ensure consistent aspect ratio
	return Vector2(
		normalized_x * minimap_sizes[mm_idx],
		normalized_y * minimap_sizes[mm_idx]
	)

func register_player_ship(ship: Node3D) -> void:
	player_ship = ship
	print("Player ship registered at: ", ship.global_position) # Debug info

func register_ship(ship: Node3D) -> void:
	if tracked_ships.find_custom(func (a): return a.ship == ship) == -1:
		var a = {"ship": ship, "init": null}
		tracked_ships.append(a)
		# Connect to ship's tree_exiting signal to remove it when destroyed
		if not ship.is_connected("tree_exiting", _on_ship_destroyed):
			ship.connect("tree_exiting", _on_ship_destroyed.bind(ship))

func _on_ship_destroyed(ship: Node3D) -> void:
	tracked_ships.erase(ship)

func clear_ships() -> void:
	tracked_ships.clear()
	player_ship = null

func _physics_process(_delta: float) -> void:
	# Clear previous drawing
	ship_markers_canvas.queue_redraw()

	# Setup draw signal - will be called by the rendering system
	if not ship_markers_canvas.is_connected("draw", _on_canvas_draw):
		ship_markers_canvas.connect("draw", _on_canvas_draw)

func _input(_event: InputEvent) -> void:
	var prev_mmidx = mm_idx
	if _event.is_action_pressed("map_up"):
		mm_idx = clamp(mm_idx + 1, 0, num_sizes - 1)
	elif _event.is_action_pressed("map_down"):
		mm_idx = clamp(mm_idx - 1, 0, num_sizes - 1)


	if prev_mmidx == mm_idx:
		return

	# Update parent panel size using anchoring - this automatically handles positioning
	var parent_panel = get_parent()
	if parent_panel:
		# Set the panel size to match the minimap size
		var minimap_size = minimap_sizes[mm_idx]
		parent_panel.offset_left = -minimap_size - 10  # 10px margin from right edge
		parent_panel.offset_top = -minimap_size - 10   # 10px margin from bottom edge

	# Clear existing children and rebuild
	for child in get_children():
		child.queue_free()

	setup_minimap()
	if map_texture != null:
		background.texture = map_texture

enum ShipState {
	ALLY,
	ENEMY,
	UNDETECTED,
	DETECTED,
	DEAD
}

# Draw signal handler
func _on_canvas_draw() -> void:
	# Draw a border around the minimap for visibility
	ship_markers_canvas.draw_rect(Rect2(Vector2.ZERO, Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])), Color(1, 1, 1, 0.5), false, 2.0)

	var ship = player_ship as Ship
	# Draw camera FOV arc
	draw_camera_fov_arc(ship.artillery_controller.get_params()._range)

	var ships_to_draw: Array = []
	var ship_auras_to_draw: Array = []
	# Draw tracked ships
	for dict in tracked_ships:
		var tracked_ship = dict["ship"] as Ship
		if is_instance_valid(tracked_ship):
			if tracked_ship.visible_to_enemy and tracked_ship.team.team_id != player_ship.team.team_id:
				dict.init = true
			if !dict.init and tracked_ship.team.team_id != player_ship.team.team_id:
				continue
			var is_friendly = false
			is_friendly = tracked_ship.team.team_id == player_ship.team.team_id if is_instance_valid(player_ship) and is_instance_valid(tracked_ship.team) and is_instance_valid(player_ship.team) else false

			# var color = FRIENDLY_COLOR if is_friendly else ENEMY_COLOR
			var ship_state = ShipState.ALLY if is_friendly else ShipState.ENEMY

			if tracked_ship.health_controller.is_dead():
				ship_state = ShipState.DEAD
			elif tracked_ship.visible_to_enemy and is_friendly:
				ship_state = ShipState.DETECTED
			elif !is_friendly and !tracked_ship.visible_to_enemy:
				ship_state = ShipState.UNDETECTED

			var color
			match ship_state:
				ShipState.ALLY:
					color = FRIENDLY_COLOR
				ShipState.ENEMY: color = ENEMY_COLOR
				ShipState.UNDETECTED: color = Color(0.4, 0.4, 0.4, 1) # Gray for undetected
				ShipState.DETECTED: color = FRIENDLY_COLOR # Orange for detected
				ShipState.DEAD: color = Color(0.2, 0.2, 0.2, 1) # Dark gray for dead
				_: color = Color(1, 1, 1, 1) # Default to white

			# if (ship as Ship).visible_to_enemy:
			if ship_state == ShipState.DETECTED:
				var col = Color.GOLD
				col.a = 0.7
				ship_auras_to_draw.append({"pos": tracked_ship.global_position, "rot": -tracked_ship.rotation.y, "color": col})
				# draw_ship_aura_on_minimap(tracked_ship.global_position, -tracked_ship.rotation.y, col, 1.3)
			ships_to_draw.append({"pos": tracked_ship.global_position, "rot": -tracked_ship.rotation.y, "color": color})
			# draw_ship_on_minimap(tracked_ship.global_position, -tracked_ship.rotation.y, color)

	# draw gun ranges
	draw_range_circle_on_minimap(ship.global_position, ship.artillery_controller.get_params()._range, Color(1, 1, 1, 0.5))
	if ship.secondary_controller.sub_controllers.size() > 0:
		for controller in ship.secondary_controller.sub_controllers:
			draw_range_circle_on_minimap(ship.global_position, controller.get_params()._range, Color.DARK_KHAKI)

	draw_dashed_circle_on_minimap(ship.global_position, ship.concealment.get_concealment(), Color(1, 1, 1, 0.5), 8.0, 4.0)


	# Draw ship auras first
	for aura in ship_auras_to_draw:
		draw_ship_aura_on_minimap(aura.pos, aura.rot, aura.color, 1.3)

	# Draw ships
	for ship_info in ships_to_draw:
		draw_ship_on_minimap(ship_info.pos, ship_info.rot, ship_info.color)

	# Draw player ship on top if it exists
	if is_instance_valid(player_ship):
		draw_ship_on_minimap(player_ship.global_position, -player_ship.rotation.y, PLAYER_COLOR)

	var minimap_pos = world_to_minimap_position(aim_point)
	if minimap_pos.x < 0 or minimap_pos.y < 0 or minimap_pos.x > minimap_sizes[mm_idx] or minimap_pos.y > minimap_sizes[mm_idx]:
		return
	_draw_aim_point(minimap_pos)

func draw_dashed_circle_on_minimap(world_position: Vector3, radius: float, color: Color, dash_length: float = 5.0, gap_length: float = 3.0) -> void:
	var minimap_pos = world_to_minimap_position(world_position)
	var minimap_radius = radius * scale_factor.x
	_draw_dashed_circle(minimap_pos, minimap_radius, color, dash_length, gap_length)

func _draw_dashed_circle(center: Vector2, radius: float, color: Color, dash_length: float = 5.0, gap_length: float = 3.0) -> void:
	var circumference = TAU * radius
	var num_dashes = int(circumference / (dash_length + gap_length))
	var angle_step = TAU / num_dashes

	for i in range(num_dashes):
		var start_angle = i * angle_step
		var end_angle = start_angle + (dash_length / circumference) * TAU

		var start_point = center + Vector2(cos(start_angle), sin(start_angle)) * radius
		var end_point = center + Vector2(cos(end_angle), sin(end_angle)) * radius

		ship_markers_canvas.draw_line(start_point, end_point, color, 2.0)

func draw_ship_aura_on_minimap(world_position: Vector3, ship_rotation: float, color: Color, marker_size: float = 1.0) -> void:
	var minimap_pos = world_to_minimap_position(world_position)
	if minimap_pos.x < 0 or minimap_pos.y < 0 or minimap_pos.x > minimap_sizes[mm_idx] or minimap_pos.y > minimap_sizes[mm_idx]:
		return
	_draw_ship_aura(minimap_pos, ship_rotation, color, marker_size)

func _draw_ship_aura(minimap_pos: Vector2, _ship_rotation: float, color: Color, scaling: float) -> void:
	var marker_size = SHIP_MARKER_SIZE * minimap_sizes[mm_idx] / minimap_sizes.back()
	ship_markers_canvas.draw_circle(minimap_pos, marker_size * scaling / 2.0, color)

# Public function to draw a single ship
func draw_ship_on_minimap(world_position: Vector3, ship_rotation: float, color: Color, marker_size: float = 1.0) -> void:
	var minimap_pos = world_to_minimap_position(world_position)

	# Skip drawing if outside minimap boundaries
	if minimap_pos.x < 0 or minimap_pos.y < 0 or minimap_pos.x > minimap_sizes[mm_idx] or minimap_pos.y > minimap_sizes[mm_idx]:
		return

	_draw_ship_marker(minimap_pos, ship_rotation, color, marker_size)


# Draw range circle around ship (clipping handled by clip_contents on ship_markers_canvas)
func draw_range_circle_on_minimap(world_position: Vector3, weapon_range: float, color: Color) -> void:
	var minimap_pos = world_to_minimap_position(world_position)
	var minimap_radius = weapon_range * scale_factor.x
	ship_markers_canvas.draw_arc(minimap_pos, minimap_radius, 0, TAU, 64, color, 2.0)


# Private function to handle the actual drawing
func _draw_ship_marker(marker_position: Vector2, ship_rotation: float, color: Color, scaling: float = 1.0) -> void:
	var marker_size = SHIP_MARKER_SIZE * minimap_sizes[mm_idx] / minimap_sizes.back()
	var points = PackedVector2Array([
		Vector2(0, -marker_size / 2.0) * scaling, # Tip
		Vector2(-marker_size / 3.0, marker_size / 2.0) * scaling, # Left corner
		Vector2(marker_size / 3.0, marker_size / 2.0) * scaling, # Right corner
	])

	# Apply rotation
	for i in range(points.size()):
		points[i] = points[i].rotated(ship_rotation)
		points[i] += marker_position

	# Draw the triangle
	ship_markers_canvas.draw_colored_polygon(points, color)

func _draw_aim_point(aim_position: Vector2):
	ship_markers_canvas.draw_circle(aim_position, 2, Color.WHITE, false)

# Draw a translucent arc showing the camera's field of view
func draw_camera_fov_arc(range: float) -> void:
	# Get the camera from viewport if not cached
	if not is_instance_valid(battle_camera):
		battle_camera = get_viewport().get_camera_3d()

	if not is_instance_valid(battle_camera) or not is_instance_valid(player_ship):
		return

	# Get camera properties
	var camera_fov_vertical = battle_camera.fov # Vertical FOV in degrees
	var camera_rotation_y = battle_camera.rotation.y # Horizontal rotation

	# Calculate horizontal FOV based on aspect ratio
	var viewport_size = get_viewport().get_visible_rect().size
	var aspect_ratio = viewport_size.x / viewport_size.y
	var fov_vertical_rad = deg_to_rad(camera_fov_vertical)
	var fov_horizontal_rad = 2.0 * atan(tan(fov_vertical_rad / 2.0) * aspect_ratio)

	# Get player position on minimap (camera follows player ship)
	var minimap_center = world_to_minimap_position(player_ship.global_position)

	# Calculate arc radius on minimap
	var arc_radius = range * scale_factor.x

	# Calculate start and end angles for the arc
	# Camera rotation.y is the horizontal look direction
	# We need to flip it for the minimap coordinate system (Y is down)
	# and adjust because 0 rotation means looking along -Z in Godot
	var center_angle = -camera_rotation_y - PI / 2.0
	var half_fov = fov_horizontal_rad / 2.0
	var start_angle = center_angle - half_fov
	var end_angle = center_angle + half_fov

	# Build polygon points for the filled arc (pie slice)
	var points = PackedVector2Array()
	points.append(minimap_center) # Center point

	# Add arc points
	for i in range(FOV_ARC_SEGMENTS + 1):
		var t = float(i) / float(FOV_ARC_SEGMENTS)
		var angle = start_angle + t * (end_angle - start_angle)
		var point = minimap_center + Vector2(cos(angle), sin(angle)) * arc_radius
		points.append(point)

	# Draw the filled arc
	if points.size() >= 3:
		ship_markers_canvas.draw_colored_polygon(points, FOV_ARC_COLOR)

		# Draw arc outline for better visibility
		var outline_color = Color(FOV_ARC_COLOR.r, FOV_ARC_COLOR.g, FOV_ARC_COLOR.b, 0.5)
		ship_markers_canvas.draw_arc(minimap_center, arc_radius, start_angle, end_angle, FOV_ARC_SEGMENTS, outline_color, 1.5)

		# Draw the two edge lines of the FOV cone
		var start_point = minimap_center + Vector2(cos(start_angle), sin(start_angle)) * arc_radius
		var end_point = minimap_center + Vector2(cos(end_angle), sin(end_angle)) * arc_radius
		ship_markers_canvas.draw_line(minimap_center, start_point, outline_color, 1.5)
		ship_markers_canvas.draw_line(minimap_center, end_point, outline_color, 1.5)
