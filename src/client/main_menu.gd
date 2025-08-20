# src/client/client_ui_manager.gd
extends Control

@onready var connect_button = $VBoxContainer/ConnectButton
@onready var ip_input = $VBoxContainer/IPInput
@onready var name_input = $VBoxContainer/NameInput
@onready var status_label = $VBoxContainer/StatusLabel
@onready var dock = $Dock
@onready var ship_button_container = $ScrollContainer/HBoxContainer
var udp
var lobby
var selected_ship
var ship_scenes = []

func _ready():
	connect_button.pressed.connect(_on_connect_pressed)
	_load_ship_buttons()

func _load_ship_buttons():
	_scan_directory("res://scenes/Ships/")

	var button = Button.new()
	button.text = "Bismarck"
	button.pressed.connect(_on_ship_button_pressed.bind("res://ShipModels/Bismarck2.tscn"))
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
	if GameSettings.selected_ship == "":
		return
	# Update game settings
	GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.save_settings()
	
	status_label.text = "Connecting to matchmaker..."
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")
