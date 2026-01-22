extends Skill

var bonus = 1.0
func _a(ship: Ship):
	(ship.artillery_controller.params.p() as GunParams).reload_time *= bonus
	for sc in ship.secondary_controller.sub_controllers:
		sc.params.p().reload_time *= bonus
	if ship.torpedo_controller:
		ship.torpedo_controller.params.p().reload_time *= bonus

func apply(ship: Ship):
	_ship = ship
	ship.health_controller.hp_changed.connect(func (new_hp: float) -> void:

		var curr_hp = new_hp
		var max_hp = ship.health_controller.max_hp
		var hp_ratio = curr_hp / max_hp
		const modifier = 0.2
		bonus = 1.0 - (1.0 - hp_ratio) * modifier

		ship.remove_dynamic_mod(_a)
		ship.add_dynamic_mod(_a)
	)
	ship.dynamic_mods.append(_a)
