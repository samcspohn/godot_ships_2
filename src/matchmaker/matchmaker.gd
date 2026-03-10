extends Node

var available_servers = []
var min_players = 2
var connecting_clients = {}
var available_ports = []  # List to track available ports
var port_range_start = 28970  # Starting port for game servers
var port_range_end = 29000    # Ending port for game servers

# Ship class constants matching Ship.ShipClass enum
const SHIP_CLASS_BB = 0  # Battleship
const SHIP_CLASS_CA = 1  # Cruiser
const SHIP_CLASS_DD = 2  # Destroyer

# Ship data: path -> {class, tier}
const SHIP_DATA = {
	"res://Ships/Bismarck/Bismarck3.tscn": {"class": SHIP_CLASS_BB, "tier": 8},
	"res://Ships/H44/H44.tscn": {"class": SHIP_CLASS_BB, "tier": 11},
	"res://Ships/DesMoines/DesMoines.tscn": {"class": SHIP_CLASS_CA, "tier": 10},
	"res://Ships/Shimakaze/Shimakaze.tscn": {"class": SHIP_CLASS_DD, "tier": 10}
}

# Available ships by class for bot team generation
const SHIPS_BY_CLASS = {
	SHIP_CLASS_BB: [
		# "res://Ships/Bismarck/Bismarck3.tscn",
		"res://Ships/H44/H44.tscn"
	],
	SHIP_CLASS_CA: [
		"res://Ships/DesMoines/DesMoines.tscn"
	],
	SHIP_CLASS_DD: [
		"res://Ships/Shimakaze/Shimakaze.tscn"
	]
}

func _ready():
	# Initialize available ports
	initialize_available_ports()

	# Setup UDP beacon for server discovery
	var udp = PacketPeerUDP.new()
	udp.bind(28961)  # Matchmaker port

	while true:
		if udp.get_available_packet_count() > 0:
			var packet = udp.get_packet()
			var sender_ip = udp.get_packet_ip()
			var sender_port = udp.get_packet_port()

			var info = {"ip": sender_ip, "port": sender_port}
			var packet_str = packet.get_string_from_utf8()
			var json = JSON.new()
			var err = json.parse(packet_str)
			if err != OK:
				push_error("Failed to parse packet data")
				continue
			var packet_result = json.data
			if packet_result["request"] == "request_server":
				# Track this connecting client
				var client_data = {
					"ship": packet_result['selected_ship'],
					"single_player": packet_result.get('single_player', false),
					"player_name": packet_result.get('player_name', 'Player')
				}
				connecting_clients[info] = client_data
			elif packet_result["request"] == "leave_queue":
				connecting_clients.erase(info)

			# Check if we have a single player request
			var single_player_client = null
			for client in connecting_clients:
				if connecting_clients[client]["single_player"]:
					single_player_client = client
					break

			# Handle single player mode
			if single_player_client != null:
				# Find an available port for the server
				var server_port = find_available_port()
				if server_port == -1:
					push_error("No available ports for game server!")
					continue

				# Create team info for single player vs 4 bots
				var team = {}
				var client_data = connecting_clients[single_player_client]

				team = create_balanced_single_player_teams(client_data["player_name"], client_data["ship"])

				var team_info = {
					"team": team
				}

				print("Single player team info created: ", team_info)

				# Save team info
				var team_file_path = "user://team_info.json"
				var file = FileAccess.open(team_file_path, FileAccess.WRITE)
				file.store_string(JSON.stringify(team_info))
				file.close()

				# Mark this port as in use
				mark_port_as_used(server_port)

				# Send server info to the single player
				var server_info = {
					"ip": "127.0.0.1",
					"port": server_port,
					"player_id": "0",
					"max_players": GameSettings.MAX_PLAYERS
				}

				udp.set_dest_address(single_player_client["ip"], single_player_client["port"])
				udp.put_packet(var_to_bytes(server_info))

				# Remove the single player client from queue
				connecting_clients.erase(single_player_client)
				continue

			# Check if we have enough multiplayer clients to start a game
			if connecting_clients.size() >= min_players:
				# Check if all clients are multiplayer (not single player)
				var multiplayer_clients = []
				for client in connecting_clients:
					if not connecting_clients[client]["single_player"]:
						multiplayer_clients.append(client)

				if multiplayer_clients.size() < min_players:
					continue  # Not enough multiplayer clients yet

				# Find an available port for the server
				var server_port = find_available_port()
				if server_port == -1:
					push_error("No available ports for game server!")
					continue

				# Send team info to the server (as a file for simplicity)
				var team = {}
				for i in range(min_players):
					var client = multiplayer_clients[i]
					# Get the ship type from the client
					var ship_type = connecting_clients[client]["ship"]
					var player_name = connecting_clients[client]["player_name"]
					# Assign a team ID to each client
					var team_id = i % 2  # Simple round-robin assignment
					team[player_name] = {
						"team": str(team_id),
						"player_id": player_name,
						"ship": ship_type,
						"is_bot": false
					}
				var team_info = {
					"team": team
				}
				var team_file_path = "user://team_info.json"
				var file = FileAccess.open(team_file_path, FileAccess.WRITE)
				file.store_string(JSON.stringify(team_info))
				file.close()


				# Mark this port as in use
				mark_port_as_used(server_port)

				# Notify all connecting clients
				for i in range(min_players):
					var client = multiplayer_clients[i]

					# Get server info with the newly assigned port
					var server_info = {
						"ip": "127.0.0.1",
						"port": server_port,
						"player_id": str(i),
						"max_players": GameSettings.MAX_PLAYERS
					}

					# Reply with server connection details
					udp.set_dest_address(client["ip"], client["port"])
					udp.put_packet(var_to_bytes(server_info))

				# Remove the clients that have been assigned to a server
				for i in range(min_players):
					var client = multiplayer_clients[i]
					connecting_clients.erase(client)

# Initialize the list of available ports
func initialize_available_ports():
	for port in range(port_range_start, port_range_end + 1):
		available_ports.append(port)

# Find an available port for a new game server
func find_available_port():
	if available_ports.size() > 0:
		return available_ports[0]  # Return the first available port
	return -1  # No ports available

# Mark a port as being in use (remove from available ports)
func mark_port_as_used(port):
	available_ports.erase(port)

# Release a port when a server shuts down (could be called from a signal)
func release_port(port):
	if port >= port_range_start and port <= port_range_end and not port in available_ports:
		available_ports.append(port)
		# Sort to keep order
		available_ports.sort()

func find_best_game_server():
	# This function is now only used as a fallback
	var port = find_available_port()
	if port == -1:
		port = GameSettings.DEFAULT_PORT

	return {
		"ip": "127.0.0.1",
		"port": port,
		"max_players": GameSettings.MAX_PLAYERS
	}

# Create balanced teams for single player mode
# Each team will have 3-4 destroyers, 3-4 cruisers, and 3-4 battleships (10 total)
# The player's ship class is accounted for to ensure balance
# Both teams will have identical ship compositions (mirrored) for tier balance
# Spawn positions: Ships are grouped into 3 clusters (left flank, center, right flank)
# Each cluster contains one of each class (DD, CA, BB), with the bonus class adding a 4th to one cluster
# Cluster order is shuffled so the player can end up on either flank or in the middle
func create_balanced_single_player_teams(player_name: String, player_ship: String) -> Dictionary:
	var team = {}

	# Determine player's ship class
	var player_ship_data = SHIP_DATA.get(player_ship, {"class": SHIP_CLASS_CA, "tier": 10})
	var player_ship_class = player_ship_data["class"]

	# Define team composition: 10 ships per team
	# Randomly choose which class gets 4 ships (others get 3)
	const num_ships_per_team = 7
	var class_counts = {
		SHIP_CLASS_BB: floor(num_ships_per_team / 3.0),
		SHIP_CLASS_CA: floor(num_ships_per_team / 3.0),
		SHIP_CLASS_DD: floor(num_ships_per_team / 3.0)
	}
	var left_over = num_ships_per_team - (class_counts[SHIP_CLASS_BB] + class_counts[SHIP_CLASS_CA] + class_counts[SHIP_CLASS_DD])
	var classes = [SHIP_CLASS_BB, SHIP_CLASS_CA, SHIP_CLASS_DD]
	# var bonus_class = classes[randi() % classes.size()]
	var bonus_class = SHIP_CLASS_BB
	# for i in range(left_over):
	# 	var bonus_class = classes[i % classes.size()]
	# 	class_counts[bonus_class] += 1
	# var bonus_class = SHIP_CLASS_BB
	class_counts[bonus_class] += 1

	# Build the ship list for each class
	# This ensures both teams have identical tier compositions
	var ships_by_class_list = {
		SHIP_CLASS_BB: [],
		SHIP_CLASS_CA: [],
		SHIP_CLASS_DD: []
	}

	for ship_class in [SHIP_CLASS_BB, SHIP_CLASS_CA, SHIP_CLASS_DD]:
		var ships_available = SHIPS_BY_CLASS[ship_class]
		var count = class_counts[ship_class]

		# If this is the player's class, ensure player's exact ship is included first
		if ship_class == player_ship_class:
			ships_by_class_list[ship_class].append(player_ship)
			var remaining = count - 1
			var ship_index = 0
			while remaining > 0:
				var ship_path = ships_available[ship_index % ships_available.size()]
				ships_by_class_list[ship_class].append(ship_path)
				ship_index += 1
				remaining -= 1
		else:
			for i in range(count):
				var ship_path = ships_available[i % ships_available.size()]
				ships_by_class_list[ship_class].append(ship_path)

	# Build 3 clusters, each with one ship per class
	# A cluster is an array of {"class": ship_class, "ship": ship_path, "is_player": bool}
	var clusters = [[], [], []]

	# Track consumption index per class
	var class_consume_index = {
		SHIP_CLASS_BB: 0,
		SHIP_CLASS_CA: 0,
		SHIP_CLASS_DD: 0
	}

	# Fill base clusters: one DD, one CA, one BB each
	for cluster_idx in range(3):
		for ship_class in [SHIP_CLASS_DD, SHIP_CLASS_CA, SHIP_CLASS_BB]:
			var idx = class_consume_index[ship_class]
			if idx < ships_by_class_list[ship_class].size():
				var ship_path = ships_by_class_list[ship_class][idx]
				var is_player = (ship_path == player_ship and idx == 0 and ship_class == player_ship_class)
				clusters[cluster_idx].append({
					"class": ship_class,
					"ship": ship_path,
					"is_player": is_player
				})
				class_consume_index[ship_class] = idx + 1

	# Add the bonus (4th) ship from the bonus class to a random cluster
	var bonus_idx = class_consume_index[bonus_class]
	if bonus_idx < ships_by_class_list[bonus_class].size():
		var ship_path = ships_by_class_list[bonus_class][bonus_idx]
		var is_player = (ship_path == player_ship and bonus_idx == 0 and bonus_class == player_ship_class)
		var bonus_cluster = randi() % 3
		clusters[bonus_cluster].append({
			"class": bonus_class,
			"ship": ship_path,
			"is_player": is_player
		})

	# Shuffle order within each cluster (so DD/CA/BB positions vary within the group)
	for cluster in clusters:
		cluster.shuffle()

	# Shuffle the order of the 3 clusters (left flank, center, right flank)
	clusters.shuffle()

	# Flatten clusters into a single ordered spawn list
	var spawn_list = []  # Array of {"class", "ship", "is_player"} in spawn position order
	for cluster in clusters:
		for entry in cluster:
			spawn_list.append(entry)

	print("=== Spawn Order (positions 0-%d) ===" % (spawn_list.size() - 1))
	for i in range(spawn_list.size()):
		var class_label = ["BB", "CA", "DD"][spawn_list[i]["class"]]
		var player_marker = " [PLAYER]" if spawn_list[i]["is_player"] else ""
		print("  Position %d: %s (%s)%s" % [i, class_label, spawn_list[i]["ship"].get_file(), player_marker])

	# Randomize which team the player is on
	# var player_team_id = randi() % 2
	var player_team_id = 0  # For testing, put player on team 0
	var enemy_team_id = 1 - player_team_id
	print("Player assigned to team %d" % player_team_id)

	var bot_id_counter = 1001

	# Fill player's team using the spawn list
	for spawn_pos in range(spawn_list.size()):
		var entry = spawn_list[spawn_pos]
		if entry["is_player"]:
			team[player_name] = {
				"team": str(player_team_id),
				"player_id": player_name,
				"ship": entry["ship"],
				"is_bot": false,
				"spawn_position": spawn_pos
			}
		else:
			var bot_id = str(bot_id_counter)
			bot_id_counter += 1
			team[bot_id] = {
				"team": str(player_team_id),
				"player_id": bot_id,
				"ship": entry["ship"],
				"is_bot": true,
				"spawn_position": spawn_pos
			}

	# Fill enemy team - same spawn list for mirrored tier balance
	for spawn_pos in range(spawn_list.size()):
		var entry = spawn_list[spawn_pos]
		var bot_id = str(bot_id_counter)
		bot_id_counter += 1
		team[bot_id] = {
			"team": str(enemy_team_id),
			"player_id": bot_id,
			"ship": entry["ship"],
			"is_bot": true,
			"spawn_position": spawn_pos
		}

	# Log team composition for debugging
	_log_team_composition(team)

	return team

func _log_team_composition(team: Dictionary) -> void:
	var team0_tiers = []
	var team1_tiers = []
	var team0_classes = {SHIP_CLASS_BB: 0, SHIP_CLASS_CA: 0, SHIP_CLASS_DD: 0}
	var team1_classes = {SHIP_CLASS_BB: 0, SHIP_CLASS_CA: 0, SHIP_CLASS_DD: 0}

	for key in team:
		var ship_path = team[key]["ship"]
		var ship_data = SHIP_DATA.get(ship_path, {"tier": 10, "class": SHIP_CLASS_CA})
		var tier = ship_data["tier"]
		var ship_class = ship_data["class"]

		if team[key]["team"] == "0":
			team0_tiers.append(tier)
			team0_classes[ship_class] += 1
		else:
			team1_tiers.append(tier)
			team1_classes[ship_class] += 1

	print("=== Team Composition ===")
	print("Team 0: %d ships (BB:%d CA:%d DD:%d) - Tiers: %s (avg: %.1f)" % [
		team0_tiers.size(),
		team0_classes[SHIP_CLASS_BB],
		team0_classes[SHIP_CLASS_CA],
		team0_classes[SHIP_CLASS_DD],
		str(team0_tiers),
		_array_average(team0_tiers)
	])
	print("Team 1: %d ships (BB:%d CA:%d DD:%d) - Tiers: %s (avg: %.1f)" % [
		team1_tiers.size(),
		team1_classes[SHIP_CLASS_BB],
		team1_classes[SHIP_CLASS_CA],
		team1_classes[SHIP_CLASS_DD],
		str(team1_tiers),
		_array_average(team1_tiers)
	])
	print("========================")

func _array_average(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var total = 0.0
	for val in arr:
		total += val
	return total / arr.size()
