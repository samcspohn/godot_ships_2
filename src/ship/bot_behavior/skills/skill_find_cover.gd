class_name SkillFindCover
extends BotSkill

var _broadside: SkillBroadside = SkillBroadside.new()

var _target_island_id: int = -1
var _target_island_pos: Vector3 = Vector3.ZERO
var _target_island_radius: float = 0.0
var _nav_destination: Vector3 = Vector3.ZERO
var _nav_destination_valid: bool = false
var _cover_recalc_ms: int = 0
var _arrived: bool = false
var can_shoot: bool = false
var _dist_to_dest: float = 0.0
var _last_valid_cover_pos: Vector3 = Vector3.ZERO
var _last_valid_cover_pos_set: bool = false


func execute(ctx: SkillContext, params: Dictionary, prioritize_cover: bool = true) -> NavIntent:
	var ship = ctx.ship
	var target = ctx.target
	var desired_range = params.get("desired_range", ship.artillery_controller.get_params()._range * 0.6)
	var recalc_cooldown = params.get("recalc_cooldown_ms", 3000)

	# Find initial island if we don't have one yet
	if not _nav_destination_valid:
		var island = _get_cover_position(ctx, desired_range, target, prioritize_cover)
		if island.is_empty():
			return null  # No cover available — caller falls back
		_set_island(island)

	# Periodically recalculate cover position
	var now_ms = Time.get_ticks_msec()
	if now_ms - _cover_recalc_ms >= recalc_cooldown:
		_cover_recalc_ms = now_ms
		var island: Dictionary
		if _target_island_id >= 0:
			# Already in cover: prefer staying on the same island, only move if
			# it can no longer provide a shootable position.
			island = _recalc_same_island(ctx, target)
			if island.is_empty():
				# Committed island can no longer provide cover while arrived —
				# clear commitment so _get_cover_position skips it and picks
				# the next viable candidate.
				_target_island_id = -1
				island = _get_cover_position(ctx, desired_range, target, prioritize_cover)
		else:
			# Not yet arrived — _get_cover_position will honour the commitment
			# internally: try the cached island first, skip it on failure.
			island = _get_cover_position(ctx, desired_range, target, prioritize_cover)

		if not island.is_empty():
			_set_island(island)
		elif not _nav_destination_valid:
			return null  # No cover available and no previous destination to fall back on

	# Approach / station-keep
	var dist = ship.global_position.distance_to(_nav_destination)
	_dist_to_dest = dist
	var clearance = ctx.behavior._get_ship_clearance()
	var arrival_radius = clearance * 2.0
	var exit_radius = clearance * 3.5
	_arrived = dist < exit_radius if _arrived else dist < arrival_radius

	var heading = ctx.behavior._tangential_heading(_target_island_pos, _nav_destination)

	# Check shootability (shell arc over terrain) from current or destination position
	can_shoot = false
	var check_pos = ship.global_position if _arrived else _nav_destination
	var shell_params = ship.artillery_controller.get_shell_params()
	var gun_range = ship.artillery_controller.get_params()._range
	if shell_params != null:
		for enemy in ctx.server.get_valid_targets(ship.team.team_id):
			if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
				continue
			var tgt = enemy.global_position + enemy.global_basis * ctx.behavior.target_aim_offset(enemy)
			if check_pos.distance_to(tgt) > gun_range:
				continue
			var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(check_pos, tgt, shell_params)
			if sol[0] == null:
				continue
			var result = Gun.sim_can_shoot_over_terrain_static(check_pos, sol[0], sol[1], shell_params, ship)
			if result.can_shoot_over_terrain:
				can_shoot = true
				break

	var broadside_bias: float = params.get("broadside_bias", 0.4)

	if _arrived:
		var arrived_intent = NavIntent.create(_nav_destination, heading, arrival_radius * 0.5)
		arrived_intent.near_terrain = true
		arrived_intent.skip_threat_adjustment = true
		return _broadside.apply(arrived_intent, ctx, {"oscillation_bias": broadside_bias})

	var intent = NavIntent.create(_nav_destination, heading)
	intent.near_terrain = true
	intent.skip_threat_adjustment = true
	return _broadside.apply(intent, ctx, {"oscillation_bias": broadside_bias})


# ---------------------------------------------------------------------------
# Recalculate the best position on the island we are already holding.
# Returns empty dict only when the island is genuinely no longer viable:
#   • No concealed position exists at all, OR
#   • Enemies ARE visible yet none can be shot from any position on the island.
# If no enemies are currently visible we cannot assess shootability, so we
# stay put rather than thrashing to a different island.
# ---------------------------------------------------------------------------
func _recalc_same_island(ctx: SkillContext, _target: Ship) -> Dictionary:
	var ship = ctx.ship
	var my_pos: Vector3 = ship.global_position
	var threats = ctx.behavior._gather_threat_positions(ship)
	var targets = ctx.server.get_valid_targets(ship.team.team_id)

	# ── Fastest path: re-validate the last known-good cover position ─────────
	# This is a fixed world point that was previously confirmed as hidden AND
	# shootable.  A cheap LOS + shoot check is all we need; no geometry search.
	if _last_valid_cover_pos_set and threats.size() > 0:
		var cached_pos := _last_valid_cover_pos
		var cached_hidden := true
		for threat_pos in threats:
			if not ctx.behavior._is_los_blocked_with_clearance(cached_pos, threat_pos):
				cached_hidden = false
				break
		if cached_hidden:
			var can_shoot_cached := _can_shoot_from(ctx, cached_pos, targets)
			if targets.is_empty() or can_shoot_cached:
				return {
					"id": _target_island_id,
					"center": _target_island_pos,
					"radius": _target_island_radius,
					"dest": cached_pos,
					"can_shoot": can_shoot_cached,
				}
		# Cached position no longer valid — clear it and keep searching.
		_last_valid_cover_pos_set = false

	# ── Fast path: current position is already concealed ─────────────────────
	# Skip the full candidate search when the ship is already hidden from every
	# known threat.  Stamp the current world position as the destination so it
	# doesn't slowly drift with the ship between recalc ticks.
	if threats.size() > 0:
		var all_hidden := true
		for threat_pos in threats:
			if not ctx.behavior._is_los_blocked_with_clearance(my_pos, threat_pos):
				all_hidden = false
				break
		if all_hidden:
			var can_shoot_here := _can_shoot_from(ctx, my_pos, targets)
			if targets.is_empty() or can_shoot_here:
				if can_shoot_here:
					_last_valid_cover_pos = my_pos
					_last_valid_cover_pos_set = true
				return {
					"id": _target_island_id,
					"center": _target_island_pos,
					"radius": _target_island_radius,
					"dest": my_pos,
					"can_shoot": can_shoot_here,
				}
			# Concealed but visible enemies are not shootable from here →
			# fall through so the candidate search tries a better spot on
			# this same island before considering abandoning it.

	var hide_h: float
	if threats.size() > 0:
		hide_h = ctx.behavior._compute_hide_heading(_target_island_pos, threats)
	else:
		hide_h = atan2(ctx.behavior._cached_safe_dir.x, ctx.behavior._cached_safe_dir.z)

	var cover_result = ctx.behavior._find_cover_position_on_island(
		_target_island_pos, _target_island_radius, hide_h, threats, targets, true
	)

	# Island can't conceal us at all — abandon it.
	if cover_result.is_empty():
		return {}

	# Enemies are visible but we provably can't shoot any of them from this
	# island — it's no longer a viable firing position, so move on.
	if targets.size() > 0 and not cover_result["can_shoot"]:
		return {}

	# Either can shoot, or no enemies are currently spotted (can't assess
	# shootability) — stay on the island.  Cache the position when shootable.
	var result_can_shoot: bool = cover_result.get("can_shoot", false)
	if result_can_shoot:
		_last_valid_cover_pos = cover_result["pos"]
		_last_valid_cover_pos_set = true
	return {
		"id": _target_island_id,
		"center": _target_island_pos,
		"radius": _target_island_radius,
		"dest": cover_result["pos"],
		"can_shoot": result_can_shoot,
	}


# ---------------------------------------------------------------------------
# Search all islands for the best cover position.
#
# When prioritize_cover is true (default): islands are sorted by proximity and
# the first island that offers a shootable cover position is returned — i.e.
# "nearest island that works".
#
# When prioritize_cover is false: all viable islands are scored by how close
# the engagement distance to the nearest enemy cluster is to desired_range,
# and the best-scoring island is returned.
#
# In both modes islands are always evaluated nearest-first so ties naturally
# resolve toward the ship's current position.
# ---------------------------------------------------------------------------
func _get_cover_position(ctx: SkillContext, desired_range: float, _target: Ship, prioritize_cover: bool = true) -> Dictionary:
	if not NavigationMapManager.is_map_ready():
		return {}

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return {}

	var ship = ctx.ship
	var my_pos = ship.global_position
	var gun_range = ship.artillery_controller.get_params()._range
	var min_safe_range = gun_range * 0.35

	var threats = ctx.behavior._gather_threat_positions(ship)
	if ctx.server == null:
		return {}
	var targets = ctx.server.get_valid_targets(ship.team.team_id)
	var enemy_clusters = ctx.server.get_enemy_clusters(ship.team.team_id)

	ctx.behavior._ensure_safe_dir(ship, ctx.server)

	# Always sort islands by proximity — nearest edge of island to ship wins ties
	islands.sort_custom(func(a, b):
		var ca = Vector3(a["center"].x, 0.0, a["center"].y)
		var cb = Vector3(b["center"].x, 0.0, b["center"].y)
		return my_pos.distance_to(ca) - a["radius"] < my_pos.distance_to(cb) - b["radius"]
	)

	var best_id: int = -1
	var best_score: float = INF
	var best_pos: Vector3 = Vector3.ZERO
	var best_radius: float = 0.0
	var best_dest: Vector3 = Vector3.ZERO
	var best_can_shoot: bool = false

	# ── Commitment: try the cached island first ───────────────────────────
	# If we already have a committed island, evaluate it before the sorted
	# search. If it still provides shootable cover we return immediately,
	# honouring the commitment. If it fails we record its id so the main
	# loop can skip it and find the next viable candidate.
	var skip_committed_id: int = -1
	if _target_island_id >= 0:
		for isl in islands:
			if isl["id"] != _target_island_id:
				continue
			var c2d: Vector2 = isl["center"]
			var c_pos = Vector3(c2d.x, 0.0, c2d.y)
			var c_rad: float = isl["radius"]
			var c_hide_h: float
			if threats.size() > 0:
				c_hide_h = ctx.behavior._compute_hide_heading(c_pos, threats)
			else:
				c_hide_h = atan2(ctx.behavior._cached_safe_dir.x, ctx.behavior._cached_safe_dir.z)
			var c_result = ctx.behavior._find_cover_position_on_island(
				c_pos, c_rad, c_hide_h, threats, targets, true
			)
			# Stay on committed island when:
			#   • it can still conceal us AND we can shoot, OR
			#   • it can still conceal us AND no enemies are visible (can't
			#     assess shootability — don't thrash to a different island).
			if not c_result.is_empty() and (targets.is_empty() or c_result["can_shoot"]):
				return {
					"id": isl["id"],
					"center": c_pos,
					"radius": c_rad,
					"dest": c_result["pos"],
					"can_shoot": c_result.get("can_shoot", false),
				}
			# Committed island can no longer provide cover — exclude it from
			# the upcoming search so we pick the next best candidate.
			skip_committed_id = _target_island_id
			break

	for isl in islands:
		if isl["id"] == skip_committed_id:
			continue
		var center_2d: Vector2 = isl["center"]
		var isl_pos = Vector3(center_2d.x, 0.0, center_2d.y)
		var isl_radius: float = isl["radius"]

		var hide_h: float
		if threats.size() > 0:
			hide_h = ctx.behavior._compute_hide_heading(isl_pos, threats)
		else:
			hide_h = atan2(ctx.behavior._cached_safe_dir.x, ctx.behavior._cached_safe_dir.z)

		# Always sort candidate positions on the island by proximity to the ship
		var cover_result = ctx.behavior._find_cover_position_on_island(
			isl_pos, isl_radius, hide_h, threats, targets, true
		)
		# Only consider islands where we can actually shoot from cover
		if cover_result.is_empty() or not cover_result["can_shoot"]:
			continue

		var dest: Vector3 = cover_result["pos"]

		if prioritize_cover:
			# Nearest viable island — return immediately (list is already sorted)
			return {
				"id": isl["id"],
				"center": isl_pos,
				"radius": isl_radius,
				"dest": dest,
				"can_shoot": true,
			}

		# ── Range-optimising mode ────────────────────────────────────────────
		# Find the nearest non-DD enemy cluster to score engagement distance.
		var nearest_cluster_dist = INF
		var nearest_cluster_valid = false
		for cluster in enemy_clusters:
			var d = dest.distance_to(cluster.center)
			if d < nearest_cluster_dist:
				for cluster_ship: Ship in cluster.ships:
					if cluster_ship.ship_class != Ship.ShipClass.DD:
						nearest_cluster_dist = d
						nearest_cluster_valid = true
						break

		var score: float
		if nearest_cluster_valid:
			if nearest_cluster_dist > gun_range or nearest_cluster_dist < min_safe_range:
				continue
			score = absf(1.0 - nearest_cluster_dist / desired_range)
		else:
			# No cluster data — fall back to proximity score
			score = maxf(isl_pos.distance_to(my_pos) - isl_radius, 0.0)

		if score < best_score:
			best_score = score
			best_id = isl["id"]
			best_pos = isl_pos
			best_radius = isl_radius
			best_dest = dest
			best_can_shoot = true

	if best_id < 0:
		return {}

	return {
		"id": best_id,
		"center": best_pos,
		"radius": best_radius,
		"dest": best_dest,
		"can_shoot": best_can_shoot,
	}


func _set_island(island: Dictionary) -> void:
	if _target_island_id != island["id"]:
		# Switching islands — cached position belongs to the old island.
		_last_valid_cover_pos_set = false
	_target_island_id = island["id"]
	_target_island_pos = island["center"]
	_target_island_radius = island["radius"]
	_nav_destination = island["dest"]
	_nav_destination_valid = true


# ---------------------------------------------------------------------------
# Returns true if any valid target can be hit with a ballistic arc from
# from_pos.  Mirrors the shootability check in execute().
# ---------------------------------------------------------------------------
func _can_shoot_from(ctx: SkillContext, from_pos: Vector3, targets: Array) -> bool:
	var ship = ctx.ship
	var shell_params = ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return false
	var gun_range = ship.artillery_controller.get_params()._range
	for t_ship in targets:
		if not is_instance_valid(t_ship) or not t_ship.health_controller.is_alive():
			continue
		var tgt = t_ship.global_position + t_ship.global_basis * ctx.behavior.target_aim_offset(t_ship)
		if from_pos.distance_to(tgt) > gun_range:
			continue
		var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(from_pos, tgt, shell_params)
		if sol[0] == null:
			continue
		var result = Gun.sim_can_shoot_over_terrain_static(from_pos, sol[0], sol[1], shell_params, ship)
		if result.can_shoot_over_terrain:
			return true
	return false


func is_complete(_ctx: SkillContext) -> bool:
	return _arrived


func get_dist() -> float:
	return _dist_to_dest


func reset() -> void:
	_target_island_id = -1
	_nav_destination_valid = false
	_arrived = false
	can_shoot = false
	_last_valid_cover_pos_set = false


# ---------------------------------------------------------------------------
# Returns true if the current cover destination is reasonably "on the way"
# relative to the optimal engagement heading toward `nearest`.
#
# Angle tolerance scales with distance to cover:
#   70° when cover is <= 1000 m away  (almost there — accept wide detours)
#   10° when cover is >= 5000 m away  (far detour is too costly)
#
# Call this AFTER execute() so that _nav_destination is up to date.
# ---------------------------------------------------------------------------
func is_cover_on_the_way(ctx: SkillContext, nearest: Ship) -> bool:
	if not _nav_destination_valid:
		return false
	var ship = ctx.ship
	var to_cover = _nav_destination - ship.global_position
	to_cover.y = 0.0
	var dist_to_cover = to_cover.length()
	if dist_to_cover < 750.0:
		return true

	var t = clampf((dist_to_cover - 750.0) / 4000.0, 0.0, 1.0)
	var angle_tol = lerpf(deg_to_rad(65.0), deg_to_rad(20.0), t)

	var to_nearest = nearest.global_position - ship.global_position
	to_nearest.y = 0.0
	var enemy_bearing = atan2(to_nearest.x, to_nearest.z)
	var optimal_heading = SkillAngle.calc_heading(enemy_bearing, ctx, {})
	var cover_bearing = atan2(to_cover.x, to_cover.z) if dist_to_cover > 1.0 else optimal_heading
	var bearing_diff = absf(angle_difference(optimal_heading, cover_bearing))

	return bearing_diff <= angle_tol
