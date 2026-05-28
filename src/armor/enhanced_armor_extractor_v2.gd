extends Node
class_name EnhancedArmorExtractorV2

## Enhanced Armor Extractor with proper GLTF node hierarchy traversal
## Creates correct mapping from GLTF nodes to armor data using mesh indices

var armor_map: Dictionary = {}  # Raw armor data by mesh index
var node_armor_mapping: Dictionary = {}  # Final node -> armor array mapping

func extract_armor_with_node_mapping(file_path: String) -> Dictionary:
	"""
	Extract armor data using proper GLTF node hierarchy traversal
	Returns simplified structure: {"node_path": [armor_values]}
	"""
	armor_map.clear()
	node_armor_mapping.clear()

	# Load the GLB file
	var gltf_doc = GLTFDocument.new()
	var gltf_state = GLTFState.new()

	var error = gltf_doc.append_from_file(file_path, gltf_state)
	if error != OK:
		print("Failed to load GLB file: ", file_path)
		return {}

	# Extract raw armor data from GLB binary first
	extract_armor_data_from_binary(gltf_state, file_path)

	# Build proper node hierarchy mapping from GLTF structure
	build_node_to_armor_mapping(gltf_state)

	# Return the simplified mapping
	return node_armor_mapping

func extract_armor_data_from_binary(gltf_state: GLTFState, file_path: String):
	"""Extract armor data from GLTF binary data and store by mesh index"""
	var gltf_json = gltf_state.get_json()
	if gltf_json == null:
		print("No GLTF JSON data available")
		return

	print("Extracting armor data from GLB binary...")
	# print(gltf_json)

	if not gltf_json.has("meshes"):
		print("No meshes found in GLTF")
		return

	# Extract armor data from mesh primitives
	for mesh_index in range(gltf_json["meshes"].size()):
		var mesh = gltf_json["meshes"][mesh_index]

		if not mesh.has("primitives"):
			continue

		var mesh_armor_data: Array[int] = []

		for prim_index in range(mesh["primitives"].size()):
			var primitive = mesh["primitives"][prim_index]

			# Check for _ARMOR attribute and indices
			if primitive.has("attributes") and primitive["attributes"].has("_ARMOR"):
				var armor_accessor_index = primitive["attributes"]["_ARMOR"]
				var vertex_armor_data = extract_armor_from_accessor(gltf_json, armor_accessor_index, file_path)

				if vertex_armor_data.size() > 0:
					print("  Extracted ", vertex_armor_data.size(), " vertex armor values from mesh ", mesh_index, " primitive ", prim_index)

					# Extract indices to convert vertex armor to face armor
					if primitive.has("indices"):
						var indices_accessor_index = primitive["indices"]
						var indices_data = extract_indices_from_accessor(gltf_json, indices_accessor_index, file_path)

						if indices_data.size() > 0:
							# Convert vertex-based armor to face-based armor using indices
							var face_armor_data = convert_vertex_armor_to_face_armor(vertex_armor_data, indices_data, mesh_index, prim_index)
							mesh_armor_data.append_array(face_armor_data)
							print("  Converted to ", face_armor_data.size(), " face armor values")
						else:
							print("  Warning: No indices found for primitive with armor data")
					else:
						print("  Warning: Primitive has armor but no indices - cannot convert to face-based armor")

		if mesh_armor_data.size() > 0:
			armor_map[mesh_index] = mesh_armor_data
			print("Total armor data for mesh ", mesh_index, ": ", mesh_armor_data.size(), " values")

func extract_armor_from_accessor(gltf_json: Dictionary, accessor_index: int, file_path: String) -> Array[int]:
	"""Extract armor values from GLTF accessor with proper binary parsing"""
	if not gltf_json.has("accessors"):
		print("No accessors in GLTF")
		return []

	var accessors = gltf_json["accessors"]
	if accessor_index >= accessors.size():
		print("Accessor index out of range: ", accessor_index)
		return []

	var accessor = accessors[accessor_index]
	if not accessor.has("bufferView"):
		print("Accessor has no bufferView")
		return []

	var buffer_view_index = accessor["bufferView"]
	var component_type = accessor.get("componentType", 5126)  # Default to FLOAT
	var count = accessor.get("count", 0)

	# Read binary data from GLB
	var armor_values = read_glb_buffer_data(file_path, gltf_json, buffer_view_index, component_type, count)
	return armor_values

func read_glb_buffer_data(file_path: String, gltf_json: Dictionary, buffer_view_index: int, component_type: int, count: int) -> Array[int]:
	"""Read binary data directly from GLB file"""
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		print("Cannot open GLB file for binary reading: ", file_path)
		return []

	# Read GLB header
	var magic = file.get_32()
	if magic != 0x46546C67:  # "glTF"
		print("Invalid GLB magic number")
		file.close()
		return []

	var _version = file.get_32()
	var _length = file.get_32()

	# Skip JSON chunk
	var json_chunk_length = file.get_32()
	var _json_chunk_type = file.get_32()
	file.seek(file.get_position() + json_chunk_length)

	# Read BIN chunk header
	var _bin_chunk_length = file.get_32()
	var _bin_chunk_type = file.get_32()
	var bin_data_start = file.get_position()

	# Get buffer view info
	if not gltf_json.has("bufferViews"):
		print("No bufferViews in GLTF")
		file.close()
		return []

	var buffer_views = gltf_json["bufferViews"]
	if buffer_view_index >= buffer_views.size():
		print("BufferView index out of range: ", buffer_view_index)
		file.close()
		return []

	var buffer_view = buffer_views[buffer_view_index]
	var byte_offset = buffer_view.get("byteOffset", 0)
	var _byte_length = buffer_view.get("byteLength", 0)

	# Seek to the data position
	file.seek(bin_data_start + byte_offset)

	# Parse binary data based on component type
	var armor_data = parse_binary_armor_data(file, component_type, count)

	file.close()
	return armor_data

func parse_binary_armor_data(file: FileAccess, component_type: int, count: int) -> Array[int]:
	"""Parse binary armor data based on component type"""
	var armor_values: Array[int] = []

	for i in range(count):
		var value: int = 0
		match component_type:
			5126:  # FLOAT
				value = int(file.get_float())
			5125:  # UNSIGNED_INT
				value = int(file.get_32())
			5123:  # UNSIGNED_SHORT
				value = int(file.get_16())
			5121:  # UNSIGNED_BYTE
				value = int(file.get_8())
			5124:  # SIGNED_INT
				value = file.get_32()
			5122:  # SIGNED_SHORT
				value = file.get_16()
			5120:  # SIGNED_BYTE
				value = file.get_8()
			_:
				print("Unsupported component type: ", component_type)
				value = 100  # Default fallback

		armor_values.append(value)

	return armor_values

func extract_indices_from_accessor(gltf_json: Dictionary, accessor_index: int, file_path: String) -> Array[int]:
	"""Extract indices from GLTF accessor for face construction"""
	if not gltf_json.has("accessors"):
		print("No accessors in GLTF")
		return []

	var accessors = gltf_json["accessors"]
	if accessor_index >= accessors.size():
		print("Indices accessor index out of range: ", accessor_index)
		return []

	var accessor = accessors[accessor_index]
	if not accessor.has("bufferView"):
		print("Indices accessor has no bufferView")
		return []

	var buffer_view_index = accessor["bufferView"]
	var component_type = accessor.get("componentType", 5123)  # Default to UNSIGNED_SHORT
	var count = accessor.get("count", 0)

	# Read binary indices data from GLB
	var indices_values = read_glb_buffer_data(file_path, gltf_json, buffer_view_index, component_type, count)
	return indices_values

func convert_vertex_armor_to_face_armor(vertex_armor: Array[int], indices: Array[int], mesh_index: int, prim_index: int) -> Array[int]:
	"""Convert vertex-based armor data to face-based using indices with validation"""
	var face_armor: Array[int] = []

	# Indices are typically in groups of 3 for triangular faces
	if indices.size() % 3 != 0:
		print("Warning: Indices count (", indices.size(), ") is not divisible by 3 for mesh ", mesh_index, " primitive ", prim_index)
		return face_armor

	var face_count = int(indices.size() / 3)  # Convert to integer for triangular faces
	print("  Processing ", face_count, " faces from ", indices.size(), " indices")

	# Process each face (triangle)
	for face_idx in range(face_count):
		var idx_offset = face_idx * 3
		var vertex_idx1 = indices[idx_offset]
		var vertex_idx2 = indices[idx_offset + 1]
		var vertex_idx3 = indices[idx_offset + 2]

		# Validate vertex indices
		if vertex_idx1 >= vertex_armor.size() or vertex_idx2 >= vertex_armor.size() or vertex_idx3 >= vertex_armor.size():
			print("Warning: Vertex index out of range for face ", face_idx, " in mesh ", mesh_index, " primitive ", prim_index)
			face_armor.append(0)  # Default armor value
			continue

		# Get armor values for the three vertices of this face
		var armor1 = vertex_armor[vertex_idx1]
		var armor2 = vertex_armor[vertex_idx2]
		var armor3 = vertex_armor[vertex_idx3]

		# Validate that all vertices of a face have the same armor value
		if armor1 != armor2 or armor1 != armor3:
			print("⚠️ Face ", face_idx, " has inconsistent armor values: v1=", armor1, " v2=", armor2, " v3=", armor3,
				  " (vertices: ", vertex_idx1, ",", vertex_idx2, ",", vertex_idx3, ") - using first vertex value")

		# Use the armor value from the first vertex (they should all be the same)
		face_armor.append(armor1)

		# Debug output every 1000 faces to avoid spam
		if face_idx % 1000 == 0 and face_idx > 0:
			print("  Processed ", face_idx, " faces...")

	print("  Successfully converted ", face_count, " faces with armor values")
	return face_armor

func build_sibling_names_map(gltf_json: Dictionary) -> Dictionary:
	"""Build a map of node_index -> array of raw sibling names (nodes sharing the same parent)"""
	var siblings: Dictionary = {}

	if not gltf_json.has("nodes"):
		return siblings

	var nodes = gltf_json["nodes"]

	# Root-level nodes are siblings of each other
	if gltf_json.has("scenes") and gltf_json["scenes"].size() > 0:
		var scene = gltf_json["scenes"][0]
		if scene.has("nodes"):
			var root_names: Array[String] = []
			for root_idx in scene["nodes"]:
				var root_idx_int: int = int(root_idx)
				if root_idx_int < nodes.size():
					root_names.append(nodes[root_idx_int].get("name", ""))
			for root_idx in scene["nodes"]:
				siblings[int(root_idx)] = root_names

	# Non-root nodes: each parent's children are siblings of each other
	for node_index in range(nodes.size()):
		var node = nodes[node_index]
		if node.has("children"):
			var child_names: Array[String] = []
			for child_idx in node["children"]:
				var child_idx_int: int = int(child_idx)
				if child_idx_int < nodes.size():
					child_names.append(nodes[child_idx_int].get("name", ""))
			for child_idx in node["children"]:
				siblings[int(child_idx)] = child_names

	return siblings

func get_godot_node_name(raw_name: String, sibling_raw_names: Array) -> String:
	"""
	Apply Godot's GLB import renaming: if a node ends with _col (with optional number
	suffix) and no sibling exists with the base name, Godot strips the _col suffix.
	  barbette_col       -> barbette       (no sibling named barbette)
	  barbette_col.001   -> barbette_001   (no sibling named barbette.001)
	  barbette_col_001   -> barbette_001   (no sibling named barbette_001)
	If a matching sibling does exist, the name is kept (dots normalized to underscores).
	"""
	var col_regex = RegEx.new()
	col_regex.compile("^(.+)_col(?:\\.(\\d+)|_(\\d+))?$")
	var m = col_regex.search(raw_name)

	if m == null:
		# No _col pattern: just normalize dots to underscores (Godot import behavior)
		return raw_name.replace(".", "_")

	var base: String = m.get_string(1)       # e.g. "barbette"
	var dot_num: String = m.get_string(2)    # e.g. "001" when suffix was .001, else ""
	var under_num: String = m.get_string(3)  # e.g. "001" when suffix was _001, else ""

	var candidate_raw: String  # The sibling name that would conflict (raw GLB name)
	var stripped_name: String  # The Godot name if _col is stripped

	if dot_num != "":
		candidate_raw = base + "." + dot_num   # "barbette.001"
		stripped_name = base + "_" + dot_num   # "barbette_001"
	elif under_num != "":
		candidate_raw = base + "_" + under_num  # "barbette_001"
		stripped_name = base + "_" + under_num  # "barbette_001"
	else:
		candidate_raw = base   # "barbette"
		stripped_name = base   # "barbette"

	if candidate_raw in sibling_raw_names:
		# A sibling with the base name exists; Godot keeps _col (normalize dots only)
		return raw_name.replace(".", "_")
	else:
		# No conflicting sibling; Godot strips _col
		return stripped_name

func build_node_to_armor_mapping(gltf_state: GLTFState):
	"""Build node hierarchy mapping using GLTF structure"""
	var gltf_json = gltf_state.get_json()
	if gltf_json == null:
		print("No GLTF JSON data available for hierarchy mapping")
		return

	print("Building GLTF node hierarchy mapping...")

	# Process each scene in the GLTF
	if not gltf_json.has("scenes"):
		print("No scenes found in GLTF")
		return

	# Build sibling map so each node can check for name conflicts
	var node_sibling_names: Dictionary = build_sibling_names_map(gltf_json)

	# Process the first scene (usually the main scene)
	if gltf_json["scenes"].size() > 0:
		var scene = gltf_json["scenes"][0]
		print("Processing main scene")

		if scene.has("nodes"):
			for root_node_index in scene["nodes"]:
				traverse_node_hierarchy(gltf_json, int(root_node_index), "", node_sibling_names)

func traverse_node_hierarchy(gltf_json: Dictionary, node_index: int, parent_path: String, node_sibling_names: Dictionary):
	"""Recursively traverse GLTF node hierarchy and map to armor data"""
	if not gltf_json.has("nodes"):
		return

	var nodes = gltf_json["nodes"]
	if node_index >= nodes.size():
		return

	var node = nodes[node_index]
	var raw_name: String = node.get("name", "Node_" + str(node_index))

	# Apply Godot's import-time renaming (strips _col when no sibling conflicts)
	var siblings: Array = node_sibling_names.get(node_index, [])
	var godot_name: String = get_godot_node_name(raw_name, siblings)

	# Build the hierarchical path using the Godot-resolved name
	var current_path: String
	if parent_path == "":
		current_path = godot_name
	else:
		current_path = parent_path + "/" + godot_name

	print("Processing GLTF node: ", raw_name, " -> ", godot_name, " (path: ", current_path, ")")

	# Check if this node has a mesh
	if node.has("mesh"):
		var mesh_index = int(node["mesh"])  # Convert to int
		print("  Node has mesh index: ", mesh_index)

		# Find armor data for this mesh
		if armor_map.has(mesh_index):
			var mesh_armor_data = armor_map[mesh_index]
			node_armor_mapping[current_path] = mesh_armor_data
			print("  Mapped armor data: ", mesh_armor_data.size(), " values to node: ", current_path)
		else:
			print("  No armor data found for mesh index: ", mesh_index)

	# Recursively process children
	if node.has("children"):
		for child_index in node["children"]:
			traverse_node_hierarchy(gltf_json, int(child_index), current_path, node_sibling_names)

func get_armor_for_face(node_path: String, face_index: int) -> int:
	"""Get armor value for a specific face on a specific node"""
	if not node_armor_mapping.has(node_path):
		return 0

	var armor_array = node_armor_mapping[node_path]
	if face_index >= 0 and face_index < armor_array.size():
		return armor_array[face_index]
	return 0

func get_node_armor_info(node_path: String) -> Dictionary:
	"""Get complete armor information for a node"""
	if not node_armor_mapping.has(node_path):
		return {}

	var armor_array = node_armor_mapping[node_path]

	return {
		"node_path": node_path,
		"armor_array": armor_array,
		"face_count": armor_array.size(),
		"min_armor": armor_array.min() if armor_array.size() > 0 else 0,
		"max_armor": armor_array.max() if armor_array.size() > 0 else 0
	}

func save_armor_mapping_to_json(output_path: String) -> bool:
	"""Save armor mapping to JSON file with simplified structure"""
	var json_string = JSON.stringify(node_armor_mapping, "\t")

	var file = FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		print("Failed to create armor mapping file: ", output_path)
		return false

	file.store_string(json_string)
	file.close()

	print("Armor mapping saved to: ", output_path)
	print("Structure: {\"node_path\": [armor_array]} with direct face index correspondence")
	print("Total nodes with armor: ", node_armor_mapping.size())

	# Print summary
	for node_path in node_armor_mapping.keys():
		var armor_array = node_armor_mapping[node_path]
		print("  ", node_path, ": ", armor_array.size(), " faces")

	return true

# Main function for enhanced extraction
func extract_armor_with_mapping_to_json(glb_path: String, json_output_path: String = "") -> bool:
	"""Extract armor data with proper GLTF node mapping and save to JSON"""
	if json_output_path == "":
		var base_name = glb_path.get_basename()
		json_output_path = base_name + "_enhanced_armor.json"

	print("Enhanced armor extraction from: ", glb_path)
	var result = extract_armor_with_node_mapping(glb_path)

	if result.is_empty():
		print("No armor data found in GLB file")
		return false

	print("Found armor data for ", result.size(), " nodes")
	save_armor_mapping_to_json(json_output_path)
	return true
