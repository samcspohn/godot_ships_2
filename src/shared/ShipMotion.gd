extends RigidBody3D
class_name ShipMotion

# Physics properties
@export var speed: float = 5
@export var time_to_full_speed: float = 10.0  # Time in seconds to reach full speed from stop
@export var linear_damping: float = 1.0
@export var angular_damping: float = 3.0
@export var drift_coefficient: float = 0.85  # Lower values = more drift
@export var rudder_node: Node3D  # The physical rudder node where torque will be applied

# Ship movement variables
@export var rudder_shift_time: float = 2.0  # Time to move rudder from center to max
@export var turning_circle: float = 20.0  # Turning circle radius - sole factor for turn rate
var throttle_level: int = 0  # -1 = reverse, 0 = stop, 1-4 = forward speeds
var throttle_settings: Array = [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0]  # reverse, Stop, 1/4, 1/2, 3/4, full
var engine_power: float = 0.0
var rudder_value: float = 0.0  # -1.0 to 1.0
var target_rudder_value: float = 0.0

# Input received from player controller
var _input_array: Array = [0.0, 0.0]  # [throttle, rudder]
var _thrust_vector: Vector3 = Vector3(0,0,0)
var previous_position: Vector3

# Sync-related variables
var guns: Array[Gun] = []
var _aim_point: Vector3

# Debug visualization
var debug_mesh: ImmediateMesh
var debug_instance: MeshInstance3D

func _ready() -> void:
	previous_position = global_position
	
	# Set up RigidBody properties
	linear_damp = linear_damping
	angular_damp = angular_damping
	
	# Find all guns in the ship
	var gun_id = 0
	for ch in self.get_child(1).get_children():
		if ch is Gun:
			ch.gun_id = gun_id
			gun_id += 1
			self.guns.append(ch)
	
	# Setup debug visualization
	setup_debug_visualization()

func setup_debug_visualization() -> void:
	debug_mesh = ImmediateMesh.new()
	debug_instance = MeshInstance3D.new()
	debug_instance.mesh = debug_mesh
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(1, 0, 0)  # Red color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.CULL_BACK = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	material.render_priority = -100
	debug_instance.material_override = material
	get_tree().root.add_child(debug_instance)

func set_input(input_array: Array, aim_point: Vector3) -> void:
	_input_array = input_array
	_aim_point = aim_point

func draw_debug_arrow(start: Vector3, end: Vector3, color: Color) -> void:
	# Clear the existing mesh data
	debug_mesh.clear_surfaces()
	
	# Update the debug_instance position to match the starting point
	debug_instance.global_position = Vector3.ZERO
	
	# Create the arrow shaft
	debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	debug_mesh.surface_add_vertex(start)
	debug_mesh.surface_add_vertex(end)
	debug_mesh.surface_end()
	
	# Create an arrowhead
	var direction = (end - start).normalized()
	var arrowhead_length = (end - start).length() * 0.2  # 20% of arrow length
	
	# Create two vectors perpendicular to the arrow direction
	var up = Vector3(0, 1, 0)
	if abs(direction.dot(up)) > 0.99:
		up = Vector3(1, 0, 0)
	var perpendicular1 = direction.cross(up).normalized() * arrowhead_length * 0.5
	var perpendicular2 = direction.cross(perpendicular1).normalized() * arrowhead_length * 0.5
	
	# Create the arrowhead points
	var arrowhead_point1 = end - direction * arrowhead_length + perpendicular1
	var arrowhead_point2 = end - direction * arrowhead_length - perpendicular1
	var arrowhead_point3 = end - direction * arrowhead_length + perpendicular2
	var arrowhead_point4 = end - direction * arrowhead_length - perpendicular2
	
	# Draw the arrowhead lines
	debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	debug_mesh.surface_add_vertex(end)
	debug_mesh.surface_add_vertex(arrowhead_point1)
	debug_mesh.surface_add_vertex(end)
	debug_mesh.surface_add_vertex(arrowhead_point2)
	debug_mesh.surface_add_vertex(end)
	debug_mesh.surface_add_vertex(arrowhead_point3)
	debug_mesh.surface_add_vertex(end)
	debug_mesh.surface_add_vertex(arrowhead_point4)
	debug_mesh.surface_end()
	
	# Update the material color
	debug_instance.material_override.albedo_color = color

func _physics_process(delta: float) -> void:
	if !multiplayer.is_server():
		return
		
	previous_position = global_position
	
	# Server-side ship movement processing using _input_array
	self.throttle_level = int(_input_array[0])
	self.target_rudder_value = _input_array[1]
	
	# Gradually move rudder toward target value
	self.rudder_value = move_toward(self.rudder_value, target_rudder_value, delta / rudder_shift_time)
	
	# Get current speed in the forward direction
	var thrust_dir = -global_transform.basis.z
	var current_forward_speed = thrust_dir.dot(linear_velocity)
	
	# Calculate target speed based on throttle level and speed variable
	var target_speed = 0.0
	if throttle_level >= -1 and throttle_level <= 4:
		target_speed = throttle_settings[throttle_level + 1] * speed
	
	var target_engine_power = mass * target_speed
	var max_engine_power = mass * speed
	# Calculate acceleration needed to reach full speed in time_to_full_speed
	# var max_acceleration = target_speed / time_to_full_speed
	engine_power = move_toward(engine_power, target_engine_power, delta * max_engine_power / time_to_full_speed)
	
	# Calculate thrust force based on desired acceleration and ship mass
	var thrust_magnitude = engine_power
	var thrust_force = thrust_dir * thrust_magnitude
	
	# Apply thrust force
	apply_central_force(thrust_force)
	
	# Increase water resistance to slow ship down
	var velocity_squared = linear_velocity.length_squared()
	var resistance_dir = -linear_velocity.normalized()
	var resistance_force = resistance_dir * velocity_squared * linear_damping * 0.5
	apply_central_force(resistance_force)
	
	# Adjust drift correction
	var drift_velocity = linear_velocity - thrust_dir * current_forward_speed
	var drift_resistance = -drift_velocity * drift_coefficient * mass
	apply_central_force(drift_resistance)
	
	# Fix turning mechanics
	# Calculate turning torque based on rudder value and current speed
	var min_speed_for_turning = 0.5
	var effective_speed = max(abs(current_forward_speed), min_speed_for_turning)
	
	# Simplified turning calculation - directly relate torque to rudder and speed
	# Smaller turning circles should result in sharper turns (higher torque)
	var turn_factor = 2.0  # Base turn factor
	# Use inverse relationship with turning circle - smaller circles = more torque
	var turn_circle_factor = 90.0 / max(turning_circle / 2.0, 1.0)  # Prevent division by zero
	var torque_magnitude = rudder_value * effective_speed * turn_factor * turn_circle_factor * mass
	
	# Ensure we see some turning effect even at low speeds
	if abs(rudder_value) > 0.1:
		# Instead of applying torque at center, create a pivot point effect
		
		# 1. Get ship dimensions - assuming the bow is in the -Z direction from center
		var ship_length = 250.0  # Approximate length of ship, adjust as needed
		var pivot_offset = ship_length * 0.3  # Pivot point ~30% from bow
		
		# 2. Calculate bow and stern positions
		var bow_position = -global_transform.basis.z * (ship_length/2)
		var stern_position = global_transform.basis.z * (ship_length/2)
		
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
		var side_force = global_transform.basis.x * -turn_direction * force_magnitude
		
		# Apply additional force at stern to create pivot effect
		apply_force(side_force, stern_position)
		
		# Apply a smaller counter-force at bow to stabilize
		apply_force(-side_force * 0.3, bow_position)
	
	# Cap maximum velocity for safety
	if linear_velocity.length() > speed * 1.5:
		linear_velocity = linear_velocity.normalized() * speed * 1.5
	
	# Store thrust vector for visualization and sync
	_thrust_vector = thrust_force
	
	for g in guns:
		g._aim(_aim_point, delta)
	
	# Sync ship data to all clients
	sync_ship_data()

func sync_ship_data() -> void:
	var d = {'y': throttle_level, 't': _thrust_vector, 'r': rudder_value, 'b': global_basis, 'p': global_position, 'g': [], 's': []}
	for g in guns:
		d.g.append({'b': g.basis, 'c': g.barrel.basis})
	var secondaries = get_node("Secondaries")
	for s: Gun in secondaries.get_children():
		d.s.append({'b': s.basis,'c': s.barrel.basis})
		
	sync.rpc(d)

@rpc("any_peer", "call_remote")
func sync(d: Dictionary):
	self.global_position = d.p
	self.global_basis = d.b
	self.rudder_value = d.r
	self._thrust_vector = d.t
	self.throttle_level = d.y
	var i = 0
	for g in guns:
		g.basis = d.g[i].b
		g.barrel.basis = d.g[i].c
		i += 1
	var _s = get_node("Secondaries")
	i = 0
	for s: Gun in _s.get_children():
		s.basis = d.s[i].b
		s.barrel.basis = d.s[i].c
		i += 1

@rpc("any_peer", "call_remote")
func fire_gun(gun_id: int) -> void:
	if multiplayer.is_server() and gun_id < guns.size():
		guns[gun_id].fire()

@rpc("any_peer", "call_remote")
func fire_all_guns() -> void:
	if multiplayer.is_server():
		for gun in guns:
			if gun.reload >= 1.0:
				gun.fire()

@rpc("any_peer", "call_remote")
func fire_next_ready_gun() -> void:
	if multiplayer.is_server():
		for g in guns:
			if g.reload >= 1:
				g.fire()
				return
