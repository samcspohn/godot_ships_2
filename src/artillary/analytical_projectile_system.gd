extends Node3D

class_name ProjectilePhysicsWithDrag


const GRAVITY = -9.8
const DEFAULT_DRAG_COEFFICIENT = 0.1 / 50.0 # Default drag coefficient

# Specific object drag coefficients - formula: (Cd × Area) / Mass
# German 380mm AP shell - recalculated with proper ballistic coefficient
# Diameter: 380mm, Mass: 800kg, Cd: 0.17 (streamlined artillery shell)
const SHELL_380MM_DRAG_COEFFICIENT = 0.0000241

# Ping Pong Ball
# Diameter: 40mm, Mass: 2.7g, Cd: 0.5 (sphere)
const PING_PONG_DRAG_COEFFICIENT = 0.233

# Bowling Ball
# Diameter: 218mm, Mass: 7kg, Cd: 0.5 (smooth sphere)
const BOWLING_BALL_DRAG_COEFFICIENT = 0.00267

# Target position tolerance (in meters)
const POSITION_TOLERANCE = 0.5
# Maximum iterations for binary search
const MAX_ITERATIONS = 16
# Angle adjustment step for binary search (in radians)
const INITIAL_ANGLE_STEP = 0.1
## Calculate the absolute maximum range possible with the given projectile speed,
## regardless of direction, and return [max_range, optimal_angle, flight_time]
static func calculate_absolute_max_range(projectile_speed: float, 
									   drag_coefficient) -> Array:
	# Initialize search parameters
	var min_range = 0.0
	var max_range = projectile_speed * projectile_speed / abs(GRAVITY) * 2.0  # Theoretical max without drag
	var best_range = 0.0
	var best_angle = 0.0
	var best_time = 0.0
	
	# Binary search to find maximum range
	# Increased iterations for better precision
	for i in range(MAX_ITERATIONS):
		var test_range = (min_range + max_range) / 2.0
		
		# Test range at various angles to ensure we find the best one
		var angles_to_test = [PI/6, PI/5, PI/4, PI/3]
		var valid_solution_found = false
		var best_solution_angle = 0.0
		var best_solution_time = 0.0
		
		for angle in angles_to_test:
			# Create a target position at the test range along the horizontal
			var target_pos = Vector3(test_range, 0, 0)
			
			# Use calculate_launch_vector to check if this range is achievable
			var result = calculate_launch_vector(Vector3.ZERO, target_pos, projectile_speed, drag_coefficient)
			
			if result[0] != null and result[1] > 0:
				valid_solution_found = true
				
				# Store the angle of this valid solution
				var velocity = result[0]
				var launch_angle = atan2(velocity.y, sqrt(velocity.x * velocity.x + velocity.z * velocity.z))
				
				# Update best angle and time for this range
				best_solution_angle = launch_angle
				best_solution_time = result[1]
				break
		
		# Adjust search range based on whether we found a solution
		if valid_solution_found:
			# This range is achievable, so update best values and try farther
			best_range = test_range
			best_angle = best_solution_angle
			best_time = best_solution_time
			min_range = test_range
		else:
			# This range is too far, try a shorter range
			max_range = test_range
		
		# Break if our search interval is small enough
		if max_range - min_range < 0.01:  # 1cm tolerance, increased precision
			break
	
	# Return the best range, angle, and flight time found
	return [best_range, best_angle, best_time]

## Calculate projectile velocity at any time with drag effects
## Returns the velocity vector at the specified time
static func calculate_velocity_at_time(launch_vector: Vector3, time: float,
									 drag_coefficient: float) -> Vector3:
	# Extract components
	var v0x = launch_vector.x
	var v0y = launch_vector.y
	var v0z = launch_vector.z
	var beta = drag_coefficient
	var g = abs(GRAVITY)
	
	var velocity = Vector3()
	
	# Calculate exponential decay due to drag
	var drag_decay = exp(-beta * time)
	
	# For x and z (horizontal components with drag)
	# vx = v₀x * e^(-βt)
	velocity.x = v0x * drag_decay
	velocity.z = v0z * drag_decay
	
	# For y (vertical component with drag and gravity)
	# vy = v₀y * e^(-βt) - (g/β) + (g/β) * e^(-βt)
	velocity.y = v0y * drag_decay - (g / beta) + (g / beta) * drag_decay
	
	return velocity

## Calculates shell position with endpoint precision guarantee
## This ensures the shell will hit exactly at the target position despite floating point errors
## Allows shell to continue past the target with the correct final velocity
## 
## Parameters:
## - start_pos: Starting position
## - target_pos: Target position (will hit exactly)
## - launch_vector: Initial velocity vector
## - current_time: Current time of simulation
## - total_flight_time: Total time to target
## - drag_coefficient: Drag coefficient
##
## Returns: The shell's position at current_time
static func calculate_precise_shell_position(start_pos: Vector3, target_pos: Vector3,
										   launch_vector: Vector3, current_time: float,
										   total_flight_time: float,
										   drag_coefficient: float) -> Vector3:
	# Safety check
	if total_flight_time <= 0.0:
		return start_pos
		
	# If we haven't reached the target yet, use physics with correction
	if current_time <= total_flight_time:
		# Calculate the physically expected position using drag physics
		var physics_position = calculate_position_at_time(start_pos, launch_vector, current_time, drag_coefficient)
		
		# If we're at the end time or very close to it, return exactly the target position
		if is_equal_approx(current_time, total_flight_time) or \
		   (total_flight_time - current_time) < 0.001:
			return target_pos
		
		# Generate a correction factor that smoothly transitions from 0 to 1
		# Starts small and increases toward the end of the flight
		# Using a smooth cubic function for natural-looking correction
		var t = current_time / total_flight_time
		var correction_strength = t * t * t # Smooth step function
		
		# Apply increasing correction as we get closer to the target
		# For artillery shells, the correction is very small until near the end
		var projected_error = target_pos - calculate_position_at_time(start_pos, launch_vector,
																	total_flight_time, drag_coefficient)
		# Scale error correction - minimal during most of flight, increasing toward end
		var corrected_position = physics_position + projected_error * correction_strength
		
		return corrected_position
	
	# If we're past the target, extrapolate from end position using end velocity
	else:
		# Calculate velocity at impact point
		var impact_velocity = calculate_velocity_at_time(launch_vector, total_flight_time, drag_coefficient)
		
		# Ensure we have exactly the target position at impact time
		var excess_time = current_time - total_flight_time
		
		# Linear extrapolation past the target using the final velocity
		# This is a simple approximation but works well for small time intervals past impact
		# For longer post-impact trajectories, you might want to calculate a new trajectory
		return target_pos + impact_velocity * excess_time


## Calculates the launch vector needed to hit a stationary target from a given position
## with drag effects considered
## Returns [launch_vector, time_to_target] or [null, -1] if no solution exists
static func calculate_launch_vector(start_pos: Vector3, target_pos: Vector3, projectile_speed: float,
								  drag_coefficient: float) -> Array:
	# Start with the non-drag physics as initial approximation
	var initial_result = ProjectilePhysics.calculate_launch_vector(start_pos, target_pos, projectile_speed)
	
	if initial_result[0] == null:
		return [null, -1] # Target is out of range even without drag
	
	var initial_vector = initial_result[0]
	var initial_time = initial_result[1]
	
	# Calculate direction to target (for azimuth angle)
	var disp = target_pos - start_pos
	var horiz_dist = Vector2(disp.x, disp.z).length()
	var horiz_dir = Vector2(disp.x, disp.z).normalized()
	
	# Extract elevation angle from initial vector
	var initial_speed_xz = Vector2(initial_vector.x, initial_vector.z).length()
	var elevation_angle = atan2(initial_vector.y, initial_speed_xz)
	
	# Binary search for the correct elevation angle with drag
	var min_angle = elevation_angle - PI / 4 # Lower bound
	var max_angle = elevation_angle + PI / 4 # Upper bound
	var error_distance = INF
	for i in range(MAX_ITERATIONS):
		var test_angle = (min_angle + max_angle) / 2.0
		
		# Create launch vector with current test angle
		var launch_vector = Vector3(
			projectile_speed * cos(test_angle) * horiz_dir.x,
			projectile_speed * sin(test_angle),
			projectile_speed * cos(test_angle) * horiz_dir.y
		)
		
		# Estimate time of flight with drag
		var flight_time = estimate_time_of_flight(start_pos, launch_vector, horiz_dist, drag_coefficient)
		# Calculate final position using analytical drag approximation
		var final_pos = calculate_position_at_time(start_pos, launch_vector, flight_time, drag_coefficient)
		
		# Calculate error to target
		var error_vector = target_pos - final_pos
		error_distance = error_vector.length()
		
		# If we're within tolerance, we've found a solution
		if error_distance < POSITION_TOLERANCE:
			return [launch_vector, flight_time]
		
		# Adjust search bounds based on vertical error
		if final_pos.y < target_pos.y:
			min_angle = test_angle # Need to increase angle
		else:
			max_angle = test_angle # Need to decrease angle
	
	# If we reach here, we've hit maximum iterations but haven't converged
	# Return the best approximation we have
	var best_angle = (min_angle + max_angle) / 2.0
	var best_launch_vector = Vector3(
		projectile_speed * cos(best_angle) * horiz_dir.x,
		projectile_speed * sin(best_angle),
		projectile_speed * cos(best_angle) * horiz_dir.y
	)
	
	var best_flight_time = estimate_time_of_flight(start_pos, best_launch_vector, horiz_dist, drag_coefficient)
	if error_distance >= POSITION_TOLERANCE:
		return [null, -1]
	return [best_launch_vector, best_flight_time]

## Estimate time of flight with drag effects
static func estimate_time_of_flight(start_pos: Vector3, launch_vector: Vector3, horiz_dist: float,
								  drag_coefficient: float) -> float:
	# Extract horizontal and vertical components
	var v0_horiz = Vector2(launch_vector.x, launch_vector.z).length()
	var v0_vert = launch_vector.y
	var beta = drag_coefficient
	
	# For horizontal motion with drag: x = (v₀/β) * (1-e^(-βt))
	# Solve for t: t = -ln(1-βx/v₀)/β
	
	# We need to find approximate time based on horizontal distance
	# This is an approximation since drag makes the trajectory non-parabolic
	var target_time = 0.0
	
	# Solve for time using the analytical formula for horizontal motion with drag
	var drag_factor = beta * horiz_dist / v0_horiz
	
	# Handle edge case where drag would slow projectile too much
	if drag_factor >= 0.99:
		target_time = INF
	else:
		target_time = -log(1.0 - drag_factor) / beta
	
	return target_time

## Calculate projectile position at any time with drag effects
static func calculate_position_at_time(start_pos: Vector3, launch_vector: Vector3, time: float,
									 drag_coefficient: float) -> Vector3:
	# Extract components
	var v0x = launch_vector.x
	var v0y = launch_vector.y
	var v0z = launch_vector.z
	var beta = drag_coefficient
	var g = abs(GRAVITY)
	
	var position = Vector3()
	
	# For x and z (horizontal components with drag)
	# x = (v₀/β) * (1-e^(-βt))
	var drag_factor = 1.0 - exp(-beta * time)
	position.x = start_pos.x + (v0x / beta) * drag_factor
	position.z = start_pos.z + (v0z / beta) * drag_factor
	
	# For y (vertical component with drag and gravity)
	# y ≈ y₀ + v₀y*(1-e^(-βt))/β - (g/β)t + (g/β²)(1-e^(-βt))
	position.y = start_pos.y + (v0y / beta) * drag_factor - (g / beta) * time + (g / (beta * beta)) * drag_factor
	
	return position


## Calculate launch vector to lead a moving target with drag effects
## Returns [launch_vector, time_to_target, final_target_position] or [null, -1, null] if no solution exists
static func calculate_leading_launch_vector(start_pos: Vector3, target_pos: Vector3, target_velocity: Vector3,
										  projectile_speed: float,
										  drag_coefficient: float) -> Array:
	# Start with the time it would take to hit the current position (non-drag estimation)
	var result = ProjectilePhysics.calculate_launch_vector(start_pos, target_pos, projectile_speed)
	
	if result[0] == null:
		return [null, -1, null] # No solution exists in basic physics
	
	var time_estimate = result[1]
	
	# Refine the estimate iteratively
	for i in range(3): # Just a few iterations for prediction
		# Predict target position after estimated time
		var predicted_pos = target_pos + target_velocity * time_estimate
		
		# Calculate launch vector to hit that position with drag
		result = calculate_launch_vector(start_pos, predicted_pos, projectile_speed, drag_coefficient)
		
		if result[0] == null:
			return [null, -1, null]
		
		time_estimate = result[1]
	
	# Final calculation with the best time estimate
	var final_target_pos = target_pos + target_velocity * time_estimate
	result = calculate_launch_vector(start_pos, final_target_pos, projectile_speed, drag_coefficient)
	
	# Return launch vector, time to target, and the final target position
	return [result[0], result[1], final_target_pos]


## Calculate the maximum horizontal range given a launch angle, accounting for drag
static func calculate_max_range_from_angle(angle: float, projectile_speed: float,
										 drag_coefficient: float) -> float:
	# Create a launch vector for this angle
	var launch_vector = Vector3(
		projectile_speed * cos(angle),
		projectile_speed * sin(angle),
		0
	)
	
	# Use the same horizontal calculation that's used in other functions for consistency
	var v0x = projectile_speed * cos(angle)
	var horiz_dist = v0x  # Just a placeholder - we need the actual range
	
	# Use estimate_time_of_flight to find when the projectile would hit the ground
	# First, we need to estimate when y=0 (the projectile returns to ground level)
	# This is an iterative process
	
	var max_time = 100.0  # Safety limit for flight time
	var time_step = 0.1
	var current_time = 0.0
	var prev_pos = Vector3.ZERO
	var current_pos = Vector3.ZERO
	var range_found = false
	
	# Find when the projectile hits the ground (y=0) by stepping through time
	while current_time < max_time:
		current_pos = calculate_position_at_time(Vector3.ZERO, launch_vector, current_time, drag_coefficient)
		
		# If we've gone below y=0, we can interpolate to find the exact impact point
		if current_pos.y < 0 and prev_pos.y >= 0:
			# Linear interpolation to find more precise impact time
			var t_ratio = prev_pos.y / (prev_pos.y - current_pos.y)
			var impact_time = current_time - time_step + (time_step * t_ratio)
			
			# Calculate final position at impact time
			var impact_pos = calculate_position_at_time(Vector3.ZERO, launch_vector, impact_time, drag_coefficient)
			
			# Return the horizontal distance traveled (the range)
			return Vector2(impact_pos.x, impact_pos.z).length()
		
		prev_pos = current_pos
		current_time += time_step
	
	# If we never hit the ground (unlikely but possible with certain drag values)
	# Calculate the asymptotic range
	var asymptotic_range = (v0x / drag_coefficient)
	return asymptotic_range

## Calculate the required launch angle to achieve a specific range with drag
static func calculate_angle_from_max_range(max_range: float, projectile_speed: float,
										 drag_coefficient: float) -> float:
	var beta = drag_coefficient
	var g = abs(GRAVITY)
	
	# With drag, we need to search for the angle that gives desired range
	# Binary search through angles to find best match
	
	# Start with reasonable bounds: 0 to 45 degrees
	# (with drag, maximum range is usually below 45 degrees)
	var min_angle = 0.0
	var max_angle = PI / 4.0
	
	# Find theoretical max range first
	var max_possible_range = 0.0
	for test_angle in [PI / 6.0, PI / 5.0, PI / 4.0, PI / 3.0]:
		var test_range = calculate_max_range_from_angle(test_angle, projectile_speed, beta)
		max_possible_range = max(max_possible_range, test_range)
	
	# Check if requested range is possible
	if max_range > max_possible_range:
		return -1 # Impossible range
	
	# Binary search for angle that gives desired range
	for i in range(MAX_ITERATIONS):
		var test_angle = (min_angle + max_angle) / 2.0
		var test_range = calculate_max_range_from_angle(test_angle, projectile_speed, beta)
		
		var error = test_range - max_range
		
		# If close enough, return this angle
		if abs(error) < 0.1: # 10cm tolerance
			return test_angle
			
		# Adjust search bounds
		if error < 0:
			min_angle = test_angle # Range too short, increase angle
		else:
			max_angle = test_angle # Range too far, decrease angle
	
	# Return best approximation after max iterations
	return (min_angle + max_angle) / 2.0
