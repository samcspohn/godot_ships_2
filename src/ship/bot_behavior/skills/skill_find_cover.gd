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
		if _arrived and _target_island_id >= 0:
			# Already in cover: prefer staying on the same island, only move if
			# it can no longer provide a shootable position.
			island = _recalc_same_island(ctx, target)
			if island.is_empty():
				island = _get_cover_position(ctx, desired_range, target, prioritize_cover)
		else:
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
			var tgt = enemy.global_position + ctx.behavior.target_aim_offset(enemy)
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
		return _broadside.apply(arrived_intent, ctx, {"oscillation_bias": broadside_bias})

	var intent = NavIntent.create(_nav_destination, heading)
	intent.near_terrain = true
	return _broadside.apply(intent, ctx, {"oscillation_bias": broadside_bias})


# ---------------------------------------------------------------------------
# Recalculate the best position on the island we are already holding.
# Returns empty dict if the island can no longer provide a shootable position.
# ---------------------------------------------------------------------------
func _recalc_same_island(ctx: SkillContext, _target: Ship) -> Dictionary:
	var ship = ctx.ship
	var threats = ctx.behavior._gather_threat_positions(ship)
	var targets = ctx.server.get_valid_targets(ship.team.team_id)
	ctx.behavior._ensure_safe_dir(ship, ctx.server)

	var hide_h: float
	if threats.size() > 0:
		hide_h = ctx.behavior._compute_hide_heading(_target_island_pos, threats)
	else:
		hide_h = atan2(ctx.behavior._cached_safe_dir.x, ctx.behavior._cached_safe_dir.z)

	var cover_result = ctx.behavior._find_cover_position_on_island(
		_target_island_pos, _target_island_radius, hide_h, threats, targets, true
	)
	if cover_result.is_empty() or not cover_result["can_shoot"]:
		return {}

	return {
		"id": _target_island_id,
		"center": _target_island_pos,
		"radius": _target_island_radius,
		"dest": cover_result["pos"],
		"can_shoot": cover_result["can_shoot"],
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

	for isl in islands:
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
	_target_island_id = island["id"]
	_target_island_pos = island["center"]
	_target_island_radius = island["radius"]
	_nav_destination = island["dest"]
	_nav_destination_valid = true


func is_complete(_ctx: SkillContext) -> bool:
	return _arrived


func get_dist() -> float:
	return _dist_to_dest


func reset() -> void:
	_target_island_id = -1
	_nav_destination_valid = false
	_arrived = false
	can_shoot = false
