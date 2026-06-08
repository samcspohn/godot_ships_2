extends Skill

## Outboard Engines — DD / CA.
## While above 75 % HP the engines push to an overclocked maximum speed.
## Dropping below the threshold cuts the bonus immediately via the hp_changed
## signal; the _active flag gates the modifier in _a.

const SPEED_MOD: float = 1.05

const HP_THRESHOLD: float = 0.75

func _init() -> void:
	name = "Outboard Engines"
	tier = 2
	cost = 2
	allowed_classes = [Ship.ShipClass.DD, Ship.ShipClass.CA]
	flavor_text = "Extra boost when the hull is still intact — speed demon builds."
	tooltip_stats = [
		{"stat": "Max Speed", "value": "%s (above %.0f%% HP)" % [fmt_mult_pct(SPEED_MOD), HP_THRESHOLD * 100], "positive": true},
	]

var _active: bool = false

func _a(ship: Ship) -> void:
	if _active:
		(ship.movement_controller.params.dynamic_mod as MovementParams).max_speed_knots *= SPEED_MOD

func _on_hp_changed(new_hp: float) -> void:
	# hp_changed emits raw _current_hp (no mult); compare against raw _max_hp.
	var hp_ratio: float = new_hp / _ship.health_controller._max_hp
	var should_be_active: bool = hp_ratio > HP_THRESHOLD
	if should_be_active == _active:
		return
	_active = should_be_active
	_ship.remove_dynamic_mod(_a)
	_ship.add_dynamic_mod(_a)

func apply(ship: Ship) -> void:
	_ship = ship
	_active = ship.health_controller._current_hp / ship.health_controller._max_hp > HP_THRESHOLD
	ship.health_controller.hp_changed.connect(_on_hp_changed)
	ship.add_dynamic_mod(_a)

func remove(ship: Ship) -> void:
	if ship.health_controller.hp_changed.is_connected(_on_hp_changed):
		ship.health_controller.hp_changed.disconnect(_on_hp_changed)
	ship.remove_dynamic_mod(_a)
