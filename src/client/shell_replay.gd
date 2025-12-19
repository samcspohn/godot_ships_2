# src/client/shell_replay.gd
extends Node

# References to UI elements
@onready var text_input: TextEdit = $CanvasLayer/UIPanel/VBoxContainer/TextInput
@onready var play_button: Button = $CanvasLayer/UIPanel/VBoxContainer/HBoxContainer/PlayButton
@onready var validate_button: Button = $CanvasLayer/UIPanel/VBoxContainer/HBoxContainer/ValidateButton
@onready var back_button: Button = $CanvasLayer/UIPanel/VBoxContainer/HBoxContainer/BackButton
@onready var result_label: Label = $CanvasLayer/UIPanel/VBoxContainer/ResultLabel
@onready var validation_label: Label = $CanvasLayer/UIPanel/VBoxContainer/ValidationLabel

# References to 3D world elements
@onready var world_3d: Node3D = $CanvasLayer/SubViewportContainer/SubViewport/World3D
var ship: Node3D = null  # Will be dynamically spawned
@onready var camera: Camera3D = $CanvasLayer/SubViewportContainer/SubViewport/World3D/Camera3D
@onready var shell_trail: Node3D = $CanvasLayer/SubViewportContainer/SubViewport/World3D/ShellTrail

# Shell representation
var shell: MeshInstance3D
var shell_material: StandardMaterial3D

# Replay state
var events: Array = []
var current_event_index: int = 0
var is_playing: bool = false
var playback_speed: float = 0.1  # Time between events in seconds
var time_accumulator: float = 0.0

# Trail visualization
var trail_points: Array = []
var trail_mesh: ImmediateMesh
var trail_mesh_instance: MeshInstance3D

# Simulated trail visualization
var sim_trail_points: Array = []
var sim_trail_mesh: ImmediateMesh
var sim_trail_mesh_instance: MeshInstance3D

# Hit result tracking
var hit_citadel: bool = false
var over_penetration: bool = false
var last_armor_result: String = ""
var shell_velocity_zero: bool = false

# Validation mode
var is_validating: bool = false
var validation_results: Array = []

# Camera control
var camera_rotation: Vector2 = Vector2.ZERO
var camera_distance: float = 100.0
var camera_target: Vector3 = Vector3.ZERO
var camera_speed: float = 50.0
var rotate_speed: float = 0.005
var zoom_speed: float = 5.0
var is_dragging: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO

func _ready():
	# Connect button signals
	play_button.pressed.connect(_on_play_pressed)
	validate_button.pressed.connect(_on_validate_pressed)
	back_button.pressed.connect(_on_back_pressed)
	
	# Create shell mesh
	create_shell()
	
	# Create trail mesh
	create_trail_mesh()
	
	# Initially hide the shell
	shell.visible = false
	
	# Initialize camera
	camera_rotation = Vector2(-PI / 6, 0)  # Start with slight downward angle
	update_camera_transform()

func _input(event):
	# Handle mouse button for camera rotation
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			is_dragging = event.pressed
			if event.pressed:
				last_mouse_pos = event.position
		# Handle zoom with mouse wheel
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = max(10.0, camera_distance - zoom_speed)
			update_camera_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = min(500.0, camera_distance + zoom_speed)
			update_camera_transform()
	
	# Handle mouse motion for camera rotation
	if event is InputEventMouseMotion and is_dragging:
		var delta_mouse = event.position - last_mouse_pos
		last_mouse_pos = event.position
		
		camera_rotation.y -= delta_mouse.x * rotate_speed
		camera_rotation.x = clamp(camera_rotation.x + delta_mouse.y * rotate_speed, -PI / 2, PI / 2)
		update_camera_transform()

func _process(delta: float):
	# Handle WASD camera movement
	var move_input = Vector3.ZERO
	
	if Input.is_key_pressed(KEY_W):
		move_input.z -= 1
	if Input.is_key_pressed(KEY_S):
		move_input.z += 1
	if Input.is_key_pressed(KEY_A):
		move_input.x -= 1
	if Input.is_key_pressed(KEY_D):
		move_input.x += 1
	if Input.is_key_pressed(KEY_Q):
		move_input.y -= 1
	if Input.is_key_pressed(KEY_E):
		move_input.y += 1
	
	if move_input.length() > 0:
		move_input = move_input.normalized()
		# Transform movement relative to camera rotation
		var forward = Vector3(sin(camera_rotation.y), 0, cos(camera_rotation.y))
		var right = Vector3(cos(camera_rotation.y), 0, -sin(camera_rotation.y))
		camera_target += (forward * move_input.z + right * move_input.x + Vector3.UP * move_input.y) * camera_speed * delta
		update_camera_transform()
	
	# Handle replay playback
	process_replay(delta)

func create_shell():
	# Create a simple sphere to represent the shell
	shell = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.5
	sphere_mesh.height = 1.0
	shell.mesh = sphere_mesh
	
	# Create material for the shell
	shell_material = StandardMaterial3D.new()
	shell_material.albedo_color = Color(1.0, 0.5, 0.0)  # Orange color
	shell_material.emission_enabled = true
	shell_material.emission = Color(1.0, 0.3, 0.0)
	shell_material.emission_energy_multiplier = 2.0
	shell.material_override = shell_material
	
	world_3d.add_child(shell)

func create_trail_mesh():
	# Create an ImmediateMesh for drawing the logged trail (yellow/orange)
	trail_mesh = ImmediateMesh.new()
	trail_mesh_instance = MeshInstance3D.new()
	trail_mesh_instance.mesh = trail_mesh
	
	# Create material for the logged trail
	var trail_material = StandardMaterial3D.new()
	trail_material.albedo_color = Color(1.0, 0.8, 0.0, 0.8)  # Yellow
	trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_mesh_instance.material_override = trail_material
	
	shell_trail.add_child(trail_mesh_instance)
	
	# Create an ImmediateMesh for drawing the simulated trail (cyan/blue)
	sim_trail_mesh = ImmediateMesh.new()
	sim_trail_mesh_instance = MeshInstance3D.new()
	sim_trail_mesh_instance.mesh = sim_trail_mesh
	
	# Create material for the simulated trail
	var sim_trail_material = StandardMaterial3D.new()
	sim_trail_material.albedo_color = Color(0.0, 0.8, 1.0, 0.8)  # Cyan
	sim_trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sim_trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sim_trail_mesh_instance.material_override = sim_trail_material
	
	shell_trail.add_child(sim_trail_mesh_instance)

func _on_play_pressed():
	if is_playing:
		# Stop playback
		stop_replay()
	else:
		# Start playback
		start_replay()

func _on_validate_pressed():
	if is_validating:
		# Stop validation
		stop_validation()
	else:
		# Start validation
		start_validation()

func _on_back_pressed():
	get_tree().change_scene_to_file("res://src/client/main_menu.tscn")

func start_replay():
	# Parse the input text
	var input_text = text_input.text
	if input_text.strip_edges().is_empty():
		push_warning("No input text to parse")
		return
	
	events = ShellEventParser.parse_events(input_text)
	
	if events.is_empty():
		push_warning("No events parsed from input")
		return
	
	# Load the ship from the first Ship event
	var ship_scene_path: String = ""
	for event in events:
		if event.event_type == "Ship" and event.data.has("scene_path"):
			ship_scene_path = event.data["scene_path"]
			break
	
	if ship_scene_path.is_empty():
		push_warning("No ship scene path found in events")
		return
	
	# Remove old ship if exists
	if ship != null:
		ship.queue_free()
		ship = null
	
	# Load and instantiate the ship
	var ship_scene = load(ship_scene_path)
	if ship_scene == null:
		push_error("Failed to load ship scene: " + ship_scene_path)
		return
	
	ship = ship_scene.instantiate()
	world_3d.add_child(ship)
	
	# Reset state
	current_event_index = 0
	trail_points.clear()
	time_accumulator = 0.0
	is_playing = true
	shell.visible = true
	play_button.text = "Stop"
	hit_citadel = false
	over_penetration = false
	last_armor_result = ""
	shell_velocity_zero = false
	result_label.text = "Result: Processing..."
	
	# Disable physics on the ship if it's a RigidBody3D
	if ship != null and ship is RigidBody3D:
		ship.gravity_scale = 0.0
		ship.freeze = true
	
	# Position ship if we have ship data
	if ship != null:
		for event in events:
			if event.event_type == "Ship":
				ship.position = event.data["position"]
				# Rotation is already in radians (x, y, z) = (pitch, yaw, roll)
				var rot = event.data["rotation"]
				ship.rotation = Vector3(rot.x, rot.y, rot.z)
				break
	
	# Position camera to view the ship and shell trajectory
	update_camera_position()

func stop_replay():
	is_playing = false
	play_button.text = "Play Replay"
	shell.visible = false

func update_camera_transform():
	# Calculate camera position based on target, rotation, and distance
	var offset = Vector3(
		cos(camera_rotation.x) * sin(camera_rotation.y),
		sin(camera_rotation.x),
		cos(camera_rotation.x) * cos(camera_rotation.y)
	) * camera_distance
	
	camera.position = camera_target + offset
	camera.look_at(camera_target, Vector3.UP)

func process_replay(delta: float):
	if not is_playing:
		return
	
	time_accumulator += delta
	
	# Process events at the specified playback speed
	while time_accumulator >= playback_speed and current_event_index < events.size():
		process_event(events[current_event_index])
		current_event_index += 1
		time_accumulator -= playback_speed
		
		# Check if we've reached the end
		if current_event_index >= events.size():
			is_playing = false
			play_button.text = "Replay"
			calculate_final_result()
			break

func process_event(event):
	match event.event_type:
		"Ship":
			# Update ship position/rotation if needed
			ship.position = event.data["position"]
			var rot = event.data["rotation"]
			ship.rotation = Vector3(rot.x, rot.y, rot.z)
		
		"Shell":
			# Update shell position
			var pos = event.data["position"]
			shell.position = pos
			
			# Track if shell stopped
			if event.data.has("velocity"):
				var vel = event.data["velocity"]
				if vel.length() < 0.1:
					shell_velocity_zero = true
			
			# Add to trail
			trail_points.append(pos)
			update_trail()
			
			# Optionally rotate shell to face velocity direction
			if event.data.has("velocity"):
				var vel = event.data["velocity"]
				if vel.length() > 0.1:
					shell.look_at(pos + vel.normalized(), Vector3.UP)
		
		"Armor":
			# Create a visual indicator at the impact point
			# We'll use the last shell position as the impact point
			if trail_points.size() > 0:
				var impact_pos = trail_points[-1]
				create_impact_marker(impact_pos, event.data["result"])
			
			# Track hit results
			last_armor_result = event.data["result"]
			var is_citadel_armor = event.data.get("is_citadel", false)
			
			if is_citadel_armor:
				hit_citadel = true
			
			if event.data["result"] == "OVERPEN":
				over_penetration = true

func update_trail():
	# Redraw the logged trail using ImmediateMesh
	trail_mesh.clear_surfaces()
	
	if trail_points.size() < 2:
		return
	
	trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	
	for point in trail_points:
		trail_mesh.surface_add_vertex(point)
	
	trail_mesh.surface_end()

func update_sim_trail():
	# Redraw the simulated trail using ImmediateMesh
	sim_trail_mesh.clear_surfaces()
	
	if sim_trail_points.size() < 2:
		return
	
	sim_trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	
	for point in sim_trail_points:
		sim_trail_mesh.surface_add_vertex(point)
	
	sim_trail_mesh.surface_end()

func create_impact_marker(position: Vector3, result: String):
	# Create a small sphere at the impact point
	var marker = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	marker.mesh = sphere
	
	# Color based on result type
	var material = StandardMaterial3D.new()
	match result:
		"OVERPEN":
			material.albedo_color = Color(0.5, 0.5, 1.0)  # Blue
		"RICOCHET":
			material.albedo_color = Color(1.0, 1.0, 0.0)  # Yellow
		"SHATTER":
			material.albedo_color = Color(0.5, 0.5, 0.5)  # Gray
		"PENETRATION":
			material.albedo_color = Color(1.0, 0.0, 0.0)  # Red
		_:
			material.albedo_color = Color(1.0, 1.0, 1.0)  # White
	
	material.emission_enabled = true
	material.emission = material.albedo_color
	material.emission_energy_multiplier = 1.5
	marker.material_override = material
	
	marker.position = position
	shell_trail.add_child(marker)

func update_camera_position():
	# Calculate bounds of the trajectory
	if trail_points.is_empty() and events.is_empty():
		return
	
	var min_pos = Vector3.ZERO
	var max_pos = Vector3.ZERO
	var has_points = false
	
	# Get ship position
	if ship != null:
		min_pos = ship.position
		max_pos = ship.position
		has_points = true
	
	# Get all shell positions to calculate bounds
	for event in events:
		if event.event_type == "Shell":
			var pos = event.data["position"]
			if not has_points:
				min_pos = pos
				max_pos = pos
				has_points = true
			else:
				min_pos.x = min(min_pos.x, pos.x)
				min_pos.y = min(min_pos.y, pos.y)
				min_pos.z = min(min_pos.z, pos.z)
				max_pos.x = max(max_pos.x, pos.x)
				max_pos.y = max(max_pos.y, pos.y)
				max_pos.z = max(max_pos.z, pos.z)
	
	if has_points:
		# Calculate center and size
		var center = (min_pos + max_pos) / 2.0
		var size = (max_pos - min_pos).length()
		
		# Set camera target and distance to view the entire scene
		camera_target = center
		camera_distance = max(size * 1.5, 50.0)
		update_camera_transform()

func calculate_final_result():
	# Replicate the logic from ArmorInteraction.gd to determine final hit result
	# This needs to match the exact logic from process_hit() around line 370-390
	
	var final_result = "UNKNOWN"
	
	if ship == null:
		result_label.text = "Final Result: NO SHIP"
		return
	
	# Get the final shell position
	var final_shell_pos = trail_points[-1] if trail_points.size() > 0 else Vector3.ZERO

	var space_state = world_3d.get_world_3d().direct_space_state
	var d = ArmorInteraction.get_part_hit(ship, final_shell_pos, space_state)
	
	# var damage_result = ArmorInteraction.HitResult.WATER
	# final_result = "WATER"
	# Check definitive outcomes first (shatter/ricochet)
	if over_penetration:
		final_result = "OVERPENETRATION"
	elif last_armor_result == "SHATTER":
		final_result = "SHATTER"
	elif last_armor_result == "RICOCHET":
		final_result = "RICOCHET"
	# Then check penetration depth
	if d != null and (d.is_citadel or d.armor_path.find("Citadel") != -1):
		final_result = "CITADEL"
	elif hit_citadel: # overpen citadel but still could be inside hull
		final_result = "CITADEL OVERPEN"
	elif d != null: # inside hull
		final_result = "PENETRATION"
	
	# Update the label with color coding
	result_label.text = "Final Result: " + str(final_result)
	
	# Color code the result
	match final_result:
		"CITADEL":
			result_label.add_theme_color_override("font_color", Color.RED)
		"CITADEL OVERPEN":
			result_label.add_theme_color_override("font_color", Color.ORANGE)
		"PENETRATION":
			result_label.add_theme_color_override("font_color", Color.DARK_RED)
		"OVERPENETRATION":
			result_label.add_theme_color_override("font_color", Color.BLUE)
		"RICOCHET":
			result_label.add_theme_color_override("font_color", Color.YELLOW)
		"SHATTER":
			result_label.add_theme_color_override("font_color", Color.GRAY)
		_:
			result_label.add_theme_color_override("font_color", Color.WHITE)

func check_if_inside_citadel(pos: Vector3) -> bool:
	if ship == null:
		return false
	
	# Use the same logic as ArmorInteraction.get_part_hit()
	# Cast rays from port and starboard to determine what's at this position
	var space_state = world_3d.get_world_3d().direct_space_state
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.to = pos
	ray_query.hit_back_faces = true
	ray_query.collision_mask = 1 << 1  # armor layer
	
	# Cast from right (starboard)
	ray_query.from = pos + ship.global_basis.x.normalized() * 60.0
	ray_query.exclude = []
	var right_hits = []
	var armor_hit = space_state.intersect_ray(ray_query)
	var exclude = []
	while !armor_hit.is_empty():
		var armor_part = armor_hit.get('collider') as ArmorPart
		if armor_part != null:
			right_hits.append(armor_part)
		exclude.append(armor_hit.get('collider'))
		ray_query.exclude = exclude
		armor_hit = space_state.intersect_ray(ray_query)
	
	# Cast from left (port)
	ray_query.from = pos + ship.global_basis.x.normalized() * -60.0
	ray_query.exclude = []
	var left_hits = []
	armor_hit = space_state.intersect_ray(ray_query)
	exclude = []
	while !armor_hit.is_empty():
		var armor_part = armor_hit.get('collider') as ArmorPart
		if armor_part != null:
			left_hits.append(armor_part)
		exclude.append(armor_hit.get('collider'))
		ray_query.exclude = exclude
		armor_hit = space_state.intersect_ray(ray_query)
	
	# Must hit armor from both sides to be inside
	if right_hits.size() == 0 or left_hits.size() == 0:
		return false
	
	# Check if citadel is hit from BOTH sides
	var right_has_citadel = false
	var left_has_citadel = false
	
	for part in right_hits:
		if part.armor_path.find("Citadel") != -1:
			right_has_citadel = true
			break
	
	for part in left_hits:
		if part.armor_path.find("Citadel") != -1:
			left_has_citadel = true
			break
	
	# Only inside citadel if BOTH sides hit citadel
	return right_has_citadel and left_has_citadel

func check_if_inside_hull(pos: Vector3) -> bool:
	if ship == null:
		return false
	
	# Use the same logic as ArmorInteraction.get_part_hit()
	# Must hit armor from both port and starboard to be inside hull
	var space_state = world_3d.get_world_3d().direct_space_state
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.to = pos
	ray_query.hit_back_faces = true
	ray_query.collision_mask = 1 << 1  # armor layer
	
	# Cast from right (starboard)
	ray_query.from = pos + ship.global_basis.x.normalized() * 60.0
	var right_hit = space_state.intersect_ray(ray_query)
	
	# Cast from left (port)
	ray_query.from = pos + ship.global_basis.x.normalized() * -60.0
	var left_hit = space_state.intersect_ray(ray_query)
	
	# Must hit armor from both sides to be inside the hull
	return !right_hit.is_empty() and !left_hit.is_empty()

#region Validation Mode

func start_validation():
	# Parse the input text
	var input_text = text_input.text
	if input_text.strip_edges().is_empty():
		validation_label.text = "Validation: No input text"
		return
	
	events = ShellEventParser.parse_events(input_text)
	
	if events.is_empty():
		validation_label.text = "Validation: No events parsed"
		return
	
	# Load the ship
	var ship_scene_path: String = ""
	for event in events:
		if event.event_type == "Ship" and event.data.has("scene_path"):
			ship_scene_path = event.data["scene_path"]
			break
	
	if ship_scene_path.is_empty():
		validation_label.text = "Validation: No ship scene path"
		return
	
	# Remove old ship if exists
	if ship != null:
		ship.queue_free()
		ship = null
	
	# Load and instantiate the ship
	var ship_scene = load(ship_scene_path)
	if ship_scene == null:
		validation_label.text = "Validation: Failed to load ship scene"
		return
	
	ship = ship_scene.instantiate()
	world_3d.add_child(ship)
	
	# Position ship
	for event in events:
		if event.event_type == "Ship":
			ship.position = event.data["position"]
			var rot = event.data["rotation"]
			ship.rotation = Vector3(rot.x, rot.y, rot.z)
			break
	
	# Disable physics on the ship
	if ship is RigidBody3D:
		ship.gravity_scale = 0.0
		ship.freeze = true
	
	# Extract shell parameters from events
	var shell_params = extract_shell_params()
	if shell_params == null:
		validation_label.text = "Validation: Failed to extract shell parameters"
		return
	
	# Clear simulated trail
	sim_trail_points.clear()
	update_sim_trail()
	
	# Run validation simulation
	run_validation_simulation(shell_params)
	
	is_validating = true
	validate_button.text = "Stop Validation"

func stop_validation():
	is_validating = false
	validate_button.text = "Validate"

func extract_shell_params() -> Dictionary:
	# Extract initial shell state from the first Shell event
	var first_shell_event = null
	
	for event in events:
		if event.event_type == "Shell":
			first_shell_event = event
			break
	
	if first_shell_event == null:
		return {}
	
	# Use actual 500mm AP shell parameters from H44
	var params = ShellParams.new()
	params.speed = 810.0
	params.drag = 0.008
	params.damage = 20000.0
	params.size = 5.0
	params.caliber = 500.0
	params.mass = 1850.0
	params.fire_buildup = 0.0
	params.fuze_delay = 0.035
	params.type = ShellParams.ShellType.AP
	params.penetration_modifier = 1.0
	params.auto_bounce = deg_to_rad(60.0)
	params.ricochet_angle = deg_to_rad(45.0)
	params.overmatch = 35
	params.arming_threshold = 83
	
	# Get position and velocity from first shell event
	var hit_pos: Vector3 = first_shell_event.data["position"]
	var vel: Vector3 = first_shell_event.data["velocity"]
	
	# Time step: 1/20 second
	const TIME_STEP = 1.0 / 20.0
	
	# Calculate prev_pos and current_pos centered around the hit position
	# prev_pos = hit_pos - TIME_STEP * vel * 0.5
	# current_pos = hit_pos + TIME_STEP * vel * 0.5
	var prev_pos = hit_pos - vel * TIME_STEP * 0.5
	var current_pos = hit_pos + vel * TIME_STEP * 0.5
	
	return {
		"params": params,
		"prev_pos": prev_pos,
		"current_pos": current_pos,
		"velocity": vel,
		"time_step": TIME_STEP
	}

func run_validation_simulation(shell_data: Dictionary):
	validation_results.clear()
	
	# Create ProjectileData
	var projectile = ProjectileManager.ProjectileData.new()
	var _ship = Ship.new()
	projectile.initialize(
		shell_data["prev_pos"],
		shell_data["velocity"],
		0.0,
		shell_data["params"],
		_ship,
		[]
	)
	
	var space_state = world_3d.get_world_3d().direct_space_state
	
	# Set current position from shell data
	var prev_pos = shell_data["prev_pos"]
	projectile.position = shell_data["current_pos"]
	var time_step = shell_data["time_step"]
	
	var sim_events: Array = []
	var result = ArmorInteraction.process_travel(projectile, prev_pos, time_step, space_state, sim_events)
	
	# Visualize both trajectories
	visualize_trajectories(sim_events)
	
	# Print results from both logged events and simulated events
	print_comparison_results(sim_events, result)

func visualize_trajectories(sim_events: Array):
	# Visualize logged trajectory using process_event
	trail_points.clear()
	for event in events:
		process_event(event)
	
	# Extract and visualize simulated trajectory from events
	sim_trail_points.clear()
	for event_str in sim_events:
		# Parse position from event strings like "Shell: ... pos=(x, y, z)"
		if event_str is String and event_str.contains("pos=(") and event_str.contains("Shell:"):
			var pos_start = event_str.find("pos=(") + 5
			var pos_end = event_str.find(")", pos_start)
			var pos_str = event_str.substr(pos_start, pos_end - pos_start)
			var parts = pos_str.split(",")
			if parts.size() >= 3:
				var pos = Vector3(
					float(parts[0].strip_edges()),
					float(parts[1].strip_edges()),
					float(parts[2].strip_edges())
				)
				sim_trail_points.append(pos)
		
		# Create markers for simulated armor hits
		if event_str is String and event_str.contains("Armor:"):
			# Parse result type
			var result_start = event_str.find("Armor: ") + 7
			var result_end = event_str.find(",", result_start)
			if result_end != -1:
				var result_type = event_str.substr(result_start, result_end - result_start).strip_edges()
				# Use the last position as the impact point
				if sim_trail_points.size() > 0:
					create_impact_marker(sim_trail_points[-1], result_type)
	
	update_sim_trail()
	
	# Update camera to view both trajectories
	update_camera_for_both_trajectories()

func update_camera_for_both_trajectories():
	# Calculate bounds of both trajectories
	var all_points: Array = []
	all_points.append_array(trail_points)
	all_points.append_array(sim_trail_points)
	
	if all_points.is_empty():
		return
	
	var min_pos = all_points[0]
	var max_pos = all_points[0]
	
	for pos in all_points:
		min_pos.x = min(min_pos.x, pos.x)
		min_pos.y = min(min_pos.y, pos.y)
		min_pos.z = min(min_pos.z, pos.z)
		max_pos.x = max(max_pos.x, pos.x)
		max_pos.y = max(max_pos.y, pos.y)
		max_pos.z = max(max_pos.z, pos.z)
	
	# Include ship position if available
	if ship != null:
		min_pos.x = min(min_pos.x, ship.position.x)
		min_pos.y = min(min_pos.y, ship.position.y)
		min_pos.z = min(min_pos.z, ship.position.z)
		max_pos.x = max(max_pos.x, ship.position.x)
		max_pos.y = max(max_pos.y, ship.position.y)
		max_pos.z = max(max_pos.z, ship.position.z)
	
	# Calculate center and size
	var center = (min_pos + max_pos) / 2.0
	var size = (max_pos - min_pos).length()
	
	# Set camera target and distance to view the entire scene
	camera_target = center
	camera_distance = max(size * 1.5, 50.0)
	update_camera_transform()

func print_comparison_results(sim_events: Array, sim_result):
	print("\\n========== SHELL REPLAY VALIDATION ==========")
	print("\\n--- LOGGED EVENTS ---")
	
	for event in events:
		match event.event_type:
			"Processing Shell":
				print("Processing Shell: %s" % event.data.get("shell_info", ""))
			"Ship":
				print("Ship: %s pos=(%.1f, %.1f, %.1f), rot=(%.1f, %.1f, %.1f), scene=%s" % [
					event.data.get("name", ""),
					event.data["position"].x, event.data["position"].y, event.data["position"].z,
					event.data["rotation"].x, event.data["rotation"].y, event.data["rotation"].z,
					event.data.get("scene_path", "")
				])
			"Shell":
				print("Shell: speed=%.1f vel=(%.1f, %.1f, %.1f) m/s, fuze=%.3f s, pos=(%.1f, %.1f, %.1f), pen: %.1f" % [
					event.data["speed"],
					event.data["velocity"].x, event.data["velocity"].y, event.data["velocity"].z,
					event.data["fuze"],
					event.data["position"].x, event.data["position"].y, event.data["position"].z,
					event.data["penetration"]
				])
			"Armor":
				print("Armor: %s, %s with %.1f/%.1fmm (angle %.1f°), is_citadel: %s" % [
					event.data["result"],
					event.data["part"],
					event.data["armor_thickness"],
					event.data["effective_thickness"],
					event.data["angle"],
					event.data.get("is_citadel", false)
				])
			"Final Hit Result":
				print("Final Hit Result: %s" % event.data["result"])
	
	print("\\n--- SIMULATED EVENTS ---")
	
	for event_str in sim_events:
		print(event_str)
	
	if sim_result != null:
		var result_name = ArmorInteraction.HitResult.keys()[sim_result.result_type]
		print("Final Simulated Result: %s" % result_name)
		if sim_result.armor_part != null:
			print("  Armor Part: %s (citadel: %s)" % [
				sim_result.armor_part.armor_path,
				sim_result.armor_part.is_citadel
			])
		print("  Position: (%.1f, %.1f, %.1f)" % [
			sim_result.explosion_position.x,
			sim_result.explosion_position.y,
			sim_result.explosion_position.z
		])
	else:
		print("Final Simulated Result: NO HIT")
	
	print("\\n==========================================\\n")
	
	# Update validation label
	var validation_text = "Validation: See console for detailed comparison"
	validation_label.text = validation_text
	validation_label.add_theme_color_override("font_color", Color.GREEN)

#endregion
