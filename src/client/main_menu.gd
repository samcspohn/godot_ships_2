# src/client/client_ui_manager.gd
extends Control

@onready var connect_button = $VBoxContainer/ConnectButton
@onready var ip_input = $VBoxContainer/IPInput
@onready var name_input = $VBoxContainer/NameInput
@onready var status_label = $VBoxContainer/StatusLabel
@onready var battleship_button = $ScrollContainer/HBoxContainer/Battleship
@onready var cruiser_button = $ScrollContainer/HBoxContainer/Cruiser
@onready var destroyer_button = $ScrollContainer/HBoxContainer/Destroyer
@onready var dock = $Dock
# @onready var leave_matchmaking = $VBoxContainer/LeaveQueue
var udp
#var timer
var lobby
var selected_ship
func _ready():
	connect_button.pressed.connect(_on_connect_pressed)
	battleship_button.pressed.connect(_on_battle_ship_button)
	cruiser_button.pressed.connect(_on_cruiser_ship_button)
	destroyer_button.pressed.connect(_on_destroyer_ship_button)
	
func _on_battle_ship_button():
	if selected_ship != null:
		selected_ship.queue_free()
	selected_ship = load("res://scenes/Ships/Battleship.tscn").instantiate()
	GameSettings.selected_ship = "res://scenes/Ships/Battleship.tscn"
	dock.add_child(selected_ship)
	selected_ship.position = Vector3(0,6,0)

func _on_cruiser_ship_button():
	if selected_ship != null:
		selected_ship.queue_free()
	selected_ship = load("res://scenes/Ships/Cruiser.tscn").instantiate()
	GameSettings.selected_ship = "res://scenes/Ships/Cruiser.tscn"
	dock.add_child(selected_ship)
	selected_ship.position = Vector3(0,6,0)

func _on_destroyer_ship_button():
	return
	if selected_ship != null:
		selected_ship.queue_free()
	selected_ship = load("res://scenes/Ships/Destroyer.tscn").instantiate()
	GameSettings.selected_ship = "res://scenes/Ships/Destroyer.tscn"
	dock.add_child(selected_ship)
	selected_ship.position = Vector3(0,6,0)

func _on_connect_pressed():
	# Update game settings
	GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.save_settings()
	
	status_label.text = "Connecting to matchmaker..."
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")
	
