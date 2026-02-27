extends TrailEmitter

@export var here: float
var local_offset: Vector3

func _ready() -> void:
	local_offset = self.position
	super._ready()

func _process(_delta: float) -> void:
	var parent = get_parent() as Node3D
	self.global_position = parent.to_global(local_offset)
	self.global_position.y = 0.1
	# self.global_rotation.y = parent.global_rotation.y
	super._process(_delta)
