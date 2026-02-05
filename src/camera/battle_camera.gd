extends Camera3D

class_name BattleCamera
signal processed
# Ship to follow
@export var _ship: Ship
var follow_ship: Ship = null
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
@export var default_fov: float = 40.0
@export var min_fov: float = 2.0 # Very narrow for extreme distance aiming
@export var max_fov: float = 40.0 # Wide enough for general aiming
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

# var aim: Node3D
var ui # Will be CameraUIScene instance
var third_person_view: ThirdPersonViewV2
var free_look_view: ThirdPersonViewV2
var sniper_view: AimView
var current_view: CameraView # Current active view
var last_view: CameraView # Last active view before switching to free look
var ray_exclude: Array = [] # Nodes to exclude from raycasting

# Zoom smoothing for Godot 4.5
var zoom_accumulator: float = 0.0
var zoom_smoothing: float = 1.0 # Adjust this value to control smoothing

var audio_listener: AudioListener3D

func set_angle(angle: float):
	current_view.rot_h = angle

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
	audio_listener = get_node("AudioListener3D")

	# Register with Debug autoload
	if has_node("/root/Debug"):
		get_node("/root/Debug").register_camera(self)

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
		follow_ship = _ship
		ui.call_deferred("initialize_for_ship")

	third_person_view = ThirdPersonViewV2.new()
	third_person_view.ship = _ship
	third_person_view.player_controller = player_controller
	free_look_view = ThirdPersonViewV2.new()
	#free_look_view = FreeLookView.new()
	free_look_view.ship = _ship
	free_look_view.player_controller = player_controller
	sniper_view = AimView.new()
	sniper_view.ship = _ship
	sniper_view.player_controller = player_controller

	get_parent().add_child(third_person_view)
	get_parent().add_child(free_look_view)
	get_parent().add_child(sniper_view)
	#get_tree().root.add_child(aim)
	current_view = third_person_view
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
		# Set follow_ship to ship closest to screen center with Ctrl+J
		if event.pressed and event.keycode == KEY_J and event.ctrl_pressed:
			var closest_ship = find_ship_closest_to_screen_center()
			if closest_ship:
				follow_ship = closest_ship

	# if not free_look:
	# 	third_person_view.input(event)

var transition_time = 0.0
const TRANSITION_DURATION = 0.1
func _process(delta):

	var cam_to_ship = self.global_transform.origin - follow_ship.global_transform.origin
	var cam_to_ship_normalized = cam_to_ship.normalized()
	var cam_to_ship_distance = cam_to_ship.length()

	audio_listener.global_position = follow_ship.global_transform.origin + cam_to_ship_normalized * clamp(cam_to_ship_distance * 0.3, 80.0, 300.0)

	# Apply accumulated zoom smoothly
	if abs(zoom_accumulator) > 0.01:
		var zoom_delta = zoom_accumulator * zoom_smoothing
		_zoom_camera(zoom_delta)
		zoom_accumulator -= zoom_delta
	# Update camera position and rotation
	_update_target_lock()

	# Update Debug autoload with current follow ship
	if has_node("/root/Debug"):
		get_node("/root/Debug").set_follow_ship(follow_ship, _ship)

	#if last_non_free_look_mode == CameraMode.THIRD_PERSON:
		#third_person_view._update_camera_transform()
	#else:
		#sniper_view._update_camera_transform()


	# Calculate ship speed
	if _ship:
		var velocity = _ship.linear_velocity
		ship_speed = velocity.length() * 1.94384 / ShipMovementV2.SHIP_SPEED_MODIFIER # Convert m/s to knots


	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		current_mode = CameraMode.FREE_LOOK
		if not free_look:
			if last_non_free_look_mode == CameraMode.THIRD_PERSON:
				last_view = third_person_view
				free_look_view.rot_h = third_person_view.rot_h
				free_look_view.rot_v = third_person_view.rot_v
				#free_look_view.rotation_degrees_vertical = third_person_view.rotation_degrees_vertical
			elif last_non_free_look_mode == CameraMode.SNIPER:
				last_view = sniper_view
				free_look_view.rot_h = sniper_view.rot_h - PI
				#free_look_view.rotation_degrees_vertical = sniper_view.rotation_degrees_vertical
			transition_time = TRANSITION_DURATION
			current_view = free_look_view
		free_look = true
	else:
		current_mode = last_non_free_look_mode
		if last_view:
			transition_time = TRANSITION_DURATION
			current_view = last_view
			last_view = null
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

	_update_camera_transform(delta)

	# self.make_current()
	#ProjectileManager1.__process(delta)
	processed.emit(delta)

func _physics_process(delta):
	_calculate_target_info()

func _zoom_camera(zoom_amount):
	current_view.zoom_camera(zoom_amount)



func _handle_mouse_motion(event):
	# Only handle mouse motion if captured
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	current_view.handle_mouse_event(event)


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
	if locked_target:
		if locked_target.global_position.distance_to(_ship.global_position) > player_controller.current_weapon_controller.get_max_range():
			# target_lock_enabled = false
			toggle_target_lock()

	if target_lock_enabled and (!locked_target.visible_to_enemy or locked_target.health_controller.is_dead()):
		toggle_target_lock()

	if target_lock_enabled:
		third_person_view.set_vh(locked_target.global_position)
		sniper_view.set_vh(locked_target.global_position)

func _update_camera_transform(delta_time: float):
	if !_ship:
		return

	if free_look:
		free_look_view.update_transform()
	else:
		third_person_view.update_transform()
		sniper_view.update_transform()

	if transition_time <= 0.0:
		self.rotation = current_view.rotation
		self.global_position = current_view.global_position
		self.fov = current_view.current_fov
	else:
		# self.rotation = lerp(self.rotation, current_view.rotation, delta_time / transition_time)
		self.rotation.x = lerp_angle(self.rotation.x, current_view.rotation.x, delta_time / transition_time)
		self.rotation.y = lerp_angle(self.rotation.y, current_view.rotation.y, delta_time / transition_time)
		self.rotation.z = lerp_angle(self.rotation.z, current_view.rotation.z, delta_time / transition_time)
		self.global_position = lerp(self.global_position, current_view.global_position, delta_time / transition_time)
		self.fov = lerp(self.fov, current_view.current_fov, delta_time / transition_time)
		transition_time = clamp(transition_time - delta_time, 0.0, transition_time)

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




func set_camera_mode(mode):
	current_mode = mode

	_Debug.sphere(aim_position, 5)
	if mode == CameraMode.SNIPER:
		last_non_free_look_mode = CameraMode.SNIPER
		if target_lock_enabled:
			sniper_view.set_vh(locked_target.global_position)
			sniper_view.set_locked_rot(aim_position)
		else:
			sniper_view.set_vh(aim_position)
		current_view = sniper_view

	elif mode == CameraMode.THIRD_PERSON:
		last_non_free_look_mode = CameraMode.THIRD_PERSON
		if target_lock_enabled:
			third_person_view.set_vh(locked_target.global_position)
			third_person_view.set_locked_rot(aim_position)
		else:
			third_person_view.set_vh(aim_position)
		current_view = third_person_view

	transition_time = TRANSITION_DURATION
	_Debug.sphere.call_deferred(aim_position, 5, Color.GREEN)


func toggle_camera_mode():
	if current_mode == CameraMode.THIRD_PERSON:
		set_camera_mode(CameraMode.SNIPER)
	else:
		set_camera_mode(CameraMode.THIRD_PERSON)

func _calculate_target_info():
	# Get the direction the camera is facing
	var aim = current_view if last_view == null else last_view
	if target_lock_enabled and locked_target and is_instance_valid(locked_target):

		var aim_direction = - aim.basis.z.normalized()
		# Cast a ray to get target position (could be terrain, enemy, etc.)
		var ray_length = 200000.0 # 50km range for naval artillery
		var space_state = get_world_3d().direct_space_state
		var ray_origin = aim.global_position

		var ray_params = PhysicsRayQueryParameters3D.new()
		ray_params.from = ray_origin
		ray_params.to = ray_origin + aim_direction * ray_length
		ray_params.collision_mask = (1 << 1) | (1 << 3) # armor | water
		if ray_exclude.size() == 0:
			ray_exclude = recurs_collision_bodies(_ship)
		ray_params.exclude = ray_exclude

		ray_params.collide_with_areas = true
		ray_params.collide_with_bodies = true

		var result = space_state.intersect_ray(ray_params)

		if result:
			aim_position = result.position
		else:
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
			# # No collision, use a point far in the distance
			# aim_position = ray_origin + aim_direction * ray_length

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
	# aim_position.y = 0.0
	ui.minimap.aim_point = aim_position
	#minimap.aim_point = aim_position
	var dist = (aim_position - _ship.global_position)
	dist.y = 0.0
	distance_to_target = dist.length() # Convert to km

	# # Calculate launch vector using our projectile physics
	# var ship_position = _ship.global_position
	# var launch_result = ProjectilePhysicsWithDragV2.calculate_launch_vector(
	# 	ship_position,
	# 	aim_position,
	# 	_ship.artillery_controller.get_shell_params()
	# )

	# # Extract results
	# var launch_vector = launch_result[0]

	# #max_range_reached = launch_result[2]
	# max_range_reached = (aim_position - ship_position).length() > _ship.artillery_controller.get_params()._range

	# # Calculate distance


	# if launch_vector != null:
	# 	time_to_target = launch_result[1] / ProjectileManager.shell_time_multiplier
	# 	var can_shoot: Gun.ShootOver = Gun.sim_can_shoot_over_terrain_static(
	# 		ship_position,
	# 		launch_vector,
	# 		launch_result[1],
	# 		_ship.artillery_controller.get_shell_params(),
	# 		_ship
	# 		)

	# 	terrain_hit = not can_shoot.can_shoot_over_terrain

	# 	var shell = _ship.artillery_controller.get_shell_params()
	# 	if shell.type == ShellParams.ShellType.HE:
	# 		penetration_power = shell.overmatch
	# 	else:
	# 		var velocity_at_impact_vec = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
	# 			launch_vector,
	# 			launch_result[1],
	# 			_ship.artillery_controller.get_shell_params()
	# 		)
	# 		var velocity_at_impact = velocity_at_impact_vec.length()
	# 		var raw_pen = _ArmorInteraction.calculate_de_marre_penetration(
	# 			shell.mass,
	# 			velocity_at_impact,
	# 			shell.caliber)
	# 		# var raw_pen = 1.0

	# 		# Calculate impact angle (angle from vertical)
	# 		var impact_angle = PI / 2 - velocity_at_impact_vec.normalized().angle_to(Vector3.UP)

	# 		# Calculate effective penetration against vertical armor
	# 		# Effective penetration = raw penetration * cos(impact_angle)
	# 		penetration_power = raw_pen * cos(impact_angle)

	# else:
	# 	terrain_hit = false
	# 	penetration_power = 0.0
	# 	time_to_target = -1.0
	# 	distance_to_target = -1.0
	var aim_data = player_controller.current_weapon_controller.get_aim_ui()
	terrain_hit = aim_data.terrain_hit
	penetration_power = aim_data.penetration_power
	time_to_target = aim_data.time_to_target



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
	# pass
	# If already locked, disable the lock
	if target_lock_enabled:
		target_lock_enabled = false
		locked_target = null
		# Reset camera offsets
		sniper_view.rot_h += sniper_view.locked_rot_h
		sniper_view.rot_v += sniper_view.locked_rot_v
		sniper_view.locked_rot_h = 0.0
		sniper_view.locked_rot_v = 0.0
		sniper_view.locked_ship = null

		third_person_view.rot_h += third_person_view.locked_rot_h
		third_person_view.rot_v += third_person_view.locked_rot_v
		third_person_view.locked_rot_h = 0.0
		third_person_view.locked_rot_v = 0.0
		third_person_view.locked_ship = null
		return

	# Try to find a suitable target
	var closest_target = find_lockable_target()
	if closest_target:
		locked_target = closest_target
		target_lock_enabled = true
		# Reset camera offsets when locking a new target
		sniper_view.locked_rot_h = 0.0
		sniper_view.locked_rot_v = 0.0
		sniper_view.locked_ship = closest_target
		sniper_view.set_vh(closest_target.global_position)
		third_person_view.locked_rot_h = 0.0
		third_person_view.locked_rot_v = 0.0
		third_person_view.locked_ship = closest_target
		third_person_view.set_vh(closest_target.global_position)

func find_ship_closest_to_screen_center():
	# Find the ship closest to the center of the screen
	var ships = get_node("/root/Server/GameWorld/Players").get_children()
	var closest_ship = null
	var closest_distance = INF

	for ship in ships:
		if not (ship is Ship):
			continue

		# Check if ship is visible on screen
		if is_position_visible_on_screen(ship.global_position):
			var screen_pos = get_viewport().get_camera_3d().unproject_position(ship.global_position)
			var screen_center = get_viewport().get_visible_rect().size / 2.0
			var center_distance = screen_pos.distance_to(screen_center)

			if center_distance < closest_distance:
				closest_distance = center_distance
				closest_ship = ship

	return closest_ship

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
			if my_team_id != ship_team_id \
			and ship.health_controller.is_alive() \
			and ship.visible_to_enemy \
			and ship.global_position.distance_to(_ship.global_position) <= player_controller.current_weapon_controller.get_max_range():
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
