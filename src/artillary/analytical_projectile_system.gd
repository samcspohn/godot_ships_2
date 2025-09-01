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
		var target_pos = Vector3(test_range, 0, 0)
		## Returns [launch_vector, time_to_target] or [null, -1] if no solution exists
		var result = calculate_launch_vector(Vector3.ZERO, target_pos, projectile_speed, drag_coefficient)
		
		if result[0] != null and result[1] > 0:
			if test_range > best_range:
				best_range = test_range
				var velocity = result[0]
				best_angle = atan2(velocity.y, sqrt(velocity.x * velocity.x + velocity.z * velocity.z))
				best_time = result[1]
				min_range = best_range
		else:
			max_range = test_range
			
		if max_range - min_range < 0.01:  # 1cm tolerance
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
	
	# Calculate direction to target (azimuth angle - remains constant)
	var disp = target_pos - start_pos
	var horiz_dist = Vector2(disp.x, disp.z).length()
	var horiz_dir = Vector2(disp.x, disp.z).normalized()
	
	# Extract elevation angle from initial vector
	var initial_speed_xz = Vector2(initial_vector.x, initial_vector.z).length()
	var elevation_angle = atan2(initial_vector.y, initial_speed_xz)
	
	var beta = drag_coefficient
	var g = abs(GRAVITY)
	var theta = elevation_angle
	
	# Newton-Raphson refinement - Step 1
	# Calculate current trajectory error
	var v0_horiz = projectile_speed * cos(theta)
	var v0y = projectile_speed * sin(theta)
	
	# Calculate flight time using horizontal constraint: horiz_dist = (v₀/β)(1-e^(-βt))
	var drag_factor = beta * horiz_dist / v0_horiz
	if drag_factor >= 0.99:
		return [null, -1] # Too much drag
	
	var flight_time = -log(1.0 - drag_factor) / beta
	
	# Calculate vertical position at this flight time
	var drag_decay = 1.0 - exp(-beta * flight_time)
	var calc_y = start_pos.y + (v0y / beta) * drag_decay - (g / beta) * flight_time + (g / (beta * beta)) * drag_decay
	var f_val = calc_y - target_pos.y
	
	# Calculate derivative numerically
	var delta_theta = 0.0001
	var theta_plus = theta + delta_theta
	var v0_horiz_plus = projectile_speed * cos(theta_plus)
	var v0y_plus = projectile_speed * sin(theta_plus)
	
	var drag_factor_plus = beta * horiz_dist / v0_horiz_plus
	if drag_factor_plus < 0.99:
		var flight_time_plus = -log(1.0 - drag_factor_plus) / beta
		var drag_decay_plus = 1.0 - exp(-beta * flight_time_plus)
		var calc_y_plus = start_pos.y + (v0y_plus / beta) * drag_decay_plus - (g / beta) * flight_time_plus + (g / (beta * beta)) * drag_decay_plus
		var f_prime = (calc_y_plus - calc_y) / delta_theta
		
		if abs(f_prime) > 1e-10:
			theta = theta - f_val / f_prime
	
	# Newton-Raphson refinement - Step 2
	v0_horiz = projectile_speed * cos(theta)
	v0y = projectile_speed * sin(theta)
	
	drag_factor = beta * horiz_dist / v0_horiz
	if drag_factor >= 0.99:
		return [null, -1]
	
	flight_time = -log(1.0 - drag_factor) / beta
	drag_decay = 1.0 - exp(-beta * flight_time)
	calc_y = start_pos.y + (v0y / beta) * drag_decay - (g / beta) * flight_time + (g / (beta * beta)) * drag_decay
	f_val = calc_y - target_pos.y
	
	theta_plus = theta + delta_theta
	v0_horiz_plus = projectile_speed * cos(theta_plus)
	v0y_plus = projectile_speed * sin(theta_plus)
	
	drag_factor_plus = beta * horiz_dist / v0_horiz_plus
	if drag_factor_plus < 0.99:
		var flight_time_plus = -log(1.0 - drag_factor_plus) / beta
		var drag_decay_plus = 1.0 - exp(-beta * flight_time_plus)
		var calc_y_plus = start_pos.y + (v0y_plus / beta) * drag_decay_plus - (g / beta) * flight_time_plus + (g / (beta * beta)) * drag_decay_plus
		var f_prime = (calc_y_plus - calc_y) / delta_theta
		
		if abs(f_prime) > 1e-10:
			theta = theta - f_val / f_prime
	
	# Newton-Raphson refinement - Step 3 (final)
	v0_horiz = projectile_speed * cos(theta)
	v0y = projectile_speed * sin(theta)
	
	drag_factor = beta * horiz_dist / v0_horiz
	if drag_factor >= 0.99:
		return [null, -1]
	
	flight_time = -log(1.0 - drag_factor) / beta
	drag_decay = 1.0 - exp(-beta * flight_time)
	calc_y = start_pos.y + (v0y / beta) * drag_decay - (g / beta) * flight_time + (g / (beta * beta)) * drag_decay
	f_val = calc_y - target_pos.y
	
	theta_plus = theta + delta_theta  
	v0_horiz_plus = projectile_speed * cos(theta_plus)
	v0y_plus = projectile_speed * sin(theta_plus)
	
	drag_factor_plus = beta * horiz_dist / v0_horiz_plus
	if drag_factor_plus < 0.99:
		var flight_time_plus = -log(1.0 - drag_factor_plus) / beta
		var drag_decay_plus = 1.0 - exp(-beta * flight_time_plus)
		var calc_y_plus = start_pos.y + (v0y_plus / beta) * drag_decay_plus - (g / beta) * flight_time_plus + (g / (beta * beta)) * drag_decay_plus
		var f_prime = (calc_y_plus - calc_y) / delta_theta
		
		if abs(f_prime) > 1e-10:
			theta = theta - f_val / f_prime
	
	# Create final launch vector
	var final_launch_vector = Vector3(
		projectile_speed * cos(theta) * horiz_dir.x,
		projectile_speed * sin(theta),
		projectile_speed * cos(theta) * horiz_dir.y
	)
	
	# Calculate final flight time
	var final_v0_horiz = projectile_speed * cos(theta)
	var final_drag_factor = beta * horiz_dist / final_v0_horiz
	
	if final_drag_factor >= 0.99:
		return [null, -1]
	
	var final_flight_time = -log(1.0 - final_drag_factor) / beta
	
	# Verify accuracy - check if we hit close enough to target
	var final_drag_decay = 1.0 - exp(-beta * final_flight_time)
	var final_y = start_pos.y + (projectile_speed * sin(theta) / beta) * final_drag_decay - (g / beta) * final_flight_time + (g / (beta * beta)) * final_drag_decay
	
	var error_distance = abs(final_y - target_pos.y)
	if error_distance > POSITION_TOLERANCE:
		return [null, -1] # Solution not accurate enough
	
	return [final_launch_vector, final_flight_time]
## Calculate the impact position where y = 0 using advanced analytical approximation
## This function uses Newton-Raphson refinement with a high-accuracy initial guess
## to solve the transcendental equation for projectile motion with drag
##
## Parameters:
## - start_pos: Starting position (Vector3)
## - launch_velocity: Initial velocity vector (Vector3)
## - drag_coefficient: Drag coefficient (float)
##
## Returns: Vector3 impact position where y = 0, or Vector3.ZERO if no solution
static func calculate_impact_position(start_pos: Vector3, launch_velocity: Vector3, 
									drag_coefficient: float) -> Vector3:
	# Safety checks
	if start_pos.y <= 0.0:
		return start_pos # Already at or below ground level
		
	if drag_coefficient <= 0.0:
		push_error("Invalid drag coefficient: must be positive")
		return Vector3.ZERO
	
	# Extract components
	var y0 = start_pos.y
	var v0y = launch_velocity.y
	var v0x = launch_velocity.x
	var v0z = launch_velocity.z
	var beta = drag_coefficient
	var g = abs(GRAVITY)
	
	# First, get a very good initial guess using the ballistic formula (no drag)
	# This provides an excellent starting point even for high drag cases
	var no_drag_time = 0.0
	if v0y >= 0:
		# Upward trajectory: t = (v₀y + sqrt(v₀y² + 2gy₀))/g
		no_drag_time = (v0y + sqrt(v0y * v0y + 2.0 * g * y0)) / g
	else:
		# Downward trajectory: t = (-v₀y + sqrt(v₀y² + 2gy₀))/g
		var discriminant = v0y * v0y + 2.0 * g * y0
		if discriminant < 0:
			return Vector3.ZERO # No solution
		no_drag_time = (-v0y + sqrt(discriminant)) / g
	
	# Refine using Newton-Raphson method (analytically - fixed number of steps)
	# The function we're solving is: f(t) = y₀ + (v₀y/β)(1-e^(-βt)) - (g/β)t + (g/β²)(1-e^(-βt))
	# Its derivative is: f'(t) = (v₀y + g/β)e^(-βt) - g/β
	
	var t = no_drag_time
	
	# Apply 2 Newton-Raphson steps for high accuracy (still analytical - no loops)
	# Step 1
	var exp_term = exp(-beta * t)
	var f_val = y0 + (v0y/beta) * (1.0 - exp_term) - (g/beta) * t + (g/(beta*beta)) * (1.0 - exp_term)
	var f_prime = (v0y + g/beta) * exp_term - g/beta
	
	if abs(f_prime) > 1e-10: # Avoid division by zero
		t = t - f_val / f_prime
	
	# Step 2 (refinement)
	exp_term = exp(-beta * t)
	f_val = y0 + (v0y/beta) * (1.0 - exp_term) - (g/beta) * t + (g/(beta*beta)) * (1.0 - exp_term)
	f_prime = (v0y + g/beta) * exp_term - g/beta
	
	if abs(f_prime) > 1e-10:
		t = t - f_val / f_prime
	
	# Ensure positive time
	if t <= 0:
		return Vector3.ZERO
	
	# Calculate final horizontal positions using analytical drag formula
	var drag_factor = 1.0 - exp(-beta * t)
	
	var final_x = start_pos.x + (v0x / beta) * drag_factor
	var final_z = start_pos.z + (v0z / beta) * drag_factor
	
	# Return impact position (y = 0 by definition)
	return Vector3(final_x, 0.0, final_z)

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
	
	if time <= 0.0:
		return start_pos
		
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
	if is_nan(drag_factor):
		drag_factor = 0.0
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
