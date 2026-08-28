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

# ── Concealment bubble ─────────────────────────────────────────────────────
## Extra clearance asked for when actually breaking away from something that has
## got inside the bubble. Opening to exactly the keepout leaves the contact one
## knot of closing speed from being back inside it, and a carrier that shaves
## the boundary spends the rest of the match flicking in and out of detection.
const BREAK_CLEARANCE: float = 1.2
## How stale a last-known position may be and still count as a ship inside the
## bubble. Far shorter than LKP_MAX_LEAD_AGE: "it was there half a minute ago"
## is a reason to keep a standoff, not a reason to believe it is alongside now.
const CONCEAL_LKP_MAX_AGE: float = 12.0
## Widest a presumption's own uncertainty may be and still be allowed to move
## this hull at all. Past this the guess says "somewhere over there", and a
## carrier that fled every shrug would never launch anything.
const CONCEAL_PRESUMED_MAX_RADIUS: float = 6000.0

# ── Screen ─────────────────────────────────────────────────────────────────
## How far from the hull a friendly still counts as part of its screen. A mate
## fighting on the far flank is alive, useful, and no use whatever to this ship.
## Floored rather than fixed, because the standoff itself scales with the air
## group's reach and the screen has to be measured on the same scale.
const SCREEN_RADIUS_MIN: float = 10000.0
## What a surviving mate is worth in the screen tally before its health is
## counted. A destroyer screens against the thing a carrier actually fears —
## something slipping in close — so it is not scored by the gunnery it brings.
const SCREEN_CLASS_WEIGHT: Dictionary = {
	Ship.ShipClass.BB: 1.0,
	Ship.ShipClass.CA: 0.9,
	Ship.ShipClass.DD: 0.7,
}
## Tally below which the carrier stops calling itself screened. Set under the
## weight of one healthy ship, so a single damaged escort still counts for
## something and the last one dying is what tips it over.
const SCREEN_MIN_STRENGTH: float = 0.6
## Share of the screen that may go before it counts as a collapse rather than
## attrition. Roughly "one of the ships in front of us has stopped being there".
const SCREEN_LOSS_FRACTION: float = 0.3
## How long a collapse keeps steering the hull — long enough to actually finish
## a leg back behind whatever is left, rather than twitching and resuming.
const SCREEN_SHOCK_MS: int = 15000
## How fast the remembered screen strength follows the live one down while
## nothing dramatic is happening, in tally per second. Without it the reference
## stays pinned at the best moment of the match and ordinary attrition reads as
## a collapse forever after.
const SCREEN_REFERENCE_DECAY: float = 0.1


var _exposed_until_ms: int = 0

## Screen tracking. The reference is what the screen was worth recently; the
## live tally is compared against it rather than against a fixed number, because
## "enough escorts" is a different figure for a carrier sat behind a whole
## division than for one that has had two ships all game.
var _screen_reference: float = -1.0
var _screen_strength: float = 0.0
var _screen_nearby: float = 0.0
var _screen_shock_until_ms: int = 0
var _screen_sample_ms: int = 0


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
	return {min_dist = min_dist, close_dist = close_dist, safe_dist = safe_dist, outer = outer}


func _own_conceal_radius() -> float:
	## The radius that matters is the one in force now, not the one on the stat
	## card: once the guns have been fired the bloom IS the ship's detection
	## range until it decays, and standing at the paper radius while blooming is
	## standing inside the real one.
	if _ship.concealment == null or _ship.concealment.params == null:
		return 0.0
	var base: float = (_ship.concealment.params.p() as ConcealmentParams).radius
	return maxf(base, _ship.concealment.bloom_radius)


func _conceal_keepout() -> float:
	## The bubble the carrier tries to keep every enemy outside of. Inside it,
	## anything with line of sight holds the ship the instant it looks; outside
	## it the ship is simply not there as far as the enemy is concerned. This is
	## the one distance a carrier never trades away for a shorter strike cycle.
	return _own_conceal_radius() * CONCEAL_MARGIN


func _conceal_contacts(server: GameServer) -> Array:
	## Every enemy this bot has any business believing in, for the single
	## question of who is inside the bubble. Unlike _enemy_gun_reach this does
	## NOT drop destroyers — a destroyer inside a carrier's detection radius is
	## the exact thing the standoff exists to prevent — and unlike _strike_anchor
	## it has nothing to do with which contact the air group is working.
	##
	## Each entry is {position, hard}. `hard` marks a contact solid enough to
	## turn the hull around on its own: something spotted, or a last-known
	## position fresh enough to still mean a place. Presumptions are carried too,
	## but only as soft contacts — they bias where the hull stands without ever
	## ordering a break, because a guess with kilometres of slop in it is not
	## grounds for abandoning a strike.
	var out: Array = []
	var held: Dictionary = {}
	for enemy in server.get_valid_targets(_ship.team.team_id):
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		held[enemy] = true
		out.append({position = enemy.global_position, hard = true})
	for enemy in server.get_unspotted_enemies(_ship.team.team_id).keys():
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		var sol: Dictionary = get_contact_solution(enemy)
		if not sol.get("valid", false) or float(sol.age) > CONCEAL_LKP_MAX_AGE:
			continue
		held[enemy] = true
		out.append({position = sol.position, hard = true})
	for guess in get_presumed_contacts():
		if held.has(guess.ship) or float(guess.radius) > CONCEAL_PRESUMED_MAX_RADIUS:
			continue
		out.append({position = guess.position, hard = false})
	return out


func _conceal_breach(contacts: Array, from_pos: Vector3, keepout: float) -> Dictionary:
	## The worst intrusion into the bubble drawn around `from_pos`. Asked about
	## the hull's own position to decide whether to break away, and about a
	## candidate station to decide whether it is worth standing on.
	##
	## A hard contact always outranks a soft one however deep the soft one is:
	## the ranking is by how much is actually known, and only then by how much
	## clearance is missing.
	var worst: Dictionary = {breached = false, hard = false, deficit = 0.0}
	var worst_deficit: float = 0.0
	var worst_hard: bool = false
	for c in contacts:
		var hard: bool = bool(c.hard)
		if worst_hard and not hard:
			continue
		var d: float = from_pos.distance_to(c.position)
		var deficit: float = keepout - d
		if deficit <= 0.0:
			continue
		if hard == worst_hard and deficit <= worst_deficit:
			continue
		worst_deficit = deficit
		worst_hard = hard
		worst = {breached = true, hard = hard, deficit = deficit,
			distance = d, position = c.position}
	return worst


func _screen_report(server: GameServer, anchor_pos: Vector3, station_dist: float) -> Dictionary:
	## What is left of the line this carrier stands behind.
	##
	## `strength` counts only the mates actually screening THIS hull: alive, not
	## another carrier, near enough to matter, and nearer the contact than we
	## are — that is, in front of us right now. Deliberately measured against
	## where this ship IS and not against the station it is thinking about
	## taking: a test that referred to the decision it feeds would flip the
	## answer every time the decision changed, and the hull would hunt in and out
	## forever. Health is part of the tally because a burning destroyer at a
	## tenth of its hit points is not a screen, it is a casualty that has not
	## sunk yet.
	##
	## `line_dist` is where that screen is standing, as its weighted mean
	## distance from the contact. A carrier only closes from behind its own line,
	## so this — not the air group's preference — is what says how far in the
	## hull may come. As escorts die the mean falls back, and the carrier falls
	## back with it without anything having to notice that anyone died.
	##
	## `nearby` is the same tally without the in-front test: every mate within
	## reach of us, wherever it is standing. That is the figure the collapse
	## detection below watches, and the distinction matters. `strength` moves
	## whenever this hull does — closing past an escort takes it out of the
	## count — so a drop in it says nothing about whether anything has happened.
	## `nearby` only falls when mates die, are shot down to nothing, or steam off
	## somewhere else, which is exactly the event worth reacting to.
	##
	## `rally` is the centre of every surviving mate whether or not it screens us
	## right now, because that is where the carrier has to get back to once the
	## ones in front of it have gone.
	var radius: float = maxf(SCREEN_RADIUS_MIN, station_dist)
	var my_dist: float = _ship.global_position.distance_to(anchor_pos)
	var strength: float = 0.0
	var nearby: float = 0.0
	var count: int = 0
	var line_dist: float = 0.0
	var rally: Vector3 = Vector3.ZERO
	var rally_weight: float = 0.0
	for mate in server.get_team_ships(_ship.team.team_id):
		if mate == _ship or not is_instance_valid(mate):
			continue
		if not mate.health_controller.is_alive() or mate.ship_class == Ship.ShipClass.CV:
			continue
		var hp: float = clampf(
			mate.health_controller.current_hp / maxf(mate.health_controller.max_hp, 1.0),
			0.0, 1.0)
		var weight: float = float(SCREEN_CLASS_WEIGHT.get(mate.ship_class, 1.0)) * hp
		rally += mate.global_position * weight
		rally_weight += weight
		if _ship.global_position.distance_to(mate.global_position) > radius:
			continue
		nearby += weight
		var mate_dist: float = mate.global_position.distance_to(anchor_pos)
		if mate_dist >= my_dist:
			continue
		strength += weight
		line_dist += mate_dist * weight
		count += 1
	var has_rally: bool = rally_weight > 0.0001
	if has_rally:
		rally /= rally_weight
		rally.y = 0.0
	if strength > 0.0001:
		line_dist /= strength
	return {
		strength = strength,
		nearby = nearby,
		count = count,
		line_dist = line_dist,
		rally = rally,
		has_rally = has_rally,
	}


func _update_screen(report: Dictionary) -> bool:
	## Tracks the company this carrier is keeping against a slowly-following
	## reference, so that the difference between "the line is wearing down" and
	## "the line just broke" is a fact the hull can steer on rather than
	## something re-derived from a threshold every tick. Returns true while the
	## latter is in force.
	##
	## Watches report.nearby rather than report.strength: the question here is
	## whether anything HAPPENED, and only the position-independent tally can
	## answer it. See _screen_report.
	var now: int = Time.get_ticks_msec()
	var strength: float = float(report.nearby)
	_screen_strength = float(report.strength)
	_screen_nearby = strength
	var dt: float = 0.0
	if _screen_sample_ms > 0:
		dt = clampf(float(now - _screen_sample_ms) / 1000.0, 0.0, 1.0)
	_screen_sample_ms = now
	if _screen_reference < 0.0:
		_screen_reference = strength
	elif strength >= _screen_reference:
		# Reinforcements, or we have worked our way back into position. Adopt at
		# once: a screen that is there is there.
		_screen_reference = strength
	elif strength < _screen_reference * (1.0 - SCREEN_LOSS_FRACTION):
		# Ships that were keeping us company have stopped doing so, all at once.
		# Take the new figure as the reference immediately so the same loss
		# cannot fire twice.
		_screen_shock_until_ms = now + SCREEN_SHOCK_MS
		_screen_reference = strength
	else:
		_screen_reference = maxf(strength, _screen_reference - SCREEN_REFERENCE_DECAY * dt)
	return now < _screen_shock_until_ms


func _station_point(anchor_pos: Vector3, dist: float, opts: Dictionary = {}) -> Vector3:
	## The point at `dist` from the contact along the bearing we already hold —
	## the carrier slides in and out along its own radius rather than taking a
	## new line that would walk it across the enemy's front.
	##
	## `opts` may ease that bearing around the radius. Every option here is a
	## BEARING change at a fixed distance, which is why they can be considered
	## one after another at all: the standoff the air group needs is never the
	## thing being traded. In priority order:
	##
	##   regroup   — swing toward `rally`, the centre of the mates still alive.
	##               Outranks everything else, because a station nothing is
	##               standing in front of any more is the wrong station whatever
	##               angle it offers the strike.
	##   work_beam — swing toward the contact's beam. An attack run is clamped to
	##               MAX_ATTACK_ANGLE either side of the carrier-to-target line,
	##               so a beam-on drop — the one that crosses the target's whole
	##               length instead of its width — is available only from off the
	##               target's beam. The air group waits at its rally for that
	##               presentation (see Behavior._wait_for_broadside); this is the
	##               half of the arrangement that goes and gets it rather than
	##               hoping the target obliges.
	##   avoid     — swing off any contact the resulting point would sit inside
	##               the detection bubble of. Applied last and on top of whatever
	##               the others chose, because being found undoes both of them.
	##
	## Every swing is bounded and always the short way round, so the carrier
	## eases along its arc over successive ticks instead of setting a course
	## across the enemy's front to reach the ideal point in one leg.
	var away: Vector3 = _ship.global_position - anchor_pos
	away.y = 0.0
	if away.length_squared() < 1.0:
		away = _cached_safe_dir
		away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3(0.0, 0.0, 1.0)
	away = away.normalized()
	_beam_work_active = false
	if bool(opts.get("regroup", false)):
		var rally: Vector3 = opts.get("rally", Vector3.ZERO)
		away = _bias_toward(away, rally - anchor_pos, REGROUP_MAX_BIAS, REGROUP_DEAD_ZONE)
	elif bool(opts.get("work_beam", false)):
		away = _bias_toward_beam(away, opts.get("beam", Basis.IDENTITY))
	var avoid: Array = opts.get("avoid", [])
	if not avoid.is_empty():
		away = _bias_off_contacts(away, anchor_pos, dist, avoid, float(opts.get("keepout", 0.0)))
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

## Widest the station bearing may be swung in one decision to get back around
## toward the surviving line, and the slop inside which it is already there.
## Larger than the beam swing: this one is answering something that has actually
## happened rather than optimising a drop angle.
const REGROUP_MAX_BIAS: float = deg_to_rad(35.0)
const REGROUP_DEAD_ZONE: float = deg_to_rad(10.0)
## Widest the station bearing may be swung in one decision to get out from in
## front of a contact whose bubble the station would otherwise sit in.
const BUBBLE_MAX_BIAS: float = deg_to_rad(25.0)


## Set while the station bearing is actually being swung, purely so the debug
## readout distinguishes a carrier working onto the beam from one parked on
## station — the two look identical by distance alone, which is what the skill
## name is otherwise derived from.
var _beam_work_active: bool = false


func _bias_toward(away: Vector3, toward: Vector3, max_bias: float, dead_zone: float) -> Vector3:
	## Eases the standoff bearing toward `toward`, the short way round and by at
	## most `max_bias`. Inside `dead_zone` the bearing is left exactly as it is,
	## so the hull settles instead of hunting either side of the ideal.
	var ideal: Vector3 = Vector3(toward.x, 0.0, toward.z)
	if ideal.length_squared() < 1.0:
		return away
	ideal = ideal.normalized()
	var offset: float = away.signed_angle_to(ideal, Vector3.UP)
	if absf(offset) <= dead_zone:
		return away
	return away.rotated(Vector3.UP, clampf(offset, -max_bias, max_bias))


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
	var biased: Vector3 = _bias_toward(away, ideal, BEAM_WORK_MAX_BIAS, BEAM_WORK_DEAD_ZONE)
	if not biased.is_equal_approx(away):
		_beam_work_active = true
	return biased


func _bias_off_contacts(away: Vector3, anchor_pos: Vector3, dist: float,
		contacts: Array, keepout: float) -> Vector3:
	## Swings the station off the bearing of whatever it would otherwise be
	## standing too close to. Walking round the ring costs the strike nothing —
	## the distance to the contact the air group is working does not change — so
	## a soft contact is answered here rather than by giving up the station.
	## A hard one inside the bubble never reaches this: it has already sent the
	## hull down the break-away path.
	if keepout <= 0.0:
		return away
	var breach: Dictionary = _conceal_breach(contacts, anchor_pos + away * dist, keepout)
	if not bool(breach.get("breached", false)):
		return away
	var to_contact: Vector3 = Vector3(breach.position.x - anchor_pos.x, 0.0,
		breach.position.z - anchor_pos.z)
	if to_contact.length_squared() < 1.0:
		# The intruder is sitting on the anchor itself. No bearing on this ring
		# is any further from it than any other, so leave the bearing alone and
		# let the standoff distance be the only thing answering.
		return away
	var offset: float = away.signed_angle_to(to_contact.normalized(), Vector3.UP)
	# Scaled to how much clearance is actually missing, so that sitting a metre
	# inside the boundary is answered with a nudge rather than with the full
	# swing — otherwise the hull would throw a three-kilometre leg to fix a
	# rounding error and be back the next tick.
	var swing: float = BUBBLE_MAX_BIAS * clampf(float(breach.deficit) / keepout, 0.15, 1.0)
	# Turn the opposite way to the contact, whichever way that is — and if it is
	# dead ahead on our own bearing, either way is as good.
	if not is_zero_approx(offset):
		swing = -signf(offset) * swing
	return away.rotated(Vector3.UP, swing)


func _update_exposure(ship: Ship) -> bool:
	## Detection flickers as islands and spotters come and go; the withdrawal it
	## triggers must not, or the carrier ends up oscillating on the spot instead
	## of actually opening the range.
	if ship.is_detected() or not active_shooters_at_me.is_empty():
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

	# The guns are a liability, not an asset: firing blooms, and bloom is what
	# gets a carrier seen. Fire only when concealment is already lost anyway.
	wants_to_be_concealed = _probe_concealment(server)
	_suppress_guns = wants_to_be_concealed

	var previous_skill: StringName = _active_skill_name
	var exposed: bool = _update_exposure(ship)
	var anchor: Dictionary = _strike_anchor(server)
	var band: Dictionary = _standoff_band(server)

	# Who is inside the bubble, and what is left of the line in front of us.
	# Both are worked out before any branch below, because both have to be
	# tracked continuously: a screen tally sampled only on the ticks the carrier
	# happens to be on station would read every interruption as a collapse the
	# moment it resumed.
	var keepout: float = _conceal_keepout()
	var contacts: Array = _conceal_contacts(server)
	var breach: Dictionary = _conceal_breach(contacts, ship.global_position, keepout)
	var screen_ref: Vector3 = _get_positioning_danger_center()
	if bool(anchor.get("valid", false)):
		screen_ref = anchor.position
	var screen: Dictionary = _screen_report(server, screen_ref, float(band.close_dist))
	var collapsing: bool = _update_screen(screen)

	# Cover is wanted purely for concealment, never as a firing position, so the
	# search runs with prioritize_cover and is allowed to consider islands right
	# out to the edge of gun range rather than the 0.7 default.
	var cover_params: Dictionary = {"max_range": 1.0}
	# Passed to every station decision below: whatever else a position is chosen
	# for, it is not worth standing on if something can see us from it.
	var station_opts: Dictionary = {avoid = contacts, keepout = keepout}

	var intent: NavIntent = null

	# ── Break away ──────────────────────────────────────────────────────────
	# Something is close enough that the air group has stopped being the
	# question. Checked ahead of everything else, including whether there is a
	# contact worth stationing against at all: a strike can be re-planned from
	# anywhere, the ship cannot.
	var breakaway: Dictionary = _break_trigger(anchor, band, breach, keepout)
	if not breakaway.is_empty():
		return _finish_intent(
			_break_away(ctx, cover_params, breakaway, station_opts), previous_skill)

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

	# ── Station on the strike ring ──────────────────────────────────────────
	# Close only while unseen and screened. A screen that has just broken counts
	# as neither: the ships that were in front of us are gone or going, and
	# whatever the picture looks like this instant it is about to get worse.
	var screened: bool = float(screen.strength) >= SCREEN_MIN_STRENGTH
	var regroup: bool = collapsing and bool(screen.has_rally)
	var defensive: bool = exposed or collapsing or not screened
	var hold_dist: float = float(band.safe_dist) if defensive else float(band.close_dist)
	# And never in front of the line itself, whatever the air group would gain by
	# it. This is the continuous half of the same idea the collapse handling
	# below does discretely: as the ships ahead are sunk or driven back, the mean
	# they are standing at falls back, and this hull's station falls back with
	# it. Capped at the outer band, past which even the bombers cannot reach and
	# there would be nothing left to protect.
	if int(screen.count) > 0:
		hold_dist = minf(maxf(hold_dist, float(screen.line_dist)), float(band.outer))
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
	var cover_band: Dictionary = {
		anchor = anchor_pos,
		min = cover_min,
		max = hold_dist * COVER_BAND_SLACK,
	}
	# With the line in front of us broken, an island is only cover if it is on
	# the same side of the map as what is left of that line. Terrain that masks
	# this hull from the contact it is stationed off is still the wrong place to
	# be when reaching it means sitting alone on the flank that just emptied.
	if regroup:
		cover_band["rally"] = screen.rally
	intent = _take_cover(ctx, cover_params, cover_band)
	if intent == null:
		# Working onto the beam is only ever done while unseen and screened, and
		# only against a contact somebody is actually watching. Once we are
		# exposed the hull's job is distance, not a better firing angle for the
		# air group; and a heading frozen on a last-known position is not one
		# there is any point manoeuvring against, since it cannot be seen to
		# change.
		var opts: Dictionary = station_opts.duplicate()
		opts["beam"] = anchor_beam
		opts["work_beam"] = not defensive and bool(anchor.get("live", false))
		if regroup:
			opts["regroup"] = true
			opts["rally"] = screen.rally
		intent = _station_intent(ctx, anchor_pos, _station_point(anchor_pos, target_dist, opts))
		if regroup:
			# The line broke; crossing back behind what is left of it is not a
			# leg to make at cruising speed, and the ships that used to be in the
			# way are the reason there is time to make it at all.
			intent.throttle_override = 3
			_active_skill_name = &"Regroup"
		elif _beam_work_active:
			_active_skill_name = &"WorkBeam"
		elif target_dist < anchor_dist - 1.0:
			_active_skill_name = &"Close"
		elif target_dist > anchor_dist + 1.0:
			_active_skill_name = &"Withdraw"
		else:
			_active_skill_name = &"Station"

	return _finish_intent(intent, previous_skill)


func _break_trigger(anchor: Dictionary, band: Dictionary, breach: Dictionary,
		keepout: float) -> Dictionary:
	## Whether anything has got close enough that the air group stops mattering,
	## and if so what to open the range from and how much of it is wanted.
	## Returns {position, cover_min, station_dist}, or empty for "carry on".
	##
	## Three triggers, ranked by how much room is actually missing rather than by
	## which happens to be tested first:
	##
	##   a hard contact inside the detection bubble — the carrier has been found,
	##     or is one line of sight away from it. Usually NOT the contact the air
	##     group is working: it is the destroyer nobody screened out;
	##   the strike anchor inside the hard floor — the brawl envelope, where a
	##     carrier is a large unarmoured cruiser with no guns worth the name;
	##   anyone actually shooting at us, which settles it on its own.
	var best: Dictionary = {}
	var best_deficit: float = 0.0
	if bool(breach.get("hard", false)):
		best_deficit = float(breach.deficit)
		best = {
			position = breach.position,
			cover_min = keepout,
			station_dist = keepout * BREAK_CLEARANCE,
		}
	if bool(anchor.get("valid", false)):
		var floor_deficit: float = float(band.min_dist) - float(anchor.distance)
		if floor_deficit > best_deficit:
			best_deficit = floor_deficit
			best = {
				position = anchor.position,
				cover_min = float(band.min_dist),
				station_dist = float(band.safe_dist),
			}
	if not best.is_empty() or active_shooters_at_me.is_empty():
		return best
	# Under fire from something neither test caught: a contact we are not holding
	# at all, or one outside the bubble that can still reach us. Open from
	# whatever we do know about — being shot at is not a thing to stand and think
	# about — and failing even that, carry on, because a retreat needs a bearing.
	var nearest: Dictionary = _get_nearest_enemy()
	if not nearest.is_empty():
		return {
			position = nearest.position,
			cover_min = keepout,
			station_dist = maxf(keepout * BREAK_CLEARANCE, float(band.safe_dist)),
		}
	if bool(anchor.get("valid", false)):
		return {
			position = anchor.position,
			cover_min = float(band.min_dist),
			station_dist = float(band.safe_dist),
		}
	return {}


func _break_away(ctx: SkillContext, cover_params: Dictionary, plan: Dictionary,
		station_opts: Dictionary = {}) -> NavIntent:
	## Open the range from plan.position by whatever means is to hand: cover
	## already far enough out, else a straight run away from the nearest enemy,
	## else a station on the far side of the ring. Nothing here weighs the air
	## group — that trade was made by whatever decided to break.
	var from_pos: Vector3 = plan.position
	var intent: NavIntent = _take_cover(ctx, cover_params,
		{anchor = from_pos, min = float(plan.cover_min)})
	if intent == null and not _get_nearest_enemy().is_empty():
		intent = _skill_retreat.execute(ctx, {})
		if intent != null:
			intent.throttle_override = 4
			_active_skill_name = &"Retreat"
	if intent == null:
		intent = _station_intent(ctx, from_pos,
			_station_point(from_pos, float(plan.station_dist), station_opts))
		_active_skill_name = &"Withdraw"
	return intent


func _take_cover(ctx: SkillContext, cover_params: Dictionary, band: Dictionary = {}) -> NavIntent:
	## Cover, accepted only when it also happens to be a place a carrier should
	## be standing. Passing no band takes whatever cover is nearest; passing one
	## rejects an island that would drag the hull inside the floor, out past
	## where its squadrons still reach, or further from the mates it is trying to
	## get back behind. `band` keys: anchor, min, max, rally — all optional.
	var cover: NavIntent = _skill_cover.execute(ctx, cover_params, true)
	if cover == null:
		return null
	if not band.is_empty():
		var anchor_pos: Vector3 = band.get("anchor", Vector3.ZERO)
		var min_dist: float = float(band.get("min", -1.0))
		var max_dist: float = float(band.get("max", -1.0))
		var d: float = anchor_pos.distance_to(cover.target_position)
		if min_dist >= 0.0 and d < min_dist:
			return null
		if max_dist >= 0.0 and d > max_dist:
			return null
		if band.has("rally"):
			var rally: Vector3 = band.rally
			if rally.distance_to(cover.target_position) > rally.distance_to(_ship.global_position):
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


func get_debug_skill_info() -> Dictionary:
	## The two numbers that explain a carrier standing further out than its
	## squadron reach would suggest: what its screen is currently worth against
	## what it was worth recently, and whether anything is inside the bubble.
	var info: Dictionary = super()
	info["screen"] = "%.1f in front, %.1f/%.1f near" % [
		_screen_strength, _screen_nearby, maxf(_screen_reference, 0.0)]
	if Time.get_ticks_msec() < _screen_shock_until_ms:
		info["screen"] = String(info["screen"]) + " broken"
	return info
