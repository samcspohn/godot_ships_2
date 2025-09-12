extends Node

# Load the ArmorInteraction script
const ArmorInteraction = preload("res://src/artillary/ArmorInteraction.gd")

## Example usage of the get_armor_part_at_point function
## This demonstrates how to check what armor part a point is inside of

func test_armor_part_detection():
	# Get the physics space state
	var space_state = get_tree().root.get_world_3d().direct_space_state
	
	# Example test points (you would replace these with actual world positions)
	var test_points = [
		Vector3(0, 0, 0),      # Center of ship
		Vector3(10, 5, 2),     # Some point on the hull
		Vector3(-5, 10, 0),    # Point near a turret
		Vector3(0, 15, 10)     # Point in superstructure
	]
	
	print("=== Armor Part Detection Test ===")
	
	for i in range(test_points.size()):
		var point = test_points[i]
		var result = ArmorInteraction.get_armor_part_at_point(point, space_state)
		
		print("\nTest Point ", i + 1, ": ", point)
		
		if result.is_empty():
			print("  ❌ Point is not inside any armor part")
		else:
			var armor_part = result['armor_part']
			var armor_path = result['armor_path']
			
			print("  ✅ Point is inside armor part:")
			print("    - Armor Path: ", armor_path)
			print("    - Armor Part: ", armor_part.name)
			
			# If there are multiple containing parts (nested), show them
			var all_parts = result['all_containing_parts']
			if all_parts.size() > 1:
				print("    - Nested within ", all_parts.size(), " armor parts:")
				for j in range(all_parts.size()):
					var part_info = all_parts[j]
					print("      ", j + 1, ". ", part_info['armor_part'].armor_path)

func check_specific_armor_at_point(world_position: Vector3) -> Dictionary:
	"""
	Utility function to check armor at a specific world position
	Returns armor information including thickness at that point
	"""
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var armor_result = ArmorInteraction.get_armor_part_at_point(world_position, space_state)
	
	if armor_result.is_empty():
		return {
			"has_armor": false,
			"armor_thickness": 0,
			"armor_path": "",
			"message": "No armor at this position"
		}
	
	var armor_part = armor_result['armor_part']
	
	# To get the exact armor thickness, we'd need to determine which face 
	# the point is closest to. For now, we'll return the armor part info.
	return {
		"has_armor": true,
		"armor_part": armor_part,
		"armor_path": armor_result['armor_path'],
		"all_containing_parts": armor_result['all_containing_parts'],
		"message": "Found armor: " + armor_result['armor_path']
	}

# Usage examples for different scenarios:

func example_explosion_damage():
	"""Example: Check armor at explosion center to determine damage"""
	var explosion_center = Vector3(0, 5, 0)
	var armor_info = check_specific_armor_at_point(explosion_center)
	
	if armor_info['has_armor']:
		print("Explosion hit armor: ", armor_info['armor_path'])
		# Apply armor-modified damage
	else:
		print("Explosion hit unarmored area - full damage")

func example_area_of_effect():
	"""Example: Check multiple points for area-of-effect damage"""
	var center = Vector3(0, 0, 0)
	var radius = 5.0
	var test_points = []
	
	# Generate points in a sphere around the center
	for i in range(20):
		var angle = i * PI * 2.0 / 20.0
		var point = center + Vector3(cos(angle), 0, sin(angle)) * radius
		test_points.append(point)
	
	print("=== Area of Effect Armor Check ===")
	for point in test_points:
		var armor_info = check_specific_armor_at_point(point)
		print("Point ", point, ": ", armor_info['message'])

func example_projectile_path():
	"""Example: Check armor along a projectile's path"""
	var start = Vector3(-20, 5, 0)
	var end = Vector3(20, 5, 0)
	var steps = 10
	
	print("=== Projectile Path Armor Check ===")
	for i in range(steps + 1):
		var t = float(i) / steps
		var point = start.lerp(end, t)
		var armor_info = check_specific_armor_at_point(point)
		print("Step ", i, " (", point, "): ", armor_info['message'])
