extends Control

class_name StatCounter

@onready var background: Panel = $Background
@onready var type_label: Label = $Container/TypeLabel
@onready var count_label: Label = $Container/CountLabel

var counter_type: String = ""
var current_count: int = 0
var config: Dictionary = {}


func _ready() -> void:
	# The Background Panel and Container Control both cover the full rect with
	# the default MOUSE_FILTER_STOP, which makes one of them the picked control
	# under the cursor. Godot only fires mouse_entered on the picked control,
	# so without this the StatCounter root would never receive hover signals
	# (HoverTooltip.attach_content() relies on those). Flip the children to
	# IGNORE so the StatCounter itself becomes the picked control.
	if background:
		background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var container := get_node_or_null("Container") as Control
	if container:
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE


func setup(counter_config: Dictionary) -> void:
	"""Configure this counter with the given settings"""
	config = counter_config
	counter_type = config.get("type", "")

	if type_label:
		type_label.text = config.get("display_name", "???")
		if config.has("label_color"):
			type_label.add_theme_color_override("font_color", config.label_color)
		if config.has("font_size"):
			type_label.add_theme_font_size_override("font_size", config.font_size)

	if background and config.has("bg_color"):
		var style = StyleBoxFlat.new()
		style.bg_color = config.bg_color
		style.corner_radius_top_left = 4
		style.corner_radius_top_right = 4
		style.corner_radius_bottom_right = 4
		style.corner_radius_bottom_left = 4
		background.add_theme_stylebox_override("panel", style)

	if config.has("min_size"):
		custom_minimum_size = config.min_size
		size = config.min_size

	update_count(0)


func update_count(count: int) -> void:
	"""Update the displayed count"""
	current_count = count
	if count_label:
		count_label.text = str(count)


func increment(amount: int = 1) -> void:
	"""Increment the count by specified amount"""
	update_count(current_count + amount)


func reset() -> void:
	"""Reset the count to zero"""
	update_count(0)


func get_count() -> int:
	return current_count


func get_type() -> String:
	return counter_type
