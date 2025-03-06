# src/client/client_ui_manager.gd
extends Control

@onready var connect_button = $VBoxContainer/ConnectButton
@onready var ip_input = $VBoxContainer/IPInput
@onready var name_input = $VBoxContainer/NameInput
@onready var status_label = $VBoxContainer/StatusLabel

func _ready():
	connect_button.pressed.connect(_on_connect_pressed)
	
	# Setup connection signals
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)

func _on_connect_pressed():
	# Update game settings
	GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.save_settings()
	
	status_label.text = "Connecting to matchmaker..."
	
	# Connect to matchmaker to get server allocation
	connect_to_matchmaker()

func connect_to_matchmaker():
	var udp = PacketPeerUDP.new()
	udp.connect_to_host(GameSettings.matchmaker_ip, 28961)
	
	# Send request for server
	udp.put_packet("request_server".to_utf8_buffer())
	
	# Create a timer for timeout
	var timeout = 5.0  # 5 second timeout
	var timer = get_tree().create_timer(timeout)
	
	# Wait for response or timeout
	while udp.get_available_packet_count() == 0:
		await get_tree().process_frame
		if timer.time_left <= 0:
			status_label.text = "Connection to matchmaker timed out."
			return
	
	# Process server info
	var server_info = bytes_to_var(udp.get_packet())
	status_label.text = "Server allocated. Connecting to game server..."
	
	# Connect to the assigned server
	NetworkManager.create_client(server_info.ip, server_info.port)

func _on_connection_succeeded():
	status_label.text = "Connected to server!"
	# Change to game scene
	#get_tree().change_scene_to_file("res://scenes/lobby.tscn")
	get_tree().change_scene_to_file("res://scenes/server.tscn")

func _on_connection_failed():
	status_label.text = "Failed to connect to server."

func _on_server_disconnected():
	status_label.text = "Disconnected from server."
	# Return to main menu
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
