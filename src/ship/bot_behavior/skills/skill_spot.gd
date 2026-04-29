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
##   Approach the nearest unspotted enemy to the sweet-spot distance so we can
##   light them up. Uses the same candidate ring so the result is nav-valid.

const CANDIDATE_COUNT := 16

## Fraction of enemy concealment radius to stay inside (detection margin).
const SPOT_MARGIN     := 0.88
## Fraction of our own concealment radius to stay outside (stealth margin).
const SAFE_MARGIN     := 1.10

## Scoring weights — must sum to 1.0.
const W_COVERAGE := 0.55   # how many spotted enemies are kept detected
const W_STEALTH  := 0.30   # how well we stay hidden from all enemies
const W_DISTANCE := 0.15   # prefer candidates closer to our current position


func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship         := ctx.ship
	var my_concealment: float = (ship.concealment.params.p() as ConcealmentParams).radius

	var spot_margin: float = params.get("spot_margin", SPOT_MARGIN)
	var safe_margin: float = params.get("safe_margin", SAFE_MARGIN)

	var spotted: Array[Ship]  = ctx.server.get_valid_targets(ship.team.team_id)
	var unspotted: Dictionary = ctx.server.get_unspotted_enemies(ship.team.team_id)

	# ── Build target list ────────────────────────────────────────────────────
	# Each entry: { pos: Vector3, concealment: float }
	var targets: Array[Dictionary] = []


	if spotted.size() > 0:
		for s: Ship in spotted:
			if not is_instance_valid(s):
				continue
			targets.append({
				pos         = s.global_position,
				concealment = (s.concealment.params.p() as ConcealmentParams).radius,
			})
	else:
		# Phase 2: only target the nearest unspotted enemy so we don't try to
		# simultaneously reveal a spread-out fleet.
		var best_dist := INF
		var best_entry: Dictionary = {}
		for s in unspotted.keys():
			var pos: Vector3 = unspotted[s]
			var d := pos.distance_to(ship.global_position)
			if d < best_dist:
				best_dist = d
				var ec: float = (s.concealment.params.p() as ConcealmentParams).radius \
					if is_instance_valid(s) else my_concealment * 2.0
				best_entry = { pos = pos, concealment = ec }
		if not best_entry.is_empty():
			targets.append(best_entry)


	if targets.is_empty():
		return null

	# ── Compute centroid and sweet-spot ring radius ──────────────────────────
	var centroid := Vector3.ZERO
	var avg_enemy_concealment := 0.0
	for t: Dictionary in targets:
		centroid              += t.pos
		avg_enemy_concealment += t.concealment
	centroid              /= targets.size()
	avg_enemy_concealment /= targets.size()

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

	for i in CANDIDATE_COUNT:
		var angle := (TAU / CANDIDATE_COUNT) * i
		var dir   := Vector2(cos(angle), sin(angle))
		var c2d   := centroid_2d + dir * ring_radius
		var c3d   := ctx.behavior._get_valid_nav_point(Vector3(c2d.x, 0.0, c2d.y))
		c2d = Vector2(c3d.x, c3d.z)

		var score := 0.0

		# 1) Coverage: fraction of targets kept within their detection radius.
		#    A target only counts as covered if terrain doesn't block LOS to it —
		#    a position behind an island is useless for spotting.
		var covered := 0
		for t: Dictionary in targets:
			var t2d  := Vector2((t.pos as Vector3).x, (t.pos as Vector3).z)
			var dist := c2d.distance_to(t2d)
			if dist <= (t.concealment as float) * spot_margin:
				if not NavigationMapManager.is_los_blocked_2d(c2d, t2d):
					covered += 1
		score += W_COVERAGE * (float(covered) / targets.size())

		# 2) Stealth: penalise proximity to any enemy's detection zone.
		#    Only penalise when the enemy actually has LOS to us — if terrain
		#    blocks their view we are already concealed regardless of distance.
		var stealth := 1.0
		for t: Dictionary in targets:
			var t2d  := Vector2((t.pos as Vector3).x, (t.pos as Vector3).z)
			var dist := c2d.distance_to(t2d)
			if dist < my_concealment * safe_margin:
				if not NavigationMapManager.is_los_blocked_2d(c2d, t2d):
					stealth -= 1.0 / targets.size()
		score += W_STEALTH * clampf(stealth, 0.0, 1.0)

		# 3) Distance: prefer candidates close to our current position.
		var dist_to_us := c2d.distance_to(ship_2d)
		var max_dist   := ring_radius * 2.0
		score += W_DISTANCE * clampf(1.0 - dist_to_us / max_dist, 0.0, 1.0)

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

	# Full speed while repositioning; ease off when nearly at the sweet spot.
	var throttle := 4 if to_dest.length() > 800.0 else 2

	var intent := NavIntent.create(best_pos, heading)
	intent.throttle_override = throttle
	return intent
