extends BotBehavior
class_name CABehavior

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
	var weights = get_target_weights()
	var gun_range = _ship.artillery_controller.get_params()._range

	var best_target: Ship = null
	var best_priority: float = -1.0

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
		var hp_contrib = (1.5 - hp_ratio) * weights.hp_weight
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

		if priority > best_priority:
			best_target = ship
			best_priority = priority

	# Stick to last target if nearby and alive
	if best_target != null and last_target != null and last_target.is_alive():
		if last_target.position.distance_to(best_target.position) < 1000:
			return last_target

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
	"""Ship beam clearance for navigation."""
	if _ship and _ship.movement_controller:
		return _ship.movement_controller.ship_beam * 0.5 + 80.0
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
		var away = ship.global_position - cluster.center
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
	"""Find the nearest island by effective distance (center - radius).
	Returns {id, center: Vector3, radius: float} or empty dict."""
	if not NavigationMapManager.is_map_ready():
		return {}

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return {}

	var my_pos = ship.global_position
	var best_id: int = -1
	var best_eff_dist: float = INF
	var best_pos: Vector3 = Vector3.ZERO
	var best_radius: float = 0.0

	for isl in islands:
		var center_2d: Vector2 = isl["center"]
		var isl_pos = Vector3(center_2d.x, 0.0, center_2d.y)
		var isl_radius: float = isl["radius"]
		var eff_dist = isl_pos.distance_to(my_pos) - isl_radius
		if eff_dist < best_eff_dist:
			best_eff_dist = eff_dist
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

func _compute_island_destination(ship: Ship, island_center: Vector3, island_radius: float, safe_dir: Vector3) -> Vector3:
	"""Compute a position on the safe side of the island (facing spawn / away from enemies).
	Places the ship just outside the island on the safe-direction side."""
	var clearance = _get_ship_clearance()
	# Target distance from island center: radius + clearance + small buffer
	var stand_off = island_radius + clearance + 50.0

	# Position on the safe side
	var dest = island_center + safe_dir * stand_off
	dest.y = 0.0

	# Validate navigability — try the exact spot first, then nudge outward
	if NavigationMapManager.is_map_ready():
		if NavigationMapManager.is_navigable(dest, clearance):
			return _safe_validate(ship, dest)

		# Nudge outward in steps if the exact safe-side spot isn't navigable
		for extra in [30.0, 60.0, 100.0, 150.0, 200.0]:
			var test = island_center + safe_dir * (stand_off + extra)
			test.y = 0.0
			if NavigationMapManager.is_navigable(test, clearance):
				return _safe_validate(ship, test)

		# Try angling ±30° from safe direction
		var safe_angle = atan2(safe_dir.x, safe_dir.z)
		for angle_offset in [deg_to_rad(30), -deg_to_rad(30), deg_to_rad(60), -deg_to_rad(60)]:
			var test_angle = safe_angle + angle_offset
			var test_dir = Vector3(sin(test_angle), 0.0, cos(test_angle))
			var test = island_center + test_dir * stand_off
			test.y = 0.0
			if NavigationMapManager.is_navigable(test, clearance):
				return _safe_validate(ship, test)

	# Fallback: just validate the original position and hope for the best
	return _safe_validate(ship, dest)

# ============================================================================
# TANGENTIAL HEADING — align ship parallel to island shore
# ============================================================================

func _tangential_heading(ship: Ship, island_center: Vector3, from_pos: Vector3) -> float:
	"""Compute a heading tangential to the island from a fixed reference position.
	Uses from_pos (typically the nav destination) instead of the ship's current
	position so the radial direction is stable and doesn't flip-flop as the
	ship passes through the destination point.
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
# NAVINTENT — Primary entry point (V4 bot controller)
# ============================================================================

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	_ensure_safe_dir(ship, server)

	# Recompute safe direction if enemies are known (it may shift as the battle moves)
	var has_enemies = server.get_valid_targets(ship.team.team_id).size() > 0 \
		or not server.get_unspotted_enemies(ship.team.team_id).is_empty()
	if has_enemies:
		_cached_safe_dir = _compute_safe_direction(ship, server)

	# Find nearest island if we don't have one or need to refresh
	if not _nav_destination_valid:
		var island = _find_nearest_island(ship)
		if island.is_empty():
			return _intent_sail_forward(ship)

		_target_island_id = island["id"]
		_target_island_pos = island["center"]
		_target_island_radius = island["radius"]

		var dest = _compute_island_destination(ship, _target_island_pos, _target_island_radius, _cached_safe_dir)
		_nav_destination = dest
		_nav_destination_valid = true

		# Update debug state
		_cover_island_center = _target_island_pos
		_cover_island_radius = _target_island_radius
		_cover_zone_center = dest
		_cover_zone_valid = true
		_cover_zone_radius = _get_ship_clearance() * 2.0

	# Check if we've arrived
	var dist_to_dest = ship.global_position.distance_to(_nav_destination)
	var arrival_radius = _get_ship_clearance() * 2.0
	var arrived = dist_to_dest < arrival_radius

	# Compute tangential heading from the stable destination position
	var heading = _tangential_heading(ship, _target_island_pos, _nav_destination)

	# Update cover state for debug
	is_in_cover = arrived
	_cover_can_shoot = arrived

	if arrived:
		# Station-keep at our island position
		return NavIntent.station(_nav_destination, arrival_radius * 0.5, heading)

	# Approach the island — full speed when far, slow down near
	var intent = NavIntent.pose(_nav_destination, heading)
	if dist_to_dest > 500.0:
		intent.throttle_override = 4
	elif dist_to_dest > 200.0:
		intent.throttle_override = 3
	return intent

# ============================================================================
# FALLBACK — sail forward when no island available
# ============================================================================

func _intent_sail_forward(ship: Ship) -> NavIntent:
	"""Fallback: sail straight ahead."""
	var fwd = -ship.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.1:
		fwd = Vector3(0, 0, -1)
	var dest = ship.global_position + fwd.normalized() * 5000.0
	dest.y = 0.0
	dest = _get_valid_nav_point(dest)
	return NavIntent.pose(dest, atan2(fwd.x, fwd.z))
