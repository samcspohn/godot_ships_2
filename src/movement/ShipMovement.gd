extends Node
class_name ShipMovement

# Physics properties
@export var speed: float = 5
@export var time_to_full_speed: float = 10.0  # Time in seconds to reach full speed from stop
@export var linear_damping: float = 1.0
@export var angular_damping: float = 3.0
@export var drift_coefficient: float = 0.75  # Lower values = more drift

# Ship movement variables
@export var rudder_shift_time: float = 2.0  # Time to move rudder from center to max
@export var turning_circle: float = 20.0  # Turning circle radius - sole factor for turn rate
var throttle_level: int = 0  # -1 = reverse, 0 = stop, 1-4 = forward speeds
var throttle_settings: Array = [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0]  # reverse, Stop, 1/4, 1/2, 3/4, full
var engine_power: float = 0.0
var rudder_value: float = 0.0  # -1.0 to 1.0
var target_rudder_value: float = 0.0

# Movement data
var thrust_vector: Vector3 = Vector3(0,0,0)
@onready var ship_body: RigidBody3D = $"../.."

func _ready() -> void:
	#ship_body = get_parent() as RigidBody3D
	
	# Set up RigidBody properties
	ship_body.linear_damp = linear_damping
	ship_body.angular_damp = angular_damping

func set_movement_input(input_array: Array) -> void:
	# Expect [throttle, rudder]
	self.throttle_level = int(input_array[0])
	self.target_rudder_value = input_array[1]

func _physics_process(delta: float) -> void:
	if !(_Utils.authority()):
		return
		
	# Gradually move rudder toward target value
	self.rudder_value = move_toward(self.rudder_value, target_rudder_value, delta / rudder_shift_time)
	
	# Get current speed in the forward direction
	var thrust_dir = -ship_body.global_transform.basis.z
	var current_forward_speed = thrust_dir.dot(ship_body.linear_velocity)
	
	# Calculate target speed based on throttle level and speed variable
	var target_speed = 0.0
	if throttle_level >= -1 and throttle_level <= 4:
		target_speed = throttle_settings[throttle_level + 1] * speed
	
	var target_engine_power = ship_body.mass * target_speed
	var max_engine_power = ship_body.mass * speed
	engine_power = move_toward(engine_power, target_engine_power, delta * max_engine_power / time_to_full_speed)
	
	# Calculate thrust force based on desired acceleration and ship mass
	var thrust_magnitude = engine_power
	var thrust_force = thrust_dir * thrust_magnitude
	
	# Apply thrust force
	ship_body.apply_central_force(thrust_force)
	
	# Increase water resistance to slow ship down
	var velocity_squared = ship_body.linear_velocity.length_squared()
	var resistance_dir = -ship_body.linear_velocity.normalized()
	var resistance_force = resistance_dir * velocity_squared * linear_damping * 0.5
	ship_body.apply_central_force(resistance_force)
	
	# Adjust drift correction
	var drift_velocity = ship_body.linear_velocity - thrust_dir * current_forward_speed
	var drift_resistance = -drift_velocity * drift_coefficient * ship_body.mass
	ship_body.apply_central_force(drift_resistance)
	
	# Fix turning mechanics
	# Calculate turning torque based on rudder value and current speed
	var min_speed_for_turning = 0.5
	var effective_speed = max(abs(current_forward_speed), min_speed_for_turning)
	
	# Simplified turning calculation - directly relate torque to rudder and speed
	# Smaller turning circles should result in sharper turns (higher torque)
	var turn_factor = 2.0  # Base turn factor
	# Use inverse relationship with turning circle - smaller circles = more torque
	var turn_circle_factor = 90.0 / max(turning_circle / 2.0, 1.0)  # Prevent division by zero
	var torque_magnitude = rudder_value * effective_speed * turn_factor * turn_circle_factor * ship_body.mass
	
	# Ensure we see some turning effect even at low speeds
	if abs(rudder_value) > 0.1:
		# Instead of applying torque at center, create a pivot point effect
		
		# 1. Get ship dimensions - assuming the bow is in the -Z direction from center
		var ship_length = 250.0  # Approximate length of ship, adjust as needed
		
		# 2. Calculate bow and stern positions
		var bow_position = -ship_body.global_transform.basis.z * (ship_length/2)
		var stern_position = ship_body.global_transform.basis.z * (ship_length/2)
		
		# 3. Determine if ship is moving forward or backward
		var moving_backward = current_forward_speed < 0
		
		# 4. Apply forces to create rotation around bow
		var turn_direction = sign(rudder_value)
		
		# When moving backward, we need to invert the turning direction
		if moving_backward:
			turn_direction = -turn_direction
		
		# Calculate force magnitude
		var force_magnitude = abs(torque_magnitude) * 0.7
		
		# Apply side force - direction depends on movement direction
		var side_force = ship_body.global_transform.basis.x * -turn_direction * force_magnitude
		
		# Apply additional force at stern to create pivot effect
		ship_body.apply_force(side_force, stern_position)
		
		# Apply a smaller counter-force at bow to stabilize
		ship_body.apply_force(-side_force * 0.15, bow_position)
	
	# Cap maximum velocity for safety
	if ship_body.linear_velocity.length() > speed * 1.5:
		ship_body.linear_velocity = ship_body.linear_velocity.normalized() * speed * 1.5
	
	# Store thrust vector for visualization and sync
	thrust_vector = thrust_force
