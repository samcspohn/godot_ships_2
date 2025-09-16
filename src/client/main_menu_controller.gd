# src/client/main_menu_controller.gd
extends Node

@onready var main_menu_ui = $MainMenuUI
@onready var main_menu_3d = $MainMenu3D
@onready var dock_node = $MainMenu3D/Dock

func _ready():
	# Connect the UI to the 3D dock node
	main_menu_ui.set_dock_node(dock_node)

	# Make the orbit camera active if present
	var orbit_instance = main_menu_3d.get_node_or_null("OrbitCam")
	if orbit_instance:
		var cam = orbit_instance.get_node_or_null("Pitch/Camera3D")
		if cam and cam is Camera3D:
			cam.current = true
