extends Skill

func _init():
	name = "Adrenaline Rush"
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
