# src/client/shell_event_parser.gd
extends RefCounted

class_name ShellEventParser

# Represents a single event in the shell's trajectory
class ShellEvent:
	var event_type: String  # "Ship", "Shell", or "Armor"
	var data: Dictionary
	
	func _init(type: String, event_data: Dictionary):
		event_type = type
		data = event_data

# Parse the entire text input and return an array of events
static func parse_events(text: String) -> Array:
	var events: Array = []
	var lines = text.split("\n")
	
	for line in lines:
		line = line.strip_edges()
		if line.is_empty():
			continue
		
		if line.begins_with("Processing Shell:"):
			events.append(parse_processing_shell_event(line))
		elif line.begins_with("Ship:"):
			events.append(parse_ship_event(line))
		elif line.begins_with("Shell:"):
			events.append(parse_shell_event(line))
		elif line.begins_with("Armor:"):
			events.append(parse_armor_event(line))
		elif line.begins_with("Final Hit Result:"):
			events.append(parse_final_result_event(line))
	
	return events

# Parse ship position/rotation line
# Format: Ship: 1016 pos=(-3276.7, -1.7, 6211.8), rot=(-0.0, 4.1, 0.0), scene=res://ShipModels/Bismarck.tscn
static func parse_ship_event(line: String) -> ShellEvent:
	var data = {}
	
	# Extract ship name (everything between "Ship: " and " pos=")
	var name_start = line.find(" ") + 1
	var name_end = line.find(" pos=")
	data["name"] = line.substr(name_start, name_end - name_start).strip_edges()
	
	# Extract position
	var pos_start = line.find("pos=(") + 5
	var pos_end = line.find(")", pos_start)
	var pos_str = line.substr(pos_start, pos_end - pos_start)
	data["position"] = parse_vector3(pos_str)
	
	# Extract rotation (in degrees, need to convert to radians)
	var rot_start = line.find("rot=(") + 5
	var rot_end = line.find(")", rot_start)
	var rot_str = line.substr(rot_start, rot_end - rot_start)
	var rot_degrees = parse_vector3(rot_str)
	# Convert from degrees to radians for Godot
	data["rotation"] = Vector3(deg_to_rad(rot_degrees.x), deg_to_rad(rot_degrees.y), deg_to_rad(rot_degrees.z))
	
	# Extract scene path if present
	if line.find("scene=") != -1:
		var scene_start = line.find("scene=") + 6
		data["scene_path"] = line.substr(scene_start).strip_edges()
	
	return ShellEvent.new("Ship", data)

# Parse shell state line
# Format: Shell: speed=785.4 vel=(-340.8, -25.2, 707.2) m/s, fuze=-1.000 s, pos=(-3282.7, 3.0, 6096.0), pen: 708.5
static func parse_shell_event(line: String) -> ShellEvent:
	var data = {}
	
	# Extract speed
	var speed_start = line.find("speed=") + 6
	var speed_end = line.find(" ", speed_start)
	data["speed"] = float(line.substr(speed_start, speed_end - speed_start))
	
	# Extract velocity
	var vel_start = line.find("vel=(") + 5
	var vel_end = line.find(")", vel_start)
	var vel_str = line.substr(vel_start, vel_end - vel_start)
	data["velocity"] = parse_vector3(vel_str)
	
	# Extract fuze time
	var fuze_start = line.find("fuze=") + 5
	var fuze_end = line.find(" s", fuze_start)
	data["fuze"] = float(line.substr(fuze_start, fuze_end - fuze_start))
	
	# Extract position
	var pos_start = line.find("pos=(") + 5
	var pos_end = line.find(")", pos_start)
	var pos_str = line.substr(pos_start, pos_end - pos_start)
	data["position"] = parse_vector3(pos_str)
	
	# Extract penetration
	var pen_start = line.find("pen: ") + 5
	data["penetration"] = float(line.substr(pen_start))
	
	return ShellEvent.new("Shell", data)

# Parse armor hit line
# Format: Armor: OVERPEN, Hull with 32.0/49.1mm (angle 49.3°), normal: (1.0, -0.1, -0.3), ship: 1016
static func parse_armor_event(line: String) -> ShellEvent:
	var data = {}
	
	# Extract hit result (OVERPEN, RICOCHET, SHATTER, etc.)
	var result_start = line.find(" ") + 1
	var result_end = line.find(",", result_start)
	data["result"] = line.substr(result_start, result_end - result_start).strip_edges()
	
	# Extract armor part name
	var part_start = result_end + 2
	var part_end = line.find(" with ", part_start)
	data["part"] = line.substr(part_start, part_end - part_start).strip_edges()
	
	# Extract armor thickness
	var thickness_start = line.find(" with ") + 6
	var thickness_end = line.find("/", thickness_start)
	data["armor_thickness"] = float(line.substr(thickness_start, thickness_end - thickness_start))
	
	# Extract effective thickness
	var effective_start = thickness_end + 1
	var effective_end = line.find("mm", effective_start)
	data["effective_thickness"] = float(line.substr(effective_start, effective_end - effective_start))
	
	# Extract angle
	var angle_start = line.find("angle ") + 6
	var angle_end = line.find("°", angle_start)
	data["angle"] = float(line.substr(angle_start, angle_end - angle_start))
	
	# Extract normal vector
	var normal_start = line.find("normal: (") + 9
	var normal_end = line.find(")", normal_start)
	var normal_str = line.substr(normal_start, normal_end - normal_start)
	data["normal"] = parse_vector3(normal_str)
	
	# Extract ship ID
	var ship_start = line.find("ship: ") + 6
	var ship_end = line.find(",", ship_start)
	if ship_end == -1:
		ship_end = line.length()
	data["ship_id"] = int(line.substr(ship_start, ship_end - ship_start).strip_edges())
	
	# Extract is_citadel flag if present
	data["is_citadel"] = false
	if line.find("is_citadel:") != -1:
		var citadel_start = line.find("is_citadel: ") + 12
		var citadel_value = line.substr(citadel_start).strip_edges()
		data["is_citadel"] = citadel_value == "true" or citadel_value == "True"
	
	return ShellEvent.new("Armor", data)

# Parse "Processing Shell" line
# Format: Processing Shell: 380 AP
static func parse_processing_shell_event(line: String) -> ShellEvent:
	var data = {}
	
	# Extract shell info (everything after "Processing Shell: ")
	var info_start = line.find(": ") + 2
	data["shell_info"] = line.substr(info_start).strip_edges()
	
	return ShellEvent.new("Processing Shell", data)

# Parse "Final Hit Result" line
# Format: Final Hit Result: CITADEL
static func parse_final_result_event(line: String) -> ShellEvent:
	var data = {}
	
	# Extract result (everything after "Final Hit Result: ")
	var result_start = line.find(": ") + 2
	data["result"] = line.substr(result_start).strip_edges()
	
	return ShellEvent.new("Final Hit Result", data)

# Helper function to parse Vector3 from string "(x, y, z)"
static func parse_vector3(vec_str: String) -> Vector3:
	var parts = vec_str.split(",")
	return Vector3(
		float(parts[0].strip_edges()),
		float(parts[1].strip_edges()),
		float(parts[2].strip_edges())
	)
