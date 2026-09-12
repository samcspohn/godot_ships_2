extends BotBehavior
class_name BBBehavior




# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.5
		Ship.ShipClass.DD: return 2.0
	return 1.0


func get_positioning_params() -> Dictionary:
	return {
		spread_distance = 3000.0,
		spread_multiplier = 1.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.4,      # Stand off 40% of gun range in front of last known position
	}





# ============================================================================
# NAVINTENT — V4 bot controller interface
# ============================================================================

func doctrine() -> BotDoctrine:
	return BotDoctrine.for_battleship()

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	wants_stealth = false  # BBs push or camp — never route around detection zones
	wants_to_be_concealed = false
	return _nav_core(SkillContext.create(ship, target, server, self))

## The engaged arm: not close aboard, or not detected. A battleship walks a
## threat ladder — flank while it is quiet, camp while it is manageable, get
## behind an island as it builds, and kite once it is bad.
func _select_engaged_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var d := _doc()
	if sit.threat < d.flank_max_threat or sit.nearest_dist > sit.gun_range:
		var flank := _run_skill(&"Flank", ctx)
		if flank != null:
			return flank
		# Flank declined, which it only does with the fight already inside half
		# gun range (SkillFlank.NO_FLANK_RANGE_RATIO).  There is no manoeuvre
		# left to make at that distance, so take the odds this arm was entered
		# on and push; above the push threshold, fall through to the ladder
		# below, which is the same ship deciding it does not like them any more.
		if sit.threat < d.push_threat:
			return _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})

	if sit.threat < d.camp_max_threat and active_shooters_at_me.is_empty():
		var camp := _run_skill(&"Camp", ctx, {"here": true})
		# Probe cover so its team-wide claim bookkeeping stays warm; _finish_nav
		# releases the claim again because Camp is what actually got adopted.
		_skill_cover.execute(ctx, {})
		return camp

	if sit.threat < d.cover_max_threat:
		return _run_skill(&"FindCover", ctx)

	var cover_intent := _skill_cover.execute(ctx, {}, false)
	var cover_usable: bool = cover_intent != null \
		and (_skill_cover.is_cover_on_the_way(ctx)
			or not ctx.ship.is_detected()
			or active_shooters_at_me.is_empty()) \
		and sit.nearest_threat_dist > d.cover_min_threat_dist
	if cover_usable:
		_active_skill_name = &"FindCover"
		return cover_intent
	return _run_skill(&"Kite", ctx)

func _apply_gun_policy(ctx: SkillContext, _sit: Dictionary) -> void:
	# Result deliberately unused: BBs never suppress. The call is kept for its
	# side effect — deducing a concealed spotter from unexplained bloom.
	_probe_concealment(ctx.server)
