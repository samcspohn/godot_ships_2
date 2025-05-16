extends Node

class_name Minimap

# Constants
const SHIP_MARKER_SIZE = 10
const PLAYER_COLOR = Color(1, 1, 1, 1)  # White
const FRIENDLY_COLOR = Color(0, 1, 0, 1)  # Green
const ENEMY_COLOR = Color(1, 0, 0, 1)  # Red

# Static minimap texture shared across all instances
static var map_texture: ImageTexture = null
static var is_initialized: bool = false

# Minimap properties
#@export var minimap_size: Vector2 = Vector2(200, 200)
var mm_idx = 2
var minimap_sizes: Array[float] = [100, 200, 300, 400, 500, 600, 800]
const w_s: float = 35000.0 / 2.0
@export var world_rect: Rect2 = Rect2(-w_s, -w_s, 2*w_s, 2*w_s)  # World boundaries

# Node references
var background: TextureRect
var ship_markers_canvas: Control
var player_ship: Node3D = null
var tracked_ships: Array[Node3D] = []
var container: Control

# Scaling factor between world coordinates and minimap coordinates
var scale_factor: Vector2
var aim_point: Vector3

func _ready():
	setup_minimap()
	
	# Apply existing texture if available
	if map_texture != null:
		background.texture = map_texture

# Update setup_minimap to ensure consistent aspect ratio
func setup_minimap():
	# Create container
	container = Control.new()
	container.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	
	# Fix the positioning - we need to use different offsets for TOP_RIGHT preset
	container.position = Vector2(-10 - minimap_sizes[mm_idx], 10)
	container.custom_minimum_size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])
	container.size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])
	add_child(container)
	
	# Background texture with gray color for debugging
	background = TextureRect.new()
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])
	#background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED  # Ensure aspect ratio
	background.modulate = Color(1.0,1.0,1.0,0.5)
	container.add_child(background)
	
	# Canvas for ship markers
	ship_markers_canvas = Control.new()
	ship_markers_canvas.size = Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])
	ship_markers_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(ship_markers_canvas)
	
	# Calculate scale factor (ensure x and y scales are the same)
	var scale = min(
		minimap_sizes[mm_idx] / world_rect.size.x,
		minimap_sizes[mm_idx] / world_rect.size.y
	)
	scale_factor = Vector2(scale, scale)
	print("Minimap scale factor: ", scale_factor)

# Server should call this to take a map snapshot once
static func server_take_map_snapshot(viewport: Viewport) -> void:
	# Store current camera position and zoom
	var camera = viewport.get_camera_3d()
	if not camera:
		print("Error: No 3D camera found in viewport")
		return
		
	# Store original camera transform
	var original_transform = camera.global_transform
	var original_projection = camera.projection
	
	# Set camera to capture the entire world from top-down view
	var center_position = Vector3(
		0.0,  # Center X
		10000, # Height above water
		0.0   # Center Z
	)
	
	# Position camera looking down
	camera.global_transform = Transform3D(
		Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.DOWN),
		center_position
	)
	
	# Use orthogonal projection for map view
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 35000.0  # Match the world boundaries
	
	# Wait for frame to update camera position
	await viewport.get_tree().process_frame
	
	# Take screenshot
	var img = viewport.get_texture().get_image()
	map_texture = ImageTexture.create_from_image(img)
	print("Server captured minimap texture")
	
	# Mark as initialized
	is_initialized = true
	
	# Restore camera
	camera.global_transform = original_transform
	camera.projection = original_projection

# Use this instead of the old take_map_snapshot
func take_map_snapshot(viewport: Viewport) -> void:
	# Only take a snapshot if we're on the server and don't have one already
	if map_texture == null:
		await server_take_map_snapshot(viewport)
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
	print("Player ship registered at: ", ship.global_position)  # Debug info

func register_ship(ship: Node3D) -> void:
	if not tracked_ships.has(ship):
		tracked_ships.append(ship)
		# Connect to ship's tree_exiting signal to remove it when destroyed
		if not ship.is_connected("tree_exiting", _on_ship_destroyed):
			ship.connect("tree_exiting", _on_ship_destroyed.bind(ship))

func _on_ship_destroyed(ship: Node3D) -> void:
	tracked_ships.erase(ship)

func clear_ships() -> void:
	tracked_ships.clear()
	player_ship = null

func _process(_delta: float) -> void:
	# Clear previous drawing
	ship_markers_canvas.queue_redraw()
	
	# Setup draw signal - will be called by the rendering system
	if not ship_markers_canvas.is_connected("draw", _on_canvas_draw):
		ship_markers_canvas.connect("draw", _on_canvas_draw)

func _input(event: InputEvent) -> void:
	var prev_mmidx = mm_idx
	if Input.is_key_pressed(KEY_EQUAL):
		mm_idx = clamp(mm_idx + 1, 0, 6)
	elif Input.is_key_pressed(KEY_MINUS):
		mm_idx = clamp(mm_idx - 1, 0, 6)
	
	if prev_mmidx == mm_idx:
		return
	
	container.queue_free()
	setup_minimap()
	if map_texture != null:
		background.texture = map_texture

# Draw signal handler
func _on_canvas_draw() -> void:
	# Draw a border around the minimap for visibility
	ship_markers_canvas.draw_rect(Rect2(Vector2.ZERO, Vector2(minimap_sizes[mm_idx], minimap_sizes[mm_idx])), Color(1, 1, 1, 0.5), false, 2.0)


			
	
	# Draw tracked ships
	for ship in tracked_ships:
		if is_instance_valid(ship):
			var is_friendly = false
			is_friendly = ship.team.team_id == player_ship.team.team_id if is_instance_valid(player_ship) and is_instance_valid(ship.team) and is_instance_valid(player_ship.team) else false
			
			var color = FRIENDLY_COLOR if is_friendly else ENEMY_COLOR
			draw_ship_on_minimap(ship.global_position, -ship.rotation.y, color)
	
	# Draw player ship on top if it exists
	if is_instance_valid(player_ship):
		draw_ship_on_minimap(player_ship.global_position, -player_ship.rotation.y, PLAYER_COLOR)
	
	# draw gun ranges
	var ship = player_ship as Ship
	draw_range_circle_on_minimap(ship.global_position, ship.artillery_controller.guns[0].max_range, Color(1, 1, 1, 0.5))
	if ship.get_node("Secondaries") != null:
		for gun in ship.get_node("Secondaries").get_children():
			var col = Color.DARK_KHAKI
			col.a = 0.5
			draw_range_circle_on_minimap(ship.global_position, gun.max_range, col)
			break

	var minimap_pos = world_to_minimap_position(aim_point)
	if minimap_pos.x < 0 or minimap_pos.y < 0 or minimap_pos.x > minimap_sizes[mm_idx] or minimap_pos.y > minimap_sizes[mm_idx]:
		return
	_draw_aim_point(minimap_pos)

# Public function to draw a single ship
func draw_ship_on_minimap(global_position: Vector3, rotation: float, color: Color) -> void:
	var minimap_pos = world_to_minimap_position(global_position)
	
	# Skip drawing if outside minimap boundaries
	if minimap_pos.x < 0 or minimap_pos.y < 0 or minimap_pos.x > minimap_sizes[mm_idx] or minimap_pos.y > minimap_sizes[mm_idx]:
		return
		
	_draw_ship_marker(minimap_pos, rotation, color)



# Calculate intersections between a circle and a line segment
# circle_center: The center point of the circle (Vector2)
# radius: The radius of the circle (float)
# line_start, line_end: The two endpoints of the line segment (Vector2)
# Returns: Array of Vector2 points where the circle and line segment intersect
func get_circle_line_segment_intersections(circle_center: Vector2, radius: float, 
										   line_start: Vector2, line_end: Vector2) -> Array[Vector2]:
	var intersections: Array[Vector2] = []
	
	# Convert line segment to vector form
	var segment_direction = line_end - line_start
	var segment_length = segment_direction.length()
	
	# Early exit if segment length is zero
	if segment_length < 0.0001:
		return intersections
		
	# Normalize direction vector
	segment_direction = segment_direction / segment_length
	
	# Vector from line start to circle center
	var start_to_center = circle_center - line_start
	
	# Project this vector onto the line direction to find the closest point
	var projection_length = start_to_center.dot(segment_direction)
	
	# Calculate the closest point on the infinite line
	var closest_point = line_start + segment_direction * projection_length
	
	# Get the distance from the circle center to the closest point on the line
	var distance_to_line = (closest_point - circle_center).length()
	
	# If distance is greater than radius, no intersection with the infinite line
	if distance_to_line > radius:
		return intersections
		
	# Calculate the half-chord distance (distance from closest point to either intersection)
	var half_chord = sqrt(radius * radius - distance_to_line * distance_to_line)
	
	# Calculate the two potential intersection points
	var intersection1 = closest_point - segment_direction * half_chord
	var intersection2 = closest_point + segment_direction * half_chord
	
	# Check if intersections are within the line segment bounds
	var t1 = (intersection1 - line_start).dot(segment_direction) / segment_length
	if t1 >= 0 && t1 <= segment_length:
		intersections.append(intersection1)
		
	var t2 = (intersection2 - line_start).dot(segment_direction) / segment_length
	if t2 >= 0 && t2 <= segment_length:
		intersections.append(intersection2)
	
	return intersections

# draw range circle around ship
# circle should be clipped to minimap
func draw_range_circle_on_minimap(global_position: Vector3, range: float, color: Color) -> void:
	# Convert global position to minimap position
	var minimap_pos = world_to_minimap_position(global_position)
	
	# Convert range to minimap scale
	var minimap_radius = range * scale_factor.x
	
	# Skip if the circle would be completely outside the minimap
	if (minimap_pos.x + minimap_radius < 0 || 
		minimap_pos.x - minimap_radius > minimap_sizes[mm_idx] ||
		minimap_pos.y + minimap_radius < 0 || 
		minimap_pos.y - minimap_radius > minimap_sizes[mm_idx]):
		return
	
	# If circle is completely inside, draw full circle
	if (minimap_pos.x - minimap_radius >= 0 && 
		minimap_pos.x + minimap_radius <= minimap_sizes[mm_idx] &&
		minimap_pos.y - minimap_radius >= 0 && 
		minimap_pos.y + minimap_radius <= minimap_sizes[mm_idx]):
		ship_markers_canvas.draw_arc(minimap_pos, minimap_radius, 0, TAU, 64, color, 2.0)
		return
	
	# Define minimap boundaries as line segments
	var border_width = minimap_sizes[mm_idx]
	var border_height = minimap_sizes[mm_idx]
	
	var left_border = [Vector2(0, 0), Vector2(0, border_height)]
	var right_border = [Vector2(border_width, 0), Vector2(border_width, border_height)]
	var top_border = [Vector2(0, 0), Vector2(border_width, 0)]
	var bottom_border = [Vector2(0, border_height), Vector2(border_width, border_height)]
	var borders = [left_border, right_border, top_border, bottom_border]
	
	# Find all intersection points
	var all_intersections = []
	for border in borders:
		var points = get_circle_line_segment_intersections(
			minimap_pos, minimap_radius, border[0], border[1])
		for point in points:
			# Calculate angle of this intersection
			var angle = (point - minimap_pos).angle()
			all_intersections.append({"point": point, "angle": angle})
	
	# Early exit if no intersections (should not happen given our earlier checks)
	if all_intersections.size() == 0:
		return
		
	# Sort intersections by angle
	all_intersections.sort_custom(func(a, b): return a.angle < b.angle)
	
	# Draw arcs between intersections
	for i in range(all_intersections.size()):
		var start = all_intersections[i]
		var end = all_intersections[(i + 1) % all_intersections.size()]
		
		var start_angle = start.angle
		var end_angle = end.angle
		
		# Ensure end angle is greater than start angle
		if end_angle < start_angle:
			end_angle += TAU
			
		var mid_angle = (start_angle + end_angle) / 2
		var test_point = Vector2(
			minimap_pos.x + minimap_radius * cos(mid_angle),
			minimap_pos.y + minimap_radius * sin(mid_angle)
		)
		
		# Draw arc if test point is inside minimap
		if test_point.x >= 0 && test_point.x <= border_width && test_point.y >= 0 && test_point.y <= border_height:
			ship_markers_canvas.draw_arc(minimap_pos, minimap_radius, start_angle, end_angle, 64, color, 2.0)
		

# Private function to handle the actual drawing
func _draw_ship_marker(position: Vector2, rotation: float, color: Color) -> void:
	var points = PackedVector2Array([
		Vector2(0, -SHIP_MARKER_SIZE/2.0),               # Tip
		Vector2(-SHIP_MARKER_SIZE/2.0, SHIP_MARKER_SIZE/2.0),  # Left corner
		Vector2(SHIP_MARKER_SIZE/2.0, SHIP_MARKER_SIZE/2.0),   # Right corner
	])
	
	# Apply rotation
	for i in range(points.size()):
		points[i] = points[i].rotated(rotation)
		points[i] += position
	
	# Draw the triangle
	ship_markers_canvas.draw_colored_polygon(points, color)

func _draw_aim_point(position: Vector2):
	ship_markers_canvas.draw_circle(position,2, Color.WHITE, false)
