extends Node

var available_servers = []
var min_players = 2
var connecting_clients = {}
var available_ports = []  # List to track available ports
var port_range_start = 28970  # Starting port for game servers
var port_range_end = 29000    # Ending port for game servers

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
				connecting_clients[info] = packet_result['selected_ship']
			elif packet_result["request"] == "leave_queue":
				connecting_clients.erase(info)
			
				
			
			if connecting_clients.size() >= min_players:
				# Find an available port for the server
				var server_port = find_available_port()
				if server_port == -1:
					push_error("No available ports for game server!")
					continue
					
				# Start server with the selected port as an argument
				#var server = OS.create_process(OS.get_executable_path(), ["--server", "--port", str(server_port)])

				# Send team info to the server (as a file for simplicity)
				var team = {}
				for i in range(min_players):
					# var client = connecting_clients[i]
					var client = connecting_clients.keys()[i]
					# Get the ship type from the client
					var ship_type = connecting_clients[client]
					# Assign a team ID to each client
					var team_id = i % 2  # Simple round-robin assignment
					team[i] = {
						"team": str(team_id),
						"player_id": str(i),
						"ship": ship_type
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
					var client = connecting_clients.keys()[i]
					# Get the ship type from the client
					# var ship_type = connecting_clients[client]
					
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
					var client = connecting_clients.keys()[0]
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
