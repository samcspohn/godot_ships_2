extends BotBehavior
class_name CABehavior

var ammo = ShellParams.ShellType.HE

# Cover preference timer - prefer cover for first 60 seconds
var cover_preference_timer: float = 60.0
const COVER_PREFERENCE_DURATION: float = 60.0

# Island abandonment thresholds (as fraction of gun range)
const ABANDON_TOO_FAR: float = 0.80
const ABANDON_TOO_CLOSE: float = 0.35
const AGGRESSIVE_RANGE: float = 0.60
const DEFENSIVE_RANGE: float = 0.70

# Cover zone state — SDF-cell-based (no circle approximation)
var _cover_island_id: int = -1
var _cover_zone_valid: bool = false
var _cover_zone_center: Vector3 = Vector3.ZERO   # Best cover position (world coords)
var _cover_zone_radius: float = 200.0             # Station-keep radius around cover pos
var _cover_zone_heading: float = 0.0              # Desired heading at cover position
var _cover_zone_timer: float = 0.0                # Timer until next recompute
var _cover_all_hidden: bool = false                # True if all threats blocked at cover pos
var _cover_hidden_count: int = 0                   # How many threats blocked at cover pos
var _cover_sdf_distance: float = 0.0              # SDF value at cover pos (dist to shore)
var _cover_can_shoot: bool = false                 # True once ballistic sim confirms shootability
var _cover_from_startup: bool = false              # True if current cover was set by startup (no threats)
const COVER_ZONE_RECOMPUTE_INTERVAL: float = 4.0  # Normal recompute interval
const COVER_SPOTTED_RECOMPUTE_INTERVAL: float = 0.25  # Recompute 4x/sec when spotted — reactive without burning CPU

# Async ballistic validation — C++ returns a ranked candidate list, GDScript
# iterates through it frame-by-frame calling can_shoot_target_from_position()
# to find the best cell the ship can actually shoot over the island from.
var _cover_candidates: Array = []          # Sorted candidate dicts from C++ find_cover_candidates
var _cover_eval_index: int = 0             # Next candidate to validate this frame
var _cover_eval_in_progress: bool = false  # True while iterating through candidates
var _cover_eval_target: Ship = null        # Target ship for ballistic sim
var _cover_eval_danger_center: Vector3 = Vector3.ZERO  # Danger center for heading calc
const COVER_CANDIDATES_PER_FRAME: int = 2  # How many ballistic sims per physics frame

# Island metadata cache
var _cover_island_center: Vector3 = Vector3.ZERO
var _cover_island_radius: float = 0.0
var _prev_cover_island_id: int = -1

# Spotted-in-cover tracking
var _spotted_in_cover_timer: float = 0.0   # How long we've been spotted while in cover
var _was_visible_last_frame: bool = false   # Track visibility transitions for reactive update
var _had_enemies_last_frame: bool = false   # Track when enemies first appear (startup -> combat)

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
		Ship.ShipClass.BB: return 2.5   # BBs can devastate cruisers
		Ship.ShipClass.CA: return 1.2
		Ship.ShipClass.DD: return 0.5
	return 1.0

func get_target_weights() -> Dictionary:
	return {
		size_weight = 0.4,
		range_weight = 0.6,
		hp_weight = 0.0,  # HP handled separately with multiplier
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.2,
			Ship.ShipClass.DD: 1.5,   # CAs prioritize DDs
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
		flanking_multiplier = 5.0,  # Priority boost for flanking enemies
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.55,
		range_increase_when_damaged = 0.40,
		min_safe_distance_ratio = 0.40,  # CAs are fragile, need more space
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 2000.0,
		spread_multiplier = 2.0,
	}

func get_island_cover_params() -> Dictionary:
	"""CA uses island cover - return configuration."""
	return {
		aggressive_range = AGGRESSIVE_RANGE,
		defensive_range = DEFENSIVE_RANGE,
		abandon_too_close = ABANDON_TOO_CLOSE,
		abandon_too_far = ABANDON_TOO_FAR,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.3,      # CAs are more cautious when hunting
		cautious_hp_threshold = 0.5,
		use_island_cover = true,
	}

func should_evade(_destination: Vector3) -> bool:
	"""CA-specific: Only evade when in cover or when no cover is available."""
	if not _ship.visible_to_enemy:
		return false

	# If we're in cover, evade (micro-adjustments)
	if is_in_cover:
		return true

	# V4 path: if we have a valid cover zone destination, don't evade —
	# prioritize reaching cover (matches old V3 logic with island_position_valid)
	if _cover_zone_valid and _cover_island_id >= 0:
		return false

	# V3 path: if we have a valid island destination, don't evade - prioritize reaching cover
	if island_position_valid and current_island != null:
		return false

	# No cover available - fall back to evasion
	return true

# ============================================================================
# TARGET SELECTION - Override for HP multiplier
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

		# Calculate apparent size (broadside profile)
		var priority: float = ship.movement_controller.ship_length / dist * abs(sin(angle)) + ship.movement_controller.ship_beam / dist * abs(cos(angle))

		# Apply class modifier
		var class_mods: Dictionary = weights.class_modifiers
		if class_mods.has(ship.ship_class):
			priority *= class_mods[ship.ship_class]

		# CA multiplies by HP factor instead of adding it
		priority *= 1.5 - hp_ratio

		# Combine with range
		priority = priority * weights.size_weight + (1.0 - dist / gun_range) * weights.range_weight

		# Boost targets within range
		if dist <= gun_range:
			priority *= weights.in_range_multiplier

		# Apply flanking priority boost
		var flank_info = _get_flanking_info(ship)
		if flank_info.is_flanking:
			var flank_multiplier = weights.get("flanking_multiplier", 5.0)
			# Scale multiplier by how deep they've penetrated (1.0 to 2.0x the base multiplier)
			var depth_scale = 1.0 + flank_info.penetration_depth
			priority *= flank_multiplier * depth_scale

		if priority > best_priority:
			best_target = ship
			best_priority = priority

	return best_target

# ============================================================================
# AMMO AND AIM - Class-specific targeting logic
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
				# AP at broadside battleships upper belt
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 4
			else:
				# HE at battleship superstructure
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			if is_broadside:
				if dist < 7000:
					# AP at broadside cruisers lower belt
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				elif dist < 10000:
					# AP at broadside cruisers upper belt
					ammo = ShellParams.ShellType.AP
					offset.y = _target.movement_controller.ship_height / 4
				else:
					# HE at cruiser upper belt
					ammo = ShellParams.ShellType.HE
					offset.y = _target.movement_controller.ship_height / 3
			else:
				# HE at cruiser upper belt when angled
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 3
		Ship.ShipClass.DD:
			# HE at destroyers always
			ammo = ShellParams.ShellType.HE
			offset.y = 1.0
	return offset

# ============================================================================
# POSITIONING - CA-specific positioning with island cover
# ============================================================================

func get_desired_position(friendly: Array[Ship], _enemy: Array[Ship], _target: Ship, current_destination: Vector3) -> Vector3:
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")

	if _ship.name == "1005" and true:
		pass
	var danger_center = _get_danger_center()

	if danger_center == Vector3.ZERO:
		current_destination =  _get_hunting_position(server_node, friendly, current_destination)
		if current_destination == Vector3.ZERO:
			var island = _find_island_toward_position(_ship.global_position, INF)
			if island != null:
				var closest_point = server_node.map.island_edge_points[island][0]
				for island_point in server_node.map.island_edge_points[island]:
					if island_point.distance_to(_ship.global_position) < closest_point.distance_to(_ship.global_position):
						closest_point = island_point
				current_destination = closest_point
				return _get_valid_nav_point(current_destination)
			else:
				current_destination = _ship.global_position - _ship.basis.z * 10_000
				current_destination.y = 0
				return _get_valid_nav_point(current_destination)
		else:
			return current_destination

	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	# Get nearest enemy for safety distance calculations
	var nearest = _get_nearest_enemy()
	var dist_to_nearest = INF
	if not nearest.is_empty():
		dist_to_nearest = nearest.distance

	# Check if we should abandon current island cover
	var should_find_new_island = false

	if current_island != null and island_position_valid:
		if dist_to_nearest > gun_range * ABANDON_TOO_FAR:
			should_find_new_island = true
			island_position_valid = false
		elif dist_to_nearest < gun_range * ABANDON_TOO_CLOSE:
			should_find_new_island = true
			island_position_valid = false
			is_in_cover = false

	# Update island cache timer
	island_cache_timer -= 1.0 / Engine.physics_ticks_per_second
	if island_cache_timer <= 0 or should_find_new_island:
		island_cache_timer = ISLAND_CACHE_DURATION
		current_island = find_optimal_island(danger_center, gun_range, hp_ratio, dist_to_nearest)
		island_position_valid = current_island != null

	# Update cover preference timer
	cover_preference_timer -= 1.0 / Engine.physics_ticks_per_second
	if cover_preference_timer < 0:
		cover_preference_timer = 0.0

	# If we have an island, use island cover logic
	if island_position_valid and current_island != null:
		var cover_pos = get_island_cover_position(current_island, danger_center, gun_range)
		if cover_pos != Vector3.ZERO:
			var dist_to_cover = _ship.global_position.distance_to(cover_pos)
			is_in_cover = dist_to_cover < IN_COVER_THRESHOLD

			# If in cover and not detected, stay put
			if is_in_cover and not _ship.visible_to_enemy:
				return _ship.global_position

			# If in cover but detected, try to get closer to island first
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
					# Already at minimum distance - abandon cover and maneuver
					is_in_cover = false
					island_position_valid = false
					current_island = null
					return _get_tactical_fallback_position(gun_range, hp_ratio, friendly)

			return cover_pos

	is_in_cover = false

	# Only fall back to tactical positioning if cover preference timer has expired
	if cover_preference_timer > 0:
		if not _ship.visible_to_enemy:
			return _ship.global_position

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
# NAVINTENT — V4 bot controller interface
# ============================================================================

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	"""CA always returns POSE/STATION_KEEP with safe heading for navigation."""
	var friendly = server.get_team_ships(ship.team.team_id)
	var _enemy = server.get_valid_targets(ship.team.team_id)

	var danger_center = _get_danger_center()

	# --- No enemies known: prioritize island cover, then hunt ---
	if danger_center == Vector3.ZERO:
		# If we're visible to the enemy but don't know where they are,
		# don't sit still — abandon startup cover and move to break detection.
		if ship.visible_to_enemy:
			if _cover_from_startup:
				_invalidate_cover()
			# Move forward aggressively — sail toward the enemy spawn side of
			# the map to find the threat, rather than sitting exposed.
			var escape_dir = -ship.global_transform.basis.z  # ship's forward
			escape_dir.y = 0.0
			if escape_dir.length_squared() < 0.1:
				escape_dir = Vector3(0, 0, -1)
			var escape_dest = ship.global_position + escape_dir.normalized() * 3000.0
			escape_dest.y = 0.0
			escape_dest = _get_valid_nav_point(escape_dest)
			var escape_heading = atan2(escape_dir.x, escape_dir.z)
			return NavIntent.pose(escape_dest, escape_heading)

		# Not visible, no enemies — head toward the nearest island for cover.
		var island_cover = _find_startup_island_cover(ship, server)
		if island_cover != null:
			return island_cover

		# No reachable island — fall back to normal hunting
		var hunt_dest = _get_hunting_position(server, friendly, ship.global_position - ship.global_transform.basis.z * 10000.0)
		if hunt_dest == Vector3.ZERO:
			var fallback = ship.global_position - ship.global_transform.basis.z * 10000.0
			fallback.y = 0.0
			fallback = _get_valid_nav_point(fallback)
			return NavIntent.pose(fallback, _calc_approach_heading(ship, fallback))
		return NavIntent.pose(hunt_dest, _calc_approach_heading(ship, hunt_dest))

	var gun_range = ship.artillery_controller.get_params()._range
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp

	# Get nearest enemy for safety distance calculations
	var nearest = _get_nearest_enemy()
	var dist_to_nearest = INF
	if not nearest.is_empty():
		dist_to_nearest = nearest.distance

	# --- Try island cover via NavigationMapManager cover zones ---
	var cover_intent = _try_get_cover_zone_intent(ship, target, danger_center, gun_range, hp_ratio, dist_to_nearest)
	if cover_intent != null:
		return cover_intent

	# --- Cover preference: early in the match, prefer to hold position rather
	#     than kite in the open. This gives the CA time to find island cover
	#     instead of rushing aggressively into the fight (matches old V3 behavior). ---
	cover_preference_timer -= 1.0 / Engine.physics_ticks_per_second
	if cover_preference_timer < 0:
		cover_preference_timer = 0.0

	if cover_preference_timer > 0:
		if not ship.visible_to_enemy:
			# Hold position — wait for cover zone to become available
			var hold_heading = _get_ship_heading()
			return NavIntent.station(ship.global_position, 200.0, hold_heading)

	# --- No cover available: tactical kiting with POSE ---
	return _get_kiting_intent(ship, target, friendly, danger_center, gun_range, hp_ratio)


func _try_get_cover_zone_intent(ship: Ship, target: Ship, danger_center: Vector3, gun_range: float, hp_ratio: float, dist_to_nearest: float) -> NavIntent:
	"""SDF-cell-based cover: find the ideal cell near an island's shore where LOS
	to all threats is blocked by land, then async-validate shootability via ballistic sim.
	Returns a POSE or STATION_KEEP NavIntent if a valid cover position is found, null otherwise.
	STATION_KEEP is only used when arrived in cover and undetected (holding position).
	All approach cases use POSE to pilot directly to the cover position at speed.
	When spotted at the cover position, actively moves closer to the island or
	abandons cover entirely if already as close as possible."""
	if not NavigationMapManager.is_map_ready():
		return null

	var params = get_island_cover_params()
	if params.is_empty():
		return null

	# Check if we should abandon current cover
	if _cover_zone_valid:
		if dist_to_nearest > gun_range * ABANDON_TOO_FAR:
			_invalidate_cover()
		elif dist_to_nearest < gun_range * ABANDON_TOO_CLOSE:
			_invalidate_cover()

	var dt = 1.0 / Engine.physics_ticks_per_second

	# --- Advance async ballistic evaluation if one is in progress ---
	if _cover_eval_in_progress:
		_advance_ballistic_eval(ship)

	# --- Reactive recompute triggers ---
	var just_became_visible = ship.visible_to_enemy and not _was_visible_last_frame
	_was_visible_last_frame = ship.visible_to_enemy

	# Detect first enemy contact: cover was from startup (no threats) and now we have a danger_center
	var first_enemy_contact = _cover_from_startup and danger_center != Vector3.ZERO
	if first_enemy_contact:
		_cover_from_startup = false

	# Determine recompute interval based on situation
	var recompute_interval = COVER_ZONE_RECOMPUTE_INTERVAL
	if ship.visible_to_enemy:
		# When spotted, recompute reactively but don't spam — allow async eval to finish
		recompute_interval = COVER_SPOTTED_RECOMPUTE_INTERVAL

	_cover_zone_timer -= dt

	# Force recompute when: timer expired, cover invalid, just spotted, or first enemy contact
	var should_recompute = _cover_zone_timer <= 0 or not _cover_zone_valid or just_became_visible or first_enemy_contact
	if should_recompute:
		_cover_zone_timer = recompute_interval
		_recompute_cover_zone(ship, target, danger_center, gun_range, hp_ratio, dist_to_nearest)

	if not _cover_zone_valid:
		return null

	# We have a valid cover position — check distance to decide behavior
	var in_cover_threshold = min(_cover_zone_radius, 250.0)
	var dist_to_cover = ship.global_position.distance_to(_cover_zone_center)
	is_in_cover = dist_to_cover < in_cover_threshold

	# --- Track spotted-in-cover duration ---
	if is_in_cover and ship.visible_to_enemy:
		_spotted_in_cover_timer += dt
	else:
		_spotted_in_cover_timer = max(0.0, _spotted_in_cover_timer - dt * 2.0)

	# --- In cover and undetected: hold position with station-keep ---
	if is_in_cover and not ship.visible_to_enemy:
		_spotted_in_cover_timer = 0.0
		return NavIntent.station(_cover_zone_center, in_cover_threshold * 0.4, _cover_zone_heading)

	# --- Spotted while at/near the cover position: the recompute returned a position
	#     that's essentially where we already are, but the enemy can still see us.
	#     Actively move closer to the island to break LOS, or abandon cover. ---
	if is_in_cover and ship.visible_to_enemy:
		var ship_clearance: float = 100.0
		if ship.movement_controller:
			ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

		var to_island = _cover_island_center - ship.global_position
		to_island.y = 0.0
		var dist_to_island = to_island.length()
		var min_safe_dist = _cover_island_radius + MIN_ISLAND_COVER_DISTANCE

		if dist_to_island > min_safe_dist + 50.0:
			# Move closer to the island — tuck in tighter to break LOS
			var closer_pos = _cover_island_center + (-to_island.normalized()) * min_safe_dist
			closer_pos.y = 0.0
			closer_pos = _validate_cover_position(ship, closer_pos, ship_clearance)
			var heading = _compute_tangential_heading(ship, _cover_island_center)
			return NavIntent.pose(closer_pos, heading)
		else:
			# Already as close as possible — abandon cover, fall through to kiting
			_invalidate_cover()
			return null

	# --- Not yet in cover: pilot directly to the cover position using POSE.
	#     The navigator's POSE mode handles pathfinding and collision avoidance. ---
	var intent = NavIntent.pose(_cover_zone_center, _cover_zone_heading)
	# Keep throttle high while approaching cover — don't let the navigator
	# decelerate early. Scale down only for the final approach so we don't
	# wildly overshoot the cover position.
	if dist_to_cover > 500.0:
		intent.throttle_override = 4   # Full speed — far from cover
	elif dist_to_cover > 200.0:
		intent.throttle_override = 3   # Three-quarter — getting close
	else:
		intent.throttle_override = -1  # Let navigator handle final approach normally
	return intent


# _get_spotted_in_cover_intent removed — spotted handling is now done reactively
# inside _try_get_cover_zone_intent by forcing an immediate _recompute_cover_zone
# when visibility changes, so the SDF search always returns the best available cell.


func _advance_ballistic_eval(ship: Ship) -> void:
	"""Process a batch of cover candidates per frame via ballistic simulation.
	The C++ find_cover_candidates returned a ranked list sorted by concealment score.
	We iterate through them calling can_shoot_target_from_position() and pick the
	first (best-concealment) candidate that the ship can actually shoot over the island from."""
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

		# Ballistic shootability check — can we arc shells over the island?
		var shootable = false
		if _cover_eval_target != null and is_instance_valid(_cover_eval_target) and _cover_eval_target.health_controller.is_alive():
			shootable = can_shoot_target_from_position(pos_3d, _cover_eval_target)
		else:
			# No valid target — accept the best concealment cell without shoot check
			shootable = true

		if shootable:
			# Found the best-concealment candidate we can shoot from — upgrade cover position
			var validated_pos = _validate_cover_position(ship, pos_3d, ship_clearance)
			_cover_zone_center = validated_pos
			_cover_can_shoot = true
			_cover_hidden_count = candidate.get("hidden_count", 0)
			_cover_all_hidden = candidate.get("all_hidden", false)
			_cover_sdf_distance = candidate.get("sdf_distance", 0.0)

			# Update heading: blend tangential with broadside since we can shoot
			_cover_zone_heading = _compute_tangential_heading(ship, _cover_island_center)
			var broadside = _compute_broadside_heading(validated_pos, _cover_eval_danger_center)
			_cover_zone_heading = _blend_headings(_cover_zone_heading, broadside, 0.7)

			# Tighten zone radius since we confirmed shootability
			if _cover_all_hidden:
				_cover_zone_radius = clamp(ship_clearance * 1.5, 80.0, 200.0)
			else:
				_cover_zone_radius = clamp(ship_clearance * 2.0, 100.0, 250.0)

			_cover_eval_in_progress = false
			return

	_cover_eval_index = batch_end

	# If we've exhausted all candidates without finding a shootable one,
	# keep the initial best-concealment position (already set by _recompute_cover_zone)
	if _cover_eval_index >= _cover_candidates.size():
		_cover_eval_in_progress = false


func _compute_broadside_heading(pos: Vector3, threat_center: Vector3) -> float:
	"""Compute a broadside heading — perpendicular to the threat direction,
	allowing the ship to present its side for maximum firepower over the island."""
	var to_threat = threat_center - pos
	to_threat.y = 0.0
	if to_threat.length_squared() < 1.0:
		return _get_ship_heading()
	var threat_bearing = atan2(to_threat.x, to_threat.z)
	# Two broadside options
	var broadside1 = _normalize_angle(threat_bearing + PI * 0.5)
	var broadside2 = _normalize_angle(threat_bearing - PI * 0.5)
	# Pick the one closer to current heading
	var current_heading = _get_ship_heading()
	var diff1 = abs(_normalize_angle(broadside1 - current_heading))
	var diff2 = abs(_normalize_angle(broadside2 - current_heading))
	if diff1 <= diff2:
		return broadside1
	else:
		return broadside2


func _compute_tangential_heading(ship: Ship, island_center: Vector3) -> float:
	"""Compute a heading tangential to the island from the ship's current position.
	This heading allows the ship to arc around the island rather than pointing
	at it or away from it."""
	var to_island = island_center - ship.global_position
	to_island.y = 0.0
	var dist = to_island.length()
	if dist < 1.0:
		return _get_ship_heading()

	var radial_bearing = atan2(to_island.x, to_island.z)

	# Two tangential options: clockwise and counter-clockwise around the island
	var tangent_cw = _normalize_angle(radial_bearing + PI * 0.5)
	var tangent_ccw = _normalize_angle(radial_bearing - PI * 0.5)

	# Pick the tangent closest to current heading (less turning required)
	var current_heading = _get_ship_heading()
	var diff_cw = abs(_normalize_angle(tangent_cw - current_heading))
	var diff_ccw = abs(_normalize_angle(tangent_ccw - current_heading))

	if diff_cw <= diff_ccw:
		return tangent_cw
	else:
		return tangent_ccw


func _blend_headings(heading_a: float, heading_b: float, t: float) -> float:
	"""Blend two headings by factor t (0.0 = heading_a, 1.0 = heading_b).
	Handles wrapping correctly."""
	var diff = _normalize_angle(heading_b - heading_a)
	return _normalize_angle(heading_a + diff * t)


func _invalidate_cover() -> void:
	"""Reset all cover state."""
	_cover_zone_valid = false
	_cover_island_id = -1
	is_in_cover = false
	_spotted_in_cover_timer = 0.0
	_prev_cover_island_id = -1
	_cover_all_hidden = false
	_cover_can_shoot = false
	_cover_hidden_count = 0
	_cover_sdf_distance = 0.0
	_cover_from_startup = false
	_cover_eval_in_progress = false
	_cover_candidates.clear()
	_cover_eval_index = 0
	_cover_eval_target = null
	_had_enemies_last_frame = false


func _gather_threat_positions(ship: Ship) -> Array:
	"""Collect all known enemy positions: currently spotted + last-known unspotted.
	These are the positions we need to hide from."""
	var threats: Array = []
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	if server_node == null:
		return threats

	# Currently spotted enemies
	var visible_enemies = server_node.get_valid_targets(ship.team.team_id)
	for enemy in visible_enemies:
		if is_instance_valid(enemy) and enemy.health_controller.is_alive():
			threats.append(enemy.global_position)

	# Last-known positions of unspotted enemies
	var unspotted = server_node.get_unspotted_enemies(ship.team.team_id)
	for enemy_ship in unspotted.keys():
		var last_pos: Vector3 = unspotted[enemy_ship]
		threats.append(last_pos)

	return threats


# Old circle-based candidate generation, async evaluation, and finalize functions
# have been removed. The SDF-cell-based search is done synchronously in C++ via
# NavigationMapManager.find_cover_position() — it walks the actual SDF grid near the
# island shoreline, so no circle approximation is needed.


func _validate_cover_position(ship: Ship, pos: Vector3, ship_clearance: float) -> Vector3:
	"""Push a cover position through the safe navigation pipeline."""
	var turning_radius: float = 300.0
	if ship.movement_controller:
		turning_radius = ship.movement_controller.turning_circle_radius
	if NavigationMapManager.is_map_ready():
		pos = NavigationMapManager.safe_nav_point(ship.global_position, pos, ship_clearance, turning_radius)
		pos = NavigationMapManager.validate_destination(ship.global_position, pos, ship_clearance, turning_radius)
	return pos


func _recompute_cover_zone(ship: Ship, target: Ship, danger_center: Vector3, gun_range: float, hp_ratio: float, dist_to_nearest: float) -> void:
	"""Find the best island and use the C++ SDF-cell-based search to get a ranked
	list of cover candidates. The top candidate (best concealment) is used immediately.
	An async ballistic evaluation then iterates the list to find the best candidate
	the ship can actually shoot over the island from, upgrading the position if found.

	IMPORTANT: When recomputing for the same island, we preserve the in-progress
	async ballistic evaluation so it isn't constantly restarted by frequent
	recompute triggers (e.g. when spotted)."""

	# Remember previous island so we can detect island changes
	var prev_island_id = _cover_island_id
	var had_eval_in_progress = _cover_eval_in_progress

	_cover_zone_valid = false
	_cover_island_id = -1

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		# Island changed (to none) — cancel async eval
		_cover_eval_in_progress = false
		_cover_candidates.clear()
		return

	var my_pos = ship.global_position
	var params = get_island_cover_params()
	var aggressive_range = params.get("aggressive_range", AGGRESSIVE_RANGE)
	var defensive_range = params.get("defensive_range", DEFENSIVE_RANGE)
	var abandon_too_close = params.get("abandon_too_close", ABANDON_TOO_CLOSE)

	var ideal_range_ratio = lerp(aggressive_range, defensive_range, 1.0 - hp_ratio)
	var ideal_distance = gun_range * ideal_range_ratio
	var prefer_farther = dist_to_nearest < gun_range * abandon_too_close

	var ship_clearance: float = 100.0
	if ship.movement_controller:
		ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

	# Gather threat positions once — shared across all island evaluations
	var threats = _gather_threat_positions(ship)

	# --- Score each island and run the SDF cover search on the best ---
	# We evaluate the top 2-3 islands and pick the one with the best cover result.
	var island_scores: Array = []  # Array of {id, score, center, radius}

	for island_dict in islands:
		var island_id: int = island_dict["id"]
		var island_center_2d: Vector2 = island_dict["center"]
		var isl_radius: float = island_dict["radius"]

		var island_pos = Vector3(island_center_2d.x, 0.0, island_center_2d.y)
		var island_to_danger = island_pos.distance_to(danger_center)

		# Skip islands too far from the fight (must be able to shoot from behind them)
		if island_to_danger > gun_range * 0.95:
			continue

		var dist_to_us = island_pos.distance_to(my_pos)

		# Primary: prefer the NEAREST island — proximity is king during combat
		# so the ship reaches cover quickly rather than sailing across the map
		var score: float = -dist_to_us * 2.0

		# The island must be between us and the danger (or at least not behind us)
		# so we can use it as a shield. Islands behind us are nearly useless.
		var to_danger_dir = (danger_center - my_pos).normalized()
		var to_island_dir = (island_pos - my_pos).normalized()
		var alignment = to_danger_dir.dot(to_island_dir)
		# Islands behind us get a harsh penalty; islands toward the enemy get a mild bonus
		if alignment < -0.2:
			score -= 2000.0
		elif alignment > 0:
			score += alignment * 150.0

		# Mild preference for islands at a good engagement distance
		var range_diff = abs(island_to_danger - ideal_distance)
		score -= range_diff * 0.3

		# If being pushed, prefer islands farther from enemies
		if prefer_farther:
			score += island_to_danger * 2.0

		# Bonus for larger islands — they provide better concealment
		score += isl_radius * 0.2

		# Bonus for islands we're already using (avoid flip-flopping)
		if island_id == _prev_cover_island_id:
			score += 400.0

		island_scores.append({
			"id": island_id,
			"score": score,
			"center": island_pos,
			"radius": isl_radius,
		})

	if island_scores.is_empty():
		return

	# Sort by score descending and evaluate top candidates with SDF search
	island_scores.sort_custom(func(a, b): return a["score"] > b["score"])

	var max_islands_to_evaluate = mini(3, island_scores.size())
	var best_candidates: Array = []
	var best_cover_score: float = -INF
	var best_island_entry: Dictionary = {}

	for i in range(max_islands_to_evaluate):
		var entry = island_scores[i]
		var island_id: int = entry["id"]

		# Run the C++ SDF-cell-based cover search — returns ranked candidate list
		var candidates: Array = NavigationMapManager.find_cover_candidates(
			island_id, threats, danger_center, my_pos, ship_clearance, gun_range * 0.9
		)

		if candidates.is_empty():
			continue

		# Score by the top candidate's concealment + island strategic value
		var top = candidates[0]
		var cover_score: float = float(top["hidden_count"]) * 1000.0
		cover_score += entry["score"] * 0.1

		if cover_score > best_cover_score:
			best_cover_score = cover_score
			best_candidates = candidates
			best_island_entry = entry

	if best_candidates.is_empty():
		# No candidates found — cancel any stale async eval
		_cover_eval_in_progress = false
		_cover_candidates.clear()
		return

	# --- Apply the top candidate immediately (best concealment) ---
	var best_island_id: int = best_island_entry["id"]
	_cover_island_id = best_island_id
	_cover_island_center = best_island_entry["center"]
	_cover_island_radius = best_island_entry["radius"]
	_prev_cover_island_id = best_island_id

	var top_candidate: Dictionary = best_candidates[0]
	var cover_pos_2d: Vector2 = top_candidate["position"]
	var cover_pos = Vector3(cover_pos_2d.x, 0.0, cover_pos_2d.y)

	# Store cover quality metadata (from top candidate before ballistic check)
	_cover_all_hidden = top_candidate.get("all_hidden", false)
	_cover_can_shoot = false  # Not yet confirmed — async eval will set this
	_cover_hidden_count = top_candidate.get("hidden_count", 0)
	_cover_sdf_distance = top_candidate.get("sdf_distance", 0.0)

	# Validate through safe navigation pipeline
	cover_pos = _validate_cover_position(ship, cover_pos, ship_clearance)

	_cover_zone_center = cover_pos
	_cover_zone_heading = _compute_tangential_heading(ship, _cover_island_center)

	_cover_zone_valid = true

	# Zone radius: wider initially until ballistic eval confirms a shootable cell
	if _cover_all_hidden:
		_cover_zone_radius = clamp(ship_clearance * 2.0, 100.0, 250.0)
	else:
		_cover_zone_radius = clamp(ship_clearance * 2.5, 120.0, 300.0)

	# --- Start async ballistic evaluation of the candidate list ---
	# Only restart the async eval if the island changed or we don't have one running.
	# When recomputing for the same island (e.g. frequent spotted recomputes),
	# let the existing async eval finish so it isn't perpetually restarted.
	var island_changed = best_island_id != prev_island_id
	if island_changed or not had_eval_in_progress:
		_cover_candidates = best_candidates
		_cover_eval_index = 0
		_cover_eval_in_progress = true
		_cover_eval_target = target
		_cover_eval_danger_center = danger_center
	else:
		# Same island, async eval still running — just update the danger center
		# and target so the eval uses fresh data when it finishes
		_cover_eval_target = target
		_cover_eval_danger_center = danger_center


func _get_kiting_intent(ship: Ship, target: Ship, friendly: Array[Ship], danger_center: Vector3, gun_range: float, hp_ratio: float) -> NavIntent:
	"""Tactical kiting when no island cover is available. Returns a POSE intent."""
	var params = get_positioning_params()

	var range_increase = clamp((1.0 - hp_ratio) * params.range_increase_when_damaged, 0.0, params.range_increase_when_damaged)
	var engagement_range = (params.base_range_ratio + range_increase) * gun_range
	var min_safe_distance = gun_range * params.min_safe_distance_ratio
	var flank_bias = lerp(params.flank_bias_healthy, params.flank_bias_damaged, 1.0 - hp_ratio)

	var desired_position = _calculate_tactical_position(engagement_range, min_safe_distance, flank_bias)
	desired_position += _calculate_spread_offset(friendly, params.spread_distance, params.spread_multiplier)
	desired_position = _get_valid_nav_point(desired_position)

	# Calculate angled heading — CAs want to angle away from threat while keeping guns on target
	var kite_heading = _calculate_kite_heading(target, danger_center, desired_position)

	# Check if evasion heading should override
	if ship.visible_to_enemy and target != null:
		var heading_info = get_desired_heading(target, _get_ship_heading(), 0.0, desired_position)
		if heading_info.get("use_evasion", false):
			return NavIntent.pose(desired_position, heading_info.heading)

	return NavIntent.pose(desired_position, kite_heading)


func _calculate_kite_heading(target: Ship, danger_center: Vector3, desired_pos: Vector3) -> float:
	"""Calculate a heading for kiting — angled away from threat with guns bearing.
	CAs want to angle ~30-40° from broadside (bow away from threat) to present
	a small profile while keeping rear turrets active."""

	var threat_pos: Vector3
	if target != null and is_instance_valid(target):
		threat_pos = target.global_position
	else:
		threat_pos = danger_center

	var to_threat = threat_pos - desired_pos
	to_threat.y = 0.0
	var threat_bearing = atan2(to_threat.x, to_threat.z)

	# CA wants to kite: stern roughly toward threat, bow away
	# This means heading ≈ threat_bearing (facing toward threat) + PI (reversed) + slight offset
	# A 30° offset from directly away keeps rear turrets bearing
	var away_bearing = _normalize_angle(threat_bearing + PI)

	# Choose kite direction based on current heading to avoid unnecessary 180s
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
# STARTUP ISLAND COVER
# ============================================================================

func _find_startup_island_cover(ship: Ship, _server: GameServer) -> NavIntent:
	"""At game start (no enemies detected yet), navigate to the nearest island
	and station on the NEAR SIDE — the side facing the ship. Uses the SDF directly
	to find the closest navigable point near the island shore, avoiding the
	island_radius circle approximation that puts ships too far away.

	Returns a POSE NavIntent (to sail there at speed) or STATION_KEEP (when already
	arrived and holding), or null if no suitable island exists."""

	var my_pos = ship.global_position

	# If we already have a valid startup cover position and we're close to it,
	# hold position with STATION_KEEP instead of re-running the full search.
	if _cover_zone_valid and _cover_from_startup:
		var dist_to_cover = my_pos.distance_to(_cover_zone_center)
		var hold_threshold = min(_cover_zone_radius, 250.0)
		if dist_to_cover < hold_threshold:
			is_in_cover = true
			return NavIntent.station(_cover_zone_center, hold_threshold * 0.4, _cover_zone_heading)
		# Still approaching — return POSE with throttle override
		var approach_intent = NavIntent.pose(_cover_zone_center, _cover_zone_heading)
		if dist_to_cover > 500.0:
			approach_intent.throttle_override = 4
		elif dist_to_cover > 200.0:
			approach_intent.throttle_override = 3
		return approach_intent
	var gun_range = ship.artillery_controller.get_params()._range

	var ship_clearance: float = 100.0
	if ship.movement_controller:
		ship_clearance = ship.movement_controller.ship_beam * 0.5 + 80.0

	if not NavigationMapManager.is_map_ready():
		return null

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return null

	# --- Pick the nearest island using SDF distance (actual shore distance) ---
	var best_island_id: int = -1
	var best_sdf_dist: float = INF
	var best_island_pos: Vector3 = Vector3.ZERO
	var best_island_radius: float = 0.0

	for island_dict in islands:
		var island_id: int = island_dict["id"]
		var island_center_2d: Vector2 = island_dict["center"]
		var isl_radius: float = island_dict["radius"]
		var island_pos = Vector3(island_center_2d.x, 0.0, island_center_2d.y)

		var dist_to_center = island_pos.distance_to(my_pos)
		var effective_dist = dist_to_center - isl_radius

		# Skip islands that are unreasonably far
		if effective_dist > gun_range * 0.8:
			continue

		if effective_dist < best_sdf_dist:
			best_sdf_dist = effective_dist
			best_island_id = island_id
			best_island_pos = island_pos
			best_island_radius = isl_radius

	if best_island_id < 0:
		return null

	# --- Find the near-side position using SDF: walk from the ship toward the
	#     island center, stopping when SDF drops to ship_clearance (just navigable).
	#     This hugs the actual shore shape, not a bounding circle. ---
	var to_island = best_island_pos - my_pos
	to_island.y = 0.0
	var dist_to_island = to_island.length()
	if dist_to_island < 1.0:
		return null
	var to_island_dir = to_island / dist_to_island

	# Walk from the ship toward the island in steps, find where SDF hits the sweet spot
	var best_station_pos: Vector3 = Vector3.ZERO
	var best_station_dist: float = INF

	# Also try a few lateral angles (±15°, ±30°) in case the direct approach isn't ideal
	var approach_angle = atan2(to_island_dir.x, to_island_dir.z)
	var angle_offsets = [0.0, deg_to_rad(15), -deg_to_rad(15), deg_to_rad(30), -deg_to_rad(30)]

	for angle_offset in angle_offsets:
		var test_angle = approach_angle + angle_offset
		var test_dir = Vector3(sin(test_angle), 0.0, cos(test_angle))

		# Walk from ship position toward the island along this direction
		# Stop when SDF is in the sweet spot: [ship_clearance, ship_clearance + 100]
		var step_size = 50.0  # Walk in 50m steps
		var max_walk = dist_to_island + best_island_radius  # Don't overshoot
		var walk_dist = 0.0

		while walk_dist < max_walk:
			var test_pos = my_pos + test_dir * walk_dist
			test_pos.y = 0.0

			var sdf_val = NavigationMapManager.get_distance(test_pos)

			# Sweet spot: navigable but close to shore
			if sdf_val >= ship_clearance and sdf_val <= ship_clearance + 100.0:
				if NavigationMapManager.is_navigable(test_pos, ship_clearance):
					var dist_from_ship = test_pos.distance_to(my_pos)
					# Prefer positions closer to the island (further along the walk)
					# but not if they're behind the island
					if walk_dist > 0:
						# Score: prefer closer to shore (lower sdf) and closer to ship
						var score_dist = dist_from_ship
						if score_dist < best_station_dist:
							best_station_dist = score_dist
							best_station_pos = test_pos
				break  # Found the shore band, stop walking further for this angle

			# If we've entered land (sdf < 0), we've gone too far
			if sdf_val < 0:
				break

			walk_dist += step_size

	# If the walk approach didn't find anything, try sampling around the island edge
	if best_station_pos == Vector3.ZERO:
		var to_ship_dir = -to_island_dir
		# Try positions radiating out from the island center toward the ship
		for extra_dist in [20.0, 50.0, 80.0, 120.0, 160.0]:
			for ang_off in angle_offsets:
				var test_angle2 = approach_angle + PI + ang_off  # Flip: from island toward ship
				var test_dir2 = Vector3(sin(test_angle2), 0.0, cos(test_angle2))
				var test_pos2 = best_island_pos + test_dir2 * (best_island_radius + extra_dist)
				test_pos2.y = 0.0
				if NavigationMapManager.is_navigable(test_pos2, ship_clearance):
					best_station_pos = test_pos2
					break
			if best_station_pos != Vector3.ZERO:
				break

	if best_station_pos == Vector3.ZERO:
		# Last resort fallback
		var to_ship_dir2 = -to_island_dir
		best_station_pos = best_island_pos + to_ship_dir2 * (best_island_radius + ship_clearance + 50.0)
		best_station_pos.y = 0.0

	# Validate through safe navigation pipeline
	best_station_pos = _validate_cover_position(ship, best_station_pos, ship_clearance)

	# Heading: tangential to island so the ship arcs around it naturally
	var station_heading = _compute_tangential_heading(ship, best_island_pos)

	var zone_radius = clamp(ship_clearance * 1.5, 80.0, 200.0)

	# Populate cover zone state — mark as startup so we force recompute on first enemy
	_cover_island_id = best_island_id
	_cover_zone_valid = true
	_cover_zone_center = best_station_pos
	_cover_zone_radius = zone_radius
	_cover_zone_heading = station_heading
	_cover_zone_timer = COVER_ZONE_RECOMPUTE_INTERVAL
	_cover_from_startup = true  # Flag: recompute immediately when enemies appear

	_cover_island_center = best_island_pos
	_cover_island_radius = best_island_radius
	_prev_cover_island_id = best_island_id

	# Use POSE to sail to the island at speed — STATION_KEEP will kick in
	# once _try_get_cover_zone_intent detects we're in cover (is_in_cover).
	var intent = NavIntent.pose(best_station_pos, station_heading)
	var dist_to_station = ship.global_position.distance_to(best_station_pos)
	if dist_to_station > 500.0:
		intent.throttle_override = 4
	elif dist_to_station > 200.0:
		intent.throttle_override = 3
	return intent

# ============================================================================
# FALLBACK POSITIONING (kept for compatibility)
# ============================================================================

## Compute approach heading from ship to destination
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

	# Apply spread
	var params = get_positioning_params()
	desired_position += _calculate_spread_offset(friendly, params.spread_distance, 1.0)

	# Cruiser prefers to kite - bias away from enemies
	var away_from_enemy = (_ship.global_position - avg_enemy).normalized()
	desired_position += away_from_enemy * r * 0.2

	# Only retreat toward teammates if below 50% HP
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
