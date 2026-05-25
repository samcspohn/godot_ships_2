extends Skill

const sec_reload_mod = 0.9
const sec_spread_mod = 0.9
const sec_grouping_bonus = 0.1
const main_gun_in_range_mod = 0.9
# const sec_range = 1.15

func _init():
	name = "Close Quarters Expertise"
	tier = 2
	cost = 2
	tooltip_stats = [
		{"stat": "Secondary Reload", "value": fmt_mult_pct(sec_reload_mod), "positive": true},
		{"stat": "Secondary Spread", "value": fmt_mult_pct(sec_spread_mod), "positive": true},
		{"stat": "Secondary Grouping", "value": fmt_add(sec_grouping_bonus), "positive": true},
		# {"stat": "Secondary Range", "value": fmt_mult_pct(sec_range), "positive": true},
		{"stat": "Main Gun Dispersion (within secondary range)", "value": fmt_mult_pct(main_gun_in_range_mod), "positive": true},
	]

var main_gun_bonus = 1.0
func _a(ship: Ship):
	var main = ship.artillery_controller.params.dynamic_mod as GunParams
	main.base_spread *= main_gun_bonus

	for sec in ship.secondary_controller.sub_controllers:
		var sec_params = sec.params.dynamic_mod as GunParams
		sec_params.reload_time *= sec_reload_mod
		sec_params.base_spread *= sec_spread_mod
		sec_params.h_grouping += sec_grouping_bonus
		sec_params.v_grouping += sec_grouping_bonus
		# sec_params._range *= sec_range

var enabled = false
func _proc(_delta: float) -> void:

	var max_secondary_range = 0.0
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		if (sec.params.dynamic_mod as GunParams)._range > max_secondary_range:
			max_secondary_range = (sec.params.dynamic_mod as GunParams)._range

	if _ship.artillery_controller.aim_point.distance_to(_ship.global_position) < max_secondary_range:
		if not enabled:
			enabled = true
			main_gun_bonus = main_gun_in_range_mod
			_ship.remove_dynamic_mod(_a)
			_ship.add_dynamic_mod(_a)
	else:
		if enabled:
			enabled = false
			main_gun_bonus = 1.0
			_ship.remove_dynamic_mod(_a)
			_ship.add_dynamic_mod(_a)

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_8(1 if enabled else 0)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray):
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	enabled = reader.get_u8()

func init_ui(container: Control):
	var _ui = load("res://Skills/skill_ui/cq_expert.tscn")
	var ui = _ui.instantiate()
	container.add_child(ui)

func update_ui(container: Control):
	if enabled:
		container.visible = true
	else:
		container.visible = false
