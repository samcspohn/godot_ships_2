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

# Cached safe direction (toward spawn, away from enemies)
var _cached_safe_dir: Vector3 = Vector3.ZERO
var _safe_dir_initialized: bool = false

# Current island target (-1 = none)
var _target_island_id: int = -1
var _target_island_pos: Vector3 = Vector3.ZERO
var _target_island_radius: float = 0.0
var _nav_destination: Vector3 = Vector3.ZERO
var _nav_destination_valid: bool = false
var _abandoned_island_id: int = -1  # Island we just left — skip in next search

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
	"""Determine the 'safe' direction: toward our spawn, or away from the
	nearest enemy cluster if spawn is unavailable."""
	# Try spawn direction first
	_initialize_spawn_cache()
	if _cached_friendly_spawn != Vector3.ZERO:
		var dir = _cached_friendly_spawn
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

func _find_nearest_island(ship: Ship) -> Dictionary:
	"""Find the best island to move to — prefers islands that put the CA
	within gun range of enemies over merely close islands.
	Returns {id, center: Vector3, radius: float} or empty dict."""
	if not NavigationMapManager.is_map_ready():
		return {}

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return {}

	var my_pos = ship.global_position
	var gun_range = ship.artillery_controller.get_params()._range

	# Use spotted danger center if available; fall back to any known enemies.
	var enemy_center = _get_spotted_danger_center()
	if enemy_center == Vector3.ZERO:
		enemy_center = _get_danger_center()
	# Direction toward the enemy — used to prefer islands that push us forward.
	var toward_enemy = Vector3.ZERO
	if enemy_center != Vector3.ZERO:
		toward_enemy = (enemy_center - my_pos)
		toward_enemy.y = 0.0
		if toward_enemy.length_squared() > 1.0:
			toward_enemy = toward_enemy.normalized()

	var best_id: int = -1
	var best_score: float = INF
	var best_pos: Vector3 = Vector3.ZERO
	var best_radius: float = 0.0

	for isl in islands:
		# Skip the island we just abandoned — forces finding a new one
		if isl["id"] == _abandoned_island_id:
			continue

		var center_2d: Vector2 = isl["center"]
		var isl_pos = Vector3(center_2d.x, 0.0, center_2d.y)
		var isl_radius: float = isl["radius"]
		var eff_dist = maxf(isl_pos.distance_to(my_pos) - isl_radius, 0.0)

		var score: float = eff_dist
		if enemy_center != Vector3.ZERO:
			# How far the island's cover side is from the enemy.
			# Approximate cover position: island center + away-from-enemy * radius
			var away = (isl_pos - enemy_center).normalized() if isl_pos.distance_to(enemy_center) > 1.0 else Vector3.ZERO
			var cover_pos = isl_pos + away * (isl_radius + _get_ship_clearance())
			var cover_to_enemy = cover_pos.distance_to(enemy_center)

			# Penalise islands whose cover position is beyond gun range —
			# we can't shoot from there, so they're far less useful.
			var range_overshoot = maxf(cover_to_enemy - gun_range, 0.0)
			score += range_overshoot * 3.0

			# Bonus for islands that are ahead of us (toward the enemy).
			# dot > 0 means the island is in the enemy direction.
			if toward_enemy != Vector3.ZERO:
				var to_isl = (isl_pos - my_pos)
				to_isl.y = 0.0
				var forward_dot = to_isl.normalized().dot(toward_enemy) if to_isl.length_squared() > 1.0 else 0.0
				# Subtract a bonus (up to 2000) for islands in the forward hemisphere
				score -= forward_dot * 2000.0

		if score < best_score:
			best_score = score
			best_id = isl["id"]
			best_pos = isl_pos
			best_radius = isl_radius

	if best_id < 0:
		return {}

	return {
		"id": best_id,
		"center": best_pos,
		"radius": best_radius,
	}

func _compute_island_destination(_ship_unused: Ship, island_center: Vector3, island_radius: float, safe_dir: Vector3) -> Vector3:
	"""Ray-march from island center along safe_dir to find the actual shore edge,
	then place the ship just outside with clearance.
	Result is ship-independent so multiple ships share the same cover zone."""
	var clearance = _get_ship_clearance()

	if not NavigationMapManager.is_map_ready():
		var dest = island_center + safe_dir * (island_radius + clearance + 50.0)
		dest.y = 0.0
		return dest

	# Ray-march outward from island center along safe_dir
	var step_size = 25.0
	var max_dist = island_radius + 500.0
	var dest = Vector3.ZERO

	var found = false
	var dist = 0.0
	while dist < max_dist:
		var test = island_center + safe_dir * dist
		test.y = 0.0
		var sdf = NavigationMapManager.get_distance(test)
		if sdf >= clearance:
			dest = test
			found = true
			break
		if sdf < 0.0:
			dist -= min(sdf, -50)
		else:
			dist += max(clearance, 50)

	if not found:
		# Fallback: circle approximation
		dest = island_center + safe_dir * (island_radius + clearance + 50.0)
		dest.y = 0.0

	return dest

# ============================================================================
# TANGENTIAL HEADING — align ship parallel to island shore
# ============================================================================

func _tangential_heading(ship: Ship, island_center: Vector3, from_pos: Vector3) -> float:
	"""Compute a heading tangential to the island shore at from_pos using the
	SDF gradient (actual shore normal) rather than the radial from island center.
	Picks whichever tangent (CW or CCW) is closest to the ship's current heading."""
	if not NavigationMapManager.is_map_ready():
		# Fallback: radial from island center
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

	# Sample SDF gradient at from_pos to get the shore normal direction
	var eps = 25.0  # half cell size for finite difference
	var dx = NavigationMapManager.get_distance(Vector3(from_pos.x + eps, 0.0, from_pos.z)) \
		   - NavigationMapManager.get_distance(Vector3(from_pos.x - eps, 0.0, from_pos.z))
	var dz = NavigationMapManager.get_distance(Vector3(from_pos.x, 0.0, from_pos.z + eps)) \
		   - NavigationMapManager.get_distance(Vector3(from_pos.x, 0.0, from_pos.z - eps))

	# If gradient is near-zero (far from any land), fall back to radial
	if dx * dx + dz * dz < 0.0001:
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

	# Gradient points away from land (toward open water).
	# Tangent is perpendicular to gradient: CW = (-dz, dx), CCW = (dz, -dx)
	var cw = _normalize_angle(atan2(-dz, dx))
	var ccw = _normalize_angle(atan2(dz, -dx))
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

func _try_set_angling_island(ship: Ship, target: Ship) -> bool:
	"""Find the nearest island reachable within the angling cone, checking
	both ahead of and behind the ship.  Any island whose disc intersects the
	allowed cone (i.e. at least one point on the island falls within ±max_angle
	of the enemy bearing) is a valid candidate."""
	if target.ship_class == Ship.ShipClass.DD:
		return false
	if not NavigationMapManager.is_map_ready():
		return false
	var to_enemy = target.global_position - ship.global_position
	to_enemy.y = 0.0
	var enemy_dir = to_enemy.normalized()
	var enemy_bearing = atan2(to_enemy.x, to_enemy.z)
	var max_angle = _get_angle_range(target.ship_class).y
	# Add a small tolerance so islands whose edge just touches the cone are
	# not rejected due to floating-point noise.
	var cone_tolerance = deg_to_rad(5.0)
	var effective_half_angle = max_angle + cone_tolerance
	var clearance = _get_ship_clearance()
	var best_score = INF   # lower = closer, so we want minimum
	var best_island: Dictionary = {}
	var best_dest = Vector3.ZERO

	for isl in NavigationMapManager.get_islands():
		var center = Vector3(isl["center"].x, 0.0, isl["center"].y)
		var radius: float = isl["radius"]
		var to_isl = center - ship.global_position
		to_isl.y = 0.0
		var dist_to_center = to_isl.length()
		if dist_to_center < 1.0:
			continue

		# Angular half-width of this island disc as seen from the ship.
		# asin is only valid when the island is farther away than its own radius.
		var angular_half_width: float
		if dist_to_center > radius:
			angular_half_width = asin(clampf(radius / dist_to_center, 0.0, 1.0))
		else:
			# Ship is inside or right next to the island — treat as fully in-cone.
			angular_half_width = PI

		# The island intersects the cone if the closest bearing on the disc
		# to the enemy_bearing is within effective_half_angle.
		var isl_bearing = atan2(to_isl.x, to_isl.z)
		var bearing_diff = abs(_normalize_angle(isl_bearing - enemy_bearing))
		# Closest bearing on the disc edge to the cone centre
		var min_bearing_diff = maxf(bearing_diff - angular_half_width, 0.0)
		if min_bearing_diff > effective_half_angle:
			continue

		# Compute a destination on the side of the island facing away from the
		# enemy, so it can serve as cover.  The hide point sits just outside the
		# island on the opposite side from the target.
		var dest = center - enemy_dir * (radius + clearance + 50.0)
		dest.y = 0.0
		if NavigationMapManager.get_distance(dest) < clearance:
			# Try positioning behind the island relative to the enemy bearing
			# but offset along the angling heading so we stay in the cone.
			var current_heading = _get_ship_heading()
			var alt_dir = Vector3(sin(current_heading), 0.0, cos(current_heading))
			dest = center - alt_dir * (radius + clearance + 50.0)
			dest.y = 0.0
			if NavigationMapManager.get_distance(dest) < clearance:
				continue

		# Emergency cover — pick the nearest island in the cone so we get
		# behind something as fast as possible while still angling.
		var eff_dist = maxf(dist_to_center - radius, 0.0)
		if eff_dist < best_score:
			best_score = eff_dist
			best_island = {"id": isl["id"], "center": center, "radius": radius}
			best_dest = dest

	if best_island.is_empty():
		return false
	_set_island_state(best_island["id"], best_island["center"], best_island["radius"], best_dest)
	return true

# ============================================================================
# SKIRTING — move around island to break LOS when spotted
# ============================================================================

func _find_skirt_position(ship: Ship, server: GameServer) -> Vector3:
	if not NavigationMapManager.is_map_ready() or _target_island_id < 0:
		return Vector3.ZERO
	var threats = _gather_threat_positions(ship)
	if threats.is_empty():
		return Vector3.ZERO
	var threat_center = Vector3.ZERO
	for t in threats:
		threat_center += t
	threat_center /= threats.size()
	var clearance = _get_ship_clearance()
	var best_pos = Vector3.ZERO
	var best_dist = INF

	for i in range(18):  # Every 20 degrees around island
		var angle = deg_to_rad(i * 20.0)
		var dir = Vector3(sin(angle), 0.0, cos(angle))
		# Ray-march from island center to find position at clearance from shore
		var d = 0.0
		var max_d = _target_island_radius + 500.0
		var pos = Vector3.ZERO
		var found = false
		while d < max_d:
			var test = _target_island_pos + dir * d
			test.y = 0.0
			var sdf = NavigationMapManager.get_distance(test)
			if sdf >= clearance and sdf < clearance * 2.0:
				pos = test
				found = true
				break
			d += max(clearance - sdf, 25.0) if sdf >= 0.0 else -min(sdf, -25.0)
		if not found:
			continue
		if not NavigationMapManager.is_los_blocked(pos, threat_center):
			continue
		var dist_to_ship = pos.distance_to(ship.global_position)
		if dist_to_ship < best_dist:
			best_dist = dist_to_ship
			best_pos = pos
	return best_pos

func _try_skirt(ship: Ship, server: GameServer):
	if not _skirt_valid or Time.get_ticks_msec() - _skirt_search_ms > 2000:
		var pos = _find_skirt_position(ship, server)
		if pos == Vector3.ZERO:
			_skirt_valid = false
			return null
		_skirt_dest = pos
		_skirt_heading = _tangential_heading(ship, _target_island_pos, pos)
		_skirt_valid = true
		_skirt_search_ms = Time.get_ticks_msec()
	if ship.global_position.distance_to(_skirt_dest) < _get_ship_clearance() * 2.0:
		return null  # At best position; 2s timer will recheck
	var intent = NavIntent.create(_skirt_dest, _skirt_heading)
	intent.near_terrain = true
	intent.throttle_override = 3
	return intent

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
	# Clear the abandoned-island exclusion now that we've committed to a new one.
	# This lets us return to it later if the tactical situation changes.
	if id != _abandoned_island_id:
		_abandoned_island_id = -1
	if _last_in_range_ms == 0:
		_last_in_range_ms = Time.get_ticks_msec()
	_cover_island_center = center
	_cover_island_radius = radius
	_cover_zone_valid = true
	_cover_zone_radius = _get_ship_clearance() * 2.0
	# _cover_zone_center is intentionally NOT set here — it is always
	# stamped from the actual NavIntent destination in _stamp_cover_dest().

func _stamp_cover_dest(dest: Vector3) -> void:
	"""Keep _cover_zone_center in sync with the destination actually navigated to."""
	_cover_zone_center = dest

# ============================================================================
# NAVINTENT — Primary entry point (V4 bot controller)
# ============================================================================

func _make_intent(dest: Vector3, heading: float, arrival_radius: float = 0.0) -> NavIntent:
	"""Thin wrapper around NavIntent.create that also stamps the cover destination."""
	_stamp_cover_dest(dest)
	if arrival_radius > 0.0:
		return NavIntent.create(dest, heading, arrival_radius)
	return NavIntent.create(dest, heading)

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
	# Goes straight to _find_nearest_island (which scores by gun-range proximity)
	# rather than _try_set_angling_island, which is reserved for mid-transit combat.
	if _nav_destination_valid and Time.get_ticks_msec() - _last_in_range_ms > 20000:
		_abandoned_island_id = _target_island_id
		_nav_destination_valid = false
		_skirt_valid = false
		_fire_suppressed = true
		_last_in_range_ms = Time.get_ticks_msec()

	# Find a new island if we don't have one — scored to push toward the fight.
	if not _nav_destination_valid:
		var island = _find_nearest_island(ship)
		if not island.is_empty():
			var dest = _compute_island_destination(ship, island["center"], island["radius"], _cached_safe_dir)
			_set_island_state(island["id"], island["center"], island["radius"], dest)
		elif target:
			# No island available at all — angle toward target and fight in the open
			_cover_zone_valid = false
			return _intent_angle(ship, target)
		else:
			_cover_zone_valid = false
			return _intent_sail_forward(ship)

	# Spotted en-route to cover — find a nearby angling island so we can
	# fight while still heading toward cover.  This is the only place
	# _try_set_angling_island should be called (mid-transit combat).
	if _nav_destination_valid and not is_in_cover and ship.visible_to_enemy and target:
		_nav_destination_valid = false
		_skirt_valid = false
		_fire_suppressed = false
		if not _try_set_angling_island(ship, target):
			_cover_zone_valid = false
			return _intent_angle(ship, target)

	# Skirt around island when spotted in cover or while already skirting
	if ship.visible_to_enemy and (is_in_cover or _skirt_valid):
		var skirt = _try_skirt(ship, server)
		if skirt:
			_stamp_cover_dest(skirt.target_position)
			return skirt
	elif not ship.visible_to_enemy:
		_skirt_valid = false

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
