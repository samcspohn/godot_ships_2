extends Node
class_name HitPointsManager

@export var max_hp: float
var current_hp: float
var sunk: bool = false
@onready var ship: Ship = $"../.."

func _ready() -> void:
	current_hp = max_hp
	
func take_damage(dmg: float, pos: Vector3):
	if sunk:
		return
	current_hp -= dmg
	if current_hp <= 0 && !sunk:
		sink()

@rpc("any_peer", "reliable", "call_remote")
func sink():
	sunk = true
	if !multiplayer.is_server():
		var expl: CSGSphere3D = preload("res://src/Shells/explosion.tscn").instantiate()
		expl.radius = 300
		get_tree().root.add_child(expl)
		expl.position = ship.global_position
	#get_parent().queue_free()
	ship.artillery_controller.set_physics_process(false)
	ship.movement_controller.set_physics_process(false)
	#ship.get_node("Secondaries").set_physics_process(false)
	var pc = ship.get_node_or_null("PlayerController")
	if pc != null:
		pc.set_physics_process(false)
		pc.set_process_input(false)
	ship._disable_guns()
	#ship.set_physics_process(false)
	if multiplayer.is_server():
		sink.rpc()
