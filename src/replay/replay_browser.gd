extends Control

# ---------------------------------------------------------------------------
# Onready references — matched to replay_browser.tscn scene structure
# ---------------------------------------------------------------------------
@onready var replay_list: ItemList = $VBox/ReplayList
@onready var info_label: Label = $VBox/InfoLabel
@onready var play_button: Button = $VBox/Buttons/PlayButton
@onready var delete_button: Button = $VBox/Buttons/DeleteButton
@onready var back_button: Button = $VBox/Buttons/BackButton

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _replay_files: Array = []   # Array of {path: String, filename: String, header: Dictionary}
var _selected_index: int = -1

# ---------------------------------------------------------------------------
# _ready
# ---------------------------------------------------------------------------
func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	play_button.pressed.connect(_on_play_pressed)
	delete_button.pressed.connect(_on_delete_pressed)
	replay_list.item_selected.connect(_on_replay_selected)

	_scan_replays()

# ---------------------------------------------------------------------------
# Scan user://replays for .replay files
# ---------------------------------------------------------------------------
func _scan_replays() -> void:
	replay_list.clear()
	_replay_files.clear()
	_selected_index = -1
	play_button.disabled = true
	delete_button.disabled = true

	var dir = DirAccess.open("user://replays")
	if dir == null:
		info_label.text = "No replays found."
		return

	dir.list_dir_begin()
	var filename = dir.get_next()
	while filename != "":
		if filename.ends_with(".replay"):
			var path = "user://replays/" + filename
			var header = _read_replay_header(path)
			_replay_files.append({"path": path, "filename": filename, "header": header})
		filename = dir.get_next()
	dir.list_dir_end()

	# Sort by timestamp descending (newest first)
	_replay_files.sort_custom(func(a, b): return a.header.get("match_ts", 0) > b.header.get("match_ts", 0))

	for entry in _replay_files:
		var ts = entry.header.get("match_ts", 0)
		var ship_count = entry.header.get("ship_count", 0)
		var map_id = entry.header.get("map_id", 0)
		var map_name = "Ocean" if map_id == 0 else "Map 2"
		var date_str = Time.get_datetime_string_from_unix_time(ts).substr(0, 16).replace("T", " ")
		var display = "%s  |  %s  |  %d ships" % [date_str, map_name, ship_count]
		replay_list.add_item(display)

	if _replay_files.is_empty():
		info_label.text = "No replays found. Play a match to record one!"

# ---------------------------------------------------------------------------
# Read just the binary header from a .replay file
# ---------------------------------------------------------------------------
func _read_replay_header(path: String) -> Dictionary:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var magic = f.get_32()
	if magic != 0x52455050:  # "REPP"
		f.close()
		return {}
	var version = f.get_16()
	var match_ts = f.get_32()
	var map_id = f.get_8()
	var ship_count = f.get_16()
	f.close()
	return {
		"magic": magic,
		"version": version,
		"match_ts": match_ts,
		"map_id": map_id,
		"ship_count": ship_count
	}

# ---------------------------------------------------------------------------
# List selection
# ---------------------------------------------------------------------------
func _on_replay_selected(index: int) -> void:
	_selected_index = index
	play_button.disabled = false
	delete_button.disabled = false
	var entry = _replay_files[index]
	var ts = entry.header.get("match_ts", 0)
	var date_str = Time.get_datetime_string_from_unix_time(ts).substr(0, 19).replace("T", " ")
	info_label.text = "Date: %s\nShips: %d\nFile: %s" % [
		date_str,
		entry.header.get("ship_count", 0),
		entry.filename
	]

# ---------------------------------------------------------------------------
# Button callbacks
# ---------------------------------------------------------------------------
func _on_play_pressed() -> void:
	if _selected_index < 0 or _selected_index >= _replay_files.size():
		return
	_Utils.pending_replay_path = _replay_files[_selected_index].path
	get_tree().change_scene_to_file("res://src/replay/match_replay.tscn")

func _on_delete_pressed() -> void:
	if _selected_index < 0:
		return
	var path = _replay_files[_selected_index].path
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_scan_replays()

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://src/port/main_menu/main_menu.tscn")
