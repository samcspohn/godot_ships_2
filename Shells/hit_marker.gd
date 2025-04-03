extends CSGSphere3D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = 100.0
	timer.timeout.connect(func(): queue_free())
	add_child(timer)
	timer.start()
	
