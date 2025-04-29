extends Control

@onready var leave: Button = $VBoxContainer/LeaveQueue
@onready var status_label: Label = $VBoxContainer/StatusLabel
var udp

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	
	leave.pressed.connect(_on_leave_queue)
	# Setup connection signals
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)

	udp = PacketPeerUDP.new()
	udp.connect_to_host(GameSettings.matchmaker_ip, 28961)
	
	# Send request for server
	var packet = {
		"request": "request_server",
		"player_name": GameSettings.player_name,
	}
	var err = udp.put_packet(JSON.stringify(packet).to_utf8_buffer())

	
	status_label.text = "Connecting to matchmaker..."
	#pass # Replace with function body.


func _on_leave_queue():
	if udp:
		var packet = {
			"leave": "leave_queue",
			"player_name": GameSettings.player_name,
		}
		udp.put_packet(JSON.stringify(packet).to_utf8_buffer())
		udp = null
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_connection_succeeded():
	status_label.text = "Connected to server!"
	get_tree().change_scene_to_file("res://scenes/server.tscn")

func _on_connection_failed():
	status_label.text = "Failed to connect to server."

func _on_server_disconnected():
	status_label.text = "Disconnected from server."
	# Return to main menu
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if not udp:
		return
	
	if udp.get_available_packet_count() != 0:
		# Process server info
		var server_info = bytes_to_var(udp.get_packet())
		if server_info:
			print(server_info)
			status_label.text = "Server allocated. Connecting to game server..."
			GameSettings.player_name = server_info.player_id
			
			# Connect to the assigned server
			NetworkManager.create_client(server_info.ip, server_info.port)
		else:
			status_label.text = "Failed to connect to server."
		udp = null
		
