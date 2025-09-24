# src/client/main_menu_ui.gd
extends Control

# Get reference to global UpgradeManager
@onready var upgrade_manager = get_node("/root/UpgradeManager")

@onready var connect_button: Button = $VBoxContainer/ConnectButton
@onready var single_player_button: Button = $VBoxContainer/SinglePlayerButton
@onready var ip_input: LineEdit = $VBoxContainer/IPInput
@onready var name_input: LineEdit = $VBoxContainer/NameInput
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var ship_button_container = $ScrollContainer/HBoxContainer
@onready var ship_upgrade_ui = $ShipUpgradeUI
var dock_node  # Will be set by the main scene
var udp: PacketPeerUDP = null
var lobby
var selected_ship
var ship_scenes = []
var waiting: bool = false
var pulse_time: float = 0.0
var original_modulate: Color
# Ship upgrades are now managed by the ship.upgrades module

func _ready():
	connect_button.pressed.connect(_on_connect_pressed)
	single_player_button.pressed.connect(_on_single_player_pressed)
	_load_ship_buttons()
	original_modulate = connect_button.modulate

	# Hook up network signals similar to the old lobby
	# if Engine.has_singleton("NetworkManager"):
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	# NetworkManager.server_disconnected.connect(_on_server_disconnected)
	
	# Initialize the upgrade UI
	ship_upgrade_ui.upgrade_selected.connect(_on_upgrade_selected)
	ship_upgrade_ui.upgrade_removed.connect(_on_upgrade_removed)
	
	# Load saved upgrades from GameSettings
	# for slot_str in GameSettings.ship_config:
	# 	var slot_index = slot_str.to_int()
	# 	var upgrade_path = GameSettings.ship_config[slot_str]
	# 	selected_upgrades[slot_index] = upgrade_path

	name_input.text = GameSettings.player_name
	if GameSettings.selected_ship != "":
		call_deferred("_on_ship_button_pressed", GameSettings.selected_ship)


func set_dock_node(dock: Node3D):
	dock_node = dock

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
	if dock_node:
		dock_node.add_child(selected_ship)
		selected_ship.position = Vector3(0,6,0)
	
	# Update the upgrade UI with the selected ship
	if selected_ship is Ship:
		ship_upgrade_ui.set_ship(selected_ship)
		
		# Apply any previously selected upgrades for this specific ship
		if GameSettings.ship_config.has(ship_path):
			for slot_str in GameSettings.ship_config[ship_path]:
				var slot_index = slot_str.to_int()
				var upgrade_path = GameSettings.ship_config[ship_path][slot_str]
				_apply_upgrade_to_ship(selected_ship, slot_index, upgrade_path)

func submit_to_matchmaker():
	if not udp:
		udp = PacketPeerUDP.new()
	udp.connect_to_host(GameSettings.matchmaker_ip, 28961)

	var packet = {
		"request": "request_server",
		"player_name": GameSettings.player_name,
		"selected_ship": GameSettings.selected_ship,
		"single_player": GameSettings.is_single_player
	}
	udp.put_packet(JSON.stringify(packet).to_utf8_buffer())

func _on_connect_pressed():
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

	# Start waiting
	name_input.text = GameSettings.player_name
	# GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.is_single_player = false
	GameSettings.save_settings()

	# udp = PacketPeerUDP.new()
	# udp.connect_to_host(GameSettings.matchmaker_ip, 28961)

	# var packet = {
	# 	"request": "request_server",
	# 	"player_name": GameSettings.player_name,
	# 	"selected_ship": GameSettings.selected_ship,
	# 	"single_player": GameSettings.is_single_player
	# }
	# udp.put_packet(JSON.stringify(packet).to_utf8_buffer())
	submit_to_matchmaker()

	status_label.text = "Connecting to matchmaker..."
	waiting = true
	single_player_button.disabled = true
	connect_button.text = "waiting..."
	connect_button.modulate = Color(1,0.5,0,1)
	pulse_time = 0.0

func _on_single_player_pressed():
	if GameSettings.selected_ship == "":
		return
	if waiting:
		return
	# Update game settings for single player
	# GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.is_single_player = true
	GameSettings.save_settings()
	
	status_label.text = "Starting single player game..."
	submit_to_matchmaker()
	#get_tree().change_scene_to_file("res://src/server/server.tscn")

func _process(delta: float) -> void:
	if waiting:
		pulse_time += delta
		var pulse = (sin(pulse_time * 4.0) + 1.0) * 0.5
		var orange = Color(1.0, 0.5, 0.0)
		connect_button.modulate = orange.lerp(original_modulate, 1.0 - pulse)

	if not udp:
		return

	if udp.get_available_packet_count() != 0:
		var server_info = bytes_to_var(udp.get_packet())
		if server_info:
			print(server_info)
			status_label.text = "Server allocated. Connecting to game server..."
			# GameSettings.player_name = server_info.player_id
			NetworkManager.create_client(server_info.ip, server_info.port)
			GameSettings.is_single_player = false
			GameSettings.save_settings()
		else:
			status_label.text = "Failed to connect to server."
		udp = null
		_stop_waiting()

func _on_connection_succeeded():
	status_label.text = "Connected to server!"
	#GameSettings.is_single_player = false
	GameSettings.save_settings()
	get_tree().call_deferred("change_scene_to_file", "res://src/server/server.tscn")

func _on_connection_failed():
	status_label.text = "Failed to connect to server."


func _stop_waiting():
	waiting = false
	single_player_button.disabled = false
	connect_button.text = "Connect"
	connect_button.modulate = original_modulate
	
func _on_upgrade_selected(slot_index: int, upgrade_path: String):
	# Check if this is the first upgrade for this ship
	if not GameSettings.ship_config.has(GameSettings.selected_ship):
		GameSettings.ship_config[GameSettings.selected_ship] = {}
	
	# Save upgrade to game settings under the current ship
	GameSettings.ship_config[GameSettings.selected_ship][str(slot_index)] = upgrade_path
	GameSettings.save_settings()
	
	print("Upgrade selected: ", upgrade_path, " for slot ", slot_index)
	
	# Note: The UI now directly applies the upgrade to the ship via UpgradeManager
	# so we don't need to apply it here

func _on_upgrade_removed(slot_index: int):
	# Check if this ship has any upgrades saved
	if GameSettings.ship_config.has(GameSettings.selected_ship):
		# Check if the slot exists in this ship's config
		if GameSettings.ship_config[GameSettings.selected_ship].has(str(slot_index)):
			print("Upgrade removed from slot ", slot_index)
			
			# Remove the upgrade from this slot
			GameSettings.ship_config[GameSettings.selected_ship].erase(str(slot_index))
			GameSettings.save_settings()
	
	# Note: The UI now directly removes the upgrade from the ship via UpgradeManager
	# so we don't need to remove it here

func _apply_upgrade_to_ship(ship: Ship, slot_index: int, upgrade_path: String):
	# Use the UpgradeManager to apply the upgrade
	if upgrade_path.is_empty():
		return
		
	var success = upgrade_manager.apply_upgrade_to_ship(ship, slot_index, upgrade_path)
	if success:
		print("Applied upgrade to ship: ", upgrade_path)
	else:
		print("Failed to apply upgrade: ", upgrade_path)
	
	ship_upgrade_ui._update_slot_buttons()

func _remove_upgrade_from_ship(ship: Ship, _slot_index: int, upgrade_path: String):
	# Use the UpgradeManager to remove the upgrade
	if upgrade_path.is_empty():
		return
		
	var success = upgrade_manager.remove_upgrade_from_ship(ship, upgrade_path)
	if success:
		print("Removed upgrade from ship: ", upgrade_path)
	else:
		print("Failed to remove upgrade: ", upgrade_path)
	ship_upgrade_ui._update_slot_buttons()
