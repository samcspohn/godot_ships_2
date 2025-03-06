# src/matchmaker/matchmaker.gd
extends Node

var available_servers = []

func _ready():
	# Setup UDP beacon for server discovery
	var udp = PacketPeerUDP.new()
	udp.bind(28961)  # Matchmaker port
	
	while true:
		if udp.get_available_packet_count() > 0:
			var packet = udp.get_packet()
			var sender_ip = udp.get_packet_ip()
			var sender_port = udp.get_packet_port()
			
			# Simple matchmaking logic
			var server_info = find_best_game_server()
			
			# Reply with server connection details
			udp.set_dest_address(sender_ip, sender_port)
			udp.put_packet(var_to_bytes(server_info))

func find_best_game_server():
	return {
		"ip": "127.0.0.1",
		"port": GameSettings.DEFAULT_PORT,
		"max_players": GameSettings.MAX_PLAYERS
	}
