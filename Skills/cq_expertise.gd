extends Skill

var main_gun_bonus = 1.0
func _a(ship: Ship):
	var main = ship.artillery_controller.params.dynamic_mod as GunParams
	main.base_spread *= main_gun_bonus

	for sec in ship.secondary_controller.sub_controllers:
		var sec_params = sec.p.dynamic_mod as GunParams
		sec_params.reload_time *= 0.9

var enabled = false
func _proc(_delta: float) -> void:

	var max_secondary_range = 0.0
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		if (sec.p.dynamic_mod as GunParams)._range > max_secondary_range:
			max_secondary_range = (sec.p.dynamic_mod as GunParams)._range
	
	if _ship.artillery_controller.aim_point.distance_to(_ship.global_position) < max_secondary_range:
		if not enabled:
			enabled = true
			main_gun_bonus = 0.9
			_ship.remove_dynamic_mod(_a)
			_ship.add_dynamic_mod(_a)
	else:
		if enabled:
			enabled = false
			main_gun_bonus = 1.0
			_ship.remove_dynamic_mod(_a)
			_ship.add_dynamic_mod(_a)
