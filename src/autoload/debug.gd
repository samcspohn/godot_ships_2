# src/autoload/debug.gd
extends Node
class_name _Debug

# Bot debug drawing
var bot_debug_heading_vector: Vector3 = Vector3.ZERO
var bot_debug_target_ship: Ship = null
var bot_debug_active: bool = false
var bot_debug_request_timer: float = 0.0
var bot_debug_request_interval: float = 0.1  # Request debug info every 100ms
var bot_debug_arrow: MeshInstance3D = null
var bot_debug_target_indicator: MeshInstance3D = null
var bot_debug_follow_ship: Ship = null

# Turn simulation debug
var bot_debug_turn_sim_points_desired: Array[Vector3] = []
var bot_debug_turn_sim_points_undesired: Array[Vector3] = []
var bot_debug_turn_sim_frame_counter: int = 0
var bot_debug_turn_sim_draw_interval: int = 8  # Draw every 8 physics frames

# Reference to the player's camera (set by BattleCamera)
var battle_camera: BattleCamera = null


func _ready() -> void:
	set_process(true)
	set_physics_process(true)


func _process(delta: float) -> void:
	_update_bot_debug(delta)


func _physics_process(_delta: float) -> void:
	_update_turn_simulation_debug()


# Called by BattleCamera to register itself
func register_camera(camera: BattleCamera) -> void:
	battle_camera = camera


# Called by BattleCamera to update which ship we're following
func set_follow_ship(ship: Ship, player_ship: Ship) -> void:
	if ship != null and ship != player_ship:
		bot_debug_follow_ship = ship
	else:
		bot_debug_follow_ship = null
		bot_debug_target_ship = null
		bot_debug_active = false
		_clear_bot_debug_arrow()
		_clear_bot_debug_target_indicator()


func _update_bot_debug(delta: float) -> void:
	if bot_debug_follow_ship == null or not is_instance_valid(bot_debug_follow_ship):
		bot_debug_active = false
		_clear_bot_debug_arrow()
		return

	bot_debug_request_timer += delta
	if bot_debug_request_timer >= bot_debug_request_interval:
		bot_debug_request_timer = 0.0
		_request_bot_debug_info()

	# Always try to draw if we have a valid heading vector
	if bot_debug_heading_vector.length() > 0.1:
		bot_debug_active = true
		_draw_bot_debug_arrow()
		_draw_bot_debug_target_indicator()
		# Turn sim points are drawn in _physics_process


func _request_bot_debug_info() -> void:
	if bot_debug_follow_ship == null:
		return
	request_debug_info.rpc_id(1, bot_debug_follow_ship.get_path())

@rpc("any_peer", "call_remote", "reliable")
func request_debug_info(target_path: NodePath) -> void:
	var target = get_node(target_path)
	var bot_controller: BotControllerV3 = target.get_node("Modules/BotController")

	if bot_controller:
		var heading_vec = bot_controller.get_debug_heading_vector()
		var turn_sim_points_desired = bot_controller.get_turn_simulation_points_desired()
		var turn_sim_points_undesired = bot_controller.get_turn_simulation_points_undesired()
		var target_ship_path = null
		if bot_controller.target != null:
			target_ship_path = bot_controller.target.get_path()
		send_debug_info_to_client.rpc_id(multiplayer.get_remote_sender_id(), heading_vec, target_ship_path, turn_sim_points_desired, turn_sim_points_undesired)

@rpc("authority", "call_remote", "unreliable")
func send_debug_info_to_client(heading_vec: Vector3, target_ship_path: Variant, turn_sim_points_desired: Array = [], turn_sim_points_undesired: Array = []) -> void:
	# Forward the debug info to the Debug autoload
	bot_debug_heading_vector = heading_vec
	# bot_debug_target_path = target_path
	bot_debug_turn_sim_points_desired = turn_sim_points_desired
	bot_debug_turn_sim_points_undesired = turn_sim_points_undesired
	if target_ship_path != null:
		bot_debug_target_ship = get_node(target_ship_path)

# Called by BotControllerV3 RPC to update heading vector on client
func receive_bot_debug_info(heading_vector: Vector3, target_ship_path: NodePath, turn_sim_points_desired: Array = [], turn_sim_points_undesired: Array = []) -> void:
	bot_debug_heading_vector = heading_vector
	bot_debug_active = true

	# Store turn simulation points - desired
	bot_debug_turn_sim_points_desired.clear()
	for point in turn_sim_points_desired:
		if point is Vector3:
			bot_debug_turn_sim_points_desired.append(point)

	# Store turn simulation points - undesired
	bot_debug_turn_sim_points_undesired.clear()
	for point in turn_sim_points_undesired:
		if point is Vector3:
			bot_debug_turn_sim_points_undesired.append(point)

	# Resolve target ship from path
	if target_ship_path != NodePath(""):
		var target_node = get_node_or_null(target_ship_path)
		if target_node and target_node is Ship:
			bot_debug_target_ship = target_node
		else:
			bot_debug_target_ship = null
	else:
		bot_debug_target_ship = null


func _draw_bot_debug_arrow() -> void:
	if bot_debug_follow_ship == null:
		return

	# Create arrow mesh if it doesn't exist
	if bot_debug_arrow == null:
		bot_debug_arrow = MeshInstance3D.new()
		bot_debug_arrow.name = "BotDebugArrow"

		var arrow_mesh = CylinderMesh.new()
		arrow_mesh.top_radius = 0.0
		arrow_mesh.bottom_radius = 10.0
		arrow_mesh.height = 200.0
		arrow_mesh.radial_segments = 8
		bot_debug_arrow.mesh = arrow_mesh

		var material = StandardMaterial3D.new()
		material.albedo_color = Color(0, 1, 0, 1.0)  # Solid green
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true  # Always visible through objects
		bot_debug_arrow.material_override = material

		bot_debug_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		get_tree().root.add_child(bot_debug_arrow)

	# Position the arrow at the ship location, pointing in the desired heading direction
	var ship_pos = bot_debug_follow_ship.global_position
	ship_pos.y += 100.0  # Offset above the ship for visibility

	# Calculate the end position of the arrow (where it should point)
	var arrow_length = 200.0
	var end_pos = ship_pos + bot_debug_heading_vector.normalized() * arrow_length

	# Position at midpoint between ship and end
	var mid_pos = (ship_pos + end_pos) / 2.0
	bot_debug_arrow.global_position = mid_pos

	# Rotate to point in desired heading direction
	# The cylinder points up (+Y) by default with tip at top (top_radius=0)
	# We need to rotate +90 on X to make tip point forward (-Z), then rotate on Y for heading
	var heading_angle = atan2(bot_debug_heading_vector.x, bot_debug_heading_vector.z)
	bot_debug_arrow.rotation = Vector3(PI / 2.0, heading_angle, 0)
	bot_debug_arrow.visible = true

	# # Draw debug spheres to verify positions
	# _draw_debug_sphere(ship_pos, 20.0, Color.BLUE, 0.2)  # Ship position (blue)
	# _draw_debug_sphere(end_pos, 20.0, Color.RED, 0.2)    # End of heading vector (red)


func _clear_bot_debug_arrow() -> void:
	if bot_debug_arrow != null:
		bot_debug_arrow.visible = false


func _update_turn_simulation_debug() -> void:
	if not bot_debug_active or bot_debug_follow_ship == null:
		return

	bot_debug_turn_sim_frame_counter += 1
	if bot_debug_turn_sim_frame_counter >= bot_debug_turn_sim_draw_interval:
		bot_debug_turn_sim_frame_counter = 0
		_draw_turn_simulation_points()


func _draw_turn_simulation_points() -> void:
	# Draw desired turn points with green gradient (light green to dark green)
	var desired_count = bot_debug_turn_sim_points_desired.size()
	for i in range(desired_count):
		var point = bot_debug_turn_sim_points_desired[i]
		var t = float(i) / float(max(desired_count - 1, 1))
		var color = Color(0.0, 1.0 - t * 0.5, 0.0)  # Light green to dark green gradient
		_draw_debug_sphere(point, 15.0, color, 0.5)

	# Draw undesired turn points with yellow to orange gradient
	var undesired_count = bot_debug_turn_sim_points_undesired.size()
	for i in range(undesired_count):
		var point = bot_debug_turn_sim_points_undesired[i]
		var t = float(i) / float(max(undesired_count - 1, 1))
		var color = Color(1.0, 1.0 - t * 0.5, 0.0)  # Yellow to orange gradient
		_draw_debug_sphere(point, 15.0, color, 0.5)


## Draw a debug sphere at a global location. Can be called from anywhere via Debug.draw_sphere()
func draw_sphere(location: Vector3, size: float = 10.0, color: Color = Color(1, 0, 0), duration: float = 3.0) -> void:
	_draw_debug_sphere(location, size, color, duration)


## Static-style helper for drawing debug spheres from other scripts
static func sphere(location: Vector3, size: float = 10.0, color: Color = Color(1, 0, 0), duration: float = 3.0) -> void:
	var debug_node = Engine.get_main_loop().root.get_node_or_null("/root/Debug")
	if debug_node:
		debug_node.draw_sphere(location, size, color, duration)


func _draw_bot_debug_target_indicator() -> void:
	if bot_debug_target_ship == null or not is_instance_valid(bot_debug_target_ship):
		_clear_bot_debug_target_indicator()
		return

	# Create target indicator mesh if it doesn't exist
	if bot_debug_target_indicator == null:
		bot_debug_target_indicator = MeshInstance3D.new()
		bot_debug_target_indicator.name = "BotDebugTargetIndicator"

		# Create a diamond/rhombus shape using two cones
		var indicator_mesh = CylinderMesh.new()
		indicator_mesh.top_radius = 0.0
		indicator_mesh.bottom_radius = 30.0
		indicator_mesh.height = 60.0
		indicator_mesh.radial_segments = 4  # Diamond shape
		bot_debug_target_indicator.mesh = indicator_mesh

		var material = StandardMaterial3D.new()
		material.albedo_color = Color(1.0, 0.0, 0.0, 1.0)  # Solid red
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true  # Always visible through objects
		bot_debug_target_indicator.material_override = material

		bot_debug_target_indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		get_tree().root.add_child(bot_debug_target_indicator)

	# Position the indicator above the target ship
	var target_pos = bot_debug_target_ship.global_position
	target_pos.y += 150.0  # Offset above the target ship
	bot_debug_target_indicator.global_position = target_pos

	# Point downward toward the target
	bot_debug_target_indicator.rotation = Vector3(PI, 0, 0)
	bot_debug_target_indicator.visible = true


func _clear_bot_debug_target_indicator() -> void:
	if bot_debug_target_indicator != null:
		bot_debug_target_indicator.visible = false


## Internal helper to draw a debug sphere
func _draw_debug_sphere(location: Vector3, size: float = 10.0, color: Color = Color(1, 0, 0), duration: float = 3.0) -> void:
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radial_segments = 4
	sphere_mesh.rings = 4
	sphere_mesh.radius = size
	sphere_mesh.height = size * 2

	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere_mesh.surface_set_material(0, material)

	var node = MeshInstance3D.new()
	node.mesh = sphere_mesh

	var t = Timer.new()
	t.wait_time = duration
	t.timeout.connect(func():
		node.queue_free()
	)
	t.autostart = true
	node.add_child(t)

	get_tree().root.add_child(node)
	node.global_transform.origin = location
