extends Node

class_name HitCounterTest

# Test the hit counter system functionality

func test_hit_counter_system():
	"""Test the hit counter system with simulated damage events"""
	print("=== Hit Counter System Test ===")
	
	# Find the camera UI in the scene
	var camera_ui = get_tree().get_nodes_in_group("camera_ui")
	if camera_ui.size() == 0:
		print("ERROR: No camera UI found in scene")
		return false
		
	var ui = camera_ui[0] as CameraUIScene
	if not ui:
		print("ERROR: Camera UI is not CameraUIScene type")
		return false
	
	print("✓ Found camera UI")
	
	# Test 1: Single penetration hit
	print("\n--- Test 1: Single Main Penetration ---")
	ui.show_hit_counter("penetration", false)
	print("✓ Displayed main penetration counter")
	
	# Test 2: Secondary shatter hit  
	print("\n--- Test 2: Secondary Shatter ---")
	ui.show_hit_counter("shatter", true)
	print("✓ Displayed secondary shatter counter")
	
	# Test 3: Multiple hits of same type
	print("\n--- Test 3: Multiple Penetrations ---")
	ui.show_hit_counter("penetration", false)  # Should increment
	ui.show_hit_counter("penetration", false)  # Should increment again
	print("✓ Incremented penetration counter")
	
	# Test 4: Different hit types
	print("\n--- Test 4: Various Hit Types ---")
	ui.show_hit_counter("ricochet", false)
	ui.show_hit_counter("overpenetration", true)
	ui.show_hit_counter("citadel", false)
	print("✓ Displayed various hit types")
	
	# Test 5: Damage event processing
	print("\n--- Test 5: Damage Event Processing ---")
	var test_events = [
		{"type": 0, "sec": false, "damage": 1000, "position": Vector3.ZERO},  # PENETRATION
		{"type": 3, "sec": true, "damage": 100, "position": Vector3.ZERO},   # SHATTER (secondary)
		{"type": 1, "sec": false, "damage": 0, "position": Vector3.ZERO},    # RICOCHET
		{"type": 5, "sec": false, "damage": 2000, "position": Vector3.ZERO}, # CITADEL
	]
	
	ui.process_damage_events(test_events)
	print("✓ Processed damage events")
	
	print("\n=== Hit Counter Test Complete ===")
	print("Check the right side of the screen for hit counters")
	print("Counters should disappear after 5 seconds")
	
	return true

func test_hit_type_conversion():
	"""Test the hit type conversion function"""
	print("\n=== Hit Type Conversion Test ===")
	
	var camera_ui = get_tree().get_nodes_in_group("camera_ui")
	if camera_ui.size() == 0:
		print("ERROR: No camera UI found")
		return false
		
	var ui = camera_ui[0] as CameraUIScene
	
	# Test each hit result type
	var test_cases = [
		{"type": 0, "expected": "penetration"},
		{"type": 1, "expected": "ricochet"},
		{"type": 2, "expected": "overpenetration"},
		{"type": 3, "expected": "shatter"},
		{"type": 5, "expected": "citadel"},
		{"type": -1, "expected": ""},  # Unknown type
		{"type": 999, "expected": ""}, # Invalid type
	]
	
	for test_case in test_cases:
		var event = {"type": test_case.type}
		var result = ui.get_hit_type_from_event(event)
		if result == test_case.expected:
			print("✓ Type %d -> '%s'" % [test_case.type, result])
		else:
			print("✗ Type %d -> '%s' (expected '%s')" % [test_case.type, result, test_case.expected])
			return false
	
	print("✓ All hit type conversions working correctly")
	return true

func _ready():
	# Wait a moment for the scene to fully load
	await get_tree().process_frame
	await get_tree().process_frame
	
	# Run tests
	test_hit_type_conversion()
	test_hit_counter_system()
