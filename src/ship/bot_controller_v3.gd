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
const TANGENT_ALIGNMENT_TOLERANCE: float = 0.1

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
	navigation_agent.path_desired_distance = movement.ship_length / 2 + 50.0
	navigation_agent.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	navigation_agent.simplify_path = true
	navigation_agent.avoidance_enabled = true
	navigation_agent.neighbor_distance = movement.ship_length * 2.0
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

	# Update debug heading vector for remote visualization
	_update_debug_heading_vector()

	if movement.is_grounded or grounded_position != null:
		if (grounded_position == null or grounded_timer > 5.0) and movement.is_grounded:
			grounded_position = movement.grounded_position
			var dir_away_from_island = _ship.global_position - grounded_position
			desired_heading = atan2(dir_away_from_island.x, dir_away_from_island.z)
			grounded_timer = 0.0
		if _ship.global_position.distance_to(grounded_position) > movement.turning_circle_radius * 2.0:
			grounded_position = null
			grounded_timer = 0.0
		else:
			grounded_timer += _delta
	else:
		desired_heading = calculate_desired_heading(waypoint)
	apply_ship_controls()


	target_scan_timer += _delta
	if target_scan_timer >= target_scan_interval\
	or target == null \
	or (target is Ship and (not target.is_alive() or not target.visible_to_enemy)) \
	or _ship.artillery_controller.guns[0].sim_can_shoot_over_terrain(target.global_position):
		target_scan_timer = 0.0
		_aquire_target()

	engage_target()

func _update_proxy():
	if Engine.get_physics_frames() % RECALC_FRAME != bot_id % RECALC_FRAME:
		return
	navigation_proxy.global_position = _ship.global_position
	navigation_proxy.global_position.y = 0.0
	path = navigation_agent.get_current_navigation_path()
	var friendly = server_node.get_team_ships(_ship.team.team_id)
	var enemy = server_node.get_valid_targets(_ship.team.team_id)
	destination = behavior.get_desired_position(friendly, enemy, target, destination)
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

## Simulates a turn and checks if the path is valid on the nav mesh.
## Returns true if the turn should be inverted (i.e., the shorter turn is blocked).
##
## Parameters:
## - ship_position: Current global position of the ship
## - waypoint: The target waypoint position
##
## This function:
## 1. Determines the shorter turn direction to the waypoint
## 2. Simulates points along the turning arc
## 3. Checks if each point is valid on the navigation mesh
## 4. If the shorter turn is blocked, checks the longer turn
## 5. Returns true if the ship should use the longer (inverted) turn
func should_invert_turn(ship_position: Vector3, waypoint: Vector3) -> bool:
	if Engine.get_physics_frames() % RECALC_FRAME != bot_id % RECALC_FRAME:
		return invert_turn_cached
	var current_heading := get_ship_heading()
	var to_waypoint := waypoint - ship_position
	to_waypoint.y = 0.0
	var target_heading := atan2(to_waypoint.x, to_waypoint.z)
	var angle_diff := _normalize_angle(target_heading - current_heading)

	# Determine shorter turn direction: positive angle_diff = turn right (clockwise)
	# negative angle_diff = turn left (counter-clockwise)
	var shorter_turn_right := angle_diff > 0

	# Generate debug visualization points if debugging is enabled
	if debug_draw_turn_sim:
		_debug_turn_sim_points_desired.clear()
		_debug_turn_sim_points_undesired.clear()

	# First, simulate the shorter turn
	var shorter_valid := _simulate_turn(ship_position, waypoint, current_heading, shorter_turn_right, _debug_turn_sim_points_desired)

	var longer_valid
	if !shorter_valid["valid"] or debug_draw_turn_sim:
		# Shorter turn is blocked, try the longer turn
		longer_valid = _simulate_turn(ship_position, waypoint, current_heading, not shorter_turn_right, _debug_turn_sim_points_undesired, shorter_valid["points"] + 1)

	invert_turn_cached = false if shorter_valid["valid"] else shorter_valid["points"] < longer_valid["points"]

	# Both turns are blocked - return false and let the ship handle it
	# (might need to back up, which is handled by the grounded logic)

	return invert_turn_cached

## Simulates a turn in the specified direction and returns true if the path is valid.
##
## Parameters:
## - ship_position: Starting position of the ship
## - waypoint: Target waypoint
## - current_heading: Ship's current heading in radians
## - turn_right: If true, simulate turning right (clockwise); otherwise, turn left
## - points_array: Optional array to store simulation points for debug visualization
## - full_sim: If true, simulate full circle regardless of early exit conditions
##
## Returns a dictionary with the following keys:
## - valid: True if all simulated points are on valid nav mesh positions
## - points: Array of simulated points
func _simulate_turn(ship_position: Vector3, waypoint: Vector3, current_heading: float, turn_right: bool, points_array: Array[Vector3] = [], max_points: int = 100) -> Dictionary:
	var nav_map := navigation_agent.get_navigation_map()

	# Get current speed (clamped to a minimum for simulation purposes)
	var forward := -_ship.global_transform.basis.z
	var current_speed: float = max(_ship.linear_velocity.dot(forward), movement.max_speed * 0.25)

	# Calculate effective turn radius (increases at lower speeds relative to max)
	# At full speed, radius = turning_circle_radius
	# The turn radius scales with speed squared (roughly)
	var speed_ratio := current_speed / movement.max_speed
	var effective_radius: float = movement.turning_circle_radius / max(speed_ratio, 0.25)

	# Calculate the center of the turning circle
	# Right turn: center is to the right of the ship
	# Left turn: center is to the left of the ship
	var perpendicular_heading := current_heading + (PI / 2.0 if turn_right else -PI / 2.0)
	var circle_center := Vector3(
		ship_position.x + sin(perpendicular_heading) * effective_radius,
		0.0,
		ship_position.z + cos(perpendicular_heading) * effective_radius
	)

	# Calculate the angular distance we need to cover
	# This is based on how much we need to turn to align tangent with waypoint
	var to_waypoint := waypoint - ship_position
	to_waypoint.y = 0.0
	var target_heading := atan2(to_waypoint.x, to_waypoint.z)
	var total_angle_to_turn: float = abs(_normalize_angle(target_heading - current_heading))

	# If turning the "wrong way", we need to go almost all the way around
	var angle_diff := _normalize_angle(target_heading - current_heading)
	if (angle_diff > 0) != turn_right:
		total_angle_to_turn = TAU - total_angle_to_turn

	# Calculate angular step for each simulation point
	var max_angle: float = min(total_angle_to_turn + TANGENT_ALIGNMENT_TOLERANCE, TAU)

	# Fixed angle step - always TAU / TURN_SIM_POINTS (e.g., 36 degrees per step for 10 points)
	var angle_step: float = TAU / float(TURN_SIM_POINTS)

	# Calculate number of points needed for this turn
	var num_points: int = int(ceil(max_angle / angle_step))

	# Account for rudder response time
	# The ship won't immediately start turning at full rate
	var time_per_point := angle_step * effective_radius / current_speed
	var rudder_delay_points := int(ceil(movement.rudder_response_time / time_per_point))

	# Starting angle on the circle (ship position relative to center)
	var start_angle := atan2(
		ship_position.x - circle_center.x,
		ship_position.z - circle_center.z
	)

	# Direction of rotation on the circle
	var rotation_dir := 1.0 if turn_right else -1.0

	# Simulate each point along the arc
	for i in range(min(num_points, max_points)):
		# For the first few points during rudder response, interpolate the turn
		var effective_angle_step := angle_step
		if i < rudder_delay_points:
			var rudder_progress := float(i + 1) / float(rudder_delay_points)
			effective_angle_step *= rudder_progress * rudder_progress  # Ease in

		var arc_angle := start_angle + rotation_dir * effective_angle_step * float(i + 1)

		var sim_point := Vector3(
			circle_center.x + sin(arc_angle) * effective_radius,
			0.0,
			circle_center.z + cos(arc_angle) * effective_radius
		)

		# Store point for debug visualization if array provided
		if points_array != null and points_array.size() >= 0:
			var debug_point := Vector3(sim_point.x, ship_position.y + 50.0, sim_point.z)
			points_array.append(debug_point)

		# Check if this point is valid on the nav mesh
		var closest_nav_point := NavigationServer3D.map_get_closest_point(nav_map, sim_point)

		# If the closest nav point is too far from our simulated point, the path is invalid
		var distance_to_nav := sim_point.distance_to(closest_nav_point)
		if distance_to_nav > movement.ship_length / 2.0:
			return { "points": i, "valid": false }  # This point would ground the ship

		# Check if tangent at this point aligns with waypoint (within tolerance)
		# Tangent direction is perpendicular to the radius
		var tangent_heading := arc_angle + (PI / TURN_SIM_POINTS if turn_right else -PI / TURN_SIM_POINTS)
		tangent_heading = _normalize_angle(tangent_heading)

		var to_waypoint_from_sim := waypoint - sim_point
		to_waypoint_from_sim.y = 0.0
		var heading_to_waypoint := atan2(to_waypoint_from_sim.x, to_waypoint_from_sim.z)

		var tangent_diff: float = abs(_normalize_angle(heading_to_waypoint - tangent_heading))
		if tangent_diff < TANGENT_ALIGNMENT_TOLERANCE:
			return { "points": i, "valid": true }  # We've aligned with the waypoint, turn is valid

	# Completed all points without hitting invalid nav mesh
	return { "points": num_points, "valid": true }

## Returns the stored arrays of simulation points for debug visualization
func get_turn_simulation_points_desired() -> Array[Vector3]:
	return _debug_turn_sim_points_desired

func get_turn_simulation_points_undesired() -> Array[Vector3]:
	return _debug_turn_sim_points_undesired


func apply_ship_controls():

	var ship_heading := get_ship_heading()
	var angle_diff := _normalize_angle(desired_heading - ship_heading)

	desired_heading_offset_deg = rad_to_deg(angle_diff)

	var invert := should_invert_turn(_ship.global_position, waypoint)

	if invert and grounded_position != null:
		# Flip the turn direction by inverting the angle difference
		angle_diff = _normalize_angle(-sign(angle_diff) * (TAU - abs(angle_diff)))

	var rudder := 0.0
	# if grounded allow reverse more
	var heading_tolerance := deg_to_rad(150) if grounded_position != null else deg_to_rad(90) # behind

	if abs(angle_diff) < heading_tolerance:
		rudder = -clampf(angle_diff * 4.0 / PI, -1.0, 1.0)
		movement.set_movement_input([4.0, rudder])
	elif angle_diff > 0: # reverse
		rudder = -clampf((PI - angle_diff) * 4.0 / PI, -1.0, 1.0)
		movement.set_movement_input([-1, rudder])

func _aquire_target():
	target = behavior.pick_target(server_node.get_valid_targets(_ship.team.team_id))

func engage_target():
	if target != null and target.visible_to_enemy and target.is_alive():
		var adjusted_target_pos = target.global_position + behavior.target_aim_offset(target)
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
	else:
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
