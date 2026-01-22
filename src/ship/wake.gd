extends TrailEmitter

@export var here: float
func _process(_delta: float) -> void:
	self.global_position.y = 0.1
	super._process(_delta)
