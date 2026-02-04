extends Control

class_name HitCounter

@onready var background: Panel = $Background
@onready var type_label: Label = $Container/TypeLabel
@onready var count_label: Label = $Container/CountLabel

var hit_type: String = ""
var current_count: int = 0


func setup(config: Dictionary) -> void:
	"""Configure this counter with the given settings"""
	hit_type = config.get("type", "")

	if type_label:
		type_label.text = config.get("display_name", "???")
		if config.has("label_color"):
			type_label.add_theme_color_override("font_color", config.label_color)

	if background and config.has("bg_color"):
		var style = StyleBoxFlat.new()
		style.bg_color = config.bg_color
		style.corner_radius_top_left = 4
		style.corner_radius_top_right = 4
		style.corner_radius_bottom_right = 4
		style.corner_radius_bottom_left = 4
		background.add_theme_stylebox_override("panel", style)

	update_count(0)


func update_count(count: int) -> void:
	"""Update the displayed count"""
	current_count = count
	if count_label:
		count_label.text = str(count)


func increment() -> void:
	"""Increment the count by 1"""
	update_count(current_count + 1)


func get_count() -> int:
	return current_count
