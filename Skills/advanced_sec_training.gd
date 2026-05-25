extends Skill


const max_grouping_bonus = 0.4
const max_spread_bonus = 0.5
const target_switch_penalty = 0.15
const RELOAD_MOD: float = 0.9

var grouping_multiplier: float = 0.0
var spread_multiplier: float = 1.0

func _init():
	skill_id = "ast"
	name = "Advanced Secondary Training"
	tier = 4
	cost = 4
	flavor_text = "Gradually improves secondary accuracy while secondaries shoot at a target."
	tooltip_stats = [
		# {"stat": "Secondary Spread (static)",   "value": "-10%",                                      "positive": true},
		# {"stat": "Secondary Range (static)",    "value": "+5%",                                      "positive": true},
		{"stat": "Secondary Reload (static)",   "value": fmt_mult_pct(RELOAD_MOD),                   "positive": true},
		{"stat": "Secondary Grouping (max)",    "value": "+%.0f%%" % (max_grouping_bonus * 100),       "positive": true},
		{"stat": "Secondary Spread (max buildup)", "value": "-%.0f%%" % (max_spread_bonus * 100),     "positive": true},
		{"stat": "Buildup Time",                "value": "%.0f s" % accuracy_buildup_time},
		{"stat": "Time Before Decay",           "value": "%.0f s" % accuracy_decay_time},
		{"stat": "Decay Time",                  "value": "%.0f s" % accuracy_falloff_time},
		{"stat": "Target Switch Penalty",       "value": "-%.0f%% buildup" % (target_switch_penalty * 100), "positive": false},
	]

func _a(ship: Ship):
	ship.secondary_controller.target_mod.dynamic_mod.h_grouping += grouping_multiplier
	ship.secondary_controller.target_mod.dynamic_mod.v_grouping += grouping_multiplier
	ship.secondary_controller.target_mod.dynamic_mod.base_spread *= spread_multiplier
	# ship.secondary_controller.priority_target_dispersion.period = 5.2
	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		var params: GunParams = sec.params.dynamic_mod as GunParams
		params.reload_time *= RELOAD_MOD
		# params.base_spread *= 0.90

var num_enemies = 0
var priority_target: Ship = null
const accuracy_buildup_time = 40.0
const accuracy_falloff_time = 50.0
const accuracy_decay_time = 10.0
var accuracy_buildup: float = 0.0
var not_shooting_timer: float = 0.0
func _proc(_delta: float) -> void:
	var secs_shooting = false
	var priority_target_changed = false
	if _ship.secondary_controller.target != priority_target:
		priority_target = _ship.secondary_controller.target
		priority_target_changed = true

	var gun_targets = _ship.secondary_controller.gun_targets
	for g in gun_targets.keys():
		if gun_targets[g] != null:
			secs_shooting = true
			break

	var curr_accuracy_buildup = accuracy_buildup
	if priority_target_changed:
		accuracy_buildup = max(0.0, accuracy_buildup - target_switch_penalty)

	if secs_shooting:
		accuracy_buildup = min(1.0, accuracy_buildup + _delta / accuracy_buildup_time)
		grouping_multiplier = (max_grouping_bonus * accuracy_buildup)
		spread_multiplier = 1.0 - (max_spread_bonus * accuracy_buildup)
		not_shooting_timer = 0.0
	else:
		not_shooting_timer = max(0.0, not_shooting_timer + _delta)
		if not_shooting_timer >= accuracy_decay_time:
			accuracy_buildup = max(0.0, accuracy_buildup - _delta / accuracy_falloff_time)
			grouping_multiplier = (max_grouping_bonus * accuracy_buildup)
			spread_multiplier = 1.0 - (max_spread_bonus * accuracy_buildup)

	if curr_accuracy_buildup != accuracy_buildup:
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)

func init_ui(control):
	var ui: PackedScene = load("res://Skills/skill_ui/adv_sec_training.tscn")
	var progress = ui.instantiate()
	var desired_size := 30.0
	var texture_size := 256.0
	var s := desired_size / texture_size
	progress.scale = Vector2(s, s)
	control.custom_minimum_size = Vector2(desired_size, desired_size)
	control.size = Vector2(desired_size, desired_size)
	control.add_child(progress)

func update_ui(container: Control):
	var progress = container.get_child(0) as TextureProgressBar
	if accuracy_buildup > 0.0:
		container.visible = true
		progress.value = accuracy_buildup
	else:
		container.visible = false

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(accuracy_buildup)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray):
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	accuracy_buildup = reader.get_float()
