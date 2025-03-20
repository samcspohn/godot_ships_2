extends Node

class_name AI_Gun

var target: PlayerController
@onready var gun: Gun = $".."
var parent_name: StringName
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var player = get_node("../../..")
	parent_name = player.name
	pass # Replace with function body.


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
	#var aim_point = ProjectilePhysics.calculate_leading_launch_vector(gun.global_position, target.global_position, target_vel, Shell.shell_speed)
	var aim_point = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(gun.global_position, target.global_position, target_vel, Shell.shell_speed)
	if aim_point[0] != null:
		gun._aim_towards(aim_point[0], delta)
	#gun._aim(target.global_position,delta)
	gun.fire()
