extends Node

# Class for managing player-specific ship upgrades that persist between sessions
class_name PlayerUpgrades

const UPGRADES_DIR = "user://player_upgrades/"
const FILE_EXTENSION = ".json"

# Save upgrades for a specific player
static func save_player_upgrades(player_name: String, ship_path: String, upgrades: Dictionary) -> bool:
	# Create the directory if it doesn't exist
	if not DirAccess.dir_exists_absolute(UPGRADES_DIR):
		var dir = DirAccess.open("user://")
		if dir:
			dir.make_dir("player_upgrades")
		else:
			push_error("Failed to create player upgrades directory")
			return false
	
	# Create a data structure to save
	var data = {
		"player_name": player_name,
		"ship": ship_path,
		"upgrades": upgrades,
		"last_updated": Time.get_datetime_dict_from_system()
	}
	
	# Save to file
	var file = FileAccess.open(UPGRADES_DIR + player_name + FILE_EXTENSION, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
		print("Saved upgrades for player: ", player_name)
		return true
	else:
		push_error("Failed to save upgrades for player: " + player_name)
		return false

# Load upgrades for a specific player
static func load_player_upgrades(player_name: String) -> Dictionary:
	var file_path = UPGRADES_DIR + player_name + FILE_EXTENSION
	if not FileAccess.file_exists(file_path):
		print("No saved upgrades found for player: ", player_name)
		return {}
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open upgrades file for player: " + player_name)
		return {}
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	if parse_result != OK:
		push_error("Failed to parse upgrades file for player: " + player_name)
		return {}
	
	var data = json.get_data()
	print("Loaded upgrades for player: ", player_name)
	return data

# Apply saved upgrades to a ship
static func apply_upgrades_to_ship(ship: Ship, player_name: String, upgrade_manager: Node) -> void:
	var data = load_player_upgrades(player_name)
	if data.is_empty() or not data.has("upgrades"):
		print("No upgrades to apply for player: ", player_name)
		return
	
	var upgrades = data["upgrades"]
	print("Applying ", upgrades.size(), " upgrades to ship for player: ", player_name)
	
	# First, clear any existing upgrades
	for existing_upgrade in ship.upgrades.upgrades:
		if existing_upgrade:
			upgrade_manager.remove_upgrade_from_ship(ship, upgrade_manager.get_path_from_upgrade(existing_upgrade))
	
	# Apply each upgrade to the ship
	for slot_str in upgrades:
		var upgrade_path = upgrades[slot_str]
		if upgrade_path and not upgrade_path.is_empty():
			var success = upgrade_manager.apply_upgrade_to_ship(ship, upgrade_path)
			if success:
				print("Applied upgrade to ship: ", upgrade_path)
			else:
				push_error("Failed to apply upgrade: " + upgrade_path)
