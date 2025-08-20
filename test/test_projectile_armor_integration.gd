extends Node

## Test ProjectileManager integration with ArmorSystemV2

func _ready():
	test_projectile_armor_integration()

func test_projectile_armor_integration():
	print("⚔️ Testing ProjectileManager + ArmorSystemV2 Integration...")
	
	# Load a ship instance (we'll use the standalone test approach)
	var armor_system = ArmorSystemV2.new()
	add_child(armor_system)
	
	# Load the armor data
	var success = armor_system.load_armor_data("res://ShipModels/bismark_low_poly_armor.json")
	
	if success:
		print("✅ Armor data loaded for integration test")
		
		# Create a mock Ship for testing
		var mock_ship = MockShip.new()
		mock_ship.armor_system = armor_system
		add_child(mock_ship)
		
		# Test the enhanced armor lookup function
		test_armor_lookup(mock_ship)
		test_penetration_scenarios(mock_ship)
		
		print("✅ ProjectileManager integration test completed!")
	else:
		print("❌ Failed to load armor data for integration test")

func test_armor_lookup(ship):
	print("\n🎯 Testing Enhanced Armor Lookup:")
	
	# Test different hit scenarios using ProjectileManager's new functions
	var pm = get_node("/root/ProjectileManager") as Node
	if pm == null:
		print("❌ ProjectileManager not found as autoload")
		return
	
	# Create mock collision data
	var test_scenarios = [
		{"pos": Vector3(0, 5, 0), "normal": Vector3(0, 1, 0), "desc": "Top hull hit"},
		{"pos": Vector3(10, 0, 0), "normal": Vector3(1, 0, 0), "desc": "Side hull hit"},
		{"pos": Vector3(0, 15, -20), "normal": Vector3(0, 0, 1), "desc": "Turret front hit"}
	]
	
	for scenario in test_scenarios:
		var armor_data = pm.get_armor_thickness_at_point(ship, scenario.pos, scenario.normal)
		print("  ", scenario.desc, ": ", armor_data.thickness, "mm (", armor_data.node_path, ")")

func test_penetration_scenarios(ship):
	print("\n💥 Testing Combat Scenarios:")
	
	var pm = get_node("/root/ProjectileManager") as Node
	if pm == null:
		return
	
	# Create test shells
	var shells = [
		create_test_shell(203, 118, 1, "Cruiser AP"),
		create_test_shell(380, 800, 1, "Battleship AP"),
		create_test_shell(152, 45, 0, "Destroyer HE")
	]
	
	# Create test projectiles and collisions
	for shell_data in shells:
		var projectile = pm.ProjectileData.new()
		projectile.params = shell_data.shell
		projectile.launch_velocity = Vector3(0, 0, 800)  # 800 m/s velocity
		projectile.start_time = Time.get_unix_time_from_system()
		projectile.position = Vector3(0, 5, 0)
		
		var collision = {
			"position": Vector3(0, 5, 0),
			"normal": Vector3(0, 1, 0)
		}
		
		var result = pm.calculate_armor_interaction(projectile, collision, ship)
		print("  ", shell_data.name, " vs Hull: ", get_result_name(result.result_type), " (", "%.0fmm pen vs %.0fmm armor)" % [result.penetration_power, result.armor_thickness])

func create_test_shell(caliber: float, mass: float, type: int, shell_name: String) -> Dictionary:
	var shell = ShellParams.new()
	shell.caliber = caliber
	shell.mass = mass
	shell.type = type
	shell.damage = caliber * 10  # Simplified damage
	shell.penetration_modifier = 1.0
	shell.size = caliber / 100.0  # Visual size
	
	return {"shell": shell, "name": shell_name}

func get_result_name(result_type: int) -> String:
	match result_type:
		0: return "PENETRATION"
		1: return "RICOCHET" 
		2: return "OVERPENETRATION"
		3: return "SHATTER"
		_: return "UNKNOWN"

# Mock Ship class for testing
class MockShip:
	extends Node
	
	var armor_system: ArmorSystemV2
	var health_controller = MockHealthController.new()
	
	func get_armor_at_hit_point(_hit_node: Node3D, face_index: int) -> int:
		if armor_system == null:
			return 0
		
		# For testing, we'll simulate hitting the Hull
		return armor_system.get_face_armor_thickness("Hull", face_index)

class MockHealthController:
	extends RefCounted
	
	var max_hp = 45000  # Battleship HP for testing
