# src/server/game_server.gd
extends Node

class_name GameServer
var players = {}
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
	
	# # Wait a frame for the world to fully initialize
	# await get_tree().process_frame
	
	# # Take the map snapshot only on the server
	# if multiplayer.is_server():
	# 	await Minimap.server_take_map_snapshot(get_viewport())

func _on_peer_connected(id):
	print("Peer connected: ", id)
	
	#join_game.rpc_id(id)
	#spawn_player(id, str(id))
	# Wait for them to register before spawning

func _on_peer_disconnected(id):
	print("Peer disconnected: ", id)
	# Remove player
	if players.has(id):
		players[id][0].queue_free()
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
	if players.has(id):
		return
	
	#join_game.rpc_id(id)
	var team_data = team_info["team"][player_name]

	var ship = team_data["ship"]
	var player: Ship = load(ship).instantiate()
	#print(player_name)
	player.name = str(id)
	player._enable_guns()
	
	if !team.has(team_data["team"]):
		team[team_data["team"]] = {}
	team[team_data["team"]][id] = player
	
	
	var team_id = int(team_data["team"])
	var team_: TeamEntity = preload("res://src/teams/TeamEntity.tscn").instantiate()
	team_.team_id = team_id
	team_.is_bot = false
	player.get_node("Modules").add_child(team_)
	player.team = team_
	
	
		
	var controller = preload("res://scenes/player_control.tscn").instantiate()
	# controller.name = str(id)
	player.get_node("Modules").add_child(controller)
	player.control = controller
	controller.ship = player
	
	# Add to world - note game_world is a child of this node
	players[id] = [player, ship]
	
	# Randomize spawn position
	var spawn_pos = Vector3(randf_range(-1000, 1000), 0, randf_range(-1000, 1000))
	spawn_point.add_child(player)
	player.position = spawn_pos
	spawn_pos = player.global_position
	
	#join_game.rpc_id(id)
	for pid in players:
		var p: Ship = players[pid][0]
		var p_ship = players[pid][1]
		# notify new client of current players
		spawn_players_client.rpc_id(id, pid,p.name, p.global_position, p.team.team_id, p_ship)
		#notify current players of new player
		spawn_players_client.rpc_id(pid, id, player.name, spawn_pos, team_id, ship)
	
	#spawn_players_client.rpc_id(id, id,player_name,spawn_pos)

@rpc("call_remote", "reliable")
func spawn_players_client(id, player_name, pos, team_id, ship):

	if !Minimap.is_initialized:
		Minimap.server_take_map_snapshot(get_viewport())
	if players.has(id):
		return

	var player: Ship = load(ship).instantiate()
	player.name = str(id)
	player._enable_guns()
	
	if id == multiplayer.get_unique_id():
		var controller = preload("res://scenes/player_control.tscn").instantiate()
		player.get_node("Modules").add_child(controller)
		player.control = controller
		controller.ship = player
		
	
	var team_: TeamEntity = preload("res://src/teams/TeamEntity.tscn").instantiate()
	team_.team_id = int(team_id)
	team_.is_bot = false
	player.get_node("Modules").add_child(team_)
	player.team = team_
	
	# Add to world - note game_world is a child of this node
	players[id] = [player, ship]
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
	ray_query.hit_from_inside = false
	
	for p in players.values():
		(p[0] as Ship).visible_to_enemy = false
	
	for p_id in players.size() - 1:
		var p: Ship = players[players.keys()[p_id]][0]
		ray_query.from = p.global_position
		var d = p.sync_ship_data()
		for p_id2 in range(p_id + 1,players.size()):
			var p2: Ship = players[players.keys()[p_id2]][0]
			if p.team.team_id != p2.team.team_id: # other team
				ray_query.to = p2.global_position
				var collision: Dictionary = space_state.intersect_ray(ray_query)
				if !collision.is_empty() and collision.collider is Ship: # can see each other (add concealment)
					p.visible_to_enemy = true
					p2.visible_to_enemy = true
		
	for pid in players: # for every player, synchronize self with others
		var p: Ship = players[pid][0]
		var d = p.sync_ship_data()
		for pid2 in players: # every other player
			var p2: Ship = players[pid2][0]
			if p.team.team_id == p2.team.team_id or p.visible_to_enemy:
				p.sync.rpc_id(pid2, d) # sync self to other player
			else:
				p._hide.rpc_id(pid2) # hide from other player
				
		
			#if p_id == p_id2:
				#p.sync.rpc_id(p_id2, d)
				#continue
			#var p2: Ship = players[p_id2][0]
			#ray_query.to = p2.global_position
			#var collision: Dictionary = space_state.intersect_ray(ray_query)
			#if !collision.is_empty() and collision.collider is Ship && collision.collider != p:
				#p.sync.rpc_id(p_id2, d)
			#else:
				#p._hide.rpc_id(p_id2)
