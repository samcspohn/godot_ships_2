# launch_modes.gd
extends Node

enum LaunchMode {
	CLIENT,
	DEDICATED_SERVER,
	MATCHMAKER,
	#LOCAL_HOST
}

var launch_mode = LaunchMode.CLIENT
var player_name = ""

func _ready():
	# Parse command-line arguments
	var args = OS.get_cmdline_args()
	
	if "--server" in args:
		launch_mode = LaunchMode.DEDICATED_SERVER
	elif "--matchmaker" in args:
		launch_mode = LaunchMode.MATCHMAKER
	#elif "--local" in args:
		#launch_mode = LaunchMode.LOCAL_HOST
		
	# Check for name parameter
	for i in range(args.size()):
		if args[i] == "--name" and i + 1 < args.size():
			player_name = args[i + 1]
			GameSettings.player_name = player_name
	
	# Initialize based on launch mode
	match launch_mode:
		LaunchMode.CLIENT:
			print("client")
			get_tree().call_deferred("change_scene_to_file", "res://src/client/main_menu.tscn")
		LaunchMode.DEDICATED_SERVER:
			print("server")
			for i in range(args.size()):
				if args[i] == "--port" and i + 1 < args.size():
					var port = int(args[i + 1])
					setup_dedicated_server(port)
					return
			setup_dedicated_server(GameSettings.DEFAULT_SERVER_PORT)
		LaunchMode.MATCHMAKER:
			print("matchmaker")
			setup_matchmaker()
		#LaunchMode.LOCAL_HOST:
			#setup_local_host()

func setup_dedicated_server(port):
	NetworkManager.create_server(port, GameSettings.MAX_PLAYERS)
	get_tree().call_deferred("change_scene_to_file", "res://src/server/server.tscn")

func setup_matchmaker():
	var matchmaker = preload("res://src/matchmaker/matchmaker.gd").new()
	add_child(matchmaker)
