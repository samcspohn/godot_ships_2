extends Node

## Test script for ArmorSystemV2 with simplified JSON structure

const ArmorSystemV2 = preload("res://armor_system_v2.gd")

func _ready():
	test_armor_system_v2()

func test_armor_system_v2():
	print("Testing ArmorSystemV2...")
	
	# Create the armor system
	var armor_system = ArmorSystemV2.new()
	add_child(armor_system)
	
	# Load the armor data
	var json_path = "res://bismark_hierarchy_armor.json"
	var success = armor_system.load_armor_data(json_path)
	
	if not success:
		print("❌ Failed to load armor data")
		return
	
	print("✅ Armor data loaded successfully")
	
	# Print comprehensive summary
	armor_system.print_armor_summary()
	
	# Test face armor lookup
	print("=== Testing Face Armor Lookup ===")
	test_face_lookup(armor_system, "Hull", 0)
	test_face_lookup(armor_system, "Hull", 100)
	test_face_lookup(armor_system, "Hull/380mmTurret", 0)
	test_face_lookup(armor_system, "Hull/barbette.001", 50)
	
	# Test node stats
	print("\n=== Testing Node Statistics ===")
	test_node_stats(armor_system, "Hull")
	test_node_stats(armor_system, "Hull/380mmTurret")
	
	# Test weak points
	print("\n=== Testing Weak Points ===")
	var weak_points = armor_system.find_weak_points("Hull", 100)
	print("Weak points on Hull (≤100mm): ", weak_points.size())
	if weak_points.size() > 0:
		for i in range(min(3, weak_points.size())):
			var wp = weak_points[i]
			print("  Face ", wp.face_index, ": ", wp.armor_thickness, "mm")
	
	# Test penetration calculation
	print("\n=== Testing Penetration Calculation ===")
	test_penetration(armor_system, "Hull", 0, 300)
	test_penetration(armor_system, "Hull", 100, 150)
	test_penetration(armor_system, "Hull/380mmTurret", 0, 400)
	
	# Test best target zones for different shell types
	print("\n=== Testing Target Zone Analysis ===")
	test_target_zones(armor_system, 200, "Cruiser AP")
	test_target_zones(armor_system, 400, "Battleship AP")
	
	# Test overall weak points
	print("\n=== Testing Overall Weak Points ===")
	var all_weak_points = armor_system.find_all_weak_points(80)
	print("Ship-wide weak points (≤80mm): ", all_weak_points.size())
	if all_weak_points.size() > 0:
		print("Top 5 weakest points:")
		for i in range(min(5, all_weak_points.size())):
			var wp = all_weak_points[i]
			print("  ", wp.node_path, " face ", wp.face_index, ": ", wp.armor_thickness, "mm (", wp.zone_info.zone_type, ")")
	
	print("\n✅ ArmorSystemV2 test completed successfully!")

func test_face_lookup(armor_system: ArmorSystemV2, node_path: String, face_index: int):
	var armor = armor_system.get_face_armor_thickness(node_path, face_index)
	print("  ", node_path, " face ", face_index, ": ", armor, "mm")

func test_node_stats(armor_system: ArmorSystemV2, node_path: String):
	var stats = armor_system.get_node_armor_stats(node_path)
	if not stats.is_empty():
		print("  ", node_path, ":")
		print("    Faces: ", stats.face_count)
		print("    Armor range: ", stats.min_armor, "-", stats.max_armor, "mm")
		print("    Average: %.1f mm" % stats.average_armor)
	else:
		print("  ", node_path, ": No armor data")

func test_penetration(armor_system: ArmorSystemV2, node_path: String, face_index: int, shell_power: int):
	var damage_info = armor_system.calculate_penetration_damage(node_path, face_index, shell_power)
	print("  ", shell_power, "mm vs ", node_path, " face ", face_index, " (", damage_info.armor_thickness, "mm):")
	print("    Result: ", damage_info.damage_type, " (", "%.1f%%" % (damage_info.damage_ratio * 100), " damage)")

func test_target_zones(armor_system: ArmorSystemV2, shell_power: int, shell_type: String):
	var zones = armor_system.get_best_target_zones(shell_power)
	print("  Best zones for ", shell_type, " (", shell_power, "mm penetration):")
	for i in range(min(3, zones.size())):
		var zone = zones[i]
		print("    ", zone.node_path, ": ", "%.1f%%" % (zone.penetration_ratio * 100), " penetrable, effectiveness ", "%.2f" % zone.effectiveness)
