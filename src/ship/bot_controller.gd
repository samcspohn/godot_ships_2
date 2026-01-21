# src/ship/bot_controller.gd
extends Node

class_name BotController

var ship: Ship
var target_ship: Ship = null
var target_scan_timer: float = 0.0
var target_scan_interval: float = 20.0
var attack_range: float = 100000.0
var preferred_distance: float = 8000.0
var engagement_range: float = 10000.0  # Set based on concealment

# Target angle thresholds (in radians)
var broadside_angle_threshold: float = deg_to_rad(30.0)  # Target within 30 degrees of broadside
var angled_threshold: float = deg_to_rad(45.0)  # Target is considered angled above this

# Torpedo parameters
var torpedo_fire_interval: float = 3.0  # How often to attempt firing
var torpedo_fire_timer: float = 0.0
var torpedo_land_check_segments: int = 10  # Number of points to check along torpedo path
var torpedo_target_position: Vector3 = Vector3.ZERO  # Calculated interception point
var has_valid_torpedo_solution: bool = false
var friendly_fire_check_radius: float = 5000.0  # Check allies within this distance
var friendly_fire_safety_margin: float = 500.0  # How close torpedo path can be to ally

# Movement state
var desired_heading: float = 0.0
var turn_speed: float = 0.5

# Collision avoidance parameters (dynamically calculated based on ship movement)
var collision_avoidance_distance: float = 2000.0  # Distance to start avoiding obstacles
var collision_check_rays: int = 16  # Number of rays to cast for collision detection (increased for better lateral detection)
var collision_ray_spread: float = TAU  # 360 degrees spread for collision rays (full circle)
var emergency_stop_distance: float = 500.0  # Distance to emergency stop
var avoidance_turn_strength: float = 2.0  # How strong avoidance turning should be
var debug_draw: bool = false  # Enable debug visualization

# Minimum collision distances (safety floor for small/agile ships)
var min_collision_avoidance_distance: float = 400.0  # Minimum distance to start avoiding
var min_emergency_stop_distance: float = 150.0  # Minimum emergency stop distance
var min_recovery_reverse_distance: float = 100.0  # Minimum reverse distance

# Lateral obstacle detection
var lateral_check_distance: float = 300.0  # Distance to check for obstacles on sides
var lateral_avoidance_strength: float = 1.5  # How strongly to avoid lateral obstacles

# Collision recovery state
enum RecoveryState { NORMAL, EMERGENCY_REVERSING, RECOVERY_TURNING, STUCK_ESCAPE }
var recovery_state: RecoveryState = RecoveryState.NORMAL
var recovery_reverse_distance: float = 0.0  # How far we need to reverse
var recovery_start_position: Vector3 = Vector3.ZERO  # Where we started reversing
var recovery_escape_heading: float = 0.0  # Direction to escape after reversing
var recovery_timeout: float = 0.0  # Timeout to prevent getting stuck in recovery
var recovery_max_timeout: float = 15.0  # Maximum time in recovery mode

# Stuck detection
var stuck_check_interval: float = 2.0  # How often to check if stuck
var stuck_check_timer: float = 0.0
var last_stuck_check_position: Vector3 = Vector3.ZERO
var stuck_movement_threshold: float = 5.0  # Minimum movement expected in stuck_check_interval
var consecutive_stuck_checks: int = 0  # How many times we've detected being stuck
var stuck_threshold: int = 2  # Number of consecutive stuck checks before taking action

# Ship avoidance reduction during recovery
var recovery_ship_avoidance_factor: float = 0.1  # Reduce ship avoidance to 10% during recovery
var normal_ship_avoidance_factor: float = 1.0  # Normal ship avoidance strength

# Base collision parameters (multipliers for ship-specific calculations)
var base_collision_multiplier: float = 1.5  # Safety multiplier for collision distance
var base_emergency_multiplier: float = 0.3  # Emergency distance as fraction of collision distance

# Strategic navigation parameters
var map_center: Vector3 = Vector3(0, 0, 0)  # Center of the map
var patrol_radius: float = 8000.0  # 8km patrol circle around center
var opposite_side_reached: bool = false  # Whether bot has reached opposite side
var initial_approach_distance: float = 2000.0  # How close to get to opposite side before patrolling

# Patrol point management
var current_patrol_target: Vector3 = Vector3.ZERO  # Current patrol destination
var patrol_point_reach_distance: float = 500.0  # Distance to reach patrol point before selecting new one
var has_patrol_target: bool = false  # Whether we have a valid patrol target

# Consumable usage parameters
var consumable_check_interval: float = 1.0  # How often to evaluate consumable usage
var consumable_check_timer: float = 0.0
var repair_party_hp_threshold: float = 0.7  # Use repair party when HP below 70%
var repair_party_critical_threshold: float = 0.4  # Always use repair party when HP below 40%
var damage_control_min_fires: int = 1  # Minimum fires to trigger damage control
var damage_control_hp_threshold: float = 0.5  # Use damage control more aggressively when HP below 50%
var debug_consumables: bool = true  # Enable debug logging for consumable usage
var debug_consumables_verbose: bool = false  # Enable verbose logging (logs every check, not just actions)

var ray_query: PhysicsRayQueryParameters3D
func _ready():
	# Wait for ship reference to be set
	if !ship:
		await get_tree().process_frame


	# Initialize strategic navigation
	opposite_side_reached = false
	has_patrol_target = false
	current_patrol_target = Vector3.ZERO

	# Initialize desired heading based on ship's current orientation if available
	if ship:
		desired_heading = get_ship_heading()

		# If we start in the patrol zone, skip the approach phase
		if is_in_patrol_zone():
			opposite_side_reached = true

		# Calculate dynamic collision avoidance distances based on ship movement parameters
		calculate_dynamic_collision_distances()

		# Set engagement range based on concealment (just outside detection range)
		_update_engagement_range()
	else:
		desired_heading = randf() * TAU

	ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collision_mask = 1 | 1 << 2 # Check for terrain and ships
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	ray_query.hit_from_inside = false
	ray_query.exclude = [ship]

func _update_engagement_range() -> void:
	"""Set engagement range to just outside concealment range"""
	if ship and ship.concealment and ship.concealment.params:
		var base_concealment = ship.concealment.params.radius
		engagement_range = min(base_concealment + 500.0, 11000.0)  # 500m buffer outside concealment
		preferred_distance = engagement_range

func get_target_angle(target: Ship) -> float:
	"""Calculate the angle between target's facing direction and the line from target to us.
	Returns 0 for perfect broadside, PI/2 for bow/stern on."""
	if !target or !is_instance_valid(target):
		return 0.0

	# Get target's forward direction (local Z axis in world space)
	var target_forward = -target.global_transform.basis.z.normalized()

	# Get direction from target to our ship
	var to_us = (ship.global_position - target.global_position).normalized()
	to_us.y = 0  # Only consider horizontal plane
	target_forward.y = 0
	target_forward = target_forward.normalized()
	to_us = to_us.normalized()

	# Calculate angle between target's forward and direction to us
	var dot = target_forward.dot(to_us)
	var angle_from_bow = acos(clamp(dot, -1.0, 1.0))

	# Convert to angle from broadside (0 = broadside, PI/2 = bow/stern)
	var angle_from_broadside = abs(PI / 2.0 - angle_from_bow)

	return angle_from_broadside

func is_target_broadside(target: Ship) -> bool:
	"""Check if target is showing broadside (within threshold of perpendicular)"""
	return get_target_angle(target) < broadside_angle_threshold

func is_target_angled(target: Ship) -> bool:
	"""Check if target is significantly angled (bow/stern towards us)"""
	return get_target_angle(target) > angled_threshold

func select_shell_for_target(target: Ship) -> int:
	"""Select appropriate shell type based on own ship class, target class, and angle.
	Returns 0 for AP (shell1), 1 for HE (shell2)."""
	if !target or !is_instance_valid(target):
		return 0  # Default to AP

	var my_class = ship.ship_class
	var target_class = target.ship_class
	var target_is_broadside = is_target_broadside(target)
	var target_is_angled = is_target_angled(target)

	match my_class:
		Ship.Class.BB:  # Battleship
			# Battleships generally shoot AP
			if target_is_angled:
				# At angled targets, still use AP but aim at superstructure (handled in aim logic)
				return 0  # AP
			else:
				return 0  # AP for broadside targets

		Ship.Class.CA:  # Cruiser
			# Cruisers generally shoot HE except at cruiser broadsides
			if target_class == Ship.Class.CA and target_is_broadside:
				return 0  # AP at cruiser broadsides
			elif target_class == Ship.Class.BB:
				return 1  # HE at battleships (superstructure)
			else:
				return 1  # HE default for cruisers

		Ship.Class.DD:  # Destroyer
			# Destroyers use HE
			return 1

		_:
			return 1  # Default to HE for other classes

func get_aim_offset_for_target(target: Ship) -> Vector3:
	"""Get vertical aim offset based on target type and situation.
	Returns offset to add to target position for aiming."""
	if !target or !is_instance_valid(target):
		return Vector3.ZERO

	var my_class = ship.ship_class
	var target_class = target.ship_class
	var target_is_angled = is_target_angled(target)

	# Default offset (waterline)
	var offset = Vector3.ZERO

	match my_class:
		Ship.Class.BB:  # Battleship
			if target_is_angled:
				# Aim at superstructure when target is angled
				offset.y = 8.0  # Aim higher for superstructure
			elif target_class == Ship.Class.DD:
				offset.y = 2.0  # Slight elevation for destroyers
			# else aim at waterline/belt

		Ship.Class.CA:  # Cruiser
			if target_class == Ship.Class.BB:
				# Aim at superstructure with HE
				offset.y = 10.0
			elif target_class == Ship.Class.CA:
				# Aim at upper belt
				offset.y = 4.0
			elif target_class == Ship.Class.DD:
				offset.y = 2.0

		Ship.Class.DD:  # Destroyer
			# Aim center mass
			offset.y = 3.0

	return offset

func can_destroyer_shoot(target: Ship) -> bool:
	"""Check if destroyer is within its concealment range to shoot"""
	if ship.ship_class != Ship.Class.DD:
		return true  # Non-destroyers can always shoot

	if !target or !is_instance_valid(target):
		return false

	var distance = ship.global_position.distance_to(target.global_position)
	var concealment_range = ship.concealment.params.radius if ship.concealment and ship.concealment.params else 6000.0

	# Destroyer should only shoot if target is within their concealment range
	return distance <= concealment_range

func calculate_dynamic_collision_distances() -> void:
	"""Calculate collision avoidance distances dynamically based on ship movement parameters."""
	if !ship:
		return

	var movement_controller = ship.get_node_or_null("Modules/MovementController")
	if !movement_controller:
		return

	# Get movement parameters from ShipMovementV2
	var max_speed: float = movement_controller.max_speed if "max_speed" in movement_controller else 15.0
	var deceleration_time: float = movement_controller.deceleration_time if "deceleration_time" in movement_controller else 4.0
	var acceleration_time: float = movement_controller.acceleration_time if "acceleration_time" in movement_controller else 8.0
	var turning_circle: float = movement_controller.turning_circle_radius if "turning_circle_radius" in movement_controller else 200.0
	var rudder_response: float = movement_controller.rudder_response_time if "rudder_response_time" in movement_controller else 1.5

	# Calculate stopping distance: distance = speed * deceleration_time / 2 (average speed during decel)
	var stopping_distance: float = max_speed * deceleration_time * 0.5

	# Add turning circle contribution - need room to turn away
	var turning_contribution: float = turning_circle * 1.5

	# Add rudder response time contribution - reaction distance
	var rudder_reaction_distance: float = max_speed * rudder_response * 0.5

	# Calculate total collision avoidance distance with safety multiplier
	# Apply minimum floor to prevent small ships from cutting too close
	collision_avoidance_distance = max(
		(stopping_distance + turning_contribution + rudder_reaction_distance) * base_collision_multiplier,
		min_collision_avoidance_distance
	)

	# Emergency stop distance is a fraction of collision avoidance distance, with minimum
	emergency_stop_distance = max(
		collision_avoidance_distance * base_emergency_multiplier,
		min_emergency_stop_distance
	)

	# Calculate minimum reverse distance for recovery (need enough room to turn)
	# This should be at least half the turning circle radius plus some buffer
	recovery_reverse_distance = max(
		turning_circle * 0.6 + stopping_distance * 0.3,
		min_recovery_reverse_distance
	)

	# Calculate lateral check distance based on ship size and turning circle
	lateral_check_distance = max(turning_circle * 0.4, 150.0)

	# Adjust avoidance turn strength based on ship agility
	# Ships with faster rudder response can turn more aggressively
	avoidance_turn_strength = 1.5 + (2.0 / max(rudder_response, 0.5))

	# Set recovery timeout based on how long it takes to reverse and turn
	recovery_max_timeout = deceleration_time + acceleration_time + (turning_circle / max_speed) * 2

	# Set stuck movement threshold based on speed
	stuck_movement_threshold = max_speed * stuck_check_interval * 0.1  # Expect at least 10% of max movement

	if debug_draw:
		print("Bot collision distances calculated:")
		print("  - Collision avoidance: ", collision_avoidance_distance)
		print("  - Emergency stop: ", emergency_stop_distance)
		print("  - Recovery reverse: ", recovery_reverse_distance)
		print("  - Lateral check: ", lateral_check_distance)
		print("  - Avoidance strength: ", avoidance_turn_strength)

func get_ship_heading() -> float:
	if !ship:
		return 0.0
	# Ship's forward direction is -Z axis
	var forward = -ship.global_transform.basis.z
	# Convert to 2D heading (angle in XZ plane)
	return atan2(forward.z, forward.x)

func get_opposite_side_target() -> Vector3:
	if !ship:
		return map_center

	var ship_pos = ship.global_position

	# Determine which team spawn this bot is closer to, and target the opposite side
	var spawn0_pos = Vector3(0, 0, -5352.04)  # Team 0 spawn (North)
	var spawn1_pos = Vector3(0, 0, 7234.61)   # Team 1 spawn (South)

	var dist_to_spawn0 = ship_pos.distance_to(spawn0_pos)
	var dist_to_spawn1 = ship_pos.distance_to(spawn1_pos)

	var max_attempts = 15  # Prevent infinite loops
	var attempt = 0

	while attempt < max_attempts:
		var target: Vector3

		# Target the opposite spawn area
		if dist_to_spawn0 < dist_to_spawn1:
			# Closer to north spawn, go towards south
			target = spawn1_pos + Vector3(randf_range(-2000, 2000), 0, randf_range(-1000, 1000))
		else:
			# Closer to south spawn, go towards north
			target = spawn0_pos + Vector3(randf_range(-2000, 2000), 0, randf_range(-1000, 1000))

		# Check if this position is on water
		if is_position_on_water(target):
			return target

		attempt += 1

	# Fallback: return the base spawn position (should be in water)
	if dist_to_spawn0 < dist_to_spawn1:
		return spawn1_pos
	else:
		return spawn0_pos

func get_patrol_target() -> Vector3:
	var max_attempts = 20  # Prevent infinite loops
	var attempt = 0

	while attempt < max_attempts:
		# Generate a random point within the patrol radius around map center
		var angle = randf() * TAU
		var distance = randf_range(patrol_radius * 0.3, patrol_radius * 0.9)  # Stay within 30-90% of patrol radius

		var target = map_center + Vector3(
			cos(angle) * distance,
			0,
			sin(angle) * distance
		)

		# Check if this position is on water (not on land)
		if is_position_on_water(target):
			return target

		attempt += 1

	# Fallback: return map center if we can't find a water position
	return map_center

func is_position_on_water(position: Vector3) -> bool:
	if !ship:
		return true  # Default to true if no ship reference

	var space_state = ship.get_world_3d().direct_space_state

	# Cast ray downward from high above the position to check for terrain
	var ray_start = position + Vector3(0, 100, 0)  # Start 100m above
	var ray_end = position + Vector3(0, 0.1, 0)    # End just above sea level

	ray_query.from = ray_start
	ray_query.to = ray_end

	var collision = space_state.intersect_ray(ray_query)

	# If no collision, assume it's water
	if collision.is_empty():
		return true

	# If collision is above sea level (y > -5), it's likely land
	# Sea level in most naval games is around y = 0, so anything above -5 is probably land
	if collision.position.y > -5.0:
		return false

	# If collision is well below sea level, it's likely underwater terrain (still water)
	return true

func is_in_patrol_zone() -> bool:
	if !ship:
		return false

	var distance_to_center = ship.global_position.distance_to(map_center)
	return distance_to_center <= patrol_radius

func has_reached_opposite_side() -> bool:
	if !ship:
		return false

	var ship_pos = ship.global_position
	var opposite_target = get_opposite_side_target()

	# Check if we're within the approach distance of the opposite side
	var distance_to_opposite = ship_pos.distance_to(opposite_target)
	return distance_to_opposite <= initial_approach_distance

func _physics_process(delta: float):
	if !ship:
		return

	if !(_Utils.authority()):
		return

	# Check consumable usage periodically
	consumable_check_timer += delta
	if consumable_check_timer >= consumable_check_interval:
		evaluate_consumable_usage()
		consumable_check_timer = 0.0

	# Check if ship is stuck
	check_if_stuck(delta)

	# Handle collision recovery state
	if recovery_state != RecoveryState.NORMAL:
		handle_collision_recovery(delta)
		apply_ship_controls(delta)
		return

	# Scan for targets periodically
	target_scan_timer += delta
	if target_scan_timer > target_scan_interval:
		scan_for_targets()
		target_scan_timer = 0.0

	# Execute AI behavior
	if target_ship and is_instance_valid(target_ship):
		attack_behavior(delta)
	else:
		patrol_behavior(delta)

	# Apply movement
	apply_ship_controls(delta)

func check_if_stuck(delta: float) -> void:
	"""Check if the ship is stuck and hasn't moved significantly."""
	if !ship:
		return

	stuck_check_timer += delta

	if stuck_check_timer >= stuck_check_interval:
		stuck_check_timer = 0.0

		var current_pos = ship.global_position
		var distance_moved = current_pos.distance_to(last_stuck_check_position)

		if distance_moved < stuck_movement_threshold:
			consecutive_stuck_checks += 1
			if debug_draw:
				print("Stuck check: moved only ", distance_moved, "m (threshold: ", stuck_movement_threshold, ") - count: ", consecutive_stuck_checks)

			if consecutive_stuck_checks >= stuck_threshold and recovery_state == RecoveryState.NORMAL:
				# We're stuck - enter escape mode
				enter_stuck_escape_mode()
		else:
			# We're moving fine, reset counter
			consecutive_stuck_checks = 0

		last_stuck_check_position = current_pos

func enter_stuck_escape_mode() -> void:
	"""Enter stuck escape mode when boxed in by obstacles."""
	if debug_draw:
		print("Entering STUCK_ESCAPE mode - ship appears to be boxed in")

	recovery_state = RecoveryState.STUCK_ESCAPE
	recovery_start_position = ship.global_position
	recovery_timeout = 0.0
	consecutive_stuck_checks = 0

	# Find the best escape direction by checking all around
	recovery_escape_heading = find_best_escape_heading()

func handle_collision_recovery(delta: float) -> void:
	"""Handle collision recovery state machine."""
	if !ship:
		recovery_state = RecoveryState.NORMAL
		return

	recovery_timeout += delta

	# Timeout protection - exit recovery if taking too long
	if recovery_timeout > recovery_max_timeout:
		if debug_draw:
			print("Recovery timeout - forcing normal state")
		recovery_state = RecoveryState.NORMAL
		recovery_timeout = 0.0
		consecutive_stuck_checks = 0
		return

	print("handle_collision_recovery")
	match recovery_state:
		RecoveryState.EMERGENCY_REVERSING:
			_handle_emergency_reversing()
		RecoveryState.RECOVERY_TURNING:
			_handle_recovery_turning()
		RecoveryState.STUCK_ESCAPE:
			_handle_stuck_escape()

func _handle_emergency_reversing() -> void:
	"""Handle the emergency reversing phase of collision recovery."""
	var distance_reversed = recovery_start_position.distance_to(ship.global_position)
	var ship_heading = get_ship_heading()

	# Continuously check if the original obstruction is still there
	# This allows early exit if a ship passed in front of us
	var front_clearance = check_clearance_terrain_only(ship_heading)
	var min_clearance_to_proceed = emergency_stop_distance * 1.5

	if front_clearance > min_clearance_to_proceed:
		# Path ahead is now clear - exit recovery early
		if debug_draw:
			print("Obstruction cleared during reverse - exiting recovery early (clearance: ", front_clearance, ")")
		recovery_state = RecoveryState.NORMAL
		recovery_timeout = 0.0
		consecutive_stuck_checks = 0
		return

	# Check if we've reversed far enough
	if distance_reversed >= recovery_reverse_distance:
		# Check clearance in multiple directions to find escape route
		var best_heading = find_best_escape_heading()
		if best_heading != INF:
			recovery_escape_heading = best_heading
			recovery_state = RecoveryState.RECOVERY_TURNING
			if debug_draw:
				print("Reversed ", distance_reversed, "m - turning to escape heading: ", rad_to_deg(recovery_escape_heading))
		else:
			# Still blocked, continue reversing
			recovery_reverse_distance += 100.0  # Need to reverse more
			if debug_draw:
				print("Still blocked after reversing - extending reverse distance")

	# Set desired heading to continue reversing (we'll handle throttle in apply_ship_controls)
	desired_heading = ship_heading  # Maintain current heading while reversing

func _handle_recovery_turning() -> void:
	"""Handle the turning phase of collision recovery."""
	var ship_heading = get_ship_heading()
	var angle_diff = recovery_escape_heading - ship_heading

	# Normalize angle difference
	while angle_diff > PI:
		angle_diff -= TAU
	while angle_diff < -PI:
		angle_diff += TAU

	# Continuously check if any forward direction is now clear (obstacle may have moved)
	var front_clearance = check_clearance_terrain_only(ship_heading)
	if front_clearance > collision_avoidance_distance * 0.6:
		# Current heading is now clear - exit recovery
		if debug_draw:
			print("Forward path cleared during turn - exiting recovery (clearance: ", front_clearance, ")")
		recovery_state = RecoveryState.NORMAL
		recovery_timeout = 0.0
		consecutive_stuck_checks = 0
		return

	# Check if we're now facing the escape direction
	if abs(angle_diff) < 0.2:  # About 11 degrees tolerance
		# Check if path ahead is clear
		var clearance = check_clearance(recovery_escape_heading)
		if clearance > emergency_stop_distance:
			# We're clear - exit recovery mode
			recovery_state = RecoveryState.NORMAL
			recovery_timeout = 0.0
			consecutive_stuck_checks = 0
			if debug_draw:
				print("Recovery complete - path clear")
			return

	# Continue turning towards escape heading
	desired_heading = recovery_escape_heading

func _handle_stuck_escape() -> void:
	"""Handle escape when ship is boxed in by obstacles on multiple sides."""
	var ship_heading = get_ship_heading()

	# Check lateral clearances
	var left_clearance = check_clearance(ship_heading - PI/2)
	var right_clearance = check_clearance(ship_heading + PI/2)
	var front_clearance = check_clearance(ship_heading)
	var back_clearance = check_clearance(ship_heading + PI)

	if debug_draw:
		print("Stuck escape - L:", left_clearance, " R:", right_clearance, " F:", front_clearance, " B:", back_clearance)

	# Determine best escape strategy
	var best_clearance = max(left_clearance, right_clearance, front_clearance, back_clearance)

	if best_clearance < min_emergency_stop_distance:
		# Completely boxed in - just try reversing
		desired_heading = ship_heading
		# Throttle will be set to reverse in apply_ship_controls
	elif back_clearance == best_clearance and front_clearance < emergency_stop_distance:
		# Best escape is behind us - reverse and turn
		desired_heading = ship_heading + PI
		recovery_escape_heading = ship_heading + PI
	elif left_clearance > right_clearance and left_clearance > front_clearance:
		# Turn left
		recovery_escape_heading = ship_heading - PI/2
		desired_heading = recovery_escape_heading
	elif right_clearance > left_clearance and right_clearance > front_clearance:
		# Turn right
		recovery_escape_heading = ship_heading + PI/2
		desired_heading = recovery_escape_heading
	else:
		# Go forward if possible
		recovery_escape_heading = ship_heading
		desired_heading = ship_heading

	# Check if we've escaped (have good clearance ahead in our escape direction)
	var escape_clearance = check_clearance(recovery_escape_heading)
	if escape_clearance > collision_avoidance_distance * 0.5:
		var angle_to_escape = abs(recovery_escape_heading - ship_heading)
		while angle_to_escape > PI:
			angle_to_escape -= TAU
		if abs(angle_to_escape) < 0.3:  # Facing roughly the right direction
			recovery_state = RecoveryState.NORMAL
			recovery_timeout = 0.0
			consecutive_stuck_checks = 0
			if debug_draw:
				print("Escaped from stuck state")

func find_best_escape_heading() -> float:
	"""Find the best direction to escape after reversing."""
	if !ship:
		return get_ship_heading()  # Return current heading as fallback

	var ship_heading = get_ship_heading()
	var best_heading = ship_heading
	var best_clearance = 0.0

	# Check 12 directions around the ship for finer granularity
	for i in range(12):
		var test_heading = ship_heading + (i * PI / 6)  # 30 degree increments
		var clearance = check_clearance(test_heading)

		if clearance > best_clearance:
			best_clearance = clearance
			best_heading = test_heading

	# Also check lateral directions more carefully
	var left_heading = ship_heading - PI/2
	var right_heading = ship_heading + PI/2
	var left_clearance = check_clearance(left_heading)
	var right_clearance = check_clearance(right_heading)

	if left_clearance > best_clearance:
		best_clearance = left_clearance
		best_heading = left_heading
	if right_clearance > best_clearance:
		best_clearance = right_clearance
		best_heading = right_heading

	# Return the best heading found (even if clearance is low, we need some direction)
	if debug_draw:
		print("Best escape heading: ", rad_to_deg(best_heading), " with clearance: ", best_clearance)

	return best_heading

func enter_collision_recovery() -> void:
	"""Enter collision recovery mode."""
	if recovery_state != RecoveryState.NORMAL:
		return  # Already in recovery

	# Before entering recovery, check if the obstacle is terrain or just a ship
	# If it's only a ship blocking us, don't enter full recovery - just slow down
	var ship_heading = get_ship_heading()
	var terrain_clearance = check_clearance_terrain_only(ship_heading)

	# If terrain is clear but we're here, it means a ship triggered this
	# Don't enter full recovery for ships - they'll move
	if terrain_clearance > emergency_stop_distance * 1.5:
		if debug_draw:
			print("Skipping collision recovery - obstacle is a ship, not terrain (terrain clearance: ", terrain_clearance, ")")
		return

	recovery_state = RecoveryState.EMERGENCY_REVERSING
	recovery_start_position = ship.global_position
	recovery_timeout = 0.0

	# Recalculate distances in case they weren't set
	if recovery_reverse_distance <= 0:
		calculate_dynamic_collision_distances()

	if debug_draw:
		print("Entering collision recovery - will reverse ", recovery_reverse_distance, "m")

func evaluate_consumable_usage() -> void:
	"""Evaluate and use consumables smartly based on current situation."""
	if !ship:
		if debug_consumables_verbose:
			print("[BOT] evaluate_consumable_usage: ship is null")
		return

	if !ship.consumable_manager:
		if debug_consumables_verbose:
			print("[BOT %s] evaluate_consumable_usage: consumable_manager is null" % ship.name)
		return

	var consumable_manager = ship.consumable_manager
	var health_controller = ship.health_controller
	var fire_manager = ship.fire_manager

	if !health_controller:
		if debug_consumables_verbose:
			print("[BOT %s] evaluate_consumable_usage: health_controller is null" % ship.name)
		return

	# Calculate current HP ratio
	var hp_ratio = health_controller.current_hp / health_controller.max_hp

	# Get active fire count for logging and decisions
	# Fire nodes exist as potential fire locations, but are only active when lifetime > 0
	var fire_count = 0
	if fire_manager and fire_manager.fires:
		for fire in fire_manager.fires:
			if fire.lifetime > 0:
				fire_count += 1

	# Verbose: Log current state every check
	if debug_consumables_verbose:
		print("[BOT %s] Status - HP: %.0f/%.0f (%.0f%%), Fires: %d, Consumables: %d" % [
			ship.name,
			health_controller.current_hp,
			health_controller.max_hp,
			hp_ratio * 100,
			fire_count,
			consumable_manager.equipped_consumables.size()
		])

	# Track which consumable slots have which types
	var repair_party_slot: int = -1
	var damage_control_slot: int = -1

	# Find consumable slots by type
	for i in range(consumable_manager.equipped_consumables.size()):
		var item = consumable_manager.equipped_consumables[i]
		if item:
			if debug_consumables_verbose:
				var can_use = consumable_manager.can_use_item(item)
				var cooldown = consumable_manager.cooldowns.get(item.id, 0.0)
				var active = consumable_manager.active_effects.get(item.id, 0.0)
				print("[BOT %s] Slot %d: %s (type=%d), stacks=%d, cooldown=%.1f, active=%.1f, can_use=%s" % [
					ship.name, i, item.name, item.type, item.current_stack, cooldown, active, can_use
				])
			match item.type:
				ConsumableItem.ConsumableType.REPAIR_PARTY:
					repair_party_slot = i
				ConsumableItem.ConsumableType.DAMAGE_CONTROL:
					damage_control_slot = i
		else:
			if debug_consumables_verbose:
				print("[BOT %s] Slot %d: empty" % [ship.name, i])

	if debug_consumables_verbose:
		print("[BOT %s] Found slots - repair_party: %d, damage_control: %d" % [ship.name, repair_party_slot, damage_control_slot])

	# Evaluate Damage Control usage
	if damage_control_slot >= 0:
		var damage_control_item = consumable_manager.equipped_consumables[damage_control_slot]
		var can_use_dc = consumable_manager.can_use_item(damage_control_item)
		if debug_consumables_verbose:
			print("[BOT %s] Damage Control can_use: %s" % [ship.name, can_use_dc])
		if can_use_dc:
			var should_use_damage_control = false

			# Use damage control if we have fires
			var use_reason: String = ""
			if fire_count >= damage_control_min_fires:
				# More aggressive usage when HP is low
				if hp_ratio <= damage_control_hp_threshold:
					should_use_damage_control = true
					use_reason = "low HP (%.0f%%) with %d fire(s) - prioritizing survival" % [hp_ratio * 100, fire_count]
				# At higher HP, wait for multiple fires to be efficient
				elif fire_count >= 2:
					should_use_damage_control = true
					use_reason = "multiple fires (%d) - maximizing value" % fire_count

			if should_use_damage_control:
				if debug_consumables:
					print("[BOT %s] Using DAMAGE CONTROL - Reason: %s" % [ship.name, use_reason])
				consumable_manager.use_consumable(damage_control_slot)
				return  # Only use one consumable per check

	# Evaluate Repair Party usage
	if repair_party_slot >= 0:
		var repair_party_item = consumable_manager.equipped_consumables[repair_party_slot]
		var can_use_rp = consumable_manager.can_use_item(repair_party_item)
		if debug_consumables_verbose:
			print("[BOT %s] Repair Party can_use: %s, hp_ratio: %.2f, threshold: %.2f" % [ship.name, can_use_rp, hp_ratio, repair_party_hp_threshold])
		if can_use_rp:
			var should_use_repair_party = false

			# Check if repair party would actually heal (already checked by can_use)
			var missing_hp_ratio = 1.0 - hp_ratio
			var use_reason: String = ""

			# Critical HP - always use if available
			if hp_ratio <= repair_party_critical_threshold:
				should_use_repair_party = true
				use_reason = "CRITICAL HP (%.0f%%) - emergency heal" % [hp_ratio * 100]
			# Below threshold - use if we're missing significant HP
			elif hp_ratio <= repair_party_hp_threshold:
				# Only use if we'd get good value from the heal (missing at least 15% HP)
				if missing_hp_ratio >= 0.15:
					should_use_repair_party = true
					use_reason = "low HP (%.0f%%), missing %.0f%% - good heal value" % [hp_ratio * 100, missing_hp_ratio * 100]
			# Higher HP - be conservative, save for emergencies
			# Only use if we have plenty of charges and are missing decent HP
			elif repair_party_item.current_stack >= 3 and missing_hp_ratio >= 0.25:
				should_use_repair_party = true
				use_reason = "HP at %.0f%%, have %d charges remaining - using surplus" % [hp_ratio * 100, repair_party_item.current_stack]

			if should_use_repair_party:
				if debug_consumables:
					print("[BOT %s] Using REPAIR PARTY - Reason: %s" % [ship.name, use_reason])
				consumable_manager.use_consumable(repair_party_slot)
				return

func scan_for_targets():
	var closest_visible_ship: Ship = null
	var closest_visible_distance = attack_range
	var closest_any_ship: Ship = null
	var closest_any_distance = attack_range

	# Find closest enemy ship
	var space_state = ship.get_world_3d().direct_space_state
	var server_node = ship.get_node("/root/Server")

	if !server_node:
		return

	for player_data in server_node.players.values():
		var enemy_ship: Ship = player_data[0]
		if enemy_ship == ship or !is_instance_valid(enemy_ship):
			continue

		# Check if it's an enemy
		if enemy_ship.team.team_id == ship.team.team_id:
			continue

		# Check if it's alive
		if enemy_ship.health_controller.current_hp <= 0 or !enemy_ship.visible_to_enemy:
			continue

		var distance = ship.global_position.distance_to(enemy_ship.global_position)

		# Track closest ship regardless of visibility
		if distance < closest_any_distance:
			closest_any_ship = enemy_ship
			closest_any_distance = distance

		# If ship is visible to enemy, prioritize it
		if enemy_ship.visible_to_enemy:
			if distance < closest_visible_distance:
				closest_visible_ship = enemy_ship
				closest_visible_distance = distance

	# Priority: visible ship first, then any ship if no visible ones
	if closest_visible_ship:
		target_ship = closest_visible_ship
	elif closest_any_ship:
		# For non-visible ships, check line of sight to decide navigation approach
		ray_query.from = ship.global_position + Vector3(0, 1, 0)
		ray_query.to = closest_any_ship.global_position + Vector3(0, 1, 0)

		var _collision = space_state.intersect_ray(ray_query)
		target_ship = closest_any_ship  # Set target regardless of line of sight for navigation
	else:
		target_ship = null

func attack_behavior(_delta: float):
	if !target_ship or !is_instance_valid(target_ship):
		return

	var distance_to_target = ship.global_position.distance_to(target_ship.global_position)
	var target_position = target_ship.global_position

	# Check if target is visible and if we have line of sight
	#var has_line_of_sight = false
	var space_state = ship.get_world_3d().direct_space_state

	ray_query.from = ship.global_position + Vector3(0, 1, 0)
	ray_query.to = target_position + Vector3(0, 1, 0)
	var _collision = space_state.intersect_ray(ray_query)
	#has_line_of_sight = collision.is_empty()

	# Calculate desired position relative to target
	var angle_to_target = atan2(target_position.z - ship.global_position.z, target_position.x - ship.global_position.x)

	var base_heading = angle_to_target

	# Update engagement range dynamically
	_update_engagement_range()

	# If target is visible and we're in good range, use tactical maneuvering
	if target_ship.visible_to_enemy:
		# Try to maintain engagement range (just outside concealment)
		if distance_to_target > engagement_range + 500:
			# Move closer
			base_heading = angle_to_target
		elif distance_to_target < engagement_range - 500:
			# Move away (stay at edge of concealment)
			base_heading = angle_to_target + PI
		else:
			# Circle around target at engagement range
			base_heading = angle_to_target + PI/2
	else:
		# Target is obscured or not visible - navigate directly towards it
		base_heading = angle_to_target

	# Apply collision avoidance to the base heading
	desired_heading = apply_collision_avoidance(base_heading)

	# Fire guns if target is visible, in range, and we have line of sight
	# Destroyers have additional restriction - must be within concealment
	if target_ship.visible_to_enemy and distance_to_target < attack_range:
		fire_at_target()

	# Handle torpedo aiming and firing (runs every frame for smooth turret tracking)
	update_torpedo_aim()

	# Attempt to fire torpedoes periodically if we have a valid solution
	torpedo_fire_timer += _delta
	if torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes()

func patrol_behavior(_delta: float):
	# Strategic navigation system
	var ship_pos = ship.global_position
	var target_position: Vector3

	# Check if we've reached the opposite side yet
	if not opposite_side_reached:
		# First phase: Move towards opposite side of the map
		target_position = get_opposite_side_target()

		# Check if we've reached the opposite side
		if has_reached_opposite_side():
			opposite_side_reached = true
			has_patrol_target = false  # Reset patrol target when transitioning phases
			if debug_draw and ship.get_tree():
				BattleCamera.draw_debug_sphere(ship.get_tree().root, ship_pos + Vector3(0, 20, 0), 150, Color.GREEN, 2.0)
	else:
		# Second phase: Patrol within patrol radius around center
		# Check if we need a new patrol target or if we've reached the current one
		if not has_patrol_target or ship_pos.distance_to(current_patrol_target) <= patrol_point_reach_distance:
			# Generate new patrol target
			current_patrol_target = get_patrol_target()
			has_patrol_target = true

			if debug_draw and ship.get_tree():
				# Show new patrol target with a distinct marker
				BattleCamera.draw_debug_sphere(ship.get_tree().root, current_patrol_target + Vector3(0, 10, 0), 80, Color.WHITE, 1.0)

		target_position = current_patrol_target

		# If we're outside patrol zone, head back towards center and reset patrol target
		if not is_in_patrol_zone():
			var direction_to_center = (map_center - ship_pos).normalized()
			target_position = map_center + direction_to_center * (patrol_radius * 0.7)
			has_patrol_target = false  # Force new patrol target once back in zone

	# Calculate heading towards target position
	var direction_to_target = target_position - ship_pos
	var target_heading = atan2(direction_to_target.z, direction_to_target.x)

	# Apply collision avoidance to the strategic heading
	desired_heading = apply_collision_avoidance(target_heading)

	# Debug visualization for strategic navigation
	if debug_draw and ship.get_tree():
		var debug_color = Color.CYAN if not opposite_side_reached else Color.MAGENTA
		BattleCamera.draw_debug_sphere(ship.get_tree().root, target_position, 100, debug_color, 0.1)

func fire_at_target():
	if !target_ship or !is_instance_valid(target_ship):
		return

	# Destroyers should only shoot when within concealment range
	if !can_destroyer_shoot(target_ship):
		return

	# Get artillery controller and set aim then fire
	var artillery = ship.get_node_or_null("Modules/ArtilleryController") as ArtilleryController
	if artillery:
		# Select appropriate shell type
		var desired_shell = select_shell_for_target(target_ship)
		if artillery.shell_index != desired_shell:
			artillery.select_shell(desired_shell)

		# Get aim offset based on target type
		var aim_offset = get_aim_offset_for_target(target_ship)
		var adjusted_target_pos = target_ship.global_position + aim_offset

		var target_position = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(
			ship.global_position,
			adjusted_target_pos,
			target_ship.linear_velocity / ProjectileManager.shell_time_multiplier,
			artillery.get_shell_params().speed,
			artillery.get_shell_params().drag
		)[2]

		if target_position != null:
			# Set aim input like player controller does
			artillery.set_aim_input(target_position)
			# Fire guns
			artillery.fire_next_ready()

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

func update_torpedo_aim():
	has_valid_torpedo_solution = false

	if !target_ship or !is_instance_valid(target_ship):
		return

	# Get torpedo controller
	var torpedo_controller = ship.torpedo_controller
	if !torpedo_controller:
		return

	# Check distance - torpedoes have limited range
	var distance_to_target = ship.global_position.distance_to(target_ship.global_position)
	var torpedo_range = torpedo_controller.get_params()._range

	if distance_to_target > torpedo_range * 0.9:  # Use 90% of max range for safety margin
		return

	# Calculate interception point using the quadratic formula
	# Torpedo speed is multiplied by 3.0 (TORPEDO_SPEED_MULTIPLIER from TorpedoManager)
	var torpedo_speed = torpedo_controller.get_torp_params().speed * 3.0
	torpedo_target_position = calculate_interception_point(
		ship.global_position,
		target_ship.global_position,
		target_ship.linear_velocity,
		torpedo_speed
	)

	# Verify the interception point is within range
	var interception_distance = ship.global_position.distance_to(torpedo_target_position)
	if interception_distance > torpedo_range * 0.95:
		return

	# Check if land is in the way of the torpedo path
	if is_land_blocking_torpedo_path(ship.global_position, torpedo_target_position):
		return

	# Check if friendly ships would be hit by the torpedo
	# Pass the actual torpedo speed (already multiplied above)
	if would_hit_friendly_ship(ship.global_position, torpedo_target_position, torpedo_speed):
		return

	has_valid_torpedo_solution = true

	# Set aim input every frame for smooth turret tracking
	torpedo_controller.set_aim_input(torpedo_target_position)

func try_fire_torpedoes():
	if !has_valid_torpedo_solution:
		return

	if !target_ship or !is_instance_valid(target_ship):
		return

	# Get torpedo controller
	var torpedo_controller = ship.torpedo_controller
	if !torpedo_controller:
		return

	# Check if any launcher is ready and aimed
	for launcher in torpedo_controller.launchers:
		if launcher.reload >= 1.0 and launcher.can_fire and !launcher.disabled:
			torpedo_controller.fire_next_ready()
			print("Firing torpedo from launcher:", launcher)
			return

func is_land_blocking_torpedo_path(from_pos: Vector3, to_pos: Vector3) -> bool:

	var space_state = ship.get_world_3d().direct_space_state
	var ray = PhysicsRayQueryParameters3D.new()
	ray.from = from_pos + (to_pos - from_pos).normalized() * 30.0
	ray.from.y = 1
	ray.to = to_pos
	ray.to.y = 1

	var collision = space_state.intersect_ray(ray)

	if !collision.is_empty():
		return true

	# if !ship:
	# 	return false

	# var space_state = ship.get_world_3d().direct_space_state

	# # Torpedoes travel at water level, so we check along the surface
	# var water_level_y = 0.5  # Slightly above water surface for detection

	# # Check multiple points along the path
	# for i in range(torpedo_land_check_segments + 1):
	# 	var t = float(i) / float(torpedo_land_check_segments)
	# 	var check_pos = from_pos.lerp(to_pos, t)
	# 	check_pos.y = water_level_y

	# 	# Cast a ray downward to check for land at this position
	# 	ray_query.from = check_pos + Vector3(0, 50, 0)  # Start from above
	# 	ray_query.to = check_pos + Vector3(0, -10, 0)   # Go below water level

	# 	var collision = space_state.intersect_ray(ray_query)

	# 	if !collision.is_empty():
	# 		# If we hit something above water level, it's likely land
	# 		if collision.position.y > -2.0:
	# 			# Debug visualization
	# 			if debug_draw and ship.get_tree():
	# 				BattleCamera.draw_debug_sphere(ship.get_tree().root, collision.position, 30, Color.RED, 0.5)
	# 			return true

	# # Also do a direct horizontal ray check at water level to catch islands
	# var start_pos = Vector3(from_pos.x, water_level_y, from_pos.z)
	# var end_pos = Vector3(to_pos.x, water_level_y, to_pos.z)

	# ray_query.from = start_pos
	# ray_query.to = end_pos

	# var direct_collision = space_state.intersect_ray(ray_query)

	# if !direct_collision.is_empty():
	# 	# Check if collision point is between us and target (not past target)
	# 	var dist_to_collision = from_pos.distance_to(direct_collision.position)
	# 	var dist_to_target = from_pos.distance_to(to_pos)

	# 	if dist_to_collision < dist_to_target:
	# 		if debug_draw and ship.get_tree():
	# 			BattleCamera.draw_debug_sphere(ship.get_tree().root, direct_collision.position, 50, Color.ORANGE, 0.5)
	# 		return true

	return false

func would_hit_friendly_ship(from_pos: Vector3, to_pos: Vector3, torpedo_speed: float) -> bool:
	# Check if any friendly ship within range would be hit by the torpedo
	if !ship:
		return false

	var server_node = ship.get_node_or_null("/root/Server")
	if !server_node:
		return false

	var torpedo_direction = (to_pos - from_pos).normalized()
	var torpedo_distance = from_pos.distance_to(to_pos)
	var time_to_target = torpedo_distance / torpedo_speed

	for player_data in server_node.players.values():
		var other_ship: Ship = player_data[0]

		# Skip self and invalid ships
		if other_ship == ship or !is_instance_valid(other_ship):
			continue

		# Only check friendly ships
		if other_ship.team.team_id != ship.team.team_id:
			continue

		# Skip dead ships
		if other_ship.health_controller.current_hp <= 0:
			continue

		# Only check ships within the friendly fire check radius
		var distance_to_ally = ship.global_position.distance_to(other_ship.global_position)
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
				# Debug visualization
				if debug_draw and ship.get_tree():
					BattleCamera.draw_debug_sphere(ship.get_tree().root, torpedo_pos, 40, Color.YELLOW, 0.5)
					BattleCamera.draw_debug_sphere(ship.get_tree().root, ally_pos, 40, Color.GREEN, 0.5)
				return true

	return false

func apply_collision_avoidance(base_heading: float) -> float:
	if !ship:
		return base_heading

	var space_state = ship.get_world_3d().direct_space_state
	var ship_position = ship.global_position
	var modified_heading = base_heading

	# Check for obstacles in multiple directions around the intended heading
	var obstacles_detected = false
	var avoidance_vector = Vector2.ZERO

	for i in range(collision_check_rays):
		# Calculate ray direction spread around base heading
		var angle_offset = (float(i) / float(collision_check_rays - 1) - 0.5) * collision_ray_spread
		var ray_heading = base_heading + angle_offset

		# Create ray direction
		var ray_direction = Vector3(cos(ray_heading), 0, sin(ray_heading))
		var ray_start = ship_position + Vector3(0, 0, 0)  # Slightly above water level
		var ray_end = ray_start + ray_direction * collision_avoidance_distance

		# Cast ray for all collision objects (terrain and ships)
		ray_query.from = ray_start
		ray_query.to = ray_end

		var collision = space_state.intersect_ray(ray_query)
		if not collision.is_empty():
			var collision_object = collision.collider

			# Determine if this is a ship (moving object) or terrain (static)
			var is_ship_collision = collision_object is RigidBody3D and collision_object != ship

			# During recovery states, significantly reduce ship avoidance to prioritize escaping land
			var ship_avoidance_multiplier = normal_ship_avoidance_factor
			if recovery_state != RecoveryState.NORMAL and is_ship_collision:
				ship_avoidance_multiplier = recovery_ship_avoidance_factor
				if debug_draw:
					print("Recovery mode - reducing ship avoidance")

			obstacles_detected = true
			var collision_point = collision.position
			var distance_to_obstacle = ship_position.distance_to(collision_point)

			# Try to cast as RigidBody to get velocity information for moving objects
			var obstacle_velocity = Vector3.ZERO
			if collision_object is RigidBody3D:
				var rigid_body = collision_object as RigidBody3D
				obstacle_velocity = rigid_body.linear_velocity

				# For moving objects, predict where they'll be and adjust avoidance accordingly
				if obstacle_velocity.length() > 1.0:  # Moving object threshold
					var time_to_collision = distance_to_obstacle / 20.0  # Approximate time estimate
					var predicted_position = collision_point + obstacle_velocity * time_to_collision
					collision_point = predicted_position

					# Debug visualization for moving objects
					if debug_draw and ship.get_tree():
						BattleCamera.draw_debug_sphere(ship.get_tree().root, predicted_position, 70, Color.RED, 0.1)

			# Debug visualization for all obstacles
			if debug_draw and ship.get_tree():
				var debug_color = Color.YELLOW if obstacle_velocity.length() < 1.0 else Color.ORANGE
				if is_ship_collision and recovery_state != RecoveryState.NORMAL:
					debug_color = Color.GRAY  # Show reduced priority obstacles as gray
				BattleCamera.draw_debug_sphere(ship.get_tree().root, collision.position, 50, debug_color, 0.1)

			# Calculate avoidance direction (perpendicular to obstacle direction)
			var to_obstacle = Vector2(collision_point.x - ship_position.x, collision_point.z - ship_position.z).normalized()
			var avoidance_strength = 1.0 - (distance_to_obstacle / collision_avoidance_distance)
			avoidance_strength = max(avoidance_strength, 0.0) * avoidance_turn_strength

			# Apply ship avoidance reduction during recovery
			avoidance_strength *= ship_avoidance_multiplier

			# Add perpendicular avoidance force (turn away from obstacle)
			var perpendicular = Vector2(-to_obstacle.y, to_obstacle.x)  # 90 degree rotation
			# Choose direction that's closer to our current ship heading
			var ship_heading = get_ship_heading()
			var current_dir = Vector2(cos(ship_heading), sin(ship_heading))
			if perpendicular.dot(current_dir) < 0:
				perpendicular = -perpendicular

			avoidance_vector += perpendicular * avoidance_strength

	# Additional lateral obstacle detection - check sides even when moving forward
	var lateral_avoidance = check_lateral_obstacles()
	avoidance_vector += lateral_avoidance

	# Apply avoidance if obstacles detected
	if obstacles_detected or lateral_avoidance.length() > 0.1:
		var base_direction = Vector2(cos(base_heading), sin(base_heading))
		var combined_direction = (base_direction + avoidance_vector).normalized()
		modified_heading = atan2(combined_direction.y, combined_direction.x)

		# Debug visualization for final heading
		if debug_draw and ship.get_tree():
			var final_dir = Vector3(cos(modified_heading), 0, sin(modified_heading))
			var final_end = ship_position + final_dir * 1000
			BattleCamera.draw_debug_sphere(ship.get_tree().root, final_end, 100, Color.BLUE, 0.1)

	# Emergency collision prevention - check directly ahead
	var emergency_check = check_emergency_collision()
	if emergency_check.collision_detected:
		# Emergency turn - pick the direction with more clearance
		var left_clear = check_clearance(base_heading - PI/2)
		var right_clear = check_clearance(base_heading + PI/2)

		if left_clear > right_clear:
			modified_heading = base_heading - PI/2
		else:
			modified_heading = base_heading + PI/2

		# Debug emergency avoidance
		if debug_draw and ship.get_tree():
			BattleCamera.draw_debug_sphere(ship.get_tree().root, ship_position + Vector3(0, 15, 0), 100, Color.MAGENTA, 0.1)

	return modified_heading

func check_lateral_obstacles() -> Vector2:
	"""Check for obstacles on the sides of the ship and return avoidance vector."""
	if !ship:
		return Vector2.ZERO

	var space_state = ship.get_world_3d().direct_space_state
	var ship_position = ship.global_position
	var ship_heading = get_ship_heading()
	var avoidance = Vector2.ZERO

	# During recovery, we only care about terrain, not other ships
	var in_recovery = recovery_state != RecoveryState.NORMAL

	# Check left side
	var left_heading = ship_heading - PI/2
	var left_direction = Vector3(cos(left_heading), 0, sin(left_heading))
	ray_query.from = ship_position
	ray_query.to = ship_position + left_direction * lateral_check_distance

	var left_collision = space_state.intersect_ray(ray_query)
	if not left_collision.is_empty():
		var is_ship = left_collision.collider is RigidBody3D and left_collision.collider != ship
		var avoidance_multiplier = recovery_ship_avoidance_factor if (in_recovery and is_ship) else normal_ship_avoidance_factor

		var distance = ship_position.distance_to(left_collision.position)
		var strength = (1.0 - distance / lateral_check_distance) * lateral_avoidance_strength * avoidance_multiplier
		# Push away from left obstacle (turn right)
		avoidance += Vector2(cos(ship_heading + PI/2), sin(ship_heading + PI/2)) * strength

		if debug_draw and ship.get_tree():
			var color = Color.GRAY if (in_recovery and is_ship) else Color.CYAN
			BattleCamera.draw_debug_sphere(ship.get_tree().root, left_collision.position, 30, color, 0.1)

	# Check right side
	var right_heading = ship_heading + PI/2
	var right_direction = Vector3(cos(right_heading), 0, sin(right_heading))
	ray_query.from = ship_position
	ray_query.to = ship_position + right_direction * lateral_check_distance

	var right_collision = space_state.intersect_ray(ray_query)
	if not right_collision.is_empty():
		var is_ship = right_collision.collider is RigidBody3D and right_collision.collider != ship
		var avoidance_multiplier = recovery_ship_avoidance_factor if (in_recovery and is_ship) else normal_ship_avoidance_factor

		var distance = ship_position.distance_to(right_collision.position)
		var strength = (1.0 - distance / lateral_check_distance) * lateral_avoidance_strength * avoidance_multiplier
		# Push away from right obstacle (turn left)
		avoidance += Vector2(cos(ship_heading - PI/2), sin(ship_heading - PI/2)) * strength

		if debug_draw and ship.get_tree():
			var color = Color.GRAY if (in_recovery and is_ship) else Color.CYAN
			BattleCamera.draw_debug_sphere(ship.get_tree().root, right_collision.position, 30, color, 0.1)

	# Check diagonal front-left and front-right for early warning
	var diag_distance = lateral_check_distance * 1.5

	var front_left_heading = ship_heading - PI/4
	var front_left_dir = Vector3(cos(front_left_heading), 0, sin(front_left_heading))
	ray_query.from = ship_position
	ray_query.to = ship_position + front_left_dir * diag_distance

	var front_left_collision = space_state.intersect_ray(ray_query)
	if not front_left_collision.is_empty():
		var is_ship = front_left_collision.collider is RigidBody3D and front_left_collision.collider != ship
		var avoidance_multiplier = recovery_ship_avoidance_factor if (in_recovery and is_ship) else normal_ship_avoidance_factor

		var distance = ship_position.distance_to(front_left_collision.position)
		var strength = (1.0 - distance / diag_distance) * lateral_avoidance_strength * 0.7 * avoidance_multiplier
		avoidance += Vector2(cos(ship_heading + PI/4), sin(ship_heading + PI/4)) * strength

	var front_right_heading = ship_heading + PI/4
	var front_right_dir = Vector3(cos(front_right_heading), 0, sin(front_right_heading))
	ray_query.from = ship_position
	ray_query.to = ship_position + front_right_dir * diag_distance

	var front_right_collision = space_state.intersect_ray(ray_query)
	if not front_right_collision.is_empty():
		var is_ship = front_right_collision.collider is RigidBody3D and front_right_collision.collider != ship
		var avoidance_multiplier = recovery_ship_avoidance_factor if (in_recovery and is_ship) else normal_ship_avoidance_factor

		var distance = ship_position.distance_to(front_right_collision.position)
		var strength = (1.0 - distance / diag_distance) * lateral_avoidance_strength * 0.7 * avoidance_multiplier
		avoidance += Vector2(cos(ship_heading - PI/4), sin(ship_heading - PI/4)) * strength

	return avoidance

func check_clearance_terrain_only(heading: float) -> float:
	"""Check clearance in a direction, ignoring other ships (only terrain/static obstacles)."""
	if !ship:
		return 0.0

	var space_state = ship.get_world_3d().direct_space_state
	var ship_position = ship.global_position
	var direction = Vector3(cos(heading), 0, sin(heading))

	ray_query.from = ship_position + Vector3(0, 5, 0)
	ray_query.to = ship_position + direction * collision_avoidance_distance + Vector3(0, 5, 0)

	var collision = space_state.intersect_ray(ray_query)
	if collision.is_empty():
		return collision_avoidance_distance
	else:
		var collision_object = collision.collider
		# If it's a ship (RigidBody3D that's not us), ignore it and return full clearance
		if collision_object is RigidBody3D and collision_object != ship:
			return collision_avoidance_distance
		# It's terrain - return actual distance
		return ship_position.distance_to(collision.position)

func check_emergency_collision() -> Dictionary:
	if !ship:
		return {"collision_detected": false, "distance": 0.0}

	var space_state = ship.get_world_3d().direct_space_state
	var ship_position = ship.global_position
	# Use ship's actual forward direction (-Z axis)
	var forward_direction = -ship.global_transform.basis.z

	# Check straight ahead for emergency collision
	ray_query.from = ship_position + Vector3(0, 5, 0)
	ray_query.to = ship_position + forward_direction * emergency_stop_distance + Vector3(0, 5, 0)

	var collision = space_state.intersect_ray(ray_query)
	if not collision.is_empty():
		var collision_object = collision.collider

		# During recovery, ignore other ships for emergency collision detection
		# We need to focus on escaping terrain
		var is_ship_collision = collision_object is RigidBody3D and collision_object != ship
		if recovery_state != RecoveryState.NORMAL and is_ship_collision:
			return {"collision_detected": false, "distance": emergency_stop_distance}

		# Skip collision with our own ship or friendly ships
		#if collision_object == ship:
			#return {"collision_detected": false, "distance": emergency_stop_distance}
		#if collision_object.has_method("get") and collision_object.has_property("team"):
			#if collision_object.team and ship.team and collision_object.team.team_id == ship.team.team_id:
				#return {"collision_detected": false, "distance": emergency_stop_distance}

		var distance = ship_position.distance_to(collision.position)

		# Handle moving objects for emergency avoidance
		if collision_object is RigidBody3D:
			var rigid_body = collision_object as RigidBody3D
			var obstacle_velocity = rigid_body.linear_velocity

			# If object is moving towards us, treat it as more urgent
			if obstacle_velocity.length() > 1.0:
				var relative_velocity = obstacle_velocity.dot(-forward_direction)
				if relative_velocity > 0:  # Moving towards us
					distance *= 0.5  # Treat as closer for more aggressive avoidance

		return {"collision_detected": true, "distance": distance}

	return {"collision_detected": false, "distance": emergency_stop_distance}

func check_clearance(heading: float) -> float:
	if !ship:
		return 0.0

	var space_state = ship.get_world_3d().direct_space_state
	var ship_position = ship.global_position
	var direction = Vector3(cos(heading), 0, sin(heading))

	ray_query.from = ship_position + Vector3(0, 0, 0)
	ray_query.to = ship_position + direction * collision_avoidance_distance + Vector3(0, 0, 0)

	var collision = space_state.intersect_ray(ray_query)
	if collision.is_empty():
		return collision_avoidance_distance
	else:
		# var collision_object = collision.collider

		# Skip collision with our own ship or friendly ships
		# if collision_object == ship:
		# 	return collision_avoidance_distance
		# if collision_object.has_method("get") and collision_object.has_property("team"):
		# 	if collision_object.team and ship.team and collision_object.team.team_id == ship.team.team_id:
		# 		return collision_avoidance_distance

		return ship_position.distance_to(collision.position)

func apply_ship_controls(_delta: float):
	if !ship:
		return

	# Get ship's actual current heading from its orientation
	var ship_heading = get_ship_heading()

	# Calculate angle difference between desired and actual heading
	var angle_diff = desired_heading - ship_heading
	# Normalize angle difference to [-PI, PI]
	while angle_diff > PI:
		angle_diff -= TAU
	while angle_diff < -PI:
		angle_diff += TAU

	# Check for emergency collision and adjust throttle
	var emergency_check = check_emergency_collision()
	var throttle = 4  # Medium speed (0-4 scale)

	# Handle collision recovery state - early return with dedicated handling
	if recovery_state == RecoveryState.EMERGENCY_REVERSING:
		# Full reverse during recovery, keep rudder centered for predictable movement
		_send_movement_input([float(-1), 0.0])
		return
	elif recovery_state == RecoveryState.RECOVERY_TURNING:
		# Slow speed while turning to escape with aggressive rudder
		_send_movement_input([float(1), clamp(angle_diff * 3.0, -1.0, 1.0)])
		return
	elif recovery_state == RecoveryState.STUCK_ESCAPE:
		# Handle stuck escape - check if we need to reverse or turn
		var front_clearance = check_clearance(ship_heading)
		var back_clearance = check_clearance(ship_heading + PI)

		if front_clearance < min_emergency_stop_distance:
			# Can't go forward - reverse
			_send_movement_input([float(-1), clamp(angle_diff * 2.0, -1.0, 1.0)])
		elif back_clearance > front_clearance and front_clearance < emergency_stop_distance:
			# Better to reverse
			_send_movement_input([float(-1), clamp(angle_diff * 2.0, -1.0, 1.0)])
		else:
			# Try to move forward while turning
			_send_movement_input([float(2), clamp(angle_diff * 3.0, -1.0, 1.0)])
		return

	if emergency_check.collision_detected:
		# Check if it's terrain or a ship
		var terrain_clearance = check_clearance_terrain_only(ship_heading)
		var is_terrain_emergency = terrain_clearance < emergency_stop_distance

		# Emergency measures based on distance
		if emergency_check.distance < emergency_stop_distance * 0.3:
			if is_terrain_emergency:
				# Very close to terrain - enter collision recovery mode
				enter_collision_recovery()
				throttle = -1
			else:
				# Just a ship - slow down but don't reverse aggressively
				throttle = 0
		elif emergency_check.distance < emergency_stop_distance * 0.5:
			if is_terrain_emergency:
				# Close to terrain - full reverse
				throttle = -1
			else:
				# Ship in the way - just stop
				throttle = 0
		elif emergency_check.distance < emergency_stop_distance * 0.75:
			# Close - stop engines
			throttle = 0
		else:
			# Moderate distance - slow speed
			throttle = 1

	# Calculate rudder input to turn towards desired heading
	var rudder = 0.0
	var heading_tolerance = 0.05  # About 3 degrees tolerance

	if abs(angle_diff) > heading_tolerance:
		# Calculate rudder based on angle difference and turn aggressively
		# Normalize the rudder input between -1.0 and 1.0
		rudder = clamp(angle_diff * 2.0, -1.0, 1.0)  # Scale factor of 2.0 for responsive turning

		# Increase rudder response during emergency avoidance
		if emergency_check.collision_detected:
			rudder = clamp(angle_diff * 3.0, -1.0, 1.0)  # Even more aggressive during emergency

	# Send movement input to ship
	var movement_input = [float(throttle), rudder]
	_send_movement_input(movement_input)

func _send_movement_input(movement_input: Array) -> void:
	"""Helper function to send movement input to ship's movement controller."""
	if ship.has_method("get_node") and ship.get_node_or_null("Modules"):
		var movement_controller = ship.get_node_or_null("Modules/MovementController")
		if movement_controller and movement_controller.has_method("set_movement_input"):
			movement_controller.set_movement_input(movement_input)
		elif ship.has_node("movement_controller"):
			ship.movement_controller.set_movement_input(movement_input)
