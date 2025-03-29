extends Node3D
@export var wake: PackedScene
@onready var t = $Timer

func _ready() -> void:
	t.timeout.connect(_emit_wake)

func _emit_wake() -> void:
	var w = wake.instantiate()
	get_tree().root.add_child(w)
	w.global_position = self.global_position
	var a = self.global_basis.z
	w.vel = Vector2(a.x,a.z) * 5
	
