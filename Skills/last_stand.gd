extends Skill

## Last Stand — BB / CA, Tier 3.
## Below 30% HP: +25% torpedo_protection (additive), fire and flood DPS ×0.80.

const HP_THRESHOLD    := 0.30
const TORP_PROT_BONUS := 0.25
const FIRE_MOD        := 0.80
const FLOOD_MOD       := 0.80

var _active := false
var _hp_changed_cb: Callable

func _init() -> void:
	name = "Last Stand"
	tier = 3
	cost = 3
	allowed_classes = [Ship.ShipClass.BB, Ship.ShipClass.CA]
	flavor_text = "When the hull is failing, every second counts."
	tooltip_stats = [
		{"stat": "HP Threshold",       "value": "< 30%"},
		{"stat": "Torpedo Protection", "value": "+%.0f%%" % (TORP_PROT_BONUS * 100.0), "positive": true},
		{"stat": "Fire DPS",           "value": fmt_mult_pct(FIRE_MOD),  "positive": true},
		{"stat": "Flood DPS",          "value": fmt_mult_pct(FLOOD_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	if not _active:
		return
	(ship.health_controller.params.dynamic_mod as HPParams).torpedo_protection        += TORP_PROT_BONUS
	(ship.fire_manager.fparams.dynamic_mod   as FireParams).dmg_rate                  *= FIRE_MOD
	(ship.flood_manager.params.dynamic_mod   as FloodParams).dmg_rate                 *= FLOOD_MOD

func apply(ship: Ship) -> void:
	_ship = ship
	_hp_changed_cb = func(new_hp: float) -> void:
		var ratio        := new_hp / _ship.health_controller._max_hp
		var should_active := ratio < HP_THRESHOLD
		if should_active != _active:
			_active = should_active
			_ship.remove_dynamic_mod(_a)
			_ship.add_dynamic_mod(_a)
	ship.health_controller.hp_changed.connect(_hp_changed_cb)
	ship.dynamic_mods.append(_a)

func remove(ship: Ship) -> void:
	if _hp_changed_cb.is_valid() and ship.health_controller.hp_changed.is_connected(_hp_changed_cb):
		ship.health_controller.hp_changed.disconnect(_hp_changed_cb)
	ship.remove_dynamic_mod(_a)
