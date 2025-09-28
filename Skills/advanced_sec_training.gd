extends Skill


const max_grouping_bonus = 0.2
const max_spread_bonus = 0.6

var grouping_multiplier: float = 1.0
var spread_multiplier: float = 1.0

func _a(ship: Ship):
	# for sec: SecSubController in ship.secondary_controller.sub_controllers:
	# 	var params: GunParams = sec.params.dynamic_mod as GunParams
	# 	# params.v_grouping_mod = grouping_multiplier
	# 	# params.h_grouping_mod = grouping_multiplier
	# 	# params.base_spread_mod = spread_multiplier
	# 	sec.target_mod.h_grouping = grouping_multiplier
	# 	sec.target_mod.v_grouping = grouping_multiplier
	# 	sec.target_mod.base_spread = spread_multiplier
	# 	params.reload_time *= 0.9

	_ship.secondary_controller.target_mod.h_grouping = grouping_multiplier
	_ship.secondary_controller.target_mod.v_grouping = grouping_multiplier
	_ship.secondary_controller.target_mod.base_spread = spread_multiplier
	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		var params: GunParams = sec.p.dynamic_mod as GunParams
		params.reload_time *= 0.9

var num_enemies = 0
var priority_target: Ship = null
const accuracy_buildup_time = 35.0
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

	for t in _ship.secondary_controller.gun_targets:
		if t != null: # build accuracy if at least one gun has a target
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
		grouping_multiplier = 1.0 + (max_grouping_bonus * accuracy_buildup)
		spread_multiplier = 1.0 - (max_spread_bonus * accuracy_buildup)
		not_shooting_timer = 0.0
	else:
		not_shooting_timer = max(0.0, not_shooting_timer + _delta)
		if not_shooting_timer >= accuracy_decay_time:
			accuracy_buildup = max(0.0, accuracy_buildup - _delta / accuracy_falloff_time)
			grouping_multiplier = 1.0 + (max_grouping_bonus * accuracy_buildup)
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
