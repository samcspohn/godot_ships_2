extends Node3D
@export var wake: PackedScene
var last_pos: Vector3
var accum: float = 0

func _ready() -> void:
	last_pos = global_position
	#t.timeout.connect(_emit_wake)

func _process(dt: float) -> void:
	if (global_position - last_pos).length_squared() > 200:
		_emit_wake()
		accum = 0
		last_pos = global_position	

func _emit_wake() -> void:
	var w = wake.instantiate()
	get_tree().root.add_child(w)
	w.global_position = self.global_position
	var a = self.global_basis.z
	w.vel = Vector2(a.x,a.z) * 5
	
