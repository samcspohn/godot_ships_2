extends BotBehavior
class_name BBBehavior

var ammo = ShellParams.ShellType.AP

# Arc movement state
var current_arc_direction: int = 0  # 1 = clockwise, -1 = counter-clockwise, 0 = uninitialized
var arc_direction_timer: float = 0.0
var arc_direction_initialized: bool = false
const ARC_DIRECTION_CHANGE_TIME: float = 30.0  # How often to consider changing arc direction
const ARC_MOVEMENT_SPEED: float = 0.15  # Radians per position update to move along arc
const MIN_SAFE_ANGLE_FROM_THREAT: float = PI / 3.0  # 60 degrees - don't get closer than this to threat direction

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(25),
		max_angle = deg_to_rad(35),
		evasion_period = 7.0,  # Slow, deliberate weaves
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 2.0   # Other BBs are primary threat
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 0.3   # DDs less relevant for angling
	return 1.0

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	var target = null
	var best_priority = -1
	var gun_range = _ship.artillery_controller.get_params()._range

	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
		# pick apparently biggest target + most broadside
		var priority = ship.movement_controller.ship_length / dist * abs(sin(angle)) + ship.movement_controller.ship_beam / dist * abs(cos(angle))
		# priority *= 1.7 - hp_ratio
		priority = priority * 0.3 + (1 - dist / gun_range) * 0.5 + (1.5 - hp_ratio) * 0.2

		# Significantly boost priority for targets within gun range
		if dist <= gun_range:
			priority *= 10.0  # Strong preference for targets we can actually shoot

		if priority > best_priority:
			target = ship
			best_priority = priority
	return target

func pick_ammo(_target: Ship) -> int:
	# Ammo is set as side effect in target_aim_offset
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _target.global_position - _ship.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var offset = Vector3(0, 0, 0)
	angle = abs(angle)
	if angle > PI / 2.0:
		angle = PI - angle

	# Default to AP
	ammo = ShellParams.ShellType.AP

	match _target.ship_class:
		Ship.ShipClass.BB:
			if angle < deg_to_rad(10):
				# HE against heavily angled battleships (< 10 degrees from bow/stern)
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2.0  # superstructure
			elif angle < deg_to_rad(30):
				# AP at battleship superstructure when angled (but not heavily angled)
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 2.0  # superstructure
			else:
				ammo = ShellParams.ShellType.AP
				offset.y = 0.1
		Ship.ShipClass.CA:
			if angle < deg_to_rad(30):
				# AP at angled cruiser bow/stern when angled 30 degrees
				ammo = ShellParams.ShellType.AP
				offset.z -= _target.movement_controller.ship_length / 2.0 * 0.75  # bow/stern
			else:
				# AP at broadside cruisers waterline
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0  # waterline
		Ship.ShipClass.DD:
			# HE at destroyers
			ammo = ShellParams.ShellType.HE
			offset.y = 1.0
	return offset

func get_desired_position(friendly: Array[Ship], _enemy: Array[Ship], _target: Ship, current_destination: Vector3) -> Vector3:
	# Get cached data from server
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")

	# Check if we have any known enemies
	var danger_center = _get_danger_center()
	if danger_center == Vector3.ZERO:
		# No known enemies - use hunting behavior
		return _get_hunting_position(server_node, friendly, current_destination)

	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	# Calculate desired engagement range based on HP
	# BBs want to fight at 60-80% of max range
	var base_range_ratio = 0.70  # 70% of gun range
	# Increase range when damaged
	var range_increase = clamp((1.0 - hp_ratio) * 0.2, 0.0, 0.15)  # Up to +15% range when low HP
	var engagement_range = (base_range_ratio + range_increase) * gun_range

	# Minimum safe distance from nearest enemy (don't let anyone get too close)
	# BBs need distance to use their guns effectively
	var min_safe_distance = gun_range * 0.35  # Don't let enemies within 35% range

	# Calculate flanking bias based on situation
	# BBs should flank moderately when healthy, less when damaged
	var flank_bias = lerp(0.4, 0.1, 1.0 - hp_ratio)

	# Get tactical position based on danger center, not single target
	var desired_position = _calculate_tactical_position(engagement_range, min_safe_distance, flank_bias)

	# Apply arc movement for continuous maneuvering
	desired_position = _apply_arc_movement(desired_position, danger_center, engagement_range, server_node)

	# Calculate spread offset to avoid clumping with teammates
	var spread_offset = Vector3.ZERO
	var min_spread_distance = 500.0
	for ship in friendly:
		if ship == _ship:
			continue
		var to_teammate = _ship.global_position - ship.global_position
		var dist_to_teammate = to_teammate.length()
		if dist_to_teammate < min_spread_distance * 3.0 and dist_to_teammate > 0.1:
			var push_strength = 1.0 - (dist_to_teammate / (min_spread_distance * 3.0))
			spread_offset += to_teammate.normalized() * push_strength * min_spread_distance

	desired_position += spread_offset

	return _get_valid_nav_point(desired_position)


func _apply_arc_movement(base_position: Vector3, danger_center: Vector3, engagement_range: float, server_node: GameServer) -> Vector3:
	"""Apply continuous arc movement around danger center to avoid parking."""
	var my_pos = _ship.global_position

	# Current angle on circle around danger center
	var to_me = my_pos - danger_center
	to_me.y = 0.0
	var current_angle = atan2(to_me.x, to_me.z)

	# Calculate threat angle (direction toward danger center from our perspective is the threat)
	var threat_angle = _normalize_angle(current_angle + PI)

	# Calculate friendly angle for reference
	var friendly_angle = current_angle
	if server_node:
		var friendly_avg = server_node.get_team_avg_position(_ship.team.team_id)
		if friendly_avg != Vector3.ZERO:
			var to_friendly = friendly_avg - danger_center
			to_friendly.y = 0.0
			friendly_angle = atan2(to_friendly.x, to_friendly.z)

	# Safe angle is away from danger center (same as current angle direction)
	var safe_angle = current_angle

	# Initialize arc direction on first call
	if not arc_direction_initialized:
		arc_direction_initialized = true
		var angle_to_friendly = _normalize_angle(friendly_angle - current_angle)
		# Flank away from friendlies to spread out
		current_arc_direction = -1 if angle_to_friendly > 0 else 1

	# Update arc direction periodically
	arc_direction_timer += 1.0 / Engine.physics_ticks_per_second
	if arc_direction_timer >= ARC_DIRECTION_CHANGE_TIME:
		arc_direction_timer = 0.0
		var angle_to_friendly = _normalize_angle(friendly_angle - current_angle)
		# Continue flanking away from friendlies, but allow some randomness
		var preferred_direction = -sign(angle_to_friendly) if abs(angle_to_friendly) > 0.1 else current_arc_direction
		current_arc_direction = 1 if preferred_direction > 0 else -1

	# Apply arc movement
	var arc_movement = ARC_MOVEMENT_SPEED * current_arc_direction
	var new_angle = current_angle + arc_movement

	# Calculate new position on arc
	var arc_position = danger_center + Vector3(sin(new_angle), 0, cos(new_angle)) * engagement_range
	arc_position.y = 0.0

	# Blend between tactical position and arc position
	# This keeps movement smooth while respecting tactical constraints
	var blend_factor = 0.3  # 30% arc influence
	var final_position = base_position * (1.0 - blend_factor) + arc_position * blend_factor

	return final_position


func _get_hunting_position(server_node: GameServer, friendly: Array[Ship], current_destination: Vector3) -> Vector3:
	"""When no enemies are visible, move toward last known positions of unspotted enemies."""
	if server_node == null:
		return current_destination

	var unspotted_enemies = server_node.get_unspotted_enemies(_ship.team.team_id)
	if unspotted_enemies.is_empty():
		# No unspotted enemies tracked, move toward average enemy position
		var avg_enemy = server_node.get_enemy_avg_position(_ship.team.team_id)
		if avg_enemy != Vector3.ZERO:
			var gun_range = _ship.artillery_controller.get_params()._range
			var to_enemy = (avg_enemy - _ship.global_position).normalized()
			var desired_pos = _ship.global_position + to_enemy * gun_range * 0.4
			return _get_valid_nav_point(desired_pos)
		return current_destination

	# Find the closest unspotted enemy's last known position
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

	# Battleships move more aggressively toward last known positions
	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	# Move toward the last known position
	var to_target = (closest_pos - _ship.global_position).normalized()

	# Adjust approach based on HP - lower HP = more cautious
	var approach_distance = gun_range * lerp(0.5, 0.3, 1.0 - hp_ratio)
	var desired_pos = _ship.global_position + to_target * approach_distance

	# Calculate spread offset to avoid clumping with teammates
	var spread_offset = Vector3.ZERO
	var min_spread_distance = 500.0
	for ship in friendly:
		if ship == _ship:
			continue
		var to_teammate = _ship.global_position - ship.global_position
		var dist_to_teammate = to_teammate.length()
		if dist_to_teammate < min_spread_distance * 3.0 and dist_to_teammate > 0.1:
			var push_strength = 1.0 - (dist_to_teammate / (min_spread_distance * 3.0))
			spread_offset += to_teammate.normalized() * push_strength * min_spread_distance

	desired_pos += spread_offset

	# If low HP, bias toward friendly cluster while hunting
	if hp_ratio < 0.5:
		var nearest_cluster = server_node.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
		if not nearest_cluster.is_empty():
			var cluster_center: Vector3 = nearest_cluster.center
			var to_cluster = (cluster_center - _ship.global_position).normalized()
			# Blend hunting direction with cluster direction
			desired_pos = _ship.global_position + (to_target * 0.6 + to_cluster * 0.4).normalized() * approach_distance

	return _get_valid_nav_point(desired_pos)
