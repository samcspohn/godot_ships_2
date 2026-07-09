extends Aircraft
class_name TorpedoAircraft

@export var torpedo_params: TorpedoParams

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

# Fires a single torpedo from wherever this aircraft currently is (its
# formation slot, spread out by the squadron for the attack run), then
# reports back that it should be recalled - a torpedo run is one-shot.
func fire_ordnance(direction: Vector2) -> bool:
	var torp_vel = Vector3(direction.x, 0.0, direction.y).normalized()
	var t = ProjectileManager.get_current_time()
	var t_id = TorpedoManager.fireTorpedo(torp_vel, global_position, torpedo_params, t, _ship, 1000.0)
	TorpedoManager.notify_fired(t_id, global_position, torp_vel, t, torpedo_params, _ship, false)
	return true
