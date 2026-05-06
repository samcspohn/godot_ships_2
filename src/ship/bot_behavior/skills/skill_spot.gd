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

## Fraction of enemy concealment radius to stay inside (detection margin).
const SPOT_MARGIN            := 1.0
## Fraction of our own concealment radius to stay outside (stealth margin).
const SAFE_MARGIN            := 1.50

## How many times our own concealment radius we're willing to travel to reach
## an unspotted enemy.  Keeps ships from hunting targets across the whole map.
## Overridable via params key "max_target_distance".
const MAX_TARGET_DIST_FACTOR := 5.0

## Scoring weights — must sum to 1.0.
const W_COVERAGE := 0.45   # how many spotted enemies are kept detected
const W_STEALTH  := 0.30   # how well we stay hidden from all enemies
const W_DISTANCE := 0.25   # prefer candidates closer to our current position


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
		ring_radius = (outer_edge + inner_edge) * 0.5
	else:
		# No clean stealth corridor — accept exposure, stay just inside detection.
		ring_radius = outer_edge

	# ── Generate and score candidates ────────────────────────────────────────
	var ship_2d     := Vector2(ship.global_position.x, ship.global_position.z)
	var centroid_2d := Vector2(centroid.x, centroid.z)

	var best_score := -INF
	var best_pos   := Vector3.ZERO

	# Sample a 180° arc on the side of the centroid facing our ship so the
	# chosen position is always between us and the enemy, not behind them.
	var to_ship_dir := ship_2d - centroid_2d
	var base_angle: float = atan2(to_ship_dir.y, to_ship_dir.x) if to_ship_dir.length_squared() > 1.0 else 0.0

	for i in CANDIDATE_COUNT:
		var t_frac := float(i) / (CANDIDATE_COUNT - 1) if CANDIDATE_COUNT > 1 else 0.5
		var angle  := base_angle - PI * 0.5 + PI * t_frac
		var dir    := Vector2(cos(angle), sin(angle))
		var c2d    := centroid_2d + dir * ring_radius
		var c3d    := ctx.behavior._get_valid_nav_point(Vector3(c2d.x, 0.0, c2d.y))
		c2d = Vector2(c3d.x, c3d.z)

		var score := 0.0

		# 1+2) Single pass: coverage and stealth.
		var covered := 0
		var stealth := 1.0
		for t: Dictionary in targets:
			var t2d  := Vector2((t.pos as Vector3).x, (t.pos as Vector3).z)
			var dist := c2d.distance_to(t2d)
			var los_blocked := NavigationMapManager.is_los_blocked_2d(c2d, t2d)
			if dist <= (t.concealment as float) * spot_margin and not los_blocked:
				covered += 1
			if dist < my_concealment * safe_margin and not los_blocked:
				stealth -= 1.0 / targets.size()
		score += W_COVERAGE * (float(covered) / targets.size())
		score += W_STEALTH * clampf(stealth, 0.0, 1.0)

		# 3) Proximity: prefer candidates close to our current position.
		#    Normalise against ring_radius (not ring_radius*2) so that small
		#    differences in distance produce a real score spread.
		var dist_to_us := c2d.distance_to(ship_2d)
		score += W_DISTANCE * clampf(1.0 - dist_to_us / ring_radius, 0.0, 1.0)

		if score > best_score:
			best_score = score
			best_pos   = c3d

	if best_pos == Vector3.ZERO:
		return null

	# ── Build NavIntent ──────────────────────────────────────────────────────
	var to_dest := best_pos - ship.global_position
	to_dest.y = 0.0
	var heading := atan2(to_dest.x, to_dest.z) \
		if to_dest.length_squared() > 1.0 \
		else ctx.behavior._get_ship_heading()

	return NavIntent.create(best_pos, heading)
