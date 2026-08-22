extends RefCounted
class_name EnemyPresumption

## Where the enemy probably is, for the ships nobody currently has a fix on.
##
## A human reading the minimap does not think "there is one enemy and it is at
## the only place I can see one". They think "their line came off that spawn,
## something is off my flank by now, and nothing has come round the north island
## yet". Bots had none of that: an enemy that had never been spotted did not
## exist at all, so a cruiser would take cover from the single contact it could
## see while sitting broadside to the half of the map it had never looked at.
##
## This builds the missing half of the picture out of things the whole lobby
## already has - the spawn positions, the clock, and the enemy team list - plus
## whatever the team has actually observed. It never reads a live enemy position.
##
## It is also where everything the team has DEDUCED rather than seen ends up.
## Bloom with nothing in sight means someone concealed has line of sight to us; a
## torpedo wake means someone was back along that bearing a while ago. Both used
## to be written into the last-known-position tables, which made them
## indistinguishable from sightings and let bots put salvos onto ships they had
## merely inferred. They now arrive here instead, as anchors carrying their own
## uncertainty radius (GameServer.record_inferred_contact), which keeps them in
## the positioning picture and out of reach of anything that fires.
##
## `server` is left untyped on purpose. GameServer publishes this same picture
## into the shared threat registry, so naming the type here would make the two
## scripts reference each other and leave the parser resolving a cycle.
##
## What comes out is deliberately coarse: a position, and a radius saying how
## wrong it might be. It is for POSITIONING ONLY - cover, standoff, where to
## send a search. Nothing here may pick a target or aim a weapon. A guess is not
## a contact, and ordnance is only ever committed against something the team is
## genuinely holding (see Behavior._contact_is_strikeable).

## Flank speed of a nominal ship in world units, derived rather than guessed so
## that everything below stays expressed as a FRACTION of how fast ships
## actually move. The previous hard-coded 30.0 m/s was written when it was well
## under flank; the speed scale was retuned since and it quietly became 97% of
## it, which had bots presuming the enemy line had come almost twice as far as it
## could have. Tying it to the modifier means that cannot happen silently again.
const NOMINAL_FLANK_SPEED: float = 30.0 * 0.514444 * ShipMovementV4.SHIP_SPEED_MODIFIER

## How fast a fleet is presumed to advance out of its spawn. Well under flank: a
## line advances at the pace of its slowest, angling and turning the whole way,
## and stops entirely once the shooting starts. With the per-class multipliers
## below even the destroyers stay under what a ship could actually do.
const ADVANCE_SPEED: float = NOMINAL_FLANK_SPEED * 0.5
## The advance stops here - fleets settle at roughly a gun range apart and trade
## rather than steaming into each other, so nobody is presumed to be past the
## point where that would have happened.
const ENGAGEMENT_GAP: float = 16000.0
## Half-width of the front the enemy line is presumed to be spread across. Not
## the map width: fleets converge on the middle, they do not hug the edges.
const LINE_HALF_WIDTH: float = 9000.0

## Uncertainty, as a radius around the presumed position: where it starts, how
## fast it grows with time since anything was actually observed, and the point
## past which "somewhere over there" stops getting any vaguer.
const RADIUS_MIN: float = 1500.0
## Half of flank. The along-axis part of an unseen ship's motion is already
## modelled by _advance, so what is left to be uncertain about is the lateral
## wandering and the decisions nobody watched it make. At 6.0 m/s this took
## nearly 21 minutes to reach RADIUS_MAX - longer than a match runs
## (GameServer.MATCH_DURATION), so the error bar never really opened and bots
## treated pure guesses as near-sightings all game. It now saturates in about
## eight minutes.
const RADIUS_GROWTH: float = NOMINAL_FLANK_SPEED * 0.5
const RADIUS_MAX: float = 9000.0

## How long a course observed on a particular ship stays worth projecting along.
## Past this the heading tells you nothing a fleet-wide advance does not already
## say, and the projection falls all the way back to the spawn-axis model. A
## course is only trusted in proportion to how recently it was seen AND how far
## forward it is being run: both are staleness, and both are counted.
const KINEMATIC_TRUST_HORIZON: float = 90.0
## Ceiling on an observed velocity before it is projected. Guards against a
## collision or a physics spike being extrapolated into a contact halfway across
## the map.
const KINEMATIC_SPEED_CAP: float = NOMINAL_FLANK_SPEED * 1.5

## Error bar on a ground-truth intuition fix. Larger than RADIUS_MIN on purpose:
## a bot that periodically just knows should still be working from a read of the
## battle rather than from a live feed, so even a fresh fix is a position with
## slop in it. See BotAptitude.intuition_interval.
const INTUITION_RADIUS_MIN: float = 2000.0

# ---------------------------------------------------------------------------
# Per-owner tuning. The server's team-wide instances keep the defaults - shared
# intel cannot vary by who is asking - while each bot's own instance takes these
# from its aptitude (see Behavior.get_presumed_contacts).
# ---------------------------------------------------------------------------

## Whether to believe in ships nobody has ever seen. Off, this model produces
## nothing for a ship with no observation and no deduction behind it.
var use_spawn_line: bool = true
## Multiplier on how fast uncertainty opens up.
var radius_growth_mult: float = 1.0
## Whether to project a contact along its own last-observed course rather than
## along the fleet's spawn axis.
var kinematic_reckoning: bool = false
## Ground-truth fixes this owner has taken, Ship -> {position, velocity,
## rotation, time}. Owned and refreshed by the Behavior; read here as the
## highest-grade anchor available. Never consulted by anything that fires.
var intuition: Dictionary = {}


## Applies per-owner tuning, dropping any cached picture built under different
## settings. Cheap enough to call every time the picture is asked for.
func configure(p_use_spawn_line: bool, p_radius_growth_mult: float,
		p_kinematic_reckoning: bool, p_intuition: Dictionary = {}) -> void:
	if (use_spawn_line == p_use_spawn_line
			and is_equal_approx(radius_growth_mult, p_radius_growth_mult)
			and kinematic_reckoning == p_kinematic_reckoning):
		intuition = p_intuition
		return
	use_spawn_line = p_use_spawn_line
	radius_growth_mult = p_radius_growth_mult
	kinematic_reckoning = p_kinematic_reckoning
	intuition = p_intuition
	_cache_frame = -1
	_lead_cache_frame = -1

# Geometry of this battle, resolved once: the spawn axis everything is measured
# along, its perpendicular, and how far up it a fleet is presumed to come.
var _ready_geometry: bool = false
var _enemy_spawn: Vector3 = Vector3.ZERO
var _axis: Vector3 = Vector3.ZERO
var _lateral: Vector3 = Vector3.ZERO
var _max_advance: float = 0.0

# One build per physics frame is plenty - several systems ask per tick.
var _cache: Array[Dictionary] = []
var _cache_frame: int = -1
# Lead projections get a slot of their own, keyed by the horizon asked for. A
# caller that wants the picture N seconds out generally wants it several times
# in the same frame, and rebuilding the whole roster for each of those is pure
# waste. One slot is enough: horizons vary between callers, not within one.
var _lead_cache: Array[Dictionary] = []
var _lead_cache_frame: int = -1
var _lead_cache_value: float = -1.0


## Every enemy `my_team` is not holding right now, as
## {ship, position, radius, advance_mult}. One instance serves one team - the
## per-frame cache does not distinguish them. `lead` projects the whole picture
## that many seconds further on, for deciding where something should be SENT
## rather than where it is now.
func contacts(my_team: int, server, lead: float = 0.0) -> Array[Dictionary]:
	if server == null:
		return []
	var frame: int = Engine.get_physics_frames()
	if lead <= 0.0:
		if _cache_frame == frame:
			return _cache
	elif _lead_cache_frame == frame and is_equal_approx(_lead_cache_value, lead):
		return _lead_cache

	var enemy_team: int = 1 - my_team
	if not _resolve_geometry(server, my_team, enemy_team):
		return []

	var roster: Array = server.get_team_ships(enemy_team)
	var lkp: Dictionary = server.get_unspotted_enemies(my_team)
	var times: Dictionary = server.get_unspotted_enemy_times(my_team)
	var vels: Dictionary = server.get_unspotted_enemy_velocities(my_team)
	var inferences: Dictionary = server.get_inferred_contacts(my_team)
	var now: float = Time.get_ticks_msec() / 1000.0
	var out: Array[Dictionary] = []

	for i in range(roster.size()):
		var enemy: Ship = roster[i]
		if not is_instance_valid(enemy) or not enemy.is_alive():
			continue
		# Held for real: there is nothing to presume about a ship the team can
		# see, and a guess must never displace an observation.
		if enemy.visible_to_enemy:
			continue
		# Grades of anchor, all of which say "it was HERE at THIS time": a
		# ground-truth fix this bot took, somewhere it was actually seen, and
		# somewhere it has been deduced to be. The most recent of whichever exist
		# wins outright - a bloom deduction made this instant says more than a
		# sighting from a minute ago, and a sighting from two seconds ago says
		# more than a torpedo launch point from a minute back. Failing all three
		# there is the station in the line its fleet is presumed to have advanced
		# in, which is a guess about the whole fleet rather than about this ship.
		var anchor: Vector3
		var age: float
		var base_radius: float = RADIUS_MIN
		var anchor_vel: Vector3 = Vector3.ZERO
		var best_time: float = -INF

		var fix: Dictionary = intuition.get(enemy, {})
		if not fix.is_empty():
			best_time = float(fix.get("time", -INF))
			anchor = fix.position
			age = maxf(now - best_time, 0.0)
			base_radius = INTUITION_RADIUS_MIN
			anchor_vel = fix.get("velocity", Vector3.ZERO)

		if lkp.has(enemy):
			# Last seen somewhere specific. That still says which flank it is
			# on, however old it is - the guess is how much further along it has
			# got since, not a fresh position.
			var lkp_time: float = float(times.get(enemy, now))
			if lkp_time > best_time:
				best_time = lkp_time
				anchor = lkp[enemy]
				age = maxf(now - lkp_time, 0.0)
				base_radius = RADIUS_MIN
				anchor_vel = vels.get(enemy, Vector3.ZERO)

		var inferred: Dictionary = inferences.get(enemy, {})
		if not inferred.is_empty():
			# Worked out rather than seen. The position is only as good as the
			# error bar whoever deduced it recorded alongside it, so that becomes
			# the floor the usual staleness growth builds on top of. A deduction
			# establishes a place, never a course, so it carries no velocity.
			var inferred_time: float = float(inferred.get("time", -INF))
			if inferred_time > best_time:
				best_time = inferred_time
				anchor = inferred.position
				age = maxf(now - inferred_time, 0.0)
				base_radius = maxf(RADIUS_MIN, float(inferred.get("radius", RADIUS_MIN)))
				anchor_vel = Vector3.ZERO

		if best_time == -INF:
			# Nothing observed, deduced or known about this ship at all.
			if not use_spawn_line:
				# This owner does not believe in ships nobody has seen. It will
				# sail broadside to a flank nobody has looked at, which is what
				# the bottom of the aptitude range is supposed to look like.
				continue
			# Everything known about it is that it came off their spawn, so it is
			# placed in the line abreast of its fleet and advanced with it (see
			# _line_station).
			anchor = _line_station(i, roster.size())
			age = server.match_elapsed

		var elapsed: float = age + lead
		var mult: float = _advance_mult(enemy)
		out.append({
			ship = enemy,
			position = _project_anchor(anchor, anchor_vel, elapsed, mult),
			radius = clampf(base_radius + elapsed * RADIUS_GROWTH * radius_growth_mult,
				RADIUS_MIN, RADIUS_MAX),
			advance_mult = mult,
			velocity = anchor_vel,
			age = elapsed,
		})

	if lead <= 0.0:
		_cache = out
		_cache_frame = frame
	else:
		_lead_cache = out
		_lead_cache_frame = frame
		_lead_cache_value = lead
	return out


## How well pinned down a presumption is, 0 (a rumour) to 1 (as good as a
## sighting), from its own uncertainty radius. Consumers map this onto whatever
## scale they work in - how hard to route around it, how much to fear it.
static func certainty(guess: Dictionary) -> float:
	var span: float = RADIUS_MAX - RADIUS_MIN
	if span <= 0.0:
		return 1.0
	return clampf(1.0 - (float(guess.radius) - RADIUS_MIN) / span, 0.0, 1.0)


## Runs one presumed contact further forward - for asking where a ship will be
## by the time something sent after it actually arrives.
func project(guess: Dictionary, seconds: float) -> Vector3:
	if not _ready_geometry or seconds <= 0.0:
		return guess.position
	# `age` is how stale the guess already was, so trust in its course has to be
	# judged from where it has got to, not from a fresh zero.
	var already: float = float(guess.get("age", 0.0))
	var moved: Vector3 = _project_anchor(guess.position, guess.get("velocity", Vector3.ZERO),
		already + seconds, float(guess.get("advance_mult", 1.0)))
	if already <= 0.0:
		return moved
	# _project_anchor measures from the anchor, so re-running it over the full
	# span would double-count what the guess had already travelled. Take only the
	# part added by `seconds`.
	var from_anchor: Vector3 = _project_anchor(guess.position, guess.get("velocity", Vector3.ZERO),
		already, float(guess.get("advance_mult", 1.0)))
	return _clamp_to_map(guess.position + (moved - from_anchor))


## Runs an anchor forward, blending the two things that can be said about where a
## ship went: what its own fleet is doing, and what IT was doing when somebody
## last looked.
##
## The fleet model (_advance) is all a coarse picture can offer - it says the
## enemy line has come so far up the axis, which is true of the line and only
## roughly true of any ship in it. An observed course says something much sharper
## and much more perishable: that THIS cruiser was pushing THIS way. That is the
## difference between "the enemy is somewhere ahead" and "that one is coming
## round the island at me in thirty seconds", and it is what makes a ship worth
## finding cover from before it arrives rather than after.
##
## Trust in the course decays over KINEMATIC_TRUST_HORIZON and is measured
## against `seconds`, which already carries both halves of the staleness: how
## long ago the course was seen, and how far forward it is being run. Fully
## decayed, this is exactly the fleet model again.
##
## Unlike the fleet advance this is NOT capped at the engagement line. A ship
## observed pushing is a ship that may well push past where the lines would
## otherwise have settled - refusing to project that is refusing to see the very
## thing the course was worth reading for.
func _project_anchor(anchor: Vector3, observed_vel: Vector3, seconds: float, mult: float) -> Vector3:
	var axis_pos: Vector3 = _advance(anchor, seconds, mult)
	if not kinematic_reckoning:
		return axis_pos
	var vel: Vector3 = Vector3(observed_vel.x, 0.0, observed_vel.z)
	var speed: float = vel.length()
	if speed < 1.0:
		return axis_pos
	if speed > KINEMATIC_SPEED_CAP:
		vel = vel / speed * KINEMATIC_SPEED_CAP
	var trust: float = clampf(1.0 - seconds / KINEMATIC_TRUST_HORIZON, 0.0, 1.0)
	if trust <= 0.0:
		return axis_pos
	var kinematic_pos: Vector3 = _clamp_to_map(anchor + vel * maxf(seconds, 0.0))
	return _clamp_to_map(axis_pos.lerp(kinematic_pos, trust))


## Advances `anchor` along the spawn axis by however far a fleet could have come
## in `seconds`, never past the line where the two sides would have met.
func _advance(anchor: Vector3, seconds: float, mult: float) -> Vector3:
	var travelled: float = (anchor - _enemy_spawn).dot(_axis)
	var room: float = maxf(_max_advance - travelled, 0.0)
	var step: float = minf(maxf(seconds, 0.0) * ADVANCE_SPEED * mult, room)
	return _clamp_to_map(anchor + _axis * step)


## Where in the enemy line a ship nobody has ever seen is presumed to sit. Spread
## evenly across the front by roster order, which is the same list for every bot
## on the team, so they all picture the same enemy line rather than each
## inventing its own.
func _line_station(index: int, count: int) -> Vector3:
	var offset: float = 0.0
	if count > 1:
		offset = (float(index) / float(count - 1) - 0.5) * 2.0 * LINE_HALF_WIDTH
	return _clamp_to_map(_enemy_spawn + _lateral * offset)


## How far up the advance each class is presumed to have pushed. Destroyers lead,
## battleships come along behind their screen, and a carrier has barely left the
## line it spawned on.
static func _advance_mult(enemy: Ship) -> float:
	match enemy.ship_class:
		Ship.ShipClass.DD:
			return 1.3
		Ship.ShipClass.CA:
			return 1.0
		Ship.ShipClass.BB:
			return 0.85
		Ship.ShipClass.CV:
			return 0.25
	return 1.0


static func _clamp_to_map(pos: Vector3) -> Vector3:
	return Vector3(
		clampf(pos.x, -Ship.MAP_BOUNDARY, Ship.MAP_BOUNDARY),
		0.0,
		clampf(pos.z, -Ship.MAP_BOUNDARY, Ship.MAP_BOUNDARY))


func _resolve_geometry(server, my_team: int, enemy_team: int) -> bool:
	if _ready_geometry:
		return true
	var friendly_spawn: Vector3 = server.get_team_spawn_position(my_team)
	_enemy_spawn = server.get_team_spawn_position(enemy_team)
	if friendly_spawn == Vector3.ZERO and _enemy_spawn == Vector3.ZERO:
		return false
	var span: Vector3 = friendly_spawn - _enemy_spawn
	span.y = 0.0
	if span.length_squared() < 1.0:
		return false
	_enemy_spawn.y = 0.0
	_axis = span.normalized()
	_lateral = Vector3(-_axis.z, 0.0, _axis.x)
	_max_advance = maxf((span.length() - ENGAGEMENT_GAP) * 0.5, 0.0)
	_ready_geometry = true
	return true
