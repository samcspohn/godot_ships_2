extends Node
class_name ArtilleryController

# Gun-related variables
@export var params: GunParams
# var _gun_params: GunParams
@export var guns: Array[Gun] = []
var shell_index: int = 0
var aim_point: Vector3
var _ship: Ship
var target_mod: TargetMod = TargetMod.new()

func to_dict() -> Dictionary:
	return {
		"params": params.dynamic_mod.to_dict(),
	}
func from_dict(d: Dictionary) -> void:
	params.dynamic_mod.from_dict(d.get("params", {}))

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
	# params = params.duplicate(true)
	params.init(_ship)
	target_mod.init(_ship)

	for g in guns:
		g.gun_id = i
		g.controller = self
		g._ship = _ship
		i += 1

func set_aim_input(target_point: Vector3) -> void:
	aim_point = target_point

func _physics_process(delta: float) -> void:
	if !(_Utils.authority()):
		return
		
	# Aim all guns toward the target point
	for g in guns:
		g._aim(aim_point, delta)
		

@rpc("any_peer", "call_remote")
func fire_all_guns() -> void:
	for gun in guns:
		if gun.reload >= 1.0 and gun.can_fire:
			gun.fire(target_mod)

@rpc("any_peer", "call_remote")
func fire_next_ready_gun() -> void:
	for g in guns:
		if g.reload >= 1 and g.can_fire:
			g.fire(target_mod)
			return

@rpc("any_peer", "call_remote")
func select_shell(_shell_index: int) -> void:
	if !(_Utils.authority()):
		return
	shell_index = clamp(_shell_index, 0, 1)
	select_shell_client.rpc(shell_index)

# todo: only broadcast if shooting or detected
@rpc("authority", "call_remote")
func select_shell_client(_shell_index: int) -> void:
	shell_index = clamp(_shell_index, 0, 1)

func get_shell_params() -> ShellParams:
	if shell_index == 0:
		return params.dynamic_mod.shell1
	else:
		return params.dynamic_mod.shell2

func get_params() -> GunParams:
	return params.dynamic_mod as GunParams
