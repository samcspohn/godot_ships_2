extends ConsumableItem
class_name SmokeScreen

@export var emit_time = 1.0
var tick_start := -1
@export var size := 100.0
@export var smoke_duration := 100.0
# var smoke_pos := Vector3.ZERO
# Called when the node enters the scene tree for the first time.
func _init():
	#pass # Replace with function body.
	tick_start = Engine.get_physics_frames()

var time_elapsed := 0.0
func _proc(delta: float, ship :Ship):
	time_elapsed += delta
	# if _Utils.authority() and (Engine.get_physics_frames() - tick_start) % emit_ticks == 0:
		# var server: GameServer = ship.get_tree().root.get_node_or_null("/root/Server")
		# if server:
		# 	server.spawn_smoke_screen(ship.global_position, ship.team.team_id)
		# var smoke_puff = preload("res://src/Consumable/smoke/smoke_puff.tscn").instantiate()
		# smoke_puff.global_position = ship.global_position
		# smoke_pos = ship.global_position
		# smoke_puff.team_id = ship.team.team_id
		# ship.get_tree().root.add_child(smoke_puff)
		# spawn_smoke_c.rpc(ship.global_position, ship.team.team_id)
	if time_elapsed >= emit_time:
		time_elapsed = 0.0
		SmokeManager.spawn_smoke(ship, size, smoke_duration)

# # @rpc("call_remote")
# func spawn_smoke_c(pos: Vector3, team_id: int):
# 	var smoke_puff = preload("res://src/Consumable/smoke/smoke_puff.tscn").instantiate()
# 	var scene_tree = Engine.get_main_loop() as SceneTree
# 	scene_tree.root.add_child(smoke_puff)
# 	smoke_puff.global_position = pos
# 	# smoke_puff.team_id = team_id
# 	# get_tree().root.add_child(smoke_puff)

# func to_bytes() -> PackedByteArray:
# 	var writer = StreamPeerBuffer.new()
# 	writer.put_32(tick_start)
# 	writer.put_var(smoke_pos)
# 	return writer.get_data_array()

# func from_bytes(data: PackedByteArray):
# 	var reader = StreamPeerBuffer.new()
# 	reader.data_array = data
# 	tick_start = reader.get_32()
# 	smoke_pos = reader.get_var()
# 	if (Engine.get_physics_frames() - tick_start) % emit_ticks == 0:
# 		spawn_smoke_c(smoke_pos, 0)
