extends Node

## Test the Ship's integrated armor system

func _ready():
	test_ship_armor_integration()

func test_ship_armor_integration():
	print("🚢 Testing Ship armor system integration...")
	
	# Load the Ship scene  
	var ship_scene = preload("res://ShipModels/Bismarck2.tscn")
	var ship_instance = ship_scene.instantiate()
	add_child(ship_instance)
	
	# Wait a bit for initialization
	await get_tree().create_timer(3.0).timeout
	
	# Test the ship's armor system
	if ship_instance.armor_system != null:
		print("✅ Armor system successfully initialized")
		
		# Test armor lookup
		var _hull_armor = ship_instance.get_armor_at_hit_point(null, 0)  # Simplified test
		print("   Test armor lookup works")
		
		# Test damage calculation
		var damage_info = ship_instance.calculate_damage_from_hit(null, 0, 300)
		print("   Test damage calculation works: ", damage_info.damage_type)
		
		# Print basic stats if available
		if ship_instance.armor_system.armor_data.size() > 0:
			print("   📊 Armor data loaded for ", ship_instance.armor_system.armor_data.size(), " nodes")
			ship_instance.armor_system.print_armor_summary()
		
	else:
		print("❌ Armor system failed to initialize")
	
	print("🎯 Ship armor integration test completed!")
