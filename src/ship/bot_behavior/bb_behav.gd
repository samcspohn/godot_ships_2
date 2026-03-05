extends BotBehavior
class_name BBBehavior

var ammo = ShellParams.ShellType.AP

# Arc movement state
var current_arc_direction: int = 0
var arc_direction_timer: float = 0.0
var arc_direction_initialized: bool = false
const ARC_DIRECTION_CHANGE_TIME: float = 30.0
const ARC_MOVEMENT_SPEED: float = 0.15
const MIN_SAFE_ANGLE_FROM_THREAT: float = PI / 3.0

# Broadside heading preference (degrees offset from pure perpendicular)
const BROADSIDE_ANGLE_OFFSET: float = 15.0  # slight bow-in for angling

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(25),
		max_angle = deg_to_rad(35),
		evasion_period = 20.0,  # Slow, deliberate weaves
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 2.0   # Other BBs are primary threat
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 3.0   # DDs less relevant for angling
	return 1.0

func get_target_weights() -> Dictionary:
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
		flanking_multiplier = 4.0,  # BBs prioritize flanking enemies (slightly lower than CA/DD since BBs turn slowly)
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.60,           # 70% of gun range
		range_increase_when_damaged = 0.35, # Up to +15% range when low HP
		min_safe_distance_ratio = 0.40,     # Don't let enemies within 50% range
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.1,
		spread_distance = 3000.0,
		spread_multiplier = 3.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.5,      # BBs move aggressively toward last known positions
		cautious_hp_threshold = 0.5,
		use_island_cover = false,
	}

# ============================================================================
# AMMO AND AIM - Class-specific targeting logic
# ============================================================================

func pick_ammo(_target: Ship) -> int:
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
				# HE against heavily angled battleships
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2.0
			elif angle < deg_to_rad(30):
				# AP at battleship superstructure when angled
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 2.0
			else:
				ammo = ShellParams.ShellType.AP
				offset.y = 0.1
		Ship.ShipClass.CA:
			if angle < deg_to_rad(30):
				# AP at angled cruiser bow/stern
				ammo = ShellParams.ShellType.AP
				offset.z -= _target.movement_controller.ship_length / 2.0 * 0.75
			else:
				# AP at broadside cruisers waterline
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0
		Ship.ShipClass.DD:
			# HE at destroyers
			ammo = ShellParams.ShellType.HE
			offset.y = 1.0
	return offset

# ============================================================================
# POSITIONING - BB-specific positioning with arc movement
# ============================================================================

func get_desired_position(friendly: Array[Ship], _enemy: Array[Ship], _target: Ship, current_destination: Vector3) -> Vector3:
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")

	var danger_center = _get_danger_center()
	if danger_center == Vector3.ZERO:
		current_destination = _get_hunting_position(server_node, friendly, current_destination)
		if current_destination == Vector3.ZERO:
			current_destination = _ship.global_position - _ship.basis.z * 10_000
			current_destination.y = 0
			return _get_valid_nav_point(current_destination)
		else:
			return current_destination



	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
	var params = get_positioning_params()

	# Calculate engagement range based on HP
	var range_increase = clamp((1.0 - hp_ratio) * params.range_increase_when_damaged, 0.0, params.range_increase_when_damaged)
	var engagement_range = (params.base_range_ratio + range_increase) * gun_range
	var min_safe_distance = gun_range * params.min_safe_distance_ratio

	# Calculate flanking bias
	var flank_bias = lerp(params.flank_bias_healthy, params.flank_bias_damaged, 1.0 - hp_ratio)

	# Get tactical position
	var desired_position = _calculate_tactical_position(engagement_range, min_safe_distance, flank_bias)

	# Apply arc movement for continuous maneuvering
	desired_position = _apply_arc_movement(desired_position, danger_center, engagement_range, server_node)

	# Apply spread offset
	desired_position += _calculate_spread_offset(friendly, params.spread_distance, params.spread_multiplier)

	return _get_valid_nav_point(desired_position)

func _apply_arc_movement(base_position: Vector3, danger_center: Vector3, engagement_range: float, server_node: GameServer) -> Vector3:
	"""Apply continuous arc movement around danger center to avoid parking."""
	var my_pos = _ship.global_position

	var to_me = my_pos - danger_center
	to_me.y = 0.0
	var current_angle = atan2(to_me.x, to_me.z)

	var friendly_angle = current_angle
	if server_node:
		var friendly_avg = server_node.get_team_avg_position(_ship.team.team_id)
		if friendly_avg != Vector3.ZERO:
			var to_friendly = friendly_avg - danger_center
			to_friendly.y = 0.0
			friendly_angle = atan2(to_friendly.x, to_friendly.z)

	# Initialize arc direction
	if not arc_direction_initialized:
		arc_direction_initialized = true
		var angle_to_friendly = _normalize_angle(friendly_angle - current_angle)
		current_arc_direction = -1 if angle_to_friendly > 0 else 1

	# Update arc direction periodically
	arc_direction_timer += 1.0 / Engine.physics_ticks_per_second
	if arc_direction_timer >= ARC_DIRECTION_CHANGE_TIME:
		arc_direction_timer = 0.0
		var angle_to_friendly = _normalize_angle(friendly_angle - current_angle)
		var preferred_direction = -sign(angle_to_friendly) if abs(angle_to_friendly) > 0.1 else current_arc_direction
		current_arc_direction = 1 if preferred_direction > 0 else -1

	# Apply arc movement
	var arc_movement = ARC_MOVEMENT_SPEED * current_arc_direction
	var new_angle = current_angle + arc_movement

	var arc_position = danger_center + Vector3(sin(new_angle), 0, cos(new_angle)) * engagement_range
	arc_position.y = 0.0

	# Blend between tactical position and arc position
	var blend_factor = 0.3
	return base_position * (1.0 - blend_factor) + arc_position * blend_factor

# ============================================================================
# NAVINTENT — V4 bot controller interface
# ============================================================================

var base_intent_pos = null
func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	"""BB always returns POSE with safe heading for navigation."""
	var friendly = server.get_team_ships(ship.team.team_id)
	var _enemy = server.get_valid_targets(ship.team.team_id)

	var danger_center = _get_danger_center()

	# --- No enemies visible: hunt ---
	if danger_center == Vector3.ZERO:
		if base_intent_pos == null:
			base_intent_pos = ship.global_position - ship.global_transform.basis.z * 20_000.0
			base_intent_pos.y = 0.0
		var hunt_dest = _get_hunting_position(server, friendly, base_intent_pos)
		if hunt_dest == Vector3.ZERO:

			var fallback = base_intent_pos
			fallback = _get_valid_nav_point(fallback)
			return NavIntent.pose(fallback, _calc_approach_heading(ship, fallback))
		return NavIntent.pose(hunt_dest, _calc_approach_heading(ship, hunt_dest))

	# --- Engagement: calculate tactical position with arc movement ---
	var gun_range = ship.artillery_controller.get_params()._range
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
	var params = get_positioning_params()

	var range_increase = clamp((1.0 - hp_ratio) * params.range_increase_when_damaged, 0.0, params.range_increase_when_damaged)
	var engagement_range = (params.base_range_ratio + range_increase) * gun_range
	var min_safe_distance = gun_range * params.min_safe_distance_ratio
	var flank_bias = lerp(params.flank_bias_healthy, params.flank_bias_damaged, 1.0 - hp_ratio)

	var desired_position = _calculate_tactical_position(engagement_range, min_safe_distance, flank_bias)
	desired_position = _apply_arc_movement(desired_position, danger_center, engagement_range, server)
	desired_position += _calculate_spread_offset(friendly, params.spread_distance, params.spread_multiplier)
	desired_position = _get_valid_nav_point(desired_position)

	# --- Calculate broadside heading ---
	var broadside_heading = _calculate_broadside_heading(target, danger_center, desired_position)

	# --- Check if evasion heading should override ---
	if ship.visible_to_enemy and target != null:
		var heading_info = get_desired_heading(target, _get_ship_heading(), 0.0, desired_position)
		if heading_info.get("use_evasion", false):
			# Blend evasion with broadside: evasion takes priority but keep broadside influence
			var evasion_heading: float = heading_info.heading
			var blended = _normalize_angle(evasion_heading * 0.6 + broadside_heading * 0.4)
			return NavIntent.pose(desired_position, blended)

	return NavIntent.pose(desired_position, broadside_heading)


## Compute approach heading from ship to destination
func _calc_approach_heading(ship: Ship, dest: Vector3) -> float:
	var to_dest = dest - ship.global_position
	to_dest.y = 0.0
	if to_dest.length_squared() > 1.0:
		return atan2(to_dest.x, to_dest.z)
	return _get_ship_heading()

func _calculate_broadside_heading(target: Ship, danger_center: Vector3, desired_pos: Vector3) -> float:
	"""Calculate a heading that presents broadside to the primary threat while angling slightly bow-in.
	BBs want to keep all turrets on target, which means roughly perpendicular to the threat bearing."""

	# Use target position if available, otherwise use danger center
	var threat_pos: Vector3
	if target != null and is_instance_valid(target):
		threat_pos = target.global_position
	else:
		threat_pos = danger_center

	var to_threat = threat_pos - desired_pos
	to_threat.y = 0.0
	var threat_bearing = atan2(to_threat.x, to_threat.z)

	# Pure broadside is perpendicular to threat bearing
	# Choose the perpendicular direction that is closest to our current heading
	# so the ship doesn't do a 180 to present the other broadside
	var current_heading = _get_ship_heading()

	var broadside_right = _normalize_angle(threat_bearing + PI / 2.0)
	var broadside_left = _normalize_angle(threat_bearing - PI / 2.0)

	var diff_right = abs(_normalize_angle(broadside_right - current_heading))
	var diff_left = abs(_normalize_angle(broadside_left - current_heading))

	var broadside: float
	if diff_right <= diff_left:
		broadside = broadside_right
	else:
		broadside = broadside_left

	# Angle slightly bow-in toward the threat for armor angling
	var bow_in_offset = deg_to_rad(BROADSIDE_ANGLE_OFFSET)
	var angle_to_threat = _normalize_angle(threat_bearing - broadside)
	if angle_to_threat > 0:
		broadside = _normalize_angle(broadside + bow_in_offset)
	else:
		broadside = _normalize_angle(broadside - bow_in_offset)

	return broadside
