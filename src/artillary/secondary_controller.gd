extends Node

var guns: Array[Gun]
var target: PlayerController
var parent_name: StringName
var sequential_fire_delay: float = 0.4 # Delay between sequential gun fires
var sequential_fire_timer: float = 0.0 # Timer for sequential firing

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var player = get_node("..")
	parent_name = player.name

	for ch in get_children():
		if ch is Gun:
			guns.append(ch)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if !multiplayer.is_server():
		return

	if target == null:
		var spawn_players = get_tree().root.get_node("/root/Server/GameWorld/SpawnPlayers")
		for child in spawn_players.get_children():
			if child.name != parent_name:
				target = child
	if target == null:
		return
	var target_vel = (target.global_position - target.previous_position) / delta * 0.5

	for g in guns:
		g._aim_leading(target.global_position, target_vel, delta)
	sequential_fire_timer += delta
	if sequential_fire_timer >= sequential_fire_delay:
		sequential_fire_timer = 0.0
		fire_next_gun()

# @rpc("any_peer", "call_remote")
func fire_next_gun() -> void:
	if multiplayer.is_server():
		for g in guns:
			if g.reload >= 1:
				g.fire()
				return
