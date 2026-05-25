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
var hp_regen_per_sec: float = 0.0

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
	var sec_tic: bool = Engine.get_physics_frames() % Engine.physics_ticks_per_second == int(Engine.physics_ticks_per_second / 2.0)
	if !sec_tic:
		return
	var max_hp:     float = _ship.health_controller.max_hp
	var current_hp: float = _ship.health_controller.current_hp
	var hp_lost_pct: float = clamp((1.0 - current_hp / max_hp), 0.0, 1.0)

	# Passive regen maxing out at .15% per second at 0 hp
	# regen per hp lost: 0.0015% max HP/s, so at 100% hp lost you get .15% max HP/s regen.
	hp_regen_per_sec = max_hp * 0.0015 * hp_lost_pct
	_ship.health_controller.heal(hp_regen_per_sec)

	# Re-bake the resistance mod only when HP loss has shifted enough.
	if abs(hp_lost_pct - _cached_hp_lost_pct) >= 0.5:
		_cached_hp_lost_pct = hp_lost_pct
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)

func init_ui(container: Control) -> void:
	var tex: Texture2D = load("res://circle.png")
	var bar := TextureProgressBar.new()
	bar.max_value = 1.0
	bar.value = 1.0
	bar.fill_mode = 4  # clockwise
	bar.texture_under = tex
	bar.texture_progress = tex
	bar.tint_under    = Color(0.05, 0.25, 0.05, 0.30)
	bar.tint_progress = Color(0.20, 0.85, 0.35, 0.85)
	var desired_size := 30.0
	var texture_size := 256.0
	var s := desired_size / texture_size
	bar.scale = Vector2(s, s)
	container.custom_minimum_size = Vector2(desired_size, desired_size)
	container.size = Vector2(desired_size, desired_size)
	container.add_child(bar)

func update_ui(container: Control) -> void:
	container.visible = hp_regen_per_sec > 0.0

func init_hover(container: Control, ht) -> void:
	ht.attach(container, func() -> String:
		return "Juggernaut\nHP Regen: +%.1f HP/s" % hp_regen_per_sec
	)

func to_bytes() -> PackedByteArray:
	var writer := StreamPeerBuffer.new()
	writer.put_float(_cached_hp_lost_pct)
	writer.put_float(hp_regen_per_sec)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	var reader := StreamPeerBuffer.new()
	reader.data_array = data
	_cached_hp_lost_pct = reader.get_float()
	hp_regen_per_sec = reader.get_float()
