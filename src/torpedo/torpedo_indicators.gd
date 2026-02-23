extends Control

## Draws triangle indicators on screen pointing at armed torpedo positions.
## Colors: white = player's own, green = friendly team, red = enemy team.
## Reads directly from the torpedo manager each frame — no accumulated state.

var torpedo_manager: _TorpedoManager

const TRIANGLE_SIZE: float = 5.0
const TRIANGLE_OFFSET_Y: float = -2.0  # Offset above the torpedo position (negative = up)
const OUTLINE_WIDTH: float = 1.5
const OUTLINE_COLOR: Color = Color(0, 0, 0, 0.6)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

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
