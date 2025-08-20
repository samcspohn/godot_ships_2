extends Node
class_name ArmorSystemV2

## Enhanced Armor System V2 for simplified JSON structure
## Works with {"node_path": [armor_array]} format with direct face indexing

var armor_data: Dictionary = {}
var loaded_ship_path: String = ""

signal armor_data_loaded(ship_path: String)

func load_armor_data(json_path: String) -> bool:
	"""Load armor data from simplified JSON file"""
	var file = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		print("Failed to load armor data from: ", json_path)
		return false
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	if parse_result != OK:
		print("Failed to parse armor JSON: ", json.get_error_message())
		return false
	
	armor_data = json.data
	loaded_ship_path = json_path.get_file().get_basename().replace("_hierarchy_armor", "")
	
	var total_faces = 0
	for node_path in armor_data.keys():
		total_faces += armor_data[node_path].size()
	
	print("Loaded armor data for ", armor_data.size(), " nodes with ", total_faces, " armored faces")
	armor_data_loaded.emit(loaded_ship_path)
	return true

func get_face_armor_thickness(node_path: String, face_index: int) -> int:
	"""Get armor thickness for a specific face on a node"""
	if not armor_data.has(node_path):
		return 0
	
	var armor_array = armor_data[node_path]
	if face_index >= 0 and face_index < armor_array.size():
		return armor_array[face_index]
	return 0

func get_node_armor_stats(node_path: String) -> Dictionary:
	"""Get armor statistics for a node"""
	if not armor_data.has(node_path):
		return {}
	
	var armor_array = armor_data[node_path]
	if armor_array.size() == 0:
		return {}
	
	var total_armor = 0
	var min_armor = armor_array[0]
	var max_armor = armor_array[0]
	var armor_distribution = {}
	
	for armor_value in armor_array:
		total_armor += armor_value
		min_armor = min(min_armor, armor_value)
		max_armor = max(max_armor, armor_value)
		
		# Count distribution
		if armor_distribution.has(armor_value):
			armor_distribution[armor_value] += 1
		else:
			armor_distribution[armor_value] = 1
	
	return {
		"node_path": node_path,
		"face_count": armor_array.size(),
		"min_armor": min_armor,
		"max_armor": max_armor,
		"average_armor": float(total_armor) / armor_array.size(),
		"total_armor_volume": total_armor,
		"armor_distribution": armor_distribution
	}

func get_all_armored_nodes() -> Array:
	"""Get list of all nodes that have armor"""
	return armor_data.keys()

func find_weak_points(node_path: String, max_thickness: int = 50) -> Array:
	"""Find faces with armor below specified thickness"""
	if not armor_data.has(node_path):
		return []
	
	var weak_points = []
	var armor_array = armor_data[node_path]
	
	for face_index in range(armor_array.size()):
		var armor = armor_array[face_index]
		if armor <= max_thickness:
			weak_points.append({
				"face_index": face_index,
				"armor_thickness": armor
			})
	
	return weak_points

func calculate_penetration_damage(node_path: String, face_index: int, penetration_power: int) -> Dictionary:
	"""Calculate damage based on penetration power vs armor thickness"""
	var armor_thickness = get_face_armor_thickness(node_path, face_index)
	
	var damage_info = {
		"node_path": node_path,
		"face_index": face_index,
		"armor_thickness": armor_thickness,
		"penetration_power": penetration_power,
		"penetrated": penetration_power > armor_thickness,
		"damage_ratio": 0.0,
		"damage_type": "bounce"
	}
	
	if penetration_power > armor_thickness:
		# Successful penetration
		damage_info.damage_ratio = min(1.0, float(penetration_power - armor_thickness) / max(armor_thickness, 1))
		damage_info.damage_type = "penetration"
	elif penetration_power >= armor_thickness * 0.8:
		# Partial damage from near-penetration
		damage_info.damage_ratio = (float(penetration_power) / max(armor_thickness, 1) - 0.8) / 0.2 * 0.3
		damage_info.damage_type = "damage"
	else:
		# Bounce with minimal damage
		damage_info.damage_ratio = 0.0
		damage_info.damage_type = "bounce"
	
	return damage_info

func get_armor_zone_info(node_path: String) -> Dictionary:
	"""Get armor zone classification based on node path"""
	var zone_type = "unknown"
	var importance = 1.0
	
	# Classify based on node name
	var path_lower = node_path.to_lower()
	
	if path_lower == "hull":
		zone_type = "main_belt"
		importance = 1.0
	elif "turret" in path_lower:
		zone_type = "turret_armor"
		importance = 0.9
	elif "barbette" in path_lower:
		zone_type = "barbette_armor"
		importance = 0.8
	elif "superstructure" in path_lower or "superstructrure" in path_lower:  # Handle typo in model
		zone_type = "superstructure"
		importance = 0.6
	elif "gun" in path_lower or "barrel" in path_lower:
		zone_type = "weapon"
		importance = 0.7
	
	var stats = get_node_armor_stats(node_path)
	
	return {
		"zone_type": zone_type,
		"importance": importance,
		"stats": stats,
		"node_path": node_path
	}

func print_armor_summary():
	"""Print a comprehensive summary of the loaded armor data"""
	print("\n=== Armor System V2 Summary ===")
	print("Ship: ", loaded_ship_path)
	print("Total armored nodes: ", armor_data.size())
	
	var total_faces = 0
	var zones = {}
	var overall_min = 999999
	var overall_max = 0
	
	for node_path in armor_data.keys():
		var armor_array = armor_data[node_path]
		total_faces += armor_array.size()
		
		var zone_info = get_armor_zone_info(node_path)
		var zone_type = zone_info.zone_type
		var stats = zone_info.stats
		
		if not zones.has(zone_type):
			zones[zone_type] = {
				"node_count": 0,
				"face_count": 0,
				"min_armor": 999999,
				"max_armor": 0,
				"nodes": []
			}
		
		zones[zone_type].node_count += 1
		zones[zone_type].face_count += armor_array.size()
		zones[zone_type].nodes.append(node_path)
		
		if not stats.is_empty():
			zones[zone_type].min_armor = min(zones[zone_type].min_armor, stats.min_armor)
			zones[zone_type].max_armor = max(zones[zone_type].max_armor, stats.max_armor)
			overall_min = min(overall_min, stats.min_armor)
			overall_max = max(overall_max, stats.max_armor)
	
	print("Total faces with armor: ", total_faces)
	print("Overall armor range: ", overall_min, "-", overall_max, "mm")
	
	print("\nArmor zones:")
	for zone_type in zones.keys():
		var zone = zones[zone_type]
		print("  ", zone_type.replace("_", " ").capitalize(), ":")
		print("    Nodes: ", zone.node_count, " (", zone.face_count, " faces)")
		print("    Armor: ", zone.min_armor, "-", zone.max_armor, "mm")
		for node_path in zone.nodes:
			var node_stats = get_node_armor_stats(node_path)
			if not node_stats.is_empty():
				print("      ", node_path.get_file(), ": ", node_stats.face_count, " faces, avg ", "%.0f" % node_stats.average_armor, "mm")
	
	print("===============================\n")

func get_best_target_zones(shell_penetration: int) -> Array:
	"""Get the best target zones for a shell with given penetration power"""
	var target_zones = []
	
	for node_path in armor_data.keys():
		var armor_array = armor_data[node_path]
		var zone_info = get_armor_zone_info(node_path)
		
		# Calculate penetration effectiveness
		var penetratable_faces = 0
		for armor_value in armor_array:
			if shell_penetration > armor_value:
				penetratable_faces += 1
		
		if penetratable_faces > 0:
			var penetration_ratio = float(penetratable_faces) / armor_array.size()
			var effectiveness = penetration_ratio * zone_info.importance
			
			target_zones.append({
				"node_path": node_path,
				"zone_type": zone_info.zone_type,
				"importance": zone_info.importance,
				"penetratable_faces": penetratable_faces,
				"total_faces": armor_array.size(),
				"penetration_ratio": penetration_ratio,
				"effectiveness": effectiveness,
				"average_armor": zone_info.stats.get("average_armor", 0)
			})
	
	# Sort by effectiveness
	target_zones.sort_custom(func(a, b): return a.effectiveness > b.effectiveness)
	
	return target_zones

func find_all_weak_points(max_armor_thickness: int = 100) -> Array:
	"""Find all weak points across the entire ship"""
	var all_weak_points = []
	
	for node_path in armor_data.keys():
		var weak_points = find_weak_points(node_path, max_armor_thickness)
		
		for weak_point in weak_points:
			weak_point.node_path = node_path
			weak_point.zone_info = get_armor_zone_info(node_path)
			all_weak_points.append(weak_point)
	
	# Sort by armor thickness (thinnest first)
	all_weak_points.sort_custom(func(a, b): return a.armor_thickness < b.armor_thickness)
	
	return all_weak_points

# Helper function for integration with Godot nodes
# func get_armor_for_mesh_face(mesh_node: Node3D, face_index: int) -> int:
# 	"""Get armor for a mesh face using the node's scene path"""
# 	var node_path = get_node_path_from_scene(mesh_node)
# 	return get_face_armor_thickness(node_path, face_index)

func get_node_path_from_scene(node: Node3D, root: String) -> String:
	# node is a StaticBody3D. need parent for name
	"""Convert a scene node to the armor data path format"""
	# This is a simplified version - you might need to adjust based on your scene structure
	var path_parts = []
	var current_node = node.get_parent()
	
	while current_node != null and current_node.name != root:
		path_parts.push_front(current_node.name)
		current_node = current_node.get_parent()
		if current_node == null or not current_node is Node3D:
			break
	return "/".join(path_parts)
