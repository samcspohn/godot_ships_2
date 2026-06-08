extends Skill

## Light Weight Brawler — DD and CA only, Tier 4.
## Light hulls fight best up close — brawling rewards boldness.
##
## While detected (visible_to_enemy): main gun reload -10%, all secondary reload -10%.
## When aim point is within half main gun range: main gun spread -10%.
## Both bonuses are conditional and re-baked when their state changes.

var _reload_active: bool = false
var _spread_active: bool = false

var _reload_mod: float = 1.0
var _spread_mod: float = 1.0

const RELOAD_MOD: float = 0.9
const SPREAD_MOD: float = 0.9

func _init() -> void:
	skill_id = "lwb"
	name = "Light Weight Brawler"
	tier = 4
	cost = 4
	allowed_classes = [Ship.ShipClass.DD, Ship.ShipClass.CA]
	flavor_text = "Light hulls fight best up close — brawling rewards boldness."
	tooltip_stats = [
		{"stat": "Main/Secondary Reload (while detected)", "value": fmt_mult_pct(RELOAD_MOD), "positive": true},
		{"stat": "Main Gun Spread (within half range)",    "value": fmt_mult_pct(SPREAD_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	var main := ship.artillery_controller.params.dynamic_mod as GunParams
	main.reload_time  *= _reload_mod
	main.h_spread     *= _spread_mod
	main.v_spread     *= _spread_mod
	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		(sec.params.dynamic_mod as GunParams).reload_time *= _reload_mod

func _proc(_delta: float) -> void:
	var main_params := _ship.artillery_controller.params.dynamic_mod as GunParams
	var half_range  := main_params._range * 0.5
	var aim_dist    := _ship.artillery_controller.aim_point.distance_to(_ship.global_position)

	var new_reload_active := _ship.visible_to_enemy
	var new_spread_active := aim_dist < half_range

	var state_changed := (new_reload_active != _reload_active) or (new_spread_active != _spread_active)
	_reload_active = new_reload_active
	_spread_active = new_spread_active
	_reload_mod = RELOAD_MOD if _reload_active else 1.0
	_spread_mod = SPREAD_MOD if _spread_active else 1.0
	if state_changed:
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)
