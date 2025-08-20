extends Node

## Quick demo of the Ship's armor functionality

func _ready():
	test_ship_armor_functionality()

func test_ship_armor_functionality():
	print("⚔️ Testing Ship armor functionality...")
	
	# Load the Ship scene  
	var ship_scene = preload("res://ShipModels/Bismarck2.tscn")
	var ship_instance = ship_scene.instantiate()
	add_child(ship_instance)
	
	# Wait for initialization
	await get_tree().create_timer(1.0).timeout
	
	if ship_instance.armor_system != null:
		print("✅ Armor system ready, testing combat scenarios...")
		
		# Test different hit scenarios
		test_hit_scenario(ship_instance, "Hull", 0, 300, "Cruiser AP vs Hull")
		test_hit_scenario(ship_instance, "Hull/380mmTurret", 10, 500, "Battleship AP vs Turret")
		test_hit_scenario(ship_instance, "Hull/Superstructrure", 100, 150, "Destroyer HE vs Superstructure")
		
		# Show armor zone analysis
		print("\n📊 Armor Zone Analysis:")
		print_armor_zones(ship_instance.armor_system)
		
		# Show weak points
		print("\n🎯 Tactical Analysis:")
		show_weak_points(ship_instance.armor_system)
		
		print("\n🚢 Ship armor system fully operational!")
	else:
		print("❌ Armor system not available")

func test_hit_scenario(ship: Ship, node_path: String, face_index: int, shell_power: int, scenario: String):
	var armor_thickness = ship.armor_system.get_face_armor_thickness(node_path, face_index)
	var damage_info = ship.armor_system.calculate_penetration_damage(node_path, face_index, shell_power)
	
	print("  ", scenario, ":")
	print("    Target: ", node_path, " face ", face_index, " (", armor_thickness, "mm)")
	print("    Shell: ", shell_power, "mm penetration")
	print("    Result: ", damage_info.damage_type, " - ", "%.1f%%" % (damage_info.damage_ratio * 100), " damage")

func print_armor_zones(armor_system: ArmorSystemV2):
	var zones = ["main_belt", "turret_armor", "barbette_armor", "superstructure"]
	
	for zone_type in zones:
		print("  ", zone_type.replace("_", " ").capitalize(), ":")
		for node_path in armor_system.get_all_armored_nodes():
			var zone_info = armor_system.get_armor_zone_info(node_path)
			if zone_info.zone_type == zone_type:
				var stats = zone_info.stats
				if not stats.is_empty():
					print("    ", node_path.get_file(), ": ", stats.face_count, " faces, ", stats.min_armor, "-", stats.max_armor, "mm")

func show_weak_points(armor_system: ArmorSystemV2):
	# Find overall weak points
	var weak_points = armor_system.find_all_weak_points(100)  # Under 100mm
	print("  Weak points (≤100mm armor): ", weak_points.size(), " locations")
	
	if weak_points.size() > 0:
		print("  Top 3 weakest spots:")
		for i in range(min(3, weak_points.size())):
			var wp = weak_points[i]
			print("    ", wp.node_path.get_file(), " face ", wp.face_index, ": ", wp.armor_thickness, "mm")
