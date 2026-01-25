extends Node

class_name BotControllerV3

var debug_log_interval: float = 1.0
var debug_log_timer: float = 0.0

var _ship: Ship

var server_node: GameServer # Todo: create GLOBALS with server_node
var movement: ShipMovementV4
var target: Variant
var navigation_proxy: Node3D
var navigation_agent: NavigationAgent3D
var path: PackedVector3Array
var desired_heading: float
var grounded_position: Variant = null

@export var target_scan_interval: float = 30.0
var target_scan_timer: float = 0.0

func _ready() -> void:
	server_node = get_tree().root.get_node("/root/Server")
	movement = get_node("../MovementController")

	navigation_proxy = Node3D.new()
	navigation_agent = NavigationAgent3D.new()
	navigation_agent.radius = movement.ship_length / 2 + 50.0
	# navigation_agent.border_size = 50.0
	navigation_agent.path_desired_distance = movement.ship_length / 2 + 50.0
	navigation_agent.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	navigation_agent.simplify_path = true
	navigation_agent.avoidance_enabled = true
	navigation_agent.neighbor_distance = movement.ship_length
	# path = navigation_agent.get_current_navigation_path()
	server_node.get_node("GameWorld/Env").get_child(0).add_child(navigation_proxy)
	navigation_proxy.global_position = _ship.global_position
	navigation_proxy.add_child(navigation_agent)
	# navigation_agent.set_target_position(target)
	get_tree().create_timer(0.1).timeout.connect(defer_target)

func defer_target():
	target = _ship.global_position
	target.z = -target.z
	target.y = 0.0
	navigation_agent.set_target_position(target)

func _physics_process(_delta: float) -> void:
	_update_proxy()
	var pos = navigation_agent.get_next_path_position()

	target_scan_timer += _delta
	if target_scan_timer >= target_scan_interval:
		target_scan_timer = 0.0
		_aquire_target()

	if movement.is_grounded or grounded_position != null:
		if grounded_position == null:
			grounded_position = _ship.global_position
		desired_heading = _normalize_angle(get_ship_heading() - PI)
		if _ship.global_position.distance_to(grounded_position) > movement.turning_circle_radius * 2.0:
			grounded_position = null
	else:
		desired_heading = calculate_desired_heading(pos)
	apply_ship_controls()

	engage_target()

func _update_proxy():
	navigation_proxy.global_position = _ship.global_position
	navigation_proxy.global_position.y = 0.0
	path = navigation_agent.get_current_navigation_path()
	if target is Ship:
		navigation_agent.set_target_position(target.global_position)
	if path.is_empty():
		navigation_agent.set_target_position(target if target is Vector3 else Vector3.ZERO)

func get_ship_heading() -> float:
	"""Get ship's current heading. 0 = +Z, PI/2 = +X, etc."""
	var forward := -_ship.global_transform.basis.z
	return atan2(forward.x, forward.z)

func _normalize_angle(angle: float) -> float:
	while angle > PI:
		angle -= TAU
	while angle < -PI:
		angle += TAU
	return angle

func calculate_desired_heading(target_position: Vector3) -> float:
	var to_target: Vector3 = target_position - _ship.global_position
	to_target.y = 0.0
	return atan2(to_target.x, to_target.z)

func apply_ship_controls():

	var ship_heading := get_ship_heading()
	var angle_diff := _normalize_angle(desired_heading - ship_heading)

	var rudder := 0.0
	var heading_tolerance := deg_to_rad(150) # behind

	if abs(angle_diff) < heading_tolerance:
		rudder = -clampf(angle_diff * 4.0 / PI, -1.0, 1.0)
		movement.set_movement_input([4.0, rudder])
	elif angle_diff > 0: # reverse
		rudder = -clampf(deg_to_rad(180) - angle_diff, -1.0, 1.0)
		movement.set_movement_input([-1, rudder])

func _aquire_target():
	var closest_ship: Ship = null
	var closest_distance = 1000000.0
	for ship in server_node.get_valid_targets(_ship.team.team_id):
		var distance = _ship.global_position.distance_to(ship.global_position)
		if distance < closest_distance:
			closest_distance = distance
			closest_ship = ship
	if closest_ship != null:
		target = closest_ship
	elif target is Vector3:
		target = target
	elif target == null:
		target = Vector3.ZERO # todo, search for last seen/random point

func engage_target():
	if target is Ship:
		var adjusted_target_pos = target.global_position
		var target_lead = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(
			_ship.global_position,
			adjusted_target_pos,
			target.linear_velocity / ProjectileManager.shell_time_multiplier,
			_ship.artillery_controller.get_shell_params().speed,
			_ship.artillery_controller.get_shell_params().drag
		)[2]

		if target_lead != null:
			_ship.artillery_controller.set_aim_input(target_lead)
			_ship.artillery_controller.fire_next_ready()
