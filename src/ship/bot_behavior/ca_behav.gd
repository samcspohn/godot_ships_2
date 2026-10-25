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
	if not would_fire_guns():
		_ship.artillery_controller.set_aim_input(aim_pos)
		return
	super.engage_target(target)

func would_fire_guns() -> bool:
	return can_fire_guns() and not _suppress_guns and super()



## Whether the hull sits on the cover station it is holding. Shared with
## CVBehavior, which runs its own decision tree over the same skills.
func _sync_cover_debug(_ctx: SkillContext) -> void:
	var c: SkillCover = _skill_fight.cover if _fighting(SkillFight.Mode.COVER) else _skill_disengage.cover()
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
	# Good odds release the cover, unless what it faces has yet to be seen: then wait for it.
	if not _fighting(SkillFight.Mode.COVER) or not _skill_fight.cover.has_station() \
			or (sit.threat < _doc().cover_release_threat and not priority_dark()):
		return null
	var p := SkillFight.advance_cover_params(ctx) if _skill_fight.cover.mode == SkillCover.Mode.OFFENSE \
		else SkillFight.cover_params(ctx, _skill_fight.cover.mode)
	var held := _run_skill(&"Fight", ctx, p.merged({"only": SkillFight.Mode.COVER}))
	if held != null:
		sit["arm"] = &"engaged"
	return held

## The engaged arm: hidden island cover with a target in reach first.
func _select_engaged_skill(ctx: SkillContext, _sit: Dictionary) -> NavIntent:
	return _fight(ctx, {"prefer_cover": true})

func _apply_gun_policy(ctx: SkillContext, sit: Dictionary) -> void:
	# Only when something is actually spotted, matching the arms this used to sit
	# in. Result unused: the call is kept for its side effect, deducing a
	# concealed spotter from unexplained bloom.
	if sit.has_spotted:
		_probe_concealment(ctx.server)

func try_use_consumable():
	super.try_use_consumable()

## Opening: hidden cover with the priority's spawn reference in reach.
func _opening(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	return _run_skill(&"Fight", ctx, SkillFight.advance_cover_params(ctx).merged({"only": SkillFight.Mode.COVER}))
