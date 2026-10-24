extends CanvasLayer
class_name LiveScoreboard

const REFRESH_S: float = 0.5

var _server: GameServer
var _root: Control
var _title: Label
var _table: Control
var _refresh_in: float = 0.0


func _ready() -> void:
	layer = 90
	_server = get_tree().root.get_node_or_null("Server") as GameServer
	_server.live_leaderboard_received.connect(_on_leaderboard)

	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 60 if side in ["left", "right"] else 40)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)
	_title = BattleEndScreen._make_label("", 26, BattleEndScreen.VALUE_WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_title)
	_table = VBoxContainer.new()
	_table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_table.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_table)


# Polled, not event-driven: BattleCamera's spectate input swallows every key event.
func _process(delta: float) -> void:
	var held := Input.is_physical_key_pressed(KEY_TAB) and get_window().has_focus()
	_root.visible = held
	if not held:
		_refresh_in = 0.0
		return
	var remaining := int(_server.get_match_time_remaining())
	var p0: int = _server.teams[0].points
	var p1: int = _server.teams[1].points
	_title.text = "%d  :  %d      %d:%02d" % [p0, p1, remaining / 60, remaining % 60]
	_refresh_in -= delta
	if _refresh_in <= 0.0:
		_refresh_in = REFRESH_S
		_server.request_live_leaderboard.rpc_id(1)


func _on_leaderboard(leaderboard: Array) -> void:
	for c in _table.get_children():
		c.queue_free()
	var local := _local_ship()
	var team_id: int = local.team.team_id if local != null else 0
	var ship_name: String = local.ship_name if local != null else ""
	var board := BattleEndScreen.build_leaderboard(leaderboard, team_id, ship_name, local == null)
	_ignore_mouse(board)
	_table.add_child(board)


func _local_ship() -> Ship:
	var my_id := multiplayer.get_unique_id()
	for p_name in _server.players:
		var entry: Array = _server.players[p_name]
		var s: Ship = entry[0]
		if int(entry[2]) == my_id and is_instance_valid(s) and s.team != null and not s.team.is_bot:
			return s
	return null


static func _ignore_mouse(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		_ignore_mouse(c)
