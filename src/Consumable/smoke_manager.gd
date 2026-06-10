extends Node3D

var smoke_puffs: Array[Node3D] = []
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func spawn_smoke(ship: Ship, size: float, duration: float) -> void:
	var smoke_puff = preload("res://src/Consumable/smoke/smoke_puff.tscn").instantiate() as Node3D
	# smoke_puff.team_id = team_id
	# get_tree().root.add_child(smoke_puff)
	add_child(smoke_puff)
	get_tree().create_timer(duration).timeout.connect(smoke_puff.queue_free)
	smoke_puff.global_position = ship.global_position
	smoke_puff.scale = Vector3(size, size, size)
	spawn_smoke_c.rpc(ship.global_position, ship.team.team_id, size, duration)

@rpc("call_remote", "reliable")
func spawn_smoke_c(pos: Vector3, team_id: int, size: float, duration: float):
	var smoke_puff = preload("res://src/Consumable/smoke/smoke_puff.tscn").instantiate()
	#var scene_tree = Engine.get_main_loop() as SceneTree
	# scene_tree.root.add_child(smoke_puff)
	add_child(smoke_puff)
	get_tree().create_timer(duration).timeout.connect(smoke_puff.queue_free)
	smoke_puff.global_position = pos
	smoke_puff.scale = Vector3(size, size, size)
	# smoke_puff.team_id = team_id
	# get_tree().root.add_child(smoke_puff)
