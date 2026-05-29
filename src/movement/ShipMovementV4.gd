extends Node
class_name ShipMovementV4

const SHIP_SPEED_MODIFIER: float = 2.0 # Adjust to calibrate ship speed display

var debug_log: bool = false

# All per-ship tunables live in MovementParams (Moddable). Assign a
# MovementParams subresource to `params` in the ship's .tscn.
@export var params: MovementParams

var max_speed: float = 15.0  # Maximum speed in m/s (derived at runtime from params)


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

var turning_drag_multiplier: float = 1.0
var grounded_drag_multiplier: float = 1.0
const BASE_DRAG: float = 0.3
enum __NavMode {
	NAV_MODE_IDLE,
	NAV_MODE_AVOID,
	NAV_MODE_FOLLOW,
	NAV_MODE_WAYPOINT,
	NAV_MODE_TARGET
}


func _ready() -> void:
	ship = $"../.." as RigidBody3D

	if ship == null:
		push_error("ShipMovementV4: Could not find RigidBody3D parent")
		return

	if params == null:
		push_error("ShipMovementV4: 'params' (MovementParams) is not set — assign a MovementParams subresource in the ship scene.")
		return
	params = params.instantiate(ship as Ship) as MovementParams

	_detect_ship_dimensions()

	# Set moderate damping to minimize unwanted physics effects without preventing top speed
	ship.linear_damp = BASE_DRAG
	# ship.angular_damp = 100 / (ship.mass * 1e-6) # convert to 1000 tons
	ship.angular_damp = 0.4

	# ship.axis_lock_angular_z = true
	# ship.axis_lock_angular_y = true
	# ship.axis_lock_angular_x = true

	# Convert max speed from knots to m/s (live, reflects current dynamic_mod)
	max_speed = _p().max_speed_knots * 0.514444 * SHIP_SPEED_MODIFIER

	# Enable contact monitoring to use get_colliding_bodies()
	ship.contact_monitor = true
	ship.max_contacts_reported = 4

## Returns the effective (modded) movement parameters.
func _p() -> MovementParams:
	return params.dynamic_mod as MovementParams

func get_params() -> MovementParams:
	return params.dynamic_mod as MovementParams

func get_base_params() -> MovementParams:
	return params.base as MovementParams

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
			var impulse = (ship.position - dict["point"])
			impulse.y = 0
			impulse = ship.mass * 30.0 * impulse.normalized()
			ship.apply_central_impulse(impulse)
			grounded_position = dict["point"]
			grounded_island = dict["collider"]
			break

	# Update grounded state
	if touching_land and not is_grounded:
		is_grounded = true
		# ship.linear_damp = 3.0
		grounded_drag_multiplier = 50.0
		engine_power = 0.0  # Immediately cut engine power
	elif not touching_land and is_grounded:
		is_grounded = false
		# ship.linear_damp = 0.3
		grounded_drag_multiplier = 1.0
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
	if node is MeshInstance3D and is_hull_mesh and not node.get_children().any(func(c): return c is ArmorPart):
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



func _physics_process(delta: float) -> void:
	if !(_Utils.authority()):
		return

	# Check for land collision
	_check_land_collision()

	# # Apply anisotropic hull drag (lateral drag much higher than forward drag)
	# _apply_hull_drag(delta)
	# Convert max speed from knots to m/s (live, reflects current dynamic_mod)
	max_speed = _p().max_speed_knots * 0.514444 * SHIP_SPEED_MODIFIER

	# Buoyancy (vertical)
	if ship.global_position.y < ship_draft:
		var submerged_ratio = clamp(ship_draft - ship.global_position.y, 0.0, ship_draft * 2.0) / ship_draft
		ship.apply_central_force(Vector3.UP * ship.mass * -ship.get_gravity() * submerged_ratio)

	# Self-righting buoyancy (roll and pitch stability)
	_apply_righting_moment(delta)

	# Thrust
	var target_power = throttle_settings[throttle_level + 1]

	# # Refresh derived top speed each tick so mods take effect.
	# max_speed = _p().max_speed_knots * 0.514444 * SHIP_SPEED_MODIFIER

	# Rudder
	rudder_input = move_toward(rudder_input, target_rudder, delta / _p().rudder_response_time)


	var forward = -ship.global_transform.basis.z.normalized()
	var current_speed: float = clamp(ship.linear_velocity.dot(forward), -max_speed, max_speed)

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
	var speed_ratio: float = clampf(abs(current_speed) / max_speed, 0.0, 1.0)
	if abs(rudder_input) > 0.01 and abs(current_speed) > 1.0:
		# Tighten radius at low speed — rudder has more leverage relative to forward momentum
		var max_speed_ratio: float = max_speed * (1.0 - abs(rudder_input) * _p().turn_speed_loss)
		speed_ratio = clampf(abs(current_speed) / max_speed_ratio, 0.0, 1.0)
		var radius_scale: float = lerpf(_p().slow_speed_turn_tightening, 1.0, speed_ratio)
		var effective_radius: float = _p().turning_circle_radius * radius_scale

		# Turn rate follows rudder directly — rudder_input is already the smooth signal
		# (via rudder_response_time); no secondary omega lag.
		var desired_omega: float = (current_speed / effective_radius) * -rudder_input

		# Directly assign yaw rate — zero lag between rudder position and turn rate.
		var av: Vector3 = ship.angular_velocity
		av.y = desired_omega
		ship.angular_velocity = av

		# Pivot the ship around its bow tip by setting the COM lateral velocity directly.
		# Derivation: v_COM = ω_vec × (COM − bow) = (0,ω,0) × (0,0,+L/2) = ω·(L/2)·flat_right
		# Result: bow translates only forward (zero lateral at tip), stern sweeps 2× COM lateral.
		# Drift scales with (speed/max_speed) so it is near-zero at low speed and full at max speed,
		# matching the hydrodynamic reality that hull side-resistance overpowers drift at slow speed.
		var drift_scale: float = clampf(abs(current_speed) / max_speed, 0.0, 1.0)
		var fwd_vel: Vector3 = forward * ship.linear_velocity.dot(forward)
		var vert_vel: Vector3 = Vector3.UP * ship.linear_velocity.y
		ship.linear_velocity = fwd_vel + flat_right * desired_omega * (ship_length * 0.5) * drift_scale + vert_vel

		turning_drag_multiplier = 1.0 + _p().turn_speed_loss * abs(rudder_input) * 1.5
	else:
		turning_drag_multiplier = 1.0
	var rudder_loss := (1.0 - absf(rudder_input) * _p().turn_speed_loss if target_power > engine_power else 1.0 + absf(rudder_input) * _p().turn_speed_loss * speed_ratio)
	engine_power = move_toward(engine_power, target_power, delta / _p().acceleration_time * rudder_loss)
	ship.linear_damp = BASE_DRAG * grounded_drag_multiplier * turning_drag_multiplier

	# Apply forward thrust
	ship.apply_force(forward * engine_power * max_speed * ship.mass * turn_thrust_ratio * 0.4, -forward.normalized() * ship_length * 0.4)

	# Apply turn-induced roll
	_apply_turn_roll(delta, current_speed, right)

	ship.rotation.z = clamp(ship.rotation.z, -deg_to_rad(_p().max_turn_roll_angle + 2.0), deg_to_rad(_p().max_turn_roll_angle + 2.0))
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


## Applies anisotropic drag - ships resist sideways motion much more than forward motion
## because the hull is long and narrow. This prevents excessive drift during turns.
func _apply_hull_drag(_delta: float) -> void:
	var forward = -ship.global_transform.basis.z.normalized()
	var flat_right = forward.cross(Vector3.UP).normalized()

	# Decompose velocity into forward and lateral components
	var velocity = ship.linear_velocity
	var _forward_speed = velocity.dot(forward)
	var lateral_speed = velocity.dot(flat_right)

	# Apply extra drag force only to the lateral (sideways) component
	# The base linear_damp already handles uniform drag, so we add the difference
	# F_drag = -lateral_drag_multiplier * linear_damp * lateral_velocity
	var extra_lateral_drag = _p().lateral_drag_multiplier * ship.linear_damp
	var lateral_drag_force = -flat_right * lateral_speed * extra_lateral_drag * ship.mass
	ship.apply_central_force(lateral_drag_force)

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
	var roll_righting_torque = -roll_angle * _p().righting_strength * ship.mass * abs(ship.get_gravity().y)
	roll_righting_torque -= local_angular_vel.z * _p().righting_damping * ship.mass

	# Righting torque for pitch (around local X axis)
	var pitch_righting_torque = pitch_angle * _p().pitch_righting_strength * ship.mass * abs(ship.get_gravity().y) * ship_length / 2.0
	pitch_righting_torque -= local_angular_vel.x * _p().righting_damping * ship.mass

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
	var target_roll_deg = -rudder_input * _p().max_turn_roll_angle * speed_factor

	# Smooth transition to target roll
	current_turn_roll = move_toward(current_turn_roll, target_roll_deg, delta * _p().max_turn_roll_angle / _p().roll_response_time)

	# Apply as a torque that fights against the righting moment
	# This creates a dynamic equilibrium where the ship settles at an angle during turns
	var roll_rad = deg_to_rad(current_turn_roll)
	var forward = -ship.global_transform.basis.z

	# Apply torque around the forward axis to induce roll
	var turn_roll_torque = forward * roll_rad * _p().righting_strength * ship.mass * abs(ship.get_gravity().y) * 0.5
	ship.apply_torque(turn_roll_torque)
