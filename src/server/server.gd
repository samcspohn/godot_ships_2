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
var players_size = 0

var gun_updated = false

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
	player._enable_weapons()
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
		bot_controller.name = "BotController"
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
	var spawn_pos = right_of_spawn * randf_range(-10000, 10000) + team_spawn_point
	spawn_pos.y = 0
	spawn_point.add_child(player)
	player.position = spawn_pos
	spawn_pos = player.global_position
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var rot_y = (-spawn_pos).angle_to(-player.global_transform.basis.z)
	player.rotate(Vector3.UP,rot_y)

	#join_game.rpc_id(id)
	for p_name in players:
		var p: Ship = players[p_name][0]
		var p_ship = players[p_name][1]
		var pid = players[p_name][2]
		# notify new client of current players
		if not is_bot:
			spawn_players_client.rpc_id(id, pid,p.name, p.global_position, p.global_rotation.y, p.team.team_id, p_ship)
		#notify current players of new player
		if not p.team.is_bot:
			spawn_players_client.rpc_id(pid, id, player.name, spawn_pos, rot_y, team_id, ship)

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
func spawn_players_client(id, _player_name, _pos, rot_y, team_id, ship):

	if !Minimap.is_initialized:
		Minimap.server_take_map_snapshot(get_viewport())
	if players.has(_player_name):
		return

	var player: Ship = load(ship).instantiate()
	player.name = _player_name

	player._enable_weapons()

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
	player.rotation.y = rot_y
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

	if not player_settings.ship_config.has(ship_path):
		print("No upgrades configured for ship: ", ship_path, " for player: ", player_name)
		return
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

func find_all_guns(node: Node) -> Array:
	var guns: Array = []
	if node is Gun:
		guns.append(node)
	for child in node.get_children():
		guns += find_all_guns(child)
	return guns

@rpc("authority", "reliable", "call_remote")
func init_guns(gun_paths):
	TcpThreadPool.initialize_guns(gun_paths)

func defer_sync_ship(friendly: int, player_name: String, ship_data: Variant):
	if not players.has(player_name):
		return
	var ship: Ship = players[player_name][0]
	if not is_instance_valid(ship):
		return
	if ship_data == null:
		ship._hide()
		return
	elif friendly == 2:
		# partial update
		var transform_data = ship_data
		ship.parse_ship_transform(transform_data)
	else:
		ship.sync2(ship_data, friendly == 1)

@rpc("any_peer", "unreliable_ordered", "call_remote", 1)
func sync_game_state(bytes: PackedByteArray):
	var reader = StreamPeerBuffer.new()
	reader.data_array = bytes
	var frame_time = 1.0 / Engine.get_frames_per_second()
	var phys_time = get_physics_process_delta_time()
	var num_steps = phys_time / frame_time
	var defer_time_step = frame_time / max(num_steps, 1)
	var i := 0.0
	while reader.get_available_bytes() > 0:
		var friendly = reader.get_u8()
		var player_name = reader.get_var()
		var ship_data = reader.get_var()
		get_tree().create_timer(defer_time_step * i).timeout.connect(func ():
			defer_sync_ship(friendly, player_name, ship_data)
		)
		# defer_sync_ship(friendly, player_name, ship_data)

func is_aabb_in_frustum(aabb: AABB, planes: Array[Plane]) -> bool:
	if planes.is_empty():
		return true  # No frustum data yet, include the ship
	for plane in planes:
		var positive_vertex = Vector3(
			aabb.end.x if plane.normal.x >= 0 else aabb.position.x,
			aabb.end.y if plane.normal.y >= 0 else aabb.position.y,
			aabb.end.z if plane.normal.z >= 0 else aabb.position.z
		)
		if plane.is_point_over(positive_vertex):
			return false
	return true

func is_point_in_frustum(point: Vector3, planes: Array[Plane]) -> bool:
	for plane in planes:
		if plane.is_point_over(point):
			return false
	return true

func _physics_process(_delta: float) -> void:
	if !_Utils.authority():
		return
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 # only terrain

	if players_size != players.size() or gun_updated:
		gun_updated = false
		players_size = players.size()
		print("Players size changed, now: ", players_size)
		var guns = find_all_guns(get_tree().root)
		var i = 0
		var gun_paths: Array[String] = []
		for gun: Gun in guns:
			var path = str(gun.get_path())
			gun.id = i
			gun_paths.push_back(path)
			i += 1
		#TcpThreadPool.initialize_guns(gun_paths)
		for p in players.values():
			var ship: Ship = p[0]
			if ship.team.is_bot:
				continue
			var pid = p[2]
			init_guns.rpc_id(pid, gun_paths)

	var visible_toggled = {}
	for p in players.values():
		var ship: Ship = p[0]
		visible_toggled[ship.name] = ship.visible_to_enemy
		if ship.health_controller.is_dead():
			ship.visible_to_enemy = true
		else:
			ship.visible_to_enemy = false

	for p_idx in players.size() - 1:
		var p_name = players.keys()[p_idx]
		var p: Ship = players[p_name][0]
		ray_query.from = p.global_position
		ray_query.from.y = 1.0
		for p2_idx in range(p_idx + 1,players.size()):
			var p2_name = players.keys()[p2_idx]
			var p2: Ship = players[p2_name][0]
			if p.team.team_id != p2.team.team_id and p.health_controller.is_alive() and p2.health_controller.is_alive(): # other team
				ray_query.to = p2.global_position
				ray_query.to.y = 1.0
				var collision: Dictionary = space_state.intersect_ray(ray_query)
				if collision.is_empty(): # can see each other no obstacles (add concealment)
					var dist = p.global_position.distance_to(p2.global_position)
					if p.concealment.get_concealment() > dist:
						p.visible_to_enemy = true
					if p2.concealment.get_concealment() > dist:
						p2.visible_to_enemy = true

	for p_name in players:
		var p: Ship = players[p_name][0]
		if visible_toggled[p.name] == p.visible_to_enemy:
			visible_toggled.erase(p.name)




	# if c > 2:
	# 	c = 0
	# 	# Prepare data for each team

	# var team_0_writer = StreamPeerBuffer.new()
	# var team_1_writer = StreamPeerBuffer.new()
	# var teams = [[], []] # team_id -> [ships]

	var team_0_bytes_list: Array = []
	var team_1_bytes_list: Array = []
	var partial_bytes_list: Array = []
	var writer = StreamPeerBuffer.new()

	for p_name: String in players:
		var p: Ship = players[p_name][0]
		var team_id = p.team.team_id
		var d0 = p.sync_ship_data2(p.visible_to_enemy, true) # friendly view
		var d1 = p.sync_ship_data2(p.visible_to_enemy, false) # enemy view
		var dt = p.sync_ship_transform()

		writer.put_u8(2) # partial update
		writer.put_var(p_name)
		writer.put_var(dt)
		partial_bytes_list.push_back([p, writer.data_array])
		writer.clear()

		if team_id == 0:
			# friendly
			writer.put_u8(1)
			writer.put_var(p_name)
			writer.put_var(d0)
			team_0_bytes_list.push_back([p, writer.data_array])
			writer.clear()

			# enemy
			writer.put_u8(0)
			writer.put_var(p_name)
			if p.visible_to_enemy:
				writer.put_var(d1)
			else:
				writer.put_var(null)
			team_1_bytes_list.push_back([p, writer.data_array])
			writer.clear()
		else:
			# friendly
			writer.put_u8(1)
			writer.put_var(p_name)
			writer.put_var(d0)
			team_1_bytes_list.push_back([p, writer.data_array])
			writer.clear()

			# enemy
			writer.put_u8(0)
			writer.put_var(p_name)
			if p.visible_to_enemy:
				writer.put_var(d1)
			else:
				writer.put_var(null)
			team_0_bytes_list.push_back([p, writer.data_array])
			writer.clear()


	# Send all team data to appropriate players
	# var team_0_bytes = team_0_writer.data_array
	# var team_1_bytes = team_1_writer.data_array

	for p_name in players:
		var p: Ship = players[p_name][0]
		var _p_id = players[p_name][2]
		var team_list = team_0_bytes_list if p.team.team_id == 0 else team_1_bytes_list
		if not p.team.is_bot:
			var writer1 = StreamPeerBuffer.new()
			var i = 0
			for b in team_list:
				var b0: Ship = b[0]
				if p == b0:
					pass
				elif visible_toggled.has(b0.name) or is_point_in_frustum(b0.global_position, p.frustum_planes): #or is_aabb_in_frustum(b0.get_aabb(), p.frustum_planes):
					writer1.data_array += b[1]
				elif b0.team.team_id == p.team.team_id or b0.visible_to_enemy:
					writer1.data_array += partial_bytes_list[i][1]
				i += 1
			var team_0_bytes = writer1.data_array
			if not team_0_bytes.is_empty():
				sync_game_state.rpc_id(_p_id, team_0_bytes)


	# c += 1
	# Sync individual player data
	for p_name in players:
		var p: Ship = players[p_name][0]
		var p_id = players[p_name][2]
		if p.team.is_bot:
			continue
		var d = p.sync_player_data()
		p.sync_player.rpc_id(p_id, d)


	team_0_valid_targets = _get_valid_targets(0)
	team_1_valid_targets = _get_valid_targets(1)


	# for p_name in players: # for every player, synchronize self with others - TODO: sync all to self instead
	# 	var p: Ship = players[p_name][0]
	# 	var _p_id = players[p_name][2]
	# 	# var d = p.sync_ship_data()
	# 	# d['vs'] = p.visible_to_enemy
	# 	var d = p.sync_ship_data2(p.visible_to_enemy)
	# 	# writer.data_array = d
	# 	# writer.put_u8(1 if p.visible_to_enemy else 0)
	# 	# d = writer.get_data_array()
	# 	for p_name2 in players: # every other player
	# 		var p2: Ship = players[p_name2][0]
	# 		var pid2 = players[p_name2][2]
	# 		if not p2.team.is_bot: # player to sync with is not bot
	# 			if p.team.team_id == p2.team.team_id or p.visible_to_enemy:
	# 				# p.sync.rpc_id(pid2, d) # sync self to other player
	# 				p.sync2.rpc_id(pid2, d)
	# 			else:
	# 				p._hide.rpc_id(pid2) # hide from other player


			#if p_id == p_id2:
				#p.sync.rpc_id(p_id2, d)
				#continue
			#var p2: Ship = players[p_id2][0]
			#ray_query.to = p2.global_position
			#var collision: Dictionary = space_state.intersect_ray(ray_query)
			#if !collision.is_empty() and collision.collider is Ship && collision.collider != p:
