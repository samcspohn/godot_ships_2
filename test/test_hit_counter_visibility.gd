extends Control

# Test the new visibility-based hit counter system

func _ready():
	print("Testing Hit Counter System...")
	test_hit_counter_functionality()

func test_hit_counter_functionality():
	# Find the camera UI scene
	var camera_ui_scene = get_node("/root/Main/CameraUI")
	if not camera_ui_scene:
		print("ERROR: Could not find camera UI scene")
		return
	
	# Test the hit counter references
	print("Testing hit counter references...")
	
	# Check main counter temp container
	var main_counter_temp = camera_ui_scene.get_node("MainContainer/TopRightPanel/MainCounterTemp")
	if main_counter_temp:
		print("✓ MainCounterTemp found")
		print("  Children: ", main_counter_temp.get_children().size())
	else:
		print("✗ MainCounterTemp not found")
	
	# Check secondary counter temp container
	var sec_counter_temp = camera_ui_scene.get_node("MainContainer/TopRightPanel/SecCounterTemp")
	if sec_counter_temp:
		print("✓ SecCounterTemp found")
		print("  Children: ", sec_counter_temp.get_children().size())
	else:
		print("✗ SecCounterTemp not found")
	
	# Test individual counters
	test_individual_counters(main_counter_temp, "Main")
	test_individual_counters(sec_counter_temp, "Secondary")
	
	# Test the hit counter system functions
	if camera_ui_scene.has_method("show_hit_counter"):
		print("✓ show_hit_counter method exists")
		
		# Test showing different hit types
		camera_ui_scene.show_hit_counter("penetration", false)  # Main
		camera_ui_scene.show_hit_counter("ricochet", true)      # Secondary
		camera_ui_scene.show_hit_counter("citadel", false)     # Main
		
		print("Hit counters activated - check visibility")
	else:
		print("✗ show_hit_counter method not found")

func test_individual_counters(container, type_name):
	if not container:
		return
		
	print("Testing ", type_name, " counters:")
	var expected_counters = ["TempPenetrationCounter", "TempOverpenetrationCounter", 
							"TempShatterCounter", "TempRicochetCounter", "TempCitadelCounter"]
	
	for counter_name in expected_counters:
		var counter = container.get_node_or_null(counter_name)
		if counter:
			print("  ✓ ", counter_name, " found")
			var label = counter.get_node_or_null("Label")
			if label:
				print("    - Label text: '", label.text, "'")
			else:
				print("    ✗ Label not found")
		else:
			print("  ✗ ", counter_name, " not found")
