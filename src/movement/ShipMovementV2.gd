extends Node
class_name ShipMovementV2

const SHIP_SPEED_MODIFIER: float = 2.0 # Adjust to calibrate ship speed display

# Direct movement properties
@export var max_speed_knots: float
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

# Internal state
var current_speed: float = 0.0
var target_speed: float = 0.0
var ship_body: RigidBody3D

# For compatibility with systems that might need thrust vector data
var thrust_vector: Vector3 = Vector3.ZERO

# Collision detection
var collision_override_timer: float = 0.0
var collision_override_duration: float = 0.5  # How long to let physics take over after collision

func _ready() -> void:
	ship_body = $"../.." as RigidBody3D

	if ship_body == null:
		push_error("ShipMovementV2: Could not find RigidBody3D parent")
		return

	# Set moderate damping to minimize unwanted physics effects without preventing top speed
	ship_body.linear_damp = 0.0
	ship_body.angular_damp = 0.0

	# Connect to collision signals to detect when physics should take over
	if ship_body.has_signal("body_entered"):
		ship_body.body_entered.connect(_on_collision)

	# Convert max speed from knots to m/s
	max_speed = max_speed_knots * 0.514444 * SHIP_SPEED_MODIFIER

func _on_collision(_body):
	# Immediately stop the ship's internal speed for instant response
	current_speed = 0.0
	target_speed = 0.0
	print("Collision detected - stopping ship movement control")

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

	# if ship_body.global_position.y > 1.0:
	# 	# Ship is airborne - let physics handle it
	# 	var dir_to_move = ship_body.global_basis.z
	# 	ship_body.linear_velocity = dir_to_move * 10.0 * ship_body.global_position.y - Vector3.UP * ship_body.global_position.y

	# 	return

	# Check for sudden velocity changes (collision detection)
	var forward_dir = -ship_body.global_transform.basis.z
	var actual_forward_speed = forward_dir.dot(ship_body.linear_velocity)

	# If we're moving forward but actual speed is much less, we likely hit something
	if current_speed > 1.0 and abs(actual_forward_speed) < current_speed * 0.3:
		# Sudden stop detected - likely collision
		current_speed = 0.0
		target_speed = 0.0
		collision_override_timer = collision_override_duration

	# Update collision timer
	if collision_override_timer > 0.0:
		collision_override_timer -= delta
		return  # Let physics handle movement during collision

	# Smooth rudder movement
	rudder_input = move_toward(rudder_input, target_rudder, delta / rudder_response_time)

	# Calculate target speed from throttle
	_update_target_speed()

	# Update current speed with acceleration/deceleration
	_update_current_speed(delta)

	# Apply movement
	_apply_movement(delta)


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
		current_speed = target_speed
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

func _apply_movement(_delta: float) -> void:
	# Get current ship orientation
	var forward_dir = -ship_body.global_transform.basis.z

	# Get current forward speed
	var current_forward_velocity = forward_dir.dot(ship_body.linear_velocity)

	# Calculate desired velocity
	var desired_velocity = forward_dir * current_speed

	# Apply turning if moving
	if abs(current_speed) > 0.1 and abs(rudder_input) > 0.01:
		_apply_turning()

	# Use a hybrid approach: direct velocity setting with force assistance
	if abs(current_forward_velocity - current_speed) > 0.5:
		# If there's a significant difference, apply force to reach target speed
		var speed_error = current_speed - current_forward_velocity
		var force_magnitude = speed_error * ship_body.mass * 2.0
		ship_body.apply_central_force(forward_dir * force_magnitude)
	else:
		# When close to target speed, set velocity directly for precision
		ship_body.linear_velocity = desired_velocity

	# Store thrust vector for compatibility (represents desired movement direction and magnitude)
	thrust_vector = desired_velocity * ship_body.mass

	# # Apply additional resistance to prevent sliding
	# _apply_drift_resistance()

func _apply_turning() -> void:
	# Calculate turn rate based on current speed and turning circle
	var speed_factor = min(abs(current_speed) / min_turn_speed, 1.0)

	# Calculate angular velocity based on turning circle radius
	# At full speed and full rudder, ship should turn in a circle of radius turning_circle_radius
	# Angular velocity = linear velocity / radius
	var effective_speed = abs(current_speed) * speed_factor
	var angular_velocity_rad = 0.0

	if turning_circle_radius > 0.1:  # Prevent division by zero
		# Maximum angular velocity when at full rudder and full speed
		angular_velocity_rad = effective_speed / turning_circle_radius

	# Apply rudder input scaling (invert for correct steering direction)
	angular_velocity_rad *= -rudder_input

	# If moving backward, invert turning direction
	if current_speed < 0:
		angular_velocity_rad = -angular_velocity_rad

	# Apply rotation
	ship_body.angular_velocity = Vector3(0, angular_velocity_rad, 0)

func _apply_drift_resistance() -> void:
	# Get side velocity (drift)
	var right_dir = ship_body.global_transform.basis.x
	var side_velocity = right_dir.dot(ship_body.linear_velocity)

	# Apply resistance to side movement to prevent unrealistic sliding
	# Only apply if there's significant side velocity
	if abs(side_velocity) > 0.5:
		var resistance_force = -right_dir * side_velocity * ship_body.mass * 3.0
		ship_body.apply_central_force(resistance_force)

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
		"can_reverse_immediately": collision_override_timer > 0.0 and current_speed == 0.0
	}

# Emergency stop function
func emergency_stop() -> void:
	throttle_level = 0
	target_speed = 0.0
	current_speed = 0.0
	ship_body.linear_velocity = Vector3.ZERO
	ship_body.angular_velocity = Vector3.ZERO
