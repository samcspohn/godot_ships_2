# Naval Artillery Dispersion Calculator for GODOT 4.X
extends Node
class_name ArtilleryDispersion

## Parameters for shell dispersion

# Base dispersion values at 0.5 km (500 meters)
@export var base_horizontal_dispersion: float = 10.0  # Meters perpendicular to aim direction
@export var base_vertical_dispersion: float = 120.0    # Meters in line with aim direction

# Linear dispersion growth with range (meters per kilometer)
@export var horizontal_dispersion_modifier: float = 13.56  # Additional meters of dispersion per km
@export var vertical_dispersion_modifier: float = 13.56    # Additional meters of dispersion per km (typically 1.5-2x horizontal)

# Sigma values control how tightly shells group within the ellipse
@export var horizontal_sigma: float = 3.0  # Standard deviations within horizontal dispersion
@export var vertical_sigma: float = 3.0    # Standard deviations within vertical dispersion 

## Calculate a point within the dispersion ellipse
# aim_point: The precise point being aimed at
# gun_position: The position of the gun firing the shell
# Returns: A new point representing where the shell will actually go due to dispersion
func calculate_dispersion_point(aim_point: Vector3, gun_position: Vector3) -> Vector3:
	# Calculate range to target in kilometers
	var range_to_target_km = gun_position.distance_to(aim_point) / 1000.0
	
	# Calculate actual dispersion values based on range using the formula:
	# dispersion = base_dispersion + dispersion_modifier * range_in_km
	var horizontal_dispersion = base_horizontal_dispersion + (horizontal_dispersion_modifier * range_to_target_km)
	var vertical_dispersion = base_vertical_dispersion + (vertical_dispersion_modifier * range_to_target_km)
	
	# Project positions to horizontal plane (XZ plane, Y is up)
	var gun_position_2d = Vector2(gun_position.x, gun_position.z) 
	var aim_point_2d = Vector2(aim_point.x, aim_point.z)
	
	# Get 2D direction and distance
	var y_dir = (aim_point_2d - gun_position_2d).normalized()
	
	# Calculate perpendicular vector in 2D (90 degrees counterclockwise)
	var x_dir = Vector2(-y_dir.y, y_dir.x)
	
	# Generate point within elliptical distribution with normal distribution
	#var u = randf() * TAU  # Random angle around the ellipse (0 to 2π)
	
	# Create radius with bell curve distribution (more shots near center)
	# We use 0.99 to avoid potential log(0) issues
	#var r = inverse_normal_cdf(randf() * 0.99)
	
	# var rho: float = randf_range(0.0, 1.0)
	# var phi: float = randf_range(0.0, TAU)
	
	# perpendicular_2d *= sqrt(rho) * cos(phi) * random_normal(horizontal_sigma)
	# direction_2d *= sqrt(rho) * sin(phi) * random_normal(vertical_sigma)
	# #direction_2d *= 0.9
	# #perpendicular_2d *= 0.6
	
	
	# # Scale by dispersion values and apply to aim point
	# var horizontal_offset = horizontal_dispersion * perpendicular_2d
	# var vertical_offset = vertical_dispersion * direction_2d
	
	# # Apply offsets in 2D
	# # Horizontal is perpendicular to aim direction
	# # Vertical is along aim direction
	# var dispersed_point_2d = aim_point_2d + horizontal_offset + vertical_offset
	var p = random_point_in_ellipse(horizontal_dispersion, vertical_dispersion, 1.8, 1.8)
	var dispersed_point_2d = aim_point_2d + y_dir * p.y + x_dir * p.x
	
	# Convert back to 3D, preserving original height
	return Vector3(dispersed_point_2d.x, aim_point.y, dispersed_point_2d.y)
# Function to generate a random 2D point within an ellipse with adjustable distribution
# Parameters:
# - width: Width of the ellipse (x-axis radius * 2)
# - height: Height of the ellipse (y-axis radius * 2)
# - h_grouping: Controls horizontal distribution (1.0 = uniform, >1.0 = increasingly clustered toward center)
# - v_grouping: Controls vertical distribution (1.0 = uniform, >1.0 = increasingly clustered toward center)
# Returns: Vector2 representing a point inside the ellipse with origin at (0,0)
func random_point_in_ellipse(width: float, height: float, h_grouping: float = 1.0, v_grouping: float = 1.0) -> Vector2:
	# Get the semi-major and semi-minor axes
	var a = width / 2.0
	var b = height / 2.0
	
	# Step 1: Calculate a random angle
	var angle = randf() * 2.0 * PI
	
	# Step 2: Find the point on the ellipse that corresponds to that angle
	# For an ellipse, the point (a*cos(t), b*sin(t)) gives us a point on the boundary
	var ellipse_x = a * cos(angle)
	var ellipse_y = b * sin(angle)
	
	# Step 3: Multiply by randf() for uniform distribution within the ellipse
	var scale_factor = randf()
	var x = ellipse_x * scale_factor
	var y = ellipse_y * scale_factor
	
	# Step 4: Apply grouping to cluster points toward the center
	if h_grouping > 1.0:
		x = sign(x) * pow(abs(x) / a, h_grouping) * a
	
	if v_grouping > 1.0:
		y = sign(y) * pow(abs(y) / b, v_grouping) * b
	
	return Vector2(x, y)
