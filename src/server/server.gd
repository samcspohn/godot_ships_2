# src/server/game_server.gd
extends Node

class_name GameServer

# Use GameSettings for player ship configs
var players = {}
var player_info = {}
var game_world = null
var spawn_point = null
var team_info = null
var team_file_path = ""
var team = {}
var players_spawned_bots = false  # Track if bots have been spawned for single player
var team_0_valid_targets = []
var team_1_valid_targets = []


func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	# Create the game world as a separate entity
	game_world = preload("res://src/Maps/game_world.tscn").instantiate()
	add_child(game_world)
	spawn_point = game_world.get_child(1)
	var map = load("res://src/Maps/map2.tscn").instantiate()
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
		pass
		# players[id][0].queue_free()
		# players.erase(id)
		# player_info.erase(id)

@rpc("any_peer", "call_remote", "reliable")
func reconnect(id, player_name):
	# Handle player reconnection
	if players.has(player_name):
		var player_data = players[player_name]
		var player: Ship = player_data[0]
		player.peer_id = id
		players[player_name][2] = id  # Update stored peer ID
		# Notify other players of the reconnection if needed
		print("Player ", player_name, " reconnected with ID ", id)
		validate_connection.rpc_id(id)
	else:
		print("No existing player data for ", player_name)
		# spawn_player(id, player_name)

@rpc("authority", "call_remote", "reliable")
func validate_connection():
	# Implement validation logic if needed
	NetworkManager.player_controller_connected = true

func spawn_player(id, player_name):
	print("spawn_player called with ID: ", id, ", player_name: ", player_name)

	# Check for team file argument
	if team_info == null:
		team_file_path = "user://team_info.json"
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
			print("Team info keys: ", team_info["team"].keys() if team_info.has("team") else "No team key")

	# team_info = {
	# 	"team": {
	# 		"1": {
	# 			"team": 1,
	#			"player_id": 0, // player_name
	# 			"ship": "res://scenes/ship.tscn"
	# 		},
	# 		"2": {
	# 			"team": 2,
	#			"player_id": 1, // player_name
	# 			"ship": "res://scenes/ship.tscn"
	# 		}
	# 	}
	# }
	if players.has(player_name):
		return
	
	#join_game.rpc_id(id)
	
	if not team_info or not team_info.has("team"):
		push_error("No team info available for player: " + str(player_name))
		return
		
	if not team_info["team"].has(player_name):
		push_error("Player " + str(player_name) + " not found in team info. Available keys: " + str(team_info["team"].keys()))
		return
		
	var team_data = team_info["team"][player_name]

	var ship = team_data["ship"]
	var is_bot = team_data.get("is_bot", false)
	var player: Ship = load(ship).instantiate()
	player.peer_id = id
	#print(player_name)
	player.name = player_name
	player._enable_guns()
	var tl = player.get_node_or_null("TorpedoLauncher")
	if tl:
		(tl as TorpedoLauncher).disabled = false
		
	# Load and apply player upgrades (skip for bots)
	if not is_bot:
		call_deferred("_load_and_apply_player_config", player, player_name)
	
	
	if !team.has(team_data["team"]):
		team[team_data["team"]] = {}
	team[team_data["team"]][id] = player
	
	
	var team_id = int(team_data["team"])
	var team_: TeamEntity = preload("res://src/teams/TeamEntity.tscn").instantiate()
	team_.team_id = team_id
	team_.is_bot = is_bot
	print("server: Assigning team ID ", team_id, " team.team_id ", team_.team_id, " to player ID ", id, " (is_bot=", is_bot, ")")
	player.get_node("Modules").add_child(team_)
	player.team = team_
	
	
	# If it's a bot, add bot AI controller instead of player controller
	if is_bot:
		var bot_controller = preload("res://src/ship/bot_controller.tscn").instantiate()
		player.get_node("Modules").add_child(bot_controller)
		bot_controller.ship = player
	else:
		# Only add player control for human players
		var controller = preload("res://scenes/player_control.tscn").instantiate()
		# controller.name = str(id)
		player.get_node("Modules").add_child(controller)
		player.control = controller
		controller.ship = player
	
	# Add to world - note game_world is a child of this node
	players[player_name] = [player, ship, id]

	var map = get_node("GameWorld/Env").get_child(0)
	var team_spawn_point: Vector3 = (map.get_node("Spawn").get_child(team_id) as Node3D).global_position

	var right_of_spawn = Vector3.UP.cross(team_spawn_point).normalized()

	# Randomize spawn position
	var spawn_pos = right_of_spawn * randf_range(-6000, 6000) + team_spawn_point
	spawn_point.add_child(player)
	player.position = spawn_pos
	spawn_pos = player.global_position
	player.rotate(Vector3.UP,spawn_pos.angle_to(player.global_transform.basis.z))

	#join_game.rpc_id(id)
	for p_name in players:
		var p: Ship = players[p_name][0]
		var p_ship = players[p_name][1]
		var pid = players[p_name][2]
		# notify new client of current players
		if not is_bot:
			spawn_players_client.rpc_id(id, pid,p.name, p.global_position, p.team.team_id, p_ship)
		#notify current players of new player
		if not p.team.is_bot:
			spawn_players_client.rpc_id(pid, id, player.name, spawn_pos, team_id, ship)

	#spawn_players_client.rpc_id(id, id,player_name,spawn_pos)
	
	# Check if this is single player and spawn bots (only for human players, not bots)
	if team_info and team_info.has("team") and not is_bot:
		var is_single_player = false
		var bot_count = 0
		
		# Check if any team member is a bot to determine if this is single player
		for team_player_id in team_info["team"]:
			var player_data = team_info["team"][team_player_id]
			if player_data.get("is_bot", false):
				is_single_player = true
				bot_count += 1
		
		# If this is single player mode and this is the human player, spawn all bots
		if is_single_player and not players_spawned_bots:
			print("Spawning ", bot_count, " bots for single player mode")
			for team_player_id in team_info["team"]:
				var player_data = team_info["team"][team_player_id]
				if player_data.get("is_bot", false):
					# Spawn bot with unique ID
					var bot_id = team_player_id
					print("Spawning bot: ID=", bot_id, ", player_name=", team_player_id, ", ship=", player_data["ship"])
					spawn_player(bot_id, team_player_id)
			players_spawned_bots = true

@rpc("call_remote", "reliable")
func spawn_players_client(id, _player_name, _pos, team_id, ship):

	if !Minimap.is_initialized:
		Minimap.server_take_map_snapshot(get_viewport())
	if players.has(_player_name):
		return

	var player: Ship = load(ship).instantiate()
	player.name = _player_name
	
	player._enable_guns()
	
	# Check if this is the local player or a bot by checking team info
	var is_local_player = (int(id) == multiplayer.get_unique_id())
	var is_bot = false
	
	# Check team info for bot status
	if team_info and team_info.has("team"):
		for team_player_id in team_info["team"]:
			if str(id) == str(int(team_player_id) + 1000) or team_player_id == str(id):  # Check both bot ID mapping and regular ID
				var player_data = team_info["team"][team_player_id]
				is_bot = player_data.get("is_bot", false)
				break
	
	# Only add player control for local human player
	if is_local_player and not is_bot:
		NetworkManager.player_controller_connected = true

		var controller = preload("res://scenes/player_control.tscn").instantiate()
		player.get_node("Modules").add_child(controller)
		player.control = controller
		controller.ship = player
		
		# # Apply any saved upgrades to the local player's ship
		# # This ensures the client-side ship has the same upgrades as configured in the menu
		# if GameSettings.player_name == _player_name and not GameSettings.ship_config.is_empty():
		# 	# Use the UpgradeManager to apply upgrades from GameSettings
		# 	var upgrade_manager = get_node_or_null("/root/UpgradeManager")
		# 	if upgrade_manager:
		# 		print("Applying client-side upgrades for player: ", _player_name)
		# 		for slot_str in GameSettings.ship_config:
		# 			var upgrade_path = GameSettings.ship_config[slot_str]
		# 			if not upgrade_path.is_empty():
		# 				var success = upgrade_manager.apply_upgrade_to_ship(player, upgrade_path)
		# 				if success:
		# 					print("Applied client-side upgrade: ", upgrade_path)
		# 				else:
		# 					push_error("Failed to apply client-side upgrade: " + upgrade_path)
	
	var team_: TeamEntity = preload("res://src/teams/TeamEntity.tscn").instantiate()
	team_.team_id = int(team_id)
	print("Assigning team ID ", team_id, " team.team_id ", team_.team_id, " to player ID ", id, " (is_bot=", is_bot, ")")
	team_.is_bot = is_bot
	player.get_node("Modules").add_child(team_)
	player.team = team_
	
	# Add to world - note game_world is a child of this node
	players[_player_name] = [player, ship, id]
	spawn_point.add_child(player)
	
	#player.global_position = pos


# Function to load and apply player config
func _load_and_apply_player_config(ship: Ship, player_name: String) -> void:
	# Skip for bots or empty player names
	if player_name.is_empty() or not ship:
		return

	print("Loading config for player: ", player_name)
	
	var player_settings = _GameSettings.new()
	player_settings.player_name = player_name
	player_settings.load_settings()
	# Get the ship path
	var ship_path = player_settings.selected_ship
	
	# Apply each upgrade to the ship
	var upgrades = player_settings.ship_config[ship_path]
	print("Applying ", upgrades.size(), " upgrades to ship for player: ", player_name)
	
	for slot_str in upgrades:
		if slot_str == "skills":  # Skip skills section
			continue
		var upgrade_path = upgrades[slot_str]
		if upgrade_path and not upgrade_path.is_empty():
			var success = UpgradeManager.apply_upgrade_to_ship(ship, int(slot_str), upgrade_path)
			if success:
				print("Applied upgrade to ship: ", upgrade_path)
			else:
				push_error("Failed to apply upgrade: " + upgrade_path)

	# Apply each skill to the ship
	if not player_settings.ship_config[ship_path].has("skills"):
		return
	var skills = player_settings.ship_config[ship_path]["skills"]
	print("Applying ", skills.size(), " skills to ship for player: ", player_name)

	for skill_path in skills:
		if skill_path and not skill_path.is_empty():
			var skill = load(skill_path)
			if skill == null:
				push_error("Failed to load skill resource: " + skill_path)
				continue
			var skill_instance = skill.new()
			if not skill_instance is Skill:
				push_error("Loaded resource is not a Skill: " + skill_path)
				continue
			ship.skills.add_skill(skill_instance)

@rpc("any_peer", "call_remote")
func join_game():
	# Called on client to switch to game world
	get_tree().change_scene_to_file("res://src/server/server.tscn")


func _get_enemy_ships(team_id: int) -> Array:
	var enemies: Array = []
	for p_name in players:
		# print("Checking player ID: ", p, (players[p][0] as Ship).health_controller.current_hp)
		var ship: Ship = players[p_name][0]
		if is_instance_valid(ship) and ship.team.team_id != team_id:
			enemies.append(ship)
	return enemies

func get_team_ships(team_id: int) -> Array:
	var team_ships: Array = []
	for p_name in players:
		# print("Checking player ID: ", p, " current HP: ", (players[p][0] as Ship).health_controller.current_hp)
		var ship: Ship = players[p_name][0]
		if is_instance_valid(ship) and ship.team.team_id == team_id:
			team_ships.append(ship)
	return team_ships

func _get_valid_targets(team_id: int) -> Array[Ship]:
	var targets: Array[Ship] = []
	for p in players.values():
		var ship: Ship = p[0]
		if ship.team.team_id != team_id and ship.health_controller.is_alive() and ship.visible_to_enemy:
			targets.append(ship)
	return targets

func get_valid_targets(team_id: int) -> Array[Ship]:
	if team_id == 0:
		return team_0_valid_targets
	else:
		return team_1_valid_targets

func get_all_ships() -> Array:
	var all_ships: Array = []
	for p in players.values():
		var ship: Ship = p[0]
		if is_instance_valid(ship):
			all_ships.append(ship)
	return all_ships

# func sync_players(player_data: Array[Dictionary]) -> void:
# 	for data in player_data:
# 		var id = data.get("id", -1)
# 		if id == -1 or not players.has(id):
# 			continue
# 		var ship: Ship = players[id][0]
# 		if not is_instance_valid(ship):
# 			continue
# 		# ship.set_input(data.get("input", [0,0]), data.get("aim_point", Vector3.ZERO))

func _physics_process(_delta: float) -> void:
	if !multiplayer.is_server():
		return
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 # only terrain

	
	for p in players.values():
		var ship: Ship = p[0]			
		if ship.health_controller.is_dead():
			ship.visible_to_enemy = true
		else:
			ship.visible_to_enemy = false
	for p_idx in players.size() - 1:
		var p_name = players.keys()[p_idx]
		var p: Ship = players[p_name][0]
		ray_query.from = p.global_position
		ray_query.from.y = 1.0
		# var d = p.sync_ship_data() 
		for p2_idx in range(p_idx + 1,players.size()):
			var p2_name = players.keys()[p2_idx]
			var p2: Ship = players[p2_name][0]
			if p.team.team_id != p2.team.team_id and p.health_controller.is_alive() and p2.health_controller.is_alive(): # other team
				ray_query.to = p2.global_position
				ray_query.to.y = 1.0
				var collision: Dictionary = space_state.intersect_ray(ray_query)
				if collision.is_empty(): # can see each other no obstacles (add concealment)
					p.visible_to_enemy = true
					p2.visible_to_enemy = true
		
	for p_name in players: # for every player, synchronize self with others
		var p: Ship = players[p_name][0]
		var _p_id = players[p_name][2]
		var d = p.sync_ship_data()
		d['vs'] = p.visible_to_enemy
		for p_name2 in players: # every other player
			var p2: Ship = players[p_name2][0]
			var pid2 = players[p_name2][2]
			if not p2.team.is_bot: # player to sync with is not bot
				if p.team.team_id == p2.team.team_id or p.visible_to_enemy:
					p.sync.rpc_id(pid2, d) # sync self to other player
				else:
					p._hide.rpc_id(pid2) # hide from other player
				
	team_0_valid_targets = _get_valid_targets(0)
	team_1_valid_targets = _get_valid_targets(1)
			#if p_id == p_id2:
				#p.sync.rpc_id(p_id2, d)
				#continue
			#var p2: Ship = players[p_id2][0]
			#ray_query.to = p2.global_position
			#var collision: Dictionary = space_state.intersect_ray(ray_query)
			#if !collision.is_empty() and collision.collider is Ship && collision.collider != p:
	
