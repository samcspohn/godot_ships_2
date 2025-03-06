# src/autoload/network_manager.gd
extends Node

enum ConnectionType {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
	SERVER,
	MATCHMAKER
}

var current_connection_type = ConnectionType.DISCONNECTED
var network_peer: ENetMultiplayerPeer = null

signal connection_failed
signal connection_succeeded
signal server_disconnected

func _ready():
	# Setup signal connections for the multiplayer system
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func create_client(address: String, port: int):
	print("Attempting to connect to: ", address, ":", port)
	network_peer = ENetMultiplayerPeer.new()
	var error = network_peer.create_client(address, port)
	
	if error != OK:
		print("Failed to create client: ", error)
		emit_signal("connection_failed")
		return
	
	multiplayer.multiplayer_peer = network_peer
	current_connection_type = ConnectionType.CONNECTING
	print("Client created, connecting...")

func create_server(port: int, max_players: int):
	network_peer = ENetMultiplayerPeer.new()
	var error = network_peer.create_server(port, max_players)
	
	if error != OK:
		print("Failed to create server: ", error)
		return
	
	multiplayer.multiplayer_peer = network_peer
	current_connection_type = ConnectionType.SERVER
	print("Server created on port: ", port)

func disconnect_network():
	if network_peer:
		network_peer.close()
	current_connection_type = ConnectionType.DISCONNECTED
	print("Network disconnected")

# Signal handlers
func _on_connected_to_server():
	print("Successfully connected to server")
	current_connection_type = ConnectionType.CONNECTED
	emit_signal("connection_succeeded")

func _on_connection_failed():
	print("Connection failed")
	current_connection_type = ConnectionType.DISCONNECTED
	emit_signal("connection_failed")

func _on_server_disconnected():
	print("Server disconnected")
	current_connection_type = ConnectionType.DISCONNECTED
	emit_signal("server_disconnected")

# Adding the request_spawn RPC function
@rpc("any_peer", "call_remote")
func request_spawn(id, player_name):
	if multiplayer.is_server():
		# Get the game server node - adjust path as needed
		var server: GameServer = get_tree().root.get_node_or_null("Server")
		if server:
			server.spawn_player(id, player_name)
		else:
			print(ConnectionType.keys()[current_connection_type])
			print("ERROR: GameServer node not found")
