extends Node

## Complete demonstration of the enhanced armor extraction and analysis system

const EnhancedArmorExtractorV2 = preload("res://enhanced_armor_extractor_v2.gd")
const ArmorSystemV2 = preload("res://armor_system_v2.gd")

func _ready():
	demonstrate_complete_system()

func demonstrate_complete_system():
	print("\n🚢 === COMPLETE ARMOR SYSTEM DEMONSTRATION === 🚢\n")
	
	# Step 1: Extract armor data from GLB
	print("Step 1: Extracting armor data from GLB file...")
	var extractor = EnhancedArmorExtractorV2.new()
	var success = extractor.extract_armor_from_glb("res://ShipModels/bismark_low_poly.glb")
	
	if not success:
		print("❌ Failed to extract armor data")
		return
	
	print("✅ Armor extraction completed successfully")
	print("   - Created: bismark_hierarchy_armor.json")
	
	# Step 2: Load armor data into the runtime system
	print("\nStep 2: Loading armor data into runtime system...")
	var armor_system = ArmorSystemV2.new()
	add_child(armor_system)
	
	success = armor_system.load_armor_data("res://bismark_hierarchy_armor.json")
	if not success:
		print("❌ Failed to load armor data")
		return
	
	print("✅ Armor data loaded into runtime system")
	
	# Step 3: Demonstrate key features
	print("\n=== SYSTEM CAPABILITIES DEMONSTRATION ===")
	
	demonstrate_armor_lookup(armor_system)
	demonstrate_weak_point_analysis(armor_system)
	demonstrate_penetration_mechanics(armor_system)
	demonstrate_tactical_analysis(armor_system)
	demonstrate_zone_classification(armor_system)
	
	print("\n🎯 === DEMONSTRATION COMPLETE === 🎯")
	print("The system successfully:")
	print("  ✅ Extracts armor data from GLB files using GLTF hierarchy")
	print("  ✅ Creates simplified JSON with direct face indexing")
	print("  ✅ Provides fast face-specific armor lookup")
	print("  ✅ Analyzes weak points and penetration mechanics")
	print("  ✅ Offers tactical targeting recommendations")
	print("  ✅ Classifies armor zones by importance")
	print("\nReady for integration into your Godot naval combat system!")

func demonstrate_armor_lookup(armor_system: ArmorSystemV2):
	print("\n--- Armor Lookup System ---")
	
	# Test various node types
	var test_cases = [
		{"node": "Hull", "face": 0, "desc": "Main belt armor"},
		{"node": "Hull/380mmTurret", "face": 10, "desc": "Primary turret front"},
		{"node": "Hull/Aft-Barbette", "face": 50, "desc": "Rear barbette"},
		{"node": "Hull/Superstructrure", "face": 100, "desc": "Superstructure"}
	]
	
	for test in test_cases:
		var armor = armor_system.get_face_armor_thickness(test.node, test.face)
		print("  ", test.desc, ": ", armor, "mm (", test.node, " face ", test.face, ")")

func demonstrate_weak_point_analysis(armor_system: ArmorSystemV2):
	print("\n--- Weak Point Analysis ---")
	
	# Find weak points on critical components
	var critical_nodes = ["Hull", "Hull/380mmTurret", "Hull/Superstructrure"]
	
	for node in critical_nodes:
		var weak_points = armor_system.find_weak_points(node, 100)
		print("  ", node.get_file(), ": ", weak_points.size(), " weak points (≤100mm)")
		
		if weak_points.size() > 0:
			# Show the 3 weakest points
			for i in range(min(3, weak_points.size())):
				var wp = weak_points[i]
				print("    Face ", wp.face_index, ": ", wp.armor_thickness, "mm")

func demonstrate_penetration_mechanics(armor_system: ArmorSystemV2):
	print("\n--- Penetration Mechanics ---")
	
	# Test different shell types against various armor
	var shell_tests = [
		{"power": 150, "name": "Destroyer HE"},
		{"power": 300, "name": "Cruiser AP"},
		{"power": 500, "name": "Battleship AP"},
		{"power": 700, "name": "Super-heavy AP"}
	]
	
	var target_node = "Hull"
	var target_face = 0
	var target_armor = armor_system.get_face_armor_thickness(target_node, target_face)
	
	print("  Target: ", target_node, " face ", target_face, " (", target_armor, "mm armor)")
	
	for shell in shell_tests:
		var damage_info = armor_system.calculate_penetration_damage(target_node, target_face, shell.power)
		var damage_pct = "%.1f%%" % (damage_info.damage_ratio * 100)
		print("    ", shell.name, " (", shell.power, "mm): ", damage_info.damage_type, " - ", damage_pct, " damage")

func demonstrate_tactical_analysis(armor_system: ArmorSystemV2):
	print("\n--- Tactical Analysis ---")
	
	# Analyze best target zones for different weapons
	var weapon_types = [
		{"pen": 200, "name": "Heavy Cruiser"},
		{"pen": 400, "name": "Battleship"},
		{"pen": 600, "name": "Super Battleship"}
	]
	
	for weapon in weapon_types:
		print("  Best targets for ", weapon.name, " (", weapon.pen, "mm penetration):")
		var zones = armor_system.get_best_target_zones(weapon.pen)
		
		for i in range(min(3, zones.size())):
			var zone = zones[i]
			var pen_pct = "%.1f%%" % (zone.penetration_ratio * 100)
			var effectiveness = "%.2f" % zone.effectiveness
			print("    ", zone.node_path.get_file(), ": ", pen_pct, " penetrable (effectiveness: ", effectiveness, ")")

func demonstrate_zone_classification(armor_system: ArmorSystemV2):
	print("\n--- Zone Classification ---")
	
	var all_nodes = armor_system.get_all_armored_nodes()
	var zones_by_type = {}
	
	for node_path in all_nodes:
		var zone_info = armor_system.get_armor_zone_info(node_path)
		var zone_type = zone_info.zone_type
		
		if not zones_by_type.has(zone_type):
			zones_by_type[zone_type] = []
		zones_by_type[zone_type].append({
			"path": node_path,
			"importance": zone_info.importance,
			"stats": zone_info.stats
		})
	
	# Sort zone types by importance
	var sorted_types = zones_by_type.keys()
	sorted_types.sort_custom(func(a, b): 
		var a_importance = zones_by_type[a][0].importance
		var b_importance = zones_by_type[b][0].importance
		return a_importance > b_importance
	)
	
	for zone_type in sorted_types:
		var zones = zones_by_type[zone_type]
		var type_name = zone_type.replace("_", " ").capitalize()
		print("  ", type_name, " (importance: ", "%.1f" % zones[0].importance, "):")
		
		for zone in zones:
			var stats = zone.stats
			if not stats.is_empty():
				print("    ", zone.path.get_file(), ": ", stats.face_count, " faces, avg ", "%.0f" % stats.average_armor, "mm")
