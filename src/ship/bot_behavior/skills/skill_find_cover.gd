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
var _last_valid_intent: NavIntent = null

const _TEAM_COVER_CLAIM_TTL_MS: int = 6000
const _TEAM_COVER_MIN_SEPARATION_MULT: float = 3.0

# Team-shared reservations: team_id -> ship_instance_id -> claim dictionary
# claim = {"pos": Vector3, "island_id": int, "updated_ms": int}
static var _team_cover_claims: Dictionary = {}

# Last key used by this skill instance; allows reset() to release reservation.
var _claimed_team_id: int = -1
var _claimed_ship_id: int = -1


func execute(ctx: SkillContext, params: Dictionary, prioritize_cover: bool = true) -> NavIntent:
	if _last_valid_intent != null and _is_last_intent_still_valid(ctx, params):
		if _target_island_id >= 0:
			_reserve_cover_claim(ctx, {
				"id": _target_island_id,
				"dest": _last_valid_intent.target_position,
			})
		return _last_valid_intent

	# var ship = ctx.ship
	# var target = ctx.target
	# var desired_range = params.get("desired_range", ship.artillery_controller.get_params()._range * 0.6)
	# var recalc_cooldown = params.get("recalc_cooldown_ms", 3000)

	# # Find initial island if we don't have one yet
	# if not _nav_destination_valid:
	# 	var island = _get_cover_position(ctx, desired_range, target, prioritize_cover)
	# 	if island.is_empty():
	# 		return null  # No cover available — caller falls back
	# 	_set_island(island)

	# # Periodically recalculate cover position
	# var now_ms = Time.get_ticks_msec()
	# if now_ms - _cover_recalc_ms >= recalc_cooldown:
	# 	_cover_recalc_ms = now_ms
	# 	var island: Dictionary
	# 	if _target_island_id >= 0:
	# 		# Already in cover: prefer staying on the same island, only move if
	# 		# it can no longer provide a shootable position.
	# 		island = _recalc_same_island(ctx, target)
	# 		if island.is_empty():
	# 			# Committed island can no longer provide cover while arrived —
	# 			# clear commitment so _get_cover_position skips it and picks
	# 			# the next viable candidate.
	# 			_target_island_id = -1
	# 			island = _get_cover_position(ctx, desired_range, target, prioritize_cover)
	# 	else:
	# 		# Not yet arrived — _get_cover_position will honour the commitment
	# 		# internally: try the cached island first, skip it on failure.
	# 		island = _get_cover_position(ctx, desired_range, target, prioritize_cover)

	# 	if not island.is_empty():
	# 		_set_island(island)
	# 	elif not _nav_destination_valid:
	# 		return null  # No cover available and no previous destination to fall back on

	# # Approach / station-keep
	# var dist = ship.global_position.distance_to(_nav_destination)
	# _dist_to_dest = dist
	# var clearance = ctx.behavior._get_ship_clearance()
	# var arrival_radius = clearance * 2.0
	# var exit_radius = clearance * 3.5
	# _arrived = dist < exit_radius if _arrived else dist < arrival_radius

	var d = _get_cover_position(ctx, params)
	if d.is_empty():
		_release_cover_claim()
		_last_valid_intent = null
		return null
	_set_island(d)
	_reserve_cover_claim(ctx, d)
	# "id": isl["id"],
	# "center": isl_pos,
	# "radius": isl_radius,
	# "dest": dest,
	# "can_shoot": true,
	var heading = ctx.behavior._tangential_heading(_target_island_pos, _nav_destination)
	var intent := NavIntent.create(d["dest"], heading)
	_last_valid_intent = intent

	return intent


	# var heading = ctx.behavior._tangential_heading(_target_island_pos, _nav_destination)

	# # Check shootability (shell arc over terrain) from current or destination position
	# can_shoot = false
	# var check_pos = ship.global_position if _arrived else _nav_destination
	# var shell_params = ship.artillery_controller.get_shell_params()
	# var gun_range = ship.artillery_controller.get_params()._range
	# if shell_params != null:
	# 	for enemy in ctx.server.get_valid_targets(ship.team.team_id):
	# 		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
	# 			continue
	# 		var tgt = enemy.global_position + enemy.global_basis * ctx.behavior.target_aim_offset(enemy)
	# 		if check_pos.distance_to(tgt) > gun_range:
	# 			continue
	# 		var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(check_pos, tgt, shell_params)
	# 		if sol[0] == null:
	# 			continue
	# 		var result = Gun.sim_can_shoot_over_terrain_static(check_pos, sol[0], sol[1], shell_params, ship)
	# 		if result.can_shoot_over_terrain:
	# 			can_shoot = true
	# 			break

	# var broadside_bias: float = params.get("broadside_bias", 0.4)

	# if _arrived:
	# 	var arrived_intent = NavIntent.create(_nav_destination, heading, arrival_radius * 0.5)
	# 	arrived_intent.near_terrain = true
	# 	arrived_intent.skip_threat_adjustment = true
	# 	return _broadside.apply(arrived_intent, ctx, {"oscillation_bias": broadside_bias})

	# var intent = NavIntent.create(_nav_destination, heading)
	# intent.near_terrain = true
	# intent.skip_threat_adjustment = true
	# return _broadside.apply(intent, ctx, {"oscillation_bias": broadside_bias})
	# _get_cover_position(ctx)


func _resolve_min_cover_separation(ctx: SkillContext, params: Dictionary) -> float:
	var default_sep = ctx.behavior._get_ship_clearance() * _TEAM_COVER_MIN_SEPARATION_MULT
	return params.get("min_cover_separation", default_sep)

func _prune_team_cover_claims(team_id: int, now_ms: int) -> void:
	if not _team_cover_claims.has(team_id):
		return
	var team_claims: Dictionary = _team_cover_claims[team_id]
	for ship_id in team_claims.keys():
		var entry: Dictionary = team_claims[ship_id]
		if now_ms - int(entry.get("updated_ms", 0)) > _TEAM_COVER_CLAIM_TTL_MS:
			team_claims.erase(ship_id)
	if team_claims.is_empty():
		_team_cover_claims.erase(team_id)
	else:
		_team_cover_claims[team_id] = team_claims

func _collect_other_claim_positions(ctx: SkillContext) -> Array:
	var claims: Array = []
	if ctx.server == null or ctx.ship == null:
		return claims
	var team_id = ctx.ship.team.team_id
	var now_ms = Time.get_ticks_msec()
	_prune_team_cover_claims(team_id, now_ms)
	if not _team_cover_claims.has(team_id):
		return claims
	var my_ship_id = ctx.ship.get_instance_id()
	var team_claims: Dictionary = _team_cover_claims[team_id]
	for ship_id in team_claims.keys():
		if int(ship_id) == my_ship_id:
			continue
		var entry: Dictionary = team_claims[ship_id]
		var p: Vector3 = entry.get("pos", Vector3.ZERO)
		if p != Vector3.ZERO:
			claims.append(p)
	return claims

func _has_cover_spacing_conflict(pos: Vector3, claim_positions: Array, min_cover_separation: float) -> bool:
	if min_cover_separation <= 0.0 or claim_positions.is_empty():
		return false
	for claim_pos in claim_positions:
		if pos.distance_to(claim_pos) < min_cover_separation:
			return true
	return false

func _reserve_cover_claim(ctx: SkillContext, island: Dictionary) -> void:
	if ctx.server == null or ctx.ship == null:
		return
	var team_id = ctx.ship.team.team_id
	var ship_id = ctx.ship.get_instance_id()
	var now_ms = Time.get_ticks_msec()
	_prune_team_cover_claims(team_id, now_ms)
	var team_claims: Dictionary = _team_cover_claims.get(team_id, {})
	team_claims[ship_id] = {
		"pos": island["dest"],
		"island_id": island["id"],
		"updated_ms": now_ms,
	}
	_team_cover_claims[team_id] = team_claims
	_claimed_team_id = team_id
	_claimed_ship_id = ship_id

func _release_cover_claim() -> void:
	if _claimed_team_id < 0 or _claimed_ship_id < 0:
		return
	if _team_cover_claims.has(_claimed_team_id):
		var team_claims: Dictionary = _team_cover_claims[_claimed_team_id]
		team_claims.erase(_claimed_ship_id)
		if team_claims.is_empty():
			_team_cover_claims.erase(_claimed_team_id)
		else:
			_team_cover_claims[_claimed_team_id] = team_claims
	_claimed_team_id = -1
	_claimed_ship_id = -1


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
	var max_desired_range = ship.artillery_controller.get_params()._range * 0.7
	var min_cover_separation = ctx.behavior._get_ship_clearance() * _TEAM_COVER_MIN_SEPARATION_MULT
	var other_claim_positions = _collect_other_claim_positions(ctx)

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
			var cached_conflict = _has_cover_spacing_conflict(cached_pos, other_claim_positions, min_cover_separation)
			if (targets.is_empty() or can_shoot_cached) and not cached_conflict:
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
			var current_conflict = _has_cover_spacing_conflict(my_pos, other_claim_positions, min_cover_separation)
			if (targets.is_empty() or can_shoot_here) and not current_conflict:
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
		_target_island_pos,
		_target_island_radius,
		hide_h,
		threats,
		targets,
		max_desired_range,
		other_claim_positions,
		min_cover_separation
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

var curr_dest_island_id: int = -1
var curr_dest_island_pos: Vector3 = Vector3.ZERO
var curr_heading: float = 0.0

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
func _get_cover_position(ctx: SkillContext, params: Dictionary) -> Dictionary:
	if not NavigationMapManager.is_map_ready():
		return {}

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return {}

	var ship = ctx.ship
	var my_pos = ship.global_position
	var gun_range = ship.artillery_controller.get_params()._range
	var max_desired_range = gun_range * params.get("max_range", 0.7)
	# var min_safe_range = gun_range * 0.35

	var threats = ctx.behavior._gather_threat_positions(ship)
	if ctx.server == null:
		return {}
	var targets = ctx.server.get_valid_targets(ship.team.team_id)
	# var enemy_clusters = ctx.server.get_enemy_clusters(ship.team.team_id)

	ctx.behavior._ensure_safe_dir(ship, ctx.server)
	var min_cover_separation = _resolve_min_cover_separation(ctx, params)
	var other_claim_positions = _collect_other_claim_positions(ctx)

	# Pre-compute a hide-aware travel cost for each island so the sort
	# comparator stays O(1) per comparison.  Cost combines:
	#   - edge_dist : distance from the ship to the nearest island edge
	#   - arc_cost  : arc the ship must travel around the island to reach
	#                 the hide side = angle_diff (0..PI) * island_radius
	# The hide side of every island is the face pointing directly away from
	# the spotted danger centre -- one shared reference point, computed once.
	# When there is no danger centre (no enemies), arc_cost is always 0 so the
	# sort reduces to a pure proximity sort, which is exactly what we want.
	var _danger_center: Vector3 = ctx.behavior._get_spotted_danger_center()
	var _use_danger_center: bool = _danger_center != Vector3.ZERO

	var _island_travel_cost: Dictionary = {}
	for _sort_isl in islands:
		var _sc2d: Vector2 = _sort_isl["center"]
		var _sisl_pos := Vector3(_sc2d.x, 0.0, _sc2d.y)
		var _sisl_radius: float = _sort_isl["radius"]
		var _edge_dist := maxf(my_pos.distance_to(_sisl_pos) - _sisl_radius, 0.0)

		var _arc_cost := 0.0
		if _use_danger_center:
			# Hide direction: from danger centre toward island centre (the far side).
			var _hide_dir := _sisl_pos - _danger_center
			_hide_dir.y = 0.0
			# Ship direction: from island centre toward the ship.
			var _ship_dir: Vector3 = my_pos - _sisl_pos
			_ship_dir.y = 0.0
			if _hide_dir.length_squared() > 1.0 and _ship_dir.length_squared() > 1.0:
				var _cos_a := _hide_dir.normalized().dot(_ship_dir.normalized())
				# acos gives the unsigned angle (0..PI) between the two directions.
				_arc_cost = acos(clampf(_cos_a, -1.0, 1.0)) * _sisl_radius

		_island_travel_cost[_sort_isl["id"]] = _edge_dist + _arc_cost

	# Sort islands by estimated navigation cost; committed island is kept
	# first as long as it is still within firing range.
	islands.sort_custom(func(a, b):
		var ca = Vector3(a["center"].x, 0.0, a["center"].y)
		if a["id"] == _target_island_id and my_pos.distance_to(ca) - a["radius"] < max_desired_range:
			return true
		return _island_travel_cost[a["id"]] < _island_travel_cost[b["id"]]
	)

	# ── No-enemy shortcut ────────────────────────────────────────────────────
	# When there are no known threats or valid targets, skip the full cover
	# search.  The islands are already sorted nearest-first (arc_cost == 0 with
	# no danger centre), so just walk the list and return the first island that
	# has no spacing conflict.  Honour any existing island commitment via the
	# sort comparator above (committed island sorts first when in range).
	if threats.is_empty() and targets.is_empty():
		for isl in islands:
			var c2d: Vector2 = isl["center"]
			var isl_pos := Vector3(c2d.x, 0.0, c2d.y)
			var isl_radius: float = isl["radius"]
			var away_dir := isl_pos.normalized() if isl_pos.length() > 0.01 else Vector3(1.0, 0.0, 0.0)
			var dest := isl_pos + away_dir * isl_radius * 0.9
			if not _has_cover_spacing_conflict(dest, other_claim_positions, min_cover_separation):
				return {
					"id": isl["id"],
					"center": isl_pos,
					"radius": isl_radius,
					"dest": dest,
					"can_shoot": false,
				}
		return {}

	var spacing_conflict_fallback: Dictionary = {}

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
			isl_pos,
			isl_radius,
			hide_h,
			threats,
			targets,
			max_desired_range,
			other_claim_positions,
			min_cover_separation
		)
		# Only consider islands where we can actually shoot from cover
		if cover_result.is_empty() or not cover_result["can_shoot"]:
			continue

		var dest: Vector3 = cover_result["pos"]
		var island_result := {
			"id": isl["id"],
			"center": isl_pos,
			"radius": isl_radius,
			"dest": dest,
			"can_shoot": true,
		}

		if cover_result.get("spacing_conflict", false):
			if spacing_conflict_fallback.is_empty():
				spacing_conflict_fallback = island_result
			continue

		# if prioritize_cover:
		# Nearest viable island — return immediately (list is already sorted)
		return island_result

	if not spacing_conflict_fallback.is_empty():
		return spacing_conflict_fallback

	return {}


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
func _is_last_intent_still_valid(ctx: SkillContext, params: Dictionary) -> bool:
	if _last_valid_intent == null or not _nav_destination_valid:
		return false
	if ctx.ship == null or ctx.server == null:
		return false
	var pos: Vector3 = _last_valid_intent.target_position
	var ship = ctx.ship

	# if an island is outside desired range, its validity is ignored for better cover options
	if pos.distance_to(ship.global_position) > ship.artillery_controller.get_params()._range * 1.0: # adjust to 1 for more safety
		return false

	var threats = ctx.behavior._gather_threat_positions(ship)
	for threat_pos in threats:
		if not ctx.behavior._is_los_blocked_with_clearance(pos, threat_pos):
			return false

	var targets = ctx.server.get_valid_targets(ship.team.team_id)
	var can_shoot_here := targets.is_empty() or _can_shoot_from(ctx, pos, targets)
	if not can_shoot_here:
		return false

	var min_cover_separation = _resolve_min_cover_separation(ctx, params)
	var other_claim_positions = _collect_other_claim_positions(ctx)
	if _has_cover_spacing_conflict(pos, other_claim_positions, min_cover_separation):
		return false

	can_shoot = not targets.is_empty()
	return true


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
	_release_cover_claim()
	_target_island_id = -1
	_nav_destination_valid = false
	_arrived = false
	can_shoot = false
	_last_valid_cover_pos_set = false
	_last_valid_intent = null


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
	var angle_tol = lerpf(deg_to_rad(75.0), deg_to_rad(15.0), t)

	var to_nearest = nearest.global_position - ship.global_position
	to_nearest.y = 0.0
	var enemy_bearing = atan2(to_nearest.x, to_nearest.z)
	var optimal_heading = SkillAngle.calc_heading(ctx, {})
	var cover_bearing = atan2(to_cover.x, to_cover.z) if dist_to_cover > 1.0 else optimal_heading
	var bearing_diff = absf(angle_difference(optimal_heading, cover_bearing))
	if bearing_diff > PI / 2.0: # bearing is behind us
		bearing_diff = PI - bearing_diff # convert to smaller angle on the other side

	return bearing_diff <= angle_tol
