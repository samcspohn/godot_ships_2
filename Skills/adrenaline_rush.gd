extends Skill

var bonus = 1.0
func _a(ship: Ship):
	(ship.artillery_controller.params.params() as GunParams).reload_time *= bonus

func apply(ship: Ship):
	_ship = ship
	ship.get_health_controller().hp_changed.connect(func (new_hp: float) -> void:

		if ship != _ship:
			print("Adrenaline Rush connected to wrong ship!")
			return
		var curr_hp = new_hp
		var max_hp = ship.health_controller.max_hp
		var hp_ratio = curr_hp / max_hp
		const modifier = 0.2
		bonus = 1.0 - (1.0 - hp_ratio) * modifier

		ship.remove_dynamic_mod(_a)
		ship.add_dynamic_mod(_a)
	)
	ship.add_dynamic_mod(_a)
