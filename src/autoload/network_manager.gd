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
var player_controller_connected = false
var _address = ""
var _port = 0

signal connection_failed
signal connection_succeeded
signal server_disconnected

func _ready():
	# Setup signal connections for the multiplayer system
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func create_client(address: String, port: int) -> bool:
	print("Attempting to connect to: ", address, ":", port)
	network_peer = ENetMultiplayerPeer.new()
	_address = address
	_port = port
	var error = network_peer.create_client(_address, _port)
	
	if error != OK:
		print("Failed to create client: ", error)
		emit_signal("connection_failed")
		return false
	
	multiplayer.multiplayer_peer = network_peer
	current_connection_type = ConnectionType.CONNECTING
	print("Client created, connecting...")
	return true

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
	print("Successfully player_controller_connected to server")
	current_connection_type = ConnectionType.CONNECTED
	connection_succeeded.emit()

func _on_connection_failed():
	print("Connection failed")
	current_connection_type = ConnectionType.DISCONNECTED
	connection_failed.emit()
	_attempt_reconnect()

func _on_server_disconnected():
	print("Server disconnected")
	current_connection_type = ConnectionType.DISCONNECTED
	server_disconnected.emit()
	player_controller_connected = false
	_attempt_reconnect()

func _attempt_reconnect():
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	while server and not NetworkManager.create_client(_address, _port):
		print("Attempting to reconnect...")
		await get_tree().create_timer(2.0).timeout
	# Start polling for reconnection
	_poll_reconnect()

func _poll_reconnect():
	# This can be expanded to include a timeout or max attempts
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	while current_connection_type != ConnectionType.CONNECTED:
		await get_tree().create_timer(2.0).timeout
	while server and not player_controller_connected:
		server.reconnect.rpc_id(1, multiplayer.get_unique_id(), GameSettings.player_name)
		await get_tree().create_timer(2.0).timeout

# func validate_reconnection():
# 	# Implement validation logic if needed
# 	pass

# Adding the request_spawn RPC function
@rpc("any_peer", "call_remote", "reliable")
func request_spawn(id, player_name):
	if multiplayer.is_server():
		# Get the game server node - adjust path as needed
		var server: GameServer = get_tree().root.get_node_or_null("Server")
		if server:
			server.spawn_player(id, player_name)
		else:
			print(ConnectionType.keys()[current_connection_type])
			print("ERROR: GameServer node not found")
