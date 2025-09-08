extends Node
class_name ArtilleryController

# Gun-related variables
@export var gun_params: GunParams
var _my_gun_params: GunParams
@export var guns: Array[Gun] = []
var aim_point: Vector3
var _ship: Ship

func _ready() -> void:
	# Find all guns in the ship
	#var parent_model = get_parent().get_parent().get_child(1)
	#var gun_id = 0
	#for ch in parent_model.get_children():
		#if ch is Gun:
			#ch.gun_id = gun_id
			#gun_id += 1
			#self.guns.append(ch)
	_ship = get_parent().get_parent() as Ship
	var i = 0
	_my_gun_params = gun_params.duplicate(true)
	_my_gun_params.shell = _my_gun_params.shell1

	for g in guns:
		g.gun_id = i
		g.controller = self
		g._ship = _ship
		i += 1

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
		if guns[gun_id].reload >= 1.0 and guns[gun_id].can_fire:
			guns[gun_id].fire()
@rpc("any_peer", "call_remote")
func fire_all_guns() -> void:
	for gun in guns:
		if gun.reload >= 1.0 and gun.can_fire:
			gun.fire()
@rpc("any_peer", "call_remote")
func fire_next_ready_gun() -> void:
	for g in guns:
		if g.reload >= 1 and g.can_fire:
			g.fire()
			return

@rpc("any_peer", "call_remote")
func select_shell(shell_index: int) -> void:
	if !multiplayer.is_server():
		return
	if shell_index == 0:
		_my_gun_params.shell = _my_gun_params.shell1
	elif shell_index == 1:
		_my_gun_params.shell = _my_gun_params.shell2
	else:
		return
	#for gun in guns:
		#if shell_index == 1:
			#gun.my_params.shell = gun.my_params.shell2
		#else:
			#gun.my_params.shell = gun.my_params.shell1
	
	select_shell_client.rpc(shell_index)

# todo: only broadcast if shooting or detected
@rpc("authority", "call_remote")
func select_shell_client(shell_index: int) -> void:
	if shell_index == 0:
		_my_gun_params.shell = _my_gun_params.shell1
	elif shell_index == 1:
		_my_gun_params.shell = _my_gun_params.shell2
	else:
		return
	# for gun in guns:
	# 	if shell_index == 1:
	# 		gun.my_params.shell = gun.my_params.shell2
	# 	else:
	# 		gun.my_params.shell = gun.my_params.shell1
