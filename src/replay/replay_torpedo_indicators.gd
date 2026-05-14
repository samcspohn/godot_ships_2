extends Control
class_name ReplayTorpedoIndicators

## Replay-side counterpart to torpedo_indicators.gd. Reads from a
## TorpedoReplayer instead of a live TorpedoManager and uses ghost-ship
## metadata for team-colour attribution.
##
## Lives inside the SubViewport so that Camera3D.unproject_position() values
## (which are in SubViewport pixel space) match this Control's coordinate
## system 1:1, regardless of the SubViewportContainer's screen-space scale.
##
## Wiring (see match_replay.gd):
##   indicators.torpedo_replayer = torpedo_replayer
##   indicators.camera           = replay_camera
##   indicators.ghost_ships      = ghost_ships
##   indicators.set_followed_ship_id(ship_id)

var torpedo_replayer: TorpedoReplayer = null
var camera: Camera3D = null
var ghost_ships: Array = []   ## Array[GhostShip]
var _followed_ship_id: int = -1

# Reuse the same constants / colours as the live torpedo_indicators so the
# replay HUD reads identically to the in-game HUD.
const TRIANGLE_SIZE: float = 2.5
const TRIANGLE_OFFSET_Y: float = -2.0

const DETECTION_DOT_RADIUS: float = 1.2
const DETECTION_DOT_GAP: float = 1.0
const DETECTION_DOT_COLOR: Color = Color(1.0, 0.8, 0.1, 0.95)

const PROXIMITY_CIRCLE_RADIUS_RATIO: float = 0.25
const PROXIMITY_DETECTION_RANGE: float = 2000.0
const PROXIMITY_INDICATOR_SIZE: float = 18.0
const PROXIMITY_MIN_ALPHA: float = 0.3
const PROXIMITY_MAX_ALPHA: float = 1.0
const PROXIMITY_PULSE_SPEED: float = 3.0

var _time_elapsed: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func set_followed_ship_id(ship_id: int) -> void:
	_followed_ship_id = ship_id


func _process(delta: float) -> void:
	_time_elapsed += delta
	queue_redraw()


func _draw() -> void:
	if torpedo_replayer == null or camera == null:
		return
	if torpedo_replayer._active_torpedos.is_empty():
		return

	var local_ghost: GhostShip = _get_followed_ghost()
	var local_team_id: int = -1
	if local_ghost != null:
		local_team_id = int(local_ghost.ship_entry.get("team_id", -1))

	var cam_dir: Vector3 = -camera.global_transform.basis.z.normalized()
	var viewport_rect: Rect2 = get_viewport_rect()

	# --- On-screen torpedo markers ---
	for torp_id in torpedo_replayer._active_torpedos:
		var entry: Dictionary = torpedo_replayer._active_torpedos[torp_id]
		if not entry.get("armed", false):
			continue

		var mesh_inst = entry.get("mesh")
		if mesh_inst == null or not is_instance_valid(mesh_inst):
			continue

		var world_pos: Vector3 = mesh_inst.global_position
		world_pos.y = 0.0

		var to_pos: Vector3 = (world_pos - camera.global_position).normalized()
		if cam_dir.dot(to_pos) <= 0:
			continue

		var screen_pos: Vector2 = camera.unproject_position(world_pos)
		if screen_pos.x < -50 or screen_pos.x > viewport_rect.size.x + 50:
			continue
		if screen_pos.y < -50 or screen_pos.y > viewport_rect.size.y + 50:
			continue

		var owner_id: int = int(entry.event.get("ship_id", -1))
		var color: Color = _torpedo_color_for(owner_id, local_team_id)

		var tip := screen_pos + Vector2(0, TRIANGLE_OFFSET_Y)
		var left := tip + Vector2(-TRIANGLE_SIZE, -TRIANGLE_SIZE * 1.5)
		var right := tip + Vector2(TRIANGLE_SIZE, -TRIANGLE_SIZE * 1.5)
		draw_colored_polygon(PackedVector2Array([tip, left, right]), color)

		# Detection dot above the chevron when the torpedo has been spotted.
		if entry.get("detected", false):
			var dot_y: float = left.y - DETECTION_DOT_GAP - DETECTION_DOT_RADIUS
			draw_circle(Vector2(screen_pos.x, dot_y), DETECTION_DOT_RADIUS, DETECTION_DOT_COLOR)

	# --- Proximity circle indicators (only when following a ship) ---
	if local_ghost == null or not is_instance_valid(local_ghost):
		return

	var screen_center: Vector2 = viewport_rect.size / 2.0
	var min_dimension: float = minf(viewport_rect.size.x, viewport_rect.size.y)
	var circle_radius: float = min_dimension * PROXIMITY_CIRCLE_RADIUS_RATIO
	var ship_pos: Vector3 = local_ghost.global_position

	var cam_forward_xz: Vector3 = Vector3(cam_dir.x, 0.0, cam_dir.z).normalized()
	var cam_right_xz: Vector3 = Vector3(-cam_forward_xz.z, 0.0, cam_forward_xz.x)

	for torp_id in torpedo_replayer._active_torpedos:
		var entry: Dictionary = torpedo_replayer._active_torpedos[torp_id]
		if not entry.get("armed", false):
			continue

		var owner_id: int = int(entry.event.get("ship_id", -1))
		# Skip the followed ship's own torpedoes.
		if owner_id == _followed_ship_id:
			continue
		# Skip friendlies for the proximity warning.
		if local_team_id >= 0 and _team_id_for(owner_id) == local_team_id:
			continue

		var mesh_inst = entry.get("mesh")
		if mesh_inst == null or not is_instance_valid(mesh_inst):
			continue
		var world_pos: Vector3 = mesh_inst.global_position
		var to_torpedo: Vector3 = world_pos - ship_pos
		var distance: float = to_torpedo.length()
		if distance > PROXIMITY_DETECTION_RANGE or distance < 1.0:
			continue

		var dir_xz: Vector3 = Vector3(to_torpedo.x, 0.0, to_torpedo.z).normalized()
		var angle: float = atan2(dir_xz.dot(cam_right_xz), dir_xz.dot(cam_forward_xz))

		var circle_x: float = sin(angle)
		var circle_y: float = -cos(angle)
		var indicator_pos: Vector2 = screen_center + Vector2(circle_x, circle_y) * circle_radius

		var distance_factor: float = 1.0 - clampf(distance / PROXIMITY_DETECTION_RANGE, 0.0, 1.0)
		var base_alpha: float = lerpf(PROXIMITY_MIN_ALPHA, PROXIMITY_MAX_ALPHA, distance_factor)
		var pulse: float = 1.0
		if distance_factor > 0.5:
			pulse = 0.85 + 0.15 * sin(_time_elapsed * PROXIMITY_PULSE_SPEED)

		var color: Color = _torpedo_color_for(owner_id, local_team_id)
		color.a = base_alpha * pulse

		_draw_proximity_indicator(indicator_pos, angle, color, distance_factor)


func _draw_proximity_indicator(pos: Vector2, angle: float, color: Color, urgency: float) -> void:
	var inward_angle: float = angle + PI
	var dir := Vector2(sin(inward_angle), -cos(inward_angle))
	var perp := Vector2(-dir.y, dir.x)
	var sz: float = PROXIMITY_INDICATOR_SIZE * (1.0 + urgency * 0.4)
	var tip: Vector2 = pos + dir * sz
	var left: Vector2 = pos - dir * sz * 0.5 + perp * sz * 0.5
	var right: Vector2 = pos - dir * sz * 0.5 - perp * sz * 0.5
	draw_colored_polygon(PackedVector2Array([tip, left, right]), color)


func _torpedo_color_for(owner_ship_id: int, local_team_id: int) -> Color:
	# White if the torpedo belongs to the followed ship.
	if owner_ship_id == _followed_ship_id:
		return Color(1.0, 1.0, 1.0, 0.9)
	# Green if same team as the followed ship.
	var owner_team: int = _team_id_for(owner_ship_id)
	if local_team_id >= 0 and owner_team == local_team_id:
		return Color(0.2, 1.0, 0.2, 0.9)
	# Red if enemy team.
	return Color(1.0, 0.2, 0.2, 0.9)


func _team_id_for(ship_id: int) -> int:
	for gs in ghost_ships:
		if gs == null or not is_instance_valid(gs):
			continue
		if int(gs.ship_entry.get("ship_id", -1)) == ship_id:
			return int(gs.ship_entry.get("team_id", -1))
	return -1


func _get_followed_ghost() -> GhostShip:
	if _followed_ship_id < 0:
		return null
	for gs in ghost_ships:
		if gs == null or not is_instance_valid(gs):
			continue
		if int(gs.ship_entry.get("ship_id", -1)) == _followed_ship_id:
			return gs
	return null
