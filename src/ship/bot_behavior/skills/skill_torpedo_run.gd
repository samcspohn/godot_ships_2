class_name SkillTorpedoRun
extends BotSkill

## Number of candidate positions to evaluate around the target
const CANDIDATE_COUNT := 12

## Weight for "how close is the candidate to the DD" scoring
const SCORE_WEIGHT_DISTANCE := 0.25
## Weight for "is the candidate on our side of the enemy fleet" scoring
const SCORE_WEIGHT_SAFE_SIDE := 0.35
## Weight for "how good is the beam-on torpedo angle" scoring
const SCORE_WEIGHT_BEAM_ANGLE := 0.25
## Weight for "how far from threat zones" scoring
const SCORE_WEIGHT_THREAT_CLEAR := 0.15


func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var target = ctx.target
	if target == null:
		return null
	if ship.torpedo_controller == null:
		return null

	var concealment_radius: float = (ship.concealment.params.p() as ConcealmentParams).radius
	var torpedo_range: float = ship.torpedo_controller.get_params()._range
	if torpedo_range <= 0.0:
		return null

	# Gather all known enemy positions for threat checking
	var threat_positions: Array = ctx.behavior._gather_threat_positions(ship)
	# Scoring radius: detection boundary + small buffer. Heuristic-only, not
	# tied to what the pathfinder consumes.
	var scoring_radius: float = concealment_radius + 500.0

	# Enemy fleet centroid — used to determine "our side" vs "their side"
	var enemy_centroid := _get_enemy_centroid(threat_positions)

	# Launch distance: place candidates just outside the DD's own detection
	# radius from the target — close enough for a good shot, but not inside
	# the detection boundary.
	var launch_dist: float = concealment_radius * 1.25

	# --- Generate and score candidate positions around the target ---
	var ship_pos_2d := Vector2(ship.global_position.x, ship.global_position.z)
	var target_pos_2d := Vector2(target.global_position.x, target.global_position.z)
	var centroid_2d := Vector2(enemy_centroid.x, enemy_centroid.z)

	# Direction from enemy centroid to DD — this is the "safe" direction
	var safe_dir := (ship_pos_2d - centroid_2d)
	if safe_dir.length_squared() < 1.0:
		safe_dir = (ship_pos_2d - target_pos_2d)
	if safe_dir.length_squared() < 1.0:
		safe_dir = Vector2(1.0, 0.0)
	safe_dir = safe_dir.normalized()

	# Target's forward direction (XZ plane) — beam is perpendicular to this
	var target_fwd := Vector2(target.transform.basis.z.x, target.transform.basis.z.z).normalized()
	var target_beam := Vector2(-target_fwd.y, target_fwd.x)  # perpendicular

	var best_score: float = -INF
	var best_pos: Vector3 = Vector3.ZERO
	var any_valid := false

	for i in CANDIDATE_COUNT:
		var angle: float = (TAU / CANDIDATE_COUNT) * i
		var dir := Vector2(cos(angle), sin(angle))
		var candidate_2d := target_pos_2d + dir * launch_dist

		# Validate the point is in navigable water
		var candidate_3d := Vector3(candidate_2d.x, 0.0, candidate_2d.y)
		candidate_3d = ctx.behavior._get_valid_nav_point(candidate_3d)
		candidate_2d = Vector2(candidate_3d.x, candidate_3d.z)

		# --- Score this candidate ---
		var score: float = 0.0

		# 1) Distance score: prefer candidates closer to the DD (less travel = less exposure)
		var dist_to_ship := candidate_2d.distance_to(ship_pos_2d)
		# Normalize against the distance from ship to target as a baseline
		var baseline_dist := ship_pos_2d.distance_to(target_pos_2d)
		if baseline_dist > 1.0:
			# Score 1.0 when candidate is at ship pos, 0.0 when twice the baseline away
			score += SCORE_WEIGHT_DISTANCE * clampf(1.0 - dist_to_ship / (baseline_dist * 2.0), 0.0, 1.0)

		# 2) Safe-side score: prefer candidates on the DD's side of the enemy fleet
		var candidate_dir := (candidate_2d - centroid_2d)
		if candidate_dir.length_squared() > 1.0:
			candidate_dir = candidate_dir.normalized()
			var safe_dot := candidate_dir.dot(safe_dir)
			# Remap from [-1, 1] to [0, 1]
			score += SCORE_WEIGHT_SAFE_SIDE * clampf((safe_dot + 1.0) * 0.5, 0.0, 1.0)

		# 3) Beam angle score: prefer positions where torpedo tubes bear on target
		#    Best angle is when the line from candidate to target is perpendicular
		#    to the target's heading (i.e., broadside shot)
		var to_target_dir := (target_pos_2d - candidate_2d)
		if to_target_dir.length_squared() > 1.0:
			to_target_dir = to_target_dir.normalized()
			# abs(dot with beam) = 1.0 for perfect broadside, 0.0 for bow/stern
			var beam_quality := absf(to_target_dir.dot(target_beam))
			score += SCORE_WEIGHT_BEAM_ANGLE * beam_quality

		# 4) Threat clearance score: prefer candidates outside threat zones
		var threat_score := _score_threat_clearance(candidate_2d, threat_positions, scoring_radius)
		score += SCORE_WEIGHT_THREAT_CLEAR * threat_score

		if score > best_score:
			best_score = score
			best_pos = candidate_3d
			any_valid = true

	if not any_valid:
		return null

	# --- Reject if the best candidate is deeply inside threat zones ---
	# If even the best position is surrounded by threats on all sides, it's
	# better to fall through to Flank/Hunt than to send the pathfinder on
	# an impossible quest.
	var best_2d := Vector2(best_pos.x, best_pos.z)
	var threats_covering_best := _count_covering_threats(best_2d, threat_positions, concealment_radius)
	if threats_covering_best >= 3:
		# Surrounded by 3+ threat zones — torpedo run is suicidal, abort
		return null

	# Push the chosen position clear of every known threat by at least one
	# concealment radius so the DD isn't sitting inside an enemy's detection
	# zone when it arrives.
	best_pos = ctx.behavior._push_clear_of_threats(best_pos, threat_positions, concealment_radius)

	# Final validation
	best_pos = ctx.behavior._get_valid_nav_point(best_pos)

	# --- Calculate heading for torpedo launch ---
	var heading := _calculate_launch_heading(ctx, ship, target, best_pos)

	return NavIntent.create(best_pos, heading)


## Score how clear a candidate position is from threat zones.
## Returns 1.0 if fully clear, 0.0 if deep inside multiple zones.
func _score_threat_clearance(pos: Vector2, threat_positions: Array, scoring_radius: float) -> float:
	if threat_positions.is_empty():
		return 1.0

	var total_penalty: float = 0.0
	for tp in threat_positions:
		var tp_2d := Vector2(tp.x, tp.z)
		var dist := pos.distance_to(tp_2d)
		if dist < scoring_radius:
			# Quadratic ramp: 1.0 at center, 0.0 at edge
			var t := (scoring_radius - dist) / scoring_radius
			total_penalty += t * t

	# Normalize: 0 penalty = 1.0 score, heavy penalty = 0.0
	return clampf(1.0 - total_penalty * 0.5, 0.0, 1.0)


## Count how many threat zones fully cover the candidate position (inside the
## caller-supplied radius — the DD's concealment radius by default).
func _count_covering_threats(pos: Vector2, threat_positions: Array, cover_radius: float) -> int:
	var count := 0
	for tp in threat_positions:
		var tp_2d := Vector2(tp.x, tp.z)
		if pos.distance_to(tp_2d) < cover_radius:
			count += 1
	return count


## Get the centroid of all known enemy positions.
func _get_enemy_centroid(threat_positions: Array) -> Vector3:
	if threat_positions.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for tp in threat_positions:
		sum += tp
	return sum / threat_positions.size()


## Calculate the heading the DD should face when launching torpedoes.
## DDs want their torpedo tubes (beam-mounted) to bear on the target's
## predicted path. The ideal heading is perpendicular to the bearing
## toward the target, with a bias toward an escape heading.
func _calculate_launch_heading(ctx: SkillContext, ship: Ship, target: Ship, launch_pos: Vector3) -> float:
	# Predict where the target will be when torpedoes arrive
	var target_pos := target.global_position
	if target.linear_velocity.length() > 0.5 and ship.torpedo_controller != null:
		var torp_speed: float = ship.torpedo_controller.get_torp_params().speed
		if torp_speed > 0:
			var dist := launch_pos.distance_to(target_pos)
			target_pos = target_pos + target.linear_velocity * (dist / torp_speed) * 0.5

	var to_target := target_pos - launch_pos
	to_target.y = 0.0
	if to_target.length_squared() < 1.0:
		return ctx.behavior._get_ship_heading()

	var target_bearing := atan2(to_target.x, to_target.z)
	var current_heading := ctx.behavior._get_ship_heading()

	# Torpedo tubes are beam-mounted: heading should be perpendicular to target bearing
	var perp_right := ctx.behavior._normalize_angle(target_bearing + PI / 2.0)
	var perp_left := ctx.behavior._normalize_angle(target_bearing - PI / 2.0)

	# Slight bias toward the perpendicular that keeps us moving away (escape route)
	var away_from_target := ctx.behavior._normalize_angle(target_bearing + PI)

	var diff_right: float = abs(ctx.behavior._normalize_angle(perp_right - current_heading))
	var diff_left: float = abs(ctx.behavior._normalize_angle(perp_left - current_heading))
	var right_escape: float = abs(ctx.behavior._normalize_angle(perp_right - away_from_target))
	var left_escape: float = abs(ctx.behavior._normalize_angle(perp_left - away_from_target))

	# Blend heading preference (60% ease of turn, 40% escape route)
	var right_score := diff_right * 0.6 + right_escape * 0.4
	var left_score := diff_left * 0.6 + left_escape * 0.4

	return perp_right if right_score <= left_score else perp_left
