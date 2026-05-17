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
