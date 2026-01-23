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

func get_weapon_ui() -> Array[Button]:
	var shell1 = Button.new()
	shell1.text = "AP"
	shell1.pressed.connect(func():
		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
		select_shell.rpc_id(1, 0)
	)

	var shell2 = Button.new()
	shell2.text = "HE"
	shell2.pressed.connect(func():
		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
		select_shell.rpc_id(1, 1)
	)

	return [shell1, shell2]

var weapons: Array[Turret]:
	get:
		var arr: Array[Turret] = []
		for g in guns:
			arr.append(g)
		return arr

func to_dict() -> Dictionary:
	return {
		"params": params.dynamic_mod.to_dict(),
	}

func to_bytes() -> PackedByteArray:
	return params.dynamic_mod.to_bytes()

func from_dict(d: Dictionary) -> void:
	params.dynamic_mod.from_dict(d.get("params", {}))

func from_bytes(b: PackedByteArray) -> void:
	params.dynamic_mod.from_bytes(b)

func _ready() -> void:
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

	if _Utils.authority():
		set_physics_process(true)
	else:
		set_physics_process(false)

func set_aim_input(target_point: Vector3) -> void:
	aim_point = target_point

func _physics_process(delta: float) -> void:

	# Aim all guns toward the target point
	for g in guns:
		g._aim(aim_point, delta)


@rpc("any_peer", "call_remote")
func fire_all() -> void:
	for gun in guns:
		if gun.reload >= 1.0 and gun.can_fire:
			gun.fire(target_mod)

@rpc("any_peer", "call_remote")
func fire_next_ready() -> void:
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
