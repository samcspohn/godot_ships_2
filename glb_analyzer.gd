# glb_analyzer.gd
# Tool script to analyze GLB file contents and custom attributes
@tool
extends EditorScript

func _run():
	# Update this path to your GLB file
	var file_path = "res://ShipModels/bismark_low_poly.glb"
	
	print("=== Starting GLB Analysis ===")
	print("File: ", file_path)
	
	if not FileAccess.file_exists(file_path):
		print("ERROR: File not found at ", file_path)
		return
	
	analyze_glb_file(file_path)

func analyze_glb_file(file_path: String):
	var gltf_doc = GLTFDocument.new()
	var gltf_state = GLTFState.new()
	
	var error = gltf_doc.append_from_file(file_path, gltf_state)
	if error != OK:
		print("ERROR: Failed to load GLB file. Error code: ", error)
		return
	
	print("✓ GLB file loaded successfully")
	print("")
	
	# Analyze the JSON structure
	analyze_json_structure(gltf_state)
	
	# Analyze the imported meshes
	analyze_imported_meshes(gltf_state)
	
	# Check accessors for custom data
	analyze_accessors(gltf_state)
	
	print("=== Analysis Complete ===")

func analyze_json_structure(state: GLTFState):
	print("--- JSON Structure Analysis ---")
	
	var json_data = state.get_json()
	print("JSON keys: ", json_data.keys())
	
	if json_data.has("asset"):
		var asset = json_data["asset"]
		print("GLTF Version: ", asset.get("version", "unknown"))
		print("Generator: ", asset.get("generator", "unknown"))
	
	if json_data.has("meshes"):
		print("Number of meshes in JSON: ", json_data["meshes"].size())
		
		for i in json_data["meshes"].size():
			var mesh_data = json_data["meshes"][i]
			print("\nMesh ", i, ":")
			print("  Name: ", mesh_data.get("name", "unnamed"))
			
			if mesh_data.has("primitives"):
				print("  Primitives: ", mesh_data["primitives"].size())
				
				for j in mesh_data["primitives"].size():
					var primitive = mesh_data["primitives"][j]
					print("    Primitive ", j, ":")
					
					if primitive.has("attributes"):
						var attributes = primitive["attributes"]
						print("      Standard attributes:")
						for attr_name in attributes.keys():
							if not is_custom_attribute(attr_name):
								print("        ", attr_name, " -> accessor ", attributes[attr_name])
						
						print("      Custom attributes:")
						var found_custom = false
						for attr_name in attributes.keys():
							if is_custom_attribute(attr_name):
								print("        ★ ", attr_name, " -> accessor ", attributes[attr_name])
								found_custom = true
						
						if not found_custom:
							print("        (none found)")
					
					if primitive.has("material"):
						print("      Material: ", primitive["material"])
	else:
		print("No meshes found in JSON")
	
	print("")

func analyze_imported_meshes(state: GLTFState):
	print("--- Imported Meshes Analysis ---")
	
	var meshes = state.get_meshes()
	print("Number of imported meshes: ", meshes.size())
	
	for i in meshes.size():
		var gltf_mesh = meshes[i]
		var mesh = gltf_mesh.mesh
		
		print("\nImported Mesh ", i, ":")
		print("  Resource name: ", mesh.resource_name if mesh.resource_name else "unnamed")
		print("  Surface count: ", mesh.get_surface_count())
		
		for surface_idx in mesh.get_surface_count():
			print("    Surface ", surface_idx, ":")
			
			var arrays = mesh.surface_get_arrays(surface_idx)
			var format = mesh.surface_get_format(surface_idx)
			
			print("      Format flags: ", format, " (binary: ", var_to_str(format).substr(0, 32), ")")
			print("      Arrays present:")
			
			# Check standard arrays
			check_array_presence(arrays, Mesh.ARRAY_VERTEX, "VERTEX")
			check_array_presence(arrays, Mesh.ARRAY_NORMAL, "NORMAL")
			check_array_presence(arrays, Mesh.ARRAY_TANGENT, "TANGENT")
			check_array_presence(arrays, Mesh.ARRAY_COLOR, "COLOR")
			check_array_presence(arrays, Mesh.ARRAY_TEX_UV, "TEX_UV")
			check_array_presence(arrays, Mesh.ARRAY_TEX_UV2, "TEX_UV2")
			check_array_presence(arrays, Mesh.ARRAY_BONES, "BONES")
			check_array_presence(arrays, Mesh.ARRAY_WEIGHTS, "WEIGHTS")
			check_array_presence(arrays, Mesh.ARRAY_INDEX, "INDEX")
			
			# Check custom arrays
			print("      Custom arrays:")
			var found_custom_arrays = false
			for custom_idx in range(4):
				var array_idx = Mesh.ARRAY_CUSTOM0 + custom_idx
				if array_idx < arrays.size() and arrays[array_idx] != null:
					var custom_format = get_custom_format(format, custom_idx)
					print("        ★ CUSTOM", custom_idx, ": ", typeof(arrays[array_idx]), " size: ", get_array_size(arrays[array_idx]), " format: ", get_custom_format_name(custom_format))
					
					# Sample the data
					sample_custom_array_data(arrays[array_idx], custom_idx)
					found_custom_arrays = true
			
			if not found_custom_arrays:
				print("        (none found)")
	
	print("")

func analyze_accessors(state: GLTFState):
	print("--- Accessors Analysis ---")
	
	var json_data = state.get_json()
	if not json_data.has("accessors"):
		print("No accessors found in GLB")
		return
	
	var accessors = json_data["accessors"]
	print("Number of accessors: ", accessors.size())
	
	for i in accessors.size():
		var accessor = accessors[i]
		print("  Accessor ", i, ":")
		print("    Type: ", accessor.get("type", "unknown"))
		print("    Component Type: ", accessor.get("componentType", "unknown"), " (", get_component_type_name(accessor.get("componentType", 0)), ")")
		print("    Count: ", accessor.get("count", 0))
		
		if accessor.has("bufferView"):
			print("    Buffer View: ", accessor["bufferView"])
		
		if accessor.has("name"):
			print("    Name: ", accessor["name"])
	
	print("")

# Helper functions
func is_custom_attribute(attr_name: String) -> bool:
	return attr_name.begins_with("_") or attr_name.begins_with("CUSTOM") or attr_name.to_upper().begins_with("COLOR_") and attr_name != "COLOR_0"

func check_array_presence(arrays: Array, index: int, name: String):
	if index < arrays.size() and arrays[index] != null:
		print("        ✓ ", name, ": ", typeof(arrays[index]), " size: ", get_array_size(arrays[index]))
	else:
		print("        ✗ ", name, ": not present")

func get_array_size(array) -> String:
	if array == null:
		return "null"
	elif array.has_method("size"):
		return str(array.size())
	else:
		return "unknown"

func get_custom_format(surface_format: int, custom_index: int) -> int:
	var shift = 0
	match custom_index:
		0: shift = 13
		1: shift = 16
		2: shift = 19
		3: shift = 22
	
	return (surface_format >> shift) & 0x7

func get_custom_format_name(format: int) -> String:
	match format:
		0: return "NONE"
		1: return "RGBA8_UNORM"
		2: return "RGBA8_SNORM"
		3: return "RG_HALF"
		4: return "RGBA_HALF"
		5: return "R_FLOAT"
		6: return "RG_FLOAT"
		7: return "RGB_FLOAT"
		_: return "RGBA_FLOAT"

func get_component_type_name(type: int) -> String:
	match type:
		5120: return "BYTE"
		5121: return "UNSIGNED_BYTE"
		5122: return "SHORT"
		5123: return "UNSIGNED_SHORT"
		5125: return "UNSIGNED_INT"
		5126: return "FLOAT"
		_: return "UNKNOWN"

func sample_custom_array_data(array, custom_idx: int, max_samples: int = 5):
	if array == null:
		return
	
	print("          Sample data (first ", max_samples, " elements):")
	
	if array is PackedByteArray:
		for i in range(min(max_samples * 4, array.size())):
			if i % 4 == 0:
				var rgba = []
				for j in range(4):
					if i + j < array.size():
						rgba.append(array[i + j])
				print("            [", i/4, "]: RGBA(", rgba, ")")
	
	elif array is PackedFloat32Array:
		for i in range(min(max_samples, array.size())):
			print("            [", i, "]: ", array[i])
	
	elif array is PackedVector2Array:
		for i in range(min(max_samples, array.size())):
			print("            [", i, "]: ", array[i])
	
	elif array is PackedVector3Array:
		for i in range(min(max_samples, array.size())):
			print("            [", i, "]: ", array[i])
	
	elif array is PackedColorArray:
		for i in range(min(max_samples, array.size())):
			print("            [", i, "]: ", array[i])
	
	else:
		print("            Type: ", typeof(array), " (can't sample)")
