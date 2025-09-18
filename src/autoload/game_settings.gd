# src/autoload/game_settings.gd
extends Node
class_name _GameSettings

const DEFAULT_PORT = 28960
const DEFAULT_SERVER_PORT = 28970
const MAX_PLAYERS = 16

var player_name = "Player"
var server_ip = "127.0.0.1"
var matchmaker_ip = "127.0.0.1"
var selected_ship = ""
var is_single_player = false
# Dictionary of ship path -> upgrades (each upgrades entry is slot_index -> upgrade_path)
var ship_config = {}

func save_settings():
	var config = ConfigFile.new()
	config.set_value("network", "player_name", player_name)
	config.set_value("network", "server_ip", server_ip)
	config.set_value("network", "matchmaker_ip", matchmaker_ip)
	config.set_value("game", "is_single_player", is_single_player)
	config.set_value("game", "selected_ship", selected_ship)
	
	# Save each ship's upgrades individually
	for ship_path in ship_config:
		var ship_key = ship_path
		config.set_value("ships", ship_key, ship_config[ship_path])
		
	var dir = OS.get_data_dir()
	print("user dir: %s" % dir)
	config.save("user://%s.cfg" % player_name)

func load_settings():
	var config = ConfigFile.new()
	var dir = OS.get_data_dir()

	print("user dir: %s" % dir)

	var err = config.load("user://%s.cfg" % player_name)
	
	if err == OK:
		player_name = config.get_value("network", "player_name", "Player")
		server_ip = config.get_value("network", "server_ip", "127.0.0.1")
		matchmaker_ip = config.get_value("network", "matchmaker_ip", "127.0.0.1")
		is_single_player = config.get_value("game", "is_single_player", false)
		selected_ship = config.get_value("game", "selected_ship", "")
		
		# Load ship configs
		ship_config = {}
		if config.has_section("ships"):
			for ship_key in config.get_section_keys("ships"):
				# Convert key back to path
				var ship_path = ship_key
				
				ship_config[ship_path] = config.get_value("ships", ship_key, {})
