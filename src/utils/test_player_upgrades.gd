# Test script showing how to use the PlayerUpgrades system
extends Node

# Import the PlayerUpgrades utility class
const PlayerUpgrades = preload("res://src/utils/player_upgrades.gd")

func _ready():
	print("Running PlayerUpgrades test")
	
	# Example upgrade data
	var player_name = "TestPlayer"
	var ship_path = "res://ShipModels/Bismarck2.tscn"
	var upgrades = {
		"0": "res://src/ship/Upgrades/main_reload.gd",
		"1": "res://src/ship/Upgrades/secondary_upgrade.gd",
		"2": "res://src/ship/Upgrades/torpedo_upgrade.gd"
	}
	
	# Save the upgrade data
	var success = PlayerUpgrades.save_player_upgrades(player_name, ship_path, upgrades)
	print("Save upgrades result: ", success)
	
	# Load the upgrade data
	var data = PlayerUpgrades.load_player_upgrades(player_name)
	print("Loaded upgrade data: ", data)
	
	# This shows how the server would apply upgrades to a ship
	# (Note: In actual use, this would be called from the server's spawn_player function)
	# var upgrade_manager = get_node("/root/UpgradeManager")
	# var ship = load(ship_path).instantiate()
	# PlayerUpgrades.apply_upgrades_to_ship(ship, player_name, upgrade_manager)
