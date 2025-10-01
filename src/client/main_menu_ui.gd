# src/client/main_menu_ui.gd
extends Control

# Get reference to global UpgradeManager
@onready var upgrade_manager = get_node("/root/UpgradeManager")

@onready var connect_button: Button = $TopBar/HBoxContainer/ConnectButton
@onready var single_player_button: Button = $TopBar/HBoxContainer/SinglePlayerButton
@onready var name_value_label: Label = $TopBar/HBoxContainer/NameValue
@onready var status_label: Label = $TopBar/StatusLabel
@onready var tab_container: TabContainer = $TabContainer
@onready var ship_tab = $HBoxContainer/TabContainer/Ship
@onready var upgrade_tab = $HBoxContainer/TabContainer/Upgrades
@onready var commander_skills_tab = $"HBoxContainer/TabContainer/Commander Skills"

var dock_node  # Will be set by the main scene
var udp: PacketPeerUDP = null
var lobby
var selected_ship
var waiting: bool = false
var pulse_time: float = 0.0
var original_modulate: Color

func _ready():
	connect_button.pressed.connect(_on_connect_pressed)
	single_player_button.pressed.connect(_on_single_player_pressed)
	original_modulate = connect_button.modulate

	# Hook up network signals
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	
	# Connect ship_selected signal from ship_tab
	ship_tab.ship_selected.connect(_on_ship_selected)
	
	# Connect upgrade signals from upgrade_tab
	upgrade_tab.upgrade_selected.connect(_on_upgrade_selected)
	upgrade_tab.upgrade_removed.connect(_on_upgrade_removed)

	commander_skills_tab.skill_toggled.connect(_on_skill_toggled)

	# Load saved player name
	name_value_label.text = GameSettings.player_name
	
	# If there's a previously selected ship, restore it
	if GameSettings.selected_ship != "":
		ship_tab.call_deferred("_on_ship_button_pressed", GameSettings.selected_ship)

func set_dock_node(dock: Node3D):
	dock_node = dock
	ship_tab.set_dock_node(dock)

# Handle ship selection from the ship tab
func _on_ship_selected(ship_node):
	selected_ship = ship_node

	
	# Apply any previously selected upgrades for this specific ship
	if selected_ship is Ship and GameSettings.ship_config.has(GameSettings.selected_ship):
		for slot_str in GameSettings.ship_config[GameSettings.selected_ship]:
			if slot_str != "skills":
				var slot_index = slot_str.to_int()
				var upgrade_path = GameSettings.ship_config[GameSettings.selected_ship][slot_str]
				_apply_upgrade_to_ship(selected_ship, slot_index, upgrade_path)
		var skills = GameSettings.ship_config[GameSettings.selected_ship].get("skills", [])
		for skill_path in skills:
			var skill = load(skill_path)
			if skill == null:
				push_error("Failed to load skill resource: " + skill_path)
				continue
			var skill_instance = skill.new()
			if not skill_instance is Skill:
				push_error("Loaded resource is not a Skill: " + skill_path)
				continue
			selected_ship.skills.add_skill(skill_instance)

	# Pass the selected ship to the upgrade and commander tabs
	upgrade_tab.set_ship(selected_ship)
	commander_skills_tab.set_ship(selected_ship)

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
	GameSettings.is_single_player = false
	GameSettings.save_settings()
	
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
	GameSettings.is_single_player = true
	GameSettings.save_settings()
	
	status_label.text = "Starting single player game..."
	submit_to_matchmaker()

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
	GameSettings.save_settings()
	TcpThreadPool.start_client()
	get_tree().call_deferred("change_scene_to_file", "res://src/server/server.tscn")

func _on_connection_failed():
	status_label.text = "Failed to connect to server."


func _stop_waiting():
	waiting = false
	single_player_button.disabled = false
	connect_button.text = "Multiplayer"
	connect_button.modulate = original_modulate
	
func _on_upgrade_selected(slot_index: int, upgrade_path: String):
	# Check if this is the first upgrade for this ship
	if not GameSettings.ship_config.has(GameSettings.selected_ship):
		GameSettings.ship_config[GameSettings.selected_ship] = {}
	
	# Save upgrade to game settings under the current ship
	GameSettings.ship_config[GameSettings.selected_ship][str(slot_index)] = upgrade_path
	GameSettings.save_settings()
	
	print("Upgrade selected: ", upgrade_path, " for slot ", slot_index)

func _on_upgrade_removed(slot_index: int):
	# Check if this ship has any upgrades saved
	if GameSettings.ship_config.has(GameSettings.selected_ship):
		# Check if the slot exists in this ship's config
		if GameSettings.ship_config[GameSettings.selected_ship].has(str(slot_index)):
			print("Upgrade removed from slot ", slot_index)
			
			# Remove the upgrade from this slot
			GameSettings.ship_config[GameSettings.selected_ship].erase(str(slot_index))
			GameSettings.save_settings()

func _apply_upgrade_to_ship(ship: Ship, slot_index: int, upgrade_path: String):
	# Use the UpgradeManager to apply the upgrade
	if upgrade_path.is_empty():
		return
		
	var success = upgrade_manager.apply_upgrade_to_ship(ship, slot_index, upgrade_path)
	if success:
		print("Applied upgrade to ship: ", upgrade_path)
	else:
		print("Failed to apply upgrade: ", upgrade_path)
	
	# Update the upgrade tab UI
	upgrade_tab.ship_upgrade_ui._update_slot_buttons()

func _on_skill_toggled(skill_path: String, enabled: bool):
	if selected_ship == null or skill_path == "":
		return

	var skill_resource = load(skill_path)
	if skill_resource == null:
		print("Failed to load skill resource: ", skill_path)
		return
	
	var skill_instance = skill_resource.new()
	if skill_instance is Skill:
		if enabled:
			selected_ship.skills.add_skill(skill_instance)
			if not GameSettings.ship_config.has(GameSettings.selected_ship):
				GameSettings.ship_config[GameSettings.selected_ship] = {}
			if not GameSettings.ship_config[GameSettings.selected_ship].has("skills"):
				GameSettings.ship_config[GameSettings.selected_ship]["skills"] = []
			var skills_array = GameSettings.ship_config[GameSettings.selected_ship]["skills"]
			if skill_path not in skills_array:
				skills_array.append(skill_path)
			GameSettings.save_settings()

		else:
			if GameSettings.ship_config.has(GameSettings.selected_ship) and GameSettings.ship_config[GameSettings.selected_ship].has("skills"):
				var skills_array = GameSettings.ship_config[GameSettings.selected_ship]["skills"]
				if skill_path in skills_array:
					skills_array.erase(skill_path)
					GameSettings.save_settings()
			selected_ship.skills.remove_skill(skill_instance)
