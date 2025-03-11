# src/autoload/game_settings.gd
extends Node

const DEFAULT_PORT = 28960
const DEFAULT_SERVER_PORT = 28970
const MAX_PLAYERS = 16

var player_name = "Player"
var server_ip = "127.0.0.1"
var matchmaker_ip = "127.0.0.1"

func save_settings():
	var config = ConfigFile.new()
	config.set_value("network", "player_name", player_name)
	config.set_value("network", "server_ip", server_ip)
	config.set_value("network", "matchmaker_ip", matchmaker_ip)
	config.save("user://game_settings.cfg")

func load_settings():
	var config = ConfigFile.new()
	var err = config.load("user://game_settings.cfg")
	
	if err == OK:
		player_name = config.get_value("network", "player_name", "Player")
		server_ip = config.get_value("network", "server_ip", "127.0.0.1")
		matchmaker_ip = config.get_value("network", "matchmaker_ip", "127.0.0.1")
