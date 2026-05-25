extends Skill

## Last Gasp Tubes — DD / CA.
## Below 25 % HP the torpedo crews redline the tubes, granting a significant
## reload bonus. An _active flag keeps the modifier out of _a until the
## threshold is crossed; the hp_changed signal flips it and re-bakes the mod.

const HP_THRESHOLD: float = 0.25
const RELOAD_MOD: float = 0.70

func _init() -> void:
	name = "Last Gasp Tubes"
	tier = 3
	cost = 3
	allowed_classes = [Ship.ShipClass.DD, Ship.ShipClass.CA]
	flavor_text = "Below quarter health, the torpedo crews push the tubes to their limits."
	tooltip_stats = [
		{"stat": "HP Threshold",    "value": "< %.0f%%" % (HP_THRESHOLD * 100)},
		{"stat": "Torpedo Reload",  "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
	]

var _active: bool = false

func _a(ship: Ship) -> void:
	if ship.torpedo_controller == null:
		return
	if _active:
		(ship.torpedo_controller.params.dynamic_mod as TorpedoLauncherParams).reload_time *= RELOAD_MOD

func _on_hp_changed(new_hp: float) -> void:
	# hp_changed emits raw _current_hp (no mult); compare against raw _max_hp.
	var hp_ratio: float = new_hp / _ship.health_controller._max_hp
	var should_be_active: bool = hp_ratio < HP_THRESHOLD
	if should_be_active == _active:
		return
	_active = should_be_active
	_ship.remove_dynamic_mod(_a)
	_ship.add_dynamic_mod(_a)

func apply(ship: Ship) -> void:
	_ship = ship
	_active = ship.health_controller._current_hp / ship.health_controller._max_hp < HP_THRESHOLD
	ship.health_controller.hp_changed.connect(_on_hp_changed)
	ship.add_dynamic_mod(_a)

func remove(ship: Ship) -> void:
	if ship.health_controller.hp_changed.is_connected(_on_hp_changed):
		ship.health_controller.hp_changed.disconnect(_on_hp_changed)
	ship.remove_dynamic_mod(_a)
