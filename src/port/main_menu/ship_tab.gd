# src/client/ship_tab.gd
extends Control

@onready var ship_button_container = $ScrollContainer/HBoxContainer
var ship_scenes = []
var selected_ship = null
var dock_node = null

signal ship_selected(ship_node)

func _ready():
	_load_ship_buttons()
	
	# If there's a previously selected ship, select it
	if GameSettings.selected_ship != "":
		call_deferred("_on_ship_button_pressed", GameSettings.selected_ship)

func set_dock_node(dock: Node3D):
	dock_node = dock

func _load_ship_buttons():
	# Only allow selection of Bismarck3 and H44
	var available_ships = [
		{"name": "Bismarck3", "path": "res://Ships/Bismarck/Bismarck3.tscn"},
		{"name": "H44", "path": "res://Ships/H44/H44.tscn"}
	]
	
	for ship_data in available_ships:
		var button = Button.new()
		button.text = ship_data.name
		button.pressed.connect(_on_ship_button_pressed.bind(ship_data.path))
		ship_button_container.add_child(button)

func _scan_directory(path: String):
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir() and file_name != "." and file_name != "..":
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
	var ship_asset = load(ship_path)
	if ship_asset == null:
		return
	selected_ship = ship_asset.instantiate()
	GameSettings.selected_ship = ship_path
	if dock_node:
		dock_node.add_child(selected_ship)
		selected_ship.position = Vector3(0,0,0)
	
	# Emit signal that ship was selected
	ship_selected.emit(selected_ship)
