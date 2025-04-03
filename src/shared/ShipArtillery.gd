extends Node
class_name ShipArtillery

# Gun-related variables
var guns: Array[Gun] = []
var aim_point: Vector3

func _ready() -> void:
	# Find all guns in the ship
	var parent_model = get_parent().get_child(1)
	var gun_id = 0
	for ch in parent_model.get_children():
		if ch is Gun:
			ch.gun_id = gun_id
			gun_id += 1
			self.guns.append(ch)

func set_aim_input(target_point: Vector3) -> void:
	aim_point = target_point

func _physics_process(delta: float) -> void:
	if !multiplayer.is_server():
		return
		
	# Aim all guns toward the target point
	for g in guns:
		g._aim(aim_point, delta)
		
@rpc("any_peer", "call_remote")
func fire_gun(gun_id: int) -> void:
	if gun_id < guns.size():
		guns[gun_id].fire()
@rpc("any_peer", "call_remote")
func fire_all_guns() -> void:
	for gun in guns:
		if gun.reload >= 1.0:
			gun.fire()
@rpc("any_peer", "call_remote")
func fire_next_ready_gun() -> void:
	for g in guns:
		if g.reload >= 1:
			g.fire()
			return
