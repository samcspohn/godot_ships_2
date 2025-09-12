# Naval Artillery Dispersion Calculator for GODOT 4.X
extends Node
class_name ArtilleryDispersion

## Parameters for shell dispersion

# Base dispersion values at 0.5 km (500 meters)
# @export var base_horizontal_dispersion: float = 10.0 # Meters perpendicular to aim direction
# @export var base_vertical_dispersion: float = 120.0 # Meters in line with aim direction

# # Linear dispersion growth with range (meters per kilometer)
# @export var horizontal_dispersion_modifier: float = 13.56 # Additional meters of dispersion per km
# @export var vertical_dispersion_modifier: float = 13.56 # Additional meters of dispersion per km (typically 1.5-2x horizontal)

# Grouping values control how tightly shells cluster (higher = tighter grouping, lower variance)
@export var h_grouping: float = 3.0 # Horizontal grouping factor (higher = less spread)
@export var v_grouping: float = 3.0 # Vertical grouping factor (higher = less spread)

@export var base_spread: float = 0.01

# Normal distribution cache for Box-Muller transform efficiency
var _has_cached_normal: bool = false
var _cached_normal: float = 0.0

## Calculate a point within the dispersion ellipse
# aim_point: The precise point being aimed at
# gun_position: The position of the gun firing the shell
# Returns: A new point representing where the shell will actually go due to dispersion
func calculate_dispersion_point(aim_point: Vector3, gun_position: Vector3, speed: float, drag: float) -> Vector3:
	var a = ProjectilePhysicsWithDrag.calculate_launch_vector(gun_position, aim_point, speed, drag)
	var launch_velocity = a[0]


	var _dist = gun_position.distance_to(aim_point)
	# var horizontal_dispersion = base_horizontal_dispersion + _dist * horizontal_dispersion_modifier
	# var vertical_dispersion = base_vertical_dispersion + _dist * vertical_dispersion_modifier
	# Use efficient normal distribution for more realistic dispersion
	var p = random_point_in_ellipseV3(1.0, 1.0, h_grouping, v_grouping)
	
	# Alternative: Use the original method with uniform distribution
	# var p = random_point_in_ellipse(1, 1, h_grouping, v_grouping)

	var r = launch_velocity.cross(Vector3.UP).normalized()
	var u = launch_velocity.cross(r).normalized()
	# var base_spread = 0.01
	var new_launch_velocity = (launch_velocity.normalized() + (r * p.x + u * p.y) * base_spread) * speed

	# var dispersed_position = ProjectilePhysicsWithDrag.calculate_impact_position(gun_position, new_launch_velocity, drag)
	# print("aim_point: ", aim_point)
	# print("dispersed_position: ", dispersed_position)
	# return dispersed_position
	return new_launch_velocity

	# # return aim_point
	# # Calculate range to target in kilometers
	# var range_to_target_km = gun_position.distance_to(aim_point) / 1000.0
	
	# # Calculate actual dispersion values based on range using the formula:
	# # dispersion = base_dispersion + dispersion_modifier * range_in_km
	# var horizontal_dispersion = base_horizontal_dispersion + (horizontal_dispersion_modifier * range_to_target_km)
	# var vertical_dispersion = base_vertical_dispersion + (vertical_dispersion_modifier * range_to_target_km)
	
	# # Project positions to horizontal plane (XZ plane, Y is up)
	# var gun_position_2d = Vector2(gun_position.x, gun_position.z) 
	# var aim_point_2d = Vector2(aim_point.x, aim_point.z)
	
	# # Get 2D direction and distance
	# var y_dir = (aim_point_2d - gun_position_2d).normalized()
	
	# # Calculate perpendicular vector in 2D (90 degrees counterclockwise)
	# var _x_dir = Vector3(y_dir.x, 0, y_dir.y).cross(Vector3.UP)
	# var x_dir = Vector2(_x_dir.x, _x_dir.z).normalized()
	
	# # Generate point within elliptical distribution with normal distribution
	# #var u = randf() * TAU  # Random angle around the ellipse (0 to 2π)
	
	# # Create radius with bell curve distribution (more shots near center)
	# # We use 0.99 to avoid potential log(0) issues
	# #var r = inverse_normal_cdf(randf() * 0.99)
	
	# # var rho: float = randf_range(0.0, 1.0)
	# # var phi: float = randf_range(0.0, TAU)
	
	# # perpendicular_2d *= sqrt(rho) * cos(phi) * random_normal(h_grouping)
	# # direction_2d *= sqrt(rho) * sin(phi) * random_normal(v_grouping)
	# # #direction_2d *= 0.9
	# # #perpendicular_2d *= 0.6
	
	
	# # # Scale by dispersion values and apply to aim point
	# # var horizontal_offset = horizontal_dispersion * perpendicular_2d
	# # var vertical_offset = vertical_dispersion * direction_2d
	
	# # # Apply offsets in 2D
	# # # Horizontal is perpendicular to aim direction
	# # # Vertical is along aim direction
	# # var dispersed_point_2d = aim_point_2d + horizontal_offset + vertical_offset
	# var p = random_point_in_ellipse(horizontal_dispersion, vertical_dispersion, h_grouping, v_grouping)
	# var dispersed_point_2d = aim_point_2d + y_dir * p.y + x_dir * p.x
	
	# # Convert back to 3D, preserving original height
	# return Vector3(dispersed_point_2d.x, aim_point.y, dispersed_point_2d.y)


# Function to generate a random 2D point within an ellipse with adjustable distribution
# Parameters:
# - width: Width of the ellipse (x-axis radius * 2)
# - height: Height of the ellipse (y-axis radius * 2)
# - h_grouping: Controls horizontal distribution (1.0 = uniform, >1.0 = increasingly clustered toward center)
# - v_grouping: Controls vertical distribution (1.0 = uniform, >1.0 = increasingly clustered toward center)
# Returns: Vector2 representing a point inside the ellipse with origin at (0,0)
func random_point_in_ellipse(width: float, height: float, h_group: float = 1.0, v_group: float = 1.0) -> Vector2:
	# # Get the semi-major and semi-minor axes
	# var a = width / 2.0
	# var b = height / 2.0
	
	# # Step 1: Calculate a random angle
	# var angle = randf() * 2.0 * PI
	
	# # Step 2: Find the point on the ellipse that corresponds to that angle
	# # For an ellipse, the point (a*cos(t), b*sin(t)) gives us a point on the boundary
	# var ellipse_x = a * cos(angle)
	# var ellipse_y = b * sin(angle)
	
	# # Step 3: Multiply by randf() for uniform distribution within the ellipse
	# var scale_factor = randf()
	# var x = ellipse_x * scale_factor
	# var y = ellipse_y * scale_factor
	
	# # Step 4: Apply grouping to cluster points toward the center
	# if h_grouping > 1.0:
	# 	x = sign(x) * pow(abs(x) / a, h_grouping) * a
	
	# if v_grouping > 1.0:
	# 	y = sign(y) * pow(abs(y) / b, v_grouping) * b
	
	# return Vector2(x, y)
	var rho = randf_range(0.0, 1.0)
	var phi = randf_range(0.0, TAU)
	var a = width / 2.0
	var b = height / 2.0
	var x = cos(phi) * sqrt(rho) * a
	var y = sin(phi) * sqrt(rho) * b
	if h_group > 1.0:
		x = sign(x) * pow(abs(x) / a, h_group) * a
	if v_group > 1.0:
		y = sign(y) * pow(abs(y) / b, v_group) * b
	return Vector2(x, y)


## EFFICIENT NORMAL DISTRIBUTION METHODS ##

# Generate a single normal random value (mean=0, std=1) using Box-Muller transform
# This method caches one value for efficiency, so every other call is nearly free
func randn() -> float:
	if _has_cached_normal:
		_has_cached_normal = false
		return _cached_normal
	
	# Box-Muller transform - generates two normal values at once
	var u1 = randf()
	var u2 = randf()
	
	var z0 = sqrt(-2.0 * log(u1)) * cos(TAU * u2)
	var z1 = sqrt(-2.0 * log(u1)) * sin(TAU * u2)
	
	# Cache one for next call
	_cached_normal = z1
	# _has_cached_normal = true
	
	return z0

# Generate normal random value with custom mean and standard deviation
func randn_scaled(mean: float = 0.0, std_dev: float = 1.0) -> float:
	return randn() * std_dev + mean

# Generate a Vector2 with both components being normal random values
# This is very efficient as Box-Muller naturally generates pairs
func randn_vector2(mean: float = 0.0, std_dev: float = 1.0) -> Vector2:
	# If we have a cached value, use it and generate one more
	if _has_cached_normal:
		var x = _cached_normal * std_dev + mean
		_has_cached_normal = false
		return Vector2(x, randn_scaled(mean, std_dev))
	
	# Generate both at once with Box-Muller
	var u1 = randf()
	var u2 = randf()
	
	var z0 = sqrt(-2.0 * log(u1)) * cos(TAU * u2)
	var z1 = sqrt(-2.0 * log(u1)) * sin(TAU * u2)
	
	return Vector2(z0 * std_dev + mean, z1 * std_dev + mean)

# Alternative efficient method for elliptical distribution using normal distribution
# This gives a true normal distribution within the ellipse (Bell curve)
# Higher grouping values create steeper distribution (lower variance, tighter grouping)
func random_normal_point_in_ellipse(width: float, height: float, h_group_param: float = 1.0, v_group_param: float = 1.0) -> Vector2:
	var normal_pair = randn_vector2()
	
	# Convert grouping to variance reduction: higher grouping = lower variance
	# Use inverse relationship: std_dev = 1.0 / grouping
	var h_std_dev = 1.0 / max(h_group_param, 0.1)  # Prevent division by zero
	var v_std_dev = 1.0 / max(v_group_param, 0.1)
	
	return Vector2(
		normal_pair.x * h_std_dev * width / 6.0,  # 6 sigma covers ~99.7% of distribution
		normal_pair.y * v_std_dev * height / 6.0
	)

# Improved version of your original function using normal distribution for better clustering
# Higher grouping values create steeper distribution (lower variance, tighter grouping)
func random_point_in_ellipse_normal(width: float, height: float, h_group_param: float = 1.0, v_group_param: float = 1.0) -> Vector2:
	var a = width / 2.0
	var b = height / 2.0
	
	# Convert grouping to variance reduction: higher grouping = lower variance
	var h_std_dev = 1.0 / max(h_group_param, 0.1)
	var v_std_dev = 1.0 / max(v_group_param, 0.1)
	
	# Use normal distribution instead of uniform for more realistic clustering
	var normal_pair = randn_vector2()
	var x = normal_pair.x * h_std_dev * a / 3.0  # 3 sigma covers ~99.7%
	var y = normal_pair.y * v_std_dev * b / 3.0
	
	# Clamp to ellipse bounds if needed
	x = clamp(x, -a, a)
	y = clamp(y, -b, b)
	
	return Vector2(x, y)

# Advanced grouping function with exponential variance control
# Higher grouping creates much steeper distribution curves
func random_point_with_advanced_grouping(width: float, height: float, h_group_param: float = 1.0, v_group_param: float = 1.0) -> Vector2:
	var normal_pair = randn_vector2()
	
	# Advanced grouping: use exponential decay for variance
	# Formula: std_dev = base_std * exp(-grouping_factor * (grouping - 1))
	var base_std = 0.33  # Base standard deviation (about 1/3 of radius)
	var grouping_factor = 0.5  # Controls how quickly variance decreases
	
	var h_std_dev = base_std * exp(-grouping_factor * (h_group_param - 1.0))
	var v_std_dev = base_std * exp(-grouping_factor * (v_group_param - 1.0))
	
	return Vector2(
		normal_pair.x * h_std_dev * width,
		normal_pair.y * v_std_dev * height
	)


# Function to generate a random point within an ellipse with grouping control
# semi_major_x: horizontal radius of the ellipse
# semi_major_y: vertical radius of the ellipse
# h_grouping: horizontal grouping factor (1.0 = uniform, >1.0 = bias toward center)
# v_grouping: vertical grouping factor (1.0 = uniform, >1.0 = bias toward center)
func random_point_in_ellipseV2(semi_major_x: float, semi_major_y: float, h_grouping: float = 1.0, v_grouping: float = 1.0) -> Vector2:
	var max_attempts = 100
	var attempts = 0
	
	while attempts < max_attempts:
		# Generate biased random coordinates in [-1, 1] range
		var x = _biased_random_symmetric(h_grouping)
		var y = _biased_random_symmetric(v_grouping)
		
		# Check if the point is inside the unit circle
		# This ensures uniform distribution within the ellipse shape
		if x * x + y * y <= 1.0:
			# Scale by ellipse semi-axes and return
			return Vector2(x * semi_major_x, y * semi_major_y)
		
		attempts += 1
	
	# Fallback: return origin if we exceed max attempts
	return Vector2.ZERO

# Helper function to generate a biased random value in [-1, 1] range
# grouping = 1.0: uniform distribution
# grouping > 1.0: bias toward center (0)
func _biased_random_symmetric(grouping: float) -> float:
	# Clamp grouping to prevent division by zero or negative values
	grouping = max(grouping, 0.001)
	
	# Generate random value in [0, 1]
	var u = randf()
	
	# Generate random sign
	var sign_val = 1.0 if randf() < 0.5 else -1.0
	
	# Apply power transformation to bias toward center
	# When grouping = 1.0: pow(u, 1.0) = u (uniform)
	# When grouping > 1.0: pow(u, 1/grouping) biases toward smaller values
	return sign_val * pow(u, 1.0 / grouping)

func random_point_in_ellipseV3(width: float, height: float, h_group: float = 1.0, v_group: float = 1.0):
	var rho = randf_range(0.0, 1.0)
	var phi = randf_range(0.0, TAU)
	var a = width / 2.0
	var b = height / 2.0
	var x = pow(rho, h_group) * cos(phi) * a
	var y = pow(rho, v_group) * sin(phi) * b
	return Vector2(x, y)

	# var x = cos(phi) * sqrt(rho) * a
	# var y = sin(phi) * sqrt(rho) * b
	# if h_group > 1.0:
	# 	x = sign(x) * pow(abs(x) / a, h_group) * a
	# if v_group > 1.0:
	# 	y = sign(y) * pow(abs(y) / b, v_group) * b
	# return Vector2(x, y)
