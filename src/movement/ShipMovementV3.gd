extends Node
class_name ShipMovementV3

const SHIP_SPEED_MODIFIER: float = 2.0 # Adjust to calibrate ship speed display

# Direct movement properties
@export var max_speed_knots: float = 30.0
var max_speed: float = 15.0  # Maximum speed in m/s
@export var acceleration_time: float = 8.0  # Time to reach full speed from stop
@export var deceleration_time: float = 4.0  # Time to stop from full speed
@export var reverse_speed_ratio: float = 0.4  # Reverse speed as ratio of max speed

# Turning properties
@export var turning_circle_radius: float = 200.0  # Turning circle radius in meters at full rudder and full speed
@export var min_turn_speed: float = 2.0  # Minimum speed needed for effective turning

# Ship control variables
var throttle_level: int = 0  # -1 = reverse, 0 = stop, 1-4 = forward speeds
var throttle_settings: Array = [-1.0, 0.0, 0.25, 0.5, 0.75, 1.0]  # reverse, stop, 1/4, 1/2, 3/4, full
var rudder_input: float = 0.0  # -1.0 to 1.0
var target_rudder: float = 0.0
@export var rudder_response_time: float = 1.5  # Time for rudder to move from center to full

# Buoyancy properties
@export var water_level: float = 0.0  # Y coordinate of water surface
@export var water_density: float = 1025.0  # kg/m³ for seawater
@export var vertical_damping: float = 8.0  # Strong damping to prevent bouncing
@export var water_drag: float = 2.0  # Linear drag from water resistance
@export var water_angular_drag: float = 3.0  # Angular drag from water
var ship_draft: float = 5.0  # How deep the ship sits in water (auto-detected from AABB)
var ship_length: float = 150.0  # Length of ship (auto-detected from AABB)
var ship_beam: float = 20.0  # Width of ship (auto-detected from AABB)
var ship_height: float = 10.0  # Height of ship (auto-detected from AABB)
var submerged_volume_at_rest: float = 0.0  # Volume displaced when floating at rest

# Buoyancy point configuration
@export var buoyancy_points_longitudinal: int = 5  # Number of points along length
@export var buoyancy_points_lateral: int = 3  # Number of points across width
@export var buoyancy_point_depth: float = 3.0  # Depth of buoyancy points below ship origin

# Wave simulation (optional)
@export var enable_waves: bool = false
@export var wave_amplitude: float = 0.5
@export var wave_frequency: float = 0.5
@export var wave_speed: float = 2.0

# Internal state
var current_speed: float = 0.0
var target_speed: float = 0.0
var ship_body: RigidBody3D
var buoyancy_points: Array[Vector3] = []  # Local positions of buoyancy sample points

# For compatibility with systems that might need thrust vector data
var thrust_vector: Vector3 = Vector3.ZERO

# Collision detection
var collision_override_timer: float = 0.0
var collision_override_duration: float = 0.5  # How long to let physics take over after collision

# Engine power tracking for force-based movement
var engine_power: float = 0.0
var max_engine_power: float = 0.0

# Reference to parent ship for AABB access
var ship: Node = null

func _ready() -> void:
	ship_body = $"../.." as RigidBody3D

	if ship_body == null:
		push_error("ShipMovementV3: Could not find RigidBody3D parent")
		return

	# Get reference to parent ship
	ship = ship_body

	# Configure RigidBody for buoyancy simulation
	# We handle drag ourselves, so set engine damping to 0
	ship_body.linear_damp = 0.0
	ship_body.angular_damp = 0.0

	# Ensure gravity is enabled for buoyancy to work against
	ship_body.gravity_scale = 1.0

	# Connect to collision signals to detect when physics should take over
	if ship_body.has_signal("body_entered"):
		ship_body.body_entered.connect(_on_collision)

	# Convert max speed from knots to m/s
	max_speed = max_speed_knots * 0.514444 * SHIP_SPEED_MODIFIER

	# Calculate max engine power based on desired acceleration
	max_engine_power = ship_body.mass * max_speed / acceleration_time

	# Get ship dimensions from parent Ship's AABB
	_detect_ship_dimensions()

	# Generate buoyancy sample points
	_generate_buoyancy_points()

func _detect_ship_dimensions() -> void:
	# Try to get AABB from parent ship
	var hull_aabb: AABB = AABB()
	var found_aabb: bool = false

	# Check if parent has aabb property (Ship class)
	if ship and ship.get("aabb") != null:
		hull_aabb = ship.aabb
		if hull_aabb.size != Vector3.ZERO:
			found_aabb = true
			print("ShipMovementV3: Got AABB from ship.aabb: ", hull_aabb)

	# Fallback: search for hull meshes and calculate AABB
	if not found_aabb:
		hull_aabb = _calculate_hull_aabb_from_meshes(ship_body)
		if hull_aabb.size != Vector3.ZERO:
			found_aabb = true
			print("ShipMovementV3: Calculated AABB from meshes: ", hull_aabb)

	# Apply dimensions from AABB
	if found_aabb:
		ship_length = hull_aabb.size.z  # Z is forward/back
		ship_beam = hull_aabb.size.x    # X is left/right (beam)
		ship_height = hull_aabb.size.y  # Y is up/down

		# Draft is the distance from origin (waterline) to the lowest point of the hull
		# Since origin is at waterline, draft = -aabb.position.y (the bottom of the AABB)
		ship_draft = -hull_aabb.position.y  # Lowest point below origin

		# Set buoyancy point depth based on draft
		buoyancy_point_depth = ship_draft * 0.7  # Points at 70% of draft depth

		# Calculate the submerged volume at rest (approximating hull as a box for simplicity)
		# This is the volume that must be displaced to counter the ship's weight
		# At equilibrium: buoyancy = weight, so displaced_volume * water_density * g = mass * g
		submerged_volume_at_rest = ship_body.mass / water_density

		print("ShipMovementV3: Ship dimensions - Length: %.1f, Beam: %.1f, Height: %.1f, Draft: %.1f" % [ship_length, ship_beam, ship_height, ship_draft])
		print("ShipMovementV3: Submerged volume at rest: %.1f m³" % submerged_volume_at_rest)
	else:
		push_warning("ShipMovementV3: Could not detect ship dimensions, using defaults")

func _calculate_hull_aabb_from_meshes(root: Node) -> AABB:
	# Use a dictionary to pass by reference
	var result: Dictionary = {"aabb": AABB(), "found": false}

	_collect_mesh_aabb_recursive(root, result)

	return result["aabb"]

func _collect_mesh_aabb_recursive(node: Node, result: Dictionary) -> void:
	var node_name_lower = node.name.to_lower()

	# Check if this is a hull-related mesh
	var is_hull_mesh = (
		node_name_lower.contains("hull") or
		node_name_lower.contains("bow") or
		node_name_lower.contains("stern") or
		node_name_lower.contains("casemate") or
		node_name_lower.contains("citadel")
	)

	# Skip collision meshes
	var is_armor_col = node_name_lower.ends_with("_col")

	if node is MeshInstance3D and is_hull_mesh and not is_armor_col:
		var mesh_instance = node as MeshInstance3D
		var mesh_aabb = mesh_instance.get_aabb()

		# Transform AABB to parent space
		var transformed_aabb = mesh_instance.transform * mesh_aabb

		if not result["found"]:
			result["aabb"] = transformed_aabb
			result["found"] = true
		else:
			result["aabb"] = result["aabb"].merge(transformed_aabb)

	# Recurse into children
	for child in node.get_children():
		_collect_mesh_aabb_recursive(child, result)

func _generate_buoyancy_points() -> void:
	buoyancy_points.clear()

	var half_length = ship_length / 2.0
	var half_beam = ship_beam / 2.0

	# Generate a grid of buoyancy points
	for i in range(buoyancy_points_longitudinal):
		var z_ratio = float(i) / float(buoyancy_points_longitudinal - 1) if buoyancy_points_longitudinal > 1 else 0.5
		var z_pos = lerp(half_length, -half_length, z_ratio)

		for j in range(buoyancy_points_lateral):
			var x_ratio = float(j) / float(buoyancy_points_lateral - 1) if buoyancy_points_lateral > 1 else 0.5
			var x_pos = lerp(-half_beam, half_beam, x_ratio)

			# Points are below the ship's origin at the waterline
			buoyancy_points.append(Vector3(x_pos, -buoyancy_point_depth, z_pos))

	# Add corner points for stability
	buoyancy_points.append(Vector3(-half_beam, -buoyancy_point_depth, half_length))  # Bow port
	buoyancy_points.append(Vector3(half_beam, -buoyancy_point_depth, half_length))   # Bow starboard
	buoyancy_points.append(Vector3(-half_beam, -buoyancy_point_depth, -half_length)) # Stern port
	buoyancy_points.append(Vector3(half_beam, -buoyancy_point_depth, -half_length))  # Stern starboard

func _on_collision(_body):
	# Reduce speed on collision for instant response
	current_speed *= 0.5
	engine_power *= 0.5
	print("Collision detected - reducing ship movement control")

	# Let physics handle movement briefly after collision
	collision_override_timer = collision_override_duration

func set_movement_input(input_array: Array) -> void:
	# Expect [throttle, rudder]
	if input_array.size() >= 2:
		throttle_level = clamp(int(input_array[0]), -1, 4)
		target_rudder = clamp(float(input_array[1]), -1.0, 1.0)

func _physics_process(delta: float) -> void:
	if !(_Utils.authority()):
		return

	# Apply buoyancy forces
	_apply_buoyancy(delta)

	# Apply water drag
	_apply_water_drag(delta)

	# Check for sudden velocity changes (collision detection)
	var forward_dir = -ship_body.global_transform.basis.z
	var actual_forward_speed = forward_dir.dot(ship_body.linear_velocity)

	# If we're moving forward but actual speed is much less, we likely hit something
	if current_speed > 1.0 and abs(actual_forward_speed) < current_speed * 0.3:
		# Sudden stop detected - likely collision
		current_speed *= 0.5
		engine_power *= 0.5
		collision_override_timer = collision_override_duration

	# Update collision timer
	if collision_override_timer > 0.0:
		collision_override_timer -= delta
		# Still apply buoyancy but skip movement control
		return

	# Smooth rudder movement
	rudder_input = move_toward(rudder_input, target_rudder, delta / rudder_response_time)

	# Calculate target speed from throttle
	_update_target_speed()

	# Update current speed with acceleration/deceleration
	_update_current_speed(delta)

	# Apply thrust force
	_apply_thrust_force(delta)

	# Apply turning force
	_apply_turning_force(delta)

func _get_wave_height(world_pos: Vector3, time: float) -> float:
	if not enable_waves:
		return water_level

	# Simple wave function using sine waves
	var wave_offset = sin(world_pos.x * wave_frequency + time * wave_speed) * wave_amplitude
	wave_offset += sin(world_pos.z * wave_frequency * 0.7 + time * wave_speed * 1.3) * wave_amplitude * 0.5

	return water_level + wave_offset

func _apply_buoyancy(delta: float) -> void:
	var time = Time.get_ticks_msec() / 1000.0
	var gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

	# Calculate how far the ship's origin (designed waterline) is from the actual water surface
	var ship_waterline_y = ship_body.global_position.y
	var water_height = _get_wave_height(ship_body.global_position, time)

	# Displacement from equilibrium position (origin should be at water level)
	# Positive means ship is too high (needs more buoyancy to rise), negative means too low
	var depth_below_water = water_height - ship_waterline_y

	# At equilibrium (origin at water level), depth_below_water = 0 and we need buoyancy = weight
	# When ship rises above water (depth_below_water < 0), buoyancy should decrease
	# When ship sinks below water (depth_below_water > 0), buoyancy should increase

	# Calculate buoyancy multiplier based on position relative to equilibrium
	# At equilibrium: multiplier = 1.0 (buoyancy = weight)
	# The rate of change is based on draft - small displacement = small change
	var buoyancy_multiplier = 1.0 + (depth_below_water / ship_draft) if ship_draft > 0 else 1.0

	# Clamp to reasonable range (0 = fully out of water, 2 = deeply submerged)
	buoyancy_multiplier = clamp(buoyancy_multiplier, 0.0, 2.0)

	# Buoyancy force - at equilibrium exactly equals weight
	var weight = ship_body.mass * gravity
	var buoyancy_force_magnitude = weight * buoyancy_multiplier

	# Apply buoyancy as central force
	var buoyancy_force = Vector3.UP * buoyancy_force_magnitude
	ship_body.apply_central_force(buoyancy_force)

	# Apply strong vertical damping to prevent bouncing/oscillation
	var vertical_velocity = ship_body.linear_velocity.y
	var damping_force = -vertical_velocity * vertical_damping * ship_body.mass
	ship_body.apply_central_force(Vector3.UP * damping_force)

	# Apply tilting forces from buoyancy points for wave response and stability
	_apply_buoyancy_torque(time)

	# Apply a stabilizing force to keep the ship upright
	_apply_stabilization(delta)

func _apply_buoyancy_torque(time: float) -> void:
	var total_torque = Vector3.ZERO
	var gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var force_per_point = ship_body.mass * gravity / buoyancy_points.size()

	for local_point in buoyancy_points:
		# Convert local point to world position
		var world_point = ship_body.global_transform * local_point

		# Get water height at this point
		var water_height = _get_wave_height(world_point, time)

		# Calculate submersion depth at this point
		var submersion_depth = water_height - world_point.y

		if submersion_depth > 0:
			# Normalize submersion relative to draft for consistent force scaling
			var submersion_ratio = clamp(submersion_depth / ship_draft, 0.0, 2.0)

			# Force at this point
			var point_force = Vector3.UP * force_per_point * submersion_ratio

			# Calculate torque from this point
			var offset_from_center = world_point - ship_body.global_position
			total_torque += offset_from_center.cross(point_force)

	# Apply torque with reduced magnitude to prevent excessive tilting
	ship_body.apply_torque(total_torque * 0.05)

func _apply_stabilization(delta: float) -> void:
	# Get current up vector of the ship
	var ship_up = ship_body.global_transform.basis.y
	var world_up = Vector3.UP

	# Calculate the rotation needed to align ship up with world up
	var correction_axis = ship_up.cross(world_up)
	var correction_angle = ship_up.angle_to(world_up)

	if correction_axis.length() > 0.001 and correction_angle > 0.01:
		# Apply a corrective torque to stabilize the ship
		var stabilization_strength = 5.0
		var corrective_torque = correction_axis.normalized() * correction_angle * stabilization_strength * ship_body.mass
		ship_body.apply_torque(corrective_torque)

	# Dampen vertical angular velocity to prevent oscillation
	var angular_vel = ship_body.angular_velocity
	var pitch_roll_damping = Vector3(angular_vel.x, 0, angular_vel.z) * -2.0 * ship_body.mass
	ship_body.apply_torque(pitch_roll_damping)

func _apply_water_drag(_delta: float) -> void:
	# Get velocity components
	var velocity = ship_body.linear_velocity
	var forward_dir = -ship_body.global_transform.basis.z
	var right_dir = ship_body.global_transform.basis.x

	# Separate forward and lateral velocity
	var forward_speed = forward_dir.dot(velocity)
	var lateral_speed = right_dir.dot(velocity)

	# Lateral drag - ships resist sideways motion much more than forward
	if abs(lateral_speed) > 0.1:
		var lateral_drag = -right_dir * lateral_speed * water_drag * 3.0 * ship_body.mass
		ship_body.apply_central_force(lateral_drag)

	# Angular drag - opposes rotation
	var angular_velocity = ship_body.angular_velocity
	if angular_velocity.length() > 0.01:
		var angular_drag_torque = -angular_velocity * water_angular_drag * ship_body.mass
		ship_body.apply_torque(angular_drag_torque)

func _update_target_speed() -> void:
	if throttle_level >= -1 and throttle_level <= 4:
		var throttle_ratio = throttle_settings[throttle_level + 1]

		if throttle_ratio < 0:
			# Reverse
			target_speed = throttle_ratio * max_speed * reverse_speed_ratio
		else:
			# Forward or stop
			target_speed = throttle_ratio * max_speed

func _update_current_speed(delta: float) -> void:
	# If we just collided and want to reverse, allow immediate direction change
	if collision_override_timer > 0.0 and target_speed < 0 and current_speed >= 0:
		current_speed = target_speed * 0.5
		return

	if abs(target_speed - current_speed) < 0.1:
		current_speed = target_speed
		return

	var acceleration_rate: float

	if target_speed > current_speed:
		# Accelerating
		acceleration_rate = max_speed / acceleration_time
	else:
		# Decelerating
		acceleration_rate = max_speed / deceleration_time

	current_speed = move_toward(current_speed, target_speed, acceleration_rate * delta)

func _apply_thrust_force(_delta: float) -> void:
	# Get forward direction (-z is forward)
	var forward_dir = -ship_body.global_transform.basis.z

	# Get current forward speed
	var current_forward_speed = forward_dir.dot(ship_body.linear_velocity)

	# Simple approach: apply force to reach and maintain current_speed
	# Force = mass * acceleration needed
	var speed_error = current_speed - current_forward_speed

	# Strong force to correct speed error quickly
	# F = m * a, we want to correct the error within ~1 second
	engine_power = speed_error * ship_body.mass * 2.0

	# Clamp engine power to prevent excessive forces
	var max_force = ship_body.mass * max_speed / acceleration_time * 3.0
	engine_power = clamp(engine_power, -max_force, max_force)

	# Calculate thrust force
	var thrust_force = forward_dir * engine_power

	# Apply thrust as central force for simplicity and reliability
	ship_body.apply_central_force(thrust_force)

	# Store thrust vector for compatibility
	thrust_vector = thrust_force

func _apply_turning_force(delta: float) -> void:
	# Only turn if we're moving and rudder is engaged
	if abs(current_speed) < 0.1 or abs(rudder_input) < 0.01:
		return

	# Get current forward speed
	var forward_dir = -ship_body.global_transform.basis.z
	var forward_speed = forward_dir.dot(ship_body.linear_velocity)

	# Calculate speed factor - turning is less effective at very low speeds
	var speed_factor = clamp(abs(forward_speed) / min_turn_speed, 0.0, 1.0)

	# Calculate desired angular velocity based on turning circle
	# Angular velocity = linear velocity / radius
	var target_angular_velocity = 0.0
	if turning_circle_radius > 0.1:
		target_angular_velocity = abs(forward_speed) / turning_circle_radius

	# Apply rudder influence
	target_angular_velocity *= -rudder_input * speed_factor

	# Invert turning when going backwards
	if forward_speed < 0:
		target_angular_velocity = -target_angular_velocity

	# Calculate torque needed to achieve desired angular velocity
	# We want smooth transition, so apply force proportional to difference
	var current_yaw_rate = ship_body.angular_velocity.y
	var yaw_rate_error = target_angular_velocity - current_yaw_rate

	# Apply torque to achieve desired yaw rate
	var turn_torque = yaw_rate_error * ship_body.mass * 10.0
	ship_body.apply_torque(Vector3(0, turn_torque, 0))

	# Apply lateral force at the stern to simulate rudder effect
	var rudder_force_magnitude = abs(forward_speed) * abs(rudder_input) * ship_body.mass * 0.5
	var rudder_force_dir = ship_body.global_transform.basis.x * sign(rudder_input)

	# Invert rudder force when reversing
	if forward_speed < 0:
		rudder_force_dir = -rudder_force_dir

	# Stern is at +z in local space (since forward is -z)
	var stern_local_offset = Vector3(0, 0, ship_length / 2.0)
	ship_body.apply_force(rudder_force_dir * rudder_force_magnitude, stern_local_offset)

# Utility functions for debugging and external access
func get_current_speed_kmh() -> float:
	return current_speed * 3.6

func get_current_speed_knots() -> float:
	return current_speed * 1.944

func get_actual_turning_radius() -> float:
	# Calculate the actual turning radius based on current speed and angular velocity
	if abs(ship_body.angular_velocity.y) < 0.001:
		return 0.0  # Not turning
	return abs(current_speed) / abs(ship_body.angular_velocity.y)

func get_throttle_percentage() -> float:
	if throttle_level >= -1 and throttle_level <= 4:
		return throttle_settings[throttle_level + 1] * 100.0
	return 0.0

func get_movement_debug_info() -> Dictionary:
	var forward_dir = -ship_body.global_transform.basis.z
	var actual_forward_speed = forward_dir.dot(ship_body.linear_velocity)

	return {
		"throttle_level": throttle_level,
		"throttle_percentage": get_throttle_percentage(),
		"rudder_input": rudder_input,
		"target_speed": target_speed,
		"current_speed": current_speed,
		"actual_forward_speed": actual_forward_speed,
		"speed_kmh": get_current_speed_kmh(),
		"speed_knots": get_current_speed_knots(),
		"actual_turning_radius": get_actual_turning_radius(),
		"target_turning_radius": turning_circle_radius,
		"collision_override": collision_override_timer > 0.0,
		"collision_timer": collision_override_timer,
		"total_velocity": ship_body.linear_velocity.length(),
		"can_reverse_immediately": collision_override_timer > 0.0 and current_speed == 0.0,
		"engine_power": engine_power,
		"ship_height": ship_body.global_position.y,
		"buoyancy_points_count": buoyancy_points.size()
	}

# Emergency stop function
func emergency_stop() -> void:
	throttle_level = 0
	target_speed = 0.0
	current_speed = 0.0
	engine_power = 0.0
	ship_body.linear_velocity = Vector3.ZERO
	ship_body.angular_velocity = Vector3.ZERO
