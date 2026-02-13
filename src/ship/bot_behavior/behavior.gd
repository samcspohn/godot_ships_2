extends Node
class_name BotBehavior
# Base class for bot behavior with configurable weights and shared utilities

var _ship: Ship = null
var nav: NavigationAgent3D

# Evasion state variables
var evasion_timer: float = 0.0
var evasion_direction: int = 1  # 1 or -1, which side we're currently angling
var last_target_bearing: float = 0.0  # Track target to keep guns on it

# ============================================================================
# ISLAND COVER SYSTEM (moved from CA - available to all classes)
# ============================================================================
var current_island: StaticBody3D = null
var island_position_valid: bool = false
var island_cache_timer: float = 0.0
const ISLAND_CACHE_DURATION: float = 5.0

var is_in_cover: bool = false
const IN_COVER_THRESHOLD: float = 300.0
const MIN_ISLAND_COVER_DISTANCE: float = 100.0

# Approximate island radius cache
var island_radius_cache: Dictionary = {}  # StaticBody3D -> float

# ============================================================================
# TORPEDO SYSTEM (moved from DD - available to ships with torpedoes)
# ============================================================================
var torpedo_fire_interval: float = 3.0
var torpedo_fire_timer: float = 0.0
var torpedo_target_position: Vector3 = Vector3.ZERO
var has_valid_torpedo_solution: bool = false
var current_torpedo_range: float = 0.0

# Torpedo lead tracking
var last_lead_angle: float = 0.0
var lead_angle_change_rate: float = 0.0
var last_lead_update_time: float = 0.0
const LEAD_ANGLE_SMOOTHING: float = 0.3

# Torpedo spread parameters
const SPREAD_ANGLE_BASE: float = 0.05
const SPREAD_ANGLE_PER_KM: float = 0.01
const MIN_TORPEDO_INTERVAL: float = 0.5
const MAX_TORPEDO_INTERVAL: float = 15.0
const RANGE_FOR_MAX_INTERVAL: float = 10000.0

# Torpedo salvo state
var torpedoes_in_salvo: int = 0
var salvo_spread_index: int = 0
var current_salvo_positions: Array[Vector3] = []

# Friendly fire check
var friendly_fire_check_radius: float = 5000.0
var friendly_fire_safety_margin: float = 500.0

# ============================================================================
# CONFIGURABLE WEIGHT SYSTEMS - Override in subclasses
# ============================================================================

func get_target_weights() -> Dictionary:
	"""Override to customize target selection weights."""
	return {
		size_weight = 0.3,
		range_weight = 0.5,
		hp_weight = 0.2,
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.0,
			Ship.ShipClass.DD: 1.0,
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
	}

func get_positioning_params() -> Dictionary:
	"""Override to customize positioning behavior."""
	return {
		base_range_ratio = 0.60,
		range_increase_when_damaged = 0.20,
		min_safe_distance_ratio = 0.40,
		flank_bias_healthy = 0.5,
		flank_bias_damaged = 0.2,
		spread_distance = 500.0,
		spread_multiplier = 2.0,
	}

func get_island_cover_params() -> Dictionary:
	"""Override to customize island cover behavior. Return empty dict to disable."""
	return {}  # Base class doesn't use island cover by default

func get_hunting_params() -> Dictionary:
	"""Override to customize hunting behavior."""
	return {
		approach_multiplier = 0.4,
		cautious_hp_threshold = 0.5,
		use_island_cover = false,
	}

func get_evasion_params() -> Dictionary:
	"""Override for class-specific evasion parameters."""
	return {
		min_angle = deg_to_rad(25),
		max_angle = deg_to_rad(35),
		evasion_period = 6.0,
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	"""Weight for threat calculation based on enemy ship class."""
	match ship_class:
		Ship.ShipClass.BB: return 1.5
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 0.5
	return 1.0

# ============================================================================
# NAVIGATION UTILITIES
# ============================================================================

func _get_valid_nav_point(target: Vector3) -> Vector3:
	var nav_map = nav.get_navigation_map()
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, target)
	return closest_point

# ============================================================================
# TARGET SELECTION
# ============================================================================

func pick_target(targets: Array[Ship], last_target: Ship) -> Ship:
	"""Configurable target selection using weights from get_target_weights()."""
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
		var priority: float = 0.0
		if weights.prefer_broadside:
			priority = ship.movement_controller.ship_length / dist * abs(sin(angle)) + ship.movement_controller.ship_beam / dist * abs(cos(angle))
		else:
			priority = ship.movement_controller.ship_length / dist

		# Apply class modifier
		var class_mods: Dictionary = weights.class_modifiers
		if class_mods.has(ship.ship_class):
			priority *= class_mods[ship.ship_class]

		# Combine with range and HP weights
		var size_contrib = priority * weights.size_weight
		var range_contrib = (1.0 - dist / gun_range) * weights.range_weight
		var hp_contrib = (1.5 - hp_ratio) * weights.hp_weight
		priority = size_contrib + range_contrib + hp_contrib

		# Boost targets within range
		if dist <= gun_range:
			priority *= weights.in_range_multiplier

		if priority > best_priority:
			best_target = ship
			best_priority = priority

	# Stick to last target if nearby and alive
	if best_target != null and last_target != null and last_target.is_alive():
		if last_target.position.distance_to(best_target.position) < 1000:
			return last_target

	return best_target

func pick_ammo(target: Ship) -> int:
	var ammo = ShellParams.ShellType.AP
	if target.ship_class == Ship.ShipClass.DD:
		ammo = ShellParams.ShellType.HE
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	"""Returns the offset to the target to aim at in local space. Override in subclasses."""
	return Vector3.ZERO

# ============================================================================
# EVASION SYSTEM
# ============================================================================

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion. Override in DD for speed variation."""
	return 1.0

func should_evade(destination: Vector3) -> bool:
	"""Determine if ship should be evading vs traveling to destination."""
	if not _ship.visible_to_enemy:
		return false

	var dist_to_dest = _ship.global_position.distance_to(destination)
	var movement = _ship.get_node_or_null("Modules/MovementController") as ShipMovementV4
	if movement == null:
		return true

	var arrival_threshold = movement.turning_circle_radius * 2.0
	return dist_to_dest < arrival_threshold

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Returns {heading: float, use_evasion: bool}."""
	if not should_evade(destination):
		return {heading = current_heading, use_evasion = false}

	var threat_bearing = _get_weighted_threat_bearing()
	if threat_bearing == null:
		return {heading = current_heading, use_evasion = false}

	var evasion_heading = _calculate_evasion_heading(target, threat_bearing, delta)
	return {heading = evasion_heading, use_evasion = true}

func _calculate_evasion_heading(target: Ship, threat_bearing: float, delta: float) -> float:
	"""Calculate heading that angles toward threat while keeping guns on target."""
	var params = get_evasion_params()
	var min_angle = params.min_angle
	var max_angle = params.max_angle
	var period = params.evasion_period

	evasion_timer += delta

	var wave = (sin(evasion_timer * TAU / period) + 1.0) / 2.0
	var current_angle = lerp(min_angle, max_angle, wave)

	if target != null:
		var to_target = target.global_position - _ship.global_position
		var target_bearing = atan2(to_target.x, to_target.z)
		var wave_derivative = cos(evasion_timer * TAU / period)

		if wave_derivative < 0:
			var current_ship_heading = _get_ship_heading()
			var angle_to_target = _normalize_angle(target_bearing - current_ship_heading)
			evasion_direction = 1 if angle_to_target > 0 else -1

		last_target_bearing = target_bearing

	return _normalize_angle(threat_bearing + current_angle * evasion_direction)

func _get_weighted_threat_bearing() -> Variant:
	"""Returns bearing to weighted average of enemy clusters. null if no threats."""
	var danger_center = _get_danger_center()
	if danger_center == Vector3.ZERO:
		return null
	var to_danger = danger_center - _ship.global_position
	return atan2(to_danger.x, to_danger.z)

# ============================================================================
# THREAT ANALYSIS
# ============================================================================

func _get_danger_center() -> Vector3:
	"""Calculate threat-weighted center of known enemies."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return Vector3.ZERO

	var enemy_clusters = server_node.get_enemy_clusters(_ship.team.team_id)

	if enemy_clusters.is_empty():
		return server_node.get_enemy_avg_position(_ship.team.team_id)

	var weighted_pos = Vector3.ZERO
	var total_weight = 0.0

	for cluster in enemy_clusters:
		var cluster_pos: Vector3 = cluster.center
		var to_cluster = cluster_pos - _ship.global_position
		var dist = to_cluster.length()

		if dist < 1.0:
			dist = 1.0

		var base_weight = 1.0 / (dist * dist / 10000.0 + 1.0)

		var cluster_threat = 0.0
		for ship in cluster.ships:
			if ship != null and is_instance_valid(ship):
				cluster_threat += get_threat_class_weight(ship.ship_class)
			else:
				cluster_threat += 1.0

		var weight = base_weight * max(cluster_threat, 1.0)
		weighted_pos += cluster_pos * weight
		total_weight += weight

	if total_weight < 0.001:
		return Vector3.ZERO

	return weighted_pos / total_weight

func _get_nearest_enemy() -> Dictionary:
	"""Find the nearest known enemy. Returns {position, distance, ship} or empty dict."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return {}

	var nearest_pos = Vector3.ZERO
	var nearest_dist = INF
	var nearest_ship: Ship = null

	var valid_targets = server_node.get_valid_targets(_ship.team.team_id)
	for ship in valid_targets:
		var dist = _ship.global_position.distance_to(ship.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_pos = ship.global_position
			nearest_ship = ship

	var unspotted = server_node.get_unspotted_enemies(_ship.team.team_id)
	for ship in unspotted.keys():
		var last_pos: Vector3 = unspotted[ship]
		var dist = _ship.global_position.distance_to(last_pos)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_pos = last_pos
			nearest_ship = ship

	if nearest_dist == INF:
		return {}

	return {position = nearest_pos, distance = nearest_dist, ship = nearest_ship}

func _get_flanking_direction(danger_center: Vector3, friendly_avg: Vector3) -> int:
	"""Determine which direction to flank (1 = right, -1 = left)."""
	if danger_center == Vector3.ZERO:
		return 1

	var to_danger = danger_center - _ship.global_position
	to_danger.y = 0.0
	var danger_bearing = atan2(to_danger.x, to_danger.z)

	var right_angle = _normalize_angle(danger_bearing + PI / 2.0)
	var left_angle = _normalize_angle(danger_bearing - PI / 2.0)

	if friendly_avg != Vector3.ZERO:
		var to_friendly = friendly_avg - _ship.global_position
		to_friendly.y = 0.0
		var friendly_bearing = atan2(to_friendly.x, to_friendly.z)

		var right_diff = abs(_normalize_angle(right_angle - friendly_bearing))
		var left_diff = abs(_normalize_angle(left_angle - friendly_bearing))

		return 1 if right_diff > left_diff else -1

	var current_heading = _get_ship_heading()
	var angle_to_danger = _normalize_angle(danger_bearing - current_heading)
	return 1 if angle_to_danger > 0 else -1

# ============================================================================
# TACTICAL POSITIONING
# ============================================================================

func _calculate_tactical_position(desired_range: float, min_safe_distance: float, flank_bias: float = 0.0) -> Vector3:
	"""Calculate position based on tactical situation."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return _ship.global_position

	var danger_center = _get_danger_center()
	if danger_center == Vector3.ZERO:
		return _ship.global_position

	var friendly_avg = server_node.get_team_avg_position(_ship.team.team_id)
	var nearest = _get_nearest_enemy()

	var to_me = _ship.global_position - danger_center
	to_me.y = 0.0
	var current_angle = atan2(to_me.x, to_me.z)

	var retreat_factor = 0.0
	if not nearest.is_empty():
		var nearest_dist: float = nearest.distance
		if nearest_dist < min_safe_distance:
			retreat_factor = 1.0 - (nearest_dist / min_safe_distance)
			retreat_factor = clamp(retreat_factor, 0.0, 1.0)

	var target_dist = desired_range
	if retreat_factor > 0:
		target_dist = lerp(desired_range, desired_range * 1.5, retreat_factor)

	var flank_direction = _get_flanking_direction(danger_center, friendly_avg)
	var flank_angle = flank_bias * (PI / 4.0) * flank_direction
	var target_angle = current_angle + flank_angle * 0.1

	if retreat_factor > 0 and not nearest.is_empty():
		var nearest_pos: Vector3 = nearest.position
		var to_nearest = nearest_pos - _ship.global_position
		to_nearest.y = 0.0
		var nearest_bearing = atan2(to_nearest.x, to_nearest.z)
		var away_bearing = _normalize_angle(nearest_bearing + PI)

		var retreat_pos = _ship.global_position + Vector3(sin(away_bearing), 0, cos(away_bearing)) * 1000.0
		var retreat_to_danger = retreat_pos - danger_center
		var retreat_arc_angle = atan2(retreat_to_danger.x, retreat_to_danger.z)

		target_angle = lerp_angle(target_angle, retreat_arc_angle, retreat_factor * 0.5)

	var target_pos = danger_center + Vector3(sin(target_angle), 0, cos(target_angle)) * target_dist

	if friendly_avg != Vector3.ZERO:
		var to_friendly = friendly_avg - target_pos
		to_friendly.y = 0.0
		var friendly_dist = to_friendly.length()
		var max_extend_dist = 5000.0

		if friendly_dist > max_extend_dist:
			var pull_back = (friendly_dist - max_extend_dist) / friendly_dist
			target_pos = target_pos + to_friendly * pull_back * 0.5

	target_pos.y = 0.0
	return target_pos

func _calculate_spread_offset(friendly: Array[Ship], min_spread_distance: float, multiplier: float = 2.0) -> Vector3:
	"""Calculate offset to avoid clumping with teammates."""
	var spread_offset = Vector3.ZERO
	var check_distance = min_spread_distance * multiplier

	for ship in friendly:
		if ship == _ship:
			continue
		var to_teammate = _ship.global_position - ship.global_position
		var dist_to_teammate = to_teammate.length()
		if dist_to_teammate < check_distance and dist_to_teammate > 0.1:
			var push_strength = 1.0 - (dist_to_teammate / check_distance)
			spread_offset += to_teammate.normalized() * push_strength * min_spread_distance

	return spread_offset

# ============================================================================
# HUNTING BEHAVIOR
# ============================================================================

func _get_hunting_position(server_node: GameServer, friendly: Array[Ship], current_destination: Vector3) -> Vector3:
	"""Common hunting behavior when no enemies are visible."""
	if server_node == null:
		return current_destination

	var params = get_hunting_params()
	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	var unspotted_enemies = server_node.get_unspotted_enemies(_ship.team.team_id)

	if unspotted_enemies.is_empty():
		var avg_enemy = server_node.get_enemy_avg_position(_ship.team.team_id)
		if avg_enemy != Vector3.ZERO:
			var to_enemy = (avg_enemy - _ship.global_position).normalized()
			var hunt_pos = _ship.global_position + to_enemy * gun_range * params.approach_multiplier
			return _get_valid_nav_point(hunt_pos)
		return current_destination

	# Find closest unspotted enemy
	var closest_pos: Vector3 = Vector3.ZERO
	var closest_dist: float = INF

	for ship in unspotted_enemies.keys():
		var last_known_pos: Vector3 = unspotted_enemies[ship]
		var dist = _ship.global_position.distance_to(last_known_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_pos = last_known_pos

	if closest_pos == Vector3.ZERO:
		return current_destination

	var to_target = (closest_pos - _ship.global_position).normalized()
	var approach_distance = gun_range * lerp(params.approach_multiplier, params.approach_multiplier * 0.5, 1.0 - hp_ratio)
	var desired_pos = _ship.global_position + to_target * approach_distance

	# Apply spread
	var pos_params = get_positioning_params()
	desired_pos += _calculate_spread_offset(friendly, pos_params.spread_distance, pos_params.spread_multiplier)

	# Bias toward friendlies when low HP
	if hp_ratio < params.cautious_hp_threshold:
		var nearest_cluster = server_node.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
		if not nearest_cluster.is_empty():
			var cluster_center: Vector3 = nearest_cluster.center
			var to_cluster = (cluster_center - _ship.global_position).normalized()
			desired_pos = _ship.global_position + (to_target * 0.6 + to_cluster * 0.4).normalized() * approach_distance

	# Use island cover if enabled
	if params.use_island_cover:
		var island = _find_island_toward_position(closest_pos, gun_range)
		if island != null:
			var cover_pos = get_island_cover_position(island, closest_pos, gun_range)
			if cover_pos != Vector3.ZERO:
				return cover_pos

	return _get_valid_nav_point(desired_pos)

# ============================================================================
# ISLAND COVER SYSTEM
# ============================================================================

func find_optimal_island(danger_center: Vector3, gun_range: float, hp_ratio: float, dist_to_nearest: float) -> StaticBody3D:
	"""Find the best island for cover based on danger center and tactical situation."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null or server_node.map == null:
		return null

	var map: Map = server_node.map
	if map.islands.size() == 0:
		return null

	if danger_center == Vector3.ZERO:
		return null

	var params = get_island_cover_params()
	if params.is_empty():
		return null

	var my_pos = _ship.global_position
	var aggressive_range = params.get("aggressive_range", 0.60)
	var defensive_range = params.get("defensive_range", 0.70)
	var abandon_too_close = params.get("abandon_too_close", 0.35)

	var ideal_range_ratio = lerp(aggressive_range, defensive_range, 1.0 - hp_ratio)
	var ideal_distance = gun_range * ideal_range_ratio
	var prefer_farther = dist_to_nearest < gun_range * abandon_too_close

	var best_island: StaticBody3D = null
	var best_score = -INF

	for island in map.islands:
		if not is_instance_valid(island):
			continue

		var island_pos = island.global_position
		var island_to_danger = island_pos.distance_to(danger_center)

		if island_to_danger > gun_range * 0.85:
			continue

		var dist_to_us = island_pos.distance_to(my_pos)
		var potential_engagement_dist = island_to_danger
		var range_diff = abs(potential_engagement_dist - ideal_distance)
		var score = -range_diff

		score -= dist_to_us * 0.5

		if prefer_farther:
			score += island_to_danger * 3.0

		var to_danger_dir = (danger_center - my_pos).normalized()
		var to_island_dir = (island_pos - my_pos).normalized()
		var alignment = to_danger_dir.dot(to_island_dir)
		if alignment > 0:
			score += alignment * 300.0

		if score > best_score:
			best_score = score
			best_island = island

	return best_island

func get_island_cover_position(island: StaticBody3D, danger_center: Vector3, gun_range: float) -> Vector3:
	"""Get position behind island for cover."""
	if island == null:
		return Vector3.ZERO

	var island_pos = island.global_position
	var island_radius = get_island_radius(island)

	var to_danger = (danger_center - island_pos).normalized()
	var cover_dir = -to_danger

	var cover_distance = island_radius + 200.0
	if _ship.visible_to_enemy:
		cover_distance = island_radius + 400.0

	var cover_pos = island_pos + cover_dir * cover_distance
	cover_pos.y = 0.0

	var dist_to_danger = cover_pos.distance_to(danger_center)
	if dist_to_danger > gun_range * 0.9:
		var blended_dir = (cover_dir * 0.6 + to_danger * 0.4).normalized()
		cover_pos = island_pos + blended_dir * cover_distance
		cover_pos.y = 0.0

	return _get_valid_nav_point(cover_pos)

func get_island_radius(island: StaticBody3D) -> float:
	"""Get or compute approximate island radius."""
	if island_radius_cache.has(island):
		return island_radius_cache[island]

	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node and server_node.map:
		var edge_points = server_node.map.get_edge_points_for_island(island)
		if edge_points.size() > 0:
			var island_pos = island.global_position
			var max_dist = 0.0
			for point in edge_points:
				var dist = island_pos.distance_to(point)
				if dist > max_dist:
					max_dist = dist
			island_radius_cache[island] = max_dist
			return max_dist

	var radius = 500.0
	island_radius_cache[island] = radius
	return radius

func _find_island_toward_position(target_pos: Vector3, gun_range: float) -> StaticBody3D:
	"""Find an island that provides cover while moving toward a position."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null or server_node.map == null:
		return null

	var map: Map = server_node.map
	if map.islands.size() == 0:
		return null

	var my_pos = _ship.global_position
	var best_island: StaticBody3D = null
	var best_score = -INF

	for island in map.islands:
		if not is_instance_valid(island):
			continue

		var island_pos = island.global_position
		var dist_to_us = island_pos.distance_to(my_pos)
		var island_to_target = island_pos.distance_to(target_pos)

		if island_to_target > gun_range * 0.9:
			continue

		var to_target_dir = (target_pos - my_pos).normalized()
		var to_island_dir = (island_pos - my_pos).normalized()
		var alignment = to_target_dir.dot(to_island_dir)

		var score = alignment * 500.0
		score -= dist_to_us * 0.3

		if score > best_score:
			best_score = score
			best_island = island

	return best_island

func can_shoot_target_from_position(pos: Vector3, target: Ship) -> bool:
	"""Check if we can shoot over terrain at the target from the given position."""
	var shell_params = _ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return false

	var target_pos = target.global_position + target_aim_offset(target)
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(pos, target_pos, shell_params)

	if sol[0] == null:
		return false

	var launch_vector = sol[0]
	var flight_time = sol[1]

	var can_shoot = Gun.sim_can_shoot_over_terrain_static(pos, launch_vector, flight_time, shell_params, _ship)
	return can_shoot.can_shoot_over_terrain

# ============================================================================
# TORPEDO SYSTEM
# ============================================================================

func update_torpedo_aim(target_ship: Ship):
	"""Update torpedo aiming solution. Call this for ships with torpedoes."""
	has_valid_torpedo_solution = false
	current_salvo_positions.clear()

	if !target_ship or !is_instance_valid(target_ship):
		return

	var torpedo_controller = _ship.torpedo_controller
	if !torpedo_controller:
		return

	var distance_to_target = _ship.global_position.distance_to(target_ship.global_position)
	var torpedo_range = torpedo_controller.get_params()._range

	if distance_to_target > torpedo_range * 0.9:
		return

	current_torpedo_range = distance_to_target

	var torpedo_speed = torpedo_controller.get_torp_params().speed * TorpedoManager.TORPEDO_SPEED_MULTIPLIER
	torpedo_target_position = calculate_interception_point(
		_ship.global_position,
		target_ship.global_position,
		target_ship.linear_velocity,
		torpedo_speed
	)

	var interception_distance = _ship.global_position.distance_to(torpedo_target_position)
	if interception_distance > torpedo_range * 0.95:
		return

	var current_time = Time.get_ticks_msec() / 1000.0
	var to_lead = torpedo_target_position - _ship.global_position
	var current_lead_angle = atan2(to_lead.x, to_lead.z)

	if last_lead_update_time > 0:
		var dt = current_time - last_lead_update_time
		if dt > 0.01:
			var angle_diff = current_lead_angle - last_lead_angle
			while angle_diff > PI:
				angle_diff -= TAU
			while angle_diff < -PI:
				angle_diff += TAU
			var new_rate = angle_diff / dt
			lead_angle_change_rate = lerp(lead_angle_change_rate, new_rate, LEAD_ANGLE_SMOOTHING)

	last_lead_angle = current_lead_angle
	last_lead_update_time = current_time

	var flight_time = interception_distance / torpedo_speed
	var predicted_angle_offset = lead_angle_change_rate * flight_time * 0.5

	var range_km = distance_to_target / 1000.0
	var spread_angle = SPREAD_ANGLE_BASE + SPREAD_ANGLE_PER_KM * range_km

	var spread_offsets = [-2, -1, 0, 1, 2]

	for offset in spread_offsets:
		var torpedo_angle = current_lead_angle + predicted_angle_offset + (offset * spread_angle)
		var torpedo_direction = Vector3(sin(torpedo_angle), 0, cos(torpedo_angle))
		var torpedo_aim_point = _ship.global_position + torpedo_direction * interception_distance
		torpedo_aim_point.y = 0

		if is_land_blocking_torpedo_path(_ship.global_position, torpedo_aim_point):
			continue
		if would_hit_friendly_ship(_ship.global_position, torpedo_aim_point, torpedo_speed):
			continue

		current_salvo_positions.append(torpedo_aim_point)

	if current_salvo_positions.size() > 0:
		has_valid_torpedo_solution = true
		var center_idx: int = int(float(current_salvo_positions.size()) / 2.0)
		var center_pos = current_salvo_positions[center_idx]
		torpedo_controller.set_aim_input(center_pos)

	var range_ratio = clamp(distance_to_target / RANGE_FOR_MAX_INTERVAL, 0.0, 1.0)
	torpedo_fire_interval = lerp(MIN_TORPEDO_INTERVAL, MAX_TORPEDO_INTERVAL, range_ratio)

func try_fire_torpedoes(_target_ship: Ship):
	"""Attempt to fire torpedoes at current solution."""
	if !has_valid_torpedo_solution:
		salvo_spread_index = 0
		return

	if current_salvo_positions.size() == 0:
		salvo_spread_index = 0
		return

	var torpedo_controller = _ship.torpedo_controller
	if !torpedo_controller:
		return

	var aim_index = salvo_spread_index % current_salvo_positions.size()
	var aim_position = current_salvo_positions[aim_index]

	torpedo_controller.set_aim_input(aim_position)

	for launcher in torpedo_controller.launchers:
		if launcher.reload >= 1.0 and launcher.can_fire and !launcher.disabled:
			torpedo_controller.fire_next_ready()
			salvo_spread_index += 1
			torpedoes_in_salvo += 1

			if salvo_spread_index >= current_salvo_positions.size():
				salvo_spread_index = 0
				torpedoes_in_salvo = 0
			return

func is_land_blocking_torpedo_path(from_pos: Vector3, to_pos: Vector3) -> bool:
	"""Check if land blocks the torpedo path."""
	var space_state = _ship.get_world_3d().direct_space_state
	var ray = PhysicsRayQueryParameters3D.new()
	ray.from = from_pos + (to_pos - from_pos).normalized() * 30.0
	ray.from.y = 1
	ray.to = to_pos
	ray.to.y = 1

	var collision = space_state.intersect_ray(ray)
	return !collision.is_empty()

func would_hit_friendly_ship(from_pos: Vector3, to_pos: Vector3, torpedo_speed: float) -> bool:
	"""Check if torpedo would hit a friendly ship."""
	if !_ship:
		return false

	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if !server_node:
		return false

	var torpedo_direction = (to_pos - from_pos).normalized()
	var torpedo_distance = from_pos.distance_to(to_pos)
	var time_to_target = torpedo_distance / torpedo_speed

	for other_ship in server_node.get_team_ships(_ship.team.team_id):
		if other_ship == _ship or !is_instance_valid(other_ship):
			continue
		if other_ship.team.team_id != _ship.team.team_id:
			continue
		if other_ship.health_controller.current_hp <= 0:
			continue

		var distance_to_ally = _ship.global_position.distance_to(other_ship.global_position)
		if distance_to_ally > friendly_fire_check_radius:
			continue

		var check_points = 10
		for i in range(check_points + 1):
			var t = float(i) / float(check_points) * time_to_target

			var torpedo_pos = from_pos + torpedo_direction * torpedo_speed * t
			torpedo_pos.y = 0

			var ally_pos = other_ship.global_position + other_ship.linear_velocity * t
			ally_pos.y = 0

			var distance_at_t = torpedo_pos.distance_to(ally_pos)

			if distance_at_t < friendly_fire_safety_margin:
				return true

	return false

func calculate_interception_point(shooter_pos: Vector3, target_pos: Vector3, target_vel: Vector3, projectile_speed: float) -> Vector3:
	"""Calculate interception point for a projectile to hit a moving target."""
	var to_target = target_pos - shooter_pos

	var a = target_vel.dot(target_vel) - projectile_speed * projectile_speed
	var b = 2.0 * to_target.dot(target_vel)
	var c = to_target.dot(to_target)

	if abs(a) < 0.0001:
		if abs(b) < 0.0001:
			return target_pos
		var t_linear = -c / b
		if t_linear > 0:
			return target_pos + target_vel * t_linear
		return target_pos

	var discriminant = b * b - 4.0 * a * c

	if discriminant < 0:
		return target_pos

	var sqrt_disc = sqrt(discriminant)
	var t1 = (-b - sqrt_disc) / (2.0 * a)
	var t2 = (-b + sqrt_disc) / (2.0 * a)

	var t = -1.0
	if t1 > 0 and t2 > 0:
		t = min(t1, t2)
	elif t1 > 0:
		t = t1
	elif t2 > 0:
		t = t2
	else:
		return target_pos

	return target_pos + target_vel * t

# ============================================================================
# DEFAULT POSITIONING (can be overridden)
# ============================================================================

func get_desired_position(_friendly: Array[Ship], enemy: Array[Ship], target: Ship, current_destination: Vector3) -> Vector3:
	"""Returns the desired position for the bot. Override for class-specific behavior."""
	var desired_pos = Vector3.ZERO
	if target != null:
		var dist = _ship.position.distance_to(target.position)
		if dist > 4000 or dist < 500:
			desired_pos = target.position
		else:
			var t = dist / _ship.movement_controller.max_speed
			desired_pos = target.position + target.linear_velocity * min(t * 0.2, 20.0)
	elif enemy.size() > 0:
		var closest_enemy = enemy[0]
		for enemy_ship in enemy:
			var enemy_dist = _ship.position.distance_to(enemy_ship.position)
			if enemy_dist < closest_enemy.position.distance_to(_ship.position):
				closest_enemy = enemy_ship
		desired_pos = closest_enemy.global_position
	else:
		desired_pos = current_destination
	return _get_valid_nav_point(desired_pos)

# ============================================================================
# COMBAT
# ============================================================================

func engage_target(target: Ship):
	"""Fire at target. Override for class-specific behavior."""
	if target.global_position.distance_to(_ship.global_position) > _ship.artillery_controller.get_params()._range:
		return

	var adjusted_target_pos = target.global_position + target_aim_offset(target)
	var target_lead = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(
		_ship.global_position,
		adjusted_target_pos,
		target.linear_velocity / ProjectileManager.shell_time_multiplier,
		_ship.artillery_controller.get_shell_params()
	)[2]

	if target_lead != null:
		_ship.artillery_controller.set_aim_input(target_lead)

	var ammo = pick_ammo(target)
	_ship.artillery_controller.select_shell(ammo)
	_ship.artillery_controller.fire_next_ready()

func _calculate_intercept_point(target: Ship) -> Vector3:
	"""Calculate optimal intercept point given our max speed and target's velocity."""
	var our_pos = _ship.global_position
	var target_pos = target.global_position
	var target_vel = target.linear_velocity

	var our_speed = _ship.movement_controller.max_speed if _ship.movement_controller else 15.0

	var to_target = target_pos - our_pos
	var distance = to_target.length()

	var target_speed = target_vel.length()
	if target_speed < 0.1:
		return target_pos

	var a = target_speed * target_speed - our_speed * our_speed
	var b = 2.0 * to_target.dot(target_vel)
	var c = distance * distance

	var intercept_time = 0.0

	if abs(a) < 0.0001:
		if abs(b) > 0.0001:
			intercept_time = -c / b
	else:
		var discriminant = b * b - 4.0 * a * c
		if discriminant < 0:
			return Vector3.ZERO

		var sqrt_disc = sqrt(discriminant)
		var t1 = (-b + sqrt_disc) / (2.0 * a)
		var t2 = (-b - sqrt_disc) / (2.0 * a)

		if t1 > 0 and t2 > 0:
			intercept_time = min(t1, t2)
		elif t1 > 0:
			intercept_time = t1
		elif t2 > 0:
			intercept_time = t2
		else:
			return Vector3.ZERO

	if intercept_time <= 0:
		return Vector3.ZERO

	var intercept_point = target_pos + target_vel * intercept_time
	intercept_point.y = target_pos.y

	return intercept_point

func get_desired_angle(_friendly: Array[Ship], _enemy: Array[Ship], target: Variant) -> float:
	"""Returns the desired angle for the bot."""
	if target is Vector3:
		return _ship.rotation.y - atan2(target.y - _ship.position.y, target.x - _ship.position.x)
	if target is Ship:
		return _ship.rotation.y - atan2(target.position.y - _ship.position.y, target.position.x - _ship.position.x)
	return 0.0

# ============================================================================
# UTILITIES
# ============================================================================

func _get_ship_heading() -> float:
	"""Get ship's current heading. 0 = +Z, PI/2 = +X, etc."""
	var forward = -_ship.global_transform.basis.z
	return atan2(forward.x, forward.z)

func _normalize_angle(angle: float) -> float:
	while angle > PI:
		angle -= TAU
	while angle < -PI:
		angle += TAU
	return angle

# ============================================================================
# CONSUMABLES
# ============================================================================

var repair = -1
var damage_control = -1

func try_use_consumable():
	var hp = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	if repair == -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
				repair = c.id
				break

	if damage_control == -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
				damage_control = c.id
				break

	if hp < 0.5:
		if repair != -1:
			_ship.consumable_manager.use_consumable(repair)

	var fires = _ship.fire_manager.get_active_fires()
	if fires > 0:
		if hp > 0.60 and fires >= 2:
			if damage_control != -1:
				_ship.consumable_manager.use_consumable(damage_control)
		elif fires >= 1:
			if damage_control != -1:
				_ship.consumable_manager.use_consumable(damage_control)

	var floods = _ship.flood_manager.get_active_floods()
	if floods > 0:
		if hp > 0.60 and floods >= 2:
			if damage_control != -1:
				_ship.consumable_manager.use_consumable(damage_control)
		elif floods >= 1:
			if damage_control != -1:
				_ship.consumable_manager.use_consumable(damage_control)
