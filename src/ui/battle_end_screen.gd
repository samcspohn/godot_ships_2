class_name BattleEndScreen
extends Control

const GOLD := Color(1.0, 0.84, 0.0)
const DEFEAT_RED := Color(0.9, 0.2, 0.2)
const LABEL_GRAY := Color(0.7, 0.7, 0.7)
const VALUE_WHITE := Color(1.0, 1.0, 1.0)
const SUBTITLE_WHITE := Color(1.0, 1.0, 1.0, 0.7)
const OVERLAY_COLOR := Color(0, 0, 0, 0.7)
const BUTTON_BG_COLOR := Color(0.15, 0.15, 0.15, 0.9)
const BUTTON_HOVER_COLOR := Color(0.25, 0.25, 0.25, 0.9)
const SEPARATOR_COLOR := Color(0.4, 0.4, 0.4, 0.5)
const TAB_ACTIVE_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const TAB_INACTIVE_COLOR := Color(0.5, 0.5, 0.5, 0.8)
const FRIENDLY_COLOR := Color(0.4, 0.8, 1.0)
const ENEMY_COLOR := Color(1.0, 0.5, 0.4)
const DEAD_COLOR := Color(0.5, 0.5, 0.5, 0.6)
const PLAYER_HIGHLIGHT := Color(1.0, 0.84, 0.0, 0.15)
const ROW_BG_EVEN := Color(0.08, 0.08, 0.12, 0.7)
const ROW_BG_ODD := Color(0.12, 0.12, 0.16, 0.7)

var _return_button: Button
var _tab_container: TabContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate.a = 0.0

	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Read match result data stashed on the autoload
	var result: Dictionary = _Utils.match_result
	if result.is_empty():
		push_error("BattleEndScreen: No match_result data found on _Utils")
		return

	var winning_team: int = result.get("winning_team", -1)
	var friendly_team_id: int = result.get("friendly_team_id", -1)
	var ship_name: String = result.get("ship_name", "")
	var stats: Dictionary = result.get("stats", {})
	var screenshot: Image = result.get("screenshot", null)
	var leaderboard: Array = result.get("leaderboard", [])

	var is_victory := winning_team == friendly_team_id

	# -- Screenshot background --
	if screenshot:
		var tex := ImageTexture.create_from_image(screenshot)
		var screenshot_rect := TextureRect.new()
		screenshot_rect.texture = tex
		screenshot_rect.anchors_preset = Control.PRESET_FULL_RECT
		screenshot_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		screenshot_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(screenshot_rect)

	# -- Full-screen dark overlay --
	var background := ColorRect.new()
	background.color = OVERLAY_COLOR
	background.anchors_preset = Control.PRESET_FULL_RECT
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(background)

	# -- Root margin --
	var root_margin := MarginContainer.new()
	root_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_margin.add_theme_constant_override("margin_left", 60)
	root_margin.add_theme_constant_override("margin_right", 60)
	root_margin.add_theme_constant_override("margin_top", 30)
	root_margin.add_theme_constant_override("margin_bottom", 30)
	root_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_margin)

	# -- Main VBox --
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_margin.add_child(vbox)

	# -- Title --
	var title_label := _make_label(
		"VICTORY" if is_victory else "DEFEAT",
		56,
		GOLD if is_victory else DEFEAT_RED,
		HORIZONTAL_ALIGNMENT_CENTER,
	)
	vbox.add_child(title_label)

	# -- Subtitle --
	var subtitle_label := _make_label(ship_name, 22, SUBTITLE_WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	vbox.add_child(subtitle_label)

	# -- Separator --
	var separator := HSeparator.new()
	separator.add_theme_stylebox_override("separator", _make_separator_stylebox())
	vbox.add_child(separator)

	# -- Tab container (Godot's built-in TabContainer handles sizing + tab bar) --
	_tab_container = TabContainer.new()
	_tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_container.tab_alignment = TabBar.ALIGNMENT_CENTER
	# Style the tab container background to be transparent
	var tc_panel := StyleBoxFlat.new()
	tc_panel.bg_color = Color(0.05, 0.05, 0.05, 0.4)
	tc_panel.corner_radius_bottom_left = 4
	tc_panel.corner_radius_bottom_right = 4
	tc_panel.content_margin_left = 8
	tc_panel.content_margin_right = 8
	tc_panel.content_margin_top = 8
	tc_panel.content_margin_bottom = 8
	_tab_container.add_theme_stylebox_override("panel", tc_panel)
	vbox.add_child(_tab_container)

	# -- Personal Stats tab --
	var personal_tab := _build_personal_stats_tab(stats)
	personal_tab.name = "Personal Stats"
	_tab_container.add_child(personal_tab)

	# -- Leaderboard tab --
	var leaderboard_tab := _build_leaderboard_tab(leaderboard, friendly_team_id, ship_name)
	leaderboard_tab.name = "Leaderboard"
	_tab_container.add_child(leaderboard_tab)

	# -- Return to Port button --
	_return_button = _make_return_button()
	vbox.add_child(_return_button)

	# -- Fade-in --
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)





# ===========================================================================
#  Personal Stats tab
# ===========================================================================
func _build_personal_stats_tab(stats: Dictionary) -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	var scroll_vbox := VBoxContainer.new()
	scroll_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_vbox.add_theme_constant_override("separation", 12)
	scroll.add_child(scroll_vbox)

	# Center the stats grid
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_vbox.add_child(center)

	var stats_wrapper := VBoxContainer.new()
	stats_wrapper.custom_minimum_size.x = 450
	stats_wrapper.add_theme_constant_override("separation", 12)
	center.add_child(stats_wrapper)

	var stats_grid := _make_stats_grid()
	stats_wrapper.add_child(stats_grid)

	_add_stat_row(stats_grid, "Total Damage", "%d" % stats.get("total_damage", 0.0))
	_add_stat_row(stats_grid, "Ships Destroyed", str(stats.get("frags", 0)))
	_add_stat_row(stats_grid, "Main Battery Hits", str(stats.get("main_hits", 0)))
	_add_stat_row(stats_grid, "Main Battery Damage", "%d" % stats.get("main_damage", 0.0))
	_add_stat_row(stats_grid, "Citadels", str(stats.get("citadel_count", 0)))
	_add_stat_row(stats_grid, "Secondary Hits", str(stats.get("secondary_count", 0)))
	_add_stat_row(stats_grid, "Secondary Damage", "%d" % stats.get("sec_damage", 0.0))
	_add_stat_row(stats_grid, "Torpedo Hits", str(stats.get("torpedo_count", 0)))
	_add_stat_row(stats_grid, "Torpedo Damage", "%d" % stats.get("torpedo_damage", 0.0))
	_add_stat_row(stats_grid, "Fires Set", str(stats.get("fire_count", 0)))
	_add_stat_row(stats_grid, "Fire Damage", "%d" % stats.get("fire_damage", 0.0))
	_add_stat_row(stats_grid, "Floods Caused", str(stats.get("flood_count", 0)))
	_add_stat_row(stats_grid, "Flood Damage", "%d" % stats.get("flood_damage", 0.0))
	_add_stat_row(stats_grid, "Spotting Damage", "%d" % stats.get("spotting_damage", 0.0))
	_add_stat_row(stats_grid, "Potential Damage", "%d" % stats.get("potential_damage", 0.0))

	# Ships damaged section
	var ships_damaged: Dictionary = stats.get("ships_damaged", {})
	if not ships_damaged.is_empty():
		var ships_header := _make_label("Ships Damaged", 20, LABEL_GRAY, HORIZONTAL_ALIGNMENT_CENTER)
		stats_wrapper.add_child(ships_header)

		var ships_grid := _make_stats_grid()
		stats_wrapper.add_child(ships_grid)

		var sorted_ships: Array = ships_damaged.keys()
		sorted_ships.sort()
		for s_name: String in sorted_ships:
			var dmg: float = ships_damaged[s_name]
			_add_stat_row(ships_grid, s_name, "%d" % dmg)

	return scroll


# ===========================================================================
#  Leaderboard tab
# ===========================================================================
func _build_leaderboard_tab(leaderboard: Array, friendly_team_id: int, local_ship_name: String) -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	# Side-by-side layout: friendly on left, enemy on right
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.size_flags_vertical = Control.SIZE_FILL
	hbox.add_theme_constant_override("separation", 24)
	scroll.add_child(hbox)

	# Sort by damage descending within each team
	var friendly_entries: Array = []
	var enemy_entries: Array = []
	for entry in leaderboard:
		if entry.get("team_id", -1) == friendly_team_id:
			friendly_entries.append(entry)
		else:
			enemy_entries.append(entry)

	friendly_entries.sort_custom(func(a, b): return a.get("total_damage", 0) > b.get("total_damage", 0))
	enemy_entries.sort_custom(func(a, b): return a.get("total_damage", 0) > b.get("total_damage", 0))

	# Friendly team (left side)
	var friendly_vbox := VBoxContainer.new()
	friendly_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	friendly_vbox.add_theme_constant_override("separation", 4)
	hbox.add_child(friendly_vbox)

	var friendly_header := _make_label("Your Team", 22, FRIENDLY_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	friendly_vbox.add_child(friendly_header)
	if friendly_entries.size() > 0:
		var table := _build_team_table(friendly_entries, local_ship_name, true)
		friendly_vbox.add_child(table)

	# Enemy team (right side)
	var enemy_vbox := VBoxContainer.new()
	enemy_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enemy_vbox.add_theme_constant_override("separation", 4)
	hbox.add_child(enemy_vbox)

	var enemy_header := _make_label("Enemy Team", 22, ENEMY_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	enemy_vbox.add_child(enemy_header)
	if enemy_entries.size() > 0:
		var table := _build_team_table(enemy_entries, local_ship_name, false)
		enemy_vbox.add_child(table)

	return scroll


func _build_team_table(entries: Array, local_ship_name: String, is_friendly: bool) -> Control:
	"""Build a table of player stats for one team."""
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 0)

	# Header row
	var header_row := _make_leaderboard_row(
		"Ship", "Damage", "Kills", "Main", "Sec", "Torp", "Fire", "Spot",
		LABEL_GRAY, false, 14
	)
	vbox.add_child(header_row)

	# Separator under header
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", _make_separator_stylebox())
	vbox.add_child(sep)

	# Player rows
	var row_index := 0
	for entry: Dictionary in entries:
		var entry_ship_name: String = entry.get("ship_name", "Unknown")
		var player_name: String = entry.get("player_name", "")
		var is_local: bool = (entry_ship_name == local_ship_name and not entry.get("is_bot", true))
		var is_alive: bool = entry.get("alive", false)

		# Display name: ship name, with player name if not a bot
		var display_name := entry_ship_name
		if not entry.get("is_bot", true):
			display_name = entry_ship_name + " (" + player_name + ")"

		var name_color: Color
		if not is_alive:
			name_color = DEAD_COLOR
		elif is_friendly:
			name_color = FRIENDLY_COLOR
		else:
			name_color = ENEMY_COLOR

		var row_bg := ROW_BG_EVEN if row_index % 2 == 0 else ROW_BG_ODD
		var row := _make_leaderboard_row(
			display_name,
			"%d" % entry.get("total_damage", 0.0),
			str(entry.get("frags", 0)),
			str(entry.get("main_hits", 0)),
			str(entry.get("secondary_count", 0)),
			str(entry.get("torpedo_count", 0)),
			str(entry.get("fire_count", 0)),
			"%d" % entry.get("spotting_damage", 0.0),
			VALUE_WHITE,
			is_local,
			15,
			row_bg,
		)

		# Override the name label color (PanelContainer → HBoxContainer → first Label)
		var name_label: Label = row.get_child(0).get_child(0)
		name_label.add_theme_color_override("font_color", name_color)

		vbox.add_child(row)
		row_index += 1

	return vbox


func _make_leaderboard_row(
	col_name: String, col_dmg: String, col_kills: String, col_main: String,
	col_sec: String, col_torp: String, col_fire: String, col_spot: String,
	text_color: Color, highlight: bool, font_size: int = 15,
	row_bg_color: Color = Color.TRANSPARENT,
) -> PanelContainer:
	"""Create a single row for the leaderboard table."""
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Row background: highlighted for local player, otherwise alternating dark rows
	var bg := StyleBoxFlat.new()
	if highlight:
		bg.bg_color = PLAYER_HIGHLIGHT
	else:
		bg.bg_color = row_bg_color
	bg.content_margin_left = 8
	bg.content_margin_right = 8
	bg.content_margin_top = 4
	bg.content_margin_bottom = 4
	bg.corner_radius_top_left = 2
	bg.corner_radius_top_right = 2
	bg.corner_radius_bottom_left = 2
	bg.corner_radius_bottom_right = 2
	panel.add_theme_stylebox_override("panel", bg)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(hbox)

	# Column definitions: [text, min_width, alignment]
	var columns := [
		[col_name, 220, HORIZONTAL_ALIGNMENT_LEFT],
		[col_dmg, 80, HORIZONTAL_ALIGNMENT_RIGHT],
		[col_kills, 50, HORIZONTAL_ALIGNMENT_RIGHT],
		[col_main, 50, HORIZONTAL_ALIGNMENT_RIGHT],
		[col_sec, 50, HORIZONTAL_ALIGNMENT_RIGHT],
		[col_torp, 50, HORIZONTAL_ALIGNMENT_RIGHT],
		[col_fire, 50, HORIZONTAL_ALIGNMENT_RIGHT],
		[col_spot, 80, HORIZONTAL_ALIGNMENT_RIGHT],
	]

	for col in columns:
		var label := _make_label(col[0], font_size, text_color, col[2])
		label.custom_minimum_size.x = col[1]
		if col[2] == HORIZONTAL_ALIGNMENT_LEFT:
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			label.size_flags_horizontal = Control.SIZE_SHRINK_END
		label.clip_text = true
		hbox.add_child(label)

	return panel


# ===========================================================================
#  Shared helpers (same as before)
# ===========================================================================
func _make_label(
	text: String,
	font_size: int,
	color: Color,
	alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = alignment
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _make_stats_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 32)
	grid.add_theme_constant_override("v_separation", 6)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return grid


func _add_stat_row(grid: GridContainer, label_text: String, value_text: String) -> void:
	var name_label := _make_label(label_text, 18, LABEL_GRAY, HORIZONTAL_ALIGNMENT_LEFT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var value_label := _make_label(value_text, 18, VALUE_WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(name_label)
	grid.add_child(value_label)


func _make_separator_stylebox() -> StyleBoxLine:
	var style := StyleBoxLine.new()
	style.color = SEPARATOR_COLOR
	style.thickness = 1
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style




func _make_return_button() -> Button:
	var button := Button.new()
	button.text = "Return to Port"
	button.custom_minimum_size = Vector2(200, 50)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", 20)
	button.add_theme_color_override("font_color", VALUE_WHITE)
	button.add_theme_color_override("font_hover_color", GOLD)

	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = BUTTON_BG_COLOR
	normal_style.corner_radius_top_left = 4
	normal_style.corner_radius_top_right = 4
	normal_style.corner_radius_bottom_left = 4
	normal_style.corner_radius_bottom_right = 4
	normal_style.content_margin_left = 16
	normal_style.content_margin_right = 16
	normal_style.content_margin_top = 8
	normal_style.content_margin_bottom = 8
	button.add_theme_stylebox_override("normal", normal_style)

	var hover_style := normal_style.duplicate()
	hover_style.bg_color = BUTTON_HOVER_COLOR
	button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style := normal_style.duplicate()
	pressed_style.bg_color = BUTTON_BG_COLOR.darkened(0.2)
	button.add_theme_stylebox_override("pressed", pressed_style)

	button.pressed.connect(_on_return_to_port_pressed)
	return button


func _on_return_to_port_pressed() -> void:
	_Utils.match_result = {}
	NetworkManager.disconnect_network()
	get_tree().change_scene_to_file("res://src/port/main_menu/main_menu.tscn")
