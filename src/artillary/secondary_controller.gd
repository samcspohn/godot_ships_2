extends Node
class_name __SecondaryController


@export var params: GunParams
@export var guns: Array[Gun]
var shell_index: int = 1 # default HE
var _ship: Ship
var target: Ship
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var sequential_fire_timer: float = 0.0 # Timer for sequential firing
var gun_targets: Array[Ship] = []

var target_mod: TargetMod = TargetMod.new()

# Called when the node enters the scene tree for the first time.
# func _ready() -> void:

	# for ch in get_children():
	# 	if ch is Gun:
	# 		guns.append(ch)

func to_dict() -> Dictionary:
	return params.dynamic_mod.to_dict()

func from_dict(d: Dictionary) -> void:
	params.dynamic_mod.from_dict(d)

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship

	# params = params.duplicate(true)
	params.init(_ship)
	params.base.shell1._secondary = true
	params.base.shell2._secondary = true

	target_mod.init(_ship)
	# (params.shell1 as ShellParams)._secondary = true
	# (params.shell2 as ShellParams)._secondary = true

	for g in guns:
		g.controller = self
		g._ship = _ship
		gun_targets.append(null)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if !(_Utils.authority()):
		return
	# _my_gun_params.shell = _my_gun_params.shell1
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	if not server:
		return
	if not _ship.team:
		return

	var max_range = params.params()._range
	# if _my_gun_params.shell.caliber == 150:
	# 	print("ArtilleryController: 150mm gun range: ", max_range)
	# print("Max range: ", max_range)
	# var enemies_in_range: Array[Ship] = []
	# for pid in server.players:
	# 	var p: Ship = server.players[pid][0]
	# 	if p.team.team_id != _ship.team.team_id and p.global_position.distance_to(_ship.global_position) <= max_range and p.visible_to_enemy and p.health_controller.current_hp > 0:
	# 		enemies_in_range.append(p)
	var enemies_in_range: Array[Ship] = server.get_valid_targets(_ship.team.team_id).filter(func(p):
		return p.global_position.distance_to(_ship.global_position) <= max_range
	)

	enemies_in_range.sort_custom(func(a, b):
		if a == target and b != target:
			return true
		elif b == target and a != target:
			return false
		else:
			return a.global_position.distance_to(_ship.global_position) < b.global_position.distance_to(_ship.global_position))

	# if enemies_in_range.size() > 0:
	for gi in guns.size():
		var g: Gun = guns[gi]
		var found_target = false
		var pm = get_node("/root/ProjectileManager")
		for e in enemies_in_range:
			if g.valid_target_leading(e.global_position, e.linear_velocity / pm.shell_time_multiplier):
				g._aim_leading(e.global_position, e.linear_velocity / pm.shell_time_multiplier, delta)
				gun_targets[gi] = e
				found_target = true
				break
		if not found_target:
			gun_targets[gi] = null
			g.return_to_base(delta)
			# pass

	if enemies_in_range.size() > 0:
		var reload_time = params.params().reload_time
		sequential_fire_timer += delta
		if sequential_fire_timer >= min(sequential_fire_delay, reload_time / guns.size()):
			sequential_fire_timer = 0.0
			if _Utils.authority():
				for gi in guns.size():
					var g: Gun = guns[gi]
					if g.reload >= 1 and g.can_fire:
						if gun_targets[gi] == target:
							g.fire(target_mod)
						else:
							g.fire()
						return

	# if target == null or guns.size() == 0 or !target.visible_to_enemy:
	# 	for g in guns:
	# 		g.return_to_base(delta)
	# 	return
	# if target.health_controller.current_hp <= 0:
	# 	target = null
	# 	return
	# #var target_vel = (target.global_position - target.previous_position) / delta
	# var target_vel = target.linear_velocity / 2.0

	# for g in guns:
	# 	g._aim_leading(target.global_position, target_vel, delta)
	# var g: Gun = guns[0]
	# var reload_time = g.params.reload_time
	# sequential_fire_timer += delta
	# if sequential_fire_timer >= min(sequential_fire_delay, reload_time / guns.size()):
	# 	sequential_fire_timer = 0.0
	# 	fire_next_gun()

# @rpc("any_peer", "call_remote")
func fire_next_gun() -> void:
	if _Utils.authority():
		for g in guns:
			if g.reload >= 1 and g.can_fire:
				g.fire()
				return

func get_shell_params() -> ShellParams:
	if shell_index == 0:
		return params.shell1
	else:
		return params.shell2

func get_params() -> GunParams:
	return params.params() as GunParams
