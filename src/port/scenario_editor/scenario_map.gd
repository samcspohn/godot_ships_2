class_name ScenarioMap
extends Control

signal ship_selected(key: String)
signal ship_changed(key: String)

const WORLD := Rect2(-17500, -17500, 35000, 35000)
const TEAM_COLORS := [Color(0.35, 0.75, 1.0), Color(1.0, 0.35, 0.3)]
const PICK_PX := 14.0

var team: Dictionary = {}
var selected: String = ""
var control_key: String = ""
var map_texture: Texture2D

var _center := Vector2.ZERO
var _m_per_px := 40.0
var _dragging: String = ""
var _panning := false
var _aiming := false

func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(fit)
	_render_map()

func _render_map() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(2048, 2048)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.16, 0.26)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, 30, 0)
	vp.add_child(light)
	var islands: Node3D = load("res://src/Maps/map.tscn").instantiate()
	islands.set_script(null)
	for n in ["Ocean", "water", "Plane_020", "DirectionalLight3D", "DirectionalLight3D2"]:
		var c := islands.get_node_or_null(n)
		if c != null:
			islands.remove_child(c)
			c.free()
	vp.add_child(islands)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.size = WORLD.size.x
	cam.far = 20000.0
	vp.add_child(cam)
	cam.global_position = Vector3(0, 10000, 0)
	cam.look_at(Vector3.ZERO, Vector3.FORWARD)
	map_texture = vp.get_texture()
	for i in 3:
		await get_tree().process_frame
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	queue_redraw()

func fit() -> void:
	_center = WORLD.get_center()
	_m_per_px = WORLD.size.x / maxf(minf(size.x, size.y), 1.0)
	queue_redraw()

func to_screen(w: Vector2) -> Vector2:
	return (w - _center) / _m_per_px + size * 0.5

func to_world(s: Vector2) -> Vector2:
	return (s - size * 0.5) * _m_per_px + _center

static func pos_of(e: Dictionary) -> Vector2:
	var p: Array = e.get("pos", [0, 0])
	return Vector2(float(p[0]), float(p[1]))

static func dir_of(e: Dictionary) -> Vector2:
	var h := deg_to_rad(float(e.get("heading_deg", 0.0)))
	return Vector2(sin(h), cos(h))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.16, 0.26))
	if map_texture != null:
		draw_texture_rect(map_texture, Rect2(to_screen(WORLD.position), WORLD.size / _m_per_px), false)
	var grid_col := Color(1, 1, 1, 0.07)
	for k in range(-3, 4):
		var v := k * 5000.0
		draw_line(to_screen(Vector2(v, WORLD.position.y)), to_screen(Vector2(v, WORLD.end.y)), grid_col)
		draw_line(to_screen(Vector2(WORLD.position.x, v)), to_screen(Vector2(WORLD.end.x, v)), grid_col)
	var font := get_theme_default_font()
	for key in team:
		var e: Dictionary = team[key]
		var col: Color = TEAM_COLORS[clampi(int(e.get("team", 0)), 0, 1)]
		var p := to_screen(pos_of(e))
		var d := dir_of(e)
		var n := Vector2(-d.y, d.x)
		if e.has("fixed") and e.fixed.has("path"):
			var pts := PackedVector2Array([p])
			for w in e.fixed.path:
				pts.append(to_screen(Vector2(float(w[0]), float(w[1]))))
			draw_polyline(pts, Color(col, 0.5), 1.5)
		var spd := float(e.get("speed", 0.0))
		if spd > 0.0:
			draw_line(p, to_screen(pos_of(e) + d * spd * 30.0), Color(col, 0.6), 1.5)
		var tri := PackedVector2Array([p + d * 12, p - d * 8 + n * 7, p - d * 8 - n * 7])
		draw_colored_polygon(tri, col)
		if key == selected:
			draw_polyline(tri + PackedVector2Array([tri[0]]), Color.YELLOW, 2.0)
		var label: String = key
		if key == control_key:
			label = "[YOU] " + label
			draw_arc(p, 16, 0, TAU, 24, Color.WHITE, 2.0)
		if e.has("fixed"):
			label += " (fixed)"
		draw_string(font, p + Vector2(14, -10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
	var bar_m := 1000.0 if _m_per_px < 20.0 else 5000.0
	var y := size.y - 14
	draw_line(Vector2(12, y), Vector2(12 + bar_m / _m_per_px, y), Color.WHITE, 2.0)
	draw_string(font, Vector2(12, y - 6), "%d km" % int(bar_m / 1000.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	var m := to_world(get_local_mouse_position())
	draw_string(font, Vector2(size.x - 150, size.y - 8), "(%.0f, %.0f)" % [m.x, m.y], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)

func _pick(s: Vector2) -> String:
	var best := ""
	var best_d := PICK_PX
	for key in team:
		var d := to_screen(pos_of(team[key])).distance_to(s)
		if d < best_d:
			best_d = d
			best = key
	return best

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				var before := to_world(mb.position)
				_m_per_px *= 0.85 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.85
				_m_per_px = clampf(_m_per_px, 2.0, 200.0)
				_center += before - to_world(mb.position)
				queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var key := _pick(mb.position)
				if key != "":
					selected = key
					_dragging = key
					ship_selected.emit(key)
				else:
					_panning = true
			else:
				_dragging = ""
				_panning = false
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_aiming = mb.pressed and team.has(selected)
			if _aiming:
				_aim(mb.position)
			accept_event()
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if _dragging != "" and team.has(_dragging):
			var w := to_world(mm.position)
			team[_dragging]["pos"] = [snappedf(w.x, 10.0), snappedf(w.y, 10.0)]
			ship_changed.emit(_dragging)
		elif _aiming:
			_aim(mm.position)
		elif _panning:
			_center -= mm.relative * _m_per_px
		queue_redraw()

func _aim(s: Vector2) -> void:
	var d := to_world(s) - pos_of(team[selected])
	if d.length() < 1.0:
		return
	team[selected]["heading_deg"] = fposmod(snappedf(rad_to_deg(atan2(d.x, d.y)), 1.0), 360.0)
	ship_changed.emit(selected)
