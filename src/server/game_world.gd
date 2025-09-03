extends Node


func _ready():
	if multiplayer.is_server():
		# Server-side setup
		print("Game world initialized on server")
	else:
		# Client-side setup
		print("Game world initialized on client")

		get_node("Camera3D").queue_free()
		
		# Request to spawn our player
		var client_id = multiplayer.get_unique_id()
		NetworkManager.request_spawn.rpc_id(1, client_id, GameSettings.player_name)
		
