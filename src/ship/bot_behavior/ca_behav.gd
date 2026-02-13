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
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.55,
		range_increase_when_damaged = 0.20,
		min_safe_distance_ratio = 0.40,  # CAs are fragile, need more space
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 500.0,
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

	# If we have a valid island destination, don't evade - prioritize reaching cover
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

	var danger_center = _get_danger_center()
	if danger_center == Vector3.ZERO:
		return _get_hunting_position(server_node, friendly, current_destination)

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
# FALLBACK POSITIONING (kept for compatibility)
# ============================================================================

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
