# src/server/game_server.gd
extends Node

class_name GameServer
var players = {}
var player_info = {}
var game_world = null
var spawn_point = null

func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	# Create the game world as a separate entity
	game_world = preload("res://scenes/game_world.tscn").instantiate()
	add_child(game_world)
	spawn_point = game_world.get_child(1)
	print("Game server started and world loaded")

func _on_peer_connected(id):
	print("Peer connected: ", id)
	
	#join_game.rpc_id(id)
	#spawn_player(id, str(id))
	# Wait for them to register before spawning

func _on_peer_disconnected(id):
	print("Peer disconnected: ", id)
	# Remove player
	if players.has(id):
		players[id].queue_free()
		players.erase(id)
		player_info.erase(id)

@rpc("any_peer")
func register_player(player_name):
	var id = multiplayer.get_remote_sender_id()
	player_info[id] = {
		"name": player_name
	}
	
	# Tell other clients about this player
	for peer_id in player_info:
		if peer_id != id:
			# Tell new player about existing player
			register_player.rpc_id(id, player_info[peer_id].name)
			# Tell existing player about new player
			register_player.rpc_id(peer_id, player_name)
	
	# Tell client to start game
	join_game.rpc_id(id)
	
	# Spawn player for all clients including the newly registered one
	spawn_player.rpc(id, player_name)

#@rpc("authority", "call_local")
func spawn_player(id, player_name):
	
	#join_game.rpc_id(id)
	
	if players.has(id):
		return
		
	var player = preload("res://scenes/player.tscn").instantiate()
	#print(player_name)
	player.name = str(id)

	# Set player name
	if player.has_node("NameLabel"):
		player.get_node("NameLabel").text = player_name
	
	# Add to world - note game_world is a child of this node
	players[id] = player
	spawn_point.add_child(player)
	
	# Randomize spawn position
	var spawn_pos = Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
	player.position = spawn_pos
	spawn_pos = player.global_position
	
	#join_game.rpc_id(id)
	for pid in players:
		var p = players[pid]
		# notify new client of current players
		spawn_players_client.rpc_id(id, pid,p.name, p.global_position)
		#notify current players of new player
		spawn_players_client.rpc_id(pid, id, player.name, spawn_pos)
	
	#spawn_players_client.rpc_id(id, id,player_name,spawn_pos)

@rpc("authority", "call_remote", "reliable")
func spawn_players_client(id, player_name, pos):
	if players.has(id):
		return
		
	var player = preload("res://scenes/player.tscn").instantiate()
	#print(player_name)
	player.name = str(id)
	#if auth:
		#player.set_multiplayer_authority(id)
	
	# Set player name
	if player.has_node("NameLabel"):
		player.get_node("NameLabel").text = player_name
	
	# Add to world - note game_world is a child of this node
	spawn_point.add_child(player)
	players[id] = player
	
	#player.global_position = pos
	

@rpc("any_peer", "call_remote")
func join_game():
	# Called on client to switch to game world
	get_tree().change_scene_to_file("res://scenes/server.tscn")
