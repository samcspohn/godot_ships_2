extends CSGSphere3D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	scale -= Vector3(delta,delta,delta) * 20
	if scale.x < 0.05:
		queue_free() 
