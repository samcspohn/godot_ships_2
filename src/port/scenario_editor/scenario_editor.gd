extends Control

const SHIP_DATA: Dictionary = preload("res://src/matchmaker/matchmaker.gd").SHIP_DATA
const MATCHMAKER_PORT := 28961
const HALF_MAP := 17500.0

var data: Dictionary = {}
var path: String = ""
var selected: String = ""
var _syncing := false
var _udp: PacketPeerUDP = null
var _ship_paths: Array = SHIP_DATA.keys()

var map: ScenarioMap
var file_label: Label
var status: Label
var ships: ItemList
var control_opt: OptionButton
var duration: SpinBox
var elapsed: SpinBox
var f_name: LineEdit
var f_team: OptionButton
var f_ship: OptionButton
var f_x: SpinBox
var f_z: SpinBox
var f_heading: SpinBox
var f_speed: SpinBox
var f_hp: SpinBox
var f_fixed: CheckBox
var f_identified: CheckBox
var form: GridContainer
var open_dialog: FileDialog
var save_dialog: FileDialog

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	NetworkManager.connection_succeeded.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connect_failed)
	_new()

func _build_ui() -> void:
	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	map = ScenarioMap.new()
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.ship_selected.connect(_select)
	map.ship_changed.connect(_on_map_changed)
	root.add_child(map)

	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(400, 0)
	root.add_child(side)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)

	var bar := HBoxContainer.new()
	v.add_child(bar)
	_button(bar, "Back", func(): get_tree().change_scene_to_file("res://src/port/main_menu/main_menu.tscn"))
	_button(bar, "New", _new)
	_button(bar, "Load", func(): open_dialog.popup_centered_ratio(0.7))
	_button(bar, "Save", _save)
	_button(bar, "Save As", func(): save_dialog.popup_centered_ratio(0.7))
	file_label = Label.new()
	file_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(file_label)

	var sg := GridContainer.new()
	sg.columns = 2
	v.add_child(sg)
	duration = _spin(sg, "Duration (s)", 10, 1200, 10)
	elapsed = _spin(sg, "Match clock (s)", 0, 1200, 10)
	duration.value_changed.connect(_set_scenario.bind("duration_s"))
	elapsed.value_changed.connect(_set_scenario.bind("elapsed_s"))

	v.add_child(HSeparator.new())
	v.add_child(_label("Ships"))
	ships = ItemList.new()
	ships.custom_minimum_size = Vector2(0, 180)
	ships.item_selected.connect(func(i): _select(ships.get_item_metadata(i)))
	v.add_child(ships)
	var sb := HBoxContainer.new()
	v.add_child(sb)
	_button(sb, "Add", _add)
	_button(sb, "Duplicate", _duplicate)
	_button(sb, "Remove", _remove)

	form = GridContainer.new()
	form.columns = 2
	v.add_child(form)
	f_name = LineEdit.new()
	_row(form, "Name", f_name)
	f_name.text_submitted.connect(_rename)
	f_name.focus_exited.connect(func(): _rename(f_name.text))
	f_team = OptionButton.new()
	f_team.add_item("Team 0")
	f_team.add_item("Team 1")
	_row(form, "Team", f_team)
	f_team.item_selected.connect(func(i): _set_field("team", str(i)))
	f_ship = OptionButton.new()
	for p in _ship_paths:
		f_ship.add_item(String(p).get_file().get_basename())
	_row(form, "Ship", f_ship)
	f_ship.item_selected.connect(func(i): _set_field("ship", _ship_paths[i]))
	f_x = _spin(form, "X (m)", -HALF_MAP, HALF_MAP, 10)
	f_z = _spin(form, "Z (m)", -HALF_MAP, HALF_MAP, 10)
	f_x.value_changed.connect(func(x): _set_pos(0, x))
	f_z.value_changed.connect(func(x): _set_pos(1, x))
	f_heading = _spin(form, "Heading (deg)", 0, 359, 1)
	f_heading.value_changed.connect(func(x): _set_field("heading_deg", x))
	f_speed = _spin(form, "Speed (m/s)", 0, 40, 0.5)
	f_speed.value_changed.connect(func(x): _set_field("speed", x))
	f_hp = _spin(form, "HP (0 = full)", 0, 200000, 100)
	f_hp.value_changed.connect(_set_hp)
	f_fixed = CheckBox.new()
	f_fixed.text = "Fixed helm, no bot"
	_row(form, "", f_fixed)
	f_fixed.toggled.connect(_set_fixed)
	f_identified = CheckBox.new()
	f_identified.text = "Identified by enemy"
	_row(form, "", f_identified)
	f_identified.toggled.connect(func(on): _set_field("identified", on))

	v.add_child(HSeparator.new())
	var pg := GridContainer.new()
	pg.columns = 2
	v.add_child(pg)
	control_opt = OptionButton.new()
	control_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_opt.item_selected.connect(_on_control_picked)
	_row(pg, "Control", control_opt)
	var play := Button.new()
	play.text = "Play"
	play.pressed.connect(_play)
	v.add_child(play)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status)
	var help := _label("Map: left-drag ship = move, right-drag = heading, left/middle-drag empty = pan, wheel = zoom")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(1, 1, 1, 0.6)
	v.add_child(help)

	open_dialog = _dialog(FileDialog.FILE_MODE_OPEN_FILE)
	open_dialog.file_selected.connect(_load)
	save_dialog = _dialog(FileDialog.FILE_MODE_SAVE_FILE)
	save_dialog.file_selected.connect(_save_as)

func _dialog(mode: FileDialog.FileMode) -> FileDialog:
	var d := FileDialog.new()
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.file_mode = mode
	d.filters = PackedStringArray(["*.json ; Scenario"])
	var dir := ProjectSettings.globalize_path("res://tools/scenarios")
	d.current_dir = dir if DirAccess.dir_exists_absolute(dir) else OS.get_user_data_dir()
	add_child(d)
	return d

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _button(parent: Node, t: String, f: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(f)
	parent.add_child(b)
	return b

func _row(grid: GridContainer, t: String, c: Control) -> void:
	grid.add_child(_label(t))
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(c)

func _spin(grid: GridContainer, t: String, lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.allow_greater = true
	s.allow_lesser = true
	_row(grid, t, s)
	return s

func _new() -> void:
	data = {"scenario": {"duration_s": 600.0, "elapsed_s": 0.0}, "team": {}}
	path = ""
	_refresh()

func _load(p: String) -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not parsed is Dictionary or not parsed.has("team"):
		status.text = "Not a scenario: " + p
		return
	data = parsed
	if not data.has("scenario"):
		data["scenario"] = {"duration_s": 600.0, "elapsed_s": 0.0}
	path = p
	selected = ""
	_refresh()
	status.text = "Loaded %d ships." % data.team.size()

func _save() -> void:
	if path == "":
		save_dialog.popup_centered_ratio(0.7)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		status.text = "Cannot write " + path
		return
	f.store_string(JSON.stringify(data, " ", false))
	status.text = "Saved."
	file_label.text = path

func _refresh() -> void:
	_syncing = true
	file_label.text = path if path != "" else "(unsaved)"
	duration.value = float(data.scenario.get("duration_s", 600.0))
	elapsed.value = float(data.scenario.get("elapsed_s", 0.0))
	var prev_control := _control()
	ships.clear()
	control_opt.clear()
	for key in data.team:
		var e: Dictionary = data.team[key]
		var i := ships.add_item("[%s] %s  %s" % [e.get("team", "?"), key, String(e.get("ship", "")).get_file().get_basename()])
		ships.set_item_metadata(i, key)
		ships.set_item_custom_fg_color(i, ScenarioMap.TEAM_COLORS[clampi(int(e.get("team", 0)), 0, 1)])
		if key == selected:
			ships.select(i)
		control_opt.add_item(key)
		if key == prev_control:
			control_opt.select(control_opt.item_count - 1)
	if not data.team.has(selected):
		selected = ""
	_syncing = false
	map.team = data.team
	map.selected = selected
	map.control_key = _control()
	map.queue_redraw()
	_fill_form()

func _fill_form() -> void:
	_syncing = true
	form.visible = selected != ""
	if selected != "":
		var e: Dictionary = data.team[selected]
		f_name.text = selected
		f_team.select(clampi(int(e.get("team", 0)), 0, 1))
		f_ship.select(_ship_paths.find(e.get("ship", "")))
		var p := ScenarioMap.pos_of(e)
		f_x.value = p.x
		f_z.value = p.y
		f_heading.value = float(e.get("heading_deg", 0.0))
		f_speed.value = float(e.get("speed", 0.0))
		f_hp.value = float(e.get("hp", 0.0))
		f_fixed.button_pressed = e.has("fixed")
		f_identified.button_pressed = bool(e.get("identified", false))
	_syncing = false

func _control() -> String:
	return control_opt.get_item_text(control_opt.selected) if control_opt.selected >= 0 else ""

func _select(key: String) -> void:
	selected = key
	map.selected = key
	for i in ships.item_count:
		if ships.get_item_metadata(i) == key:
			ships.select(i)
	map.queue_redraw()
	_fill_form()

func _on_map_changed(key: String) -> void:
	if key == selected:
		_fill_form()

func _set_field(field: String, value) -> void:
	if _syncing or selected == "":
		return
	data.team[selected][field] = value
	if field == "team" or field == "ship":
		_refresh()
	map.queue_redraw()

func _erase_field(field: String) -> void:
	if not _syncing and selected != "":
		data.team[selected].erase(field)

func _set_scenario(value: float, field: String) -> void:
	if not _syncing:
		data["scenario"][field] = value

func _set_hp(value: float) -> void:
	if value > 0.0:
		_set_field("hp", value)
	else:
		_erase_field("hp")

func _on_control_picked(_i: int) -> void:
	map.control_key = _control()
	map.queue_redraw()

func _save_as(p: String) -> void:
	path = p
	_save()

func _on_connect_failed() -> void:
	status.text = "Connection to game server failed."

func _set_pos(axis: int, value: float) -> void:
	if _syncing or selected == "":
		return
	var p := ScenarioMap.pos_of(data.team[selected])
	p[axis] = value
	data.team[selected]["pos"] = [p.x, p.y]
	map.queue_redraw()

func _set_fixed(on: bool) -> void:
	if _syncing or selected == "":
		return
	var e: Dictionary = data.team[selected]
	if on and not e.has("fixed"):
		e["fixed"] = {"throttle": 0, "rudder": 0}
	elif not on:
		e.erase("fixed")
	_refresh()

func _rename(new_key: String) -> void:
	new_key = new_key.strip_edges()
	if _syncing or selected == "" or new_key == selected or new_key == "" or data.team.has(new_key):
		return
	var renamed: Dictionary = {}
	for key in data.team:
		renamed[new_key if key == selected else key] = data.team[key]
	renamed[new_key]["player_id"] = new_key
	data["team"] = renamed
	selected = new_key
	_refresh()

func _unique_key(base: String) -> String:
	var k := base
	var n := 1
	while data.team.has(k):
		n += 1
		k = "%s%d" % [base, n]
	return k

func _add() -> void:
	var c := map.to_world(map.size * 0.5)
	var key := _unique_key("ship")
	data.team[key] = {"team": "1", "player_id": key, "ship": _ship_paths[0], "is_bot": true, "aptitude": 1,
		"spawn_position": data.team.size(), "pos": [snappedf(c.x, 10.0), snappedf(c.y, 10.0)],
		"heading_deg": 0.0, "speed": 0.0, "identified": true}
	selected = key
	_refresh()

func _duplicate() -> void:
	if selected == "":
		return
	var key := _unique_key(selected)
	var e: Dictionary = data.team[selected].duplicate(true)
	e["player_id"] = key
	var p := ScenarioMap.pos_of(e) + Vector2(500, 500)
	e["pos"] = [p.x, p.y]
	data.team[key] = e
	selected = key
	_refresh()

func _remove() -> void:
	if selected == "":
		return
	data.team.erase(selected)
	selected = ""
	_refresh()

func _play() -> void:
	var control := _control()
	if control == "":
		status.text = "Add a ship to control."
		return
	if not data.team.values().any(func(e): return e is Dictionary and str(e.get("team", "")) != str(data.team[control].get("team", ""))):
		status.text = "Scenario needs an enemy ship."
		return
	GameSettings.is_single_player = true
	GameSettings.save_settings()
	_udp = PacketPeerUDP.new()
	_udp.connect_to_host(GameSettings.matchmaker_ip, MATCHMAKER_PORT)
	_udp.put_packet(JSON.stringify({
		"request": "request_server",
		"player_name": GameSettings.player_name,
		"selected_ship": data.team[control].get("ship", ""),
		"single_player": true,
		"scenario": data,
		"control": control,
	}).to_utf8_buffer())
	status.text = "Asking matchmaker for a server..."

func _process(_delta: float) -> void:
	if _udp == null or _udp.get_available_packet_count() == 0:
		return
	var info = bytes_to_var(_udp.get_packet())
	_udp = null
	if info == null:
		status.text = "Matchmaker gave no server."
		return
	status.text = "Connecting to game server..."
	NetworkManager.create_client(info.ip, info.port)
	GameSettings.is_single_player = false
	GameSettings.save_settings()

func _on_connected() -> void:
	TcpThreadPool.start_client()
	get_tree().change_scene_to_file.call_deferred("res://src/server/server.tscn")
