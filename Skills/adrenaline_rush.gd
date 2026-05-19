extends Skill

func _init():
	name = "Adrenaline Rush"
	tier = 3
	cost = 3
	flavor_text = "For every 1% HP lost:"
	tooltip_stats = [
		{"stat": "Main Gun Reload", "value": "-%.1f%%" % modifier, "positive": true},
		{"stat": "Secondary Gun Reload", "value": "-%.1f%%" % modifier, "positive": true},
		{"stat": "Torpedo Reload", "value": "-%.1f%%" % modifier, "positive": true},
	]

var bonus = 1.0
func _a(ship: Ship):
	(ship.artillery_controller.params.p() as GunParams).reload_time *= bonus
	for sc in ship.secondary_controller.sub_controllers:
		sc.params.p().reload_time *= bonus
	if ship.torpedo_controller:
		ship.torpedo_controller.params.p().reload_time *= bonus

const modifier = 0.2
func apply(ship: Ship):
	_ship = ship
	ship.health_controller.hp_changed.connect(func (new_hp: float) -> void:

		var curr_hp = new_hp
		var max_hp = ship.health_controller.max_hp
		var hp_ratio = curr_hp / max_hp
		bonus = 1.0 - (1.0 - hp_ratio) * modifier

		ship.remove_dynamic_mod(_a)
		ship.add_dynamic_mod(_a)
	)
	ship.dynamic_mods.append(_a)

## Directly sets the bonus for port preview, bypassing the hp_changed signal.
func preview_at_hp(hp_ratio: float) -> void:
	bonus = 1.0 - (1.0 - hp_ratio) * modifier
	if _ship != null:
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)

var _preview_hp_pct: float = 100.0

func build_preview_modal(container: Control, on_change: Callable) -> void:
	var label := Label.new()
	label.text = "Simulate HP %"
	container.add_child(label)

	var hbox := HBoxContainer.new()
	container.add_child(hbox)

	var val_label := Label.new()
	val_label.text = "%.0f%%" % _preview_hp_pct
	val_label.custom_minimum_size = Vector2(44, 0)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var slider := HSlider.new()
	slider.min_value = 1.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = _preview_hp_pct
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(slider)
	hbox.add_child(val_label)

	slider.value_changed.connect(func(v: float) -> void:
		_preview_hp_pct = v
		val_label.text = "%.0f%%" % v
		preview_at_hp(v / 100.0)
		on_change.call()
	)

func init_ui(container: Control) -> void:
	var tex: Texture2D = load("res://circle.png")
	var bar := TextureProgressBar.new()
	bar.max_value = 1.0
	bar.value = 1.0
	bar.fill_mode = 4  # clockwise
	bar.texture_under = tex
	bar.texture_progress = tex
	bar.tint_under    = Color(0.30, 0.12, 0.02, 0.30)
	bar.tint_progress = Color(1.00, 0.50, 0.10, 0.85)
	var desired_size := 30.0
	var texture_size := 256.0
	var s := desired_size / texture_size
	bar.scale = Vector2(s, s)
	container.custom_minimum_size = Vector2(desired_size, desired_size)
	container.size = Vector2(desired_size, desired_size)
	container.add_child(bar)

func update_ui(container: Control) -> void:
	container.visible = bonus < 1.0

func init_hover(container: Control, ht) -> void:
	ht.attach(container, func() -> String:
		var pct: float = (1.0 - bonus) * 100.0
		return "Adrenaline Rush\nReload Bonus: -%.1f%%" % pct
	)

func to_bytes() -> PackedByteArray:
	var writer := StreamPeerBuffer.new()
	writer.put_float(bonus)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	var reader := StreamPeerBuffer.new()
	reader.data_array = data
	bonus = reader.get_float()
