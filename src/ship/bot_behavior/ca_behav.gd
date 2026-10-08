extends BotBehavior
class_name CABehavior



# ============================================================================
# WEIGHT CONFIGURATION
# ============================================================================

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 2.0
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 0.3
	return 1.0


func get_positioning_params() -> Dictionary:
	return {
		spread_distance = 2000.0,
		spread_multiplier = 2.0,
	}



func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.3,
	}

# ============================================================================
# AMMO AND AIM
# ============================================================================

func engage_target(target: Ship) -> void:
	# Believed position, so a target that has gone dark is still tracked at its
	# dead-reckoned last-known position instead of its real one
	var aim_pos = contact_aim_point(target)
	if aim_pos == null:
		return
	if not can_fire_guns():
		_ship.artillery_controller.set_aim_input(aim_pos)
		return
	if _suppress_guns:
		_ship.artillery_controller.set_aim_input(aim_pos)
		return
	super.engage_target(target)



## Whether the hull sits on the cover station it is holding. Shared with
## CVBehavior, which runs its own decision tree over the same skills.
func _sync_cover_debug(_ctx: SkillContext) -> void:
	var c: SkillCover = _skill_hold.cover if _holding(SkillHold.Mode.COVER) else _skill_disengage.cover()
	is_in_cover = c.has_station() and _ship.global_position.distance_to(c.station_position()) <= SkillCover.COVER_HOLD_M

# ============================================================================
# NAVINTENT — decision arms specific to the cruiser
# ============================================================================

func doctrine() -> BotDoctrine:
	return BotDoctrine.for_cruiser()

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	wants_stealth = false  # reset each tick; set true below if conditions are met
	wants_to_be_concealed = false
	_suppress_guns = false
	_ensure_safe_dir(ship, server)
	var ctx := SkillContext.create(ship, target, server, self)
	_sync_cover_debug(ctx)
	return _nav_core(ctx)

## Low threat: push, but prefer running down a closer unseen contact over
## crossing the map to fight a distant visible one.
func _select_low_threat_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var near_unspotted := _nearest_unspotted_info(ctx.server)
	if not near_unspotted.is_empty() \
			and near_unspotted.distance < sit.nearest_dist \
			and sit.nearest_dist > sit.gun_range:
		var chase := _run_skill(&"Chase", ctx)
		if chase != null:
			return chase
	return _fight(ctx)

# ## Cover navigates to a hide position, so its heading belongs to the navigator.
# ## Every other close-arm skill wants a say in where the hull points, and near
# ## terrain it wants the whole say — otherwise the ship routes around an island
# ## showing its broadside the entire way.
# func _shape_close_intent(intent: NavIntent, ctx: SkillContext, _sit: Dictionary) -> void:
# 	if _active_skill_name == &"FindCover":
# 		return
# 	# intent.heading_weight = 0.0
# 	# TODO: improve by checking whether the desired heading points into terrain.
# 	# var turn_radius: float = ctx.ship.movement_controller._p().turning_circle_radius
# 	# if NavigationMapManager.get_distance(ctx.ship.global_position) < turn_radius * 4.0:
# 	# 	intent.heading_weight = 1.0

func _committed_intent(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	if not _holding(SkillHold.Mode.COVER) or not _skill_hold.cover.has_station() \
			or sit.threat < _doc().cover_release_threat:
		return null
	var hold := _hold(ctx, SkillHold.Mode.COVER, _hold_cover_params(_skill_hold.cover.mode, sit))
	if hold != null:
		sit["arm"] = &"engaged"
		wants_stealth = wants_stealth or _skill_hold.cover.wants_concealment()
	return hold

func _hold_cover_params(mode: int, sit: Dictionary) -> Dictionary:
	return {"mode": mode, "pref_range": sit.engagement_range if mode == SkillCover.Mode.OFFENSE else 0.0,
		"max_range": max_engagement_range(_ship) if mode == SkillCover.Mode.OFFENSE else 0.0,
		"fire_en_route": cant_go_dark}

## The engaged arm: hold hidden island cover with a target in reach; without
## one, engage from the band while the odds allow, then get out.
func _select_engaged_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var hold := _hold(ctx, SkillHold.Mode.COVER, _hold_cover_params(SkillCover.Mode.OFFENSE, sit))
	if hold != null:
		wants_stealth = _skill_hold.cover.wants_concealment()
		return hold
	if sit.threat < _doc().engage_max_threat:
		var engage := _fight(ctx)
		if engage != null:
			return engage
	return _disengage(ctx, sit)

func _apply_gun_policy(ctx: SkillContext, sit: Dictionary) -> void:
	# Only when something is actually spotted, matching the arms this used to sit
	# in. Result unused: the call is kept for its side effect, deducing a
	# concealed spotter from unexplained bloom.
	if sit.has_spotted:
		_probe_concealment(ctx.server)

func try_use_consumable():
	super.try_use_consumable()
