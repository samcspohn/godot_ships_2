extends VBoxContainer
class_name AccordionPanel

## Reusable accordion section: a header button that toggles a content
## VBoxContainer's visibility. Add stat rows by calling add_content() with
## any Control, or use add_stat_row()/clear_stats() for typical label rows.

signal toggled(expanded: bool)

@export var title: String = "":
	set(value):
		title = value
		if _header:
			_header.text = _build_header_text()

@export var expanded: bool = true:
	set(value):
		expanded = value
		if _content:
			_content.visible = expanded
		if _header:
			_header.text = _build_header_text()

var _header: Button
var _content: VBoxContainer
var _rating_row: HBoxContainer
var _rating_bar: ProgressBar
var _rating_label: Label

func _ready() -> void:
	add_theme_constant_override("separation", 0)
	_header = Button.new()
	_header.toggle_mode = true
	_header.button_pressed = expanded
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.focus_mode = Control.FOCUS_NONE
	_header.text = _build_header_text()
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.toggled.connect(_on_header_toggled)
	add_child(_header)

	# Always-visible rating row (hidden until set_rating() is called).
	_rating_row = HBoxContainer.new()
	_rating_row.add_theme_constant_override("separation", 6)
	_rating_row.visible = false
	_rating_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rating_margin := MarginContainer.new()
	rating_margin.add_theme_constant_override("margin_left", 8)
	rating_margin.add_theme_constant_override("margin_right", 8)
	rating_margin.add_theme_constant_override("margin_top", 1)
	rating_margin.add_theme_constant_override("margin_bottom", 1)
	rating_margin.add_child(_rating_row)
	add_child(rating_margin)

	_rating_bar = ProgressBar.new()
	_rating_bar.min_value = 0.0
	_rating_bar.max_value = 100.0
	_rating_bar.show_percentage = false
	_rating_bar.custom_minimum_size = Vector2(0, 8)
	_rating_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rating_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rating_row.add_child(_rating_bar)

	_rating_label = Label.new()
	_rating_label.custom_minimum_size = Vector2(56, 0)
	_rating_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_rating_row.add_child(_rating_label)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 2)
	_content.visible = expanded
	# Indent content slightly from the header
	var indent_margin := MarginContainer.new()
	indent_margin.add_theme_constant_override("margin_left", 8)
	indent_margin.add_theme_constant_override("margin_top", 2)
	indent_margin.add_theme_constant_override("margin_bottom", 4)
	indent_margin.add_child(_content)
	add_child(indent_margin)

func _on_header_toggled(pressed: bool) -> void:
	expanded = pressed
	_content.visible = expanded
	_header.text = _build_header_text()
	toggled.emit(expanded)

func _build_header_text() -> String:
	var arrow := "▾" if expanded else "▸"
	return "%s  %s" % [arrow, title]

## Show an always-visible "effectiveness" rating below the header. The
## progress bar is clamped to 100, but the numeric label shows the raw value
## so exceptional ships can be flagged. Call clear_rating() to hide it.
func set_rating(value: float, max_display: float = 100.0) -> void:
	if _rating_bar == null:
		return
	_rating_row.visible = true
	_rating_bar.max_value = max_display
	_rating_bar.value = clampf(value, 0.0, max_display)
	_rating_label.text = "%d / %d" % [int(round(value)), int(max_display)]
	# Color the bar from red (low) → yellow → green based on the raw value.
	var ratio := clampf(value / max_display, 0.0, 1.0)
	var c := Color(1.0 - ratio, ratio, 0.2).lerp(Color(0.4, 1.0, 0.4), max(ratio - 0.5, 0.0))
	_rating_bar.modulate = Color(1, 1, 1)
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.corner_radius_top_left = 2
	sb.corner_radius_top_right = 2
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	_rating_bar.add_theme_stylebox_override("fill", sb)

func clear_rating() -> void:
	if _rating_row:
		_rating_row.visible = false

## Removes all child rows from the content area.
func clear_stats() -> void:
	if _content == null:
		return
	for c in _content.get_children():
		c.queue_free()

## Adds an arbitrary Control to the content area.
func add_content(control: Control) -> void:
	_content.add_child(control)

## Convenience: add a "label : value" row. Highlights modified values when
## `base_value` is provided and differs from `value`.
func add_stat_row(label: String, value: String, modified: bool = false) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_lbl := Label.new()
	name_lbl.text = label
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.text = value
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if modified:
		val_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	row.add_child(val_lbl)

	_content.add_child(row)

## Add a thin section divider/sub-heading line inside the accordion.
func add_subheader(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	_content.add_child(lbl)

## Add a horizontal separator inside the content.
func add_separator() -> void:
	_content.add_child(HSeparator.new())
