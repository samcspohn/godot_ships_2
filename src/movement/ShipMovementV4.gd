extends Node
class_name ShipMovementV4

const SHIP_SPEED_MODIFIER: float = 2.0 # Adjust to calibrate ship speed display

var debug_log: bool = false

# Direct movement properties
@export var max_speed_knots: float
var max_speed: float = 15.0  # Maximum speed in m/s
@export var acceleration_time: float = 8.0  # Time to reach full speed from stop
@export var deceleration_time: float = 4.0  # Time to stop from full speed
@export var reverse_speed_ratio: float = 0.5  # Reverse speed as ratio of max speed

# Turning properties
@export var turning_circle_radius: float = 200.0  # Turning circle radius in meters at full rudder and full speed
# @export var min_turn_speed: float = 2.0  # Minimum speed needed for effective turning
@export var turn_speed_loss: float = 0.2  # Percentage of speed lost per second while turning
@export var rudder_response_time: float = 1.5  # Time for rudder to move from center to full

# Roll and stability properties
@export var max_turn_roll_angle: float = 5.0  # Maximum roll angle in degrees when turning at full speed/rudder
@export var roll_response_time: float = 2.0  # How quickly the ship rolls into a turn
@export var righting_strength: float = 5.0  # How strongly the ship rights itself (metacentric height factor)
@export var righting_damping: float = 3.0  # Damping to prevent oscillation
@export var pitch_righting_strength: float = 8.0  # Pitch stability (higher to counteract thrust offset)

# Ship control variables
var throttle_level: int = 0  # -1 = reverse, 0 = stop, 1-4 = forward speeds
var throttle_settings: Array = [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0]  # reverse, stop, 1/4, 1/2, 3/4, full
var rudder_input: float = 0.0  # -1.0 to 1.0
var target_rudder: float = 0.0

# Internal state
# var current_speed: float = 0.0
# var target_speed: float = 0.0
var engine_power: float = 0.0
var ship: RigidBody3D

# For compatibility with systems that might need thrust vector data
var thrust_vector: Vector3 = Vector3.ZERO

# Collision detection
var collision_override_timer: float = 0.0
var collision_override_duration: float = 0.5  # How long to let physics take over after collision

var ship_length: float = 0.0
var ship_draft: float = 0.0
var ship_beam: float = 0.0
var ship_height: float = 0.0

# Roll state for smooth transitions
var current_turn_roll: float = 0.0  # Current roll induced by turning

# Grounded state - ship is touching land
var is_grounded: bool = false
var grounded_position: Variant = null
var grounded_island: Node3D = null

enum __NavMode {
	NAV_MODE_IDLE,
	NAV_MODE_AVOID,
	NAV_MODE_FOLLOW,
	NAV_MODE_WAYPOINT,
	NAV_MODE_TARGET
}

enum NavSize {
	NAV_LIGHT,
	NAV_MEDIUM,
	NAV_HEAVY,
	NAV_SUPERHEAVY,
	NAV_ULTRAHEAVY
}

@export var nav_size: NavSize = NavSize.NAV_MEDIUM

func _ready() -> void:
	ship = $"../.." as RigidBody3D

	if ship == null:
		push_error("ShipMovementV4: Could not find RigidBody3D parent")
		return

	_detect_ship_dimensions()

	# Set moderate damping to minimize unwanted physics effects without preventing top speed
	ship.linear_damp = 0.2
	# ship.angular_damp = 100 / (ship.mass * 1e-6) # convert to 1000 tons
	ship.angular_damp = 0.4

	# ship.axis_lock_angular_z = true
	# ship.axis_lock_angular_y = true
	# ship.axis_lock_angular_x = true

	# Convert max speed from knots to m/s
	max_speed = max_speed_knots * 0.514444 * SHIP_SPEED_MODIFIER

	# Enable contact monitoring to use get_colliding_bodies()
	ship.contact_monitor = true
	ship.max_contacts_reported = 4

func _detect_ship_dimensions() -> void:
	var hull_aabb: AABB = AABB()
	var found_aabb: bool = false

	# Check if parent has aabb property (Ship class)
	if ship and ship.get("aabb") != null:
		hull_aabb = ship.aabb
		if hull_aabb.size != Vector3.ZERO:
			found_aabb = true

	# Fallback: search for hull meshes and calculate AABB
	if not found_aabb:
		hull_aabb = _calculate_hull_aabb_from_meshes(ship)
		if hull_aabb.size != Vector3.ZERO:
			found_aabb = true

	if found_aabb:
		ship_length = hull_aabb.size.z
		ship_beam = hull_aabb.size.x
		ship_height = hull_aabb.size.y
		# Draft is distance from origin (waterline) to bottom of hull
		ship_draft = -hull_aabb.position.y

		print("ShipMovementV4: Length=%.1f, Beam=%.1f, Height=%.1f, Draft=%.1f" % [ship_length, ship_beam, ship_height, ship_draft])
	else:
		push_warning("ShipMovementV4: Could not detect ship dimensions, using defaults")

func get_contacts() -> Array[Dictionary]:
	return ship.last_contacts if ship else []

# Check for land collision using get_colliding_bodies()
func _check_land_collision() -> void:
	# var colliding_bodies = ship.get_colliding_bodies()
	var colliding_bodies = get_contacts()

	# Check each colliding body to see if we're touching land
	var touching_land := false
	for dict in colliding_bodies:
		var body = dict["collider"]
		# print(body.name)
		# if body.has:
			# Check if this is land (collision layer 1)
		if body.collision_layer & 1:
			touching_land = true
			ship.apply_central_impulse(ship.mass * 0.5 * (ship.position - dict["point"]).normalized())
			grounded_position = dict["point"]
			grounded_island = dict["collider"]
			break

	# Update grounded state
	if touching_land and not is_grounded:
		is_grounded = true
		ship.linear_damp = 3.0
		engine_power = 0.0  # Immediately cut engine power
	elif not touching_land and is_grounded:
		is_grounded = false
		ship.linear_damp = 0.2
		grounded_position = null
		grounded_island = null

func _calculate_hull_aabb_from_meshes(root: Node) -> AABB:
	var result: Dictionary = {"aabb": AABB(), "found": false}
	_collect_mesh_aabb_recursive(root, result)
	return result["aabb"]

func _collect_mesh_aabb_recursive(node: Node, result: Dictionary) -> void:
	var node_name_lower = node.name.to_lower()
	var is_hull_mesh = (
		node_name_lower.contains("hull") or
		node_name_lower.contains("bow") or
		node_name_lower.contains("stern") or
		node_name_lower.contains("casemate") or
		node_name_lower.contains("citadel")
	)
	var is_armor_col = node_name_lower.ends_with("_col")

	if node is MeshInstance3D and is_hull_mesh and not is_armor_col:
		var mesh_instance = node as MeshInstance3D
		var mesh_aabb = mesh_instance.get_aabb()
		var transformed_aabb = mesh_instance.transform * mesh_aabb

		if not result["found"]:
			result["aabb"] = transformed_aabb
			result["found"] = true
		else:
			result["aabb"] = result["aabb"].merge(transformed_aabb)

	for child in node.get_children():
		_collect_mesh_aabb_recursive(child, result)

func set_movement_input(input_array: Array) -> void:
	# Expect [throttle, rudder]
	if input_array.size() >= 2:
		throttle_level = clamp(int(input_array[0]), -1, 4)
		target_rudder = clamp(float(input_array[1]), -1.0, 1.0)

func calculate_lateral_force(
	mass: float,
	length: float,  # ship length for inertia estimate
	turning_circle: float,
	fulcrum_offset: float,
	angular_damping: float,
	current_omega: float,
	target_omega: float,
	dt: float
) -> float:
	var I := (1.0 / 12.0) * mass * length * length
	var alpha := (target_omega - current_omega) / dt  # desired angular accel

	# Force needed at fulcrum to achieve desired alpha while fighting damping
	var F_lateral := (I * alpha + angular_damping * current_omega) / fulcrum_offset

	return F_lateral

func _physics_process(delta: float) -> void:
	if !(_Utils.authority()):
		return

	# Check for land collision
	_check_land_collision()

	# Buoyancy (vertical)
	if ship.global_position.y < ship_draft:
		var submerged_ratio = (ship_draft - ship.global_position.y) / ship_draft
		ship.apply_central_force(Vector3.UP * ship.mass * -ship.get_gravity() * submerged_ratio)

	# Self-righting buoyancy (roll and pitch stability)
	_apply_righting_moment(delta)

	# Thrust
	var target_power = throttle_settings[throttle_level + 1]

	# Rudder
	rudder_input = move_toward(rudder_input, target_rudder, delta / rudder_response_time)


	var forward = -ship.global_transform.basis.z.normalized()
	var current_speed: float = ship.linear_velocity.length() * sign(ship.linear_velocity.dot(forward))
	var right = ship.global_transform.basis.x
	var up = ship.global_transform.basis.y
	var flat_right = forward.cross(Vector3.UP)

	# Don't apply thrust if grounded
	if is_grounded:
		print("Grounded")
		engine_power = move_toward(engine_power, 0.0, delta * 0.5)
		# Still allow some movement to "unstick" if player reverses
		# if throttle_level == -1:  # Reverse
		# 	var reverse_force = forward * -0.1 * max_speed * ship.mass
		# 	ship.apply_central_force(reverse_force)
		# return

	var turn_thrust_ratio = 1.0
	if abs(rudder_input) > 0.01 and abs(current_speed) > 2.0:
		var rudder_dist = 0.5
		var half_length = ship_length * rudder_dist
		var stern_offset = -forward * half_length  # Vector from center to stern
		# Initiation: target_omega derived from desired turn
		var turn_radius := turning_circle_radius
		var target_omega: float = max_speed * (1 - turn_speed_loss * abs(rudder_input)) / turn_radius * -rudder_input  # full rudder turn rate
		var target_omega_curr: float = current_speed / turn_radius * -rudder_input
		var weight = 0.8
		target_omega = target_omega_curr * weight + target_omega * (1 - weight)
		var fulcrum_offset = -half_length

		var F := calculate_lateral_force(ship.mass, ship_length, turning_circle_radius * 2.0,
										  fulcrum_offset, ship.angular_damp,
										  ship.angular_velocity.y, target_omega, delta)
		ship.apply_force(-flat_right * F, stern_offset)
		engine_power = move_toward(engine_power, target_power * (1 - turn_speed_loss * abs(rudder_input)), delta / acceleration_time)
	else:
		engine_power = move_toward(engine_power, target_power, delta / acceleration_time)

	# Apply forward thrust
	ship.apply_force(forward * engine_power * max_speed * ship.mass * turn_thrust_ratio * 0.3, -forward.normalized() * ship_length * 0.4)

	# Apply turn-induced roll
	_apply_turn_roll(delta, current_speed, right)

	ship.rotation.z = clamp(ship.rotation.z, -deg_to_rad(max_turn_roll_angle + 2.0), deg_to_rad(max_turn_roll_angle + 2.0))
	ship.rotation.x = clamp(ship.rotation.x, -deg_to_rad(5), deg_to_rad(5))

	if debug_log and ship.name == "1" and Engine.get_physics_frames() % 16 == 0:
		print("Ship 1 Debug Info:")
		print("Current Speed:", get_current_speed_kmh(), "km/h")
		print("Current Speed (Knots):", get_current_speed_knots(), "knots")
		print("Actual Turning Radius:", get_actual_turning_radius(), "m")
		print("Throttle Percentage:", get_throttle_percentage(), "%")

# Utility functions for debugging and external access
func get_current_speed_kmh() -> float:
	return ship.linear_velocity.length() * 3.6

func get_current_speed_ms() -> float:
	return ship.linear_velocity.length()

func get_current_speed_knots() -> float:
	return ship.linear_velocity.length() * 1.9444

func get_actual_turning_radius() -> float:
	# Calculate the actual turning radius based on current speed and angular velocity
	if abs(ship.angular_velocity.y) < 0.001:
		return 0.0  # Not turning
	return abs(ship.linear_velocity.length()) / abs(ship.angular_velocity.y)

func get_throttle_percentage() -> float:
	if throttle_level >= -1 and throttle_level <= 4:
		return throttle_settings[throttle_level + 1] * 100.0
	return 0.0


## Applies a righting moment to keep the ship upright (simulates metacentric stability)
func _apply_righting_moment(_delta: float) -> void:
	var current_up = ship.global_transform.basis.y
	var target_up = Vector3.UP
	var current_forward = -ship.global_transform.basis.z

	# Calculate roll angle (rotation around forward axis)
	var right_vector = current_forward.cross(Vector3.UP).normalized()
	var roll_angle = asin(clampf(current_up.dot(right_vector), -1.0, 1.0))

	# Calculate pitch angle (rotation around right axis)
	var pitch_angle = asin(clampf(-current_forward.dot(Vector3.UP), -1.0, 1.0))

	# Get local angular velocity components
	var local_angular_vel = ship.global_transform.basis.inverse() * ship.angular_velocity

	# Righting torque for roll (around local Z axis, which is forward)
	# This simulates the metacentric righting moment: GZ * displacement * g
	var roll_righting_torque = -roll_angle * righting_strength * ship.mass * abs(ship.get_gravity().y)
	roll_righting_torque -= local_angular_vel.z * righting_damping * ship.mass

	# Righting torque for pitch (around local X axis)
	var pitch_righting_torque = pitch_angle * pitch_righting_strength * ship.mass * abs(ship.get_gravity().y) * ship_length / 2.0
	pitch_righting_torque -= local_angular_vel.x * righting_damping * ship.mass

	# Apply torques in world space
	var world_roll_torque = current_forward * roll_righting_torque
	var world_pitch_torque = ship.global_transform.basis.x * pitch_righting_torque

	ship.apply_torque(world_roll_torque + world_pitch_torque)


## Applies roll induced by turning (ships lean outward due to centrifugal force)
func _apply_turn_roll(delta: float, current_speed: float, right: Vector3) -> void:
	# Calculate target roll based on turn rate and speed
	# Ships lean OUTWARD (away from turn) due to centrifugal force on the superstructure
	# The faster and tighter the turn, the more roll
	var speed_factor = clampf(current_speed / max_speed, 0.0, 1.0)
	var target_roll_deg = -rudder_input * max_turn_roll_angle * speed_factor

	# Smooth transition to target roll
	current_turn_roll = move_toward(current_turn_roll, target_roll_deg, delta * max_turn_roll_angle / roll_response_time)

	# Apply as a torque that fights against the righting moment
	# This creates a dynamic equilibrium where the ship settles at an angle during turns
	var roll_rad = deg_to_rad(current_turn_roll)
	var forward = -ship.global_transform.basis.z

	# Apply torque around the forward axis to induce roll
	var turn_roll_torque = forward * roll_rad * righting_strength * ship.mass * abs(ship.get_gravity().y) * 0.5
	ship.apply_torque(turn_roll_torque)
