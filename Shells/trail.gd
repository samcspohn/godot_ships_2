class_name Trail extends Node3D

var timeout = -1
func _process(delta: float) -> void:
	if timeout > -1:
		if Time.get_ticks_msec() > timeout:
			queue_free()
	
