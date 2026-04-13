extends Control

## Draws triangle indicators on screen pointing at armed torpedo positions.
## Colors: white = player's own, green = friendly team, red = enemy team.
## Reads directly from the torpedo manager each frame — no accumulated state.
##
## Also draws proximity indicators on a circle around screen center for nearby
## armed torpedoes, showing their direction relative to the camera orientation.

var torpedo_manager: _TorpedoManager

const TRIANGLE_SIZE: float = 5.0
const TRIANGLE_OFFSET_Y: float = -2.0  # Offset above the torpedo position (negative = up)
const OUTLINE_WIDTH: float = 1.5
const OUTLINE_COLOR: Color = Color(0, 0, 0, 0.6)

# Proximity indicator constants
const PROXIMITY_CIRCLE_RADIUS_RATIO: float = 0.25  # 70% of min screen dimension / 2 = 35% radius
const PROXIMITY_DETECTION_RANGE: float = 2000.0  # World-unit range to detect nearby torpedoes
const PROXIMITY_INDICATOR_SIZE: float = 18.0  # Size of the directional triangle
const PROXIMITY_MIN_ALPHA: float = 0.3  # Alpha at max detection range
const PROXIMITY_MAX_ALPHA: float = 1.0  # Alpha at closest range
const PROXIMITY_PULSE_SPEED: float = 3.0  # Speed of the pulsing glow effect

var _time_elapsed: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func _process(delta: float) -> void:
	_time_elapsed += delta

func _draw() -> void:
	if torpedo_manager == null:
		return

	var cam: Camera3D = torpedo_manager.camera
	if cam == null:
		return

	var local_ship: Ship = _get_local_ship(cam)
	var local_team_id: int = -1
	if local_ship and local_ship.team:
		local_team_id = local_ship.team.team_id

	var cam_dir := -cam.global_transform.basis.z.normalized()
	var viewport_rect: Rect2 = get_viewport_rect()

	# --- On-screen torpedo markers (existing behavior) ---
	for torp in torpedo_manager.torpedos:
		if torp == null:
			continue

		if not torp.armed:
			continue

		var world_pos: Vector3 = torp.position

		# Check if position is in front of camera
		var to_pos := (world_pos - cam.global_position).normalized()
		if cam_dir.dot(to_pos) <= 0:
			continue

		var screen_pos: Vector2 = cam.unproject_position(world_pos)

		# Skip if off screen (with some padding)
		if screen_pos.x < -50 or screen_pos.x > viewport_rect.size.x + 50:
			continue
		if screen_pos.y < -50 or screen_pos.y > viewport_rect.size.y + 50:
			continue

		var color := _get_torpedo_color(torp.owner, local_ship, local_team_id)

		# Draw a downward-pointing triangle above the torpedo screen position
		var tip := screen_pos + Vector2(0, TRIANGLE_OFFSET_Y)
		var left := tip + Vector2(-TRIANGLE_SIZE, -TRIANGLE_SIZE * 1.5)
		var right := tip + Vector2(TRIANGLE_SIZE, -TRIANGLE_SIZE * 1.5)

		var points := PackedVector2Array([tip, left, right])

		# Draw filled triangle
		draw_colored_polygon(points, color)

	# --- Proximity circle indicators (new behavior) ---
	if local_ship == null or !local_ship.is_inside_tree():
		return

	var screen_center := viewport_rect.size / 2.0
	var min_dimension: float = minf(viewport_rect.size.x, viewport_rect.size.y)
	var circle_radius: float = min_dimension * PROXIMITY_CIRCLE_RADIUS_RATIO
	var ship_pos: Vector3 = local_ship.global_position
	# Use camera orientation so indicators rotate with the view
	var cam_forward_xz := Vector3(cam_dir.x, 0.0, cam_dir.z).normalized()
	var cam_right_xz := Vector3(-cam_forward_xz.z, 0.0, cam_forward_xz.x)

	for torp in torpedo_manager.torpedos:
		if torp == null:
			continue

		if not torp.armed:
			continue

		# Skip player's own torpedoes — no need to warn about your own
		if local_ship and torp.owner == local_ship:
			continue

		var world_pos: Vector3 = torp.position
		var to_torpedo: Vector3 = world_pos - ship_pos
		var distance: float = to_torpedo.length()

		# Only show torpedoes within detection range
		if distance > PROXIMITY_DETECTION_RANGE or distance < 1.0:
			continue
		if torp.owner and torp.owner.team and torp.owner.team.team_id == local_team_id:
			continue  # Skip friendly torpedoes for proximity indicators

		# Project the direction to torpedo onto the ship's horizontal plane (XZ)
		var dir_xz := Vector3(to_torpedo.x, 0.0, to_torpedo.z).normalized()

		# Calculate angle relative to camera's forward direction
		# Forward = top of circle (angle 0), right = angle PI/2, etc.
		var angle: float = atan2(dir_xz.dot(cam_right_xz), dir_xz.dot(cam_forward_xz))

		# Convert angle to screen-space circle position
		# In screen space: up = -Y, right = +X
		# angle 0 (forward) should map to top of circle (-Y direction)
		var circle_x: float = sin(angle)
		var circle_y: float = -cos(angle)
		var indicator_pos: Vector2 = screen_center + Vector2(circle_x, circle_y) * circle_radius

		# Calculate alpha based on distance (closer = more opaque)
		var distance_factor: float = 1.0 - clampf(distance / PROXIMITY_DETECTION_RANGE, 0.0, 1.0)
		var base_alpha: float = lerpf(PROXIMITY_MIN_ALPHA, PROXIMITY_MAX_ALPHA, distance_factor)

		# Add subtle pulse for very close torpedoes
		var pulse: float = 1.0
		if distance_factor > 0.5:
			pulse = 0.85 + 0.15 * sin(_time_elapsed * PROXIMITY_PULSE_SPEED)

		var color := _get_torpedo_color(torp.owner, local_ship, local_team_id)
		color.a = base_alpha * pulse

		# Draw the triangle indicator pointing inward (toward center)
		_draw_proximity_indicator(indicator_pos, angle, color, distance_factor)

func _draw_proximity_indicator(pos: Vector2, angle: float, color: Color, urgency: float) -> void:
	# Simple filled triangle pointing inward toward the screen center,
	# matching the style of the on-screen surface indicators.
	# 'angle' is the direction FROM ship TO torpedo (0 = forward/top).
	# The triangle tip should point inward, so we rotate by PI.
	var inward_angle: float = angle + PI

	# In screen space, convert the inward angle to a 2D direction
	# angle 0 = up (-Y), angle PI/2 = right (+X)
	var dir := Vector2(sin(inward_angle), -cos(inward_angle))
	var perp := Vector2(-dir.y, dir.x)

	# Scale indicator size based on urgency (closer = slightly larger)
	var sz: float = PROXIMITY_INDICATOR_SIZE * (1.0 + urgency * 0.4)

	# Simple triangle (tip + two base corners), same style as surface indicators
	var tip: Vector2 = pos + dir * sz
	var left: Vector2 = pos - dir * sz * 0.5 + perp * sz * 0.5
	var right: Vector2 = pos - dir * sz * 0.5 - perp * sz * 0.5

	var points := PackedVector2Array([tip, left, right])

	# Draw filled triangle
	draw_colored_polygon(points, color)



static func _get_torpedo_color(torp_owner: Ship, local_ship: Ship, local_team_id: int) -> Color:
	if torp_owner == null:
		return Color(1.0, 1.0, 1.0, 0.9)

	# White if the torpedo belongs to the local player
	if local_ship and torp_owner == local_ship:
		return Color(1.0, 1.0, 1.0, 0.9)

	# Green if same team as the local player
	if torp_owner.team and torp_owner.team.team_id == local_team_id:
		return Color(0.2, 1.0, 0.2, 0.9)

	# Red if enemy team
	return Color(1.0, 0.2, 0.2, 0.9)

static func _get_local_ship(cam: Camera3D) -> Ship:
	if cam is BattleCamera:
		return (cam as BattleCamera)._ship
	return null
