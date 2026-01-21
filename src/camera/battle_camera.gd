extends Camera3D

class_name BattleCamera
signal processed
# Ship to follow
@export var _ship: Ship
var player_controller: PlayerController
#@export var ship_movement: ShipMovement
#@export var hp_manager: HPManager  # Add reference to hit points
@export var projectile_speed: float = 800.0 # Realistic speed for naval artillery (m/s)
@export var projectile_drag_coefficient: float = 0.0 # 380mm shell drag

# Camera mode
enum CameraMode {THIRD_PERSON, SNIPER, FREE_LOOK}
var last_non_free_look_mode: int = CameraMode.THIRD_PERSON
var current_mode: int = CameraMode.THIRD_PERSON

# Camera properties
var camera_offset: Vector3 = Vector3(0, 50, 0) # Height offset above ship
#var sniper_range: float = 1.0

# Target locking
var locked_target: Ship = null
var target_lock_enabled: bool = false

# Zoom properties - Scaled for a 250m ship
@export var min_zoom_distance: float = 7.0 # Close to the ship
@export var max_zoom_distance: float = 500.0 # Far enough to see full ship and surroundings
@export var zoom_speed: float = 20.0 # Faster zoom for large distances
@export var sniper_threshold: float = 7.0 # Enter sniper mode when closer than this
var current_zoom: float = 200.0 # Default zoom
var just_changed_mode: bool = false

# Sniper mode properties
@export var default_fov: float = 70.0
@export var min_fov: float = 2.0 # Very narrow for extreme distance aiming
@export var max_fov: float = 60.0 # Wide enough for general aiming
var last_fov: float = 10.0
@export var fov_zoom_speed: float = 0.07
var current_fov: float = default_fov

# Mouse settings
@export var mouse_sensitivity: float = 0.3
@export var invert_y: bool = false
var free_look: bool = false

# Target information
var time_to_target: float = 0.0
var distance_to_target: float = 0.0
var terrain_hit: bool = false
var penetration_power: float = 0.0
var aim_position: Vector3 = Vector3.ZERO
var max_range_reached: bool = false

# Ship status indicators
var ship_speed: float = 0.0

# Add these variables near the top with other variable declarations
var tracked_ships = {} # Dictionary to store ships and their UI elements
var ship_ui_elements = {} # Dictionary to store UI elements for each ship

var aim: Node3D
var ui # Will be CameraUIScene instance
var third_person_view: ThirdPersonView
var free_look_view: ThirdPersonView
var sniper_view: SniperView
var ray_exclude: Array = [] # Nodes to exclude from raycasting

# Zoom smoothing for Godot 4.5
var zoom_accumulator: float = 0.0
var zoom_smoothing: float = 1.0 # Adjust this value to control smoothing

func set_angle(angle: float):
	aim.rotation_degrees_horizontal = angle

func recurs_collision_bodies(node: Node) -> Array:
	"""Recursively find all collision bodies in the node tree, excluding specified nodes."""
	var bodies = []
	if node is CollisionObject3D:
		bodies.append(node)
	for child in node.get_children():
		bodies += recurs_collision_bodies(child)
	return bodies

func _ready():
	# Initial setup
	current_fov = default_fov
	fov = current_fov

	# Load the UI scene instead of creating it programmatically
	var ui_scene = preload("res://src/camera/camera_ui.tscn")
	ui = ui_scene.instantiate()
	ui.camera_controller = self
	ui.player_controller = player_controller
	add_child(ui)

	# Setup gun reload bars after camera controller is assigned
	ui.call_deferred("setup_gun_reload_bars")

	# Initialize UI for the ship after it's added to the scene tree
	if _ship:
		ui.call_deferred("initialize_for_ship")

	third_person_view = ThirdPersonView.new()
	third_person_view._ship = _ship
	free_look_view = ThirdPersonView.new()
	#free_look_view = FreeLookView.new()
	free_look_view._ship = _ship
	sniper_view = SniperView.new()
	sniper_view._ship = _ship
	get_parent().add_child(third_person_view)
	get_parent().add_child(free_look_view)
	get_parent().add_child(sniper_view)
	#get_tree().root.add_child(aim)
	aim = third_person_view
	ProjectileManager.camera = self
	TorpedoManager.camera = self
	# processed.connect(ProjectileManager.__process)
	# processed.connect(TorpedoManager.__process)
	# processed.connect(ui.__process)

	# Make sure we have necessary references
	if not _ship:
		push_error("ArtilleryCamera requires a _ship node!")
	# Capture mouse
	#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _input(event):
	# Handle mouse movement for rotation
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event)

	# Handle zoom with mouse wheel
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom_accumulator -= zoom_speed
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom_accumulator += zoom_speed
		# activate free look while holding right mouse button


	# Toggle camera mode with Shift key
	elif event is InputEventKey:
		if event.pressed and event.keycode == KEY_SHIFT:
			toggle_camera_mode()
		# Toggle target lock with X key
		if event.pressed and event.keycode == KEY_X:
			toggle_target_lock()

	# if not free_look:
	# 	third_person_view.input(event)


func _process(delta):
	# Apply accumulated zoom smoothly
	if abs(zoom_accumulator) > 0.01:
		var zoom_delta = zoom_accumulator * zoom_smoothing
		_zoom_camera(zoom_delta)
		zoom_accumulator -= zoom_delta
	# Update camera position and rotation
	_update_target_lock()
	if last_non_free_look_mode == CameraMode.THIRD_PERSON:
		third_person_view._update_camera_transform()
	else:
		sniper_view._update_camera_transform()

	_update_camera_transform()

	# Calculate ship speed
	if _ship:
		var velocity = _ship.linear_velocity
		ship_speed = velocity.length() * 1.94384 / ShipMovementV2.SHIP_SPEED_MODIFIER # Convert m/s to knots


	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		current_mode = CameraMode.FREE_LOOK
		if not free_look:
			if last_non_free_look_mode == CameraMode.THIRD_PERSON:
				free_look_view.rotation_degrees_horizontal = third_person_view.rotation_degrees_horizontal
				#free_look_view.rotation_degrees_vertical = third_person_view.rotation_degrees_vertical
			elif last_non_free_look_mode == CameraMode.SNIPER:
				free_look_view.rotation_degrees_horizontal = sniper_view.rotation_degrees_horizontal
				#free_look_view.rotation_degrees_vertical = sniper_view.rotation_degrees_vertical
		free_look = true
	else:
		current_mode = last_non_free_look_mode
		free_look = false

	ui.locked_target = locked_target
	ui.target_lock_enabled = target_lock_enabled
	ui.aim_position = aim_position
	ui.ship_speed = ship_speed
	ui.distance_to_target = distance_to_target
	ui.time_to_target = time_to_target
	ui.terrain_hit = terrain_hit
	ui.penetration_power = penetration_power
	ui.max_range_reached = max_range_reached

	# self.make_current()
	#ProjectileManager1.__process(delta)
	processed.emit(delta)

func _physics_process(delta):
	_calculate_target_info()

func _zoom_camera(zoom_amount):
	if current_mode == CameraMode.THIRD_PERSON:
		# Adjust zoom in third-person mode
		third_person_view.current_zoom = clamp(third_person_view.current_zoom + zoom_amount, third_person_view.min_zoom_distance, third_person_view.max_zoom_distance)

		# Switch to sniper mode if zoomed in enough
		if third_person_view.current_zoom <= sniper_threshold:
			set_camera_mode(CameraMode.SNIPER)
	elif current_mode == CameraMode.SNIPER:
		# In sniper mode, adjust FOV
		sniper_view.current_fov = clamp(sniper_view.current_fov + zoom_amount * fov_zoom_speed, sniper_view.min_fov, sniper_view.max_fov)
		# fov = current_fov

		# Switch back to third-person if zoomed out enough
		if sniper_view.current_fov >= sniper_view.max_fov:
			set_camera_mode(CameraMode.THIRD_PERSON)
	else:
		# In free look mode, adjust zoom
		free_look_view.current_zoom = clamp(free_look_view.current_zoom + zoom_amount, free_look_view.min_zoom_distance, free_look_view.max_zoom_distance)



func _handle_mouse_motion(event):
	# Only handle mouse motion if captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	if current_mode == CameraMode.THIRD_PERSON:
		third_person_view.handle_mouse_motion(event)
	elif current_mode == CameraMode.SNIPER:
		sniper_view.handle_mouse_motion(event)
	elif current_mode == CameraMode.FREE_LOOK:
		free_look_view.handle_mouse_motion(event)

var _t = Time.get_unix_time_from_system()
func _print(m):
	if _t + 0.3 < Time.get_unix_time_from_system():
		print(m)

func _update_t():
	if _t + 0.3 < Time.get_unix_time_from_system():
		_t = Time.get_unix_time_from_system()

func calculate_ground_intersection(origin_position: Vector3, h_rad: float, v_rad: float) -> Vector3:
	#origin_position.y + 0.5
	# Create direction vector from angles
	var direction = Vector3(
		sin(h_rad), # x component
		sin(v_rad), # y component
		cos(h_rad) # z component
	).normalized()

	# If direction is parallel to ground or pointing up, no intersection
	if direction.y >= -0.0001:
		# Return a fallback position at maximum visible distance
		return origin_position + Vector3(sin(h_rad), 0, cos(h_rad)) * 10000.0

	# Calculate intersection parameter t using plane equation:
	# For plane at y=0: t = -origin.y / direction.y
	var t = - origin_position.y / direction.y

	# Calculate intersection point
	return origin_position + direction * t

func _get_angles_to_target(cam_pos, target_pos):
	# Calculate direction to target
	var direction_to_target = (target_pos - cam_pos).normalized()

	# Calculate base angle to target (without lerping for responsive movement)
	var target_angle_horizontal = atan2(direction_to_target.x, direction_to_target.z) + PI
	var target_distance = cam_pos.distance_to(target_pos)
	var height_diff = target_pos.y - cam_pos.y
	var target_angle_vertical = atan2(height_diff, sqrt(pow(direction_to_target.x, 2) + pow(direction_to_target.z, 2)) * target_distance)

	return [target_angle_horizontal, target_angle_vertical]


func _update_target_lock():
	third_person_view.target_lock_enabled = target_lock_enabled
	sniper_view.target_lock_enabled = target_lock_enabled
	third_person_view.locked_target = locked_target
	sniper_view.locked_target = locked_target

	if target_lock_enabled and (!locked_target.visible_to_enemy or locked_target.health_controller.is_dead()):
		# If target is not visible, disable target lock
		target_lock_enabled = false
		locked_target = null

func _update_camera_transform():
	if !_ship:
		return
	if current_mode == CameraMode.FREE_LOOK:
		free_look_view._update_camera_transform()
		self.global_position = free_look_view.global_position
		self.rotation.y = free_look_view.rotation.y
		self.rotation.x = free_look_view.rotation.x
		self.fov = free_look_view.current_fov
	elif current_mode == CameraMode.THIRD_PERSON:
		self.global_position = third_person_view.global_position
		self.rotation.y = third_person_view.rotation.y
		self.rotation.x = third_person_view.rotation.x
		self.fov = third_person_view.current_fov
	elif current_mode == CameraMode.SNIPER:
		self.global_position = sniper_view.global_position
		self.rotation.y = sniper_view.rotation.y
		self.rotation.x = sniper_view.rotation.x
		fov = sniper_view.current_fov

func get_angle_between_points(point1: Vector2, point2: Vector2, in_degrees: bool = false) -> float:
	# Calculate the difference between the points
	var delta_x = point2.x - point1.x
	var delta_y = point2.y - point1.y

	# Use atan2 to get the angle in radians
	var angle_rad = atan2(delta_y, delta_x)

	# Convert to degrees if requested
	if in_degrees:
		return rad_to_deg(angle_rad)
	else:
		return angle_rad

# Add a debug sphere at global location.
static func draw_debug_sphere(scene_root: Node, location, size, color = Color(1, 0, 0), duration: float = 3.0):
	# Will usually work, but you might need to adjust this.
	# Create sphere with low detail of size.
	var sphere = SphereMesh.new()
	sphere.radial_segments = 4
	sphere.rings = 4
	sphere.radius = size
	sphere.height = size * 2
	# Bright red material (unshaded).
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.flags_unshaded = true
	sphere.surface_set_material(0, material)

	# Add to meshinstance in the right place.
	var node = MeshInstance3D.new()
	node.mesh = sphere
	var t = Timer.new()
	t.wait_time = duration
	t.timeout.connect(func():
		node.queue_free()
		)
	t.autostart = true
	node.add_child(t)
	scene_root.add_child(node)
	node.global_transform.origin = location


func set_camera_mode(mode):
	current_mode = mode


	if mode == CameraMode.THIRD_PERSON:
		current_mode = CameraMode.THIRD_PERSON
		last_non_free_look_mode = CameraMode.THIRD_PERSON
		third_person_view.rotation_degrees_horizontal = sniper_view.rotation_degrees_horizontal
		var sniper_range = Vector2(aim_position.x, aim_position.z).distance_to(Vector2(_ship.global_position.x, _ship.global_position.z))
		var adj = sniper_range + third_person_view.current_zoom
		var opp = third_person_view.current_zoom * 0.2 - aim_position.y + 5
		# print("DEBUG: THIRD_PERSON")
		#print(sniper_view.sniper_range)
		# print(Vector2(aim_position.x, aim_position.z).distance_to(Vector2(_ship.global_position.x, _ship.global_position.z)))
		# print(adj)
		# print(opp)
		third_person_view.rotation_degrees_vertical = rad_to_deg(atan(-opp / adj))
		# print(sniper_view.rotation.x)
		# print(third_person_view.rotation_degrees_vertical)

		#third_person_view.sniper_range = sniper_view.sniper_range

		third_person_view.camera_offset_horizontal = sniper_view.camera_offset_horizontal
		third_person_view.camera_offset_vertical = rad_to_deg(atan(- (opp + sniper_view.camera_offset_vertical) / adj))
		# third_person_view.camera_offset_vertical = sniper_view.camera_offset_vertical
		aim = third_person_view

	else: # SNIPER mode
		# Switch to sniper mode if zoomed in enough
		current_mode = CameraMode.SNIPER
		last_non_free_look_mode = CameraMode.SNIPER
		draw_debug_sphere(get_tree().root, aim_position, 5)
		# print("DEBUG: SNIPER")
		# print(aim_position.y)
		var aim_dist = Vector2(aim_position.x, aim_position.z).distance_to(Vector2(_ship.global_position.x, _ship.global_position.z))
		# var sniper_height =
		var sniper_range = aim_dist + (aim_position.y) / -tan(sniper_view.sniper_angle_x)
		var sniper_height = sniper_range * -tan(sniper_view.sniper_angle_x)
		if sniper_height <= 35:
			var start_point = Vector3(_ship.global_position.x, 35, _ship.global_position.z)
			var a = aim_position - start_point
			var b = Vector3(0, -start_point.y, 0)
			var angle = a.angle_to(b) - PI / 2
			# print(rad_to_deg(angle))
			# print(a)
			var ground_intersection = calculate_ground_intersection(start_point, deg_to_rad(third_person_view.rotation_degrees_horizontal), angle)
			sniper_range = Vector2(ground_intersection.x, ground_intersection.z).distance_to(Vector2(_ship.global_position.x, _ship.global_position.z))
			sniper_height = sniper_range * -tan(sniper_view.sniper_angle_x)

		sniper_view.rotation_degrees_horizontal = third_person_view.rotation_degrees_horizontal
		#sniper_view.sniper_range = clamp(sniper_range, 0.0, _ship.artillery_controller.guns[0].max_range)
		sniper_view.camera_offset_horizontal = third_person_view.camera_offset_horizontal
		sniper_view.camera_offset_vertical = third_person_view.camera_offset_vertical
		# sniper_height = clamp(sniper_height, 0.005, -tan(sniper_view.sniper_angle_x) * _ship.artillery_controller.guns[0].max_range)

		sniper_view.sniper_height = sniper_height
		var horizontal_rad = deg_to_rad(sniper_view.rotation_degrees_horizontal)
		var intersection_point = _ship.global_position + Vector3(sin(horizontal_rad) * -sniper_range, -_ship.global_position.y, cos(horizontal_rad) * -sniper_range)
		draw_debug_sphere(get_tree().root, intersection_point, 5, Color.GREEN)
		#sniper_view.rotation.x = angle
		aim = sniper_view


func toggle_camera_mode():
	if current_mode == CameraMode.THIRD_PERSON:
		set_camera_mode(CameraMode.SNIPER)
	else:
		set_camera_mode(CameraMode.THIRD_PERSON)

func _calculate_target_info():
	# Get the direction the camera is facing
	if target_lock_enabled and locked_target and is_instance_valid(locked_target):
		var horizontal_rad = aim.rotation.y
		var vertical_rad = aim.rotation.x
		# var orbit_distance = current_zoom
		# var adj = tan(PI / 2.0 + vertical_rad)
		var cam_pos_3rd = aim.global_position
		aim_position = calculate_ground_intersection(
			cam_pos_3rd,
			horizontal_rad + PI,
			vertical_rad
		)

	else:
		var aim_direction = - aim.basis.z.normalized()
		# Cast a ray to get target position (could be terrain, enemy, etc.)
		var ray_length = 200000.0 # 50km range for naval artillery
		var space_state = get_world_3d().direct_space_state
		var ray_origin = aim.global_position

		var ray_params = PhysicsRayQueryParameters3D.new()
		ray_params.from = ray_origin
		ray_params.to = ray_origin + aim_direction * ray_length
		ray_params.collision_mask = 1 | (1 << 1) | (1 << 3) # land | armor | water
		if ray_exclude.size() == 0:
			ray_exclude = recurs_collision_bodies(_ship)
		ray_params.exclude = ray_exclude

		ray_params.collide_with_areas = true
		ray_params.collide_with_bodies = true

		var result = space_state.intersect_ray(ray_params)

		if result:
			aim_position = result.position
		else:
			# No collision, use a point far in the distance
			aim_position = ray_origin + aim_direction * ray_length
	ui.minimap.aim_point = aim_position
	#minimap.aim_point = aim_position


	# Calculate launch vector using our projectile physics
	var ship_position = _ship.global_position
	var launch_result = ProjectilePhysicsWithDrag.calculate_launch_vector(
		ship_position,
		aim_position,
		projectile_speed,
		projectile_drag_coefficient
	)

	# Extract results
	var launch_vector = launch_result[0]

	#max_range_reached = launch_result[2]
	max_range_reached = (aim_position - ship_position).length() > _ship.artillery_controller.get_params()._range

	# Calculate distance
	distance_to_target = (aim_position - ship_position).length() # Convert to km

	if launch_vector != null:
		time_to_target = launch_result[1] / ProjectileManager.shell_time_multiplier
		var can_shoot: Gun.ShootOver = Gun.sim_can_shoot_over_terrain_static(
			ship_position,
			launch_vector,
			launch_result[1],
			projectile_drag_coefficient,
			_ship
			)

		terrain_hit = not can_shoot.can_shoot_over_terrain

		var shell = _ship.artillery_controller.get_shell_params()
		if shell.type == ShellParams.ShellType.HE:
			penetration_power = shell.overmatch
		else:
			var velocity_at_impact_vec = ProjectilePhysicsWithDrag.calculate_velocity_at_time(
				launch_vector,
				launch_result[1],
				projectile_drag_coefficient
			)
			var velocity_at_impact = velocity_at_impact_vec.length()
			var raw_pen = _ArmorInteraction.calculate_de_marre_penetration(
				shell.mass,
				velocity_at_impact,
				shell.caliber)
			# var raw_pen = 1.0

			# Calculate impact angle (angle from vertical)
			var impact_angle = PI / 2 - velocity_at_impact_vec.normalized().angle_to(Vector3.UP)

			# Calculate effective penetration against vertical armor
			# Effective penetration = raw penetration * cos(impact_angle)
			penetration_power = raw_pen * cos(impact_angle)

	else:
		terrain_hit = false
		penetration_power = 0.0
		time_to_target = -1.0
		distance_to_target = -1.0



func is_position_visible_on_screen(world_position):
	var camera = get_viewport().get_camera_3d()

	# Check if position is in front of camera
	var camera_direction = - camera.global_transform.basis.z.normalized()
	var to_position = (world_position - camera.global_position).normalized()
	if camera_direction.dot(to_position) <= 0:
		return false

	# Get screen position
	var screen_position = camera.unproject_position(world_position)

	# Check if position is on screen
	var viewport_rect = get_viewport().get_visible_rect()
	return viewport_rect.has_point(screen_position)


func toggle_target_lock():
	# If already locked, disable the lock
	if target_lock_enabled:
		target_lock_enabled = false
		locked_target = null
		# Reset camera offsets
		sniper_view.camera_offset_horizontal = 0.0
		sniper_view.camera_offset_vertical = 0.0
		third_person_view.camera_offset_horizontal = 0.0
		third_person_view.camera_offset_vertical = 0.0
		return

	# Try to find a suitable target
	var closest_target = find_lockable_target()
	if closest_target:
		locked_target = closest_target
		target_lock_enabled = true
		# Reset camera offsets when locking a new target
		sniper_view.camera_offset_horizontal = 0.0
		sniper_view.camera_offset_vertical = 0.0
		third_person_view.camera_offset_horizontal = 0.0
		third_person_view.camera_offset_vertical = 0.0

func find_lockable_target():
	# Find all ships in the scene
	var potential_targets = []
	var ships = get_node("/root/Server/GameWorld/Players").get_children()

	for ship in ships:
		# Skip the player's own ship
		if ship == _ship or not (ship is Ship):
			continue

		# Check if ship is in view and within reasonable range
		if is_position_visible_on_screen(ship.global_position):
			# Check if ship is an enemy (could use team logic here)
			var my_team_id = -1
			if _ship.team and _ship.team.has_method("get_team_info"):
				my_team_id = _ship.team.get_team_info()["team_id"]

			var ship_team_id = -2
			if ship.team and ship.team.has_method("get_team_info"):
				ship_team_id = ship.team.get_team_info()["team_id"]

			# Prioritize enemy ships
			if my_team_id != ship_team_id and ship.health_controller.is_alive() and ship.visible_to_enemy:
				# Calculate screen position and center distance
				var screen_pos = get_viewport().get_camera_3d().unproject_position(ship.global_position)
				var screen_center = get_viewport().get_visible_rect().size / 2.0
				var center_distance = screen_pos.distance_to(screen_center)

				potential_targets.append({
					"ship": ship,
					"distance": center_distance,
					"world_distance": _ship.global_position.distance_to(ship.global_position)
				})

	# Find closest target to screen center
	var closest_target = null
	var closest_distance = INF

	for target in potential_targets:
		if target.distance < closest_distance:
			closest_target = target.ship
			closest_distance = target.distance

	return closest_target
