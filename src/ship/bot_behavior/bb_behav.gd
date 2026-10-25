extends BotBehavior
class_name BBBehavior




# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 2.0
		Ship.ShipClass.DD: return 4.0
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

func _apply_gun_policy(ctx: SkillContext, _sit: Dictionary) -> void:
	# Result deliberately unused: BBs never suppress. The call is kept for its
	# side effect — deducing a concealed spotter from unexplained bloom.
	_probe_concealment(ctx.server)

## Opening: fight where the unseen enemy is presumed to be; failing a station, the engaged arm.
func _opening(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var intent := _run_skill(&"Fight", ctx, {"only": SkillFight.Mode.STATION, "presumed": true})
	return intent if intent != null else _select_engaged_skill(ctx, sit)

## The engaged arm: island cover toward the priority first, as a cruiser; open water failing it.
func _select_engaged_skill(ctx: SkillContext, _sit: Dictionary) -> NavIntent:
	return _fight(ctx, {"prefer_cover": true})
