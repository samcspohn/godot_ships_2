extends Node
class_name SecondaryController_

@export var sub_controllers: Array[SecSubController] = []
var shell_index: int = 1 # default HE
var _ship: Ship
var target: Ship
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var sequential_fire_timer: float = 0.0 # Timer for sequential firing
var gun_targets: Dictionary[Gun, Ship] = {}

var target_mod: TargetMod
var manual_target_mod: TargetMod = TargetMod.new()
var target_mods: Dictionary[Ship, TargetMod] = {}
var enabled: bool = true

var aim_point: Variant = null # for manual control
var target_offset: Vector3 = Vector3.ZERO
var guns_shooting_at_aim_point: Dictionary[Gun, bool] = {}
var just_switched_mode: bool = false
# var _found_target: bool = false
# var not_all_returned_to_base: bool
var targets_guns: Dictionary[Ship, Array] = {}
var target_seq_timers: Dictionary[Ship, float] = {}

var weapons: Array[Turret]:
	get:
		var all_weapons: Array[Turret] = []
		for sc in sub_controllers:
			for g in sc.guns:
				all_weapons.append(g as Turret)
		return all_weapons

var active: bool

func get_weapon_ui() -> Array[Button]:

	if sub_controllers.size() == 0:
		return []

	var shell1 = Button.new()
	shell1.text = "sAP"
	shell1.pressed.connect(func():
		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
		# shell_index = 0
		select_shell.rpc_id(1, 0)
	)

	var shell2 = Button.new()
	shell2.text = "sHE"
	shell2.pressed.connect(func():
		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
		# shell_index = 1
		select_shell.rpc_id(1, 1)
	)

	return [shell1, shell2]


func get_aim_ui() -> Dictionary:
	var time_to_target = -1
	var penetration_power = -1
	var terrain_hit = false
	if aim_point == null:
		return {
			"terrain_hit": terrain_hit,
			"penetration_power": penetration_power,
			"time_to_target": time_to_target
		}
	var ship_position = _ship.global_position
	var _aim_point = aim_point as Vector3

	var max_range = -1
	for sec in sub_controllers:
		var gun_params: GunParams = sec.get_params()
		if gun_params._range > max_range:
			max_range = gun_params._range

	if Vector2(_aim_point.x, _aim_point.z).distance_to(Vector2(ship_position.x, ship_position.z)) > max_range:
		return {
			"terrain_hit": terrain_hit,
			"penetration_power": penetration_power,
			"time_to_target": time_to_target
		}

	if aim_point != null:
		for sec in sub_controllers:
			var shell_params = sec.get_shell_params()
			var pp = -1
			var th = false
			var tt = -1


			var launch_result = ProjectilePhysicsWithDragV2.calculate_launch_vector(
				ship_position,
				aim_point,
				shell_params
			)
			var launch_vector = launch_result[0]

			if launch_vector:
				tt = launch_result[1] / ProjectileManager.shell_time_multiplier
				var can_shoot: Gun.ShootOver = Gun.sim_can_shoot_over_terrain_static(
					ship_position,
					launch_vector,
					launch_result[1],
					shell_params,
					_ship
					)

				th = not can_shoot.can_shoot_over_terrain
				var shell = sec.get_shell_params()
				if shell.type == ShellParams.ShellType.HE:
					pp = shell.overmatch
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
					var impact_angle = velocity_at_impact_vec.normalized().angle_to(Vector3.UP)

					# Calculate effective penetration against vertical armor
					# Effective penetration = raw penetration * cos(impact_angle)
					pp = raw_pen * sin(impact_angle) * (shell as ShellParams).penetration_modifier

			if pp > penetration_power:
				penetration_power = pp
				time_to_target = tt
				terrain_hit = th

			# return terrain hit, penetration power, time to target
	return {
		"terrain_hit": terrain_hit,
		"penetration_power": penetration_power,
		"time_to_target": time_to_target
	}

func get_max_range() -> float:
	var max_range = 0.0
	for sc in sub_controllers:
		var p = sc.get_params() as GunParams
		if p._range > max_range:
			max_range = p._range
	return max_range

func get_params() -> GunParams:
	var min_reload = INF
	var selected_params: GunParams = null
	for sc in sub_controllers:
		var p = sc.params.p() as GunParams
		if p.reload_time < min_reload:
			min_reload = p.reload_time
			selected_params = p
	return selected_params

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship
	target_mod = TargetMod.new()
	target_mod.init(_ship)

	manual_target_mod.h_grouping = 1.5
	manual_target_mod.v_grouping = 1.5
	manual_target_mod.base_spread = 0.5
	manual_target_mod.init(_ship)

	for sc in sub_controllers:
		sc.init(_ship)
		sc.controller = self
		for g in sc.guns:
			gun_targets[g] = null
	if _Utils.authority():
		set_physics_process(true)
	else:
		set_physics_process(false)

func to_dict() -> Dictionary:
	var sub_list = []
	for sc in sub_controllers:
		sub_list.append(sc.to_dict())
	return {
		"sc": sub_list,
	}
func from_dict(d: Dictionary) -> void:
	var sub_list = d.get("sc", [])
	for i in range(sub_list.size()):
		if i < sub_controllers.size() and sub_list[i]:
			sub_controllers[i].from_dict(sub_list[i])

func set_aim_input(target_point: Variant):
	aim_point = target_point
	if aim_point == null and target_point != null:
		just_switched_mode = true
	if target_point == null:
		just_switched_mode = true
	aim_point = target_point

@rpc("any_peer", "reliable", "call_remote")
func fire_all():
	for sc in sub_controllers:
		for g in sc.guns:
			if guns_shooting_at_aim_point.has(g) and g.reload >= 1 and g.can_fire:
				g.fire(manual_target_mod)

@rpc("any_peer", "reliable", "call_remote")
func fire_next_ready():
	for sc in sub_controllers:
		for g in sc.guns:
			if guns_shooting_at_aim_point.has(g) and g.reload >= 1 and g.can_fire:
				g.fire(manual_target_mod)
				return

func _physics_process(delta: float) -> void:
	# return
	if !(_Utils.authority()):
		return
	if not enabled:
		for sc in sub_controllers:
			for g in sc.guns:
				g.return_to_base(delta)
		return
	# _my_gun_params.shell = _my_gun_params.shell1
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	if not server:
		return
	if not _ship.team:
		return

	var max_range = 0.0
	for sc in sub_controllers:
		var r = sc.params.p()._range
		if r > max_range:
			max_range = r

	guns_shooting_at_aim_point.clear()
	if aim_point != null:
		var ship_pos = _ship.global_position
		ship_pos.y = 0
		var aim_offset = (aim_point - ship_pos)
		aim_point = aim_offset.normalized() * min(aim_offset.length(), max_range) + ship_pos
		for sc in sub_controllers:
			for g in sc.guns:
				if g.is_aimpoint_valid(aim_point):
					guns_shooting_at_aim_point[g] = true
					g._aim(aim_point, delta)
	if just_switched_mode:
		just_switched_mode = false
		active = true



	var enemies_in_range : Array[Ship] = server.get_valid_targets(_ship.team.team_id).filter(func(p):
		return p.global_position.distance_to(_ship.global_position) <= max_range
	)
	enemies_in_range.sort_custom(func(a, b):
		if a == target and b != target:
			return true
		elif b == target and a != target:
			return false
		else:
			return a.global_position.distance_to(_ship.global_position) < b.global_position.distance_to(_ship.global_position)
	)
	if enemies_in_range.size() == 0 and !active:
		return

	active = false
	targets_guns.clear()
	# var gi = 0
	for sc in sub_controllers:
		var _range = sc.params.p()._range
		# var _gi = gi
		for g in sc.guns:
			if guns_shooting_at_aim_point.has(g):
				# gi += 1
				continue
			var found_target = false
			for e: Ship in enemies_in_range:
				var pos = e.global_position
				if e == target:
					pos = e.to_global(target_offset)
				var lead_target = g.get_leading_position(pos, e.linear_velocity / ProjectileManager.shell_time_multiplier)
				if lead_target and g.is_aimpoint_valid(pos) and g.sim_can_shoot_over_terrain(lead_target):
					# g._aim_leading(e.global_position, e.linear_velocity / ProjectileManager.shell_time_multiplier, delta)
					g._aim(lead_target, delta) # TODO: aim_with_solution + launch vector
					gun_targets[g] = e
					targets_guns[e] = targets_guns.get(e, []) + [g]
					found_target = true
					active = true
					break
			if not found_target:
				gun_targets[g] = null
				active = g.return_to_base(delta) || active

		# if enemies_in_range.size() > 0:
		# 	var reload_time = sc.params.p().reload_time
		# 	sc.sequential_fire_timer += delta
		# 	if sc.sequential_fire_timer >= min(sequential_fire_delay, reload_time / sc.guns.size()):
		# 		sc.sequential_fire_timer = 0.0
		# 		for g in sc.guns:
		# 			if guns_shooting_at_aim_point.has(g):
		# 				# gi += 1
		# 				continue
		# 			if g.reload >= 1 and g.can_fire and gun_targets[g] != null:
		# 				if gun_targets[g] == target:
		# 					g.fire(target_mod.dynamic_mod)
		# 				else:
		# 					g.fire()
		# 				# gi = sc.guns.size()
		# 				break
		# 			# gi += 1

		# get min reload time
		var min_reload_time = INF
		for sec in sub_controllers:
			min_reload_time = min(min_reload_time, sec.get_params().reload_time)

		# shoot at all targets
		for e in targets_guns:
			target_seq_timers[e] = target_seq_timers.get(e, 0.0) + delta
			if target_seq_timers[e] >= min(sequential_fire_delay, min_reload_time / targets_guns[e].size()):
				target_seq_timers[e] = 0.0
				for g: Gun in targets_guns[e]:
					if g.reload >= 1 and g.can_fire:
						if gun_targets[g] == target:
							g.fire(target_mod.dynamic_mod)
						else:
							g.fire()
						break

	# for g in guns:
	# 	g._aim(aim_point, delta)

@rpc("authority", "reliable", "call_remote")
func select_shell_c(new_type: int):
	if shell_index == new_type:
		return
	shell_index = new_type

@rpc("any_peer", "reliable", "call_remote")
func select_shell(new_type: int) -> void:

	if shell_index == new_type:
		return
	shell_index = new_type
	select_shell_c.rpc_id(multiplayer.get_remote_sender_id(), new_type)
	# for sc in sub_controllers:
	# 	#sc.shell_index = shell_index
	# 	for g in sc.guns:
	# 		g.reload = 0.0
