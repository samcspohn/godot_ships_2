extends Skill

## Juggernaut — Ultimate tier, all classes (exclusive group "ultimate").
## The more damage the ship has taken, the harder it fights back:
##   • Passive HP regeneration that scales with missing HP.
##   • Fire and flood DoT resistance that scales with missing HP.
##
## _a bakes the fire/flood resistance based on the live HP ratio every time
## the mod layer is refreshed. _proc heals every physics tick and re-bakes
## the mod layer only when the HP-lost percentage drifts by ≥ 0.5 %.

func _init() -> void:
	name = "Juggernaut"
	tier = 5
	cost = 0
	exclusive_group = "ultimate"
	flavor_text = "The more they break it, the harder it fights back."
	tooltip_stats = [
		{"stat": "HP Regen (per 1% HP lost)",   "value": "+0.015% max HP/s", "positive": true},
		{"stat": "Fire DPS",   "value": "-10%", "positive": true},
		{"stat": "Flood DPS",  "value": "-10%", "positive": true},
	]

var _cached_hp_lost_pct: float = 0.0

func _a(ship: Ship) -> void:
	var max_hp:     float = ship.health_controller.max_hp
	var current_hp: float = ship.health_controller.current_hp
	var hp_lost_pct: float = clamp((1.0 - current_hp / max_hp) * 100.0, 0.0, 100.0)

	# var resist_mod: float = max(0.90, 1.0 - 0.001 * hp_lost_pct)
	(ship.fire_manager.fparams.dynamic_mod as FireParams).dmg_rate   *= 0.9
	(ship.flood_manager.params.dynamic_mod as FloodParams).dmg_rate  *= 0.9

func apply(ship: Ship) -> void:
	_ship = ship
	var max_hp:     float = ship.health_controller.max_hp
	var current_hp: float = ship.health_controller.current_hp
	_cached_hp_lost_pct = clamp((1.0 - current_hp / max_hp) * 100.0, 0.0, 100.0)
	ship.add_dynamic_mod(_a)

func _proc(delta: float) -> void:
	var sec_tic: bool = Engine.get_physics_frames() % Engine.physics_ticks_per_second == 0
	if !sec_tic:
		return
	var max_hp:     float = _ship.health_controller.max_hp
	var current_hp: float = _ship.health_controller.current_hp
	var hp_lost_pct: float = clamp((1.0 - current_hp / max_hp), 0.0, 1.0)

	# Passive regen maxing out at .15% per second at 0 hp
	# regen per hp lost: 0.0015% max HP/s, so at 100% hp lost you get .15% max HP/s regen.
	_ship.health_controller.heal(max_hp * 0.0015 * hp_lost_pct * 1.0)

	# Re-bake the resistance mod only when HP loss has shifted enough.
	if abs(hp_lost_pct - _cached_hp_lost_pct) >= 0.5:
		_cached_hp_lost_pct = hp_lost_pct
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)
