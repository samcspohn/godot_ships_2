extends Node3D

class_name ProjectilePhysics

const GRAVITY = -0.98

## Calculates the launch vector needed to hit a stationary target from a given position
## with a specified projectile speed
## Returns [launch_vector, time_to_target] or [null, -1] if no solution exists
static func calculate_launch_vector(start_pos: Vector3, target_pos: Vector3, projectile_speed: float) -> Array:
	# Calculate displacement vector
	var disp = target_pos - start_pos
	
	# Calculate horizontal distance and direction
	var horiz_dist = Vector2(disp.x, disp.z).length()
	var horiz_angle = atan2(disp.z, disp.x)
	
	# Physical parameters
	var g = abs(GRAVITY)
	var v = projectile_speed
	var h = disp.y
	
	# Calculate the discriminant from the quadratic equation derived from the physics
	var discriminant = pow(v, 4) - g * (g * pow(horiz_dist, 2) + 2 * h * pow(v, 2))
	
	if discriminant < 0:
		return [null, -1]  # No solution exists - target is out of range
	
	# Calculate the two possible elevation angles (high and low arc)
	var sqrt_disc = sqrt(discriminant)
	var angle1 = atan((pow(v, 2) + sqrt_disc) / (g * horiz_dist))
	var angle2 = atan((pow(v, 2) - sqrt_disc) / (g * horiz_dist))
	
	# Calculate flight times for both possible angles
	# A valid trajectory requires that cos(angle) != 0 (not firing straight up or down)
	var time1 = -1.0
	var time2 = -1.0
	
	if abs(cos(angle1)) > 0.001:  # Avoid division by zero
		time1 = horiz_dist / (v * cos(angle1))
		# Make sure this is a valid forward trajectory (not firing backward)
		if time1 <= 0:
			time1 = -1.0
	
	if abs(cos(angle2)) > 0.001:  # Avoid division by zero
		time2 = horiz_dist / (v * cos(angle2))
		# Make sure this is a valid forward trajectory (not firing backward)
		if time2 <= 0:
			time2 = -1.0
	
	# Choose the angle that results in the shortest time to target (shortest path)
	var elev_angle
	
	# If only one solution is valid, use that one
	if time1 < 0 and time2 >= 0:
		elev_angle = angle2
	elif time2 < 0 and time1 >= 0:
		elev_angle = angle1
	# If both are valid, use the one with shorter time
	elif time1 >= 0 and time2 >= 0:
		elev_angle = angle1 if time1 < time2 else angle2
	else:
		# No valid solution
		return [null, -1]
	
	# Calculate the initial velocity components
	var launch_vector = Vector3(
		v * cos(elev_angle) * cos(horiz_angle),
		v * sin(elev_angle),
		v * cos(elev_angle) * sin(horiz_angle)
	)
	
	# Calculate time to target
	var time_to_target = horiz_dist / (v * cos(elev_angle))
	
	return [launch_vector, time_to_target]

## Calculate projectile position at any time without simulation
static func calculate_position_at_time(start_pos: Vector3, launch_vector: Vector3, time: float) -> Vector3:
	return Vector3(
		start_pos.x + launch_vector.x * time,
		start_pos.y + launch_vector.y * time + 0.5 * GRAVITY * time * time,
		start_pos.z + launch_vector.z * time
	)

## Calculate launch vector to lead a moving target
## This uses the analytical solution with iterative refinement
static func calculate_leading_launch_vector(start_pos: Vector3, target_pos: Vector3, 
										  target_velocity: Vector3, projectile_speed: float) -> Array:
	# Start with the time it would take to hit the current position
	var result = calculate_launch_vector(start_pos, target_pos, projectile_speed)
	
	if result[0] == null:
		return [null, -1]  # No solution exists
	
	var time_estimate = result[1]
	
	# Refine the estimate a few times
	for i in range(3):  # Just a few iterations should be sufficient
		var predicted_pos = target_pos + target_velocity * time_estimate
		result = calculate_launch_vector(start_pos, predicted_pos, projectile_speed)
		
		if result[0] == null:
			return [null, -1]
		
		time_estimate = result[1]
	
	# Final calculation with the best time estimate
	var final_target_pos = target_pos + target_velocity * time_estimate
	return calculate_launch_vector(start_pos, final_target_pos, projectile_speed)

## Calculate the maximum horizontal range given a launch angle and projectile speed
## Returns the maximum distance the projectile can travel on flat ground
static func calculate_max_range_from_angle(angle: float, projectile_speed: float) -> float:
	var g = abs(GRAVITY)
	
	# Using the range formula: R = (v² * sin(2θ)) / g
	var max_range = (pow(projectile_speed, 2) * sin(2 * angle)) / g
	
	# Handle negative results (when firing downward)
	if max_range < 0:
		return 0.0
	
	return max_range

## Calculate the required launch angle to achieve a specific maximum range
## Returns the angle in radians or -1 if the range exceeds the physical limit
static func calculate_angle_from_max_range(max_range: float, projectile_speed: float) -> float:
	var g = abs(GRAVITY)
	
	# The theoretical maximum range is achieved at 45 degrees
	var theoretical_max = pow(projectile_speed, 2) / g
	
	# Check if the requested range is physically possible
	if max_range > theoretical_max or max_range < 0:
		return -1  # Impossible range
	
	# Using the formula: sin(2θ) = (R * g) / v²
	var sin_2theta = (max_range * g) / pow(projectile_speed, 2)
	
	# Calculate the angle (there are two solutions, we'll return the flatter trajectory)
	var angle = asin(sin_2theta) / 2
	
	return angle

## Example usage implementation
func _ready():
	# Example: Calculate launch vector for a stationary target
	var start = Vector3(0, 1, 0)
	var target = Vector3(10, 5, 5)
	var speed = 20.0
	
	var result = calculate_launch_vector(start, target, speed)
	if result[0] != null:
		print("Launch Vector: ", result[0])
		print("Time to Target: ", result[1])
		
		# Calculate position at midpoint
		var mid_time = result[1] / 2.0
		var mid_pos = calculate_position_at_time(start, result[0], mid_time)
		print("Position at midpoint: ", mid_pos)
	else:
		print("Target out of range!")
	
	# Example: Calculate launch vector for a moving target
	var target_vel = Vector3(2, 0, 1)  # Target moving right and forward
	var lead_result = calculate_leading_launch_vector(start, target, target_vel, speed)
	if lead_result[0] != null:
		print("Leading Vector: ", lead_result[0])
		print("Time to Moving Target: ", lead_result[1])
	else:
		print("Moving target cannot be hit!")
	
	# Example: Range calculations for upgrades
	var angle = PI/4  # 45 degrees for maximum range
	var max_range = calculate_max_range_from_angle(angle, speed)
	print("Maximum range at 45 degrees: ", max_range)
	
	# Calculate angle needed for a specific range
	var target_range = 30.0
	var needed_angle = calculate_angle_from_max_range(target_range, speed)
	if needed_angle >= 0:
		print("Angle needed for range of ", target_range, ": ", rad_to_deg(needed_angle), " degrees")
	else:
		print("Target range exceeds physical limits!")
