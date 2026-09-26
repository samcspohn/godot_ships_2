extends Camera3D
class_name SpectatorCamera

enum Mode { ORBIT, FREE }

const MIN_DIST: float = 60.0
const MAX_DIST: float = 4000.0
const FREE_SPEED: float = 400.0
const FOLLOW_LOST_DELAY: float = 3.0

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


func _ready() -> void:
	far = 60000.0
	fov = 60.0
	current = true
	_listener = AudioListener3D.new()
	add_child(_listener)
	_listener.make_current()

	var layer := CanvasLayer.new()
	add_child(layer)
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


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * 0.005
		_pitch = clampf(_pitch - event.relative.y * 0.005, -1.45, 1.2)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist / 1.15, MIN_DIST)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.15, MAX_DIST)
	elif event is InputEventKey and event.pressed and not event.echo:
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


func _process(delta: float) -> void:
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
