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
var team_0_valid_targets: Array[Ship] = []
var team_1_valid_targets: Array[Ship] = []
var team_0_ships: Array[Ship] = []
var team_1_ships: Array[Ship] = []
# Unspotted enemies with their last known positions (Ship -> Vector3)
var team_0_unspotted_enemies: Dictionary = {}  # Unspotted enemies of team 0 (i.e., team 1 ships that went dark)
var team_1_unspotted_enemies: Dictionary = {}  # Unspotted enemies of team 1 (i.e., team 0 ships that went dark)
# Timestamps (seconds, from Time.get_ticks_msec()/1000) of when each ship went unspotted
var team_0_unspotted_times: Dictionary = {}  # Ship -> float
var team_1_unspotted_times: Dictionary = {}  # Ship -> float
# Hydro LKP system.
# hydro_lkp      – frozen last-known position per ship (updated every HYDRO_LKP_INTERVAL s).
# hydro_lkp_times– server time of the last position refresh.
# hydro_in_range – ships that were in hydro range THIS physics frame (cleared each frame).
var team_0_hydro_lkp: Dictionary = {}        # Ship -> Vector3
var team_1_hydro_lkp: Dictionary = {}
var team_0_hydro_lkp_times: Dictionary = {}  # Ship -> float
var team_1_hydro_lkp_times: Dictionary = {}
var team_0_hydro_in_range: Dictionary = {}   # Ship -> bool  (cleared each frame)
var team_1_hydro_in_range: Dictionary = {}
const HYDRO_LKP_INTERVAL: float = 4.0       # Seconds between frozen-position refreshes
# Radar LKP system — mirrors the hydro system but uses radar_spotting_range_override.
var team_0_radar_lkp: Dictionary = {}        # Ship -> Vector3
var team_1_radar_lkp: Dictionary = {}
var team_0_radar_lkp_times: Dictionary = {}  # Ship -> float
var team_1_radar_lkp_times: Dictionary = {}
var team_0_radar_in_range: Dictionary = {}   # Ship -> bool  (cleared each frame)
var team_1_radar_in_range: Dictionary = {}
# One-time bootstrap per team: after the first visual spot, seed LKPs for
# still-hidden enemies so bots can begin coordinated hunting immediately.
var team_0_first_spot_lkp_seeded: bool = false
var team_1_first_spot_lkp_seeded: bool = false

# Known enemy clusters (spotted + last known positions of unspotted)
var team_0_known_enemy_clusters: Array[Dictionary] = []
var team_1_known_enemy_clusters: Array[Dictionary] = []
const CLUSTER_DISTANCE: float = 4000.0
var players_size = 0
var team_spawn_counts = {}  # Track how many players have spawned per team for even distribution
var team_spawn_slots = {}  # Pre-shuffled spawn slot indices per team
const BOT_SHIP_CONFIG_PATH := "res://bot_ship_config.cfg"


var map: Map = null

# Shared threat registry — every bot holds a pointer into a bin here instead
# of maintaining its own threat list.  Bots subscribe with their
# (team_id, effective_radius); the global tick below republishes enemy
# positions once per THREAT_UPDATE_INTERVAL frames.
var threat_registry: ThreatRegistry = ThreatRegistry.new()
const THREAT_UPDATE_INTERVAL: int = 4
const THREAT_STALE_DECAY_SECONDS: float = 100.0

# Match state
var match_active: bool = false
var match_ended: bool = false
var match_end_timer: float = 0.0
const MATCH_END_DELAY: float = 5.0  # Seconds to wait after last kill before showing end screen
const MATCH_DURATION: float = 20.0 * 60.0  # 20 minutes
var match_elapsed: float = 0.0
var _match_timer_sync_timer: float = 0.0
const MATCH_TIMER_SYNC_INTERVAL: float = 5.0

var all_players_spawned: bool = false
# When running the server from the editor, don't end/reset the match on disconnect
# so a single debugged client leaving doesn't tear everything down.
var _debug_keep_alive: bool = OS.has_feature("editor")
const MATCHMAKER_HEARTBEAT_INTERVAL: float = 5.0  # seconds between registration pings
var matchmaker_heartbeat_timer: float = 0.0

func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	process_physics_priority = 100 # Run after other scripts
	# Create the game world as a separate entity
	game_world = preload("res://src/Maps/game_world.tscn").instantiate()
	add_child(game_world)
	spawn_point = game_world.get_child(1)
	map = load("res://src/Maps/map.tscn").instantiate()
	game_world.get_node("Env").add_child(map)
	print("Game server started and world loaded")

	# Build the navigation SDF map for bot AI (must happen before bots spawn)
	if map.islands.size() > 0:
		NavigationMapManager.build_map(
			map.islands,
			Rect2(-17500, -17500, 35000, 35000)
		)
	else:
		push_warning("Server: No islands found on map — NavigationMap not built")

	# # Wait a frame for the world to fully initialize
	# await get_tree().process_frame

	# # Take the map snapshot only on the server
	# if multiplayer.is_server():
	# 	await Minimap.server_take_map_snapshot(get_viewport())

	# Register with the matchmaker so it knows this server is available
	_notify_matchmaker_available()

	# Tell TorpedoManager to find the new server node (needed after scene reload)
	(TorpedoManager as _TorpedoManager).reacquire_server()

func _on_peer_connected(id):
	print("Peer connected: ", id)

	#join_game.rpc_id(id)
	#spawn_player(id, str(id))
	# Wait for them to register before spawning

func _on_peer_disconnected(id):
	print("Peer disconnected: ", id)
	if _debug_keep_alive:
		print("Editor/debug build: keeping match alive despite disconnect")
		return
	if not match_complete:
		# Mid-match: mark disconnected human player as having left, then check if all are gone.
		for p_name in players:
			if players[p_name][2] == id:
				var ship: Ship = players[p_name][0]
				if not ship.team.is_bot and not _players_quit.has(p_name):
					_players_quit.append(p_name)
					print("Player ", p_name, " disconnected mid-match (treated as quit)")
				break
		_check_all_players_quit()
	else:
		# After match is complete, check if all human players have left.
		var humans_remaining = 0
		for p_name in players:
			var p = players[p_name]
			var ship: Ship = p[0]
			if not ship.team.is_bot:
				var peer_id = p[2]
				if peer_id != id and multiplayer.get_peers().has(peer_id):
					humans_remaining += 1
		if humans_remaining == 0:
			print("All human players disconnected, resetting immediately")
			_reset_server()

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

# var bot_id: int = 0
var ship_id: int = 0

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

	# Seed bot ship config from the human player's settings when no bot config exists.
	if not is_bot:
		_ensure_bot_ship_config_file(player_name)

	# Load and apply saved upgrades/skills for humans and bots.
	call_deferred("_load_and_apply_player_config", player, player_name, ship, is_bot)


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
		var bot_controller = preload("res://src/ship/bot_controller_v4.tscn").instantiate()
		bot_controller.name = "BotController"
		match player.ship_class:
			Ship.ShipClass.DD:
				bot_controller.behavior = DDBehavior.new()
			Ship.ShipClass.BB:
				bot_controller.behavior = BBBehavior.new()
			Ship.ShipClass.CA:
				bot_controller.behavior = CABehavior.new()
		bot_controller.behavior.threat_mod = _get_bot_threat_mod(ship)
		# bot_controller.behavior = BotBehavior.new()  # Use generic behavior for now, can be customized based on ship class or other factors
		player.get_node("Modules").add_child(bot_controller)
		bot_controller._ship = player
		bot_controller.bot_id = ship_id
	else:
		# Only add player control for human players
		var controller = preload("res://scenes/player_control.tscn").instantiate()
		# controller.name = str(id)
		controller.name = "PlayerControl"
		player.get_node("Modules").add_child(controller)
		player.control = controller
		controller.ship = player

	ship_id += 1
	player.id = ship_id

	# Add to world - note game_world is a child of this node
	players[player_name] = [player, ship, id]

	# Track consumable state changes so off-screen friendlies get full syncs
	# Deferred because consumable_manager is @onready (null until _ready())
	call_deferred("_connect_consumable_signals", player)

	var spawn_map = get_node("GameWorld/Env").get_child(0)
	var team_spawn_point: Vector3 = (spawn_map.get_node("Spawn").get_child(team_id) as Node3D).global_position

	if team_info["team"].size() <= 4:
		team_spawn_point *= 0.15

	var right_of_spawn = Vector3.UP.cross(team_spawn_point).normalized()

	# Calculate spawn position
	# Count total players on this team from team_info
	var team_player_count = 0
	for team_player_id in team_info["team"]:
		var player_data = team_info["team"][team_player_id]
		if int(player_data["team"]) == team_id:
			team_player_count += 1

	# Check if spawn_position is provided in team_info (from matchmaker)
	var spawn_index: int
	var player_team_data = team_info["team"].get(player_name, {})
	if player_team_data.has("spawn_position"):
		# Use the pre-assigned spawn position from matchmaker
		spawn_index = player_team_data["spawn_position"]
	else:
		# Fallback to old random slot system for backwards compatibility
		if not team_spawn_slots.has(team_id):
			var slots = []
			for i in range(team_player_count):
				slots.append(i)
			slots.shuffle()
			team_spawn_slots[team_id] = slots
			team_spawn_counts[team_id] = 0

		var slot_index = team_spawn_counts[team_id]
		spawn_index = team_spawn_slots[team_id][slot_index]
		team_spawn_counts[team_id] += 1

	var spawn_offset: float
	if team_player_count <= 1:
		spawn_offset = 0.0
	else:
		# Distribute evenly from -10000 to 10000
		spawn_offset = -10000.0 + (spawn_index * 20000.0 / (team_player_count - 1))

	var spawn_pos = right_of_spawn * spawn_offset + team_spawn_point
	spawn_pos.y = 0
	spawn_point.add_child(player)
	player.position = spawn_pos
	spawn_pos = player.global_position
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var rot_y = atan2(-team_spawn_point.x, team_spawn_point.z)
	player.rotation.y = rot_y

	#join_game.rpc_id(id)
	for p_name in players:
		var p: Ship = players[p_name][0]
		var p_ship = players[p_name][1]
		var pid = players[p_name][2]
		# notify new client of current players
		if not is_bot:
			spawn_players_client.rpc_id(id, pid,p.name, p.global_position, p.global_rotation.y, p.team.team_id, p_ship, p.control is BotControllerV3 or p.control is BotControllerV4)
		#notify current players of new player
		if not p.team.is_bot:
			spawn_players_client.rpc_id(pid, id, player.name, spawn_pos, rot_y, team_id, ship, is_bot)

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
					print("Spawning bot: ID=", team_player_id, ", player_name=", team_player_id, ", ship=", player_data["ship"])
					spawn_player(ship_id, team_player_id)
			players_spawned_bots = true
	match_active = true
	match_elapsed = 0.0
	_match_timer_sync_timer = 0.0
	_sync_match_timer.rpc(0.0)
	# --- Replay: begin recording once ALL ships (human + bots) are in the world.
	# Guard with players_spawned_bots so the hook only fires in the human
	# player's spawn_player call AFTER the bot-spawning loop completes,
	# not in each individual bot's spawn_player call.
	if _Utils.authority() and players_spawned_bots:
		var _rr = get_node_or_null("/root/ReplayRecorder")
		if _rr != null and not _rr._match_active:
			var _all_ships: Array = []
			for _p_name in players:
				_all_ships.append(players[_p_name][0])
			_rr.begin_match(_all_ships, 0)  # map_id 0 = default map

@rpc("call_remote", "reliable")
func spawn_players_client(id, _player_name, _pos, rot_y, team_id, ship, is_bot):

	if !Minimap.is_initialized:
		Minimap.server_take_map_snapshot(get_viewport())
	if players.has(_player_name):
		return

	var player: Ship = load(ship).instantiate()
	player.name = _player_name
	player.visible = false

	player._enable_weapons()

	# Check if this is the local player or a bot by checking team info
	var is_local_player = (int(id) == multiplayer.get_unique_id())

	# Only add player control for local human player
	if is_local_player and not is_bot:
		NetworkManager.player_controller_connected = true

		var controller = preload("res://scenes/player_control.tscn").instantiate()
		controller.name = "PlayerControl"
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

	# Deferred so @onready vars (like consumable_manager) are ready
	# call_deferred("_connect_consumable_signals", player)
	player.rotation.y = rot_y
	#player.global_position = pos


func _ensure_bot_ship_config_file(player_name: String) -> void:
	if FileAccess.file_exists(BOT_SHIP_CONFIG_PATH):
		print("Using existing bot ship config: ", BOT_SHIP_CONFIG_PATH)
		return

	var player_config_path := "user://%s.cfg" % player_name
	var config := ConfigFile.new()
	var err := config.load(player_config_path)
	if err != OK:
		push_error("Failed to load player config for bot ship config copy: " + player_config_path + " error=" + str(err))
		return

	err = config.save(BOT_SHIP_CONFIG_PATH)
	if err != OK:
		push_error("Failed to save bot ship config to: " + BOT_SHIP_CONFIG_PATH + " error=" + str(err))
		return

	print("Copied player ship config to bot ship config: ", BOT_SHIP_CONFIG_PATH)


func _load_ship_config_from_file(config_path: String) -> Dictionary:
	var config := ConfigFile.new()
	var err := config.load(config_path)
	if err != OK:
		push_error("Failed to load ship config: " + config_path + " error=" + str(err))
		return {}

	var ship_config := {}
	if config.has_section("ships"):
		for ship_key in config.get_section_keys("ships"):
			ship_config[ship_key] = config.get_value("ships", ship_key, {})

	return {
		"selected_ship": config.get_value("game", "selected_ship", ""),
		"ship_config": ship_config,
	}


func _get_bot_threat_mod(ship_path: String) -> float:
	var settings := _load_ship_config_from_file(BOT_SHIP_CONFIG_PATH)
	assert(not settings.is_empty(), "Missing bot ship config: " + BOT_SHIP_CONFIG_PATH)

	var ship_config: Dictionary = settings["ship_config"]
	assert(ship_config.has(ship_path), "Missing bot ship entry in config: " + ship_path)

	var upgrades: Dictionary = ship_config[ship_path]
	assert(upgrades.has("threat-mod"), "Missing threat-mod for bot ship: " + ship_path)
	return float(upgrades["threat-mod"])


# Function to load and apply player or bot config
func _load_and_apply_player_config(ship: Ship, player_name: String, ship_path: String = "", is_bot: bool = false) -> void:
	if player_name.is_empty() or not ship:
		return

	var config_path := BOT_SHIP_CONFIG_PATH if is_bot else "user://%s.cfg" % player_name
	print("Loading config for player: ", player_name, " from ", config_path)

	var settings := _load_ship_config_from_file(config_path)
	if settings.is_empty():
		return

	var config_ship_path: String = ship_path if not ship_path.is_empty() else settings["selected_ship"]
	var ship_config: Dictionary = settings["ship_config"]

	if not ship_config.has(config_ship_path):
		print("No upgrades configured for ship: ", config_ship_path, " for player: ", player_name)
		return

	# Apply each upgrade to the ship
	var upgrades: Dictionary = ship_config[config_ship_path]
	print("Applying ", upgrades.size(), " upgrades/skills entries to ship for player: ", player_name)

	for slot_str in upgrades:
		if slot_str == "skills" or slot_str == "threat-mod":
			continue
		var upgrade_id: String = upgrades[slot_str]
		if upgrade_id and not upgrade_id.is_empty():
			var upgrade_instance = UpgradeRegistry.create_upgrade(upgrade_id)
			if upgrade_instance:
				ship.upgrades.add_upgrade(int(slot_str), upgrade_instance)
				print("Applied upgrade to ship: ", upgrade_id)
			else:
				push_error("Failed to create upgrade from registry with id: " + upgrade_id)

	# Apply each skill to the ship
	if not upgrades.has("skills"):
		return
	var skills = upgrades["skills"]

	for skill_id in skills:
		if skill_id and not skill_id.is_empty():
			var skill_instance = SkillsRegistry.create_skill(skill_id)
			if skill_instance == null:
				push_error("Failed to create skill from registry with id: " + skill_id)
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

func get_team_ships(team_id: int) -> Array[Ship]:
	# var team_ships: Array = []
	# for p_name in players:
	# 	# print("Checking player ID: ", p, " current HP: ", (players[p][0] as Ship).health_controller.current_hp)
	# 	var ship: Ship = players[p_name][0]
	# 	if is_instance_valid(ship) and ship.team.team_id == team_id:
	# 		team_ships.append(ship)
	# return team_ships
	if team_id == 0:
		return team_0_ships
	else:
		return team_1_ships

func _get_team_ships(team_id: int) -> Array[Ship]:
	var team_ships: Array[Ship] = []
	for p_name in players:
		var ship: Ship = players[p_name][0]
		if is_instance_valid(ship) and ship.team.team_id == team_id:
			team_ships.append(ship)
	return team_ships

func _get_team(team_id: int) -> Array[Ship]:
	var ships: Array[Ship] = []
	for p_name in players:
		var ship: Ship = players[p_name][0]
		if ship.team.team_id == team_id and ship.is_alive():
			ships.append(ship)
	return ships

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

func get_unspotted_enemies(team_id: int) -> Dictionary:
	"""Returns a dictionary of unspotted enemy ships and their last known positions.
	Key: Ship, Value: Vector3 (last known position)"""
	if team_id == 0:
		return team_0_unspotted_enemies
	else:
		return team_1_unspotted_enemies

func get_unspotted_enemy_times(team_id: int) -> Dictionary:
	"""Returns a dictionary mapping unspotted enemy ships to the timestamp (seconds)
	when they were last spotted. Key: Ship, Value: float (Time.get_ticks_msec()/1000)."""
	if team_id == 0:
		return team_0_unspotted_times
	else:
		return team_1_unspotted_times

func get_all_ships() -> Array:
	var all_ships: Array = []
	for p in players.values():
		var ship: Ship = p[0]
		if is_instance_valid(ship):
			all_ships.append(ship)
	return all_ships


func _team_has_spotted_enemy(team_id: int) -> bool:
	for ship in _get_enemy_ships(team_id):
		if not is_instance_valid(ship):
			continue
		if ship.health_controller.is_alive() and ship.visible_to_enemy:
			return true
	return false


func _seed_first_spot_unspotted_lkps(team_id: int) -> void:
	var enemy_team_id := 1 if team_id == 0 else 0
	var unspotted: Dictionary = team_0_unspotted_enemies if team_id == 0 else team_1_unspotted_enemies
	var times: Dictionary = team_0_unspotted_times if team_id == 0 else team_1_unspotted_times
	for enemy in _get_team(enemy_team_id):
		if not is_instance_valid(enemy):
			continue
		if enemy.visible_to_enemy:
			continue
		unspotted[enemy] = enemy.global_position
		times[enemy] = current_time


func _update_team_clusters():
	team_0_known_enemy_clusters = _compute_known_enemy_clusters(0)
	team_1_known_enemy_clusters = _compute_known_enemy_clusters(1)





func _compute_known_enemy_clusters(team_id: int) -> Array[Dictionary]:
	"""Compute clusters of known enemies (spotted + last known unspotted positions)."""
	var positions: Array[Dictionary] = []  # Array of {position: Vector3, ship: Ship or null}

	# Add currently spotted enemies (valid targets)
	var valid_targets = team_0_valid_targets if team_id == 0 else team_1_valid_targets
	for ship in valid_targets:
		positions.append({position = ship.global_position, ship = ship})

	# Add last known positions of unspotted enemies
	var unspotted = team_0_unspotted_enemies if team_id == 0 else team_1_unspotted_enemies
	for ship in unspotted.keys():
		var last_pos: Vector3 = unspotted[ship]
		positions.append({position = last_pos, ship = ship})

	if positions.size() == 0:
		return []

	# Simple clustering by distance
	var clusters: Array[Dictionary] = []
	var assigned: Array[bool] = []
	assigned.resize(positions.size())
	assigned.fill(false)

	for i in range(positions.size()):
		if assigned[i]:
			continue

		var cluster_positions: Array[Vector3] = [positions[i].position]
		var cluster_ships: Array = [positions[i].ship]
		assigned[i] = true

		for j in range(i + 1, positions.size()):
			if assigned[j]:
				continue
			# Check if close enough to any position in the cluster
			for cluster_pos in cluster_positions:
				if positions[j].position.distance_to(cluster_pos) <= CLUSTER_DISTANCE:
					cluster_positions.append(positions[j].position)
					cluster_ships.append(positions[j].ship)
					assigned[j] = true
					break

		# Calculate cluster center
		var center = Vector3.ZERO
		for pos in cluster_positions:
			center += pos
		center /= cluster_positions.size()

		clusters.append({center = center, ships = cluster_ships})

	return clusters





func get_team_spawn_position(team_id: int) -> Vector3:
	"""Get the spawn position for a team. Used for flanking detection."""
	var spawn_map = get_node_or_null("GameWorld/Env")
	if spawn_map == null or spawn_map.get_child_count() == 0:
		print("Spawn map missing or empty")
		return Vector3.ZERO
	spawn_map = spawn_map.get_child(0)
	var spawn_node = spawn_map.get_node_or_null("Spawn")
	# print("Getting spawn position for team ", team_id, ": spawn_node=", spawn_node)
	if spawn_node == null or spawn_node.get_child_count() <= team_id:
		print("Spawn node missing or does not have child for team ", team_id)
		return Vector3.ZERO
	return (spawn_node.get_child(team_id) as Node3D).global_position


func get_nearest_enemy_cluster(position: Vector3, team_id: int) -> Dictionary:
	var enemy_clusters = team_0_known_enemy_clusters if team_id == 0 else team_1_known_enemy_clusters
	if enemy_clusters.size() == 0:
		return {}

	var nearest = enemy_clusters[0]
	var nearest_dist = position.distance_to(nearest.center)

	for cluster in enemy_clusters:
		var dist = position.distance_to(cluster.center)
		if dist < nearest_dist:
			nearest = cluster
			nearest_dist = dist

	return nearest




# func sync_players(player_data: Array[Dictionary]) -> void:
# 	for data in player_data:
# 		var id = data.get("id", -1)
# 		if id == -1 or not players.has(id):
# 			continue
# 		var ship: Ship = players[id][0]
# 		if not is_instance_valid(ship):
# 			continue
# 		# ship.set_input(data.get("input", [0,0]), data.get("aim_point", Vector3.ZERO))




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
	if not is_inside_tree():
		return
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

@rpc("any_peer", "reliable", "call_remote", 1)
func sync_game_state_reliable(bytes: PackedByteArray):
	sync_game_state(bytes)

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

var consumable_toggled: Dictionary[Ship, bool] = {}
var visible_toggled: Dictionary[Ship, bool] = {}
var sunk_toggled: Dictionary[Ship, bool] = {}
var closest_enemies_that_can_see = {}

# Called when a ship's consumable state changes (used or cooldown ended).
# Flags the ship so the next server sync sends a full update even if off-screen.
func _on_consumable_changed(_item: ConsumableItem, ship: Ship) -> void:
	consumable_toggled[ship] = true

# Called when a ship sinks. Flags the ship so the next server sync sends
# a full update (sinking animation, kill feed, etc.) even if off-screen.
func _on_ship_sunk(ship: Ship) -> void:
	sunk_toggled[ship] = true

# Connect after @onready vars are initialized (called via call_deferred)
func _connect_consumable_signals(player: Ship) -> void:
	if player.consumable_manager:
		player.consumable_manager.consumable_used.connect(_on_consumable_changed.bind(player))
		player.consumable_manager.consumable_ready.connect(_on_consumable_changed.bind(player))
	if player.health_controller:
		player.health_controller.ship_sunk.connect(_on_ship_sunk.bind(player))

var current_time = 0.0
const UNSPOTTED_TIME = 100.0

var spotter_candidates = {}
func handle_spot(spotter: Ship, spotted: Ship, dist: float):
	# var dist = spotter.global_position.distance_to(spotted.global_position)
	# Hydroacoustic Search (or any future consumable) can set a spotting_range_override
	# on the spotter, forcing detection of any enemy within that radius regardless
	# of the spotted ship's concealment radius.
	var hydro_override: float = (spotter.concealment.params.p() as ConcealmentParams).spotting_range_override
	var radar_override: float = (spotter.concealment.params.p() as ConcealmentParams).radar_spotting_range_override
	var spotting_override: float = max(hydro_override, radar_override)
	if max(spotted.concealment.get_concealment(), spotting_override) > dist:
		spotted.visible_to_enemy = true
		spotted.det_los = true
		# if !visible_toggled[spotted]:
		# 	if spotted.concealment.last_spotted_time < current_time - UNSPOTTED_TIME:
		# 		spotted.concealment.spotted_by = spotter
		# 		spotter.stats.spotting_count += 1
		# 		spotter.stats.damage_events.append({"type": "spot"})
		# else:
		if closest_enemies_that_can_see.has(spotted):
			closest_enemies_that_can_see[spotted].append([spotter,dist])
		else:
			closest_enemies_that_can_see[spotted] = [[spotter,dist]]
			# var closest_enemies: Array = closest_enemies_that_can_see[spotted]
			# closest_enemies.append(spotter)

func handle_spot_attribution():
	for spotted in closest_enemies_that_can_see.keys():
		var closest_spotter: Ship = null
		var closest_dist: float = INF
		for spotter_info in closest_enemies_that_can_see[spotted]:
			var spotter: Ship = spotter_info[0]
			var dist: float = spotter_info[1]
			if dist < closest_dist:
				closest_dist = dist
				closest_spotter = spotter
		if closest_spotter != null:
			spotted.concealment.spotted_by = closest_spotter
			if !visible_toggled[spotted] and spotted.concealment.last_spotted_time < current_time - UNSPOTTED_TIME:
				closest_spotter.stats.spotting_count += 1
				closest_spotter.stats.damage_events.append({"type": "spot"})
	closest_enemies_that_can_see.clear()


func _broadcast_match_end():
	"""Send match end notification with leaderboard data to all clients."""
	var t0 = _get_team(0)
	var t1 = _get_team(1)
	var winning_team: int
	if t0.size() == 0 and t1.size() > 0:
		winning_team = 1
	elif t1.size() == 0 and t0.size() > 0:
		winning_team = 0
	else:
		# Time limit — determine winner by total HP remaining
		var hp0: float = 0.0
		var hp1: float = 0.0
		for ship in t0:
			hp0 += ship.health_controller.current_hp
		for ship in t1:
			hp1 += ship.health_controller.current_hp
		winning_team = 0 if hp0 >= hp1 else 1

	# Gather leaderboard data from all players (including bots)
	var leaderboard: Array[Dictionary] = []
	for p_name in players:
		var ship: Ship = players[p_name][0]
		var stats: Stats = ship.stats
		var entry := {
			"player_name": p_name,
			"ship_name": ship.ship_name,
			"team_id": ship.team.team_id,
			"is_bot": ship.team.is_bot,
			"alive": ship.is_alive(),
			"total_damage": stats.total_damage,
			"frags": stats.frags,
			"main_hits": stats.main_hits,
			"main_damage": stats.main_damage,
			"citadel_count": stats.citadel_count,
			"secondary_count": stats.secondary_count,
			"sec_damage": stats.sec_damage,
			"torpedo_count": stats.torpedo_count,
			"torpedo_damage": stats.torpedo_damage,
			"fire_count": stats.fire_count,
			"fire_damage": stats.fire_damage,
			"flood_count": stats.flood_count,
			"flood_damage": stats.flood_damage,
			"spotting_damage": stats.spotting_damage,
			"potential_damage": stats.potential_damage,
		}
		leaderboard.append(entry)

	for p_name in players:
		var p = players[p_name]
		var ship: Ship = p[0]
		if not ship.team.is_bot:
			var peer_id = p[2]
			notify_match_end.rpc_id(peer_id, winning_team, leaderboard)

	# Finalize the replay file server-side.
	# _Utils.match_ended is only emitted inside notify_match_end (client RPC),
	# so we must call end_match() directly here on the server.
	if _Utils.authority():
		var _rr = get_node_or_null("/root/ReplayRecorder")
		if _rr != null and _rr._match_active:
			_rr.end_match(winning_team)

func _notify_matchmaker_available():
	"""Send UDP notification to the matchmaker that this server is available."""
	var port = NetworkManager.server_port
	if port == 0:
		return
	var udp = PacketPeerUDP.new()
	udp.connect_to_host(GameSettings.matchmaker_ip, 28961)
	var packet = {
		"request": "server_available",
		"port": port
	}
	udp.put_packet(JSON.stringify(packet).to_utf8_buffer())
	print("Notified matchmaker that port ", port, " is available")

func _reset_server():
	"""Reset the server by reloading the scene. The new instance's _ready()
	re-creates the game world and re-registers with the matchmaker."""
	print("=== Server resetting for new match ===")

	_players_quit.clear()

	# Clear projectile and torpedo managers before reload to prevent
	# stale references to freed ships/nodes causing null crashes
	ProjectileManager.clear_all()
	(TorpedoManager as _TorpedoManager).clear_all()

	get_tree().call_deferred("reload_current_scene")

@rpc("authority", "reliable", "call_remote")
func notify_match_end(winning_team: int, leaderboard: Array):
	"""Called on clients when the match ends."""
	if _Utils.match_result.is_empty():
		_Utils.match_result = {}
	_Utils.match_result["leaderboard"] = leaderboard
	_Utils.match_ended.emit(winning_team)

@rpc("authority", "call_local", "unreliable_ordered")
func _sync_match_timer(elapsed: float) -> void:
	"""Called on all clients (and locally) to sync the match elapsed time."""
	match_elapsed = elapsed

func get_match_time_remaining() -> float:
	return maxf(MATCH_DURATION - match_elapsed, 0.0)

@rpc("any_peer", "call_remote", "reliable")
func player_quit_match() -> void:
	"""Called by a client when the player deliberately quits the match."""
	if not _Utils.authority():
		return
	var caller_id: int = multiplayer.get_remote_sender_id()
	for p_name in players:
		if players[p_name][2] == caller_id:
			if not _players_quit.has(p_name):
				_players_quit.append(p_name)
				print("Player ", p_name, " quit the match")
			break
	_check_all_players_quit(true)

func _check_all_players_quit(deliberate: bool = false) -> void:
	"""End the match if every non-bot player has quit or disconnected.
	deliberate=true means all remaining players used the in-game quit menu;
	the debug guard is bypassed so the match ends and cleanup runs normally."""
	if _debug_keep_alive and not deliberate:
		return  # Suppress abandon on transient disconnect while debugging
	if match_complete or match_ended:
		return
	if players.is_empty():
		return  # No players yet — match hasn't started
	for p_name in players:
		var ship: Ship = players[p_name][0]
		if not ship.team.is_bot and not _players_quit.has(p_name):
			return  # At least one human is still in the match
	print("All human players have left — stamping replay end and resetting")
	match_ended = true
	_end_match_abandoned()
	match_complete = true
	_reset_server()

func _end_match_abandoned() -> void:
	"""Write the replay end-stamp for a match that ended without a victor."""
	if not _Utils.authority():
		return
	var _rr = get_node_or_null("/root/ReplayRecorder")
	if _rr != null and _rr._match_active:
		_rr.end_match(255)  # 255 (u8) = no winner / match abandoned

var match_complete = false
var _players_quit: Array = []  # Player names who explicitly quit or disconnected mid-match

func _physics_process(_delta: float) -> void:
	if match_complete:
		return

	# Periodically re-register with matchmaker while idle (no match running)
	if not match_active and not match_ended:
		matchmaker_heartbeat_timer -= _delta
		if matchmaker_heartbeat_timer <= 0:
			_notify_matchmaker_available()
			matchmaker_heartbeat_timer = MATCHMAKER_HEARTBEAT_INTERVAL

	current_time = Time.get_ticks_msec() / 1000.0
	team_0_ships = _get_team(0)
	team_1_ships = _get_team(1)

	# Update clusters and average positions
	_update_team_clusters()

	# Tick match timer (server advances elapsed time and broadcasts it)
	if _Utils.authority() and match_active and not match_ended:
		match_elapsed += _delta
		_match_timer_sync_timer -= _delta
		if _match_timer_sync_timer <= 0.0:
			_match_timer_sync_timer = MATCH_TIMER_SYNC_INTERVAL
			_sync_match_timer.rpc(match_elapsed)
		if match_elapsed >= MATCH_DURATION:
			match_ended = true
			match_end_timer = MATCH_END_DELAY
			print("Match ended! Time limit reached — draw!")

	# Match end detection (server-side)
	if _Utils.authority() and match_active and not match_ended:
		var team_0_all = _get_team_ships(0)
		var team_1_all = _get_team_ships(1)
		# Only check if both teams have been populated
		if team_0_all.size() > 0 and team_1_all.size() > 0:
			if team_0_ships.size() == 0 or team_1_ships.size() == 0:
				match_ended = true
				var winning_team = 1 if team_0_ships.size() == 0 else 0
				match_end_timer = MATCH_END_DELAY
				print("Match ended! Team ", winning_team, " wins!")

	# Match end delay timer (authority only — clients transition via the end screen)
	if _Utils.authority() and match_ended and match_end_timer > 0:
		match_end_timer -= _delta
		if match_end_timer <= 0:
			_broadcast_match_end()
			match_complete = true
			_reset_server()

	if !_Utils.authority():
		return
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 | (1 << 3) | (1 << 5) # terrain + smoke


	closest_enemies_that_can_see.clear()
	visible_toggled.clear()
	team_0_hydro_in_range.clear()
	team_1_hydro_in_range.clear()
	team_0_radar_in_range.clear()
	team_1_radar_in_range.clear()

	var alive_players: Array[Ship] = []
	for p in players.values():
		var ship: Ship = p[0]
		visible_toggled[ship] = ship.visible_to_enemy
		if ship.health_controller.is_dead() and !ship.health_controller.been_dead():
			ship.visible_to_enemy = true
		else:
			ship.visible_to_enemy = false
		ship.det_los = false
		ship.det_hydro = false
		ship.det_radar = false
		if ship.health_controller.is_alive():
			alive_players.append(ship)

	for i in alive_players.size():
		var a: Ship = alive_players[i]
		for j in range(i + 1, alive_players.size()):
			var b: Ship = alive_players[j]
			if a.team.team_id == b.team.team_id:
				continue
			_check_pair_detection(a, b, ray_query, space_state)

	handle_spot_attribution()

	# One-time per team: once they spot any enemy at all, snapshot current
	# positions of every still-hidden enemy as LKPs.
	if not team_0_first_spot_lkp_seeded and _team_has_spotted_enemy(0):
		_seed_first_spot_unspotted_lkps(0)
		team_0_first_spot_lkp_seeded = true
	if not team_1_first_spot_lkp_seeded and _team_has_spotted_enemy(1):
		_seed_first_spot_unspotted_lkps(1)
		team_1_first_spot_lkp_seeded = true

	for p_name in players:
		var p: Ship = players[p_name][0]
		if visible_toggled[p] == p.visible_to_enemy:
			visible_toggled.erase(p)
		else:
			# Visibility changed - update unspotted enemy lists
			var enemy_team_id = 1 if p.team.team_id == 0 else 0
			var unspotted_dict = team_0_unspotted_enemies if enemy_team_id == 0 else team_1_unspotted_enemies

			if p.visible_to_enemy:
				# Ship became spotted - remove from unspotted list
				if unspotted_dict.has(p):
					unspotted_dict.erase(p)
					var times_dict = team_0_unspotted_times if enemy_team_id == 0 else team_1_unspotted_times
					times_dict.erase(p)
			else:
				# Ship became unspotted - add to unspotted list with last known position
				# Only add if ship has been spotted before (last_spotted_time > 0 means it was spotted at some point)
				if p.health_controller.is_alive() and p.concealment.last_spotted_time > 0:
					unspotted_dict[p] = p.global_position
					var times_dict = team_0_unspotted_times if enemy_team_id == 0 else team_1_unspotted_times
					times_dict[p] = Time.get_ticks_msec() / 1000.0

	# Clean up dead ships from unspotted lists
	for ship in team_0_unspotted_enemies.keys():
		if not is_instance_valid(ship) or ship.health_controller.is_dead():
			team_0_unspotted_enemies.erase(ship)
			team_0_unspotted_times.erase(ship)
	for ship in team_1_unspotted_enemies.keys():
		if not is_instance_valid(ship) or ship.health_controller.is_dead():
			team_1_unspotted_enemies.erase(ship)
			team_1_unspotted_times.erase(ship)
	# Clean up dead ships from hydro LKP tables
	for ship in team_0_hydro_lkp.keys():
		if not is_instance_valid(ship) or ship.health_controller.is_dead():
			team_0_hydro_lkp.erase(ship)
			team_0_hydro_lkp_times.erase(ship)
	for ship in team_1_hydro_lkp.keys():
		if not is_instance_valid(ship) or ship.health_controller.is_dead():
			team_1_hydro_lkp.erase(ship)
			team_1_hydro_lkp_times.erase(ship)
	# Clean up dead ships from radar LKP tables
	for ship in team_0_radar_lkp.keys():
		if not is_instance_valid(ship) or ship.health_controller.is_dead():
			team_0_radar_lkp.erase(ship)
			team_0_radar_lkp_times.erase(ship)
	for ship in team_1_radar_lkp.keys():
		if not is_instance_valid(ship) or ship.health_controller.is_dead():
			team_1_radar_lkp.erase(ship)
			team_1_radar_lkp_times.erase(ship)

	_send_hydro_syncs()
	_send_radar_syncs()

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
				elif visible_toggled.has(b0) or consumable_toggled.has(b0) or sunk_toggled.has(b0) or is_point_in_frustum(b0.global_position, p.frustum_planes):
					writer1.data_array += b[1]
				elif b0.team.team_id == p.team.team_id or b0.visible_to_enemy:
					writer1.data_array += partial_bytes_list[i][1]
				i += 1
			var team_0_bytes = writer1.data_array
			if not team_0_bytes.is_empty():
				if visible_toggled.size() > 0 or consumable_toggled.size() > 0 or sunk_toggled.size() > 0:
					sync_game_state_reliable.rpc_id(_p_id, team_0_bytes)
				else:
					sync_game_state.rpc_id(_p_id, team_0_bytes)

			consumable_toggled.clear()
			sunk_toggled.clear()

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

	if Engine.get_physics_frames() % THREAT_UPDATE_INTERVAL == 0:
		_update_threat_registry()



## Publish the latest per-team enemy position + decay lists to the shared
## ThreatRegistry.  Called once per THREAT_UPDATE_INTERVAL frames globally;
## bots read their bin's zones on-demand (no per-ship gathering).
func _update_threat_registry() -> void:
	if threat_registry == null:
		return
	_publish_team_threats(0)
	_publish_team_threats(1)


func _publish_team_threats(team_id: int) -> void:
	var ids := PackedInt32Array()
	var data := PackedVector3Array()
	var valid_targets = team_0_valid_targets if team_id == 0 else team_1_valid_targets
	for enemy in valid_targets:
		if is_instance_valid(enemy) and enemy.is_alive():
			ids.append(int(enemy.get_instance_id()))
			data.append(Vector3(enemy.global_position.x, enemy.global_position.z, 1.0))

	var unspotted = team_0_unspotted_enemies if team_id == 0 else team_1_unspotted_enemies
	var unspotted_times = team_0_unspotted_times if team_id == 0 else team_1_unspotted_times
	var now: float = Time.get_ticks_msec() / 1000.0
	for enemy_ship in unspotted.keys():
		if not is_instance_valid(enemy_ship) or not enemy_ship.is_alive():
			continue
		var last_time: float = unspotted_times.get(enemy_ship, now)
		var decay: float = 1.0 - clamp((now - last_time) / THREAT_STALE_DECAY_SECONDS, 0.0, 1.0)
		if decay <= 0.0:
			continue
		var lp: Vector3 = unspotted[enemy_ship]
		ids.append(int(enemy_ship.get_instance_id()))
		data.append(Vector3(lp.x, lp.z, decay))

	threat_registry.update_team(team_id, ids, data)


func _refresh_hydro_lkp(team_id: int, ship: Ship) -> void:
	"""Mark ship as in hydro range this frame and refresh its frozen LKP position
	when first contacted or every HYDRO_LKP_INTERVAL seconds thereafter."""
	var active    := team_0_hydro_in_range   if team_id == 0 else team_1_hydro_in_range
	var lkp       := team_0_hydro_lkp        if team_id == 0 else team_1_hydro_lkp
	var lkp_times := team_0_hydro_lkp_times  if team_id == 0 else team_1_hydro_lkp_times

	active[ship] = true  # Visible this frame

	if not lkp.has(ship) or current_time - lkp_times.get(ship, -INF) >= HYDRO_LKP_INTERVAL:
		lkp[ship]       = ship.global_position
		lkp_times[ship] = current_time
		# Keep bot-AI unspotted tables fresh on the same cadence
		var unspotted       := team_0_unspotted_enemies if team_id == 0 else team_1_unspotted_enemies
		var unspotted_times := team_0_unspotted_times   if team_id == 0 else team_1_unspotted_times
		unspotted[ship]       = ship.global_position
		unspotted_times[ship] = current_time


func _send_hydro_syncs() -> void:
	"""Send per-frame hydro pings and one-shot clear packets to human players.
	- Ships in hydro_in_range: send sync_unspotted(frozen_pos, true) every frame.
	- Ships in hydro_lkp but not in_range: send sync_unspotted(last_pos, false) once,
	  then erase from the LKP table."""
	for team_id in [0, 1]:
		var active    := team_0_hydro_in_range   if team_id == 0 else team_1_hydro_in_range
		var lkp       := team_0_hydro_lkp        if team_id == 0 else team_1_hydro_lkp
		var lkp_times := team_0_hydro_lkp_times  if team_id == 0 else team_1_hydro_lkp_times

		# Active pings — ship is currently in hydro range
		for ship in active.keys():
			if not is_instance_valid(ship):
				continue
			# If the ship is also LOS-visible, use its real position so the hydro
			# ping doesn't conflict with the normal LOS sync and cause flickering.
			var pos: Vector3 = ship.global_position if ship.visible_to_enemy else lkp.get(ship, ship.global_position)
			var ping_bytes: PackedByteArray = ship.sync_ship_lkp(pos, true, 1)
			for p_name in players:
				var p_entry = players[p_name]
				var p_ship: Ship = p_entry[0]
				if p_ship.team.team_id == team_id and not p_ship.team.is_bot:
					ship.sync_unspotted.rpc_id(p_entry[2], ping_bytes)

		# Clear packets — ship just left hydro range (present in lkp, absent from active)
		for ship in lkp.keys():
			if active.has(ship):
				continue
			if not is_instance_valid(ship) or ship.health_controller.is_dead():
				lkp.erase(ship)
				lkp_times.erase(ship)
				continue
			var pos: Vector3 = lkp[ship]
			var clear_bytes: PackedByteArray = ship.sync_ship_lkp(pos, false, 1)
			for p_name in players:
				var p_entry = players[p_name]
				var p_ship: Ship = p_entry[0]
				if p_ship.team.team_id == team_id and not p_ship.team.is_bot:
					ship.sync_unspotted.rpc_id(p_entry[2], clear_bytes)
			lkp.erase(ship)
			lkp_times.erase(ship)


func _refresh_radar_lkp(team_id: int, ship: Ship) -> void:
	"""Mark ship as in radar range this frame and refresh its frozen LKP position
	if first contact or HYDRO_LKP_INTERVAL seconds have elapsed."""
	var active   := team_0_radar_in_range   if team_id == 0 else team_1_radar_in_range
	var lkp      := team_0_radar_lkp        if team_id == 0 else team_1_radar_lkp
	var lkp_t    := team_0_radar_lkp_times  if team_id == 0 else team_1_radar_lkp_times

	active[ship] = true

	if not lkp.has(ship) or current_time - lkp_t.get(ship, -INF) >= HYDRO_LKP_INTERVAL:
		lkp[ship]  = ship.global_position
		lkp_t[ship] = current_time
		var unspotted := team_0_unspotted_enemies if team_id == 0 else team_1_unspotted_enemies
		var u_times   := team_0_unspotted_times   if team_id == 0 else team_1_unspotted_times
		unspotted[ship] = ship.global_position
		u_times[ship]   = current_time


func _check_pair_detection(a: Ship, b: Ship, ray_query: PhysicsRayQueryParameters3D, space_state: PhysicsDirectSpaceState3D) -> void:
	var params_a := a.concealment.params.p() as ConcealmentParams
	var params_b := b.concealment.params.p() as ConcealmentParams

	# Assured acquisition — unconditional spot within range, bypasses terrain and smoke.
	var assured_acq := maxf(params_a.assured_acquisition_range, params_b.assured_acquisition_range)
	var dist: float = a.global_position.distance_to(b.global_position)
	if assured_acq > 0.0 and dist < assured_acq:
		handle_spot(a, b, dist)
		handle_spot(b, a, dist)

	# LOS raycast — only if not already spotted by assured acquisition.
	if !a.visible_to_enemy or !b.visible_to_enemy:
		ray_query.from = a.global_position
		ray_query.to = b.global_position
		ray_query.from.y = 1.0
		ray_query.to.y = 1.0
		var collision: Dictionary = space_state.intersect_ray(ray_query)
		var has_los := collision.is_empty()
		var smoke_blocked := !collision.is_empty() and (collision["collider"] as CollisionObject3D).collision_layer & (1 << 5) != 0

		if has_los:
			handle_spot(a, b, dist)
			handle_spot(b, a, dist)

		_check_sensor_range(a, b, params_a.spotting_range_override, true, smoke_blocked)
		_check_sensor_range(b, a, params_b.spotting_range_override, true, smoke_blocked)
		_check_sensor_range(a, b, params_a.radar_spotting_range_override, false, smoke_blocked)
		_check_sensor_range(b, a, params_b.radar_spotting_range_override, false, smoke_blocked)


func _check_sensor_range(detector: Ship, target: Ship, range: float, is_hydro: bool, smoke_blocked: bool) -> void:
	if range <= 0.0:
		return
	var dist := detector.global_position.distance_to(target.global_position)
	if dist >= range:
		return

	if is_hydro:
		detector.det_hydro = true
	else:
		detector.det_radar = true

	if smoke_blocked:
		handle_spot(detector, target, dist)
		return

	if is_hydro:
		target.det_hydro = true
	else:
		target.det_radar = true

	if not target.visible_to_enemy:
		if is_hydro:
			_refresh_hydro_lkp(detector.team.team_id, target)
			_refresh_hydro_lkp(target.team.team_id, detector)
		else:
			_refresh_radar_lkp(detector.team.team_id, target)
			_refresh_radar_lkp(target.team.team_id, detector)


func _send_radar_syncs() -> void:
	"""Mirror of _send_hydro_syncs but uses source = 2 (Radar)."""
	for team_id in [0, 1]:
		var active := team_0_radar_in_range   if team_id == 0 else team_1_radar_in_range
		var lkp    := team_0_radar_lkp        if team_id == 0 else team_1_radar_lkp
		var lkp_t  := team_0_radar_lkp_times  if team_id == 0 else team_1_radar_lkp_times

		for ship in active.keys():
			if not is_instance_valid(ship):
				continue
			var pos: Vector3 = ship.global_position if ship.visible_to_enemy else lkp.get(ship, ship.global_position)
			var ping_bytes: PackedByteArray = ship.sync_ship_lkp(pos, true, 2)
			for p_name in players:
				var p_entry = players[p_name]
				var p_ship: Ship = p_entry[0]
				if p_ship.team.team_id == team_id and not p_ship.team.is_bot:
					ship.sync_unspotted.rpc_id(p_entry[2], ping_bytes)

		for ship in lkp.keys():
			if active.has(ship):
				continue
			if not is_instance_valid(ship) or ship.health_controller.is_dead():
				lkp.erase(ship)
				lkp_t.erase(ship)
				continue
			var pos: Vector3 = lkp[ship]
			var clear_bytes: PackedByteArray = ship.sync_ship_lkp(pos, false, 2)
			for p_name in players:
				var p_entry = players[p_name]
				var p_ship: Ship = p_entry[0]
				if p_ship.team.team_id == team_id and not p_ship.team.is_bot:
					ship.sync_unspotted.rpc_id(p_entry[2], clear_bytes)
			lkp.erase(ship)
			lkp_t.erase(ship)
