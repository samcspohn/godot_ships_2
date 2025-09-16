extends CSGSphere3D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if scale.y > scale.x:
		scale -= Vector3(delta,delta * 3.5,delta) * 0.5
	else:
		scale -= Vector3.ONE * 2 * delta
	if scale.x < 0.05:
		queue_free() 
