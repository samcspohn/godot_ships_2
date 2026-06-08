extends Skill

## Juggernaut — Ultimate tier, all classes (exclusive group "ultimate").
## The more damage the ship has taken, the harder it fights back:
##   • Passive HP regeneration that scales with missing HP.
##   • Fire and flood DoT resistance that scales with missing HP.
##
## _a bakes the fire/flood resistance based on the live HP ratio every time
## the mod layer is refreshed. _proc heals every physics tick and re-bakes
## the mod layer only when the HP-lost percentage drifts by ≥ 0.5 %.

const REGEN_COEFF: float = 0.002
const FIRE_MOD: float = 0.9
const FLOOD_MOD: float = 0.9
const REGEN_TIMEOUT: float = 30.0
const REBAKE_THRESHOLD: float = 0.005
const DC_RP_DUR_MOD: float = 0.8

var _cached_hp_lost_pct: float = 0.0
var hp_regen_per_sec: float = 0.0
var last_potential_dmg: float = 0.0
var last_potential_dmg_time: float = 0.0

func _init() -> void:
	name = "Juggernaut"
	tier = 5
	cost = 0
	exclusive_group = "ultimate"
	flavor_text = "The more they break it, the harder it fights back. Regen pauses after %.0fs without taking potential damage." % REGEN_TIMEOUT
	tooltip_stats = [
		{"stat": "HP Regen (per 1% HP lost)", "value": "+%.1f%% max HP/s" % (REGEN_COEFF * 100), "positive": true},
		{"stat": "Fire DPS",                  "value": fmt_mult_pct(FIRE_MOD),            "positive": true},
		{"stat": "Flood DPS",                 "value": fmt_mult_pct(FLOOD_MOD),           "positive": true},
		{"stat": "DC/RP Duration",            "value": fmt_mult_pct(DC_RP_DUR_MOD),      "positive": false},
	]

func _a(ship: Ship) -> void:
	(ship.fire_manager.fparams.dynamic_mod as DOTParams).dmg_rate  *= FIRE_MOD
	(ship.flood_manager.dot_params.dynamic_mod as DOTParams).dmg_rate *= FLOOD_MOD
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			var dm := consumable.dynamic_mod as ConsumableItem
			if dm.duration > 0.0:
				dm.duration *= DC_RP_DUR_MOD

func apply(ship: Ship) -> void:
	_ship = ship
	var hp := ship.health_controller
	_cached_hp_lost_pct = clamp(1.0 - hp.current_hp / hp.max_hp, 0.0, 1.0)
	ship.add_dynamic_mod(_a)

func _proc(_delta: float) -> void:
	var sec_tic: bool = Engine.get_physics_frames() % Engine.physics_ticks_per_second == int(Engine.physics_ticks_per_second / 2.0)
	if not sec_tic:
		return

	var curr_potential_dmg: float = _ship.stats.potential_damage
	if curr_potential_dmg != last_potential_dmg:
		last_potential_dmg = curr_potential_dmg
		last_potential_dmg_time = Time.get_ticks_msec() / 1000.0

	if Time.get_ticks_msec() / 1000.0 - last_potential_dmg_time > REGEN_TIMEOUT:
		hp_regen_per_sec = 0.0
		return

	var hp := _ship.health_controller
	var hp_lost_pct: float = clamp(1.0 - hp.current_hp / hp.max_hp, 0.0, 1.0)

	hp_regen_per_sec = hp.max_hp * REGEN_COEFF * hp_lost_pct
	_ship.health_controller.heal(hp_regen_per_sec)

	if abs(hp_lost_pct - _cached_hp_lost_pct) >= REBAKE_THRESHOLD:
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
	var s := desired_size / 256.0
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
