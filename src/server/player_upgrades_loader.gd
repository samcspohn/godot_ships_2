## Function to load and apply player upgrades
#func _load_and_apply_player_upgrades(ship: Ship, player_name: String) -> void:
	## Skip for bots or empty player names
	#if player_name.is_empty() or not ship:
		#return
		#
	#print("Loading upgrades for player: ", player_name)
	#
	## Check if this player has the same name as in GameSettings
	#if player_name != GameSettings.player_name:
		#print("Player name mismatch. Cannot load upgrades for player: ", player_name)
		#return
		#
	## Get the ship path
	#var ship_path = ship.get_path()
	#if ship_path.is_empty():
		#print("No ship path found for player: ", player_name)
		#return
		#
	## Check if we have upgrades for this ship
	#if not GameSettings.ship_config.has(ship_path):
		#print("No saved upgrades found for ship: ", ship_path)
		#return
	#
	## Ensure we have the UpgradeManager
	#if not UpgradeManager:
		#push_error("UpgradeManager not found, cannot apply upgrades")
		#return
	#
	## Apply each upgrade to the ship
	#var upgrades = GameSettings.ship_config[ship_path]
	#print("Applying ", upgrades.size(), " upgrades to ship for player: ", player_name)
	#
	#for slot_str in upgrades:
		#var upgrade_path = upgrades[slot_str]
		#if upgrade_path and not upgrade_path.is_empty():
			#var success = UpgradeManager.apply_upgrade_to_ship(ship, upgrade_path)
			#if success:
				#print("Applied upgrade to ship: ", upgrade_path)
			#else:
				#push_error("Failed to apply upgrade: " + upgrade_path)
