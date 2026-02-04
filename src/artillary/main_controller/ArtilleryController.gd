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

func get_aim_ui() -> Dictionary:
	var ship_position = _ship.global_position
	var shell_params = get_shell_params()
	var time_to_target = -1
	var penetration_power = -1
	var terrain_hit = false

	var launch_result = ProjectilePhysicsWithDragV2.calculate_launch_vector(
		ship_position,
		aim_point,
		shell_params
	)
	var launch_vector = launch_result[0]

	if launch_vector:
		time_to_target = launch_result[1] / ProjectileManager.shell_time_multiplier
		var can_shoot: Gun.ShootOver = Gun.sim_can_shoot_over_terrain_static(
			ship_position,
			launch_vector,
			launch_result[1],
			shell_params,
			_ship
			)

		terrain_hit = not can_shoot.can_shoot_over_terrain
		var shell = get_shell_params()
		if shell.type == ShellParams.ShellType.HE:
			penetration_power = shell.overmatch
		else:
			var velocity_at_impact_vec = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
				launch_vector,
				launch_result[1],
				shell_params
			)
			var velocity_at_impact = velocity_at_impact_vec.length()
			var raw_pen = _ArmorInteraction.calculate_de_marre_penetration(
				shell.mass,
				velocity_at_impact,
				shell.caliber)
			# var raw_pen = 1.0

			# Calculate impact angle (angle from vertical)
			var impact_angle = PI / 2 - velocity_at_impact_vec.normalized().angle_to(Vector3.UP)

			# Calculate effective penetration against vertical armor
			# Effective penetration = raw penetration * cos(impact_angle)
			penetration_power = raw_pen * cos(impact_angle) * (shell as ShellParams).penetration_modifier

	# return terrain hit, penetration power, time to target
	return {
		"terrain_hit": terrain_hit,
		"penetration_power": penetration_power,
		"time_to_target": time_to_target
	}

func get_max_range() -> float:
	return get_params()._range

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
	var ship_pos = _ship.global_position
	ship_pos.y = 0
	var target_offset = (target_point - ship_pos)
	target_point = target_offset.normalized() * min(target_offset.length(), get_params()._range) + ship_pos
	
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
