extends Node

## Test script for the Enhanced Armor Extractor V2
## Tests the proper GLTF hierarchy traversal

const EnhancedArmorExtractorV2 = preload("res://enhanced_armor_extractor_v2.gd")

func _ready():
	test_enhanced_armor_extraction_v2()

func test_enhanced_armor_extraction_v2():
	print("=== Testing Enhanced Armor Extraction V2 ===")
	print("Using proper GLTF node hierarchy traversal")
	
	var extractor = EnhancedArmorExtractorV2.new()
	
	var glb_file_path = "ShipModels/bismark_low_poly.glb"
	var json_output_path = "bismark_hierarchy_armor.json"
	
	if not FileAccess.file_exists(glb_file_path):
		print("GLB file not found: ", glb_file_path)
		return
	
	# Test enhanced extraction with proper hierarchy
	print("Starting enhanced armor extraction with GLTF hierarchy...")
	extractor.extract_armor_with_mapping_to_json(glb_file_path, json_output_path)
	
	# Test individual armor lookup functions
	test_armor_lookup_functions_v2(extractor)
	
	extractor.queue_free()

func test_armor_lookup_functions_v2(extractor: EnhancedArmorExtractorV2):
	print("\n=== Testing Armor Lookup Functions V2 ===")
	
	# Get list of nodes with armor
	var node_mappings = extractor.node_armor_mapping
	print("Nodes with armor mapping: ", node_mappings.keys().size())
	
	# Show all node paths found
	print("\nAll armored node paths:")
	for node_path in node_mappings.keys():
		var armor_array = node_mappings[node_path]
		print("  ", node_path, ": ", armor_array.size(), " faces")
		
		# Show armor range for this node
		var min_armor = armor_array.min() if armor_array.size() > 0 else 0
		var max_armor = armor_array.max() if armor_array.size() > 0 else 0
		print("    Armor range: ", min_armor, "-", max_armor, "mm")
		
		# Test face-specific queries
		if armor_array.size() > 0:
			var face_0_armor = extractor.get_armor_for_face(node_path, 0)
			var face_mid_armor = extractor.get_armor_for_face(node_path, armor_array.size() / 2)
			var face_last_armor = extractor.get_armor_for_face(node_path, armor_array.size() - 1)
			
			print("    Sample faces - 0: ", face_0_armor, "mm, mid: ", face_mid_armor, "mm, last: ", face_last_armor, "mm")
	
	# Test node info function
	print("\nDetailed node information:")
	var test_nodes = []
	var node_keys = node_mappings.keys()
	
	# Test up to 5 nodes for detailed info
	for i in range(min(5, node_keys.size())):
		test_nodes.append(node_keys[i])
	
	for node_path in test_nodes:
		var node_info = extractor.get_node_armor_info(node_path)
		if not node_info.is_empty():
			print("  Node: ", node_info.node_path)
			print("    Face count: ", node_info.face_count)
			print("    Armor range: ", node_info.min_armor, "-", node_info.max_armor, "mm")

func _exit_tree():
	print("Enhanced armor extraction V2 test complete")
