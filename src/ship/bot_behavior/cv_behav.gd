extends CABehavior
class_name CVBehavior
## Carrier doctrine — the carrier fights with its air group, not with its hull.
##
## Everything below follows from one fact: the range that matters to a carrier is
## the squadron's tether to the ship (AircraftParams._range), not its gun range.
## So the hull's whole job is to hold a distance from the contact the air group is
## working that satisfies three things at once:
##
##   * inside the reach of the SHORTEST-legged strike squadron, so every squadron
##     on deck is usable instead of just the long-ranged bombers;
##   * as close to that contact as safety allows, because a shorter transit is a
##     shorter cycle, and cycle time is a carrier's real DPM;
##   * undetected — a spotted carrier is not at risk of losing a trade, it is at
##     risk of dying, so detection is what drives it back out, not threat score.
##
## That is the only sense in which a carrier "pushes": to cycle squadrons faster
## and to bring a target inside a short-legged squadron's reach, always from
## behind its own screen. It never closes to fight the way a cruiser does, and it
## never chases a last-known position — its planes go and look instead. Nothing
## in this file drives the hull at the enemy.
##
## Gunnery, ammo and aim are inherited from CABehavior; only navigation differs.

# ── Standoff tuning ─────────────────────────────────────────────────────────
## Fraction of the shortest strike squadron's tether to sit at when the picture
## allows it. Under 1.0 so the contact can move without immediately falling out
## of reach, and so squadrons have a short transit rather than a maximum one.
const CYCLE_BAND_RATIO: float = 0.75
## Cap on the standoff as a fraction of the LONGEST squadron's tether — past this
## even the bombers cannot reach and the carrier is a spectator.
const OUTER_BAND_RATIO: float = 0.95
## Standoff once we are seen, as a fraction of enemy gun reach. Deliberately
## short of 1.0: outrunning gun range outright is not achievable, opening the
## range to where their fire is inaccurate and their approach slow is.
const EXPOSED_STANDOFF_RATIO: float = 0.85
## Absolute floor on the standoff regardless of what the aircraft would prefer:
## a fraction of enemy gun reach, and never closer than HARD_FLOOR_MIN. Inside
## this the carrier is in the brawl envelope and stops caring about its air group.
const HARD_FLOOR_RATIO: float = 0.45
const HARD_FLOOR_MIN: float = 8000.0
## The carrier will not deliberately close inside its own detection radius times
## this. That radius is the whole reason a standoff is survivable at all: outside
## it nothing sees the ship without help, inside it everything with line of sight
## does. Closing to exactly the boundary would sit the hull on the edge and flick
## in and out of detection, so the margin buys a little room.
const CONCEAL_MARGIN: float = 1.15
## Dead-band around the station distance. Without it the hull would creep in and
## out every tick as the contact drifts.
const BAND_TOLERANCE: float = 0.15
## How far past the station distance a cover position may sit and still be worth
## taking, as a fraction of that distance.
const COVER_BAND_SLACK: float = 1.25

## How long a carrier keeps behaving as if it were seen after the last time it
## actually was. Detection flickers; the retreat it triggers must not.
const EXPOSURE_MEMORY_MS: int = 8000

var _skill_retreat: SkillRetreat = SkillRetreat.new()

var _exposed_until_ms: int = 0


# get_positioning_params() and get_hunting_params() are deliberately not
# overridden here. Both express a standoff as a fraction of GUN range, which is
# the wrong quantity for a carrier and is not what steers it — see
# _standoff_band(), which works from the air group's reach instead.

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 0.5
		Ship.ShipClass.CV: return 0.5
	return 1.0

func _roll_flank_depth() -> float:
	return randf_range(0.05, 0.15)  # stay closer to the friendly line than a BB

func get_chase_max_threat() -> float:
	# Never. The hull does not go looking for a contact it cannot see; that is
	# what the spotter squadrons are for.
	return 0.0


# ============================================================================
# AIR GROUP REACH
# ============================================================================

func _strike_reach() -> Dictionary:
	## The tether of this carrier's attack squadrons: {shortest, longest}.
	## Spotters are excluded — they fly out to look, they do not set the standoff.
	## The roster is used rather than the live aircraft count, so a squadron that
	## is currently shot down or rearming still constrains the station; it will be
	## back, and a standoff that jumped every time one was lost would be useless.
	var shortest: float = 0.0
	var longest: float = 0.0
	var av: AviationController = _ship.aviation_controller
	if av != null:
		for squad: Squadron in av.squadrons:
			if squad.aircraft.is_empty() or _squadron_is_spotter(squad):
				continue
			var r: float = _squadron_range(squad)
			if r <= 0.0:
				continue
			if shortest <= 0.0 or r < shortest:
				shortest = r
			if r > longest:
				longest = r
	if shortest <= 0.0:
		# No attack squadrons at all (spotter-only, or aviation not set up):
		# fall back to gun range so the standoff still means something.
		var gun_range: float = _ship.artillery_controller.get_params()._range
		shortest = gun_range
		longest = gun_range
	return {shortest = shortest, longest = longest}


func _enemy_gun_reach(server: GameServer) -> float:
	## Longest gun range among the enemies we know of — the distance at which
	## being seen starts to cost us. Destroyers are left out: their guns are not
	## what kills a carrier, and counting them would push the station out to no
	## purpose every time one is held on a stale contact.
	var reach: float = 0.0
	for enemy in server.get_valid_targets(_ship.team.team_id):
		if not is_instance_valid(enemy) or enemy.ship_class == Ship.ShipClass.DD:
			continue
		if enemy.artillery_controller == null:
			continue
		reach = maxf(reach, enemy.artillery_controller.get_params()._range)
	for enemy in server.get_unspotted_enemies(_ship.team.team_id).keys():
		if not is_instance_valid(enemy) or enemy.ship_class == Ship.ShipClass.DD:
			continue
		if not enemy.health_controller.is_alive() or enemy.artillery_controller == null:
			continue
		reach = maxf(reach, enemy.artillery_controller.get_params()._range)
	if reach <= 0.0:
		reach = _ship.artillery_controller.get_params()._range
	return reach




# ============================================================================
# STATION GEOMETRY
# ============================================================================

func _strike_anchor(server: GameServer) -> Dictionary:
	## The contact the air group is working, and the one the hull stations off.
	## This is literally the ship aviation_engage() picked (see
	## Behavior._select_air_target), not a second opinion about which enemy
	## matters — hull and air group must not be working two different enemies,
	## and here that is not just tidiness. The approach cone clamps every attack
	## run to MAX_ATTACK_ANGLE either side of the CARRIER-to-target line, so
	## where this hull stands is what decides whether a beam-on drop is
	## available at all. Stationing off some other contact does not merely waste
	## the transit; it takes the broadside off the table for the whole air group.
	##
	## Falls back to the nearest believable contact while there is no air target
	## — on the first tick, or with the deck empty.
	## Returns {valid, position, distance, basis, live}.
	var chosen: Ship = get_air_target()
	if chosen != null:
		var chosen_sol: Dictionary = get_contact_solution(chosen)
		if chosen_sol.get("valid", false) and float(chosen_sol.age) <= LKP_MAX_LEAD_AGE:
			var at: Vector3 = chosen_sol.position
			return {
				valid = true,
				position = at,
				distance = _ship.global_position.distance_to(at),
				basis = chosen_sol.get("basis", Basis.IDENTITY),
				live = not bool(chosen_sol.is_lkp),
			}
	var best_pos: Vector3 = Vector3.ZERO
	var best_dist: float = INF
	var best_basis: Basis = Basis.IDENTITY
	var best_live: bool = false
	for enemy in server.get_valid_targets(_ship.team.team_id):
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		var d: float = _ship.global_position.distance_to(enemy.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = enemy.global_position
			best_basis = enemy.global_transform.basis
			best_live = true
	for enemy in server.get_unspotted_enemies(_ship.team.team_id).keys():
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		var sol: Dictionary = get_contact_solution(enemy)
		# Anything staler than the dead-reckoning horizon is not stationed
		# against at all — the air group goes and re-finds it, the hull does not.
		if not sol.get("valid", false) or float(sol.age) > LKP_MAX_LEAD_AGE:
			continue
		var pos: Vector3 = sol.position
		var d2: float = _ship.global_position.distance_to(pos)
		if d2 < best_dist:
			best_dist = d2
			best_pos = pos
			best_basis = sol.get("basis", Basis.IDENTITY)
			best_live = false
	if best_dist == INF:
		return {valid = false}
	return {
		valid = true,
		position = best_pos,
		distance = best_dist,
		basis = best_basis,
		live = best_live,
	}


func _standoff_band(server: GameServer) -> Dictionary:
	## The three distances the hull is steered by, all measured from the anchor:
	##   min_dist   — never inside this, whatever the aircraft would prefer
	##   close_dist — where every squadron reaches and cycles quickly
	##   safe_dist  — where we go once somebody can see us
	var reach: Dictionary = _strike_reach()
	var enemy_reach: float = _enemy_gun_reach(server)
	var min_dist: float = maxf(enemy_reach * HARD_FLOOR_RATIO, HARD_FLOOR_MIN)
	var outer: float = maxf(float(reach.longest) * OUTER_BAND_RATIO, min_dist)
	# Closing is bounded below by our own concealment, not just by the brawl
	# line: a carrier inside its own detection radius is spotted the moment
	# anything has line of sight to it, whatever the aircraft would gain.
	var conceal_floor: float = _own_conceal_radius() * CONCEAL_MARGIN
	var close_dist: float = clampf(
		maxf(float(reach.shortest) * CYCLE_BAND_RATIO, conceal_floor), min_dist, outer)
	var safe_dist: float = clampf(enemy_reach * EXPOSED_STANDOFF_RATIO, close_dist, outer)
	return {min_dist = min_dist, close_dist = close_dist, safe_dist = safe_dist}


func _own_conceal_radius() -> float:
	if _ship.concealment == null or _ship.concealment.params == null:
		return 0.0
	return (_ship.concealment.params.p() as ConcealmentParams).radius


func _has_screen(server: GameServer, anchor_pos: Vector3, station_dist: float) -> bool:
	## True when some other ship of ours is closer to the contact than the station
	## we are considering. A carrier only closes from behind its own line; with
	## the screen gone there is nothing between it and the enemy, and the DPM it
	## would gain by closing is not worth being the front of the fleet.
	for mate in server.get_team_ships(_ship.team.team_id):
		if mate == _ship or not is_instance_valid(mate):
			continue
		if not mate.health_controller.is_alive() or mate.ship_class == Ship.ShipClass.CV:
			continue
		if mate.global_position.distance_to(anchor_pos) < station_dist:
			return true
	return false


func _station_point(anchor_pos: Vector3, dist: float, beam: Basis = Basis.IDENTITY,
		work_beam: bool = false) -> Vector3:
	## The point at `dist` from the contact along the bearing we already hold —
	## the carrier slides in and out along its own radius rather than taking a
	## new line that would walk it across the enemy's front.
	##
	## With `work_beam` set it also eases around that radius toward the contact's
	## beam. This is the hull's only real contribution to the strike: an attack
	## run is clamped to MAX_ATTACK_ANGLE either side of the carrier-to-target
	## line, so a beam-on drop — the one that crosses the target's whole length
	## instead of its width — is available only from off the target's beam. The
	## air group waits at its rally for that presentation (see
	## Behavior._wait_for_broadside); this is the half of the arrangement that
	## goes and gets it rather than hoping the target obliges.
	##
	## Bounded to BEAM_WORK_MAX_BIAS off the bearing already held, and always the
	## short way round, so the carrier eases along its arc over successive ticks
	## instead of setting a course across the enemy's front to reach the ideal
	## point in one leg.
	var away: Vector3 = _ship.global_position - anchor_pos
	away.y = 0.0
	if away.length_squared() < 1.0:
		away = _cached_safe_dir
		away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3(0.0, 0.0, 1.0)
	away = away.normalized()
	_beam_work_active = false
	if work_beam:
		away = _bias_toward_beam(away, beam)
	var pos: Vector3 = anchor_pos + away * dist
	pos.y = 0.0
	return _get_valid_nav_point(pos)


## Widest the station bearing may be swung off the one currently held in a
## single decision. A carrier that jumped straight to the ideal beam bearing
## would order a leg around the standoff arc that crosses in front of whatever
## it is stationed off; easing round means the navigator is always steering to
## somewhere just off the beam it already occupies.
const BEAM_WORK_MAX_BIAS: float = deg_to_rad(30.0)
## Inside this much of the beam the station is left alone. Without it the hull
## shuffles either side of the ideal bearing forever as the contact yaws.
const BEAM_WORK_DEAD_ZONE: float = deg_to_rad(8.0)


## Set while the station bearing is actually being swung, purely so the debug
## readout distinguishes a carrier working onto the beam from one parked on
## station — the two look identical by distance alone, which is what the skill
## name is otherwise derived from.
var _beam_work_active: bool = false


func _bias_toward_beam(away: Vector3, beam: Basis) -> Vector3:
	## Swings the standoff bearing toward whichever of the contact's two beams it
	## is already nearer, by at most BEAM_WORK_MAX_BIAS.
	var right: Vector3 = Vector3(beam.x.x, 0.0, beam.x.z)
	if right.length_squared() < 0.0001:
		return away
	right = right.normalized()
	# Standing off the contact's beam means standing where its beam points at
	# us, so the bearing we want is the beam axis itself — whichever end of it
	# is the shorter move from here.
	var ideal: Vector3 = right if away.dot(right) >= 0.0 else -right
	var offset: float = away.signed_angle_to(ideal, Vector3.UP)
	if absf(offset) <= BEAM_WORK_DEAD_ZONE:
		return away
	_beam_work_active = true
	return away.rotated(Vector3.UP, clampf(offset, -BEAM_WORK_MAX_BIAS, BEAM_WORK_MAX_BIAS))


func _update_exposure(ship: Ship) -> bool:
	## Detection flickers as islands and spotters come and go; the withdrawal it
	## triggers must not, or the carrier ends up oscillating on the spot instead
	## of actually opening the range.
	if ship.visible_to_enemy or not active_shooters_at_me.is_empty():
		_exposed_until_ms = Time.get_ticks_msec() + EXPOSURE_MEMORY_MS
		return true
	return Time.get_ticks_msec() < _exposed_until_ms


# ============================================================================
# NAVINTENT
# ============================================================================

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	# A carrier is always sneaking: while wants_stealth is set the navigator
	# routes around known enemy detection envelopes instead of straight through.
	wants_stealth = true
	_ensure_safe_dir(ship, server)
	_init_flank_identity(ship, server)
	var ctx: SkillContext = SkillContext.create(ship, target, server, self)
	_sync_cover_debug(ctx)

	var spotted: Array = server.get_valid_targets(ship.team.team_id)
	_update_enemy_tracking(ship, server, spotted)

	# The guns are a liability, not an asset: firing blooms, and bloom is what
	# gets a carrier seen. Fire only when concealment is already lost anyway.
	wants_to_be_concealed = _probe_concealment(server)
	_suppress_guns = wants_to_be_concealed

	var previous_skill: StringName = _active_skill_name
	var exposed: bool = _update_exposure(ship)
	var anchor: Dictionary = _strike_anchor(server)
	var band: Dictionary = _standoff_band(server)
	# Cover is wanted purely for concealment, never as a firing position, so the
	# search runs with prioritize_cover and is allowed to consider islands right
	# out to the edge of gun range rather than the 0.7 default.
	var cover_params: Dictionary = {"max_range": 1.0}

	var intent: NavIntent = null

	# ── Nothing worth stationing against ────────────────────────────────────
	# No contact, or only contacts too stale to be believed. Sit in cover with
	# the line and let the spotters do the finding.
	if not bool(anchor.get("valid", false)):
		intent = _take_cover(ctx, cover_params)
		if intent == null:
			intent = _skill_flank.execute(ctx, {})
			if intent != null:
				_active_skill_name = &"Flank"
		if intent == null:
			intent = _intent_sail_forward(ship)
			_active_skill_name = &"SailForward"
		return _finish_intent(intent, previous_skill)

	var anchor_pos: Vector3 = anchor.position
	var anchor_dist: float = anchor.distance
	var anchor_beam: Basis = anchor.get("basis", Basis.IDENTITY)
	var min_dist: float = band.min_dist

	# ── Contact inside the floor, or somebody is already shooting ───────────
	# Nothing about the air group matters now; break contact.
	if anchor_dist < min_dist or not active_shooters_at_me.is_empty():
		intent = _take_cover(ctx, cover_params, anchor_pos, min_dist, INF)
		if intent == null and not _get_nearest_enemy().is_empty():
			intent = _skill_retreat.execute(ctx, {})
			if intent != null:
				intent.throttle_override = 4
				_active_skill_name = &"Retreat"
		if intent == null:
			intent = _station_intent(ctx, anchor_pos, _station_point(anchor_pos, band.safe_dist))
			_active_skill_name = &"Withdraw"
		return _finish_intent(intent, previous_skill)

	# ── Station on the strike ring ──────────────────────────────────────────
	# Close only while unseen and screened; otherwise hold at the open range.
	var defensive: bool = exposed or not _has_screen(server, anchor_pos, float(band.close_dist))
	var hold_dist: float = float(band.safe_dist) if defensive else float(band.close_dist)
	var target_dist: float = clampf(
		anchor_dist,
		hold_dist * (1.0 - BAND_TOLERANCE),
		hold_dist * (1.0 + BAND_TOLERANCE))

	# Cover that sits in the band beats open water at the same distance: the
	# carrier gets its station and its concealment from the same position. While
	# we are already seen, though, cover has to be at least as far out as the
	# station is — an island that would have us steaming toward the guns to reach
	# it is not cover, whatever it hides us from once we arrive.
	var cover_min: float = min_dist
	if defensive:
		cover_min = maxf(min_dist, hold_dist * (1.0 - BAND_TOLERANCE))
	intent = _take_cover(ctx, cover_params, anchor_pos, cover_min, hold_dist * COVER_BAND_SLACK)
	if intent == null:
		# Working onto the beam is only ever done while unseen and screened, and
		# only against a contact somebody is actually watching. Once we are
		# exposed the hull's job is distance, not a better firing angle for the
		# air group; and a heading frozen on a last-known position is not one
		# there is any point manoeuvring against, since it cannot be seen to
		# change.
		var work_beam: bool = not defensive and bool(anchor.get("live", false))
		intent = _station_intent(ctx, anchor_pos,
			_station_point(anchor_pos, target_dist, anchor_beam, work_beam))
		if _beam_work_active:
			_active_skill_name = &"WorkBeam"
		elif target_dist < anchor_dist - 1.0:
			_active_skill_name = &"Close"
		elif target_dist > anchor_dist + 1.0:
			_active_skill_name = &"Withdraw"
		else:
			_active_skill_name = &"Station"

	return _finish_intent(intent, previous_skill)


func _take_cover(ctx: SkillContext, cover_params: Dictionary, anchor_pos: Vector3 = Vector3.ZERO,
		min_dist: float = -1.0, max_dist: float = -1.0) -> NavIntent:
	## Cover, accepted only when it also happens to be a place a carrier should
	## be standing. Passing no band takes whatever cover is nearest; passing one
	## rejects an island that would drag the hull inside the floor or out past
	## where its squadrons still reach.
	var cover: NavIntent = _skill_cover.execute(ctx, cover_params, true)
	if cover == null:
		return null
	if min_dist >= 0.0 or max_dist >= 0.0:
		var d: float = anchor_pos.distance_to(cover.target_position)
		if min_dist >= 0.0 and d < min_dist:
			return null
		if max_dist >= 0.0 and d > max_dist:
			return null
	# The cover position is deliberately chosen for the terrain it hides behind;
	# it must not be pushed back out of a detection arc it is already screened
	# from. See NavIntent.skip_threat_adjustment.
	cover.skip_threat_adjustment = true
	_active_skill_name = &"FindCover"
	return cover


func _station_intent(ctx: SkillContext, anchor_pos: Vector3, station_pos: Vector3) -> NavIntent:
	## Hold `station_pos`, stern to the contact — a carrier that is surprised
	## wants the next thing it does to be distance, not a turn. hold_radius keeps
	## it loosely on station instead of parking dead in the water on the mark.
	var away: Vector3 = _ship.global_position - anchor_pos
	away.y = 0.0
	var heading: float = atan2(away.x, away.z) if away.length_squared() > 1.0 else _get_ship_heading()
	var hold: float = _ship.movement_controller._p().turning_circle_radius
	var intent: NavIntent = NavIntent.create(station_pos, heading, hold)
	# Carriers stack up on the same standoff arc otherwise, and a collision at
	# the back of the fleet is a carrier that has stopped launching.
	return _skill_spread.apply(intent, ctx, {"spread_distance": 2000.0, "spread_multiplier": 1.0})
