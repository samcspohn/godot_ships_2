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
	var direction_2d = (aim_point_2d - gun_position_2d).normalized()
	
	# Calculate perpendicular vector in 2D (90 degrees counterclockwise)
	var perpendicular_2d = Vector2(-direction_2d.y, direction_2d.x)
	
	# Generate point within elliptical distribution with normal distribution
	#var u = randf() * TAU  # Random angle around the ellipse (0 to 2π)
	
	# Create radius with bell curve distribution (more shots near center)
	# We use 0.99 to avoid potential log(0) issues
	#var r = inverse_normal_cdf(randf() * 0.99)
	
	var rho: float = randf_range(0.0, 1.0)
	var phi: float = randf_range(0.0, TAU)
	
	perpendicular_2d *= sqrt(rho) * cos(phi)
	direction_2d *= sqrt(rho) * sin(phi)
	#direction_2d *= 0.9
	#perpendicular_2d *= 0.6
	
	
	# Scale by dispersion values and apply to aim point
	var horizontal_offset = horizontal_dispersion * perpendicular_2d
	var vertical_offset = vertical_dispersion * direction_2d
	
	# Apply offsets in 2D
	# Horizontal is perpendicular to aim direction
	# Vertical is along aim direction
	var dispersed_point_2d = aim_point_2d + horizontal_offset + vertical_offset
	
	# Convert back to 3D, preserving original height
	return Vector3(dispersed_point_2d.x, aim_point.y, dispersed_point_2d.y)

## Simplified approximation of the inverse normal CDF
# This transforms a uniform random value (0-1) to follow normal distribution
func inverse_normal_cdf(p: float) -> float:
	# Simple approximation using Box-Muller transform concept
	# This creates a bell curve-like distribution with most points near the center
	return sqrt(-2.0 * log(1.0 - p * 0.9))

## Alternative method for generating normally distributed random points
func random_normal() -> float:
	# Box-Muller transform - generates normally distributed random numbers
	var u1 = max(randf(), 0.0001)  # Avoid log(0)
	var u2 = randf()
	
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)
