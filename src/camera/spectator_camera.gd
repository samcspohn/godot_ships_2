extends Camera3D
class_name SpectatorCamera

enum Mode { ORBIT, FREE }

const MIN_DIST: float = 60.0
const MAX_DIST: float = 4000.0
const FREE_SPEED: float = 400.0
const FOLLOW_LOST_DELAY: float = 3.0
const TAG_W: float = 100.0
const DAMAGE_SEGMENT_S: float = 1.0
const DAMAGE_DROP_RATE: float = 200.0
const SPOT_COLOR := Color(1.0, 0.85, 0.0)
const TEAM_COLORS: Array[Color] = [Color(0.2, 0.9, 0.4), Color(0.9, 0.2, 0.2)]

## -1 shows every ship; otherwise only this team's.
var team_filter: int = -1
## The local player's own (dead) hull, if any; Debug treats it as "not spectating".
var owner_ship: Ship = null
var follow_ship: Ship = null

var mode: Mode = Mode.ORBIT
var _yaw: float = 0.0
var _pitch: float = -0.35
var _dist: float = 600.0
var _free_vel: Vector3 = Vector3.ZERO
var _lost_timer: float = 0.0
var _hud: Label
var _listener: AudioListener3D
var _looking: bool = false
var _look_anchor: Vector2
var _layer: CanvasLayer
var _minimap: Minimap
var _tags: Dictionary = {}


func _ready() -> void:
	far = 60000.0
	fov = 60.0
	var template: Camera3D = load("res://src/camera/player_cam.tscn").instantiate()
	environment = template.environment
	near = template.near
	template.free()
	current = true
	_listener = AudioListener3D.new()
	add_child(_listener)
	_listener.make_current()

	var layer := CanvasLayer.new()
	add_child(layer)
	_layer = layer
	var panel := Control.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.offset_left = -10.0
	panel.offset_top = -10.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(panel)
	_minimap = Minimap.new()
	_minimap.spectator = true
	panel.add_child(_minimap)
	_hud = Label.new()
	_hud.position = Vector2(20, 20)
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)

	ProjectileManager.set_camera(self)
	TorpedoManager.camera = self
	var dbg := get_node_or_null("/root/Debug")
	if dbg != null:
		dbg.register_camera(self)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if follow_ship == null:
		cycle(1)


func candidates() -> Array[Ship]:
	var out: Array[Ship] = []
	var server := get_tree().root.get_node_or_null("Server")
	if server == null:
		return out
	for p_name in server.players:
		var s: Ship = server.players[p_name][0]
		if not is_instance_valid(s) or not s.is_alive():
			continue
		if team_filter >= 0 and s.team.team_id != team_filter:
			continue
		out.append(s)
	out.sort_custom(func(a: Ship, b: Ship) -> bool:
		if a.team.team_id != b.team.team_id:
			return a.team.team_id < b.team.team_id
		return String(a.name) < String(b.name))
	return out


func cycle(step: int) -> void:
	var list := candidates()
	if list.is_empty():
		if follow_ship == null and is_instance_valid(owner_ship):
			follow_ship = owner_ship
		return
	var i := list.find(follow_ship)
	i = 0 if i < 0 and step > 0 else posmod(i + step, list.size())
	follow_ship = list[i]
	_lost_timer = 0.0


# _input, not _unhandled: ship-tag ProgressBars under the followed ship swallow RMB.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _looking:
		_yaw -= event.screen_relative.x * 0.005
		_pitch = clampf(_pitch - event.screen_relative.y * 0.005, -1.45, 1.2)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_set_looking(event.pressed)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist / 1.15, MIN_DIST)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.15, MAX_DIST)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				cycle(-1 if event.shift_pressed else 1)
			KEY_F:
				mode = Mode.ORBIT if mode == Mode.FREE else Mode.FREE
				if mode == Mode.FREE:
					_pitch = rotation.x
					_yaw = rotation.y
			KEY_SPACE:
				var s := _ship_nearest_screen_centre()
				if s != null:
					follow_ship = s
					mode = Mode.ORBIT


func _set_looking(on: bool) -> void:
	if on == _looking:
		return
	_looking = on
	if on:
		_look_anchor = get_viewport().get_mouse_position()
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		get_viewport().warp_mouse(_look_anchor)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		_set_looking(false)


func _process(delta: float) -> void:
	if _looking and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_set_looking(false)
	if follow_ship != null and (not is_instance_valid(follow_ship) or not follow_ship.is_alive()):
		_lost_timer += delta
		if _lost_timer >= FOLLOW_LOST_DELAY or not is_instance_valid(follow_ship):
			cycle(1)
	if mode == Mode.ORBIT and follow_ship != null and is_instance_valid(follow_ship):
		_orbit(delta)
	else:
		_free(delta)

	var dbg := get_node_or_null("/root/Debug")
	if dbg != null:
		dbg.set_follow_ship(follow_ship if is_instance_valid(follow_ship) else null, owner_ship)
	_hud.text = _hud_text()
	_update_tags()


# The world is only complete once the server has spawned ships into it; earlier snapshots miss the islands.
func _snapshot_map() -> void:
	await get_tree().process_frame
	_minimap.take_map_snapshot(get_viewport())


func _update_tags() -> void:
	var players := get_tree().root.get_node_or_null("Server/GameWorld/Players")
	if players != null:
		for s in players.get_children():
			if s is Ship and not _tags.has(s):
				if _tags.is_empty():
					_snapshot_map()
				_tags[s] = _make_tag(s)
				_minimap.register_ship(s)
	_minimap.set_followed(follow_ship if is_instance_valid(follow_ship) else null)
	var rect := get_viewport().get_visible_rect()
	var now: float = Time.get_ticks_msec() / 1000.0
	var dt: float = get_process_delta_time()
	for s in _tags.keys():
		var tag: Dictionary = _tags[s]
		if not is_instance_valid(s):
			tag.root.queue_free()
			_tags.erase(s)
			continue
		var hc: HPManager = s.health_controller
		var hp: float = hc.current_hp
		var at: Vector3 = s.global_position + Vector3(0, 20, 0)
		var shown: bool = s.is_alive() and not is_position_behind(at)
		var p := unproject_position(at) if shown else Vector2.ZERO
		shown = shown and rect.has_point(p)
		tag.root.visible = shown
		var segs: Array = tag.segs
		if not shown:
			tag.prev = hp
			segs.clear()
			continue
		tag.root.position = p - Vector2(TAG_W / 2.0, 40.0)
		tag.bar.value = 100.0 * hp / maxf(hc.max_hp, 1.0)
		tag.hp.text = "%d/%d" % [int(hp), int(hc.max_hp)]
		tag.spot.visible = s.visible_to_enemy
		# Same trailing damage strip as the game UI: one segment per 1 s window of hits.
		if hp < tag.prev and (segs.is_empty() or now >= segs[-1].expire):
			segs.append({"hp": tag.prev, "expire": now + DAMAGE_SEGMENT_S})
		tag.prev = hp
		while not segs.is_empty() and segs[0].expire <= now:
			segs.pop_front()
		if not segs.is_empty() and hp >= segs[0].hp:
			segs.clear()
		var want: float = 100.0 * (segs[0].hp if not segs.is_empty() else hp) / maxf(hc.max_hp, 1.0)
		tag.dmg.value = want if want >= tag.dmg.value else maxf(want, tag.dmg.value - DAMAGE_DROP_RATE * dt)


func _make_tag(s: Ship) -> Dictionary:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.z_index = -1
	root.size = Vector2(TAG_W, 50)
	_layer.add_child(root)
	var name_label := Label.new()
	name_label.text = s.name
	name_label.size = Vector2(TAG_W, 15)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	outline(name_label)
	root.add_child(name_label)
	var dmg := _tag_bar(root, _rounded(Color(0.09, 0.09, 0.12, 0.9), Color(0.5, 0.5, 0.5)),
		_rounded(Color(0.95, 0.95, 0.95, 0.9)))
	var transparent := StyleBoxFlat.new()
	transparent.bg_color = Color(0, 0, 0, 0)
	var bar := _tag_bar(root, transparent, _rounded(TEAM_COLORS[clampi(s.team.team_id, 0, 1)]))
	var hp := Label.new()
	hp.set_anchors_preset(Control.PRESET_FULL_RECT)
	hp.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hp.grow_vertical = Control.GROW_DIRECTION_BOTH
	hp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp.add_theme_font_size_override("font_size", 10)
	hp.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	outline(hp)
	bar.add_child(hp)
	var spot := ColorRect.new()
	spot.color = SPOT_COLOR
	spot.position = Vector2(-12, 25)
	spot.size = Vector2(10, 10)
	spot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spot)
	var full: float = s.health_controller.current_hp
	return {"root": root, "bar": bar, "dmg": dmg, "hp": hp, "spot": spot, "prev": full, "segs": []}


static func outline(l: Label) -> void:
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 2)


func _tag_bar(root: Control, bg: StyleBox, fill: StyleBox) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.value = 100.0
	bar.position = Vector2(0, 25)
	bar.size = Vector2(TAG_W, 10)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)
	return bar


func _rounded(color: Color, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(5)
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(2)
	return sb


func _orbit(delta: float) -> void:
	var dir := Vector3(sin(_yaw) * cos(_pitch), -sin(_pitch), cos(_yaw) * cos(_pitch))
	var target := follow_ship.global_position + Vector3(0, 20, 0)
	var want := target + dir * _dist
	want.y = maxf(want.y, 5.0)
	global_position = global_position.lerp(want, clampf(delta * 8.0, 0.0, 1.0))
	look_at(target, Vector3.UP)


func _free(delta: float) -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)
	var input := Vector3(
		Input.get_axis(&"ui_left", &"ui_right") + float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	var speed := FREE_SPEED * maxf(global_position.y / 200.0, 1.0)
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 4.0
	var want := global_basis * input.limit_length(1.0) * speed
	_free_vel = _free_vel.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	global_position += _free_vel * delta
	global_position.y = maxf(global_position.y, 5.0)


func _ship_nearest_screen_centre() -> Ship:
	var centre := get_viewport().get_visible_rect().size * 0.5
	var best: Ship = null
	var best_d := INF
	for s in candidates():
		if is_position_behind(s.global_position):
			continue
		var d := unproject_position(s.global_position).distance_squared_to(centre)
		if d < best_d:
			best_d = d
			best = s
	return best


func _hud_text() -> String:
	var lines: PackedStringArray = ["SPECTATING   [Tab] next  [Shift+Tab] prev  [F] free cam  [Space] ship at centre  [RMB] look"]
	if mode == Mode.FREE:
		lines.append("free cam   WASD move  Q/E down/up  Shift fast")
	if follow_ship != null and is_instance_valid(follow_ship):
		var hc := follow_ship.health_controller
		lines.append("%s  %s  team %d  HP %d / %d" % [follow_ship.name, follow_ship.ship_name,
			follow_ship.team.team_id, int(hc.current_hp), int(hc.max_hp)])
	return "\n".join(lines)
