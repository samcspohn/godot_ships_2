extends SceneTree

# Test script for the enhanced armor extractor with vertex-to-face conversion

func _init():
	test_armor_extraction()
	quit()

func test_armor_extraction():
	print("=== Testing Enhanced Armor Extractor V2 with Vertex-to-Face Conversion ===")
	
	var extractor = EnhancedArmorExtractorV2.new()
	var glb_path = "ShipModels/bismark_low_poly.glb"
	var json_output_path = "bismark_low_poly_enhanced_v2.json"
	
	print("Testing extraction from: ", glb_path)
	
	if not FileAccess.file_exists(glb_path):
		print("GLB file not found: ", glb_path)
		return
	
	var success = extractor.extract_armor_with_mapping_to_json(glb_path, json_output_path)
	
	if success:
		print("✅ Armor extraction completed successfully!")
		print("Output saved to: ", json_output_path)
		
		# Print some statistics
		var total_faces = 0
		for node_path in extractor.node_armor_mapping.keys():
			var armor_array = extractor.node_armor_mapping[node_path]
			total_faces += armor_array.size()
			print("Node: ", node_path, " - ", armor_array.size(), " faces")
		
		print("Total faces with armor data: ", total_faces)
	else:
		print("❌ Armor extraction failed")
