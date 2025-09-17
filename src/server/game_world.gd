extends Node


func _ready():
	if _Utils.authority():
		# Server-side setup
		print("Game world initialized on server")
	else:
		# Client-side setup
		print("Game world initialized on client")

		get_node("Camera3D").queue_free()
		
		# Request to spawn our player - no need to send client_id, server will use the sender ID
		NetworkManager.request_spawn.rpc_id(1, multiplayer.get_unique_id(), GameSettings.player_name)
		
		# Also store player info for potential reconnection
		#NetworkManager.store_player_info(GameSettings.player_name, GameSettings.selected_ship)
		
