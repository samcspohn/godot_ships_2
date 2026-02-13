extends BotBehavior
class_name DDBehavior

var ammo = ShellParams.ShellType.HE

# Speed variation for evasion
var speed_variation_timer: float = 0.0
var current_speed_multiplier: float = 1.0
const SPEED_VARIATION_PERIOD: float = 3.0
const SPEED_VARIATION_MIN: float = 0.6
const SPEED_VARIATION_MAX: float = 1.0

# Track torpedo hits and floods for shooting decision
var last_torpedo_count: int = 0
var last_flood_count: int = 0
var target_is_flooding: bool = false

# Track closest enemy for retreat decisions
var closest_enemy: Ship

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

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

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.50,
		range_increase_when_damaged = 0.30,
		min_safe_distance_ratio = 0.30,
		flank_bias_healthy = 0.3,
		flank_bias_damaged = 0.1,
		spread_distance = 1500.0,  # DDs spread more
		spread_multiplier = 1.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.8,      # DDs hunt aggressively
		cautious_hp_threshold = 0.3,
		use_island_cover = false,
	}

# ============================================================================
# EVASION - DD-specific with speed variation
# ============================================================================

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Override to add speed variation for DDs."""
	var result = super.get_desired_heading(target, current_heading, delta, destination)

	# Update speed variation when evading
	if result.use_evasion:
		speed_variation_timer += delta
		var speed_wave = (sin(speed_variation_timer * TAU / SPEED_VARIATION_PERIOD) + 1.0) / 2.0
		current_speed_multiplier = lerp(SPEED_VARIATION_MIN, SPEED_VARIATION_MAX, speed_wave)
	else:
		current_speed_multiplier = 1.0

	return result

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion."""
	return current_speed_multiplier

# ============================================================================
# TARGET SELECTION - DD-specific logic (visible vs hidden priority)
# ============================================================================

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	"""DD target selection differs based on visibility - torpedoes vs guns."""
	var target: Ship = null
	var highest_priority: float = -1.0
	var gun_range = _ship.artillery_controller.get_params()._range
	var torpedo_range: float = -1.0

	if _ship.torpedo_controller != null:
		torpedo_range = _ship.torpedo_controller.get_params()._range

	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		angle -= PI / 4  # Best angle to torpedo is 45 degrees incoming
		var priority: float = 0.0

		if !_ship.visible_to_enemy:
			# Hidden - prioritize torpedo targets
			priority = cos(angle) * ship.movement_controller.ship_length / dist
			if torpedo_range > 0:
				priority = priority * 0.3 + (1.0 - dist / torpedo_range) * 0.7
			if ship.ship_class == Ship.ShipClass.BB:
				priority *= 3.0  # BBs are prime torpedo targets
		else:
			# Visible - prioritize gun targets
			priority = (1.0 - dist / gun_range)

		# Boost targets within range
		if dist <= gun_range or (torpedo_range > 0 and dist <= torpedo_range):
			priority *= 10.0

		if priority > highest_priority:
			target = ship
			highest_priority = priority

	return target

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

	match _target.ship_class:
		Ship.ShipClass.BB:
			# HE at battleship superstructure
			ammo = ShellParams.ShellType.HE
			offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			# Check if broadside
			if abs(sin(angle)) > sin(deg_to_rad(70)):
				if dist < 500:
					# AP at broadside cruisers waterline < 500
					ammo = ShellParams.ShellType.AP
					offset.y = 0.0
				elif dist < 1000:
					# AP at broadside cruisers when < 1000
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				else:
					# HE at cruiser superstructure
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
				offset.y = 0.0
			else:
				# HE at destroyers
				ammo = ShellParams.ShellType.HE
				offset.y = 1.0
	return offset

# ============================================================================
# POSITIONING - DD-specific positioning (concealment-based)
# ============================================================================

func get_desired_position(friendly: Array[Ship], enemy: Array[Ship], target: Ship, current_destination: Vector3) -> Vector3:
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")

	# If no target, hunt unspotted enemies
	if target == null:
		return _get_hunting_position(server_node, friendly, current_destination)

	var concealment_radius = (_ship.concealment.params.p() as ConcealmentParams).radius
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
	var params = get_positioning_params()

	# Calculate separation from friendly ships
	var separation = _calculate_spread_offset(friendly, params.spread_distance, params.spread_multiplier)

	if _ship.visible_to_enemy:
		# Visible - retreat away from closest enemy
		closest_enemy = enemy[0]
		var closest_enemy_dist = (closest_enemy.global_position - _ship.global_position).length()
		for ship in enemy:
			var dist = (ship.global_position - _ship.global_position).length()
			if dist < closest_enemy_dist:
				closest_enemy = ship
				closest_enemy_dist = dist

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
			desired_position = desired_position * 0.8 + nearest_friendly_pos * 0.2

		desired_position += separation * 500.0
		return _get_valid_nav_point(desired_position)
	else:
		# Hidden - flank target for torpedo attack
		var right = target.transform.basis.x * concealment_radius * 1.5
		var right_of = target.global_position + right
		var left_of = target.global_position - right

		right_of = _get_valid_nav_point(right_of)
		left_of = _get_valid_nav_point(left_of)

		var desired_position: Vector3
		if right_of.distance_to(_ship.global_position) < left_of.distance_to(_ship.global_position):
			desired_position = right_of
		else:
			desired_position = left_of

		desired_position += separation * 500.0
		return _get_valid_nav_point(desired_position)

# ============================================================================
# COMBAT - DD-specific engagement with torpedo logic
# ============================================================================

func engage_target(target: Ship):
	# Track torpedo hits and floods
	var current_torpedo_count = _ship.stats.torpedo_count
	var current_flood_count = _ship.stats.flood_count

	if current_torpedo_count > last_torpedo_count:
		last_torpedo_count = current_torpedo_count

	if current_flood_count > last_flood_count:
		last_flood_count = current_flood_count
		target_is_flooding = true

	# Determine if we should shoot guns
	var should_shoot_guns = false
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	if hp_ratio < 0.3:
		# Low health - prioritize stealth
		should_shoot_guns = false
	elif _ship.visible_to_enemy and closest_enemy and closest_enemy.global_position.distance_to(_ship.global_position) < (_ship.concealment.params.p() as ConcealmentParams).radius:
		# Spotted and within detection range
		should_shoot_guns = true
	elif target_is_flooding:
		# Target is flooding from our torpedoes
		should_shoot_guns = true

	if should_shoot_guns:
		super.engage_target(target)
		target_is_flooding = false

	# Fire torpedoes using base class torpedo system
	update_torpedo_aim(target)

	torpedo_fire_timer += 1.0 / Engine.physics_ticks_per_second
	if torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes(target)
