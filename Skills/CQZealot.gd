extends Skill


func _init():
	name = "CQ Zealot"
	description = "Reduce reload time of secondary and main guns by 10% when at least one enemy is within max secondary range \n
	and reduce reload by 2.5% for every additional enemy. with no enemies within range, main gun reload and spread are increased by 15% and 10% respectively. \n
	main gun range is reduced by 5%."
	# Set icon if you have one
	# icon = preload("res://icons/auto-repair.png")

# buffs
const reload_per_additional_enemy = 0.025
const reload_for_one_enemy = 0.9

# nerfs
const base_range_modifier = 0.95
const base_reload_modifier = 1.15
const base_spread_modifier = 1.1
var reload_modifier = base_reload_modifier
var spread_modifier = base_spread_modifier
func _a(ship: Ship):
	var main = ship.artillery_controller.params.dynamic_mod as GunParams
	main.reload_time *= reload_modifier
	main._range *= base_range_modifier
	main.base_spread *= spread_modifier
	for sec in ship.secondary_controller.sub_controllers:
		var sec_params = sec.params.dynamic_mod as GunParams
		sec_params.reload_time *= reload_modifier


var num_enemies = 0
func _proc(_delta: float) -> void:
	var server: GameServer = _ship.get_tree().root.get_node_or_null("/root/Server")
	if not server:
		return
	var enemies = server.get_valid_targets(_ship.team.team_id)
	var max_secondary_range = 0.0
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		if (sec.params.dynamic_mod as GunParams)._range > max_secondary_range:
			max_secondary_range = (sec.params.dynamic_mod as GunParams)._range

	# filter out enemies that are out of secondary range
	enemies = enemies.filter(func (enemy) -> bool:
		return _ship.global_position.distance_to(enemy.global_position) < max_secondary_range
	)
	if enemies.size() != num_enemies:
		num_enemies = enemies.size()
		if num_enemies == 0:
			reload_modifier = base_reload_modifier
			spread_modifier = base_spread_modifier
		# elif num_enemies == 1:
		# 	reload_modifier = 0.9
		else:
			reload_modifier = pow(1.0 - reload_per_additional_enemy, num_enemies - 1) * reload_for_one_enemy
			spread_modifier = 1.0

		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)

	# var i = 0
	# while i < enemies.size():
	# 	var enemy = enemies[i]
	# 	if _ship.global_position.distance_to(enemy.global_position) >= max_secondary_range:
	# 		enemies.erase(enemy)
	# 	else:
	# 		i += 1

	# # first enemy reduce reload time by 10%
	# if enemies.size() > 0:
	# 	var main = _ship.artillery_controller.params.params() as GunParams
	# 	main.reload_time *= 0.9

	# 	for sec in _ship.secondaries:
	# 		var sec_params = sec.params.params() as GunParams
	# 		sec_params.reload_time *= 0.9

	# # subsequent enemies reduce reload time by 5% each, stacking multiplicatively
	# for n in enemies.size() - 1:
	# 	var main = _ship.artillery_controller.params.params() as GunParams
	# 	main.reload_time *= 0.95

	# 	for sec in _ship.secondaries:
	# 		var sec_params = sec.params.params() as GunParams
	# 		sec_params.reload_time *= 0.95
