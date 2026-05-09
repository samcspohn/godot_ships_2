extends Node

# ---------------------------------------------------------------------------
# Onready references — matched to match_replay.tscn scene structure
# ---------------------------------------------------------------------------
@onready var sub_viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var world_3d: Node3D = $SubViewportContainer/SubViewport/World3D
@onready var ghost_ships_root: Node3D = $SubViewportContainer/SubViewport/World3D/GhostShipsRoot
@onready var shell_replayer: ShellReplayer = $SubViewportContainer/SubViewport/World3D/ShellReplayer
@onready var torpedo_replayer: TorpedoReplayer = $SubViewportContainer/SubViewport/World3D/TorpedoReplayer
@onready var replay_camera: Camera3D = $SubViewportContainer/SubViewport/World3D/ReplayCamera

# UI references
@onready var back_button: Button = $UI/UIRoot/TopBar/HBox/BackButton
@onready var match_info_label: Label = $UI/UIRoot/TopBar/HBox/MatchInfoLabel
@onready var ship_follow_option: OptionButton = $UI/UIRoot/TopBar/HBox/ShipFollowOption
@onready var kill_feed: VBoxContainer = $UI/UIRoot/SidePanel/VBox/KillFeed
@onready var play_pause_button: Button = $UI/UIRoot/BottomBar/VBox/Controls/PlayPauseButton
@onready var speed_container: HBoxContainer = $UI/UIRoot/BottomBar/VBox/Controls/SpeedContainer
@onready var time_label: Label = $UI/UIRoot/BottomBar/VBox/Controls/TimeLabel
@onready var scrubber: HSlider = $UI/UIRoot/BottomBar/VBox/Scrubber

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var playback: ReplayPlayback = ReplayPlayback.new()
var ghost_ships: Array = []  # Array[GhostShip]

# Camera orbit state
var _cam_yaw: float = 0.0
var _cam_pitch: float = deg_to_rad(45.0)
var _cam_distance: float = 5000.0
var _cam_target: Vector3 = Vector3.ZERO
var _is_dragging: bool = false
var _last_mouse: Vector2 = Vector2.ZERO
const CAM_ROTATE_SPEED: float = 0.005
const CAM_ZOOM_SPEED: float = 300.0
const CAM_MIN_DIST: float = 200.0
const CAM_MAX_DIST: float = 30000.0

var _follow_ship_id: int = -1   # -1 = free orbit
var _scrubber_dragging: bool = false
var _speed_buttons: Array = []

# ---------------------------------------------------------------------------
# _ready
# ---------------------------------------------------------------------------
func _ready() -> void:
	add_child(playback)

	# Connect playback signals
	playback.time_changed.connect(_on_time_changed)
	playback.event_fired.connect(_on_event_fired)
	playback.playback_ended.connect(_on_playback_ended)
	if playback.has_signal("replay_loaded"):
		playback.replay_loaded.connect(_on_replay_loaded)

	# Connect UI signals
	back_button.pressed.connect(_on_back_pressed)
	play_pause_button.pressed.connect(_on_play_pause_pressed)
	ship_follow_option.item_selected.connect(_on_ship_follow_selected)
	scrubber.value_changed.connect(_on_scrubber_value_changed)
	scrubber.drag_started.connect(func(): _scrubber_dragging = true)
	scrubber.drag_ended.connect(func(_val): _scrubber_dragging = false)

	# Build speed buttons
	var speeds = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]
	var labels = ["0.25x", "0.5x", "1x", "2x", "4x", "8x"]
	for i in speeds.size():
		var btn = Button.new()
		btn.text = labels[i]
		var s = speeds[i]
		btn.pressed.connect(func(): _set_speed(s, btn))
		speed_container.add_child(btn)
		_speed_buttons.append(btn)

	# Style bottom bar
	var bar_style = StyleBoxFlat.new()
	bar_style.bg_color = Color(0.05, 0.05, 0.1, 0.85)
	bar_style.corner_radius_top_left = 6
	bar_style.corner_radius_top_right = 6
	bar_style.corner_radius_bottom_left = 6
	bar_style.corner_radius_bottom_right = 6

	var side_style = StyleBoxFlat.new()
	side_style.bg_color = Color(0.05, 0.05, 0.1, 0.85)
	side_style.corner_radius_top_left = 6
	side_style.corner_radius_top_right = 6
	side_style.corner_radius_bottom_left = 6
	side_style.corner_radius_bottom_right = 6

	$UI/UIRoot/BottomBar.add_theme_stylebox_override("panel", bar_style)
	$UI/UIRoot/SidePanel.add_theme_stylebox_override("panel", side_style)
	$UI/UIRoot/TopBar.add_theme_stylebox_override("panel", bar_style.duplicate())

	# Load the replay file
	var err = playback.load_replay(_Utils.pending_replay_path)
	if err != OK:
		match_info_label.text = "Error: could not load replay (code %d)" % err
		push_error("MatchReplay: load_replay failed with error %d for path: %s" % [err, _Utils.pending_replay_path])
		return

	# Instantiate ghost ships
	for ship_entry in playback.reader.ships:
		var gs = GhostShip.new()
		ghost_ships_root.add_child(gs)
		gs.setup(ship_entry)
		ghost_ships.append(gs)
		ship_follow_option.add_item(
			ship_entry.get("ship_name", "Ship") + " (" + ship_entry.get("player_name", "?") + ")",
			ship_entry.get("ship_id", 0)
		)
	ship_follow_option.add_item("Free Camera", -1)

	# Hand ghost ships to playback
	playback.setup_ghost_ships(ghost_ships)

	# Hook up weapon replayers
	playback.shell_replayer = shell_replayer
	playback.torpedo_replayer = torpedo_replayer
	shell_replayer.ghost_ships = ghost_ships

	# Load map
	var map_id = playback.reader.header.get("map_id", 0)
	var map_path = "res://src/Maps/map.tscn" if map_id == 0 else "res://src/Maps/map2.tscn"
	var map_scene = load(map_path)
	if map_scene:
		world_3d.add_child(map_scene.instantiate())

	# Update match info label
	_refresh_match_info()

	# Start playback and highlight 1x button
	playback.play()
	play_pause_button.text = "⏸"
	if _speed_buttons.size() >= 3:
		_set_speed(1.0, _speed_buttons[2])

# ---------------------------------------------------------------------------
# Speed control
# ---------------------------------------------------------------------------
func _set_speed(s: float, active_btn: Button) -> void:
	playback.set_speed(s)
	for btn in _speed_buttons:
		btn.modulate = Color.WHITE
	if active_btn:
		active_btn.modulate = Color.YELLOW

# ---------------------------------------------------------------------------
# Playback signal callbacks
# ---------------------------------------------------------------------------
func _on_time_changed(t: float) -> void:
	time_label.text = "%s / %s" % [_format_time(t), _format_time(playback.get_duration())]
	if not _scrubber_dragging:
		scrubber.value = t / max(playback.get_duration(), 1.0)

func _on_event_fired(event: Dictionary) -> void:
	if event.get("type", -1) == ReplayEvent.SHIP_SUNK:
		_add_kill_feed_entry(event)

func _on_replay_loaded() -> void:
	_refresh_match_info()

func _on_playback_ended() -> void:
	play_pause_button.text = "▶"

# ---------------------------------------------------------------------------
# Kill feed
# ---------------------------------------------------------------------------
func _add_kill_feed_entry(event: Dictionary) -> void:
	var victim_name = "Unknown"
	var sinker_name = "Unknown"
	for ship in playback.reader.ships:
		if ship.get("ship_id") == event.get("victim_ship_id"):
			victim_name = ship.get("ship_name", "Unknown")
		if ship.get("ship_id") == event.get("sinker_ship_id"):
			sinker_name = ship.get("ship_name", "Unknown")

	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.05, 0.05, 0.9)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	panel.add_theme_stylebox_override("panel", style)

	var label = Label.new()
	label.text = sinker_name + " ⚓ " + victim_name
	label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	panel.add_child(label)

	kill_feed.add_child(panel)

	# Keep max 6 entries
	while kill_feed.get_child_count() > 6:
		kill_feed.get_child(0).queue_free()

	# Fade out after 10 seconds
	var tween = create_tween()
	tween.tween_interval(8.0)
	tween.tween_property(panel, "modulate:a", 0.0, 2.0)
	tween.tween_callback(panel.queue_free)

# ---------------------------------------------------------------------------
# Scrubber
# ---------------------------------------------------------------------------
func _on_scrubber_value_changed(value: float) -> void:
	if _scrubber_dragging:
		playback.seek(value * playback.get_duration())

# ---------------------------------------------------------------------------
# Input — camera orbit and space-bar play/pause
# ---------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_is_dragging = event.pressed
			_last_mouse = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_distance = max(_cam_distance - CAM_ZOOM_SPEED * (_cam_distance / 5000.0), CAM_MIN_DIST)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_distance = min(_cam_distance + CAM_ZOOM_SPEED * (_cam_distance / 5000.0), CAM_MAX_DIST)
	elif event is InputEventMouseMotion and _is_dragging:
		var delta = event.position - _last_mouse
		_cam_yaw -= delta.x * CAM_ROTATE_SPEED
		_cam_pitch = clamp(_cam_pitch - delta.y * CAM_ROTATE_SPEED, deg_to_rad(5.0), deg_to_rad(89.0))
		_last_mouse = event.position

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_on_play_pause_pressed()

# ---------------------------------------------------------------------------
# Process — camera update
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	_update_camera()

func _update_camera() -> void:
	# Follow a ghost ship if selected
	if _follow_ship_id >= 0:
		for gs in ghost_ships:
			if gs and is_instance_valid(gs):
				if gs.ship_entry.get("ship_id", -2) == _follow_ship_id:
					_cam_target = gs.global_position
					break

	# Spherical coordinate orbit camera
	var offset = Vector3(
		sin(_cam_yaw) * cos(_cam_pitch),
		sin(_cam_pitch),
		cos(_cam_yaw) * cos(_cam_pitch)
	) * _cam_distance

	replay_camera.global_position = _cam_target + offset
	replay_camera.look_at(_cam_target, Vector3.UP)

# ---------------------------------------------------------------------------
# UI callbacks
# ---------------------------------------------------------------------------
func _on_play_pause_pressed() -> void:
	if playback.is_playing:
		playback.pause()
		play_pause_button.text = "▶"
	else:
		playback.play()
		play_pause_button.text = "⏸"

func _on_ship_follow_selected(index: int) -> void:
	var ship_id = ship_follow_option.get_item_id(index)
	_follow_ship_id = ship_id

func _on_back_pressed() -> void:
	playback.pause()
	get_tree().change_scene_to_file("res://src/port/main_menu/main_menu.tscn")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _format_time(t: float) -> String:
	return "%d:%02d" % [int(t) / 60, int(t) % 60]

func _refresh_match_info() -> void:
	if not playback.reader:
		return
	var ship_count = playback.reader.ships.size()
	var duration = _format_time(playback.reader.total_duration)
	var map_id = playback.reader.header.get("map_id", 0)
	var map_name = "Ocean" if map_id == 0 else "Map 2"
	match_info_label.text = "Map: %s  |  Ships: %d  |  Duration: %s" % [map_name, ship_count, duration]
