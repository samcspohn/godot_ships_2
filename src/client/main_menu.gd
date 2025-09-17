extends Control

@onready var connect_button: Button = $VBoxContainer/ConnectButton
@onready var single_player_button: Button = $VBoxContainer/SinglePlayerButton
@onready var ip_input: LineEdit = $VBoxContainer/IPInput
@onready var name_input: LineEdit = $VBoxContainer/NameInput
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var dock = $Dock
@onready var ship_button_container = $ScrollContainer/HBoxContainer

var udp: PacketPeerUDP = null
var selected_ship
var ship_scenes = []
var waiting: bool = false
var pulse_time: float = 0.0
var original_modulate: Color = Color(1,1,1,1)

func _ready():
	connect_button.pressed.connect(_on_connect_pressed)
	single_player_button.pressed.connect(_on_single_player_pressed)
	_load_ship_buttons()
	original_modulate = connect_button.modulate

	# Hook up network signals similar to the old lobby
	if Engine.has_singleton("NetworkManager"):
		NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
		NetworkManager.connection_failed.connect(_on_connection_failed)
		NetworkManager.server_disconnected.connect(_on_server_disconnected)

func _load_ship_buttons():
	_scan_directory("res://scenes/Ships/")

	var button = Button.new()
	button.text = "Bismarck"
	button.pressed.connect(_on_ship_button_pressed.bind("res://ShipModels/Bismarck2.tscn"))
	ship_button_container.add_child(button)

	button = Button.new()
	button.text = "Bismarck2"
	button.pressed.connect(_on_ship_button_pressed.bind("res://ShipModels/Bismarck3.tscn"))
	ship_button_container.add_child(button)

func _scan_directory(path: String):
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir() and file_name != "." and file_name != "..":
				#_scan_directory(path + file_name + "/")
			#elif file_name.ends_with(".tscn"):
				var ship_path = path + file_name + "/" + "ship.tscn"
				ship_scenes.append(ship_path)
				var button = Button.new()
				button.text = file_name.get_basename()
				button.pressed.connect(_on_ship_button_pressed.bind(ship_path))
				ship_button_container.add_child(button)
			file_name = dir.get_next()
		dir.list_dir_end()

func _on_ship_button_pressed(ship_path):
	if selected_ship != null:
		selected_ship.queue_free()
	selected_ship = load(ship_path).instantiate()
	GameSettings.selected_ship = ship_path
	dock.add_child(selected_ship)
	selected_ship.position = Vector3(0,6,0)

func _on_connect_pressed():
	# Toggle queueing with matchmaker
	if GameSettings.selected_ship == "":
		return

	if waiting:
		# Leave queue
		if udp:
			var leave_packet = {
				"request": "leave_queue",
				"player_name": GameSettings.player_name,
			}
			udp.put_packet(JSON.stringify(leave_packet).to_utf8_buffer())
			udp = null
		_stop_waiting()
		status_label.text = "Left queue."
		return

	# Start waiting for a match
	GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.is_single_player = false
	GameSettings.save_settings()

	udp = PacketPeerUDP.new()
	udp.connect_to_host(GameSettings.matchmaker_ip, 28961)

	var packet = {
		"request": "request_server",
		"player_name": GameSettings.player_name,
		"selected_ship": GameSettings.selected_ship,
		"single_player": GameSettings.is_single_player
	}
	udp.put_packet(JSON.stringify(packet).to_utf8_buffer())

	status_label.text = "Connecting to matchmaker..."
	waiting = true
	single_player_button.disabled = true
	connect_button.text = "waiting..."
	connect_button.modulate = Color(1,0.5,0,1) # orange
	pulse_time = 0.0

func _on_single_player_pressed():
	if GameSettings.selected_ship == "":
		return
	if waiting:
		return # disabled while waiting; extra guard

	# Update game settings for single player and start server scene directly
	GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.is_single_player = true
	GameSettings.save_settings()

	status_label.text = "Starting single player game..."
	get_tree().change_scene_to_file("res://src/server/server.tscn")

func _process(delta: float) -> void:
	# Handle pulsing effect when waiting
	if waiting:
		pulse_time += delta
		var pulse = (sin(pulse_time * 4.0) + 1.0) * 0.5 # 0..1
		var orange = Color(1.0, 0.5, 0.0)
		connect_button.modulate = orange.lerp(original_modulate, 1.0 - pulse)

	# Poll UDP for matchmaker response
	if not udp:
		return

	if udp.get_available_packet_count() != 0:
		var server_info = bytes_to_var(udp.get_packet())
		if server_info:
			print(server_info)
			status_label.text = "Server allocated. Connecting to game server..."
			GameSettings.player_name = server_info.player_id
			# Connect to the assigned server
			NetworkManager.create_client(server_info.ip, server_info.port)
			GameSettings.is_single_player = false
			GameSettings.save_settings()
		else:
			status_label.text = "Failed to connect to server."
		udp = null
		_stop_waiting()

func _on_connection_succeeded():
	status_label.text = "Connected to server!"
	# Reset single player flag after successful connection
	GameSettings.is_single_player = false
	GameSettings.save_settings()
	
	# Store player info for potential reconnection using player name as identifier
	NetworkManager.store_player_info(GameSettings.player_name, GameSettings.selected_ship)
	
	get_tree().change_scene_to_file("res://src/server/server.tscn")

func _on_connection_failed():
	status_label.text = "Failed to connect to server."

func _on_server_disconnected():
	status_label.text = "Disconnected from server. Attempting to reconnect..."
	
	# If we've previously connected, the NetworkManager should attempt to reconnect automatically
	# otherwise return to main menu
	if !NetworkManager.reconnect_info.was_connected:
		get_tree().change_scene_to_file("res://src/client/main_menu.tscn")

func _stop_waiting():
	waiting = false
	single_player_button.disabled = false
	connect_button.text = "Connect"
	connect_button.modulate = original_modulate
