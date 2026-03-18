extends BotBehavior
class_name CABehavior

const SAFE_DIR_INVALIDATION_DOT: float = cos(deg_to_rad(20.0))

var ammo = ShellParams.ShellType.HE

# ============================================================================
# STATE TRACKING
# ============================================================================

# Cover zone state — kept for debug.gd compatibility
var _cover_zone_valid: bool = false
var _cover_zone_center: Vector3 = Vector3.ZERO
var _cover_zone_radius: float = 200.0
var _cover_can_shoot: bool = false
var _cover_island_center: Vector3 = Vector3.ZERO
var _cover_island_radius: float = 0.0

# Cover position search tuning
const _COVER_ANGLE_STEP: float = deg_to_rad(10.0)
const _COVER_ANGLE_HALF_SPAN: float = PI / 3.0

const _COVER_LOS_CLEARANCE: float = -50.0   # 1 cell buffer for LOS concealment checks (islands aren't perfectly modeled in SDF)

# Cached safe direction (toward spawn, away from enemies)
var _cached_safe_dir: Vector3 = Vector3.ZERO
var _safe_dir_initialized: bool = false

# Current island target (-1 = none)
var _target_island_id: int = -1
var _target_island_pos: Vector3 = Vector3.ZERO
var _target_island_radius: float = 0.0
var _nav_destination: Vector3 = Vector3.ZERO
var _nav_destination_valid: bool = false


# Engagement tracking
var _last_in_range_ms: int = 0
var _last_known_enemy_pos: Vector3 = Vector3.ZERO
var _last_known_enemy_valid: bool = false

# Skirting state
var _skirt_dest: Vector3 = Vector3.ZERO
var _skirt_heading: float = 0.0
var _skirt_valid: bool = false
var _skirt_search_ms: int = 0
var _fire_suppressed: bool = false

# Cover recalculation cooldown (ms) — when spotted, recalc at most this often
const _COVER_RECALC_COOLDOWN_MS: int = 3000
var _cover_recalc_ms: int = 0

# ============================================================================
# WEIGHT CONFIGURATION
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
		base_range_ratio = 0.65,
		range_increase_when_damaged = 0.30,
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
		use_island_cover = false,
	}

func should_evade(_destination: Vector3) -> bool:
	if not _ship.visible_to_enemy:
		return false
	return true

# ============================================================================
# TARGET SELECTION
# ============================================================================

func pick_target(targets: Array[Ship], last_target: Ship) -> Ship:
	# Always prefer targets we can actually hit (not behind cover/terrain).
	# Uses can_hit_target from base class which does a full sim shell trace.
	var weights = get_target_weights()
	var gun_range = _ship.artillery_controller.get_params()._range

	var best_shootable_target: Ship = null
	var best_shootable_priority: float = -1.0
	var best_fallback_target: Ship = null
	var best_fallback_priority: float = -1.0

	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp

		# Broadside profile
		var priority: float = ship.movement_controller.ship_length / dist * abs(sin(angle)) + ship.movement_controller.ship_beam / dist * abs(cos(angle))

		# Class modifier
		var class_mods: Dictionary = weights.class_modifiers
		if class_mods.has(ship.ship_class):
			priority *= class_mods[ship.ship_class]

		# Combine with range and HP weights
		var size_contrib = priority * weights.size_weight
		var range_contrib = (1.0 - dist / gun_range) * weights.range_weight
		var hp_contrib = (1.0 - hp_ratio) * weights.hp_weight
		priority = size_contrib + range_contrib + hp_contrib

		# Boost targets within range
		if dist <= gun_range:
			priority *= weights.in_range_multiplier

		# Flanking boost
		var flank_info = _get_flanking_info(ship)
		if flank_info.is_flanking:
			var flank_multiplier = weights.get("flanking_multiplier", 5.0)
			var depth_scale = 1.0 + flank_info.penetration_depth
			priority *= flank_multiplier * depth_scale

		# Sort into shootable vs fallback based on line-of-fire check
		if dist <= gun_range and can_hit_target(ship):
			if priority > best_shootable_priority:
				best_shootable_target = ship
				best_shootable_priority = priority
		else:
			if priority > best_fallback_priority:
				best_fallback_target = ship
				best_fallback_priority = priority

	# Prefer shootable targets; only fall back to blocked targets if nothing is shootable
	var best_target = best_shootable_target if best_shootable_target != null else best_fallback_target

	# Stick to last target if nearby and alive, but only if it's still shootable
	if best_target != null and last_target != null and last_target.is_alive():
		if last_target.position.distance_to(best_target.position) < 1000:
			if best_shootable_target == null or can_hit_target(last_target):
				return last_target

	return best_target

# ============================================================================
# AMMO AND AIM
# ============================================================================

func _can_shoot_over(target: Ship) -> bool:
	var target_pos = target.global_position + target_aim_offset(target)
	for gun in _ship.artillery_controller.guns:
		if gun.sim_can_shoot_over_terrain(target_pos):
			return true
	return false

func engage_target(target: Ship) -> void:
	var hunting = not _nav_destination_valid and _last_known_enemy_valid
	var shooting_ok = is_in_cover or hunting or (_ship.visible_to_enemy and not _fire_suppressed)
	if not shooting_ok:
		return
	super.engage_target(target)

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
					offset.y = _target.movement_controller.ship_height / 3
			else:
				offset.y = _target.movement_controller.ship_height / 3
		Ship.ShipClass.DD:
			offset.y = 1.0

	return offset

# ============================================================================
# SHARED HELPERS
# ============================================================================

func _gather_threat_positions(ship: Ship) -> Array:
	"""All known enemy positions: currently visible + last-known unspotted."""
	var threats: Array = []
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	if server_node == null:
		return threats
	for enemy in server_node.get_valid_targets(ship.team.team_id):
		if is_instance_valid(enemy) and enemy.health_controller.is_alive():
			threats.append(enemy.global_position)
	var unspotted = server_node.get_unspotted_enemies(ship.team.team_id)
	for enemy_ship in unspotted.keys():
		threats.append(unspotted[enemy_ship])
	return threats

func _get_ship_clearance() -> float:
	"""Use the navigator's hard clearance — single source of truth."""
	var controller = get_parent()
	if controller and controller.navigator:
		return controller.navigator.get_clearance_radius()
	return 100.0

func _get_turning_radius() -> float:
	if _ship and _ship.movement_controller:
		return _ship.movement_controller.turning_circle_radius
	return 300.0

func _safe_validate(ship: Ship, pos: Vector3) -> Vector3:
	"""Push a position through safe_nav_point + validate_destination."""
	var clearance = _get_ship_clearance()
	var turning_radius = _get_turning_radius()
	if NavigationMapManager.is_map_ready():
		pos = NavigationMapManager.safe_nav_point(ship.global_position, pos, clearance, turning_radius)
		pos = NavigationMapManager.validate_destination(ship.global_position, pos, clearance, turning_radius)
	return pos

# ============================================================================
# SAFE DIRECTION — toward spawn / away from enemies
# ============================================================================

func _compute_safe_direction(ship: Ship, server: GameServer) -> Vector3:
	"""Determine the 'safe' direction: toward our spawn from the ship,
	or away from the nearest enemy cluster if spawn is unavailable."""
	# Try spawn direction first
	_initialize_spawn_cache()
	if _cached_friendly_spawn != Vector3.ZERO:
		var dir = _cached_friendly_spawn - ship.global_position
		dir.y = 0.0
		if dir.length_squared() > 1.0:
			return dir.normalized()

	# Fallback: away from nearest enemy cluster
	var cluster = server.get_nearest_enemy_cluster(ship.global_position, ship.team.team_id)
	if not cluster.is_empty():
		var away = _target_island_pos - cluster.center
		away.y = 0.0
		if away.length_squared() > 1.0:
			return away.normalized()

	# Fallback: away from danger center
	var danger = _get_danger_center()
	if danger != Vector3.ZERO:
		var away = ship.global_position - danger
		away.y = 0.0
		if away.length_squared() > 1.0:
			return away.normalized()

	# Last resort: ship's current forward direction
	var fwd = -ship.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() > 0.1:
		return fwd.normalized()
	return Vector3(0, 0, -1)

func _ensure_safe_dir(ship: Ship, server: GameServer) -> void:
	if not _safe_dir_initialized:
		_cached_safe_dir = _compute_safe_direction(ship, server)
		_safe_dir_initialized = true

# ============================================================================
# ISLAND FINDING — nearest island, position on safe side
# ============================================================================

func _compute_hide_heading(island_center: Vector3, threats: Array) -> float:
	"""Average the headings from island_center to each threat, then add PI
	to get the direction facing away from all enemies.  Uses circular mean
	so headings near ±PI don't cancel out."""
	if threats.is_empty():
		return 0.0
	var sum_sin = 0.0
	var sum_cos = 0.0
	for threat_pos in threats:
		var to_threat = threat_pos - island_center
		to_threat.y = 0.0
		if to_threat.length_squared() < 1.0:
			continue
		var h = atan2(to_threat.x, to_threat.z)
		sum_sin += sin(h)
		sum_cos += cos(h)
	if absf(sum_sin) < 0.001 and absf(sum_cos) < 0.001:
		return 0.0
	# Average heading toward threats, then flip 180° to get hide heading.
	return atan2(sum_sin, sum_cos) + PI

func _find_nearest_island(ship: Ship) -> Dictionary:
	"""Find the best island to move to.  For each candidate island, computes
	the hide heading from the averaged enemy bearings + PI, then runs the
	full cover-position search (multiple angles, outside-in SDF walk,
	concealment + shootability validation).  Falls back to the simple SDF
	walk when the full search finds nothing for an island.
	Returns {id, center: Vector3, radius: float, dest: Vector3} or empty dict."""
	if not NavigationMapManager.is_map_ready():
		return {}

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return {}

	var my_pos = ship.global_position
	var gun_range = ship.artillery_controller.get_params()._range
	var clearance = _get_ship_clearance()
	var min_safe_range = gun_range * 0.35

	# Gather all known enemy positions for hide-heading calculation.
	var threats = _gather_threat_positions(ship)
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	var targets = server_node.get_valid_targets(ship.team.team_id)
	var enemy_clusters = server_node.get_enemy_clusters(ship.team.team_id)

	var best_id: int = -1
	var best_score: float = INF
	var best_pos: Vector3 = Vector3.ZERO
	var best_radius: float = 0.0
	var best_dest: Vector3 = Vector3.ZERO
	var best_can_shoot: bool = false  # track if best dest was validated shootable

	var nearest_target = Vector3.ZERO
	if not targets.is_empty():
		nearest_target = targets[0].global_position
		for t_ship in targets:
			var t = t_ship.global_position
			if t.distance_to(my_pos) < nearest_target.distance_to(my_pos):
				nearest_target = t

	# islands = islands.filter(func(isl) -> bool:
	# 	# Filter out islands that are too small to hide behind (radius < clearance)
	# 	var center = Vector3(isl["center"].x, 0.0, isl["center"].y)
	# 	var radius = isl["radius"]
	# 	if center.distance_to(nearest_target) + radius + clearance > gun_range:
	# 		return false
	# 	else:
	# 		return true
	# )

	for isl in islands:

		var center_2d: Vector2 = isl["center"]
		var isl_pos = Vector3(center_2d.x, 0.0, center_2d.y)
		var isl_radius: float = isl["radius"]
		var eff_dist = maxf(isl_pos.distance_to(my_pos) - isl_radius, 0.0)

		# Compute the hide heading from averaged enemy headings + PI.
		var hide_h: float
		var hide_dir: Vector3
		if threats.size() > 0:
			hide_h = _compute_hide_heading(isl_pos, threats)
			hide_dir = Vector3(sin(hide_h), 0.0, cos(hide_h))
		else:
			hide_dir = _cached_safe_dir
			hide_h = atan2(hide_dir.x, hide_dir.z)

		# Try the full cover-position search: multiple angles, outside-in,
		# concealment + shootability validated.
		var cover_result = _find_cover_position(ship, isl_pos, isl_radius, hide_h, threats, targets)

		# Skip this island entirely if no concealed position was found —
		# never fall back to an unvalidated position that may be exposed.
		if cover_result.is_empty():
			continue

		var dest: Vector3 = cover_result["pos"]
		var dest_validated_shootable: bool = cover_result["can_shoot"]

		# Find the nearest enemy cluster to this cover destination.
		var nearest_cluster_center = Vector3.ZERO
		var nearest_cluster_dist = INF
		for cluster in enemy_clusters:
			var d = dest.distance_to(cluster.center)
			if d < nearest_cluster_dist:
				nearest_cluster_dist = d
				nearest_cluster_center = cluster.center

		if nearest_cluster_center != Vector3.ZERO:
			var dest_to_cluster = nearest_cluster_dist

			# Hard filter: dest must keep the nearest cluster in gun range.
			if dest_to_cluster > gun_range:
				continue
			# Hard filter: don't park suicidally close.
			if dest_to_cluster < min_safe_range:
				continue

			# Score against the nearest cluster, not a global average.
			var pos_params = get_positioning_params()
			var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
			var desired_range = pos_params.base_range_ratio * gun_range
			desired_range += pos_params.range_increase_when_damaged * gun_range * (1.0 - hp_ratio)
			var score: float = eff_dist + absf(dest_to_cluster - desired_range)

			# Strongly prefer islands where the cover search confirmed we can
			# actually shoot over the terrain — apply a large bonus (negative
			# penalty) so validated positions beat unvalidated ones.
			if not dest_validated_shootable:
				continue

			if score < best_score:
				best_score = score
				best_id = isl["id"]
				best_pos = isl_pos
				best_radius = isl_radius
				best_dest = dest
				best_can_shoot = dest_validated_shootable
		else:
			var score = eff_dist
			if not dest_validated_shootable:
				score += 5000.0
			if score < best_score:
				best_score = score
				best_id = isl["id"]
				best_pos = isl_pos
				best_radius = isl_radius
				best_dest = dest
				best_can_shoot = dest_validated_shootable

	if best_id < 0:
		return {}

	return {
		"id": best_id,
		"center": best_pos,
		"radius": best_radius,
		"dest": best_dest,
		"can_shoot": best_can_shoot,
	}

func _sdf_walk_to_shore(island_center: Vector3, direction: Vector3, island_radius: float, clearance: float) -> Vector3:
	"""Walk the SDF outward from island_center along direction until we find a
	point with enough clearance for the ship.  Returns Vector3.ZERO on failure."""
	var max_dist = island_radius + 500.0
	var dist = 0.0
	while dist < max_dist:
		var test = island_center + direction * dist
		test.y = 0.0
		var sdf = NavigationMapManager.get_distance(test)
		if sdf >= clearance:
			return test
		if sdf < 0.0:
			dist += maxf(-sdf, 25.0)
		else:
			dist += maxf(clearance - sdf, 25.0)
	return Vector3.ZERO

func _is_los_blocked_with_clearance(from_pos: Vector3, to_pos: Vector3) -> bool:
	"""LOS check with clearance buffer — treats islands as slightly larger than
	the raw SDF to account for imperfect island modelling (off by ~1 cell)."""
	if not NavigationMapManager.is_map_ready():
		return false
	var map = NavigationMapManager.get_map()
	if map == null:
		return false
	var result: Dictionary = map.raycast(
		Vector2(from_pos.x, from_pos.z),
		Vector2(to_pos.x, to_pos.z),
		_COVER_LOS_CLEARANCE
	)
	return result["hit"]

func _find_cover_position(_ship_unused: Ship, island_center: Vector3, island_radius: float, hide_heading: float, threats: Array, targets: Array) -> Dictionary:
	"""Search for a position around the island that is fully concealed from
	enemies (flat LOS blocked to ALL threats) and allows shooting over the
	island at targets (ballistic arc simulation).

	Scans angles inward-out (0° first, ±10°, ±20°, … ±90° last), alternating
	+/- at each step to avoid biasing one side.  For each angle, walks the SDF
	center→outward to find the shore position, then checks concealment and
	shootability.  Returns the first position that passes both checks.
	Falls back to the best concealed-only position if nothing is shootable.
	Returns { "pos": Vector3, "can_shoot": bool } or empty dict."""
	var clearance = _get_ship_clearance()
	if not NavigationMapManager.is_map_ready():
		return {}
	if threats.is_empty() and targets.is_empty():
		return {}

	var shell_params = _ship.artillery_controller.get_shell_params()
	var gun_range = _ship.artillery_controller.get_params()._range
	var threat_count = threats.size()

	# Best concealed-only fallback (hides from all threats but can't shoot).
	var best_concealed_fallback: Vector3 = Vector3.ZERO

	# Scan angles inward-out (0° first, then ±10°, ±20°, … ±90°).
	# Prefers the most-concealed position (closest to hide heading) that
	# can still shoot.  Alternates +/- at each step to avoid side bias.
	var offset: float = 0.0
	while offset <= _COVER_ANGLE_HALF_SPAN + 0.001:
		# Build the 1 or 2 angles to test at this offset.
		var angles_to_test: Array[float] = []
		if offset < 0.001:
			angles_to_test.append(0.0)
		else:
			angles_to_test.append(offset)
			angles_to_test.append(-offset)

		for a_off in angles_to_test:
			var heading = hide_heading + a_off
			var dir = Vector3(sin(heading), 0.0, cos(heading))
			var pos = _sdf_walk_to_shore(island_center, dir, island_radius, clearance)
			if pos == Vector3.ZERO:
				continue

			# Quick range sanity — skip if no enemy is within gun range.
			var any_in_range = false
			for threat_pos in threats:
				if pos.distance_to(threat_pos) <= gun_range:
					any_in_range = true
					break
			if not any_in_range:
				continue

			# --- Concealment: must block LOS to ALL threats ---
			var hidden_count: int = 0
			for threat_pos in threats:
				if _is_los_blocked_with_clearance(pos, threat_pos):
					hidden_count += 1
			if hidden_count < threat_count:
				continue

			# --- Shootability: can we arc shells over the island at any target? ---
			var can_shoot_any: bool = false
			if shell_params != null:
				for t_ship in targets:
					if not is_instance_valid(t_ship) or not t_ship.health_controller.is_alive():
						continue
					var target_pos = t_ship.global_position + target_aim_offset(t_ship)
					if pos.distance_to(target_pos) > gun_range:
						continue
					var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(pos, target_pos, shell_params)
					if sol[0] == null:
						continue
					var shoot_result = Gun.sim_can_shoot_over_terrain_static(pos, sol[0], sol[1], shell_params, _ship)
					if shoot_result.can_shoot_over_terrain:
						can_shoot_any = true
						break  # one shootable target is enough

			if can_shoot_any:
				return { "pos": pos, "can_shoot": true }

			# Fully concealed but can't shoot — remember as fallback.
			if best_concealed_fallback == Vector3.ZERO:
				best_concealed_fallback = pos

		offset += _COVER_ANGLE_STEP

	if best_concealed_fallback != Vector3.ZERO:
		return { "pos": best_concealed_fallback, "can_shoot": false }

	return {}

# ============================================================================
# TANGENTIAL HEADING — align ship parallel to island shore
# ============================================================================

func _tangential_heading(_ship_unused2: Ship, island_center: Vector3, from_pos: Vector3) -> float:
	"""Compute a heading tangential to the island center from from_pos.
	Picks whichever tangent (CW or CCW) is closest to the ship's current heading."""
	var to_island = island_center - from_pos
	to_island.y = 0.0
	if to_island.length() < 1.0:
		return _get_ship_heading()
	var radial = atan2(to_island.x, to_island.z)
	var cw = _normalize_angle(radial + PI * 0.5)
	var ccw = _normalize_angle(radial - PI * 0.5)
	var current = _get_ship_heading()
	if abs(_normalize_angle(cw - current)) <= abs(_normalize_angle(ccw - current)):
		return cw
	return ccw

# ============================================================================
# ENEMY TRACKING
# ============================================================================

func _update_enemy_tracking(ship: Ship, server: GameServer, spotted: Array) -> void:
	var gun_range = ship.artillery_controller.get_params()._range
	for enemy in spotted:
		if enemy.global_position.distance_to(ship.global_position) <= gun_range:
			_last_in_range_ms = Time.get_ticks_msec()
			break
	# Track nearest known enemy for hunting
	var best_dist = INF
	for enemy in spotted:
		var d = enemy.global_position.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			_last_known_enemy_pos = enemy.global_position
			_last_known_enemy_valid = true
	for pos in server.get_unspotted_enemies(ship.team.team_id).values():
		var d = pos.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			_last_known_enemy_pos = pos
			_last_known_enemy_valid = true

# ============================================================================
# HUNTING — move toward last known enemy position
# ============================================================================

func _intent_hunt(ship: Ship) -> NavIntent:
	var to_enemy = _last_known_enemy_pos - ship.global_position
	to_enemy.y = 0.0
	if to_enemy.length() < 500.0:
		_last_known_enemy_valid = false
		return _intent_sail_forward(ship)
	var dest = _get_valid_nav_point(_last_known_enemy_pos)
	var heading = atan2(to_enemy.x, to_enemy.z)
	var intent = NavIntent.create(dest, heading)
	intent.throttle_override = 4
	return intent

# ============================================================================
# ANGLING — maintain armor angle toward target
# ============================================================================

func _get_angle_range(ship_class: Ship.ShipClass) -> Vector2:
	match ship_class:
		Ship.ShipClass.BB: return Vector2(deg_to_rad(25), deg_to_rad(31))
		Ship.ShipClass.CA: return Vector2(deg_to_rad(0), deg_to_rad(30))
		Ship.ShipClass.DD: return Vector2(deg_to_rad(0), deg_to_rad(40))
	return Vector2(deg_to_rad(0), deg_to_rad(30))

func _intent_angle(ship: Ship, target: Ship) -> NavIntent:
	var to_enemy = target.global_position - ship.global_position
	to_enemy.y = 0.0
	var enemy_bearing = atan2(to_enemy.x, to_enemy.z)
	var angle_range = _get_angle_range(target.ship_class)
	var desired = (angle_range.x + angle_range.y) * 0.5
	var cw = _normalize_angle(enemy_bearing + desired)
	var ccw = _normalize_angle(enemy_bearing - desired)

	# Score each candidate heading against all secondary threats.
	# For each secondary enemy, compute how much its bearing falls on the
	# exposed (broadside) side of the candidate heading.  A heading that
	# keeps more threats ahead/behind (low dot product) is preferred over
	# one that exposes our broadside to a cluster of secondaries.
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	var cw_score: float = 0.0
	var ccw_score: float = 0.0
	if server_node != null:
		var all_threats = _gather_threat_positions(ship)
		for threat_pos in all_threats:
			# Skip the primary target — we already angle for them
			if threat_pos.distance_to(target.global_position) < 50.0:
				continue
			var to_threat = threat_pos - ship.global_position
			to_threat.y = 0.0
			if to_threat.length_squared() < 1.0:
				continue
			var threat_dir = to_threat.normalized()
			# Compute the right-hand perpendicular of each candidate heading
			# (the direction that is our broadside).  The less broadside we
			# show toward a secondary threat the better, so we *penalise*
			# headings whose broadside axis aligns with that threat.
			var cw_fwd = Vector3(sin(cw), 0.0, cos(cw))
			var ccw_fwd = Vector3(sin(ccw), 0.0, cos(ccw))
			var cw_side = Vector3(cw_fwd.z, 0.0, -cw_fwd.x)   # right-hand perp
			var ccw_side = Vector3(ccw_fwd.z, 0.0, -ccw_fwd.x)
			# abs dot — both sides of the ship count equally
			cw_score += abs(cw_side.dot(threat_dir))
			ccw_score += abs(ccw_side.dot(threat_dir))

	# Lower score = less broadside exposed to secondaries — prefer that side.
	# Fall back to whichever side requires the smaller turn if scores are equal.
	var heading: float
	if abs(cw_score - ccw_score) > 0.05:
		heading = cw if cw_score < ccw_score else ccw
	else:
		var current = _get_ship_heading()
		heading = cw if abs(_normalize_angle(cw - current)) < abs(_normalize_angle(ccw - current)) else ccw

	# Maintain engagement range while angling — push hard when out of range
	var gun_range = ship.artillery_controller.get_params()._range
	var desired_dist = gun_range * 0.55
	var enemy_dist = to_enemy.length()
	var fwd = Vector3(sin(heading), 0.0, cos(heading))
	var dest = ship.global_position + fwd * 1000.0
	if enemy_dist > gun_range:
		# Well out of range — charge toward the enemy aggressively.
		# Close most of the excess distance so we actually get into the fight.
		var close_dist = (enemy_dist - desired_dist) * 0.8
		dest = ship.global_position + to_enemy.normalized() * close_dist
	elif enemy_dist > desired_dist * 1.3:
		# Within gun range but farther than desired — moderate approach
		var close_dist = (enemy_dist - desired_dist) * 0.5
		dest = ship.global_position + to_enemy.normalized() * close_dist
	elif enemy_dist < desired_dist * 0.4:
		dest = ship.global_position - to_enemy.normalized() * 1000.0
	dest.y = 0.0
	dest = _get_valid_nav_point(dest)
	return NavIntent.create(dest, heading)


# ============================================================================
# ISLAND STATE HELPER
# ============================================================================

func _set_island_state(id: int, center: Vector3, radius: float, dest: Vector3) -> void:
	_target_island_id = id
	_target_island_pos = center
	_target_island_radius = radius
	_nav_destination = dest
	_nav_destination_valid = true
	_skirt_valid = false

	if _last_in_range_ms == 0:
		_last_in_range_ms = Time.get_ticks_msec()
	_cover_island_center = center
	_cover_island_radius = radius
	_cover_zone_valid = true
	_cover_zone_radius = _get_ship_clearance() * 2.0
	# _cover_zone_center is intentionally NOT set here — it is always
	# stamped from the actual NavIntent destination in _stamp_cover_dest().

# ============================================================================
# NAVINTENT — Primary entry point (V4 bot controller)
# ============================================================================

func _make_intent(dest: Vector3, heading: float, arrival_radius: float = 0.0) -> NavIntent:
	"""Thin wrapper around NavIntent.create that also stamps the cover destination."""
	# _stamp_cover_dest(dest)
	if arrival_radius > 0.0:
		return NavIntent.create(dest, heading, arrival_radius)
	return NavIntent.create(dest, heading)

func _pick_nearest_spotted(ship: Ship, spotted: Array) -> Ship:
	"""Pick the nearest spotted enemy to use as an angling target."""
	var best: Ship = null
	var best_dist: float = INF
	for enemy in spotted:
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		var d = enemy.global_position.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			best = enemy
	return best

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	_ensure_safe_dir(ship, server)

	var spotted = server.get_valid_targets(ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_spotted = spotted.size() > 0
	var has_enemies = has_spotted or not unspotted.is_empty()

	# Recompute safe direction if enemies are known
	if has_enemies:
		var new_safe_dir = _compute_safe_direction(ship, server)
		if _nav_destination_valid and _cached_safe_dir.dot(new_safe_dir) < SAFE_DIR_INVALIDATION_DOT:
			_nav_destination_valid = false
			_skirt_valid = false
		_cached_safe_dir = new_safe_dir

	_update_enemy_tracking(ship, server, spotted)

	# HUNT: no enemies known — head toward last known position
	if not has_enemies:
		_nav_destination_valid = false
		_skirt_valid = false
		_cover_zone_valid = false
		if _last_known_enemy_valid:
			return _intent_hunt(ship)
		return _intent_sail_forward(ship)

	# HUNT (stale): enemies are only known from stale unspotted positions.
	# Don't anchor to cover islands based on phantom locations — push toward
	# the last-known position so we can re-spot them and get back in the fight.
	if not has_spotted:
		_nav_destination_valid = false
		_skirt_valid = false
		_cover_zone_valid = false
		if _last_known_enemy_valid:
			return _intent_hunt(ship)
		return _intent_sail_forward(ship)

	# Change island after 20s without in-range targets — push up toward the fight.
	# The old 60s timer left CAs parked at useless islands for too long.
	if _nav_destination_valid and Time.get_ticks_msec() - _last_in_range_ms > 20000:
		_nav_destination_valid = false
		_skirt_valid = false
		_fire_suppressed = true
		_last_in_range_ms = Time.get_ticks_msec()

	# Find a new island if we don't have one — scored to push toward the fight.
	if not _nav_destination_valid:
		var island = _find_nearest_island(ship)
		if not island.is_empty():
			# Use the pre-computed destination from _find_nearest_island — it
			# was scored and validated using the enemy-aware hide direction, so
			# the destination is guaranteed to keep targets in gun range.
			_set_island_state(island["id"], island["center"], island["radius"], island["dest"])
		else:
			# No island available — angle toward target and fight in the open.
			_cover_zone_valid = false
			var angle_target = target if target else _pick_nearest_spotted(ship, spotted)
			if angle_target:
				return _intent_angle(ship, angle_target)
			return _intent_sail_forward(ship)

	# When spotted, recalculate cover position on the current island to find
	# a spot that restores concealment (and ideally keeps shootability).
	# Throttled by _COVER_RECALC_COOLDOWN_MS to keep cost bounded.
	#if ship.visible_to_enemy and _nav_destination_valid:
	var now_ms = Time.get_ticks_msec()
	if now_ms - _cover_recalc_ms >= _COVER_RECALC_COOLDOWN_MS:
		_cover_recalc_ms = now_ms
		var threats = _gather_threat_positions(ship)
		var targets_list = server.get_valid_targets(ship.team.team_id)
		var hide_h: float
		if threats.size() > 0:
			hide_h = _compute_hide_heading(_target_island_pos, threats)
		else:
			hide_h = atan2(_cached_safe_dir.x, _cached_safe_dir.z)
		var cover_result = _find_cover_position(ship, _target_island_pos, _target_island_radius, hide_h, threats, targets_list)
		if not cover_result.is_empty() and cover_result["can_shoot"]:
			var new_dest: Vector3 = cover_result["pos"]
			# Accept if meaningfully different from where the ship
			# actually IS — not from the old nav target.
			if new_dest.distance_to(ship.global_position) > _get_ship_clearance():
				_nav_destination = new_dest
				_skirt_valid = false
				is_in_cover = false
		else:
			# No concealed position exists on this island for the current
			# threat layout — abandon it and immediately try to pick a new
			# island rather than falling through to stale approach logic.
			_nav_destination_valid = false
			_skirt_valid = false
			is_in_cover = false
			var island = _find_nearest_island(ship)
			if not island.is_empty():
				_set_island_state(island["id"], island["center"], island["radius"], island["dest"])
			else:
				_cover_zone_valid = false
				var angle_target = target if target else _pick_nearest_spotted(ship, spotted)
				if angle_target:
					return _intent_angle(ship, angle_target)
				return _intent_sail_forward(ship)

	## Skirt around island when spotted in cover or while already skirting
	## (fallback if cover recalc didn't reposition us)
	#if ship.visible_to_enemy and (is_in_cover or _skirt_valid):
		#var skirt = _try_skirt(ship, server)
		#if skirt:
			#_stamp_cover_dest(skirt.target_position)
			#return skirt
	#elif not ship.visible_to_enemy:
		#_skirt_valid = false
		#_cover_recalc_ms = 0

	# Approach / station-keep
	var dist_to_dest = ship.global_position.distance_to(_nav_destination)
	var clearance = _get_ship_clearance()
	var arrival_radius = clearance * 2.0
	# Hysteresis: once in cover, allow a larger drift before losing cover status.
	# This prevents obstacle-avoidance displacement (e.g. a friendly nudging us)
	# from immediately flipping is_in_cover off → triggering COVER_LOST → forcing
	# a re-approach that fights the avoidance in a throttle oscillation loop.
	var exit_radius = clearance * 3.5
	var arrived: bool
	if is_in_cover:
		arrived = dist_to_dest < exit_radius
	else:
		arrived = dist_to_dest < arrival_radius
	var heading = _tangential_heading(ship, _target_island_pos, _nav_destination)

	is_in_cover = arrived
	_cover_can_shoot = arrived
	if arrived:
		_fire_suppressed = false

	if arrived:
		var intent = _make_intent(_nav_destination, heading, arrival_radius * 0.5)
		intent.near_terrain = true
		# When we're still in cover (hysteresis zone) but drifted past the
		# tight arrival radius, gently return without a throttle override so
		# the navigator's own avoidance can manage nearby friendlies.
		if dist_to_dest > arrival_radius:
			intent.throttle_override = -1
		return intent

	var intent = _make_intent(_nav_destination, heading)
	intent.near_terrain = true
	# throttle_override removed — the navigator handles smooth deceleration
	# on approach via compute_magnitude_for_approach(). Overriding here was
	# forcing high throttle past the navigator's deceleration zone, causing
	# ships to blow past their destination.
	return intent

# ============================================================================
# FALLBACK — sail forward when no island available
# ============================================================================

var _fwd = null
func _intent_sail_forward(ship: Ship) -> NavIntent:
	"""Fallback: sail straight ahead."""
	# var fwd = -ship.global_transform.basis.z
	if _fwd == null:
		_fwd = -ship.global_transform.basis.z
	var fwd = _fwd
	fwd.y = 0.0
	if fwd.length_squared() < 0.1:
		fwd = Vector3(0, 0, -1)
	var dest = ship.global_position + fwd.normalized() * 5000.0
	dest.y = 0.0
	dest = _get_valid_nav_point(dest)
	return NavIntent.create(dest, atan2(fwd.x, fwd.z))
