extends BotBehavior
class_name CABehavior

var ammo = ShellParams.ShellType.HE

# ============================================================================
# STATE TRACKING
# ============================================================================

# Has the ship ever detected an enemy?
var _ever_spotted_enemy: bool = false

# Cover zone state — SDF-cell-based
var _cover_island_id: int = -1
var _cover_zone_valid: bool = false
var _cover_zone_center: Vector3 = Vector3.ZERO
var _cover_zone_radius: float = 200.0
var _cover_zone_heading: float = 0.0
var _cover_zone_timer: float = 0.0
var _cover_can_shoot: bool = false
const COVER_ZONE_RECOMPUTE_INTERVAL: float = 4.0
const COVER_SPOTTED_RECOMPUTE_INTERVAL: float = 0.5

# Async ballistic validation
var _cover_candidates: Array = []
var _cover_eval_index: int = 0
var _cover_eval_in_progress: bool = false
var _cover_eval_target: Ship = null
var _cover_eval_danger_center: Vector3 = Vector3.ZERO
const COVER_CANDIDATES_PER_FRAME: int = 2

# Island metadata cache
var _cover_island_center: Vector3 = Vector3.ZERO
var _cover_island_radius: float = 0.0
var _prev_cover_island_id: int = -1

# Visibility tracking for reactive recompute
var _was_visible_last_frame: bool = false

# Cached spawn direction (toward our spawn = "safe" direction behind islands)
var _cached_spawn_dir: Vector3 = Vector3.ZERO
var _spawn_dir_initialized: bool = false

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(30),
		max_angle = deg_to_rad(45),
		evasion_period = 5.0,
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 2.5
		Ship.ShipClass.CA: return 1.2
		Ship.ShipClass.DD: return 0.5
	return 1.0

func get_target_weights() -> Dictionary:
	return {
		size_weight = 0.4,
		range_weight = 0.6,
		hp_weight = 0.0,
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.2,
			Ship.ShipClass.DD: 1.5,
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
		flanking_multiplier = 5.0,
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.55,
		range_increase_when_damaged = 0.40,
		min_safe_distance_ratio = 0.40,
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 2000.0,
		spread_multiplier = 2.0,
	}

func get_island_cover_params() -> Dictionary:
	return {
		aggressive_range = 0.60,
		defensive_range = 0.70,
		abandon_too_close = 0.35,
		abandon_too_far = 0.80,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.3,
		cautious_hp_threshold = 0.5,
		use_island_cover = false,  # When hunting, we don't want cover — we want to find enemies
	}

func should_evade(_destination: Vector3) -> bool:
	"""CA-specific: Only evade when visible and either in cover or no cover available."""
	if not _ship.visible_to_enemy:
		return false

	if is_in_cover:
		return true

	# If we have a valid cover destination, don't evade — prioritize reaching it
	if _cover_zone_valid and _cover_island_id >= 0:
		return false

	# V3 path compatibility
	if island_position_valid and current_island != null:
		return false

	return true

# ============================================================================
# TARGET SELECTION
# ============================================================================

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	var weights = get_target_weights()
	var gun_range = _ship.artillery_controller.get_params()._range

	var best_target: Ship = null
	var best_priority: float = -1.0

	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp

		var priority: float = ship.movement_controller.ship_length / dist * abs(sin(angle)) + ship.movement_controller.ship_beam / dist * abs(cos(angle))

		var class_mods: Dictionary = weights.class_modifiers
		if class_mods.has(ship.ship_class):
			priority *= class_mods[ship.ship_class]

		priority *= 1.5 - hp_ratio

		priority = priority * weights.size_weight + (1.0 - dist / gun_range) * weights.range_weight

		if dist <= gun_range:
			priority *= weights.in_range_multiplier

		var flank_info = _get_flanking_info(ship)
		if flank_info.is_flanking:
			var flank_multiplier = weights.get("flanking_multiplier", 5.0)
			var depth_scale = 1.0 + flank_info.penetration_depth
			priority *= flank_multiplier * depth_scale

		if priority > best_priority:
			best_target = ship
			best_priority = priority

	return best_target

# ============================================================================
# AMMO AND AIM
# ============================================================================

func pick_ammo(_target: Ship) -> int:
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var dist = disp.length()
	var offset = Vector3.ZERO

	ammo = ShellParams.ShellType.HE

	var is_broadside = abs(sin(angle)) > sin(deg_to_rad(60))

	match _target.ship_class:
		Ship.ShipClass.BB:
			if is_broadside and dist < 6000:
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 4
			else:
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			if is_broadside:
				if dist < 7000:
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				elif dist < 10000:
					ammo = ShellParams.ShellType.AP
					offset.y = _target.movement_controller.ship_height / 4
				else:
					ammo = ShellParams.ShellType.HE
					offset.y = _target.movement_controller.ship_height / 3
			else:
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 3
		Ship.ShipClass.DD:
			ammo = ShellParams.ShellType.HE
			offset.y = 1.0
	return offset

# ============================================================================
# POSITIONING — get_desired_position (V3 legacy interface)
# ============================================================================

func get_desired_position(friendly: Array[Ship], _enemy: Array[Ship], _target: Ship, current_destination: Vector3) -> Vector3:
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	var danger_center = _get_danger_center()

	# --- STATE 1: No enemies known at all → find nearest island ---
	if danger_center == Vector3.ZERO and not _ever_spotted_enemy:
		var island = _find_island_toward_position(_ship.global_position, INF)
		if island != null and server_node != null and server_node.map != null:
			if server_node.map.island_edge_points.has(island):
				var edge_points = server_node.map.island_edge_points[island]
				if edge_points.size() > 0:
					var closest_point = edge_points[0]
					for island_point in edge_points:
						if island_point.distance_to(_ship.global_position) < closest_point.distance_to(_ship.global_position):
							closest_point = island_point
					return _get_valid_nav_point(closest_point)
		# No island found — sail forward
		var fallback = _ship.global_position - _ship.basis.z * 10_000
		fallback.y = 0
		return _get_valid_nav_point(fallback)

	# --- STATE 3: Enemies were seen before but none visible now → hunt ---
	if danger_center == Vector3.ZERO and _ever_spotted_enemy:
		var hunt_dest = _get_hunting_position(server_node, friendly, current_destination)
		if hunt_dest != Vector3.ZERO:
			return hunt_dest
		var fallback = _ship.global_position - _ship.basis.z * 10_000
		fallback.y = 0
		return _get_valid_nav_point(fallback)

	# --- STATE 2: Enemy spotted → tactical island cover ---
	_ever_spotted_enemy = true

	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	var nearest = _get_nearest_enemy()
	var dist_to_nearest = INF
	if not nearest.is_empty():
		dist_to_nearest = nearest.distance

	# Try to find an island within gun range of the target and close to us
	island_cache_timer -= 1.0 / Engine.physics_ticks_per_second
	if island_cache_timer <= 0 or not island_position_valid:
		island_cache_timer = ISLAND_CACHE_DURATION
		current_island = find_optimal_island(danger_center, gun_range, hp_ratio, dist_to_nearest)
		island_position_valid = current_island != null

	if island_position_valid and current_island != null:
		var cover_pos = get_island_cover_position(current_island, danger_center, gun_range)
		if cover_pos != Vector3.ZERO:
			var dist_to_cover = _ship.global_position.distance_to(cover_pos)
			is_in_cover = dist_to_cover < IN_COVER_THRESHOLD

			if is_in_cover and not _ship.visible_to_enemy:
				return _ship.global_position

			if is_in_cover and _ship.visible_to_enemy:
				var island_pos = current_island.global_position
				var to_island = island_pos - _ship.global_position
				var dist_to_island = to_island.length()
				var island_radius = get_island_radius(current_island)
				var min_safe_dist = island_radius + MIN_ISLAND_COVER_DISTANCE

				if dist_to_island > min_safe_dist + 50.0:
					var closer_pos = island_pos + (-to_island.normalized()) * min_safe_dist
					closer_pos.y = 0.0
					return _get_valid_nav_point(closer_pos)
				else:
					is_in_cover = false
					island_position_valid = false
					current_island = null
					return _get_tactical_fallback_position(gun_range, hp_ratio, friendly)

			return cover_pos

	is_in_cover = false
	return _get_tactical_fallback_position(gun_range, hp_ratio, friendly)


func _get_tactical_fallback_position(gun_range: float, hp_ratio: float, friendly: Array[Ship]) -> Vector3:
	"""Tactical positioning when no cover is available."""
	var params = get_positioning_params()

	var range_increase = clamp((1.0 - hp_ratio) * params.range_increase_when_damaged, 0.0, params.range_increase_when_damaged)
	var engagement_range = (params.base_range_ratio + range_increase) * gun_range
	var min_safe_distance = gun_range * params.min_safe_distance_ratio
	var flank_bias = lerp(params.flank_bias_healthy, params.flank_bias_damaged, 1.0 - hp_ratio)

	var desired_position = _calculate_tactical_position(engagement_range, min_safe_distance, flank_bias)
	desired_position += _calculate_spread_offset(friendly, params.spread_distance, params.spread_multiplier)

	return _get_valid_nav_point(desired_position)

# ============================================================================
# NAVINTENT — V4 bot controller interface (primary entry point)
# ============================================================================

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	"""CA navigation intent with three clear states:
	1. No enemy ever spotted → go to nearest island
	2. Enemy spotted → find island within gun range of target, closest to us
	3. Enemies were seen but lost → hunt (no cover seeking)

	IMPORTANT: All cover navigation uses STATION_KEEP so the navigator handles
	approach, holding, and overshoot recovery internally with proper pathfinding."""

	# Initialize spawn direction cache (for "behind island" calculations)
	_ensure_spawn_dir(ship, server)

	var friendly = server.get_team_ships(ship.team.team_id)
	var visible_enemies = server.get_valid_targets(ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var danger_center = _get_danger_center()

	var has_visible_enemies = visible_enemies.size() > 0
	var has_last_spotted = not unspotted.is_empty()

	# Track whether we've ever seen an enemy
	if has_visible_enemies or has_last_spotted:
		_ever_spotted_enemy = true

	# ---------------------------------------------------------------
	# STATE 1: Never spotted any enemy → go to nearest island
	# ---------------------------------------------------------------
	if not _ever_spotted_enemy:
		var island_intent = _find_nearest_island_intent(ship)
		if island_intent != null:
			return island_intent
		# No island — sail forward
		var fwd = -ship.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length_squared() < 0.1:
			fwd = Vector3(0, 0, -1)
		var dest = ship.global_position + fwd.normalized() * 5000.0
		dest.y = 0.0
		dest = _get_valid_nav_point(dest)
		return NavIntent.pose(dest, atan2(fwd.x, fwd.z))

	# ---------------------------------------------------------------
	# STATE 3: Enemies were seen before but none currently visible → HUNT
	# (no cover seeking — actively look for enemies)
	# ---------------------------------------------------------------
	if not has_visible_enemies and _ever_spotted_enemy:
		_invalidate_cover()
		return _get_hunting_intent(ship, server, friendly)

	# ---------------------------------------------------------------
	# STATE 2: Enemy currently spotted → tactical island cover
	# Find island that is:
	#   a) within our gun range of the target
	#   b) of those, the closest one to our ship
	# ---------------------------------------------------------------
	_ever_spotted_enemy = true

	var gun_range = ship.artillery_controller.get_params()._range
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp

	# Advance async ballistic evaluation if in progress
	if _cover_eval_in_progress:
		_advance_ballistic_eval(ship)

	# Reactive recompute triggers
	var just_became_visible = ship.visible_to_enemy and not _was_visible_last_frame
	_was_visible_last_frame = ship.visible_to_enemy

	var dt = 1.0 / Engine.physics_ticks_per_second
	_cover_zone_timer -= dt

	var recompute_interval = COVER_ZONE_RECOMPUTE_INTERVAL
	if ship.visible_to_enemy:
		recompute_interval = COVER_SPOTTED_RECOMPUTE_INTERVAL

	var should_recompute = _cover_zone_timer <= 0 or not _cover_zone_valid or just_became_visible
	if should_recompute:
		_cover_zone_timer = recompute_interval
		_recompute_tactical_cover(ship, target, danger_center, gun_range, hp_ratio)

	# If we found a valid cover position, navigate to it
	if _cover_zone_valid:
		# Check if we're visible but all enemies are LOS-blocked by terrain.
		# If so, we need a STRONGER cover position (tuck behind the island
		# toward our spawn side) rather than sitting exposed.
		if ship.visible_to_enemy:
			var all_blocked = _are_all_enemies_los_blocked(ship, server)
			if all_blocked:
				return _get_stronger_cover_intent(ship, gun_range)

		return _navigate_to_cover(ship)

	# No cover available — kite in the open
	return _get_kiting_intent(ship, target, friendly, danger_center, gun_range, hp_ratio)

# ============================================================================
# STATE 1: NEAREST ISLAND (no enemies known)
# ============================================================================

func _find_nearest_island_intent(ship: Ship) -> NavIntent:
	"""Find the nearest island and navigate to its near side.
	Uses POSE for approach (proper pathfinding) and STATION_KEEP when arrived."""

	if not NavigationMapManager.is_map_ready():
		return null

	# If we already have a valid cover position, navigate to it
	if _cover_zone_valid and _cover_island_id >= 0:
		var dist_to_cover = ship.global_position.distance_to(_cover_zone_center)
		var hold_radius = min(_cover_zone_radius, 250.0)
		if dist_to_cover < hold_radius:
			# Arrived — hold position with STATION_KEEP
			is_in_cover = true
			return NavIntent.station(_cover_zone_center, hold_radius * 0.4, _cover_zone_heading)
		# Still approaching — use POSE so the navigator pathfinds to the cover position
		is_in_cover = false
		var intent = NavIntent.pose(_cover_zone_center, _cover_zone_heading)
		if dist_to_cover > 500.0:
			intent.throttle_override = 4
		elif dist_to_cover > 200.0:
			intent.throttle_override = 3
		return intent

	var my_pos = ship.global_position
	var ship_clearance: float = 100.0
	if ship.movement_controller:
		ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return null

	# Pick the nearest island by effective distance (center - radius)
	var best_island_id: int = -1
	var best_effective_dist: float = INF
	var best_island_pos: Vector3 = Vector3.ZERO
	var best_island_radius: float = 0.0

	for island_dict in islands:
		var island_id: int = island_dict["id"]
		var island_center_2d: Vector2 = island_dict["center"]
		var isl_radius: float = island_dict["radius"]
		var island_pos = Vector3(island_center_2d.x, 0.0, island_center_2d.y)

		var dist_to_center = island_pos.distance_to(my_pos)
		var effective_dist = dist_to_center - isl_radius

		if effective_dist < best_effective_dist:
			best_effective_dist = effective_dist
			best_island_id = island_id
			best_island_pos = island_pos
			best_island_radius = isl_radius

	if best_island_id < 0:
		return null

	# Find a position on the near side of the island using SDF walk
	var station_pos = _find_near_side_position(my_pos, best_island_pos, best_island_radius, ship_clearance)
	if station_pos == Vector3.ZERO:
		return null

	station_pos = _validate_cover_position(ship, station_pos, ship_clearance)

	var heading = _compute_tangential_heading(ship, best_island_pos)
	var zone_radius = clamp(ship_clearance * 1.5, 80.0, 200.0)

	# Store cover zone state
	_cover_island_id = best_island_id
	_cover_zone_valid = true
	_cover_zone_center = station_pos
	_cover_zone_radius = zone_radius
	_cover_zone_heading = heading
	_cover_zone_timer = COVER_ZONE_RECOMPUTE_INTERVAL
	_cover_island_center = best_island_pos
	_cover_island_radius = best_island_radius
	_prev_cover_island_id = best_island_id

	# Use POSE for the initial approach — the navigator will pathfind directly
	# to the cover position. Subsequent calls will check distance and switch
	# to STATION_KEEP once arrived (handled by the re-entry block above).
	var intent = NavIntent.pose(station_pos, heading)
	var dist_to_station = ship.global_position.distance_to(station_pos)
	if dist_to_station > 500.0:
		intent.throttle_override = 4
	elif dist_to_station > 200.0:
		intent.throttle_override = 3
	return intent

# ============================================================================
# STATE 2: TACTICAL ISLAND COVER (enemy spotted)
# ============================================================================

func _recompute_tactical_cover(ship: Ship, target: Ship, danger_center: Vector3, gun_range: float, _hp_ratio: float) -> void:
	"""Find the best island for cover when enemies are visible.
	Selection criteria:
	  1. Island must be within gun range of the danger center (so we can shoot)
	  2. Of those, pick the one closest to our ship (so we reach cover fast)
	Then run the SDF cover candidate search on that island."""

	var prev_island_id = _cover_island_id
	var had_eval_in_progress = _cover_eval_in_progress

	_cover_zone_valid = false
	_cover_island_id = -1

	if not NavigationMapManager.is_map_ready():
		_cover_eval_in_progress = false
		_cover_candidates.clear()
		return

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		_cover_eval_in_progress = false
		_cover_candidates.clear()
		return

	var my_pos = ship.global_position
	var ship_clearance: float = 100.0
	if ship.movement_controller:
		ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

	var threats = _gather_threat_positions(ship)

	# --- Filter islands within gun range of target, then pick closest to us ---
	var eligible_islands: Array = []

	for island_dict in islands:
		var island_id: int = island_dict["id"]
		var island_center_2d: Vector2 = island_dict["center"]
		var isl_radius: float = island_dict["radius"]
		var island_pos = Vector3(island_center_2d.x, 0.0, island_center_2d.y)

		# The island must be close enough to the danger center that we can
		# shoot from behind it.
		var island_to_danger = island_pos.distance_to(danger_center)
		if island_to_danger > gun_range * 0.9:
			continue

		var dist_to_us = island_pos.distance_to(my_pos)

		eligible_islands.append({
			"id": island_id,
			"center": island_pos,
			"radius": isl_radius,
			"dist_to_us": dist_to_us,
			"island_to_danger": island_to_danger,
		})

	if eligible_islands.is_empty():
		_cover_eval_in_progress = false
		_cover_candidates.clear()
		return

	# Sort by distance to us — closest first
	eligible_islands.sort_custom(func(a, b): return a["dist_to_us"] < b["dist_to_us"])

	var best_candidates: Array = []
	var best_island_entry: Dictionary = {}
	var best_cover_score: float = -INF

	# Evaluate top 3 closest islands with SDF search
	var max_to_eval = mini(3, eligible_islands.size())
	for i in range(max_to_eval):
		var entry = eligible_islands[i]
		var island_id: int = entry["id"]

		var candidates: Array = NavigationMapManager.find_cover_candidates(
			island_id, threats, danger_center, my_pos, ship_clearance, gun_range * 0.9
		)

		if candidates.is_empty():
			continue

		# Score: concealment quality + proximity bonus + stability bonus
		var top = candidates[0]
		var cover_score: float = float(top.get("hidden_count", 0)) * 1000.0
		cover_score -= entry["dist_to_us"] * 0.5
		# Bonus for staying at the same island
		if island_id == _prev_cover_island_id:
			cover_score += 400.0

		if cover_score > best_cover_score:
			best_cover_score = cover_score
			best_candidates = candidates
			best_island_entry = entry

	if best_candidates.is_empty():
		_cover_eval_in_progress = false
		_cover_candidates.clear()
		return

	# Apply the top candidate immediately
	var best_island_id: int = best_island_entry["id"]
	_cover_island_id = best_island_id
	_cover_island_center = best_island_entry["center"]
	_cover_island_radius = best_island_entry["radius"]
	_prev_cover_island_id = best_island_id

	var top_candidate: Dictionary = best_candidates[0]
	var cover_pos_2d: Vector2 = top_candidate["position"]
	var cover_pos = Vector3(cover_pos_2d.x, 0.0, cover_pos_2d.y)

	_cover_can_shoot = false
	cover_pos = _validate_cover_position(ship, cover_pos, ship_clearance)

	_cover_zone_center = cover_pos
	_cover_zone_heading = _compute_tangential_heading(ship, _cover_island_center)
	_cover_zone_valid = true
	_cover_zone_radius = clamp(ship_clearance * 2.0, 100.0, 250.0)

	# Start async ballistic evaluation
	var island_changed = best_island_id != prev_island_id
	if island_changed or not had_eval_in_progress:
		_cover_candidates = best_candidates
		_cover_eval_index = 0
		_cover_eval_in_progress = true
		_cover_eval_target = target
		_cover_eval_danger_center = danger_center
	else:
		_cover_eval_target = target
		_cover_eval_danger_center = danger_center


func _navigate_to_cover(ship: Ship) -> NavIntent:
	"""Navigate to the current cover zone position.
	Uses POSE for approach (proper pathfinding with waypoints) and switches to
	STATION_KEEP only when arrived in cover for position holding."""
	var hold_radius = min(_cover_zone_radius, 250.0)
	var dist_to_cover = ship.global_position.distance_to(_cover_zone_center)
	is_in_cover = dist_to_cover < hold_radius

	# --- In cover ---
	if is_in_cover:
		# Spotted while in cover: try to tuck closer to island or abandon
		if ship.visible_to_enemy:
			var ship_clearance: float = 100.0
			if ship.movement_controller:
				ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

			var to_island = _cover_island_center - ship.global_position
			to_island.y = 0.0
			var dist_to_island = to_island.length()
			var min_safe_dist = _cover_island_radius + MIN_ISLAND_COVER_DISTANCE

			if dist_to_island > min_safe_dist + 50.0:
				# Tuck closer — use POSE to navigate to the tighter position
				var closer_pos = _cover_island_center + (-to_island.normalized()) * min_safe_dist
				closer_pos.y = 0.0
				closer_pos = _validate_cover_position(ship, closer_pos, ship_clearance)
				var heading = _compute_tangential_heading(ship, _cover_island_center)
				return NavIntent.pose(closer_pos, heading)
			else:
				_invalidate_cover()
				return null

		# In cover and undetected — hold position with STATION_KEEP
		return NavIntent.station(_cover_zone_center, hold_radius * 0.4, _cover_zone_heading)

	# --- Not yet in cover: use POSE so the navigator pathfinds directly to it ---
	var intent = NavIntent.pose(_cover_zone_center, _cover_zone_heading)
	if dist_to_cover > 500.0:
		intent.throttle_override = 4
	elif dist_to_cover > 200.0:
		intent.throttle_override = 3
	return intent


# ============================================================================
# VISIBLE BUT ENEMIES LOS-BLOCKED — STRONGER COVER POSITION
# ============================================================================

func _are_all_enemies_los_blocked(ship: Ship, server: GameServer) -> bool:
	"""Check if all known enemies (visible + last-spotted) have their LOS to us
	blocked by terrain. If true, we're technically 'visible' (detection hasn't
	expired) but all sightlines are blocked — we should tuck deeper."""
	var threats = _gather_threat_positions(ship)
	if threats.is_empty():
		return false

	var my_pos = ship.global_position
	for threat_pos in threats:
		if not NavigationMapManager.is_los_blocked(my_pos, threat_pos):
			return false  # At least one enemy can see us

	return true


func _get_stronger_cover_intent(ship: Ship, _gun_range: float) -> NavIntent:
	"""When visible to enemies but all enemies are LOS-blocked, move to a
	stronger cover position: closer to the island, on the side facing our spawn
	(directly behind the island from the enemy's perspective).
	Uses POSE to navigate there so the navigator pathfinds properly."""

	if _cover_island_id < 0:
		return _navigate_to_cover(ship)

	var ship_clearance: float = 100.0
	if ship.movement_controller:
		ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

	# Direction from island center toward our spawn — this is the "safe" side
	var safe_dir: Vector3
	if _cached_spawn_dir != Vector3.ZERO:
		safe_dir = _cached_spawn_dir
	else:
		# Fallback: use direction from danger center to island (behind island)
		var danger_center = _get_danger_center()
		if danger_center != Vector3.ZERO:
			safe_dir = (_cover_island_center - danger_center)
			safe_dir.y = 0.0
			if safe_dir.length_squared() > 0.1:
				safe_dir = safe_dir.normalized()
			else:
				safe_dir = (ship.global_position - _cover_island_center).normalized()
		else:
			safe_dir = (ship.global_position - _cover_island_center).normalized()

	safe_dir.y = 0.0
	if safe_dir.length_squared() < 0.1:
		return _navigate_to_cover(ship)

	safe_dir = safe_dir.normalized()

	# Position: on the safe side of the island, as close to shore as navigable
	var min_dist = _cover_island_radius + ship_clearance + 20.0
	var tuck_pos = _cover_island_center + safe_dir * min_dist
	tuck_pos.y = 0.0

	# Walk outward if not navigable, in small steps
	var test_pos = tuck_pos
	for step in range(8):
		if NavigationMapManager.is_navigable(test_pos, ship_clearance):
			break
		test_pos = _cover_island_center + safe_dir * (min_dist + (step + 1) * 30.0)
		test_pos.y = 0.0

	test_pos = _validate_cover_position(ship, test_pos, ship_clearance)

	# Tangential heading so the ship orbits the island edge
	var heading = _compute_tangential_heading(ship, _cover_island_center)

	# Use POSE so the navigator pathfinds directly to the tuck position
	return NavIntent.pose(test_pos, heading)


# ============================================================================
# STATE 3: HUNTING (enemies were seen but lost)
# ============================================================================

func _get_hunting_intent(ship: Ship, server: GameServer, friendly: Array[Ship]) -> NavIntent:
	"""When enemies were seen but are no longer visible, actively seek them out.
	No cover seeking — move aggressively toward last known positions."""

	var hunt_dest = _get_hunting_position(server, friendly, ship.global_position - ship.global_transform.basis.z * 10000.0)

	if hunt_dest == Vector3.ZERO:
		# No hunting target — sail forward aggressively
		var fwd = -ship.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length_squared() < 0.1:
			fwd = Vector3(0, 0, -1)
		hunt_dest = ship.global_position + fwd.normalized() * 5000.0
		hunt_dest.y = 0.0
		hunt_dest = _get_valid_nav_point(hunt_dest)

	var heading = _calc_approach_heading(ship, hunt_dest)

	# If visible, use evasion heading
	var nearest_info = _get_nearest_enemy()
	if ship.visible_to_enemy and not nearest_info.is_empty() and nearest_info.get("ship") != null:
		var target_ship: Ship = nearest_info["ship"]
		if is_instance_valid(target_ship):
			var heading_info = get_desired_heading(target_ship, _get_ship_heading(), 0.0, hunt_dest)
			if heading_info.get("use_evasion", false):
				heading = heading_info.heading

	var intent = NavIntent.pose(hunt_dest, heading)
	intent.throttle_override = 4  # Full speed when hunting
	return intent

# ============================================================================
# KITING (fallback when no island cover available)
# ============================================================================

func _get_kiting_intent(ship: Ship, target: Ship, friendly: Array[Ship], danger_center: Vector3, gun_range: float, hp_ratio: float) -> NavIntent:
	"""Tactical kiting when no island cover is available."""
	var params = get_positioning_params()

	var range_increase = clamp((1.0 - hp_ratio) * params.range_increase_when_damaged, 0.0, params.range_increase_when_damaged)
	var engagement_range = (params.base_range_ratio + range_increase) * gun_range
	var min_safe_distance = gun_range * params.min_safe_distance_ratio
	var flank_bias = lerp(params.flank_bias_healthy, params.flank_bias_damaged, 1.0 - hp_ratio)

	var desired_position = _calculate_tactical_position(engagement_range, min_safe_distance, flank_bias)
	desired_position += _calculate_spread_offset(friendly, params.spread_distance, params.spread_multiplier)
	desired_position = _get_valid_nav_point(desired_position)

	var kite_heading = _calculate_kite_heading(target, danger_center, desired_position)

	if ship.visible_to_enemy and target != null:
		var heading_info = get_desired_heading(target, _get_ship_heading(), 0.0, desired_position)
		if heading_info.get("use_evasion", false):
			return NavIntent.pose(desired_position, heading_info.heading)

	return NavIntent.pose(desired_position, kite_heading)


func _calculate_kite_heading(target: Ship, danger_center: Vector3, desired_pos: Vector3) -> float:
	"""Calculate a heading for kiting — angled away from threat with guns bearing."""
	var threat_pos: Vector3
	if target != null and is_instance_valid(target):
		threat_pos = target.global_position
	else:
		threat_pos = danger_center

	var to_threat = threat_pos - desired_pos
	to_threat.y = 0.0
	var threat_bearing = atan2(to_threat.x, to_threat.z)

	var away_bearing = _normalize_angle(threat_bearing + PI)

	var current_heading = _get_ship_heading()
	var kite_right = _normalize_angle(away_bearing + deg_to_rad(30))
	var kite_left = _normalize_angle(away_bearing - deg_to_rad(30))

	var diff_right = abs(_normalize_angle(kite_right - current_heading))
	var diff_left = abs(_normalize_angle(kite_left - current_heading))

	if diff_right <= diff_left:
		return kite_right
	else:
		return kite_left

# ============================================================================
# SHARED UTILITY FUNCTIONS
# ============================================================================

func _ensure_spawn_dir(ship: Ship, server: GameServer) -> void:
	"""Cache the direction from map center toward our spawn. Used to determine
	the 'safe' side of islands (the side facing our spawn)."""
	if _spawn_dir_initialized:
		return
	var my_team_id = ship.team.team_id
	var spawn_pos = server.get_team_spawn_position(my_team_id)
	if spawn_pos == Vector3.ZERO:
		return
	# Direction from map center (0,0,0) toward our spawn
	var dir = spawn_pos
	dir.y = 0.0
	if dir.length_squared() > 1.0:
		_cached_spawn_dir = dir.normalized()
	else:
		# Spawn at center — use forward direction of a team 0 ship
		_cached_spawn_dir = Vector3(0, 0, -1) if my_team_id == 0 else Vector3(0, 0, 1)
	_spawn_dir_initialized = true


func _find_near_side_position(my_pos: Vector3, island_pos: Vector3, island_radius: float, ship_clearance: float) -> Vector3:
	"""Walk from the ship toward an island and find a navigable position near the shore."""
	var to_island = island_pos - my_pos
	to_island.y = 0.0
	var dist_to_island = to_island.length()
	if dist_to_island < 1.0:
		return Vector3.ZERO
	var to_island_dir = to_island / dist_to_island

	var best_station_pos: Vector3 = Vector3.ZERO
	var best_station_dist: float = INF

	var approach_angle = atan2(to_island_dir.x, to_island_dir.z)
	var angle_offsets = [0.0, deg_to_rad(15), -deg_to_rad(15), deg_to_rad(30), -deg_to_rad(30)]

	for angle_offset in angle_offsets:
		var test_angle = approach_angle + angle_offset
		var test_dir = Vector3(sin(test_angle), 0.0, cos(test_angle))

		var step_size = 50.0
		var max_walk = dist_to_island + island_radius
		var walk_dist = 0.0

		while walk_dist < max_walk:
			var test_pos = my_pos + test_dir * walk_dist
			test_pos.y = 0.0

			var sdf_val = NavigationMapManager.get_distance(test_pos)

			if sdf_val >= ship_clearance and sdf_val <= ship_clearance + 100.0:
				if NavigationMapManager.is_navigable(test_pos, ship_clearance):
					var dist_from_ship = test_pos.distance_to(my_pos)
					if walk_dist > 0 and dist_from_ship < best_station_dist:
						best_station_dist = dist_from_ship
						best_station_pos = test_pos
				break

			if sdf_val < 0:
				break

			walk_dist += step_size

	# Fallback: sample around island edge
	if best_station_pos == Vector3.ZERO:
		for extra_dist in [20.0, 50.0, 80.0, 120.0, 160.0]:
			for ang_off in angle_offsets:
				var test_angle2 = approach_angle + PI + ang_off
				var test_dir2 = Vector3(sin(test_angle2), 0.0, cos(test_angle2))
				var test_pos2 = island_pos + test_dir2 * (island_radius + extra_dist)
				test_pos2.y = 0.0
				if NavigationMapManager.is_navigable(test_pos2, ship_clearance):
					best_station_pos = test_pos2
					break
			if best_station_pos != Vector3.ZERO:
				break

	# Last resort
	if best_station_pos == Vector3.ZERO:
		var to_ship_dir = -to_island_dir
		best_station_pos = island_pos + to_ship_dir * (island_radius + ship_clearance + 50.0)
		best_station_pos.y = 0.0

	return best_station_pos


func _advance_ballistic_eval(ship: Ship) -> void:
	"""Process a batch of cover candidates per frame via ballistic simulation."""
	if not _cover_eval_in_progress:
		return
	if _cover_candidates.is_empty():
		_cover_eval_in_progress = false
		return

	var batch_end = mini(_cover_eval_index + COVER_CANDIDATES_PER_FRAME, _cover_candidates.size())
	var ship_clearance: float = 100.0
	if ship.movement_controller:
		ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

	for i in range(_cover_eval_index, batch_end):
		var candidate: Dictionary = _cover_candidates[i]
		var pos_2d: Vector2 = candidate["position"]
		var pos_3d = Vector3(pos_2d.x, 0.0, pos_2d.y)

		var shootable = false
		if _cover_eval_target != null and is_instance_valid(_cover_eval_target) and _cover_eval_target.health_controller.is_alive():
			shootable = can_shoot_target_from_position(pos_3d, _cover_eval_target)
		else:
			shootable = true

		if shootable:
			var validated_pos = _validate_cover_position(ship, pos_3d, ship_clearance)
			_cover_zone_center = validated_pos
			_cover_can_shoot = true

			_cover_zone_heading = _compute_tangential_heading(ship, _cover_island_center)
			var broadside = _compute_broadside_heading(validated_pos, _cover_eval_danger_center)
			_cover_zone_heading = _blend_headings(_cover_zone_heading, broadside, 0.7)

			_cover_zone_radius = clamp(ship_clearance * 1.5, 80.0, 200.0)

			_cover_eval_in_progress = false
			return

	_cover_eval_index = batch_end

	if _cover_eval_index >= _cover_candidates.size():
		_cover_eval_in_progress = false


func _compute_broadside_heading(pos: Vector3, threat_center: Vector3) -> float:
	"""Compute a broadside heading — perpendicular to the threat direction."""
	var to_threat = threat_center - pos
	to_threat.y = 0.0
	if to_threat.length_squared() < 1.0:
		return _get_ship_heading()
	var threat_bearing = atan2(to_threat.x, to_threat.z)
	var broadside1 = _normalize_angle(threat_bearing + PI * 0.5)
	var broadside2 = _normalize_angle(threat_bearing - PI * 0.5)
	var current_heading = _get_ship_heading()
	var diff1 = abs(_normalize_angle(broadside1 - current_heading))
	var diff2 = abs(_normalize_angle(broadside2 - current_heading))
	if diff1 <= diff2:
		return broadside1
	else:
		return broadside2


func _compute_tangential_heading(ship: Ship, island_center: Vector3) -> float:
	"""Compute a heading tangential to the island from the ship's current position."""
	var to_island = island_center - ship.global_position
	to_island.y = 0.0
	var dist = to_island.length()
	if dist < 1.0:
		return _get_ship_heading()

	var radial_bearing = atan2(to_island.x, to_island.z)

	var tangent_cw = _normalize_angle(radial_bearing + PI * 0.5)
	var tangent_ccw = _normalize_angle(radial_bearing - PI * 0.5)

	var current_heading = _get_ship_heading()
	var diff_cw = abs(_normalize_angle(tangent_cw - current_heading))
	var diff_ccw = abs(_normalize_angle(tangent_ccw - current_heading))

	if diff_cw <= diff_ccw:
		return tangent_cw
	else:
		return tangent_ccw


func _blend_headings(heading_a: float, heading_b: float, t: float) -> float:
	"""Blend two headings by factor t (0.0 = heading_a, 1.0 = heading_b)."""
	var diff = _normalize_angle(heading_b - heading_a)
	return _normalize_angle(heading_a + diff * t)


func _invalidate_cover() -> void:
	"""Reset all cover state."""
	_cover_zone_valid = false
	_cover_island_id = -1
	is_in_cover = false
	_prev_cover_island_id = -1
	_cover_can_shoot = false
	_cover_eval_in_progress = false
	_cover_candidates.clear()
	_cover_eval_index = 0
	_cover_eval_target = null


func _gather_threat_positions(ship: Ship) -> Array:
	"""Collect all known enemy positions: currently spotted + last-known unspotted."""
	var threats: Array = []
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	if server_node == null:
		return threats

	var visible_enemies = server_node.get_valid_targets(ship.team.team_id)
	for enemy in visible_enemies:
		if is_instance_valid(enemy) and enemy.health_controller.is_alive():
			threats.append(enemy.global_position)

	var unspotted = server_node.get_unspotted_enemies(ship.team.team_id)
	for enemy_ship in unspotted.keys():
		var last_pos: Vector3 = unspotted[enemy_ship]
		threats.append(last_pos)

	return threats


func _validate_cover_position(ship: Ship, pos: Vector3, ship_clearance: float) -> Vector3:
	"""Push a cover position through the safe navigation pipeline."""
	var turning_radius: float = 300.0
	if ship.movement_controller:
		turning_radius = ship.movement_controller.turning_circle_radius
	if NavigationMapManager.is_map_ready():
		pos = NavigationMapManager.safe_nav_point(ship.global_position, pos, ship_clearance, turning_radius)
		pos = NavigationMapManager.validate_destination(ship.global_position, pos, ship_clearance, turning_radius)
	return pos


func _calc_approach_heading(ship: Ship, dest: Vector3) -> float:
	var to_dest = dest - ship.global_position
	to_dest.y = 0.0
	if to_dest.length_squared() > 1.0:
		return atan2(to_dest.x, to_dest.z)
	return _get_ship_heading()


func get_fallback_position(friendly: Array[Ship], _enemy: Array[Ship], target: Ship, avg_enemy: Vector3, gun_range: float, hp_ratio: float) -> Vector3:
	"""Standard kiting/positioning when no island cover available."""
	var target_disp = _ship.global_position - target.global_position
	var hp_damage = 1.0 - hp_ratio
	var base_range = 1.0
	match target.ship_class:
		Ship.ShipClass.CA:
			base_range = 0.5
		Ship.ShipClass.DD:
			base_range = 0.3
		Ship.ShipClass.BB:
			base_range = 0.7
	var min_range = base_range * gun_range + 5_000 * clamp(hp_damage - 0.5, 0.0, 1.0)
	var r = min(gun_range, min_range)
	var desired_position = target.global_position + target_disp.normalized() * r

	var params = get_positioning_params()
	desired_position += _calculate_spread_offset(friendly, params.spread_distance, 1.0)

	var away_from_enemy = (_ship.global_position - avg_enemy).normalized()
	desired_position += away_from_enemy * r * 0.2

	if hp_ratio < 0.5:
		var nearest_friendly_pos = Vector3.ZERO
		var server_ref: GameServer = _ship.get_node_or_null("/root/Server")
		if server_ref:
			var nearest_cluster = server_ref.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
			if nearest_cluster.size() > 0:
				nearest_friendly_pos = nearest_cluster.center
			else:
				nearest_friendly_pos = server_ref.get_team_avg_position(_ship.team.team_id)
		else:
			for ship in friendly:
				nearest_friendly_pos += ship.global_position
			nearest_friendly_pos /= friendly.size()
		var retreat_dir = away_from_enemy * 0.7 + (nearest_friendly_pos - _ship.global_position).normalized() * 0.3
		desired_position = _ship.global_position + retreat_dir.normalized() * r * 0.5

	return _get_valid_nav_point(desired_position)
