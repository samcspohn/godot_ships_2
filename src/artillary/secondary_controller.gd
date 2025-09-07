extends Node
class_name SecondaryController

@export var guns: Array[Gun]
var _ship: Ship
var target: Ship
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var sequential_fire_timer: float = 0.0 # Timer for sequential firing

# Called when the node enters the scene tree for the first time.
# func _ready() -> void:

	# for ch in get_children():
	# 	if ch is Gun:
	# 		guns.append(ch)
func _ready() -> void:
	_ship = get_parent().get_parent() as Ship

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if !multiplayer.is_server():
		return
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	if not server:
		return
	if not _ship.team:
		return

	var max_range = 0.0
	if guns.size() > 0:
		max_range = guns[0].params.range
	var enemies_in_range: Array[Ship] = []
	for pid in server.players:
		var p: Ship = server.players[pid][0]
		if p.team.team_id != _ship.team.team_id and p.global_position.distance_to(_ship.global_position) <= max_range and p.visible_to_enemy and p.health_controller.current_hp > 0:
			enemies_in_range.append(p)

	enemies_in_range.sort_custom(func (a, b): 
		if a == target and b != target:
			return true
		elif b == target and a != target:
			return false
		else:
			return a.global_position.distance_to(_ship.global_position) < b.global_position.distance_to(_ship.global_position))

	# if enemies_in_range.size() > 0:
	for g in guns:
		var found_target = false
		for e in enemies_in_range:
			if g.valid_target_leading(e.global_position, e.linear_velocity / ProjectileManager.shell_time_multiplier):
				g._aim_leading(e.global_position, e.linear_velocity / ProjectileManager.shell_time_multiplier, delta)
				found_target = true
				break
		if not found_target:
			g.return_to_base(delta)
	if enemies_in_range.size() > 0:
		var g: Gun = guns[0]
		var reload_time = g.params.reload_time
		sequential_fire_timer += delta
		if sequential_fire_timer >= min(sequential_fire_delay, reload_time / guns.size()):
			sequential_fire_timer = 0.0
			fire_next_gun()			

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
	if multiplayer.is_server():
		for g in guns:
			if g.reload >= 1 and g.can_fire:
				g.fire()
				return
