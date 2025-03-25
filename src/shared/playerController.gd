extends RigidBody3D
class_name PlayerController

@export var speed: float = 5
@export var rotation_speed: float = 4
@export var rudder_node: Node3D  # The physical rudder node where torque will be applied
@export var time_to_full_speed: float = 10.0  # Time in seconds to reach full speed from stop
var _movementInput: Vector3
var _cameraInput: Vector2
@export var playerName: Label
var artillery_cam: ArtilleryCamera
var previous_position: Vector3

# Physics properties
# acceleration_force now calculated dynamically based on time_to_full_speed
@export var linear_damping: float = 1.0
@export var angular_damping: float = 3.0
@export var drift_coefficient: float = 0.85  # Lower values = more drift

var yaw: float = 0
var pitch: float = 0

var player_yaw: float = 0

var yaw_sensitivity: float = 0.07
var pitch_sensitivty: float = 0.07
var guns: Array[Gun] = []
var gun_reloads: Array[ProgressBar] = []
var ray: RayCast3D

# Timing variables
var double_click_timer: float = 0.3 # Maximum time between clicks to register as double click
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires
var last_click_time: float = 0.0 # Track time of last click for double click detection
var is_holding: bool = false # Track if mouse button is being held
var click_count: int = 0 # Track number of clicks for double click detection
var sequential_fire_timer: float = 0.0 # Timer for sequential firing

var view_port_size: Vector2i = Vector2i(0, 0)
func setName(_name: String):
	playerName.text = _name

var _input_array: Array = [0.0, 0.0, 0.0]  # [throttle, rudder, discrete_rudder_index]
var _aim_point: Vector3

@export var gravity_value = 9.8
#var gravity_value = ProjectSettings.get_setting("physics/3d/default_gravity", gravity)

func setColor(_color: Color):
	pass
	#CanvasModulate = color
	#modulate = color

# Ship movement variables
@export var rudder_shift_time: float = 2.0  # Time to move rudder from center to max
@export var turning_circle: float = 20.0  # Turning circle radius - sole factor for turn rate
var throttle_level: int = 0  # -1 = reverse, 0 = stop, 1-4 = forward speeds
var rudder_value: float = 0.0  # -1.0 to 1.0
var throttle_settings: Array = [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0]  # reverse, Stop, 1/4, 1/2, 3/4, full
var current_thrust: float = 0.0 # Current thrust value

# Discrete rudder settings
var discrete_rudder_positions: Array = [-1.0, -0.5, 0.0, 0.5, 1.0]
var discrete_rudder_index: int = 2  # Start at 0.0 (middle index)
var rudder_mode: String = "continuous"  # "continuous" or "discrete"
var target_rudder_value: float = 0.0

var debug_mesh: ImmediateMesh = ImmediateMesh.new()
var debug_instance
var _thrust_vector: Vector3 = Vector3(0,0,0)

func _ready() -> void:
	previous_position = global_position
	
	# Set up RigidBody properties
	linear_damp = linear_damping
	angular_damp = angular_damping
	
	var gun_id = 0
	for ch in self.get_child(1).get_children():
		if ch is Gun:
			ch.gun_id = gun_id
			gun_id += 1
			self.guns.append(ch)
	if name.to_int() != multiplayer.get_unique_id():
		return
	artillery_cam = load("res://scenes/player_cam.tscn").instantiate()
	artillery_cam.target_ship = self
	artillery_cam.projectile_speed = guns[0].shell.speed
	#artillery_cam.

	get_tree().root.add_child(artillery_cam)
	#add_child(artillery_cam)
	# var c: Node3D = cam_boom_pitch.get_child(0)
	var canvas: CanvasLayer = artillery_cam.get_child(1)
	#time_to_target = canvas.get_node("CenterContainer/VBoxContainer/TimeToTarget")
	for g in guns:
		var progress_bar: ProgressBar = canvas.get_node("ProgressBar").duplicate()
		progress_bar.visible = true
		progress_bar.show_percentage = false
		progress_bar.max_value = 1.0
		canvas.add_child(progress_bar)
		gun_reloads.append(progress_bar)
	self.ray = artillery_cam.get_child(0)
	
	var num_guns = guns.size()
	var viewport_size = get_viewport().size
	var y_pos = viewport_size.y * 0.75
	var w = 60
	var spc = 10
	var total_width = (w * num_guns) + (spc * (num_guns - 1))
	
	var start = (viewport_size.x - total_width) / 2.0
	
	for p in range(num_guns):
		var x = start + (p * (w + spc))
		gun_reloads[p].position = Vector2(x, y_pos)
		gun_reloads[p].custom_minimum_size = Vector2(w, 8)
		gun_reloads[p].size = Vector2(w, 8)
	
	# Add a MeshInstance3D to the scene for debug drawing
	debug_instance = MeshInstance3D.new()
	debug_instance.mesh = debug_mesh
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(1, 0, 0)  # Red color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.CULL_BACK = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true  # Draw on top of everything
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	material.render_priority = -100
	debug_instance.material_override = material
	get_tree().root.add_child(debug_instance)
	#add_child(debug_instance)
		
		
func _input(event: InputEvent):
	if name.to_int() == multiplayer.get_unique_id():
		if event is InputEventKey:
			var horizontal = 1 if Input.is_key_pressed(KEY_A) else 0 - 1 if Input.is_key_pressed(KEY_D) else 0
			var vertical = 1 if Input.is_key_pressed(KEY_W) else 0 - 1 if Input.is_key_pressed(KEY_S) else 0
			_movementInput = Vector3(horizontal, 0, vertical).normalized()
		elif event is InputEventMouseMotion:
			_cameraInput = event.relative
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Mouse button pressed
				is_holding = true
				sequential_fire_timer = 0.0
				
				# Handle click counting for double click detection
				var current_time = Time.get_ticks_msec() / 1000.0
				if current_time - last_click_time < double_click_timer:
					click_count = 2
					handle_double_click.rpc_id(1)
				else:
					click_count = 1
					handle_single_click.rpc_id(1)
				
				last_click_time = current_time
			else:
				# Mouse button released
				is_holding = false

@rpc("any_peer", "call_remote", "reliable")
func send_input(input_array: Array, aim_point: Vector3):
	if multiplayer.is_server():
		_input_array = input_array
		_aim_point = aim_point
	
@rpc("any_peer", "call_remote")
func sync(d: Dictionary):
	#print(name)
	#print(d)
	self.global_position = d.p
	self.global_basis = d.b
	self.rudder_value = d.r
	self._thrust_vector = d.t
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
		

func calculate_segment_endpoints(circle_center: Vector2, radius: float, segment_length: float) -> Array:
	# Calculate the angle subtended by the segment at the circle's center
	var angle = 2.0 * asin(segment_length / (2.0 * radius))

	# Calculate the endpoints of the segment
	var start_point = circle_center + Vector2(cos(-angle / 2.0), sin(-angle / 2.0)) * radius
	var end_point = circle_center + Vector2(cos(angle / 2.0), sin(angle / 2.0)) * radius

	return [start_point, end_point]

func calculate_tangent(circle_center: Vector2, radius: float, point: Vector2) -> Vector2:
	# Ensure the point lies on the circle
	if not is_point_on_circle(circle_center, radius, point):
		return Vector2.ZERO

	# The tangent vector is perpendicular to the radius vector
	var radius_vector = point - circle_center
	var tangent_vector = Vector2(-radius_vector.y, radius_vector.x)  # Rotate 90 degrees counterclockwise
	return tangent_vector.normalized()

func is_point_on_circle(circle_center: Vector2, radius: float, point: Vector2) -> bool:
	return abs((point - circle_center).length() - radius) < 0.001


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
	if name.to_int() == multiplayer.get_unique_id():
		for i in range(guns.size()):
			gun_reloads[i].value = guns[i].reload
		
		# Client-side input collection
		# Handle throttle input
		if Input.is_action_just_pressed("move_forward"):  # W key
			self.throttle_level = min(self.throttle_level + 1, 4)  # Max is 4 (full speed)
		elif Input.is_action_just_pressed("move_back"):   # S key
			self.throttle_level = max(self.throttle_level - 1, -1)  # Min is -1 (reverse)
		
		# Handle discrete rudder input with Q and E
		if Input.is_action_just_pressed("ui_q"):  # Q key
			rudder_mode = "discrete"
			self.discrete_rudder_index = max(self.discrete_rudder_index - 1, 0)
			target_rudder_value = discrete_rudder_positions[self.discrete_rudder_index]
		elif Input.is_action_just_pressed("ui_e"):  # E key
			rudder_mode = "discrete"
			self.discrete_rudder_index = min(self.discrete_rudder_index + 1, discrete_rudder_positions.size() - 1)
			target_rudder_value = discrete_rudder_positions[self.discrete_rudder_index]
		
		# Handle continuous rudder input with A and D
		if Input.is_action_pressed("move_left"):  # A key
			rudder_mode = "continuous"
			target_rudder_value = -1.0
			self.discrete_rudder_index = 2
		elif Input.is_action_pressed("move_right"):  # D key
			rudder_mode = "continuous"
			target_rudder_value = 1.0
			self.discrete_rudder_index = 2
		elif rudder_mode == "continuous":
			target_rudder_value = 0.0
	
		# Create input array: [throttle, rudder, discrete_rudder_index]
		var input_array = [float(self.throttle_level), target_rudder_value]
		
		var aim_point
		if ray.is_colliding():
			aim_point = ray.get_collision_point()
		else:
			aim_point = ray.global_position + Vector3(ray.global_basis.z.x,0,ray.global_basis.z.z).normalized() * -50000
		
		# Send input to server
		send_input.rpc_id(1, input_array, aim_point)
		
		# draw_debug_arrow(rudder_node.global_position, rudder_node.global_position + _thrust_vector, Color(1,0,0))
		
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
	
	# Calculate acceleration needed to reach full speed in time_to_full_speed
	var max_acceleration = speed / time_to_full_speed
	
	# Calculate thrust force based on desired acceleration and ship mass
	# Reduced force multiplier to slow down movement
	var thrust_magnitude = mass * max_acceleration * throttle_settings[throttle_level + 1] * 10.0
	var thrust_force = thrust_dir * thrust_magnitude
	
	# Apply thrust force
	apply_central_force(thrust_force)
	
	# Debug info
	# if throttle_level != 0:
	# 	print("Applied thrust: ", thrust_force.length(), " Direction: ", thrust_dir)
	# 	print("Current velocity: ", linear_velocity.length())
	# 	print("Rudder value: ", rudder_value, " Target rudder: ", target_rudder_value)
	
	# Increase water resistance to slow ship down
	var velocity_squared = linear_velocity.length_squared()
	var resistance_dir = -linear_velocity.normalized()
	var resistance_force = resistance_dir * velocity_squared * linear_damping * 0.05
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
			# to maintain consistent behavior (left rudder = counterclockwise rotation)
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
			
				# Debug output
			# print("Forward Speed: ", current_forward_speed)
			# print("Moving backward: ", moving_backward)
			# print("Rudder: ", rudder_value, " Turn Direction: ", turn_direction)
	
	# Cap maximum velocity for safety
	if linear_velocity.length() > speed * 1.5:
		linear_velocity = linear_velocity.normalized() * speed * 1.5
	
	# Store thrust vector for visualization and sync
	_thrust_vector = thrust_force
	
	for g in guns:
		g._aim(_aim_point, delta)
	
	var d = {'t': _thrust_vector, 'r': rudder_value, 'b': global_basis, 'p': global_position, 'g': [], 's': []}
	for g in guns:
		d.g.append({'b': g.basis, 'c': g.barrel.basis})
	var secondaries = get_node("Secondaries")
	for s: Gun in secondaries.get_children():
		d.s.append({'b': s.basis,'c': s.barrel.basis})
		
	sync.rpc(d)

func _process(dt):
	if name.to_int() != multiplayer.get_unique_id():
		return
		
	# Handle double click timer
	if click_count == 1:
		if Time.get_ticks_msec() / 1000.0 - last_click_time > double_click_timer:
			# Reset click count if double click timer expired
			click_count = 0
	
	# Handle sequential firing when holding
	if is_holding:
		sequential_fire_timer += dt
		if sequential_fire_timer >= sequential_fire_delay:
			sequential_fire_timer = 0.0
			fire_next_gun.rpc_id(1)
	
	if get_viewport().size != view_port_size:
		view_port_size = get_viewport().size
		var num_guns = guns.size()
		var viewport_size = get_viewport().size
		var y_pos = viewport_size.y * 0.75
		var w = 60
		var spc = 10
		var total_width = (w * num_guns) + (spc * (num_guns - 1))
		
		var start = (viewport_size.x - total_width) / 2.0
		
		for p in range(num_guns):
			var x = start + (p * (w + spc))
			gun_reloads[p].position = Vector2(x, y_pos)
			gun_reloads[p].custom_minimum_size = Vector2(w, 8)

@rpc("any_peer", "call_remote")
func handle_single_click() -> void:
	# Fire just one gun
	if multiplayer.is_server():
		if guns.size() > 0:
			for gun in guns:
				# Find first gun that's ready to fire
				if gun.reload >= 1.0:
					gun.fire()
					break

@rpc("any_peer", "call_remote")
func handle_double_click() -> void:
	# Fire all guns that are ready
	if multiplayer.is_server():
		for gun in guns:
			gun.fire()
		#if gun.is_ready_to_fire():
			#gun.fire()
			

@rpc("any_peer", "call_remote")
func fire_next_gun() -> void:
	if multiplayer.is_server():
		for g in guns:
			if g.reload >= 1:
				g.fire()
				return
