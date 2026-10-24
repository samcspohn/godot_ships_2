extends BotBehavior
class_name DDBehavior


# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.5   # CAs are DD hunters
		Ship.ShipClass.DD: return 1.0
	return 1.0

func get_positioning_params() -> Dictionary:
	return {
		spread_distance = 1500.0,  # DDs spread more
		spread_multiplier = 1.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.8,      # DDs hunt aggressively
	}

# ============================================================================
# TARGET SELECTION - DD-specific logic (visible vs hidden priority)
# ============================================================================

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	"""DD target selection differs based on visibility - torpedoes vs guns.
	Prefers targets we can actually shoot at over ones behind cover.
	Balances proximity threats against overextended enemies:
	 - Enemies very close get a strong proximity boost.
	 - Enemies farthest into friendly territory get an overextension bonus.
	 - When nothing is dangerously close, the most overextended enemy wins."""
	var gun_range = _ship.artillery_controller.get_params()._range
	# A gunboat scores gun targets whether or not it is currently lit. Being dark
	# is a passing accident for it, not the setup for a torpedo run, and picking
	# a target it means to hit with tubes it does not really have leaves it
	# tracking the wrong ship the moment it is seen again.
	var is_torpedo_boat: bool = not _is_gunboat(_ship) or _gb_stealth
	var torpedo_range: float = -1.0
	var proximity_override_dist: float = 2500.0  # DDs are fast, smaller threshold
	var overextension_weight: float = 0.3
	var overextension_bonus: float = 1.8

	if _ship.torpedo_controller != null:
		torpedo_range = _ship.torpedo_controller.get_params()._range

	# --- First pass: compute base priority and overextension for every target ---
	var candidate_data: Array[Dictionary] = []
	var max_overextension: float = 0.0
	var has_close_threat: bool = false

	# Ships held only on a fresh last-known position are candidates too, at
	# reduced priority (LKP_TARGET_PRIORITY_MULT below) - a DD that has lost the
	# plot still knows roughly where the enemy was seconds ago.
	var candidates: Array[Ship] = targets.duplicate()
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node != null:
		for enemy: Ship in server_node.get_unspotted_enemies(_ship.team.team_id).keys():
			if not is_instance_valid(enemy) or not enemy.is_alive():
				continue
			if enemy.visible_to_enemy or candidates.has(enemy):
				continue
			candidates.append(enemy)

	for ship in candidates:
		# Score the position this bot believes in, not the one it cannot see
		var contact := get_contact_solution(ship)
		if not is_engageable_contact(contact):
			continue
		var contact_pos: Vector3 = contact.position
		var disp = contact_pos - _ship.global_position
		var dist = disp.length()
		var angle = (-(contact.basis.z as Vector3)).angle_to(disp)
		angle -= PI / 4  # Best angle to torpedo is 45 degrees incoming
		var priority: float = 0.0

		if is_torpedo_boat and !_ship.is_detected():
			# Hidden - prioritize torpedo targets
			priority = cos(angle) * ship.movement_controller.ship_length / dist
			if torpedo_range > 0:
				priority = priority * 0.3 + (1.0 - dist / torpedo_range) * 0.7
			if ship.ship_class == Ship.ShipClass.BB:
				priority *= 2.0  # BBs are prime torpedo targets
		else:
			# Visible - prioritize gun targets
			priority = (1.0 - dist / gun_range)

		# Boost targets within range
		if dist <= gun_range or (torpedo_range > 0 and dist <= torpedo_range):
			priority *= 10.0

		# Apply flanking priority boost - DDs should intercept flankers
		var flank_info = _get_flanking_info(ship)
		if flank_info.is_flanking:
			# DDs are excellent at intercepting flankers due to speed and torpedoes
			var flank_multiplier = 6.0  # High priority for flankers
			var depth_scale = 1.0 + flank_info.penetration_depth
			priority *= flank_multiplier * depth_scale

		# Overextension score: how far into friendly territory this enemy is
		var overext = _get_overextension_score(ship)
		if overext > max_overextension:
			max_overextension = overext

		# Track whether any enemy is dangerously close
		if dist < proximity_override_dist:
			has_close_threat = true

		# A contact held only on a last-known position stays in the running, but
		# always loses to a ship someone can actually see
		if contact.is_lkp:
			priority *= LKP_TARGET_PRIORITY_MULT

		# A torpedo boat only counts guns once it is lit; a gunboat shoots from the start,
		# so a live contact it can actually hit beats any it cannot.
		var shootable = (_ship.is_detected() if is_torpedo_boat else not contact.is_lkp) \
			and dist <= gun_range and can_hit_target(ship)
		candidate_data.append({
			ship = ship,
			base_priority = priority,
			dist = dist,
			overextension = overext,
			shootable = shootable,
		})

	# --- Second pass: apply overextension vs proximity weighting ---
	var best_shootable: Ship = null
	var best_shootable_priority: float = -1.0
	var best_fallback: Ship = null
	var best_fallback_priority: float = -1.0

	for data in candidate_data:
		var priority: float = data.base_priority
		var dist: float = data.dist
		var overext: float = data.overextension
		var ship: Ship = data.ship

		# Overextension contribution: reward enemies deeper into friendly territory
		if max_overextension > 0.0 and overextension_weight > 0.0:
			var relative_overext = overext / max_overextension
			var overext_contrib = relative_overext * overextension_weight
			priority += overext_contrib

			# Extra bonus for the most overextended target when nothing is dangerously close
			if not has_close_threat and relative_overext > 0.9:
				priority *= overextension_bonus

		# Proximity override: if this enemy is very close, give a strong boost
		if dist < proximity_override_dist:
			var proximity_factor = 1.0 + 2.0 * (1.0 - dist / proximity_override_dist)
			priority *= proximity_factor

		# Sort into shootable vs fallback
		if data.shootable:
			if priority > best_shootable_priority:
				best_shootable = ship
				best_shootable_priority = priority
		else:
			if priority > best_fallback_priority:
				best_fallback = ship
				best_fallback_priority = priority

	# Prefer shootable gun targets when visible; otherwise fall back
	# (when hidden, torpedo targets don't need line-of-fire for guns)
	return best_shootable if best_shootable != null else best_fallback



# ============================================================================
# NAVINTENT — decision arms specific to the destroyer
# ============================================================================

## How much wider than its own detection radius a boat's tubes must reach before
## the water in between counts as a launch band worth building a playstyle on.
## A boat at 1.0 can only launch from exactly the range at which it is seen,
## which is not a torpedo boat - it is a gunboat carrying tubes.
const GUNBOAT_BAND_RATIO: float = 1.5

## Whether this hull fights in the open with its guns rather than from the dark
## with its tubes.
##
## Measured, not named, so a hull is classified by what it can actually do. The
## question is whether there is any water from which this boat can launch
## without being seen, which is the gap between the two terms engagement_range()
## already takes the min() of - concealment out to tube range. When that gap
## closes the min() starts returning a standoff the boat cannot legally fire
## from, and stealth has stopped being a weapon.
##
## Reads post-upgrade numbers (Moddable.p()), so a concealment module or a
## captain skill moves the answer, and a range-only gunnery skill such as
## Advanced Firing Training deliberately does not - it touches neither term.
func _is_gunboat(ship: Ship) -> bool:
	if not is_instance_valid(ship):
		return false
	if ship.torpedo_controller == null:
		return true
	var torp_range: float = ship.torpedo_controller.get_params()._range
	if torp_range <= 0.0:
		return true
	var conceal: float = (ship.concealment.params.p() as ConcealmentParams).radius
	if conceal <= 0.0:
		return false  # conceals perfectly; the dark is free
	return torp_range * TORPEDO_ENGAGE_RATIO \
		< conceal * SkillSpot.SAFE_MARGIN * GUNBOAT_BAND_RATIO

func _owns_gun_policy() -> bool:
	return true

func doctrine() -> BotDoctrine:
	return BotDoctrine.for_gunboat_destroyer() if _gunboating() else BotDoctrine.for_destroyer()

## Below this HP fraction a gun-armed hull fights as a torpedo boat.
const GUNBOAT_TORPEDO_HP := 0.35
## Spotting, a gunboat at any HP keeps its guns free below this threat.
const GUNBOAT_SPOT_FIRE_THREAT := 0.7

func _gunboating() -> bool:
	if not _is_gunboat(_ship):
		return false
	var hc := _ship.health_controller
	return hc.current_hp >= hc.max_hp * GUNBOAT_TORPEDO_HP

## Which row _doc() is currently holding, so a flip can be noticed.
var _doctrine_is_gunboat: bool = false

## BotBehavior._doc() builds the row once and keeps it, but the classification
## above reads post-upgrade numbers and upgrades are applied deferred
## (GameServer._add_player), so the first read can land on the bare hull. Re-run
## the classifier - two property reads - every call, and rebuild only when the
## answer actually changes.
func _doc() -> BotDoctrine:
	var gunboat := _gunboating()
	if _doctrine == null or gunboat != _doctrine_is_gunboat:
		_doctrine_is_gunboat = gunboat
		_doctrine = doctrine()
	return _doctrine

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	wants_stealth = false  # reset each tick; the gun policy below sets it
	wants_to_be_concealed = false
	return _nav_core(SkillContext.create(ship, target, server, self))

## The engaged arm.  There is no separate torpedo-run manoeuvre any more: a
## destroyer's engagement range IS its torpedo range, so pushing to that range
## puts it where it can launch, and SkillBroadside swings the tubes on.
##
## Push if the odds are good and there is something visible to push onto, run
## down a last-known position if there is not, and otherwise go make vision for
## the team.
func _select_engaged_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var d := _doc()
	var ship := ctx.ship
	var intent: NavIntent = null

	# A gunboat's ladder is its committed intent; nothing is left to try here.
	if _is_gunboat(ship):
		return null

	# The one case that is not scouting: something is lit, it is the best thing
	# on offer, and the odds are good. Push, but only to the range our weapons
	# actually want - for a boat with tubes that is torpedo range, and closing
	# further would just walk it into gun range for nothing.
	if sit.threat < d.push_threat and sit.has_spotted and ctx.target != null \
			and not _has_better_unspotted_torp_target(ship, ctx.target, ctx.server):
		intent = _fight(ctx, {"desired_range": smoothed_engagement_range(ctx)})
		if intent != null:
			wants_stealth = false
			wants_to_be_concealed = false
			_suppress_guns = false

	# Everything else is the same errand - go and make vision - so it is one
	# ladder rather than a branch per reason for being on it. Under pressure the
	# guns were the wrong answer anyway; with nothing lit there is nothing to
	# shoot; with something lit that is not worth pushing, the boat still wants
	# eyes on whatever it would rather be shooting at instead.
	#
	# Spot before Chase, which is the fix for a destroyer that used to ram.
	# Chase drives at the nearest last-known position at flank speed and arrives
	# lit up, alone, at a place the contact has already left. Spot goes to where
	# the contact can be SEEN from, which is the same errand done in a way the
	# boat survives, and launch_range prefers a station the tubes reach from.
	if intent == null:
		intent = _run_skill(&"Fight", ctx, {"only": SkillFight.Mode.SPOT, "launch_range": _torpedo_reach(ship)})
	if intent == null and sit.has_spotted:
		intent = _run_skill(&"Disengage", ctx)
	return intent


## Nothing spotted and the gunboat skill idle: spot and torpedo rather than gunboat.
var _gb_stealth: bool = false

## The gunboat's whole ladder, in every arm: fight from the band whenever a
## target is in reach, else spot its priorities. Lit, it breaks off at extreme
## threat or when hurt; hurt and unseen, it spots.
func _committed_intent(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	if not _is_gunboat(_ship):
		return null
	var hc := _ship.health_controller
	var hurt: bool = hc.current_hp < hc.max_hp * GUNBOAT_TORPEDO_HP
	var intent: NavIntent = null
	if _ship.is_detected() and hurt:
		intent = _run_skill(&"Disengage", ctx)
	if intent == null and not hurt and _has_shootable_contact(ctx):
		intent = _fight(ctx, _gunboat_params(ctx), false)
	if intent == null:
		intent = _run_skill(&"Fight", ctx, {"only": SkillFight.Mode.SPOT})
	if intent == null:
		intent = _fight(ctx)
	if intent != null:
		sit["arm"] = &"engaged"
	return intent


## Hold FIGHT as a gunboat: a station that sees its target, the bow away from the danger.
func _gunboat_params(_ctx: SkillContext) -> Dictionary:
	return {"needs_los": true, "away": true}


## The distance this destroyer wants to fight at.
##
## For a boat with tubes this is NOT tube range.  Detection is one-sided in our
## favour: an enemy has to come inside OUR concealment radius to see us, so the
## whole band from there out to tube range is an undetected launch, and the
## near end of it is strictly the best place in that band to be — the torpedoes
## have less water to cross and the target has less time to comb them.  So the
## engagement range is the closest standoff that keeps us dark, and tube range
## only ever acts as a cap.
##
## Held at SkillSpot.SAFE_MARGIN so closing to engage and holding station to
## spot land in the same band rather than pulling against each other. Not the
## identical number any more - Spot now stops on the router's own detection
## radius (BotBehavior.threat_effective_radius, a concealment radius plus two
## turning circles) rather than on this multiple of concealment - but the two
## are within a few hundred metres for any destroyer hull, and this one has to
## stay a pure function of concealment because _is_gunboat() below classifies on
## it before the navigator exists.
##
## The cap is held short of nominal tube range because update_torpedo_aim()
## rejects an intercept solved beyond 0.9x of it, so sitting at the nominal
## maximum yields a firing position that never fires.
##
## Threat does not enter into it while there are tubes: the base class yields to
## main-battery range under pressure because closing to use secondaries is a bad
## trade, but a torpedo boat under pressure has MORE reason to stay in the band
## where it launches undetected, not less.  With no tubes the boat is a gunboat
## and takes the shared answer.
const TORPEDO_ENGAGE_RATIO: float = 0.8

## The band the tubes solve in; 0 without tubes, which SkillSpot reads as "no
## preference" rather than "nothing reaches".
func _torpedo_reach(ship: Ship) -> float:
	if ship.torpedo_controller == null:
		return 0.0
	return ship.torpedo_controller.get_params()._range * TORPEDO_ENGAGE_RATIO


func engagement_range(ship: Ship, threat: float) -> float:
	# Tubes alone are not the test - the band they can be fired from is. Without
	# one the min() below returns a standoff short of the boat's own guns that it
	# still cannot launch from, which is the worst of both weapons.
	if not _is_gunboat(ship) and ship.torpedo_controller != null:
		var torp_range: float = ship.torpedo_controller.get_params()._range
		if torp_range > 0.0:
			var conceal: float = (ship.concealment.params.p() as ConcealmentParams).radius
			# min(): when we conceal worse than the tubes reach there is no
			# undetected launch at all, and the boat has to close to tube range
			# and accept being seen.
			return minf(conceal * SkillSpot.SAFE_MARGIN, torp_range * TORPEDO_ENGAGE_RATIO)
	return super(ship, threat)


## Whether the active station skill found a cell the router can reach dark.
func _stealth_corridor() -> bool:
	return _skill_fight.spot.stealth_corridor

## A torpedo boat routes stealth-aware: undetected it keeps out of enemy
## detection zones in transit, detected it routes back toward cover so it sheds
## detection as fast as possible. A gunboat does none of it - every branch here
## costs it gun time, and it has no dark water to spend that time reaching.
func _apply_gun_policy(ctx: SkillContext, sit: Dictionary) -> void:
	var d := _doc()
	var latched := _dark_hold(ctx)
	if _active_skill_name == &"Disengage" and _skill_disengage.wants_concealment() and _probe_concealment(ctx.server):
		_gb_stealth = false
		wants_stealth = true
		wants_to_be_concealed = true
		_suppress_guns = true
		return
	if latched:
		_gb_stealth = false
		wants_to_be_concealed = true
		_suppress_guns = true
		return
	if not d.trades_on_concealment and _fighting(SkillFight.Mode.STATION):
		# Overrides the cornered rule too: the band opening is this boat's way out,
		# and a quiet bait spots nothing.
		_gb_stealth = false
		wants_stealth = false
		wants_to_be_concealed = false
		_suppress_guns = false
		return
	if _is_gunboat(_ship) and _fighting(SkillFight.Mode.SPOT) and sit.threat < GUNBOAT_SPOT_FIRE_THREAT:
		_gb_stealth = false
		_suppress_guns = false
		wants_to_be_concealed = false
		return
	_gb_stealth = not d.trades_on_concealment and not sit.has_spotted
	if _gb_stealth:
		wants_stealth = _stealth_corridor()
		_suppress_guns = _hold_fire_hidden(ctx, sit)
		wants_to_be_concealed = _suppress_guns
		return
	if not d.trades_on_concealment:
		# One exception, and it is not this arm's to make: the cornered rule in
		# _nav_core() has already fired by the time we get here, and it applies
		# to every hull. Past CORNERED_THREAT with bloom that would actually
		# decay, the guns are no longer buying the gunboat anything - it is
		# being shot at by more than it can trade with, and the only exit left
		# is the one every other class takes. Clear the flags only on the ticks
		# that rule did not fire, so the tick it does is not undone here.
		if not _cornered:
			wants_stealth = false
			wants_to_be_concealed = false
		_suppress_guns = false
		return

	if sit.threat > d.stealth_threat:
		# Only ask the navigator to route around detection zones when staying
		# out of them is actually possible. Against a contact that conceals
		# better than we do there is no such route, and subscribing anyway
		# hands the pathfinder a goal inside its own blocked cells — which is
		# how a destroyer ends up circling the map instead of spotting.
		wants_stealth = _stealth_corridor()
	# Never opens up from the dark: the guns join once something has us lit.
	# Engaging is the exception; it is the aggressive leg and shoots its way in.
	_suppress_guns = _active_skill_name != &"Engage" and not _fighting(SkillFight.Mode.STATION)
	# Suppress guns when detected with bloom up and the nearest enemy far enough
	# that going dark would actually drop us. DDs always take that chance.
	wants_to_be_concealed = _suppress_guns and _probe_concealment(ctx.server)

# ============================================================================
# COMBAT - DD-specific engagement with torpedo logic
# ============================================================================

## Returns true when there is an unspotted non-DD enemy that is both within
## 1.5× torpedo range AND closer to us than the current spotted target.
## In that case it is worth spotting first for a better torpedo run.
func _has_better_unspotted_torp_target(ship: Ship, current_target: Ship, server: GameServer) -> bool:
	if ship.torpedo_controller == null:
		return false
	var torp_range: float = ship.torpedo_controller.get_params()._range
	if torp_range <= 0.0:
		return false

	var scan_radius: float = torp_range * 1.5
	var current_dist: float = ship.global_position.distance_to(current_target.global_position) \
		if current_target != null else INF

	var unspotted := server.get_unspotted_enemies(ship.team.team_id)
	for s in unspotted.keys():
		if not is_instance_valid(s):
			continue
		if s.ship_class == Ship.ShipClass.DD:
			continue  # DDs are poor torpedo targets
		var last_pos: Vector3 = unspotted[s]
		var dist: float = ship.global_position.distance_to(last_pos)
		if dist <= scan_radius and dist < current_dist:
			return true
	return false

## Guns only when already spotted (revealing position is already done), including
## on a ping or by aircraft, not just LOS; or when not suppressing; never in a stealth gunboat hold.
func would_fire_guns() -> bool:
	if _gb_stealth and _suppress_guns:
		return false
	return (_ship.is_detected() or (not _suppress_guns and can_fire_guns())) and super()

func engage_target(target: Ship):
	if would_fire_guns():
		super.engage_target(target)
		_ship.secondary_controller.enabled = not wants_to_be_concealed
	else:
		_ship.secondary_controller.enabled = false
		# Aim turrets but don't fire - at the believed position, so a target that
		# has gone dark is tracked at its dead-reckoned last-known position
		var aim_pos = contact_aim_point(target)
		if aim_pos != null:
			_ship.artillery_controller.set_aim_input(aim_pos)

	# Torpedoes are always managed
	update_torpedo_aim(target)
	torpedo_fire_timer += 1.0 / Engine.physics_ticks_per_second
	# Stance turned the hull to bear these tubes: launch the moment they do.
	if _skill_stance.wants_torpedoes() or torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes(target)
