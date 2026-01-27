extends Node

class_name BotControllerV3

# Debug info for remote clients
var _debug_desired_heading_vector: Vector3 = Vector3.ZERO
var _debug_turn_sim_points_desired: Array[Vector3] = []
var _debug_turn_sim_points_undesired: Array[Vector3] = []
var debug_draw_turn_sim: bool = true  # When true, full turn simulation is calculated for debug visualization

var debug_log_interval: float = 1.0
var debug_log_timer: float = 0.0

var _ship: Ship

var server_node: GameServer # Todo: create GLOBALS with server_node
var movement: ShipMovementV4
var target: Ship
var destination: Vector3 = Vector3.ZERO
var navigation_proxy: Node3D
var navigation_agent: NavigationAgent3D
var _avoidance_velocity: Vector3 = Vector3.ZERO
var _desired_velocity: Vector3 = Vector3.ZERO
var _avoidance_weight: float = 0.0
var _avoidance_heading: float = 0.0
var path: PackedVector3Array
var waypoint: Vector3 = Vector3.ZERO
var desired_heading: float
var desired_heading_offset_deg: float = 0.0
var grounded_position: Variant = null
var grounded_timer: float = 0.0
var behavior: BotBehavior
var invert_turn_cached: bool = false

@export var target_scan_interval: float = 30.0
var target_scan_timer: float = 0.0

## Number of simulation points per turn direction
const TURN_SIM_POINTS: int = 32
## Tolerance for considering tangent aligned with waypoint (in radians)
const TANGENT_ALIGNMENT_TOLERANCE: float = TAU / TURN_SIM_POINTS

const RECALC_FRAME: int = 4

var bot_id: int = 0

func _ready() -> void:

	if !_Utils.authority():
		set_physics_process(false)
		return

	server_node = get_tree().root.get_node("/root/Server")
	movement = get_node("../MovementController")

	navigation_proxy = Node3D.new()
	navigation_agent = NavigationAgent3D.new()
	navigation_agent.radius = movement.ship_length / 2 + 50.0
	# navigation_agent.border_size = 50.0
	navigation_agent.path_desired_distance = movement.turning_circle_radius
	navigation_agent.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	navigation_agent.simplify_path = true
	navigation_agent.avoidance_enabled = true
	navigation_agent.neighbor_distance = movement.ship_length
	navigation_agent.max_speed = movement.max_speed
	navigation_agent.time_horizon_agents = movement.rudder_response_time
	navigation_agent.velocity_computed.connect(_on_velocity_computed)
	# path = navigation_agent.get_current_navigation_path()
	# server_node.get_node("GameWorld/Env").get_child(0).add_child(navigation_proxy)
	assign_nav_agent(server_node.get_node("GameWorld/Env").get_child(0))
	navigation_proxy.global_position = _ship.global_position
	navigation_proxy.add_child(navigation_agent)
	# navigation_agent.set_target_position(target)
	get_tree().create_timer(0.1).timeout.connect(defer_target)

	behavior = BotBehavior.new()
	behavior._ship = _ship
	behavior.nav = navigation_agent
	add_child(behavior)



func _physics_process(_delta: float) -> void:
	_update_proxy()
	waypoint = navigation_agent.get_next_path_position()

	# Feed velocity to avoidance system
	_update_avoidance_velocity()

	# Update debug heading vector for remote visualization
	_update_debug_heading_vector()

	# Get terrain collision avoidance
	var threat_vector = get_threat_vector()

	if movement.is_grounded or grounded_position != null:
		if (grounded_position == null or grounded_timer > 5.0) and movement.is_grounded:
			grounded_position = movement.grounded_position
			var island = movement.grounded_island
			var dir_away_from_collision = _ship.global_position - grounded_position
			var dir_away_from_island = _ship.global_position - island.global_position
			var final_dir = dir_away_from_collision.normalized() + dir_away_from_island.normalized()
			desired_heading = atan2(final_dir.x, final_dir.z)
			grounded_timer = 0.0
		if _ship.global_position.distance_to(grounded_position) > movement.turning_circle_radius * 1.25:
			grounded_position = null
			grounded_timer = 0.0
		else:
			grounded_timer += _delta
	else:
		desired_heading = calculate_desired_heading(waypoint)

		# Apply avoidance heading override if needed (after normal heading calculation)
		# if _avoidance_weight:
		# 	desired_heading = _avoidance_heading
		desired_heading = desired_heading * (1.0 - _avoidance_weight) + _avoidance_heading * _avoidance_weight
		if threat_vector.weight > 0.0:
			var safe_heading = atan2(-threat_vector.vector.x, -threat_vector.vector.z)
			desired_heading = safe_heading * threat_vector.weight + desired_heading * (1.0 - threat_vector.weight)
	apply_ship_controls()


	target_scan_timer += _delta
	if target_scan_timer >= target_scan_interval\
	or target == null \
	or (target is Ship and (not target.is_alive() or not target.visible_to_enemy)) \
	or _ship.artillery_controller.guns[0].sim_can_shoot_over_terrain(target.global_position):
		target_scan_timer = 0.0
		_aquire_target()

	engage_target()

func _update_avoidance_velocity() -> void:
	# Calculate desired velocity toward waypoint
	var to_waypoint := waypoint - _ship.global_position
	to_waypoint.y = 0.0
	if to_waypoint.length_squared() > 0.01:
		_desired_velocity = to_waypoint.normalized() * movement.max_speed
	else:
		_desired_velocity = Vector3.ZERO

	# Feed velocity to the navigation agent for avoidance computation
	navigation_agent.set_velocity(_desired_velocity)

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	_avoidance_velocity = safe_velocity
	_avoidance_weight = 0.0

	# If avoidance velocity differs significantly from desired, store avoidance heading
	if _avoidance_velocity.length_squared() > 0.01 and _desired_velocity.length_squared() > 0.01:
		_avoidance_heading = atan2(_avoidance_velocity.x, _avoidance_velocity.z)
		var desired_heading_to_waypoint := atan2(_desired_velocity.x, _desired_velocity.z)
		var heading_diff: float = abs(_normalize_angle(_avoidance_heading - desired_heading_to_waypoint))

		_avoidance_weight = min(1.0, heading_diff / PI)

func _update_proxy():
	if Engine.get_physics_frames() % RECALC_FRAME != bot_id % RECALC_FRAME:
		return

	navigation_proxy.global_position = _ship.global_position
	navigation_proxy.global_position.y = 0.0
	path = navigation_agent.get_current_navigation_path()
	var friendly = server_node.get_team_ships(_ship.team.team_id)
	var enemy = server_node.get_valid_targets(_ship.team.team_id)
	var next_destination = behavior.get_desired_position(friendly, enemy, target, destination)
	var dir_to_next_dest = next_destination - _ship.global_position
	var dir_to_dest = destination - _ship.global_position

	var next_heading = _normalize_angle(atan2(dir_to_next_dest.x, dir_to_next_dest.z))
	var curr_heading = _normalize_angle(atan2(dir_to_dest.x, dir_to_dest.z))

	if next_destination.distance_squared_to(navigation_agent.target_position) > 1000 * 1000 or _normalize_angle(next_heading - curr_heading) > deg_to_rad(10):
		destination = next_destination
		navigation_agent.set_target_position(destination)

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

func get_threat_vector() -> Dictionary:
	var heading := get_ship_heading()
	var samples := 32
	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.from = _ship.global_position
	ray_query.from.y = - movement.ship_draft
	ray_query.collision_mask = 1
	var space_state := _ship.get_world_3d().direct_space_state
	var threat_vector := Vector3.ZERO
	var weight := 0.0
	_debug_turn_sim_points_undesired.clear()
	for i in range(samples):
		var angle := heading + (float(i) / samples) * TAU
		var point := Vector3(cos(angle), 0, sin(angle)) * movement.turning_circle_radius * 2.5
		ray_query.to = _ship.global_position + point
		var result: Dictionary = space_state.intersect_ray(ray_query)
		if !result.is_empty():
			var angle_ = angle - heading
			if angle_ > PI / 2.0:
				angle_ = PI - angle_
			angle_ = angle_ / PI # between 0 and 1, 0 directly directly forward, 1 directly perpendicular
			var weight_base = clamp(1.3 - angle_, 0.0, 1.0) # between 0 and 1, 1 directly forward, 0.3 directly perpendicular
			_debug_turn_sim_points_undesired.push_back(result.position)
			threat_vector += result.position - _ship.global_position
			weight_base = weight_base * (1.0 - threat_vector.length() / movement.turning_circle_radius * 2.5)
			threat_vector *= weight_base
			weight += weight_base

	if weight > 0.0:
		threat_vector /= weight
	weight = clamp(weight / samples * 4.0, 0.0, 1.0)
	weight = pow(weight, 0.6)
	return {"vector": threat_vector, "weight": weight}

## Returns the stored arrays of simulation points for debug visualization
func get_turn_simulation_points_desired() -> Array[Vector3]:
	return _debug_turn_sim_points_desired

func get_turn_simulation_points_undesired() -> Array[Vector3]:
	return _debug_turn_sim_points_undesired


func apply_ship_controls():

	var ship_heading := get_ship_heading()
	var angle_diff := _normalize_angle(desired_heading - ship_heading)

	desired_heading_offset_deg = rad_to_deg(angle_diff)

	var rudder := 0.0
	# if grounded allow reverse more
	# var heading_tolerance := deg_to_rad(90) if grounded_position != null else deg_to_rad(180) # behind
	# TODO: this should be behavior
	var heading_tolerance := deg_to_rad(180)
	if grounded_position != null:
		heading_tolerance = deg_to_rad(90)
	elif target != null and target.global_position.distance_to(_ship.global_position) < _ship.concealment.params.p().radius:
		heading_tolerance = deg_to_rad(150)

	if _ship.name == "1004":
		pass

	if abs(angle_diff) < heading_tolerance:
		rudder = -clampf(angle_diff * 4.0 / PI, -1.0, 1.0)
		var throttle: float = max(4 * (1.0 - angle_diff / PI * 3.0 + 0.5), 2.1)
		movement.set_movement_input([throttle, rudder])
	else: # reverse
		rudder = -clampf((PI - angle_diff) * 4.0 / PI, -1.0, 1.0)
		movement.set_movement_input([-1, rudder])

func _aquire_target():
	target = behavior.pick_target(server_node.get_valid_targets(_ship.team.team_id))

var target_lead = null
func engage_target():
	if target_lead != null and target != null:
		_ship.artillery_controller.fire_next_ready()

	if target != null and target.visible_to_enemy and target.is_alive():
		var adjusted_target_pos = target.global_position + behavior.target_aim_offset(target)
		target_lead = ProjectilePhysicsWithDrag.calculate_leading_launch_vector(
			_ship.global_position,
			adjusted_target_pos,
			target.linear_velocity / ProjectileManager.shell_time_multiplier,
			_ship.artillery_controller.get_shell_params().speed,
			_ship.artillery_controller.get_shell_params().drag
		)[2]

		if target_lead != null:
			_ship.artillery_controller.set_aim_input(target_lead)
	else:
		target_lead = null
		_ship.artillery_controller.set_aim_input(destination)

func assign_nav_agent(map: Node):
	match movement.nav_size:
		ShipMovementV4.NavSize.NAV_LIGHT:
			map.get_node("light_nav").add_child(navigation_proxy)
		ShipMovementV4.NavSize.NAV_MEDIUM:
			map.get_node("medium_nav").add_child(navigation_proxy)
		ShipMovementV4.NavSize.NAV_HEAVY:
			map.get_node("heavy_nav").add_child(navigation_proxy)
		ShipMovementV4.NavSize.NAV_SUPERHEAVY:
			map.get_node("superheavy_nav").add_child(navigation_proxy)
		ShipMovementV4.NavSize.NAV_ULTRAHEAVY:
			map.get_node("ultraheavy_nav").add_child(navigation_proxy)

func defer_target():
	destination = _ship.global_position
	destination.z = -destination.z
	destination.y = 0.0
	_update_proxy()

	# navigation_agent.set_target_position(target)

## Updates the debug heading vector based on desired_heading
func _update_debug_heading_vector() -> void:
	# Convert desired_heading angle to a direction vector
	# desired_heading uses atan2(x, z) convention
	_debug_desired_heading_vector = Vector3(
		sin(desired_heading),
		0.0,
		cos(desired_heading)
	).normalized()

## Get the debug heading vector (for local access by camera)
func get_debug_heading_vector() -> Vector3:
	return _debug_desired_heading_vector

## Get waypoint position for debug drawing
func get_debug_waypoint() -> Vector3:
	return waypoint

## Get destination position for debug drawing
func get_debug_destination() -> Vector3:
	return destination
