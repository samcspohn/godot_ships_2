# src/ship/bot_controller.gd
extends Node

class_name BotController

var ship: Ship
var target_ship: Ship = null
var target_scan_timer: float = 0.0
var target_scan_interval: float = 2.0
var attack_range: float = 100000.0
var preferred_distance: float = 10000.0

# Movement state
var desired_heading: float = 0.0
var turn_speed: float = 0.5

# Collision avoidance parameters
var collision_avoidance_distance: float = 2000.0  # Distance to start avoiding obstacles
var collision_check_rays: int = 12  # Number of rays to cast for collision detection
var collision_ray_spread: float = TAU  # 360 degrees spread for collision rays (full circle)
var emergency_stop_distance: float = 500.0  # Distance to emergency stop
var avoidance_turn_strength: float = 2.0  # How strong avoidance turning should be
var debug_draw: bool = true  # Enable debug visualization

# Strategic navigation parameters
var map_center: Vector3 = Vector3(0, 0, 0)  # Center of the map
var patrol_radius: float = 8000.0  # 8km patrol circle around center
var opposite_side_reached: bool = false  # Whether bot has reached opposite side
var initial_approach_distance: float = 2000.0  # How close to get to opposite side before patrolling

# Patrol point management
var current_patrol_target: Vector3 = Vector3.ZERO  # Current patrol destination
var patrol_point_reach_distance: float = 500.0  # Distance to reach patrol point before selecting new one
var has_patrol_target: bool = false  # Whether we have a valid patrol target

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
	else:
		desired_heading = randf() * TAU

	ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collision_mask = 1 | 1 << 2 # Check for terrain and ships
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	ray_query.hit_from_inside = false

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
	
	if !multiplayer.is_server():
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
	var collision = space_state.intersect_ray(ray_query)
	#has_line_of_sight = collision.is_empty()
	
	# Calculate desired position relative to target
	var angle_to_target = atan2(target_position.z - ship.global_position.z, target_position.x - ship.global_position.x)
	
	var base_heading = angle_to_target
	
	# If target is visible and we're in good range, use tactical maneuvering
	if target_ship.visible_to_enemy:
		# Try to maintain preferred distance with tactical movement
		if distance_to_target > preferred_distance + 500:
			# Move closer
			base_heading = angle_to_target
		elif distance_to_target < preferred_distance - 500:
			# Move away
			base_heading = angle_to_target + PI
		else:
			# Circle around target
			base_heading = angle_to_target + PI/2
	else:
		# Target is obscured or not visible - navigate directly towards it
		base_heading = angle_to_target
	
	# Apply collision avoidance to the base heading
	desired_heading = apply_collision_avoidance(base_heading)
	
	# Fire guns if target is visible, in range, and we have line of sight
	if target_ship.visible_to_enemy and distance_to_target < attack_range:
		fire_at_target()

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
	
	# Get artillery controller and set aim then fire
	var artillery = ship.get_node_or_null("Modules/ArtilleryController") as ArtilleryController
	if artillery:
		var target_position = AnalyticalProjectileSystem.calculate_leading_launch_vector(
			ship.global_position,
			target_ship.global_position,
			target_ship.linear_velocity / ProjectileManager.shell_time_multiplier,
			artillery._my_gun_params.shell.speed,
			artillery._my_gun_params.shell.drag
		)[2]

		# Set aim input like player controller does
		if artillery.has_method("set_aim_input"):
			artillery.set_aim_input(target_position)
		# Fire guns
		if artillery.has_method("fire_next_ready_gun"):
			artillery.fire_next_ready_gun()

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
			
			# Skip collision with our own ship or friendly ships
			# if collision_object == ship:
			# 	continue
			#if collision_object.has_method("get") and collision_object.has_property("team"):
				#if collision_object.team and ship.team and collision_object.team.team_id == ship.team.team_id:
					#continue
			
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
				BattleCamera.draw_debug_sphere(ship.get_tree().root, collision.position, 50, debug_color, 0.1)
			
			# Calculate avoidance direction (perpendicular to obstacle direction)
			var to_obstacle = Vector2(collision_point.x - ship_position.x, collision_point.z - ship_position.z).normalized()
			var avoidance_strength = 1.0 - (distance_to_obstacle / collision_avoidance_distance)
			avoidance_strength = max(avoidance_strength, 0.0) * avoidance_turn_strength
			
			# Add perpendicular avoidance force (turn away from obstacle)
			var perpendicular = Vector2(-to_obstacle.y, to_obstacle.x)  # 90 degree rotation
			# Choose direction that's closer to our current ship heading
			var ship_heading = get_ship_heading()
			var current_dir = Vector2(cos(ship_heading), sin(ship_heading))
			if perpendicular.dot(current_dir) < 0:
				perpendicular = -perpendicular
			
			avoidance_vector += perpendicular * avoidance_strength
	
	# Apply avoidance if obstacles detected
	if obstacles_detected:
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
	
	if emergency_check.collision_detected:
		# Emergency measures based on distance
		if emergency_check.distance < emergency_stop_distance * 0.5:
			# Very close - full reverse
			throttle = -1
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
	
	# Send movement input to ship like player controller does
	var movement_input = [float(throttle), rudder]
	if ship.has_method("get_node") and ship.get_node_or_null("Modules"):
		var movement_controller = ship.get_node_or_null("Modules/MovementController")
		if movement_controller and movement_controller.has_method("set_movement_input"):
			movement_controller.set_movement_input(movement_input)
		elif ship.has_node("movement_controller"):
			ship.movement_controller.set_movement_input(movement_input)
