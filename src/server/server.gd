# src/server/game_server.gd
extends Node

class_name GameServer
var players: Dictionary[int,Ship] = {}
var player_info = {}
var game_world = null
var spawn_point = null
var team_info = null
var team_file_path = ""
var team = {}

func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	# Create the game world as a separate entity
	game_world = preload("res://scenes/Maps/game_world.tscn").instantiate()
	add_child(game_world)
	spawn_point = game_world.get_child(1)
	var map = load("res://scenes/Maps/map2.tscn").instantiate()
	game_world.get_node("Env").add_child(map)
	
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

func spawn_player(id, player_name):

	# Check for team file argument
	if team_info == null:
		var team_file_path = "user://team_info.json"
		if FileAccess.file_exists(team_file_path):
			var file = FileAccess.open(team_file_path, FileAccess.READ)
			var content = file.get_as_text()
			var json = JSON.new()
			var err = json.parse(content)
			if err != OK:
				push_error("Failed to parse team info file")
				return
			# Load team info from file
			team_info = json.get_data()
			file.close()
			print("Loaded team info: ", team_info)

	# team_info = {
	# 	"team": {
	# 		"1": {
	# 			"team": 1,
	#			"player_id": 0, // player_name
	# 			"ship": "res://scenes/ship.tscn"
	# 		},
	# 		"2": {
	# 			"team": 2,
	#			"player_id": 1, // player_nma
	# 			"ship": "res://scenes/ship.tscn"
	# 		}
	# 	}
	# }
	
	#join_game.rpc_id(id)
	
	if players.has(id):
		return
		
	var player = preload("res://scenes/ship.tscn").instantiate()
	#print(player_name)
	player.name = str(id)
	player._enable_guns()

	var team_data = team_info["team"][player_name]

	if !team.has(team_data["team"]):
		team[team_data["team"]] = {}
	team[team_data["team"]][id] = player
	var team_id = int(team_data["team"])
	var team_: TeamEntity = preload("res://src/teams/TeamEntity.tscn").instantiate()
	team_.team_id = team_id
	team_.is_bot = false
	player.add_child(team_)
		
	var controller = preload("res://scenes/player_control.tscn").instantiate()
	# controller.name = str(id)
	player.add_child(controller)

	# player.get_node("PlayerController").setName(str(id))

	# Set player name
	if player.has_node("NameLabel"):
		player.get_node("NameLabel").text = player_name
	
	# Add to world - note game_world is a child of this node
	players[id] = player
	
	# Randomize spawn position
	var spawn_pos = Vector3(randf_range(-1000, 1000), 0, randf_range(-1000, 1000))
	spawn_point.add_child(player)
	player.position = spawn_pos
	spawn_pos = player.global_position
	
	#join_game.rpc_id(id)
	for pid in players:
		var p: Ship = players[pid]
		# notify new client of current players
		spawn_players_client.rpc_id(id, pid,p.name, p.global_position, (p.get_node("TeamEntity") as TeamEntity).team_id)
		#notify current players of new player
		spawn_players_client.rpc_id(pid, id, player.name, spawn_pos, team_id)
	
	#spawn_players_client.rpc_id(id, id,player_name,spawn_pos)

@rpc("call_remote", "reliable")
func spawn_players_client(id, player_name, pos, team_id):
	if players.has(id):
		return

	var player = preload("res://scenes/ship.tscn").instantiate()
	player.name = str(id)
	player._enable_guns()
	
	if id == multiplayer.get_unique_id():
		var controller = preload("res://scenes/player_control.tscn").instantiate()
		player.add_child(controller)
	
	var team_: TeamEntity = preload("res://src/teams/TeamEntity.tscn").instantiate()
	team_.team_id = int(team_id)
	team_.is_bot = false
	player.add_child(team_)
	
	# Set player name
	if player.has_node("NameLabel"):
		player.get_node("NameLabel").text = player_name
	
	# Add to world - note game_world is a child of this node
	players[id] = player
	spawn_point.add_child(player)
	
	#player.global_position = pos
	

@rpc("any_peer", "call_remote")
func join_game():
	# Called on client to switch to game world
	get_tree().change_scene_to_file("res://scenes/server.tscn")
	
func _physics_process(delta: float) -> void:
	if !multiplayer.is_server():
		return
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	for p_id in players:
		var p: Ship = players[p_id]
		ray_query.from = p.global_position
		var d = p.sync_ship_data()
		for p_id2 in players:
			var p2: Ship  = players[p_id2]
			ray_query.to = p2.global_position
			var collision: Dictionary = space_state.intersect_ray(ray_query)
			if p_id == p_id2 or !collision.is_empty() and collision.collider is Ship:
				p.sync.rpc_id(p_id2, d)
			else:
				p._hide.rpc_id(p_id2)
