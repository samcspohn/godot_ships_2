extends Control

class_name KillFeed

const MAX_ENTRIES := 5
const DISPLAY_DURATION := 6.0
const FADE_DURATION := 1.0

const FRIENDLY_COLOR := Color(0.4, 1.0, 0.4)
const ENEMY_COLOR := Color(1.0, 0.4, 0.4)
const DAMAGE_TYPE_COLOR := Color(0.85, 0.85, 0.85)

const DAMAGE_TYPE_ICON_PATHS := {
	0: "res://icons/kill_feed/shell.svg",      # SHELL
	1: "res://icons/kill_feed/torpedo.svg",    # TORPEDO
	2: "res://icons/kill_feed/fire.svg",       # FIRE
	3: "res://icons/kill_feed/flood.svg",      # FLOOD
	4: "res://icons/kill_feed/secondary.svg",  # SECONDARY
}

static var _damage_type_icons: Dictionary = {}

const DAMAGE_TYPE_NAMES := {
	0: "Shell",
	1: "Torpedo",
	2: "Fire",
	3: "Flood",
	4: "Secondary",
}

const FONT_SIZE := 14

@onready var entries_container: VBoxContainer = $Entries


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _get_team_color(team: int, local_team_id: int) -> Color:
	if team == local_team_id:
		return FRIENDLY_COLOR
	return ENEMY_COLOR


func _get_damage_icon(damage_type: int) -> Texture2D:
	if not _damage_type_icons.has(damage_type) and DAMAGE_TYPE_ICON_PATHS.has(damage_type):
		_damage_type_icons[damage_type] = load(DAMAGE_TYPE_ICON_PATHS[damage_type])
	if _damage_type_icons.has(damage_type):
		return _damage_type_icons[damage_type]
	return null


func _get_damage_name(damage_type: int) -> String:
	if DAMAGE_TYPE_NAMES.has(damage_type):
		return DAMAGE_TYPE_NAMES[damage_type]
	return "Unknown"


func add_kill(sinker_name: String, sinker_player_name: String, sinker_team: int, damage_type: int, sunk_name: String, sunk_player_name: String, sunk_team: int, local_team_id: int) -> void:
	# Enforce max entries by removing the oldest (top) entry
	while entries_container.get_child_count() >= MAX_ENTRIES:
		var oldest = entries_container.get_child(0)
		entries_container.remove_child(oldest)
		oldest.queue_free()

	var entry := _create_entry(sinker_name, sinker_player_name, sinker_team, damage_type, sunk_name, sunk_player_name, sunk_team, local_team_id)
	entries_container.add_child(entry)

	# Start the fade-out timer
	_start_fade_timer(entry)


func _make_label(text: String, color: Color, h_align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, expand: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = h_align
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _create_entry(sinker_name: String, sinker_player_name: String, sinker_team: int, damage_type: int, sunk_name: String, sunk_player_name: String, sunk_team: int, local_team_id: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Create semi-transparent dark background style
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.1, 0.75)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_bottom_left = 4
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	panel.add_theme_stylebox_override("panel", style)

	# HBoxContainer with three sections: sinker (left-aligned) | damage (centered) | sunk (right-aligned)
	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 0)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sinker_color := _get_team_color(sinker_team, local_team_id)
	var sunk_color := _get_team_color(sunk_team, local_team_id)
	var icon_texture := _get_damage_icon(damage_type)
	var type_name := _get_damage_name(damage_type)

	var sinker_display := sinker_player_name + " (" + sinker_name + ")" if sinker_player_name != "" else sinker_name
	var sunk_display := sunk_player_name + " (" + sunk_name + ")" if sunk_player_name != "" else sunk_name

	# Sinker label — expands to fill left side, text left-aligned
	var sinker_label := _make_label(sinker_display, sinker_color, HORIZONTAL_ALIGNMENT_LEFT, true)
	hbox.add_child(sinker_label)

	# Damage type icon + label — centered
	var damage_hbox := HBoxContainer.new()
	damage_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	damage_hbox.add_theme_constant_override("separation", 4)
	damage_hbox.alignment = BoxContainer.ALIGNMENT_CENTER

	if icon_texture:
		var icon_rect := TextureRect.new()
		icon_rect.texture = icon_texture
		icon_rect.custom_minimum_size = Vector2(FONT_SIZE, FONT_SIZE)
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		damage_hbox.add_child(icon_rect)

	# var type_label := _make_label(type_name, DAMAGE_TYPE_COLOR, HORIZONTAL_ALIGNMENT_CENTER, false)
	# damage_hbox.add_child(type_label)

	# Add spacing around the damage section
	var spacer_left := _make_label("  ", DAMAGE_TYPE_COLOR)
	var spacer_right := _make_label("  ", DAMAGE_TYPE_COLOR)
	hbox.add_child(spacer_left)
	hbox.add_child(damage_hbox)
	hbox.add_child(spacer_right)

	# Sunk label — expands to fill right side, text right-aligned
	var sunk_label := _make_label(sunk_display, sunk_color, HORIZONTAL_ALIGNMENT_RIGHT, true)
	hbox.add_child(sunk_label)

	panel.add_child(hbox)

	return panel


func _start_fade_timer(entry: PanelContainer) -> void:
	# Wait for the display duration, then fade out
	var timer := get_tree().create_timer(DISPLAY_DURATION)
	timer.timeout.connect(_fade_out_entry.bind(entry))


func _fade_out_entry(entry: PanelContainer) -> void:
	if not is_instance_valid(entry) or entry.is_queued_for_deletion():
		return

	var tween := create_tween()
	tween.tween_property(entry, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_callback(entry.queue_free)
