extends RefCounted

class_name ProfiledShipNavigator

## Thin GDScript proxy around the native ShipNavigator.
## Purpose: make navigator work visible as named GDScript calls in the profiler.

var _impl: ShipNavigator = ShipNavigator.new()


func get_raw() -> ShipNavigator:
	return _impl


func set_map(nav_map: Variant) -> void:
	_impl.set_map(nav_map)


func set_hpa_graph(hpa_graph: Variant) -> void:
	_impl.set_hpa_graph(hpa_graph)


func set_ship_params(
	turning_circle_radius: float,
	rudder_response_time: float,
	acceleration_time: float,
	deceleration_time: float,
	max_speed: float,
	reverse_speed_ratio: float,
	ship_length: float,
	ship_beam: float,
	turn_speed_loss: float,
	base_drag: float
) -> void:
	_impl.set_ship_params(
		turning_circle_radius,
		rudder_response_time,
		acceleration_time,
		deceleration_time,
		max_speed,
		reverse_speed_ratio,
		ship_length,
		ship_beam,
		turn_speed_loss,
		base_drag
	)


func set_bot_id(value: int) -> void:
	_impl.set_bot_id(value)


func set_state(
	position: Vector3,
	linear_velocity: Vector3,
	heading: float,
	angular_velocity_y: float,
	rudder_input: float,
	current_speed: float,
	delta: float
) -> void:
	_impl.set_state(
		position,
		linear_velocity,
		heading,
		angular_velocity_y,
		rudder_input,
		current_speed,
		delta
	)


func set_grounded(is_grounded: bool) -> void:
	_impl.set_grounded(is_grounded)


func set_health_fraction(value: float) -> void:
	_impl.set_health_fraction(value)


func navigate_to(
	target_position: Vector3,
	target_heading: float,
	hold_radius: float = 0.0,
	heading_tolerance: float = 0.0,
	heading_weight: float = 0.0
) -> void:
	_impl.navigate_to(
		target_position,
		target_heading,
		hold_radius,
		heading_tolerance,
		heading_weight
	)


func clear_obstacles() -> void:
	_impl.clear_obstacles()


func register_obstacle(id: int, pos_2d: Vector2, vel_2d: Vector2, radius: float, length: float) -> void:
	_impl.register_obstacle(id, pos_2d, vel_2d, radius, length)


func clear_incoming_shells() -> void:
	_impl.clear_incoming_shells()


func add_incoming_shell(
	shell_id: int,
	landing_pos: Vector2,
	time_remaining: float,
	caliber: float,
	landing_dir: Vector2,
	threat_half_len: float
) -> void:
	_impl.add_incoming_shell(
		shell_id,
		landing_pos,
		time_remaining,
		caliber,
		landing_dir,
		threat_half_len
	)


func adjust_destination_for_threats(ship_pos: Vector2, destination: Vector2) -> Dictionary:
	return _impl.adjust_destination_for_threats(ship_pos, destination)


func set_threat_source(threat_registry: Variant, team_id: int, effective_radius: float) -> void:
	_impl.set_threat_source(threat_registry, team_id, effective_radius)


func clear_threat_source() -> void:
	_impl.clear_threat_source()


func get_rudder() -> float:
	return _impl.get_rudder()


func get_throttle() -> int:
	return _impl.get_throttle()


func get_nav_state() -> int:
	return _impl.get_nav_state()


func is_collision_imminent() -> bool:
	return _impl.is_collision_imminent()


func get_desired_heading() -> float:
	return _impl.get_desired_heading()


func get_clearance_radius() -> float:
	return _impl.get_clearance_radius()


func get_soft_clearance_radius() -> float:
	return _impl.get_soft_clearance_radius()


func get_current_waypoint() -> Vector3:
	return _impl.get_current_waypoint()


func get_current_path() -> PackedVector3Array:
	return _impl.get_current_path()


func get_simulated_path() -> PackedVector3Array:
	return _impl.get_simulated_path()


func get_predicted_trajectory() -> PackedVector3Array:
	return _impl.get_predicted_trajectory()


func get_debug_threat_clusters() -> Array:
	return _impl.get_debug_threat_clusters()


func get_debug_torpedo_threat_points() -> Array:
	return _impl.get_debug_torpedo_threat_points()


func get_timing_replan_reason() -> int:
	return _impl.get_timing_replan_reason()


func get_timing_plan_phase() -> int:
	return _impl.get_timing_plan_phase()


func get_timing_update_us() -> float:
	return _impl.get_timing_update_us()


func get_timing_avoidance_us() -> float:
	return _impl.get_timing_avoidance_us()


func get_timing_plan_us() -> float:
	return _impl.get_timing_plan_us()
