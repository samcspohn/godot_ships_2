extends BotBehavior
class_name DDBehavior


# Speed variation for evasion
var speed_variation_timer: float = 0.0
var current_speed_multiplier: float = 1.0
const SPEED_VARIATION_PERIOD: float = 3.0
const SPEED_VARIATION_MIN: float = 0.6
const SPEED_VARIATION_MAX: float = 1.0

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(10),
		max_angle = deg_to_rad(25),
		evasion_period = 2.5,  # Quick, erratic weaving
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 0.5
		Ship.ShipClass.CA: return 1.5   # CAs are DD hunters
		Ship.ShipClass.DD: return 0.5
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
# EVASION - DD-specific with speed variation
# ============================================================================

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Override to add speed variation for DDs."""
	var result = super.get_desired_heading(target, current_heading, delta, destination)

	# Update speed variation when evading
	if result.use_evasion:
		speed_variation_timer += delta
		var speed_wave = (sin(speed_variation_timer * TAU / SPEED_VARIATION_PERIOD) + 1.0) / 2.0
		current_speed_multiplier = lerp(SPEED_VARIATION_MIN, SPEED_VARIATION_MAX, speed_wave)
	else:
		current_speed_multiplier = 1.0

	return result

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion."""
	return current_speed_multiplier

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
	var is_torpedo_boat: bool = not _is_gunboat(_ship)
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

		var shootable = _ship.is_detected() and dist <= gun_range and can_hit_target(ship)
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

func doctrine() -> BotDoctrine:
	return BotDoctrine.for_gunboat_destroyer() if _is_gunboat(_ship) \
		else BotDoctrine.for_destroyer()

## Which row _doc() is currently holding, so a flip can be noticed.
var _doctrine_is_gunboat: bool = false

## BotBehavior._doc() builds the row once and keeps it, but the classification
## above reads post-upgrade numbers and upgrades are applied deferred
## (GameServer._add_player), so the first read can land on the bare hull. Re-run
## the classifier - two property reads - every call, and rebuild only when the
## answer actually changes.
func _doc() -> BotDoctrine:
	var gunboat := _is_gunboat(_ship)
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

	if not d.trades_on_concealment:
		return _select_gunboat_engaged_skill(ctx, sit)

	# The one case that is not scouting: something is lit, it is the best thing
	# on offer, and the odds are good. Push, but only to the range our weapons
	# actually want - for a boat with tubes that is torpedo range, and closing
	# further would just walk it into gun range for nothing.
	if sit.threat < d.push_threat and sit.has_spotted and ctx.target != null \
			and not _has_better_unspotted_torp_target(ship, ctx.target, ctx.server):
		intent = _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})
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
	# boat survives. Chase stays as the fallback for when there is a position to
	# run down but no station worth holding, and Hunt below it for when the boat
	# does not believe in anything at all.
	if intent == null:
		intent = _run_skill(&"Spot", ctx)
	if intent == null:
		intent = _run_skill(&"Chase", ctx)
	if intent == null:
		intent = _run_skill(&"Hunt", ctx)

	return intent


## The engaged arm for a boat that fights in the open with its guns.
##
## A gunboat has no dark water to shoot from, so it trades on manoeuvre instead:
## it sits near the edge of its own gun range and dodges. Camp is what says that
## - it locks a firing position and hands the navigator a jitter radius to work
## inside, which is exactly the room BotControllerV4._update_shell_threats()
## needs to steer around incoming salvos. Push would chase a standoff that moves
## with the target and spend the fight under helm for a reason that has nothing
## to do with the shells in the air.
##
## Above camp_max_threat the position is no longer worth holding. From a camp
## near maximum gun range, opening the range usually breaks contact outright,
## so cover is tried first only because terrain is strictly better when it is
## going spare.
##
## With nothing spotted the boat falls through to the same errand the torpedo
## boat runs - go and make vision - because a destroyer that cannot see anything
## still has the fleet's eyes whatever it is armed with.
func _select_gunboat_engaged_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var d := _doc()
	var intent: NavIntent = null

	if sit.has_spotted:
		if sit.threat < d.camp_max_threat:
			# Camp wants a fraction of gun range; engagement_range() is the
			# metres. Convert rather than passing gun_engage_ratio directly, so
			# the camp distance stays the one answer every other arm uses.
			intent = _run_skill(&"Camp", ctx, {
				"desired_range_ratio": sit.engagement_range / maxf(sit.gun_range, 1.0),
				"here": false,
			})
		else:
			intent = _run_skill(&"FindCover", ctx, _cover_params())
			if intent == null:
				intent = _run_skill(&"Kite", ctx)

	if intent == null:
		intent = _run_skill(&"Spot", ctx)
	if intent == null:
		intent = _run_skill(&"Chase", ctx)
	if intent == null:
		intent = _run_skill(&"Hunt", ctx)

	return intent


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
## Shares SkillSpot.SAFE_MARGIN so that closing to engage and holding station to
## spot put the ship at the same distance rather than fighting each other.
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


## A torpedo boat routes stealth-aware: undetected it keeps out of enemy
## detection zones in transit, detected it routes back toward cover so it sheds
## detection as fast as possible. A gunboat does none of it - every branch here
## costs it gun time, and it has no dark water to spend that time reaching.
func _apply_gun_policy(ctx: SkillContext, sit: Dictionary) -> void:
	var d := _doc()
	if not d.trades_on_concealment:
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
		wants_stealth = _skill_spot.stealth_corridor
		_suppress_guns = true
	else:
		_suppress_guns = false
	# Suppress guns when detected with bloom up and the nearest enemy far enough
	# that going dark would actually drop us. DDs always take that chance.
	wants_to_be_concealed = _probe_concealment(ctx.server)

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

func engage_target(target: Ship):
	# Guns only when already spotted (revealing position is already done),
	# including on a ping or by aircraft, not just LOS.
	if _ship.is_detected() or (not _suppress_guns and can_fire_guns()):
		super.engage_target(target)
		_ship.secondary_controller.enabled = true
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
	if torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes(target)
