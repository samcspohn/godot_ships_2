extends BotBehavior
class_name DDBehavior

var ammo = ShellParams.ShellType.HE

# Speed variation for evasion
var speed_variation_timer: float = 0.0
var current_speed_multiplier: float = 1.0
const SPEED_VARIATION_PERIOD: float = 3.0  # How often to change speed
const SPEED_VARIATION_MIN: float = 0.6  # Minimum speed multiplier
const SPEED_VARIATION_MAX: float = 1.0  # Maximum speed multiplier

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(10),
		max_angle = deg_to_rad(25),
		evasion_period = 2.5,  # Quick, erratic weaving
		vary_speed = true      # Only DDs vary speed
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.5   # CAs are DD hunters
		Ship.ShipClass.DD: return 1.0
	return 1.0

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Override to add speed variation for DDs."""
	var result = super.get_desired_heading(target, current_heading, delta, destination)

	# Update speed variation when evading
	if result.use_evasion:
		speed_variation_timer += delta
		# Use a different frequency than heading to make movement less predictable
		var speed_wave = (sin(speed_variation_timer * TAU / SPEED_VARIATION_PERIOD) + 1.0) / 2.0
		current_speed_multiplier = lerp(SPEED_VARIATION_MIN, SPEED_VARIATION_MAX, speed_wave)
	else:
		current_speed_multiplier = 1.0

	return result

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion. Bot controller should use this."""
	return current_speed_multiplier

# Track torpedo hits and floods for shooting decision
var last_torpedo_count: int = 0
var last_flood_count: int = 0
var target_is_flooding: bool = false

# Torpedo lead tracking for predictive spread
var last_lead_angle: float = 0.0
var lead_angle_change_rate: float = 0.0  # Radians per second
var last_lead_update_time: float = 0.0
const LEAD_ANGLE_SMOOTHING: float = 0.3  # Smoothing factor for angle change rate

# Torpedo spread parameters
const SPREAD_ANGLE_BASE: float = 0.05  # Base spread angle in radians (~3 degrees)
const SPREAD_ANGLE_PER_KM: float = 0.01  # Additional spread per km of range
const MIN_TORPEDO_INTERVAL: float = 0.5  # Minimum time between torpedo launches
const MAX_TORPEDO_INTERVAL: float = 15.0  # Maximum time between torpedo launches
const RANGE_FOR_MAX_INTERVAL: float = 10000.0  # Range at which we use max interval

# Track torpedo salvo state
var torpedoes_in_salvo: int = 0
var salvo_spread_index: int = 0  # Which spread position we're on (-2, -1, 0, 1, 2)
var current_salvo_positions: Array[Vector3] = []  # Pre-calculated spread positions

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	var target = null
	var highest_priority = -1
	var gun_range = _ship.artillery_controller.get_params()._range
	var torpedo_range = -1
	if _ship.torpedo_controller != null:
		torpedo_range = _ship.torpedo_controller.get_params()._range
	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		angle -= PI / 4 # best angle to torpedo is 45 degrees incoming
		var priority = 0
		if !_ship.visible_to_enemy:
			priority = cos(angle) * ship.movement_controller.ship_length / dist
			priority = priority * 0.3 + (1 - dist / torpedo_range) * 0.7
			if ship.ship_class == Ship.ShipClass.BB:
				priority *= 3.0
		else:
			priority = (1 - dist / gun_range)

		# Significantly boost priority for targets within gun range
		if dist <= gun_range or dist <= torpedo_range:
			priority *= 10.0  # Strong preference for targets we can actually shoot

		if priority > highest_priority:
			target = ship
			highest_priority = priority
	return target

func pick_ammo(_target: Ship) -> int:
	# Ammo is set as side effect in target_aim_offset
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var dist = disp.length()
	var offset = Vector3.ZERO

	# Default to HE
	ammo = ShellParams.ShellType.HE

	match _target.ship_class:
		Ship.ShipClass.BB:
			# HE at battleship superstructure
			ammo = ShellParams.ShellType.HE
			offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			# Check if broadside (sin > 70 degrees means broadside)
			if abs(sin(angle)) > sin(deg_to_rad(70)):
				if dist < 500:
					# AP at broadside cruisers waterline < 500
					ammo = ShellParams.ShellType.AP
					offset.y = 0.0  # Waterline
				elif dist < 1000:
					# AP at broadside cruisers when < 1000
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5  # Slightly above waterline
				else:
					# HE at cruiser superstructure when angled or far
					ammo = ShellParams.ShellType.HE
					offset.y = _target.movement_controller.ship_height / 2
			else:
				# HE at cruiser superstructure when angled
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.DD:
			# Check if broadside for AP at waterline
			if abs(sin(angle)) > sin(deg_to_rad(70)) and dist < 1000:
				# AP at broadside destroyers at waterline when < 1000
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0  # Waterline
			else:
				# HE at destroyers
				ammo = ShellParams.ShellType.HE
				offset.y = 1.0
	return offset

var closest_enemy: Ship
func get_desired_position(friendly: Array[Ship], enemy: Array[Ship], target: Ship, current_destination: Vector3) -> Vector3:
	# Get server reference early
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if _ship.name == "1003":
		pass

	# If no target, try to hunt unspotted enemies
	if target == null:
		return _get_hunting_position(server_node, friendly, current_destination)

	var concealment_radius = (_ship.concealment.params.p() as ConcealmentParams).radius
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	# Calculate separation from friendly ships to avoid clumping
	var separation = Vector3.ZERO
	var min_separation_dist = 1500.0  # Minimum distance to maintain from teammates
	for ship in friendly:
		if ship == _ship:
			continue
		var to_self = _ship.global_position - ship.global_position
		var dist = to_self.length()
		if dist < min_separation_dist and dist > 0.1:
			# Push away from nearby teammates
			separation += to_self.normalized() * (min_separation_dist - dist) / min_separation_dist

	if _ship.visible_to_enemy: # move away from enemy
		closest_enemy = enemy[0]
		var closest_enemy_dist = (closest_enemy.global_position - _ship.global_position).length()
		for ship in enemy:
			var dist = (ship.global_position - _ship.global_position).length()
			if dist < closest_enemy_dist:
				closest_enemy = ship
				closest_enemy_dist = dist

		# Retreat away from enemy
		var retreat_dir = (_ship.global_position - closest_enemy.global_position).normalized()
		var desired_position = _ship.global_position + retreat_dir * concealment_radius * 2.0

		# Only bias toward team if below 50% HP
		if hp_ratio < 0.5:
			var nearest_friendly_pos = Vector3.ZERO
			if server_node:
				var nearest_cluster = server_node.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
				if nearest_cluster.size() > 0:
					nearest_friendly_pos = nearest_cluster.center
				else:
					nearest_friendly_pos = server_node.get_team_avg_position(_ship.team.team_id)
			else:
				for ship in friendly:
					nearest_friendly_pos += ship.global_position
				nearest_friendly_pos /= friendly.size()
			# Slight bias toward nearest friendly cluster, but primarily retreat away from enemy
			desired_position = desired_position * 0.8 + nearest_friendly_pos * 0.2

		# Apply separation to avoid clumping
		desired_position += separation * 500.0
		return _get_valid_nav_point(desired_position)
	else:
		var right = target.transform.basis.x * concealment_radius * 1.5
		var right_of = target.global_position + right
		var left_of = target.global_position - right
		var desired_position = Vector3.ZERO
		right_of = _get_valid_nav_point(right_of)
		left_of = _get_valid_nav_point(left_of)
		if right_of.distance_to(_ship.global_position) < left_of.distance_to(_ship.global_position):
			desired_position = right_of
		else:
			desired_position = left_of

		# Apply separation to avoid clumping
		desired_position += separation * 500.0
		return _get_valid_nav_point(desired_position)


func _get_hunting_position(server_node: GameServer, friendly: Array[Ship], current_destination: Vector3) -> Vector3:
	"""When no enemies are visible, move toward last known positions of unspotted enemies.
	DDs are excellent hunters - they should aggressively seek out unspotted enemies."""
	if server_node == null:
		return current_destination

	var unspotted_enemies = server_node.get_unspotted_enemies(_ship.team.team_id)
	var concealment_radius = (_ship.concealment.params.p() as ConcealmentParams).radius
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	if unspotted_enemies.is_empty():
		# No unspotted enemies tracked, move toward average enemy position to spot
		var avg_enemy = server_node.get_enemy_avg_position(_ship.team.team_id)
		if avg_enemy != Vector3.ZERO:
			var to_enemy = (avg_enemy - _ship.global_position).normalized()
			# DDs should push forward aggressively to spot enemies
			var desired_pos = _ship.global_position + to_enemy * concealment_radius * 1.5
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

	# DDs should aggressively hunt toward last known positions
	var to_target = (closest_pos - _ship.global_position).normalized()

	# Adjust approach based on HP
	var approach_speed: float
	if hp_ratio < 0.3:
		# Very low HP - be cautious, bias toward friendlies
		approach_speed = 0.3
		var nearest_cluster = server_node.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
		if not nearest_cluster.is_empty():
			var cluster_center: Vector3 = nearest_cluster.center
			var to_cluster = (cluster_center - _ship.global_position).normalized()
			to_target = (to_target * 0.4 + to_cluster * 0.6).normalized()
	elif hp_ratio < 0.5:
		approach_speed = 0.5
	else:
		# Healthy DD - hunt aggressively
		approach_speed = 0.8

	var desired_pos = _ship.global_position + to_target * concealment_radius * approach_speed * 2.0

	# Calculate separation from friendly ships to avoid clumping
	var separation = Vector3.ZERO
	var min_separation_dist = 1500.0
	for ship in friendly:
		if ship == _ship:
			continue
		var to_self = _ship.global_position - ship.global_position
		var dist = to_self.length()
		if dist < min_separation_dist and dist > 0.1:
			separation += to_self.normalized() * (min_separation_dist - dist) / min_separation_dist

	desired_pos += separation * 500.0
	return _get_valid_nav_point(desired_pos)


# Torpedo parameters
var torpedo_fire_interval: float = 3.0  # How often to attempt firing (dynamic based on range)
var torpedo_fire_timer: float = 0.0
var torpedo_land_check_segments: int = 10  # Number of points to check along torpedo path
var torpedo_target_position: Vector3 = Vector3.ZERO  # Calculated interception point
var has_valid_torpedo_solution: bool = false
var friendly_fire_check_radius: float = 5000.0  # Check allies within this distance
var friendly_fire_safety_margin: float = 500.0  # How close torpedo path can be to ally
var current_torpedo_range: float = 0.0  # Cache current range for interval calculation


func engage_target(target: Ship):
	# Check if our torpedoes have landed and caused flooding
	var current_torpedo_count = _ship.stats.torpedo_count
	var current_flood_count = _ship.stats.flood_count

	# Detect new torpedo hit
	if current_torpedo_count > last_torpedo_count:
		last_torpedo_count = current_torpedo_count

	# Detect new flood caused by our torpedoes
	if current_flood_count > last_flood_count:
		last_flood_count = current_flood_count
		target_is_flooding = true

	# Determine if we should shoot guns
	var should_shoot_guns = false
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	# Don't shoot if low health - prioritize stealth and survival
	if hp_ratio < 0.3:
		should_shoot_guns = false
	elif _ship.visible_to_enemy and closest_enemy and closest_enemy.global_position.distance_to(_ship.global_position) < (_ship.concealment.params.p() as ConcealmentParams).radius:
		# Shoot when spotted and within detection range (and not low health)
		should_shoot_guns = true
	elif target_is_flooding:
		# Shoot after our torpedoes have landed and target is flooding
		should_shoot_guns = true

	if should_shoot_guns:
		super.engage_target(target)
		# Reset flooding flag after we start shooting
		target_is_flooding = false

	# Fire torpedoes
	update_torpedo_aim(target)

	torpedo_fire_timer += 1.0 / Engine.physics_ticks_per_second
	if torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes(target)


func update_torpedo_aim(target_ship: Ship):
	has_valid_torpedo_solution = false
	current_salvo_positions.clear()

	if !target_ship or !is_instance_valid(target_ship):
		return

	# Get torpedo controller
	var torpedo_controller = _ship.torpedo_controller
	if !torpedo_controller:
		return

	# Check distance - torpedoes have limited range
	var distance_to_target = _ship.global_position.distance_to(target_ship.global_position)
	var torpedo_range = torpedo_controller.get_params()._range

	if distance_to_target > torpedo_range * 0.9:  # Use 90% of max range for safety margin
		return

	current_torpedo_range = distance_to_target

	# Calculate interception point using the quadratic formula
	# Torpedo speed is multiplied by 3.0 (TORPEDO_SPEED_MULTIPLIER from TorpedoManager)
	var torpedo_speed = torpedo_controller.get_torp_params().speed * 3.0
	torpedo_target_position = calculate_interception_point(
		_ship.global_position,
		target_ship.global_position,
		target_ship.linear_velocity,
		torpedo_speed
	)

	# Verify the interception point is within range
	var interception_distance = _ship.global_position.distance_to(torpedo_target_position)
	if interception_distance > torpedo_range * 0.95:
		return

	# Calculate current lead angle and track changes
	var current_time = Time.get_ticks_msec() / 1000.0
	var to_lead = torpedo_target_position - _ship.global_position
	var current_lead_angle = atan2(to_lead.x, to_lead.z)

	if last_lead_update_time > 0:
		var dt = current_time - last_lead_update_time
		if dt > 0.01:  # Avoid division by very small numbers
			var angle_diff = current_lead_angle - last_lead_angle
			# Normalize angle difference to -PI to PI
			while angle_diff > PI:
				angle_diff -= TAU
			while angle_diff < -PI:
				angle_diff += TAU
			# Smooth the angle change rate
			var new_rate = angle_diff / dt
			lead_angle_change_rate = lerp(lead_angle_change_rate, new_rate, LEAD_ANGLE_SMOOTHING)

	last_lead_angle = current_lead_angle
	last_lead_update_time = current_time

	# Calculate torpedo flight time for prediction
	var flight_time = interception_distance / torpedo_speed

	# Predict where the lead angle will be when torpedoes arrive
	var predicted_angle_offset = lead_angle_change_rate * flight_time * 0.5  # Partial prediction

	# Calculate spread angle based on range
	var range_km = distance_to_target / 1000.0
	var spread_angle = SPREAD_ANGLE_BASE + SPREAD_ANGLE_PER_KM * range_km

	# Generate spread positions: center adjusted for prediction, plus spread on each side
	var spread_offsets = [-2, -1, 0, 1, 2]  # 5 torpedo spread

	for offset in spread_offsets:
		# Calculate angle for this torpedo in the spread
		var torpedo_angle = current_lead_angle + predicted_angle_offset + (offset * spread_angle)
		var torpedo_direction = Vector3(sin(torpedo_angle), 0, cos(torpedo_angle))
		var torpedo_aim_point = _ship.global_position + torpedo_direction * interception_distance
		torpedo_aim_point.y = 0

		# Check if this spread position is valid (no terrain, no friendlies)
		if is_land_blocking_torpedo_path(_ship.global_position, torpedo_aim_point):
			continue
		if would_hit_friendly_ship(_ship.global_position, torpedo_aim_point, torpedo_speed):
			continue

		current_salvo_positions.append(torpedo_aim_point)

	# We have a valid solution if at least the center torpedo can fire
	if current_salvo_positions.size() > 0:
		has_valid_torpedo_solution = true
		# Aim at the center of valid positions for turret tracking
		var center_idx: int = int(float(current_salvo_positions.size()) / 2.0)
		var center_pos = current_salvo_positions[center_idx]
		torpedo_controller.set_aim_input(center_pos)

	# Calculate dynamic fire interval based on range
	var range_ratio = clamp(distance_to_target / RANGE_FOR_MAX_INTERVAL, 0.0, 1.0)
	torpedo_fire_interval = lerp(MIN_TORPEDO_INTERVAL, MAX_TORPEDO_INTERVAL, range_ratio)

func try_fire_torpedoes(target_ship):
	if !has_valid_torpedo_solution:
		salvo_spread_index = 0
		return

	if !target_ship or !is_instance_valid(target_ship):
		salvo_spread_index = 0
		return

	if current_salvo_positions.size() == 0:
		salvo_spread_index = 0
		return

	# Get torpedo controller
	var torpedo_controller = _ship.torpedo_controller
	if !torpedo_controller:
		return

	# Get the current spread position to aim at
	var aim_index = salvo_spread_index % current_salvo_positions.size()
	var aim_position = current_salvo_positions[aim_index]

	# Set aim for this specific torpedo
	torpedo_controller.set_aim_input(aim_position)

	# Check if any launcher is ready and aimed
	for launcher in torpedo_controller.launchers:
		if launcher.reload >= 1.0 and launcher.can_fire and !launcher.disabled:
			torpedo_controller.fire_next_ready()
			salvo_spread_index += 1
			torpedoes_in_salvo += 1
			print("Firing torpedo ", salvo_spread_index, " at spread position, range: ", current_torpedo_range)

			# Reset salvo tracking if we've fired all spread positions
			if salvo_spread_index >= current_salvo_positions.size():
				salvo_spread_index = 0
				torpedoes_in_salvo = 0
			return

func is_land_blocking_torpedo_path(from_pos: Vector3, to_pos: Vector3) -> bool:

	var space_state = _ship.get_world_3d().direct_space_state
	var ray = PhysicsRayQueryParameters3D.new()
	ray.from = from_pos + (to_pos - from_pos).normalized() * 30.0
	ray.from.y = 1
	ray.to = to_pos
	ray.to.y = 1

	var collision = space_state.intersect_ray(ray)

	if !collision.is_empty():
		return true
	return false

func would_hit_friendly_ship(from_pos: Vector3, to_pos: Vector3, torpedo_speed: float) -> bool:
	# Check if any friendly ship within range would be hit by the torpedo
	if !_ship:
		return false

	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if !server_node:
		return false

	var torpedo_direction = (to_pos - from_pos).normalized()
	var torpedo_distance = from_pos.distance_to(to_pos)
	var time_to_target = torpedo_distance / torpedo_speed

	for player_data in server_node.get_team_ships(_ship.team.team_id):
		var other_ship: Ship = player_data

		# Skip self and invalid ships
		if other_ship == _ship or !is_instance_valid(other_ship):
			continue

		# Only check friendly ships
		if other_ship.team.team_id != _ship.team.team_id:
			continue

		# Skip dead ships
		if other_ship.health_controller.current_hp <= 0:
			continue

		# Only check ships within the friendly fire check radius
		var distance_to_ally = _ship.global_position.distance_to(other_ship.global_position)
		if distance_to_ally > friendly_fire_check_radius:
			continue

		# Check if the ally's path intersects with the torpedo path
		# We need to check multiple points in time as both torpedo and ally are moving
		var check_points = 10
		for i in range(check_points + 1):
			var t = float(i) / float(check_points) * time_to_target

			# Torpedo position at time t
			var torpedo_pos = from_pos + torpedo_direction * torpedo_speed * t
			torpedo_pos.y = 0  # Keep at water level

			# Ally position at time t (assuming constant velocity)
			var ally_pos = other_ship.global_position + other_ship.linear_velocity * t
			ally_pos.y = 0  # Keep at water level

			# Check distance between torpedo and ally at this time
			var distance_at_t = torpedo_pos.distance_to(ally_pos)

			if distance_at_t < friendly_fire_safety_margin:
				return true

	return false

func calculate_interception_point(shooter_pos: Vector3, target_pos: Vector3, target_vel: Vector3, projectile_speed: float) -> Vector3:
	# Calculate interception point for a projectile to hit a moving target
	# Both projectile and target move at constant speed and direction
	#
	# Uses quadratic formula to solve for time t:
	# |target_pos + target_vel * t - shooter_pos|^2 = (projectile_speed * t)^2

	var to_target = target_pos - shooter_pos

	# Quadratic coefficients: a*t^2 + b*t + c = 0
	var a = target_vel.dot(target_vel) - projectile_speed * projectile_speed
	var b = 2.0 * to_target.dot(target_vel)
	var c = to_target.dot(to_target)

	# Handle case where speeds are equal (linear solution)
	if abs(a) < 0.0001:
		if abs(b) < 0.0001:
			return target_pos  # No solution, return current position
		var t_linear = -c / b
		if t_linear > 0:
			return target_pos + target_vel * t_linear
		return target_pos

	var discriminant = b * b - 4.0 * a * c

	if discriminant < 0:
		# No real solution - target is too fast or moving away
		return target_pos

	var sqrt_disc = sqrt(discriminant)
	var t1 = (-b - sqrt_disc) / (2.0 * a)
	var t2 = (-b + sqrt_disc) / (2.0 * a)

	# Choose the smallest positive time
	var t = -1.0
	if t1 > 0 and t2 > 0:
		t = min(t1, t2)
	elif t1 > 0:
		t = t1
	elif t2 > 0:
		t = t2
	else:
		# No positive solution
		return target_pos

	return target_pos + target_vel * t
