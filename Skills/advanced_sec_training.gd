extends Skill


const max_grouping_bonus = 0.3
const max_spread_bonus = 0.6

var grouping_multiplier: float = 0.0
var spread_multiplier: float = 1.0

func _init():
	name = "Advanced Secondary Training"
	description = "Increases secondary artillery accuracy the longer they fire on a target, up to 60% grouping and 30% spread improvement. Accuracy resets after not firing for a short time."

func _a(ship: Ship):
	# print("grouping_multiplier: ", grouping_multiplier, " spread_multiplier: ", spread_multiplier)
	_ship.secondary_controller.target_mod.dynamic_mod.h_grouping += grouping_multiplier
	_ship.secondary_controller.target_mod.dynamic_mod.v_grouping += grouping_multiplier
	_ship.secondary_controller.target_mod.dynamic_mod.base_spread *= spread_multiplier
	_ship.secondary_controller.priority_target_dispersion.period = 5.2
	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		var params: GunParams = sec.params.dynamic_mod as GunParams
		params.reload_time *= 0.9

var num_enemies = 0
var priority_target: Ship = null
const accuracy_buildup_time = 40.0
const accuracy_falloff_time = 50.0
const accuracy_decay_time = 10.0
var accuracy_buildup: float = 0.0
var not_shooting_timer: float = 0.0
func _proc(_delta: float) -> void:
	# var server: GameServer = _ship.get_tree().root.get_node_or_null("/root/Server")
	# if not server:
	# 	return
	# var enemies = server.get_valid_targets(_ship.team.team_id)
	# var max_secondary_range = 0.0
	var secs_shooting = false
	var priority_target_changed = false
	if _ship.secondary_controller.target != priority_target:
		priority_target = _ship.secondary_controller.target
		priority_target_changed = true

	var gun_targets = _ship.secondary_controller.gun_targets
	for t in gun_targets.keys():
		if gun_targets[t] != null: # build accuracy if at least one gun has a target
			secs_shooting = true
			break
	# for sec: SecSubController in _ship.secondary_controller.sub_controllers:

	# 	# check if any guns are shooting
	# 	for t in sec.gun_targets:
	# 		if t != null: # and t == priority_target: # build accuracy if at least one gun has a target
	# 			secs_shooting = true
	# 			break
	var curr_accuracy_buildup = accuracy_buildup
	if priority_target_changed:
		accuracy_buildup = max(0.0, accuracy_buildup - 0.15) # small accuracy penalty for switching targets

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

	# else:
	# 	accuracy_timer = max(0.0, accuracy_timer - _delta)
	# 	grouping_multiplier = max(1.0, grouping_multiplier * 0.95)
	# 	spread_multiplier = min(1.0, spread_multiplier * 1.05)

		# if (sec.params.params() as GunParams)._range > max_secondary_range:
		# 	max_secondary_range = (sec.params.params() as GunParams)._range

	# filter out enemies that are out of secondary range
	# enemies = enemies.filter(func (enemy) -> bool:
	# 	return _ship.global_position.distance_to(enemy.global_position) < max_secondary_range
	# )
	# if enemies.size() != num_enemies:
	# 	num_enemies = enemies.size()
	# 	if num_enemies > 0:
	# 		grouping_multiplier = 1.2
	# 		spread_multiplier = 0.4
	# 	else:
	# 		grouping_multiplier = 1.0
	# 		spread_multiplier = 1.0
	# 	_ship.remove_dynamic_mod(_a)
	# 	_ship.add_dynamic_mod(_a)

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
	# var color_rect = ColorRect.new()
	#color_rect.rect_size = Vector2(40, 40)
	# color_rect.color = Color(1, 0, 0)
	# color_rect.custom_minimum_size = Vector2(30, 30)
	# control.custom_minimum_size = Vector2(30, 30)
	# control.add_child(color_rect)
func update_ui(container: Control):
	var progress = container.get_child(0) as TextureProgressBar
	if accuracy_buildup > 0.0:
		container.visible = true
		progress.value = accuracy_buildup
	else:
		container.visible = false

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	# writer.put_var(skill_id)
	writer.put_float(accuracy_buildup)
	# writer.put_var(name)
	# writer.put_var(description)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray):
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	# var skill_id = reader.get_var()
	accuracy_buildup = reader.get_float()
	# return AdvancedSecTraining(skill_id, accuracy_buildup)
