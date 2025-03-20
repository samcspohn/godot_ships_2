extends Node3D

class_name ProjectilePhysicsWithDrag

const GRAVITY = ProjectilePhysics.GRAVITY


# Specific object drag coefficients - formula: (Cd × Area) / Mass
# German 380mm AP shell - recalculated with proper ballistic coefficient
# Diameter: 380mm, Mass: 800kg, Cd: 0.17 (streamlined artillery shell)
const SHELL_380MM_DRAG_COEFFICIENT = 0.00895

# Ping Pong Ball
# Diameter: 40mm, Mass: 2.7g, Cd: 0.5 (sphere)
const PING_PONG_DRAG_COEFFICIENT = 0.233  

# Bowling Ball
# Diameter: 218mm, Mass: 7kg, Cd: 0.5 (smooth sphere)
const BOWLING_BALL_DRAG_COEFFICIENT = 0.00267

const DEFAULT_DRAG_COEFFICIENT = SHELL_380MM_DRAG_COEFFICIENT  # Default drag coefficient
# Target position tolerance (in meters)
const POSITION_TOLERANCE = 0.05  
# Maximum iterations for binary search
const MAX_ITERATIONS = 20  
# Angle adjustment step for binary search (in radians)
const INITIAL_ANGLE_STEP = 0.1  

## Calculates the launch vector needed to hit a stationary target from a given position
## with drag effects considered
## Returns [launch_vector, time_to_target, is_max_range] where:
## - is_max_range = false if target can be reached
## - is_max_range = true if target is unreachable and max range vector is returned instead
static func calculate_launch_vector(start_pos: Vector3, target_pos: Vector3, projectile_speed: float, 
								  drag_coefficient: float = DEFAULT_DRAG_COEFFICIENT) -> Array:
	# Start with the non-drag physics as initial approximation
	var initial_result = ProjectilePhysics.calculate_launch_vector(start_pos, target_pos, projectile_speed)
	
	# Calculate direction to target (for azimuth angle)
	var disp = target_pos - start_pos
	var horiz_dist = Vector2(disp.x, disp.z).length()
	var horiz_dir = Vector2(disp.x, disp.z).normalized()
	
	# Check if target is unreachable (even without drag)
	var target_unreachable = initial_result[0] == null
	
	# If unreachable, or we suspect it might be with drag, find max range in that direction
	if target_unreachable or horiz_dist > 0.9 * ProjectilePhysics.calculate_max_range_from_angle(PI/4, projectile_speed):
		# For max range with drag, optimal angle is usually less than 45 degrees
		# Use binary search to find the best angle for maximum range
		var min_angle = PI/12  # 15 degrees
		var max_angle = PI/3   # 60 degrees
		var best_angle = PI/4  # Start with 45 degrees as initial guess
		var best_range = 0.0
		
		# Binary search for the optimal angle
		for i in range(MAX_ITERATIONS):
			var test_angle1 = (min_angle + best_angle) / 2.0
			var test_angle2 = (best_angle + max_angle) / 2.0
			
			var range1 = calculate_max_range_from_angle(test_angle1, projectile_speed, drag_coefficient)
			var range2 = calculate_max_range_from_angle(test_angle2, projectile_speed, drag_coefficient)
			
			if range1 > range2:
				max_angle = best_angle
				best_angle = test_angle1
			else:
				min_angle = best_angle
				best_angle = test_angle2
				
			best_range = max(range1, range2)
		
		# Create the maximum range launch vector
		var max_range_vector = Vector3(
			projectile_speed * cos(best_angle) * horiz_dir.x,
			projectile_speed * sin(best_angle),
			projectile_speed * cos(best_angle) * horiz_dir.y
		)
		
		# Calculate time to max range
		var flight_time = estimate_time_of_flight(start_pos, max_range_vector, best_range, drag_coefficient)
		
		# Return result with max range flag = true
		return [max_range_vector, flight_time, true]
	
	# If we get here, target should be reachable
	# Extract elevation angle from initial vector
	var initial_speed_xz = Vector2(initial_result[0].x, initial_result[0].z).length()
	var elevation_angle = atan2(initial_result[0].y, initial_speed_xz)
	
	# Binary search for the correct elevation angle with drag
	var min_angle = elevation_angle - PI/4  # Lower bound
	var max_angle = elevation_angle + PI/4  # Upper bound
	
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
		var error_distance = error_vector.length()
		
		# If we're within tolerance, we've found a solution
		if error_distance < POSITION_TOLERANCE:
			return [launch_vector, flight_time, false]
		
		# Adjust search bounds based on vertical error
		if final_pos.y < target_pos.y:
			min_angle = test_angle  # Need to increase angle
		else:
			max_angle = test_angle  # Need to decrease angle
	
	# If we reach here, we've hit maximum iterations but haven't converged
	# Return the best approximation we have
	var best_angle = (min_angle + max_angle) / 2.0
	var best_launch_vector = Vector3(
		projectile_speed * cos(best_angle) * horiz_dir.x,
		projectile_speed * sin(best_angle),
		projectile_speed * cos(best_angle) * horiz_dir.y
	)
	
	var best_flight_time = estimate_time_of_flight(start_pos, best_launch_vector, horiz_dist, drag_coefficient)
	
	return [best_launch_vector, best_flight_time, false]

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
	if drag_factor >= 1.0:
		# Use a large but finite time instead of infinity
		target_time = 100.0  
	else:
		target_time = -log(1.0 - drag_factor) / beta
	
	return target_time

## Calculate projectile position at any time with drag effects
static func calculate_position_at_time(start_pos: Vector3, launch_vector: Vector3, time: float, 
									 drag_coefficient: float = DEFAULT_DRAG_COEFFICIENT) -> Vector3:
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
## Returns [launch_vector, time_to_target, is_max_range] where:
## - is_max_range = false if target can be reached
## - is_max_range = true if target is unreachable and max range vector is returned instead
static func calculate_leading_launch_vector(start_pos: Vector3, target_pos: Vector3, target_velocity: Vector3, 
										  projectile_speed: float, 
										  drag_coefficient: float = DEFAULT_DRAG_COEFFICIENT) -> Array:
	# Start with the time it would take to hit the current position (non-drag estimation)
	var result = ProjectilePhysics.calculate_launch_vector(start_pos, target_pos, projectile_speed)
	
	# Check if even the current position is unreachable
	if result[0] == null:
		# Calculate direction to target for max range
		var disp = target_pos - start_pos
		var horiz_dir = Vector2(disp.x, disp.z).normalized()
		
		# Get max range information
		return calculate_launch_vector(start_pos, target_pos, projectile_speed, drag_coefficient)
	
	var time_estimate = result[1]
	
	# Refine the estimate iteratively
	for i in range(3):  # Just a few iterations for prediction
		# Predict target position after estimated time
		var predicted_pos = target_pos + target_velocity * time_estimate
		
		# Calculate launch vector to hit that position with drag
		result = calculate_launch_vector(start_pos, predicted_pos, projectile_speed, drag_coefficient)
		
		# Check if the predicted position is unreachable
		if result[2]:  # result[2] is the is_max_range flag
			return result
		
		time_estimate = result[1]
	
	# Final calculation with the best time estimate
	var final_target_pos = target_pos + target_velocity * time_estimate
	return calculate_launch_vector(start_pos, final_target_pos, projectile_speed, drag_coefficient)

## Calculate the maximum horizontal range given a launch angle, accounting for drag
static func calculate_max_range_from_angle(angle: float, projectile_speed: float, 
										 drag_coefficient: float = DEFAULT_DRAG_COEFFICIENT) -> float:
	var v0x = projectile_speed * cos(angle)
	var v0y = projectile_speed * sin(angle)
	var g = abs(GRAVITY)
	var beta = drag_coefficient
	
	# With drag, the projectile will eventually fall regardless of angle
	# We need to estimate when it would hit the ground (y = 0)
	
	# Analytical estimate for range with drag
	# We need to estimate the time of flight first
	
	# Using the drag formula for vertical motion:
	# y ≈ y₀ + v₀y*(1-e^(-βt))/β - (g/β)t + (g/β²)(1-e^(-βt))
	# For flat ground, y₀ = 0 and final y = 0
	
	# This is a complex equation to solve analytically for t
	# We'll use an approximation based on ballistic theory
	
	# For small drag, time of flight is approximately:
	# t ≈ (2 * v₀y / g) * (1 - β * v₀y / 3g)
	var time_of_flight = (2.0 * v0y / g) * (1.0 - beta * v0y / (3.0 * g))
	
	# Calculate horizontal distance using drag formula:
	# x = (v₀x/β) * (1-e^(-βt))
	var range = (v0x / beta) * (1.0 - exp(-beta * time_of_flight))
	
	# Ensure non-negative result
	return max(0.0, range)

## Calculate the required launch angle to achieve a specific range with drag
static func calculate_angle_from_max_range(max_range: float, projectile_speed: float, 
										 drag_coefficient: float = DEFAULT_DRAG_COEFFICIENT) -> float:
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
	for test_angle in [PI/6.0, PI/5.0, PI/4.0, PI/3.0]:
		var test_range = calculate_max_range_from_angle(test_angle, projectile_speed, beta)
		max_possible_range = max(max_possible_range, test_range)
	
	# Check if requested range is possible
	if max_range > max_possible_range:
		return -1  # Impossible range
	
	# Binary search for angle that gives desired range
	for i in range(MAX_ITERATIONS):
		var test_angle = (min_angle + max_angle) / 2.0
		var test_range = calculate_max_range_from_angle(test_angle, projectile_speed, beta)
		
		var error = test_range - max_range
		
		# If close enough, return this angle
		if abs(error) < 0.1:  # 10cm tolerance
			return test_angle
			
		# Adjust search bounds
		if error < 0:
			min_angle = test_angle  # Range too short, increase angle
		else:
			max_angle = test_angle  # Range too far, decrease angle
	
	# Return best approximation after max iterations
	return (min_angle + max_angle) / 2.0

## Example usage implementation
func _ready():
	# Basic parameters
	var start = Vector3(0, 1, 0)
	var target = Vector3(10, 5, 5)
	var unreachable_target = Vector3(500, 10, 200)  # Likely unreachable
	var speed = 20.0
	
	print("---- PROJECTILE WITH DRAG TESTS ----")
	
	# Test standard launch vector calculation with drag
	var result = calculate_launch_vector(start, target, speed)
	if !result[2]:  # Not at max range
		print("Launch Vector with drag: ", result[0])
		print("Time to Target with drag: ", result[1])
		
		# Verify final position
		var final_pos = calculate_position_at_time(start, result[0], result[1])
		print("Final position: ", final_pos)
		print("Distance to target: ", (final_pos - target).length())
		
		# Calculate position at midpoint
		var mid_time = result[1] / 2.0
		var mid_pos = calculate_position_at_time(start, result[0], mid_time)
		print("Position at midpoint: ", mid_pos)
	else:
		print("Target is out of range!")
		print("Max range launch vector: ", result[0])
		print("Time to max range: ", result[1])
	
	# Test unreachable target
	print("\n--- Testing Unreachable Target ---")
	var unreachable_result = calculate_launch_vector(start, unreachable_target, speed)
	if unreachable_result[2]:  # This should be true - at max range
		print("Unreachable target. Maximum range vector provided.")
		print("Launch vector for max range: ", unreachable_result[0])
		print("Time to max range: ", unreachable_result[1])
		
		# Calculate the actual maximum range achieved
		var dir_to_target = unreachable_target - start
		dir_to_target.y = 0  # Horizontal direction only
		dir_to_target = dir_to_target.normalized()
		
		var time = unreachable_result[1]
		var max_pos = calculate_position_at_time(start, unreachable_result[0], time)
		var horiz_dist = Vector2(max_pos.x - start.x, max_pos.z - start.z).length()
		
		print("Max achievable range: ", horiz_dist, " meters")
		print("Max elevation: ", max_pos.y, " meters")
	else:
		print("Target is surprisingly reachable!")
	
	# Test leading launch vector with drag
	print("\n--- Testing Moving Target ---")
	var target_vel = Vector3(2, 0, 1)  # Target moving right and forward
	var lead_result = calculate_leading_launch_vector(start, target, target_vel, speed)
	if !lead_result[2]:  # Not at max range
		print("Leading Vector with drag: ", lead_result[0])
		print("Time to Moving Target with drag: ", lead_result[1])
	else:
		print("Moving target cannot be hit!")
		print("Max range vector in target direction: ", lead_result[0])
	
	# Test range calculations with drag
	print("\n--- Testing Range Calculations ---")
	var angle = PI/4  # 45 degrees
	var max_range = calculate_max_range_from_angle(angle, speed)
	print("Maximum range at 45 degrees with drag: ", max_range)
	
	var target_range = 30.0
	var needed_angle = calculate_angle_from_max_range(target_range, speed)
	if needed_angle >= 0:
		print("Angle needed for range of ", target_range, " with drag: ", rad_to_deg(needed_angle), " degrees")
	else:
		print("Target range exceeds physical limits with drag!")
		
	# Test different projectile types
	print("\n--- Testing Different Projectiles ---")
	
	print("Ping Pong Ball:")
	var ping_pong_result = calculate_launch_vector(start, Vector3(5, 2, 0), 10.0, PING_PONG_DRAG_COEFFICIENT)
	if !ping_pong_result[2]:
		print("  Reachable! Time to target: ", ping_pong_result[1])
	else:
		print("  Unreachable! Max range time: ", ping_pong_result[1])
		
	print("Bowling Ball:")
	var bowling_result = calculate_launch_vector(start, Vector3(20, 5, 0), 15.0, BOWLING_BALL_DRAG_COEFFICIENT)
	if !bowling_result[2]:
		print("  Reachable! Time to target: ", bowling_result[1])
	else:
		print("  Unreachable! Max range time: ", bowling_result[1])
		
	print("380mm Shell:")
	max_range = calculate_max_range_from_angle(deg_to_rad(30), Shell.shell_speed,SHELL_380MM_DRAG_COEFFICIENT)
	print("max range: ", max_range)
	max_range = ProjectilePhysics.calculate_max_range_from_angle(deg_to_rad(30),Shell.shell_speed)
	print("max range no drag: ", max_range)
	var shell_result = calculate_launch_vector(start, Vector3(200, 50, 0), 100.0, SHELL_380MM_DRAG_COEFFICIENT)
	if !shell_result[2]:
		print("  Reachable! Time to target: ", shell_result[1])
	else:
		print("  Unreachable! Max range time: ", shell_result[1])
