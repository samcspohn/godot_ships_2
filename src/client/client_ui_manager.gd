# src/client/client_ui_manager.gd
extends Control

@onready var connect_button = $VBoxContainer/ConnectButton
@onready var ip_input = $VBoxContainer/IPInput
@onready var name_input = $VBoxContainer/NameInput
@onready var status_label = $VBoxContainer/StatusLabel
# @onready var leave_matchmaking = $VBoxContainer/LeaveQueue
var udp
#var timer
var lobby
func _ready():
	connect_button.pressed.connect(_on_connect_pressed)

func _on_connect_pressed():
	# Update game settings
	GameSettings.player_name = name_input.text
	GameSettings.matchmaker_ip = ip_input.text
	GameSettings.save_settings()
	
	status_label.text = "Connecting to matchmaker..."
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")
	
