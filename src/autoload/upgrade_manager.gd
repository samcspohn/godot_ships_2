extends Node

# UpgradeManager - Global singleton for managing ship upgrades
class_name _UpgradeManager

# Dictionary of available upgrades - path to loaded resource
var available_upgrades = {}

# Signal emitted when upgrades are loaded
signal upgrades_loaded

func _ready():
	# Scan for all available upgrades
	scan_upgrades()

# Scan the file system for upgrade scripts
func scan_upgrades():
	var upgrade_dir = "res://src/ship/Upgrades"
	var dir = DirAccess.open(upgrade_dir)
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			# Skip directories and non-script files
			if !dir.current_is_dir() and file_name.ends_with(".gd") and file_name != "upgrade.gd" and file_name != "upgrades.gd":
				var upgrade_path = upgrade_dir + "/" + file_name
				_load_upgrade(upgrade_path)
			
			file_name = dir.get_next()
		
		dir.list_dir_end()
		
	print("UpgradeManager: Loaded ", available_upgrades.size(), " upgrades")
	upgrades_loaded.emit()

# Load an individual upgrade from path
func _load_upgrade(path: String):
	var script = load(path)
	
	if script:
		var upgrade_instance = script.new()
		
		if upgrade_instance is Upgrade:
			# Set properties from script if they're not already set
			if upgrade_instance.name.is_empty():
				upgrade_instance.name = path.get_file().get_basename().capitalize()
				
			if upgrade_instance.description.is_empty():
				upgrade_instance.description = "An upgrade for your ship"
				
			# Add to available upgrades
			available_upgrades[path] = upgrade_instance
			print("UpgradeManager: Loaded upgrade ", upgrade_instance.name, " from ", path)
		else:
			push_error("UpgradeManager: File is not an Upgrade: ", path)

# Get upgrade instance by path
func get_upgrade(path: String) -> Upgrade:
	if available_upgrades.has(path):
		return available_upgrades[path]
	return null

# Apply an upgrade to a ship
func apply_upgrade_to_ship(ship: Ship, slot_index: int, upgrade_path: String):
	var upgrade = get_upgrade(upgrade_path)
	if upgrade:
		if ship.upgrades.upgrades[slot_index] != null:
			remove_upgrade_from_ship(ship, slot_index)
		ship.upgrades.add_upgrade(slot_index, upgrade)
		upgrade.apply(ship)
		return true
	return false

# Remove an upgrade from a ship
func remove_upgrade_from_ship(ship: Ship, slot_index: int):
	var upgrade = ship.upgrades.get_upgrade(slot_index)
	if upgrade:
		upgrade.remove(ship)
		ship.upgrades.remove_upgrade(slot_index)
		return true
	return false

# Get all upgrades as array
func get_all_upgrades() -> Array:
	return available_upgrades.values()

# Get all upgrade paths
func get_all_upgrade_paths() -> Array:
	return available_upgrades.keys()

# Get the path for an upgrade instance
func get_path_from_upgrade(upgrade: Upgrade) -> String:
	for path in available_upgrades.keys():
		if available_upgrades[path] == upgrade:
			return path
	return ""

# Get upgrade metadata
func get_upgrade_metadata() -> Array:
	var metadata = []
	
	for path in available_upgrades.keys():
		var upgrade = available_upgrades[path]
		metadata.append({
			"path": path,
			"name": upgrade.name,
			"description": upgrade.description,
			"icon": upgrade.icon
		})
		
	return metadata
