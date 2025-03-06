# src/matchmaker/matchmaker.gd
extends Node

var available_servers = []
var min_players = 4
var connecting_clients = []


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
			var info = {"ip": sender_ip,"port": sender_port, "server": server_info}
			connecting_clients.append(info)
			
			if connecting_clients.size() >= min_players:
				for i in range(min_players):
					var client = connecting_clients[i]
					# Reply with server connection details
					udp.set_dest_address(client["ip"], client["port"])
					udp.put_packet(var_to_bytes(client["server"]))
				for i in range(min_players):
					connecting_clients.pop_front()
				
			

func find_best_game_server():
	return {
		"ip": "127.0.0.1",
		"port": GameSettings.DEFAULT_PORT,
		"max_players": GameSettings.MAX_PLAYERS
	}
