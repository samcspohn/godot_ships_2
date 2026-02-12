extends Node
class_name BotBehavior
# interface for bot behavior. (to AI, this is gdscript. also stop duplicating lines with autocomplte)

var _ship: Ship = null
var nav: NavigationAgent3D

# Evasion state variables
var evasion_timer: float = 0.0
var evasion_direction: int = 1  # 1 or -1, which side we're currently angling
var last_target_bearing: float = 0.0  # Track target to keep guns on it

# func _ready():
# 	_ship = get_parent()
# 	nav = _ship.navigation_agent

func _get_valid_nav_point(target: Vector3) -> Vector3:
	var nav_map = nav.get_navigation_map()
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, target)
	return closest_point

func pick_target(targets: Array[Ship], last_target: Ship) -> Ship:
	"""Takes an array of valid targets"""
	var target = null
	var closest_dist = INF
	var gun_params = _ship.artillery_controller.params.p() as GunParams
	var _range = gun_params._range
	for ship in targets:
		var dist = _ship.position.distance_to(ship.position)
		if dist <= _range \
	 	and _ship.artillery_controller.guns[0].sim_can_shoot_over_terrain(ship.global_position) \
		and dist < closest_dist:
			target = ship
			closest_dist = dist
	if target != null:
		if last_target != null and last_target.is_alive():
			if last_target.position.distance_to(target.position) < 1000:
				return last_target
		return target
	else:
		return null

func pick_ammo(target: Ship) -> int:
	var ammo = ShellParams.ShellType.AP
	if target.ship_class == Ship.ShipClass.DD:
		ammo = ShellParams.ShellType.HE
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	"""Retrurns the offset to the target to aim at in local space"""
	return Vector3.ZERO

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

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion. Override in DD for speed variation."""
	return 1.0

func should_evade(destination: Vector3) -> bool:
	"""Determine if ship should be evading vs traveling to destination.
	Override in subclasses for class-specific behavior."""
	# Only evade when detected
	if not _ship.visible_to_enemy:
		return false

	# Check if we're close to destination (near desired engagement position)
	var dist_to_dest = _ship.global_position.distance_to(destination)
	var movement = _ship.get_node_or_null("Modules/MovementController") as ShipMovementV4
	if movement == null:
		return true

	# Evade if within 2x turning circle of destination (effectively "arrived")
	# Or if destination is very close (parked)
	var arrival_threshold = movement.turning_circle_radius * 2.0
	return dist_to_dest < arrival_threshold

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Returns desired heading for angling/evasion.
	Returns {heading: float, use_evasion: bool}
	If use_evasion is false, bot controller uses normal waypoint navigation."""

	# Check if we should be evading
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

	# Update evasion timer
	evasion_timer += delta

	# Sine wave for smooth oscillation between min and max angle
	var wave = (sin(evasion_timer * TAU / period) + 1.0) / 2.0  # 0 to 1
	var current_angle = lerp(min_angle, max_angle, wave)

	# Determine evasion direction based on target bearing (keep guns on target)
	if target != null:
		var to_target = target.global_position - _ship.global_position
		var target_bearing = atan2(to_target.x, to_target.z)

		# When wave is decreasing (angling back), pick direction toward target
		var wave_derivative = cos(evasion_timer * TAU / period)  # positive = increasing, negative = decreasing

		if wave_derivative < 0:
			# Angling back - choose direction that brings guns toward target
			var current_ship_heading = _get_ship_heading()
			var angle_to_target = _normalize_angle(target_bearing - current_ship_heading)

			# If target is to our right, angle right (direction = 1)
			# If target is to our left, angle left (direction = -1)
			evasion_direction = 1 if angle_to_target > 0 else -1

		last_target_bearing = target_bearing

	# Calculate final heading: threat bearing + angle offset in evasion direction
	var evasion_heading = _normalize_angle(threat_bearing + current_angle * evasion_direction)

	return evasion_heading

func _get_weighted_threat_bearing() -> Variant:
	"""Returns bearing to weighted average of enemy clusters. null if no threats."""
	var danger_center = _get_danger_center()
	if danger_center == Vector3.ZERO:
		return null
	var to_danger = danger_center - _ship.global_position
	return atan2(to_danger.x, to_danger.z)


func _get_danger_center() -> Vector3:
	"""Calculate threat-weighted center of known enemies.
	Closer enemies and larger clusters have more weight."""
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

		# Inverse square distance weighting - closer clusters are MUCH more threatening
		var base_weight = 1.0 / (dist * dist / 10000.0 + 1.0)

		# Add weight for each ship in cluster based on class threat
		var cluster_threat = 0.0
		for ship in cluster.ships:
			if ship != null and is_instance_valid(ship):
				cluster_threat += get_threat_class_weight(ship.ship_class)
			else:
				cluster_threat += 1.0  # Unknown/last known position

		var weight = base_weight * max(cluster_threat, 1.0)
		weighted_pos += cluster_pos * weight
		total_weight += weight

	if total_weight < 0.001:
		return Vector3.ZERO

	return weighted_pos / total_weight


func _get_nearest_enemy() -> Dictionary:
	"""Find the nearest known enemy (spotted or last known position).
	Returns {position: Vector3, distance: float, ship: Ship or null} or empty dict."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return {}

	var nearest_pos = Vector3.ZERO
	var nearest_dist = INF
	var nearest_ship: Ship = null

	# Check spotted enemies
	var valid_targets = server_node.get_valid_targets(_ship.team.team_id)
	for ship in valid_targets:
		var dist = _ship.global_position.distance_to(ship.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_pos = ship.global_position
			nearest_ship = ship

	# Check last known positions of unspotted enemies
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
	"""Determine which direction to flank (1 = right/clockwise, -1 = left/counter-clockwise).
	Prefers flanking away from friendlies to spread out."""
	if danger_center == Vector3.ZERO:
		return 1

	var to_danger = danger_center - _ship.global_position
	to_danger.y = 0.0
	var danger_bearing = atan2(to_danger.x, to_danger.z)

	# Calculate perpendicular directions
	var right_angle = _normalize_angle(danger_bearing + PI / 2.0)
	var left_angle = _normalize_angle(danger_bearing - PI / 2.0)

	# If we have friendly positions, flank away from them to spread out
	if friendly_avg != Vector3.ZERO:
		var to_friendly = friendly_avg - _ship.global_position
		to_friendly.y = 0.0
		var friendly_bearing = atan2(to_friendly.x, to_friendly.z)

		var right_diff = abs(_normalize_angle(right_angle - friendly_bearing))
		var left_diff = abs(_normalize_angle(left_angle - friendly_bearing))

		# Go the direction that's more away from friendlies
		return 1 if right_diff > left_diff else -1

	# Default to random-ish based on current position
	var current_heading = _get_ship_heading()
	var angle_to_danger = _normalize_angle(danger_bearing - current_heading)
	return 1 if angle_to_danger > 0 else -1


func _calculate_tactical_position(desired_range: float, min_safe_distance: float, flank_bias: float = 0.0) -> Vector3:
	"""Calculate position based on tactical situation.
	- desired_range: ideal distance from danger center
	- min_safe_distance: minimum distance from nearest enemy
	- flank_bias: 0.0 = direct engagement, 1.0 = full flanking"""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return _ship.global_position

	var danger_center = _get_danger_center()
	if danger_center == Vector3.ZERO:
		return _ship.global_position  # No known enemies

	var friendly_avg = server_node.get_team_avg_position(_ship.team.team_id)
	var nearest = _get_nearest_enemy()

	# Current position relative to danger center
	var to_me = _ship.global_position - danger_center
	to_me.y = 0.0
	var current_dist = to_me.length()
	var current_angle = atan2(to_me.x, to_me.z)

	# Determine if we need to retreat from nearest enemy
	var retreat_factor = 0.0
	if not nearest.is_empty():
		var nearest_dist: float = nearest.distance
		if nearest_dist < min_safe_distance:
			# Too close to nearest enemy - need to retreat
			retreat_factor = 1.0 - (nearest_dist / min_safe_distance)
			retreat_factor = clamp(retreat_factor, 0.0, 1.0)

	# Calculate target distance from danger center
	var target_dist = desired_range
	if retreat_factor > 0:
		# Increase distance when nearest enemy is too close
		target_dist = lerp(desired_range, desired_range * 1.5, retreat_factor)

	# Calculate flanking angle adjustment
	var flank_direction = _get_flanking_direction(danger_center, friendly_avg)
	var flank_angle = flank_bias * (PI / 4.0) * flank_direction  # Up to 45 degrees

	# Apply flanking to current angle
	var target_angle = current_angle + flank_angle * 0.1  # Gradual flanking

	# If retreating, bias angle away from nearest enemy
	if retreat_factor > 0 and not nearest.is_empty():
		var nearest_pos: Vector3 = nearest.position
		var to_nearest = nearest_pos - _ship.global_position
		to_nearest.y = 0.0
		var nearest_bearing = atan2(to_nearest.x, to_nearest.z)
		var away_bearing = _normalize_angle(nearest_bearing + PI)

		# Blend retreat direction into target angle
		var retreat_angle = atan2(sin(away_bearing), cos(away_bearing))
		# Convert retreat bearing to angle around danger center
		var retreat_pos = _ship.global_position + Vector3(sin(away_bearing), 0, cos(away_bearing)) * 1000.0
		var retreat_to_danger = retreat_pos - danger_center
		var retreat_arc_angle = atan2(retreat_to_danger.x, retreat_to_danger.z)

		target_angle = lerp_angle(target_angle, retreat_arc_angle, retreat_factor * 0.5)

	# Calculate final position
	var target_pos = danger_center + Vector3(sin(target_angle), 0, cos(target_angle)) * target_dist

	# Bias toward friendlies to avoid overextension
	if friendly_avg != Vector3.ZERO:
		var to_friendly = friendly_avg - target_pos
		to_friendly.y = 0.0
		var friendly_dist = to_friendly.length()
		var max_extend_dist = 5000.0  # Don't extend more than 5km from team

		if friendly_dist > max_extend_dist:
			var pull_back = (friendly_dist - max_extend_dist) / friendly_dist
			target_pos = target_pos + to_friendly * pull_back * 0.5

	target_pos.y = 0.0
	return target_pos

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

func get_desired_position(friendly: Array[Ship], enemy: Array[Ship], target: Ship, current_destination: Vector3) -> Vector3:
	"""Returns the desired position for the bot"""
	var desired_pos = Vector3.ZERO
	if target != null:
		# # Calculate intersection point using optimal intercept angle
		# var intercept_point = _calculate_intercept_point(target)
		# if intercept_point != Vector3.ZERO:
		# 	desired_pos = intercept_point * 0.3 + target.global_position * 0.7
		# else:
		# 	desired_pos = target.global_position
		var dist = _ship.position.distance_to(target.position)
		if dist > 4000 or dist < 500:
			desired_pos = target.position
		else:
			var t = dist / _ship.movement_controller.max_speed
			desired_pos = target.position + target.linear_velocity * min(t * 0.2, 20.0)

	elif enemy.size() > 0:
		var closest_enemy = enemy[0]
		for enemy_ship in enemy:
			var dist = _ship.position.distance_to(enemy_ship.position)
			if dist < closest_enemy.position.distance_to(_ship.position):
				closest_enemy = enemy_ship
		desired_pos = closest_enemy.global_position
		# desired_pos = _calculate_intercept_point(closest_enemy)
	else:
		desired_pos = current_destination
	return _get_valid_nav_point(desired_pos)

func engage_target(target: Ship):
	# if target != null and target.visible_to_enemy and target.is_alive():
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
	# else:
		# target_lead = null
		# _ship.artillery_controller.set_aim_input(destination)

func _calculate_intercept_point(target: Ship) -> Vector3:
	"""Calculate optimal intercept point given our max speed and target's velocity"""
	var our_pos = _ship.global_position
	var target_pos = target.global_position
	var target_vel = target.linear_velocity

	# Get our max speed from movement controller
	var our_speed = _ship.movement_controller.max_speed if _ship.movement_controller else 15.0

	# Vector from us to target
	var to_target = target_pos - our_pos
	var distance = to_target.length()

	# If target is stationary or very slow, just go directly to them
	var target_speed = target_vel.length()
	if target_speed < 0.1:
		return target_pos

	# Solve quadratic equation for intercept time
	# |target_pos + target_vel * t - our_pos|² = (our_speed * t)²
	# This expands to: (target_speed² - our_speed²) * t² + 2 * (to_target · target_vel) * t + distance² = 0

	var a = target_speed * target_speed - our_speed * our_speed
	var b = 2.0 * to_target.dot(target_vel)
	var c = distance * distance

	var intercept_time = 0.0

	if abs(a) < 0.0001:
		# Linear case: speeds are approximately equal
		if abs(b) > 0.0001:
			intercept_time = -c / b
	else:
		# Quadratic case
		var discriminant = b * b - 4.0 * a * c
		if discriminant < 0:
			# No intercept possible, target is faster and moving away
			return Vector3.ZERO

		var sqrt_disc = sqrt(discriminant)
		var t1 = (-b + sqrt_disc) / (2.0 * a)
		var t2 = (-b - sqrt_disc) / (2.0 * a)

		# Choose the smallest positive time
		if t1 > 0 and t2 > 0:
			intercept_time = min(t1, t2)
		elif t1 > 0:
			intercept_time = t1
		elif t2 > 0:
			intercept_time = t2
		else:
			# No positive solution, target is behind us or unreachable
			return Vector3.ZERO

	if intercept_time <= 0:
		return Vector3.ZERO

	# Calculate the intercept point
	var intercept_point = target_pos + target_vel * intercept_time

	# Keep Y coordinate at water level (same as target)
	intercept_point.y = target_pos.y

	return intercept_point

func get_desired_angle(friendly: Array[Ship], enemy: Array[Ship], target: Variant) -> float:
	"""Returns the desired angle for the bot"""
	if target is Vector3:
		return _ship.rotation.y - atan2(target.y - _ship.position.y, target.x - _ship.position.x)
	if target is Ship:
		return _ship.rotation.y - atan2(target.position.y - _ship.position.y, target.position.x - _ship.position.x)
	return 0.0

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
