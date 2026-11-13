extends Skill

## Fire Prevention — all classes, Tier 4.
## Harder to ignite, less fire damage, shorter burn duration.

const BUILDUP_MOD: float = 1.10   # +10% fire resistance (harder to ignite)
const DMG_MOD:     float = 0.9   # -10% fire damage rate
const DUR_MOD:     float = 0.9   # -10% fire duration
# const REDUCTION_RATE_MOD: float = 1.2   # +20% fire reduction block rate
# const REDUCTION_BLOCK_MOD: float = 0.20  # -20% fire reduction block duration

const DC_COOLDOWN_PER_FIRE: float = 0.9  # -10% DC cooldown per active fire

func _init() -> void:
	skill_id = "fp"
	name = "Fire Prevention"
	tier = 4
	cost = 4
	flavor_text = "Fire-retardant coatings and drilled damage-control crews."
	tooltip_stats = [
		{"stat": "Fire Resistance",      "value": fmt_mult_pct(BUILDUP_MOD), "positive": true},
		{"stat": "Fire Damage Rate",     "value": fmt_mult_pct(DMG_MOD),     "positive": true},
		{"stat": "Fire Duration",        "value": fmt_mult_pct(DUR_MOD),     "positive": true},
		# {"stat": "Fire Reduction Block Rate", "value": fmt_mult_pct(REDUCTION_BLOCK_MOD), "positive": true},
		# {"stat": "Fire Reduction Rate", "value": fmt_mult_pct(REDUCTION_RATE_MOD), "positive": true},
	]

var curr_fires := 0
func _a(ship: Ship) -> void:
	_ship = ship
	# (ship.fire_manager.rparams.dynamic_mod as ResistanceParams).max_buildup *= BUILDUP_MOD
	(ship.fire_manager.fparams.dynamic_mod as DOTParams).dmg_rate          *= DMG_MOD
	(ship.fire_manager.fparams.dynamic_mod as DOTParams).dur               *= DUR_MOD


	for consumable in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
			(consumable.dynamic_mod as DamageControl).cooldown_time *= pow(DC_COOLDOWN_PER_FIRE, curr_fires)

	# var fire_manager = ship.fire_manager
	# if fire_manager.fires.size() == 4:
	# 	fire_manager.fires[1].position = (fire_manager.fires[1].position + fire_manager.fires[2].position) / 2.0
	# 	fire_manager.fires.remove_at(2)
	# 	_ship.rpc_fire_prevention_setup.rpc()

	# (ship.fire_manager.rparams.dynamic_mod as ResistanceParams).reduction_block_rate *= REDUCTION_BLOCK_MOD
	# (ship.fire_manager.rparams.dynamic_mod as ResistanceParams).buildup_reduction_rate *= REDUCTION_RATE_MOD


func _proc(_delta: float) -> void:
	var fires = _ship.fire_manager.get_active_fires()
	if curr_fires != fires:
		curr_fires = fires
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)
# func from_bytes(data: PackedByteArray):
# 	if _ship == null:
# 		#print("Fire Prevention: no ship assigned")
# 		return
# 	#print("Fire Prevention: setting up single superstructure fire")
# 	var fire_manager = _ship.fire_manager
# 	if fire_manager.fires.size() == 4:
# 		fire_manager.fires[1].position = (fire_manager.fires[1].position + fire_manager.fires[2].position) / 2.0
# 		fire_manager.fires.remove_at(2)

# @rpc("any_peer", "reliable")
# func rpc_fire_prevention_setup() -> void:
# 	if _ship == null:
# 		#print("Fire Prevention: no ship assigned")
# 		return
# 	#print("Fire Prevention: setting up single superstructure fire")
# 	var fire_manager = _ship.fire_manager
# 	if fire_manager.fires.size() == 4:
# 		fire_manager.fires[1].position = (fire_manager.fires[1].position + fire_manager.fires[2].position) / 2.0
# 		fire_manager.fires.remove_at(2)
