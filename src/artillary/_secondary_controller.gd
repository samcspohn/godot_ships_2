extends Node
class_name SecondaryController_

@export var sub_controllers: Array[SecSubController] = []
var shell_index: int = 1 # default HE
var _ship: Ship
var target: Ship
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var sequential_fire_timer: float = 0.0 # Timer for sequential firing
var gun_targets: Array[Ship] = []

var target_mod: TargetMod = TargetMod.new().duplicate(true)
var target_mods: Dictionary[Ship, TargetMod] = {}
var enabled: bool = true
var ammo_type: int = 1 # 0 = AP, 1 = HE

# var _found_target: bool = false
# var not_all_returned_to_base: bool

var active: bool

func _ready() -> void:
	# for sc in sub_controllers:
	# 	sc.controller = self
	# 	for g in sc.guns:
	# 		g.controller = self
	_ship = get_parent().get_parent() as Ship
	target_mod.init(_ship)

	for sc in sub_controllers:
		sc.init(_ship)
		# sc.p.init(_ship)
		sc.controller = self
		for g in sc.guns:
			gun_targets.append(null)
	# # params = params.duplicate(true)
	# params.init(_ship)
	# params.base.shell1._secondary = true
	# params.base.shell2._secondary = true

	# target_mod.init(_ship)
	# # (params.shell1 as ShellParams)._secondary = true
	# # (params.shell2 as ShellParams)._secondary = true

	# for g in guns:
	# 	g.controller = self
	# 	g._ship = _ship
	# 	gun_targets.append(null)
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
		var r = sc.p.params()._range
		if r > max_range:
			max_range = r

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
	var gi = 0
	for sc in sub_controllers:
		var _range = sc.p.params()._range
		var _gi = gi
		for g in sc.guns:
			var found_target = false
			for e in enemies_in_range:
				var lead_target = g.get_leading_position(e.global_position, e.linear_velocity / ProjectileManager.shell_time_multiplier)
				if lead_target and g.is_aimpoint_valid(lead_target) and g.sim_can_shoot_over_terrain(lead_target):
					# g._aim_leading(e.global_position, e.linear_velocity / ProjectileManager.shell_time_multiplier, delta)
					g._aim(lead_target, delta) # TODO: aim_with_solution + launch vector
					gun_targets[gi] = e
					found_target = true
					active = true
					break
			if not found_target:
				gun_targets[gi] = null
				active = g.return_to_base(delta) || active
			gi += 1
		gi = _gi

		if enemies_in_range.size() > 0:
			var reload_time = sc.p.params().reload_time
			sc.sequential_fire_timer += delta
			if sc.sequential_fire_timer >= min(sequential_fire_delay, reload_time / sc.guns.size()):
				sc.sequential_fire_timer = 0.0
				for g in sc.guns:
					if g.reload >= 1 and g.can_fire and gun_targets[gi] != null:
						if gun_targets[gi] == target:
							g.fire(target_mod)
						else:
							g.fire()
						gi = sc.guns.size()
						break
					gi += 1

	# for g in guns:
	# 	g._aim(aim_point, delta)

func change_ammo_type(new_type: int) -> void:
	ammo_type = new_type
	if ammo_type == 0:
		shell_index = 0
	else:
		shell_index = 1

	for sc in sub_controllers:
		for g in sc.guns:
			g.reload = 0.0
