class_name SkillSpot
extends BotSkill

## Reveal enemies for teammates while staying concealed.
##
## Phase 1 — Spotted enemies exist:
##   Generate a ring of candidate positions around the spotted-enemy centroid.
##   Score each candidate by how many enemies it keeps detected, how well it
##   preserves our own concealment, and how close it is to our current position.
##
## Phase 2 — Nothing is spotted:
##   Approach the nearest unspotted enemy (within pursuit range) to the
##   sweet-spot distance so we can light them up.

const CANDIDATE_COUNT := 16

## True when the last execute() found a standoff that spots the enemy without
## exposing us, false when it had to accept being seen to make vision. Read by
## the behavior to decide whether stealth routing is even achievable — asking
## the navigator to avoid detection zones while sending it to a destination
## inside one produces an unreachable goal.  Mirrors SkillFindCover.can_shoot.
var stealth_corridor: bool = true

## Fraction of enemy concealment radius to stay inside (detection margin).
const SPOT_MARGIN            := 1.0
## How far outside our own concealment radius to sit, as a multiple of it.
## Since the ring is placed at exactly this distance, this constant IS the
## spotting standoff: 1.0 would ride the detection boundary itself, and the
## margin above 1.0 is the cushion that absorbs a contact closing on us, our
## own bloom, and the error in a presumed contact's position.  Keep it small —
## every metre of cushion is a metre further from the enemy than we need to be.
const SAFE_MARGIN            := 1.15

## How many times our own concealment radius we're willing to travel to reach
## an unspotted enemy.  Keeps ships from hunting targets across the whole map.
## Overridable via params key "max_target_distance".
const MAX_TARGET_DIST_FACTOR := 5.0

## Scoring weights — must sum to 1.0.
const W_COVERAGE := 0.45   # how many spotted enemies are kept detected
const W_STEALTH  := 0.30   # how well we stay hidden from all enemies
const W_DISTANCE := 0.25   # prefer candidates closer to our current position

# ── Station commitment ──────────────────────────────────────────────────────
# Re-solving the ring from scratch every tick is unstable in exactly the
# situation spotting matters most.  With an island between us and a contact the
# two ways around it score almost identically, the winner alternates on noise,
# and because the two destinations are on opposite sides of the island the
# ship splits the difference and drives straight down the middle at the enemy.
# The threat push-out then amplifies it, since it shoves each side further out.
#
# So the station is COMMITTED and then tracked, rather than re-chosen.  It is
# stored as an angle around the enemy centroid rather than as a world point,
# which means it follows the enemy for free: they sail away, the centroid moves
# with them, and the station moves forward without any decision being taken.
# A decision is only needed when the shape of the problem changes, and then it
# has to clear a margin before the ship is allowed to swap sides of an island.

## Held station, as a world angle around the enemy centroid.
var _station_valid: bool = false
var _station_angle: float = 0.0

## How much better a different station must score before we abandon the held
## one.  This is what stops the two sides of an island trading places.
const SWITCH_MARGIN := 0.12

## How many ring samples away a better station may be and still count as the
## held one sliding along rather than jumping.  Lets the station track a
## gradual change in the picture without needing to clear SWITCH_MARGIN.
const DRIFT_STEPS := 1


func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship           := ctx.ship
	var my_concealment: float = (ship.concealment.params.p() as ConcealmentParams).radius

	var spot_margin: float      = params.get("spot_margin",        SPOT_MARGIN)
	var safe_margin: float      = params.get("safe_margin",        SAFE_MARGIN)
	# Maximum distance we'll travel to reach any target.  Falls back to a
	# multiple of our own concealment radius so it scales with ship class.
	var max_target_dist: float = params.get(
		"max_target_distance", my_concealment * MAX_TARGET_DIST_FACTOR)

	var spotted: Array[Ship]  = ctx.server.get_valid_targets(ship.team.team_id)
	var unspotted: Dictionary = ctx.server.get_unspotted_enemies(ship.team.team_id)

	# ── Build target list ────────────────────────────────────────────────────
	# Each entry: { pos: Vector3, concealment: float, dist: float }
	var targets: Array[Dictionary] = []

	if spotted.size() > 0:
		# Only include spotted enemies within pursuit range so distant contacts
		# don't drag the centroid (and therefore the ring) far across the map.
		for s: Ship in spotted:
			if not is_instance_valid(s):
				continue
			var d := s.global_position.distance_to(ship.global_position)
			if d > max_target_dist:
				continue
			targets.append({
				pos         = s.global_position,
				concealment = (s.concealment.params.p() as ConcealmentParams).radius,
				dist        = d,
			})
		# If every spotted enemy was out of range, fall through to Phase 2 so
		# we don't try to navigate across the map to maintain contact.

	if targets.is_empty():
		# Phase 2: approach the nearest unspotted enemy that is within range.
		var best_dist := INF
		var best_entry: Dictionary = {}
		for s in unspotted.keys():
			var pos: Vector3 = unspotted[s]
			var d := pos.distance_to(ship.global_position)
			if d >= best_dist or d > max_target_dist:
				continue
			best_dist = d
			var ec: float = (s.concealment.params.p() as ConcealmentParams).radius \
				if is_instance_valid(s) else my_concealment * 2.0
			best_entry = { pos = pos, concealment = ec, dist = d }
		if not best_entry.is_empty():
			targets.append(best_entry)

	if targets.is_empty():
		# Nothing to hold a station against; the next contact starts fresh.
		_station_valid = false
		return null

	# ── Compute distance-weighted centroid and sweet-spot ring radius ─────────
	# Inverse-distance weighting ensures nearby enemies dominate the centroid
	# instead of being averaged equally with far-away contacts.
	var centroid              := Vector3.ZERO
	var avg_enemy_concealment := 0.0
	var total_weight          := 0.0
	for t: Dictionary in targets:
		var w := 1.0 / maxf(t.dist as float, 1.0)
		centroid              += (t.pos as Vector3) * w
		avg_enemy_concealment += (t.concealment as float) * w
		total_weight          += w
	centroid              /= total_weight
	avg_enemy_concealment /= total_weight

	var outer_edge := avg_enemy_concealment * spot_margin
	var inner_edge := my_concealment        * safe_margin

	var ring_radius: float
	if outer_edge > inner_edge:
		# A stealth corridor exists: anywhere between inner_edge and outer_edge
		# spots them without showing us.  Sit at the INNER edge, not in the
		# middle of it.  Detection is symmetric-ish and one-sided in our favour
		# here — an enemy must come inside OUR concealment radius to see us, so
		# the closest safe standoff is just outside that radius, and everything
		# a spotter wants is better there: shorter torpedo flight times, a
		# tighter reaction loop, and contacts held at the near edge of their
		# detection ring rather than the far one where they slip in and out.
		ring_radius = inner_edge
		stealth_corridor = true
	else:
		# They conceal better than we do, so no standoff both spots them and
		# hides us.  Accept exposure at the farthest range that still spots.
		ring_radius = outer_edge
		stealth_corridor = false

	# ── Generate and score candidates ────────────────────────────────────────
	var ship_2d     := Vector2(ship.global_position.x, ship.global_position.z)
	var centroid_2d := Vector2(centroid.x, centroid.z)

	# Span used to normalise the proximity term below.
	var dist_scale := maxf(ship_2d.distance_to(centroid_2d) + ring_radius, 1.0)

	var env := {
		centroid_2d    = centroid_2d,
		ring_radius    = ring_radius,
		ship_2d        = ship_2d,
		dist_scale     = dist_scale,
		targets        = targets,
		my_concealment = my_concealment,
		spot_margin    = spot_margin,
		safe_margin    = safe_margin,
	}

	# Sample a 180° arc on the side of the centroid facing our ship so the
	# chosen position is always between us and the enemy, not behind them.
	# Note this arc is anchored on OUR position, so it rotates as we move —
	# another reason the choice has to be committed rather than re-taken every
	# tick, since the candidate set itself is not stable.
	var to_ship_dir := ship_2d - centroid_2d
	var base_angle: float = atan2(to_ship_dir.y, to_ship_dir.x) if to_ship_dir.length_squared() > 1.0 else 0.0
	var arc_step: float = PI / float(CANDIDATE_COUNT - 1) if CANDIDATE_COUNT > 1 else PI

	var best: Dictionary = {}
	var best_angle: float = base_angle
	for i in CANDIDATE_COUNT:
		var t_frac := float(i) / (CANDIDATE_COUNT - 1) if CANDIDATE_COUNT > 1 else 0.5
		var angle := base_angle - PI * 0.5 + PI * t_frac
		var cand := _score_station(ctx, angle, env)
		if best.is_empty() or float(cand.score) > float(best.score):
			best = cand
			best_angle = angle

	if best.is_empty() or (best.pos as Vector3) == Vector3.ZERO:
		_station_valid = false
		return null

	var chosen: Dictionary = best
	var chosen_angle: float = best_angle

	if _station_valid:
		# The held station, re-scored against the picture as it is NOW.  It has
		# already tracked the enemy since last tick — the angle is theirs, not
		# the world's — so this is asking whether it is still a good station,
		# not whether the enemy moved.
		var held := _score_station(ctx, _station_angle, env)

		# Give it up without argument when it has stopped being a station at
		# all: the enemy has sailed past it, or it now sees nothing.
		var behind: bool = absf(angle_difference(_station_angle, base_angle)) > PI * 0.5
		var blind: bool = int(held.covered) == 0 and int(best.covered) > 0

		# Otherwise it takes either a small slide along the ring, or a clearly
		# better station elsewhere, to move us.  Both require an improvement:
		# the held station is not necessarily one of the sampled candidates, so
		# it can outscore every one of them and must be allowed to.
		var better: bool = float(best.score) > float(held.score)
		var slide: bool = better \
			and absf(angle_difference(best_angle, _station_angle)) <= arc_step * float(DRIFT_STEPS) + 0.001
		var decisive: bool = float(best.score) > float(held.score) + SWITCH_MARGIN

		if not (behind or blind or slide or decisive):
			chosen = held
			chosen_angle = _station_angle

	_station_angle = chosen_angle
	_station_valid = true
	var best_pos: Vector3 = chosen.pos

	# ── Build NavIntent ──────────────────────────────────────────────────────
	var to_dest := best_pos - ship.global_position
	to_dest.y = 0.0
	var heading := atan2(to_dest.x, to_dest.z) \
		if to_dest.length_squared() > 1.0 \
		else ctx.behavior._get_ship_heading()

	var intent := NavIntent.create(best_pos, heading)
	# With no corridor the destination is inside enemy detection by definition.
	# Let it stand rather than have the threat BFS walk it out to some cell on
	# the far side of the contact we are trying to spot.
	intent.skip_threat_adjustment = not stealth_corridor
	return intent


## Score one candidate station sitting at `angle` around the enemy centroid.
## Factored out of the candidate sweep so the held station can be re-scored by
## exactly the same rules as its challengers — scoring them differently is how
## a commitment scheme ends up either never moving or never holding.
##
## Returns { pos: Vector3, score: float, covered: int }.
func _score_station(ctx: SkillContext, angle: float, env: Dictionary) -> Dictionary:
	var targets: Array = env.targets
	var my_concealment: float = env.my_concealment
	var spot_margin: float = env.spot_margin
	var safe_margin: float = env.safe_margin

	var dir := Vector2(cos(angle), sin(angle))
	var c2d: Vector2 = (env.centroid_2d as Vector2) + dir * float(env.ring_radius)
	var c3d: Vector3 = ctx.behavior._get_valid_nav_point(Vector3(c2d.x, 0.0, c2d.y))
	c2d = Vector2(c3d.x, c3d.z)

	# Coverage and stealth in one pass over the contacts.
	var covered := 0
	var stealth := 1.0
	for t: Dictionary in targets:
		var t2d := Vector2((t.pos as Vector3).x, (t.pos as Vector3).z)
		var dist := c2d.distance_to(t2d)
		var los_blocked := NavigationMapManager.is_los_blocked_2d(c2d, t2d)
		if dist <= (t.concealment as float) * spot_margin and not los_blocked:
			covered += 1
		if dist < my_concealment * safe_margin and not los_blocked:
			stealth -= 1.0 / targets.size()

	var score := W_COVERAGE * (float(covered) / targets.size())
	score += W_STEALTH * clampf(stealth, 0.0, 1.0)

	# Proximity: prefer candidates close to our current position.  Normalised
	# against the full span a candidate can sit at (our distance to the
	# centroid, plus the ring we are placing them on).  Normalising against
	# ring_radius alone saturates to zero for every candidate as soon as we are
	# further out than one ring, which silently removes this term exactly when
	# it matters most.
	var dist_to_us := c2d.distance_to(env.ship_2d as Vector2)
	score += W_DISTANCE * clampf(1.0 - dist_to_us / float(env.dist_scale), 0.0, 1.0)

	return { pos = c3d, score = score, covered = covered }
