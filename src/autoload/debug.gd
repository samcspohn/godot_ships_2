# src/autoload/debug.gd
extends Node
class_name _Debug

# Bot debug drawing
var bot_debug_heading_vector: Vector3 = Vector3.ZERO
var bot_debug_heading_rudder_vector: Vector3 = Vector3.ZERO
var bot_debug_target_ship: Ship = null
var bot_debug_active: bool = false
var bot_debug_request_timer: float = 0.0
var bot_debug_request_interval: float = 1.0  # Request debug info every frame
var bot_debug_arrow: MeshInstance3D = null
var bot_debug_heading_rudder_arrow: MeshInstance3D = null
var bot_debug_target_indicator: MeshInstance3D = null
var bot_debug_follow_ship: Ship = null

# Turn simulation debug
var bot_debug_turn_sim_points_desired: Array[Vector3] = []
var bot_debug_turn_sim_points_undesired: Array[Vector3] = []
var bot_debug_turn_sim_frame_counter: int = 0
var bot_debug_turn_sim_draw_interval: int = 20  # Draw every physics frame

# Navigation path debug
var bot_debug_nav_path: PackedVector3Array = PackedVector3Array()
var bot_debug_nav_path_spheres: Array[MeshInstance3D] = []

# Forward simulation path debug (physics-validated path to target)
var bot_debug_simulated_path: PackedVector3Array = PackedVector3Array()
var bot_debug_simulated_path_mesh: MeshInstance3D = null
var bot_debug_simulated_path_spheres: Array[MeshInstance3D] = []

# Threat and safe vector debug
var bot_debug_threat_vector: Vector3 = Vector3.ZERO
var bot_debug_safe_vector: Vector3 = Vector3.ZERO
var bot_debug_threat_weight: float = 0.0
var bot_debug_threat_arrow: MeshInstance3D = null
var bot_debug_safe_arrow: MeshInstance3D = null

# Throttle indicator debug
var bot_debug_throttle: int = 0
var bot_debug_throttle_arrow: MeshInstance3D = null
var bot_debug_throttle_sphere: MeshInstance3D = null

# Reference to the player's camera (set by BattleCamera)
var battle_camera: BattleCamera = null

# Clearance circle debug
var bot_debug_clearance_radius: float = 0.0
var bot_debug_clearance_circle: MeshInstance3D = null
var bot_debug_soft_clearance_radius: float = 0.0
var bot_debug_soft_clearance_circle: MeshInstance3D = null

# SDF tile debug
var bot_debug_sdf_tiles: Array[MeshInstance3D] = []
var bot_debug_sdf_tile_data: PackedFloat32Array = PackedFloat32Array()  # [x, z, sdf, x, z, sdf, ...]
var bot_debug_sdf_tile_draw_interval: int = 20  # Redraw SDF tiles every physics frame
var bot_debug_sdf_tile_frame_counter: int = 0

# Island cover debug
var bot_debug_cover_island_center: Vector3 = Vector3.ZERO
var bot_debug_cover_island_radius: float = 0.0
var bot_debug_cover_safe_dist: float = 0.0        # SDF distance at cover position (distance to shore)
var bot_debug_cover_zone_center: Vector3 = Vector3.ZERO
var bot_debug_cover_zone_radius: float = 0.0
var bot_debug_cover_zone_valid: bool = false
var bot_debug_cover_in_cover: bool = false
var bot_debug_cover_spotted_in_cover: bool = false
var bot_debug_cover_hidden_count: int = 0
var bot_debug_cover_total_threats: int = 0
var bot_debug_cover_all_hidden: bool = false
var bot_debug_cover_can_shoot: bool = false
var bot_debug_cover_sdf_distance: float = 0.0
var bot_debug_cover_island_circle: MeshInstance3D = null
var bot_debug_cover_safe_circle: MeshInstance3D = null
var bot_debug_cover_zone_circle: MeshInstance3D = null
var bot_debug_cover_zone_center_sphere: MeshInstance3D = null
var bot_debug_cover_los_lines: Array[MeshInstance3D] = []

# CA tactical debug — enemy clusters + nearby islands
var bot_debug_ca_enemy_clusters: Array = []        # [{center: Vector3, ship_count: int}]
var bot_debug_ca_nearby_islands: Array = []         # [{center: Vector3, radius: float}]
var bot_debug_ca_cluster_spheres: Array[MeshInstance3D] = []
var bot_debug_ca_island_circles: Array[MeshInstance3D] = []

# World-space debug label
var bot_debug_world_label: Label3D = null
var bot_debug_nav_state: String = ""


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
		_clear_bot_debug_heading_rudder_arrow()
		_clear_bot_debug_target_indicator()
		_clear_bot_debug_nav_path()
		_clear_bot_debug_simulated_path()
		_clear_bot_debug_threat_arrow()
		_clear_bot_debug_safe_arrow()
		_clear_bot_debug_clearance_circle()
		_clear_bot_debug_soft_clearance_circle()
		_clear_bot_debug_sdf_tiles()
		_clear_bot_debug_cover_circles()


func _update_bot_debug(delta: float) -> void:
	if bot_debug_follow_ship == null or not is_instance_valid(bot_debug_follow_ship):
		bot_debug_active = false
		_clear_bot_debug_arrow()
		_clear_bot_debug_heading_rudder_arrow()
		_clear_bot_debug_nav_path()
		_clear_bot_debug_simulated_path()
		_clear_bot_debug_threat_arrow()
		_clear_bot_debug_safe_arrow()
		_clear_bot_debug_clearance_circle()
		_clear_bot_debug_soft_clearance_circle()
		_clear_bot_debug_sdf_tiles()
		_clear_bot_debug_cover_circles()
		_clear_bot_debug_throttle_indicator()
		_clear_ca_tactical_debug()
		return

	bot_debug_request_timer += delta
	if bot_debug_request_timer >= bot_debug_request_interval:
		bot_debug_request_timer = 0.0
		_request_bot_debug_info()

	# Always try to draw if we have a valid heading vector
	if bot_debug_heading_vector.length() > 0.1:
		bot_debug_active = true
		_draw_bot_debug_arrow()
		_draw_bot_debug_heading_rudder_arrow()
		_draw_bot_debug_target_indicator()
		_draw_bot_debug_threat_arrow()
		_draw_bot_debug_safe_arrow()
		_draw_bot_debug_clearance_circle()
		_draw_bot_debug_soft_clearance_circle()
		_draw_bot_debug_cover_circles()
		_draw_bot_debug_throttle_indicator()
		_draw_ca_tactical_debug()
		_draw_bot_debug_world_label()
		# Turn sim points and SDF tiles are drawn in _physics_process


func _request_bot_debug_info() -> void:
	if bot_debug_follow_ship == null:
		return
	request_debug_info.rpc_id(1, bot_debug_follow_ship.get_path())

@rpc("any_peer", "call_remote", "reliable")
func request_debug_info(target_path: NodePath) -> void:
	var target = get_node(target_path)
	var bot_controller = target.get_node_or_null("Modules/BotController")

	if bot_controller:
		var heading_vec = bot_controller.get_debug_heading_vector()
		var heading_rudder_vec = bot_controller.get_debug_heading_rudder_vector()
		var turn_sim_points_desired = bot_controller.get_turn_simulation_points_desired()
		var turn_sim_points_undesired = bot_controller.get_turn_simulation_points_undesired()
		var nav_path = bot_controller.get_debug_nav_path()
		# Prepend the ship's current position so the path always shows a line
		# from the ship to the next waypoint. get_current_path() only returns
		# remaining waypoints, so for LOS paths (2 pts) the first is skipped
		# immediately, leaving 0-1 points and nothing to draw.
		if nav_path.size() > 0:
			nav_path = PackedVector3Array([target.global_position]) + nav_path
		var threat_vec = bot_controller.get_debug_threat_vector()
		var safe_vec = bot_controller.get_debug_safe_vector()
		var threat_weight = bot_controller.get_debug_threat_weight()
		var target_ship_path = null
		if bot_controller.target != null:
			target_ship_path = bot_controller.target.get_path()

		# Get clearance radii from the navigator if V4
		var clearance_r: float = 0.0
		var soft_clearance_r: float = 0.0
		var simulated_path: PackedVector3Array = PackedVector3Array()
		var throttle_val: int = 0
		if bot_controller is BotControllerV4 and bot_controller.navigator != null:
			clearance_r = bot_controller.navigator.get_clearance_radius()
			soft_clearance_r = bot_controller.navigator.get_soft_clearance_radius()
			simulated_path = bot_controller.get_debug_simulated_path()
			throttle_val = bot_controller.get_debug_throttle()

		# Sample SDF tiles near the ship for debug visualization
		var sdf_data := _sample_sdf_tiles_near(target.global_position, 1000.0, clearance_r)

		send_debug_info_to_client.rpc_id(multiplayer.get_remote_sender_id(), heading_vec, heading_rudder_vec, target_ship_path, turn_sim_points_desired, turn_sim_points_undesired, nav_path, threat_vec, safe_vec, threat_weight, clearance_r, soft_clearance_r, sdf_data, simulated_path, throttle_val)

		# --- Island cover debug (separate RPC to avoid bloating the main one) ---
		_send_cover_debug(bot_controller, target, multiplayer.get_remote_sender_id())

		# --- CA tactical debug: enemy clusters + nearby islands ---
		_send_ca_tactical_debug(bot_controller, target, multiplayer.get_remote_sender_id())

		# --- World-space label debug ---
		_send_world_label_debug(bot_controller, multiplayer.get_remote_sender_id())

func _send_cover_debug(bot_controller, target_ship: Node, sender_id: int) -> void:
	"""Gather island cover debug data from the behavior and send to client."""
	var cover_data: Dictionary = {}
	cover_data["valid"] = false

	if bot_controller is BotControllerV4 and bot_controller.behavior != null:
		var behavior = bot_controller.behavior
		if behavior is CABehavior:
			var ca: CABehavior = behavior
			cover_data["valid"] = ca._cover_zone_valid
			cover_data["island_center"] = ca._cover_island_center
			cover_data["island_radius"] = ca._cover_island_radius
			cover_data["zone_center"] = ca._cover_zone_center
			cover_data["zone_radius"] = ca._cover_zone_radius
			cover_data["in_cover"] = ca.is_in_cover
			cover_data["spotted_in_cover"] = ca.is_in_cover and target_ship is Ship and (target_ship as Ship).visible_to_enemy

			# SDF-cell-based cover metadata (some fields removed in rework — use defaults)
			cover_data["all_hidden"] = false
			cover_data["can_shoot"] = ca._cover_can_shoot
			cover_data["sdf_distance"] = 0.0
			cover_data["cover_hidden_count"] = 0

			# Safe distance: use ship clearance as fallback
			var ship_clearance: float = 100.0
			if target_ship is Ship and (target_ship as Ship).movement_controller:
				ship_clearance = (target_ship as Ship).movement_controller.ship_beam * 0.5 + 50.0
			cover_data["safe_dist"] = ship_clearance + 50.0

			# Gather threat LOS data from the ship's actual position.
			# This shows whether the ship is currently hidden or exposed — far
			# more useful than testing from the zone center.
			var ship_pos: Vector3 = (target_ship as Ship).global_position
			var threats: Array = ca._gather_threat_positions(target_ship as Ship)
			cover_data["total_threats"] = threats.size()
			cover_data["ship_pos"] = ship_pos
			var hidden_count: int = 0
			var los_lines: Array = []  # [{from: V3, to: V3, blocked: bool}]
			for threat_pos in threats:
				var blocked = NavigationMapManager.is_los_blocked(ship_pos, threat_pos)
				if blocked:
					hidden_count += 1
				los_lines.append({
					"from": ship_pos,
					"to": threat_pos,
					"blocked": blocked,
				})
			cover_data["hidden_count"] = hidden_count
			cover_data["los_lines"] = los_lines

	_receive_cover_debug.rpc_id(sender_id, cover_data)


func _send_ca_tactical_debug(bot_controller, target_ship: Node, sender_id: int) -> void:
	"""Gather enemy cluster and nearby island data for CA tactical debug overlay."""
	var tac_data: Dictionary = {}
	tac_data["valid"] = false

	if not (target_ship is Ship):
		_receive_ca_tactical_debug.rpc_id(sender_id, tac_data)
		return

	var ship: Ship = target_ship as Ship
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	if server_node == null:
		_receive_ca_tactical_debug.rpc_id(sender_id, tac_data)
		return

	tac_data["valid"] = true

	# Enemy clusters (known to this team)
	var clusters = server_node.get_enemy_clusters(ship.team.team_id)
	var cluster_list: Array = []
	for cluster in clusters:
		cluster_list.append({
			"center": cluster.center,
			"ship_count": cluster.ships.size(),
		})
	tac_data["clusters"] = cluster_list

	# Nearby islands within 10km
	var my_pos = ship.global_position
	var island_list: Array = []
	if NavigationMapManager.is_map_ready():
		var islands = NavigationMapManager.get_islands()
		for isl in islands:
			var center_2d: Vector2 = isl["center"]
			var isl_pos = Vector3(center_2d.x, 0.0, center_2d.y)
			var isl_radius: float = isl["radius"]
			var eff_dist = isl_pos.distance_to(my_pos) - isl_radius
			if eff_dist <= 10000.0:
				island_list.append({
					"center": isl_pos,
					"radius": isl_radius,
				})
	tac_data["islands"] = island_list

	_receive_ca_tactical_debug.rpc_id(sender_id, tac_data)


const NAV_STATE_NAMES: Array[String] = [
	"PLANNING", "NAVIGATING", "ARRIVING", "SETTLING", "HOLDING", "AVOIDING", "EMERGENCY"
]

func _send_world_label_debug(bot_controller, sender_id: int) -> void:
	var label_data: Dictionary = {}
	if bot_controller is BotControllerV4 and bot_controller.navigator != null:
		var state_idx: int = bot_controller.navigator.get_nav_state()
		if state_idx >= 0 and state_idx < NAV_STATE_NAMES.size():
			label_data["nav_state"] = NAV_STATE_NAMES[state_idx]
		else:
			label_data["nav_state"] = "UNKNOWN(%d)" % state_idx
	_receive_world_label_debug.rpc_id(sender_id, label_data)

@rpc("authority", "call_remote", "unreliable")
func _receive_world_label_debug(label_data: Dictionary) -> void:
	bot_debug_nav_state = label_data.get("nav_state", "")


@rpc("authority", "call_remote", "unreliable")
func _receive_ca_tactical_debug(tac_data: Dictionary) -> void:
	"""Client receives CA tactical debug data."""
	if not tac_data.get("valid", false):
		bot_debug_ca_enemy_clusters.clear()
		bot_debug_ca_nearby_islands.clear()
		return

	bot_debug_ca_enemy_clusters = tac_data.get("clusters", [])
	bot_debug_ca_nearby_islands = tac_data.get("islands", [])


@rpc("authority", "call_remote", "unreliable")
func _receive_cover_debug(cover_data: Dictionary) -> void:
	"""Client receives cover debug data and stores it for drawing."""
	bot_debug_cover_zone_valid = cover_data.get("valid", false)
	if not bot_debug_cover_zone_valid:
		bot_debug_cover_island_center = Vector3.ZERO
		bot_debug_cover_island_radius = 0.0
		bot_debug_cover_safe_dist = 0.0
		bot_debug_cover_zone_center = Vector3.ZERO
		bot_debug_cover_zone_radius = 0.0
		bot_debug_cover_in_cover = false
		bot_debug_cover_spotted_in_cover = false
		bot_debug_cover_hidden_count = 0
		bot_debug_cover_total_threats = 0
		return

	bot_debug_cover_island_center = cover_data.get("island_center", Vector3.ZERO)
	bot_debug_cover_island_radius = cover_data.get("island_radius", 0.0)
	bot_debug_cover_safe_dist = cover_data.get("safe_dist", 0.0)
	bot_debug_cover_zone_center = cover_data.get("zone_center", Vector3.ZERO)
	bot_debug_cover_zone_radius = cover_data.get("zone_radius", 0.0)
	bot_debug_cover_in_cover = cover_data.get("in_cover", false)
	bot_debug_cover_spotted_in_cover = cover_data.get("spotted_in_cover", false)
	bot_debug_cover_hidden_count = cover_data.get("hidden_count", 0)
	bot_debug_cover_total_threats = cover_data.get("total_threats", 0)
	# New SDF-cell-based metadata (stored for potential debug overlay use)
	bot_debug_cover_all_hidden = cover_data.get("all_hidden", false)
	bot_debug_cover_can_shoot = cover_data.get("can_shoot", false)
	bot_debug_cover_sdf_distance = cover_data.get("sdf_distance", 0.0)

	# Draw LOS lines (fire-and-forget with short lifetime)
	_clear_cover_los_lines()
	var los_lines: Array = cover_data.get("los_lines", [])
	for line_data in los_lines:
		var from_pos: Vector3 = line_data.get("from", Vector3.ZERO)
		var to_pos: Vector3 = line_data.get("to", Vector3.ZERO)
		var blocked: bool = line_data.get("blocked", false)
		# Green = blocked (hidden), Red = visible (exposed)
		var color = Color(0.0, 1.0, 0.0, 0.6) if blocked else Color(1.0, 0.0, 0.0, 0.8)
		var line_mesh = _create_los_line(from_pos, to_pos, color)
		if line_mesh != null:
			get_tree().root.add_child(line_mesh)
			bot_debug_cover_los_lines.append(line_mesh)


@rpc("authority", "call_remote", "unreliable")
func send_debug_info_to_client(heading_vec: Vector3, heading_rudder_vec: Vector3, target_ship_path: Variant, turn_sim_points_desired: Array = [], turn_sim_points_undesired: Array = [], nav_path: PackedVector3Array = PackedVector3Array(), threat_vec: Vector3 = Vector3.ZERO, safe_vec: Vector3 = Vector3.ZERO, threat_weight: float = 0.0, clearance_radius: float = 0.0, soft_clearance_radius: float = 0.0, sdf_data: PackedFloat32Array = PackedFloat32Array(), simulated_path: PackedVector3Array = PackedVector3Array(), throttle: int = 0) -> void:
	# Forward the debug info to the Debug autoload
	bot_debug_heading_vector = heading_vec
	bot_debug_heading_rudder_vector = heading_rudder_vec
	# bot_debug_target_path = target_path
	bot_debug_turn_sim_points_desired = turn_sim_points_desired
	bot_debug_turn_sim_points_undesired = turn_sim_points_undesired
	bot_debug_nav_path = nav_path
	bot_debug_threat_vector = threat_vec
	bot_debug_safe_vector = safe_vec
	bot_debug_threat_weight = threat_weight
	bot_debug_clearance_radius = clearance_radius
	bot_debug_soft_clearance_radius = soft_clearance_radius
	bot_debug_sdf_tile_data = sdf_data
	bot_debug_simulated_path = simulated_path
	bot_debug_throttle = throttle
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


func _draw_bot_debug_heading_rudder_arrow() -> void:
	if bot_debug_follow_ship == null:
		return

	if bot_debug_heading_rudder_vector.length() < 0.1:
		return

	# Create arrow mesh if it doesn't exist
	if bot_debug_heading_rudder_arrow == null:
		bot_debug_heading_rudder_arrow = MeshInstance3D.new()
		bot_debug_heading_rudder_arrow.name = "BotDebugHeadingRudderArrow"

		var arrow_mesh = CylinderMesh.new()
		arrow_mesh.top_radius = 0.0
		arrow_mesh.bottom_radius = 8.0
		arrow_mesh.height = 180.0
		arrow_mesh.radial_segments = 8
		bot_debug_heading_rudder_arrow.mesh = arrow_mesh

		var material = StandardMaterial3D.new()
		material.albedo_color = Color(0, 1, 1, 1.0)  # Cyan color for heading+rudder
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true  # Always visible through objects
		bot_debug_heading_rudder_arrow.material_override = material

		bot_debug_heading_rudder_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		get_tree().root.add_child(bot_debug_heading_rudder_arrow)

	# Position the arrow at the ship location, pointing in the heading+rudder direction
	var ship_pos = bot_debug_follow_ship.global_position
	ship_pos.y += 80.0  # Slightly lower than the desired heading arrow

	# Calculate the end position of the arrow (where it should point)
	var arrow_length = 180.0
	var end_pos = ship_pos + bot_debug_heading_rudder_vector.normalized() * arrow_length

	# Position at midpoint between ship and end
	var mid_pos = (ship_pos + end_pos) / 2.0
	bot_debug_heading_rudder_arrow.global_position = mid_pos

	# Rotate to point in heading+rudder direction
	var heading_angle = atan2(bot_debug_heading_rudder_vector.x, bot_debug_heading_rudder_vector.z)
	bot_debug_heading_rudder_arrow.rotation = Vector3(PI / 2.0, heading_angle, 0)
	bot_debug_heading_rudder_arrow.visible = true


func _clear_bot_debug_heading_rudder_arrow() -> void:
	if bot_debug_heading_rudder_arrow != null:
		bot_debug_heading_rudder_arrow.visible = false


func _draw_bot_debug_threat_arrow() -> void:
	if bot_debug_follow_ship == null:
		return

	# # Only draw if there's a meaningful threat
	# if bot_debug_threat_vector.length() < 0.1 or bot_debug_threat_weight < 0.05:
	# 	_clear_bot_debug_threat_arrow()
	# 	return

	# Create arrow mesh if it doesn't exist
	if bot_debug_threat_arrow == null:
		bot_debug_threat_arrow = MeshInstance3D.new()
		bot_debug_threat_arrow.name = "BotDebugThreatArrow"

		var arrow_mesh = CylinderMesh.new()
		arrow_mesh.top_radius = 0.0
		arrow_mesh.bottom_radius = 8.0
		arrow_mesh.height = 200.0
		arrow_mesh.radial_segments = 8
		bot_debug_threat_arrow.mesh = arrow_mesh

		var material = StandardMaterial3D.new()
		material.albedo_color = Color(1.0, 0.3, 0.0, 1.0)  # Orange color for threat
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		bot_debug_threat_arrow.material_override = material

		bot_debug_threat_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		get_tree().root.add_child(bot_debug_threat_arrow)

	# Position the arrow at the ship location, pointing toward the threat
	var ship_pos = bot_debug_follow_ship.global_position
	ship_pos.y += 60.0

	# Scale arrow length by threat weight
	var arrow_length = 200.0 * bot_debug_threat_weight
	var threat_dir = bot_debug_threat_vector.normalized()
	var end_pos = ship_pos + threat_dir * arrow_length

	var mid_pos = (ship_pos + end_pos) / 2.0
	bot_debug_threat_arrow.global_position = mid_pos

	# Rotate to point toward threat
	var heading_angle = atan2(threat_dir.x, threat_dir.z)
	bot_debug_threat_arrow.rotation = Vector3(PI / 2.0, heading_angle, 0)
	bot_debug_threat_arrow.scale = Vector3(1.0, bot_debug_threat_weight, 1.0)
	bot_debug_threat_arrow.visible = true


func _clear_bot_debug_threat_arrow() -> void:
	if bot_debug_threat_arrow != null:
		bot_debug_threat_arrow.visible = false


func _draw_bot_debug_safe_arrow() -> void:
	if bot_debug_follow_ship == null:
		return

	# # Only draw if there's a meaningful threat (safe is opposite of threat)
	# if bot_debug_safe_vector.length() < 0.1 or bot_debug_threat_weight < 0.05:
	# 	_clear_bot_debug_safe_arrow()
	# 	return

	# Create arrow mesh if it doesn't exist
	if bot_debug_safe_arrow == null:
		bot_debug_safe_arrow = MeshInstance3D.new()
		bot_debug_safe_arrow.name = "BotDebugSafeArrow"

		var arrow_mesh = CylinderMesh.new()
		arrow_mesh.top_radius = 0.0
		arrow_mesh.bottom_radius = 8.0
		arrow_mesh.height = 200.0
		arrow_mesh.radial_segments = 8
		bot_debug_safe_arrow.mesh = arrow_mesh

		var material = StandardMaterial3D.new()
		material.albedo_color = Color(0.0, 1.0, 0.5, 1.0)  # Teal/mint color for safe direction
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		bot_debug_safe_arrow.material_override = material

		bot_debug_safe_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		get_tree().root.add_child(bot_debug_safe_arrow)

	# Position the arrow at the ship location, pointing toward safety
	var ship_pos = bot_debug_follow_ship.global_position
	ship_pos.y += 60.0

	# Scale arrow length by threat weight
	var arrow_length = 200.0 * bot_debug_threat_weight
	var safe_dir = bot_debug_safe_vector.normalized()
	var end_pos = ship_pos + safe_dir * arrow_length

	var mid_pos = (ship_pos + end_pos) / 2.0
	bot_debug_safe_arrow.global_position = mid_pos

	# Rotate to point toward safety
	var heading_angle = atan2(safe_dir.x, safe_dir.z)
	bot_debug_safe_arrow.rotation = Vector3(PI / 2.0, heading_angle, 0)
	bot_debug_safe_arrow.scale = Vector3(1.0, bot_debug_threat_weight, 1.0)
	bot_debug_safe_arrow.visible = true


func _clear_bot_debug_safe_arrow() -> void:
	if bot_debug_safe_arrow != null:
		bot_debug_safe_arrow.visible = false


func _draw_bot_debug_throttle_indicator() -> void:
	if bot_debug_follow_ship == null:
		return

	var ship_pos = bot_debug_follow_ship.global_position
	ship_pos.y += 120.0  # Above the other arrows

	# throttle == 0: red sphere (stopped)
	if bot_debug_throttle == 0:
		_clear_bot_debug_throttle_arrow()

		if bot_debug_throttle_sphere == null:
			bot_debug_throttle_sphere = MeshInstance3D.new()
			bot_debug_throttle_sphere.name = "BotDebugThrottleSphere"

			var sphere_mesh = SphereMesh.new()
			sphere_mesh.radial_segments = 8
			sphere_mesh.rings = 4
			sphere_mesh.radius = 15.0
			sphere_mesh.height = 30.0
			bot_debug_throttle_sphere.mesh = sphere_mesh

			var material = StandardMaterial3D.new()
			material.albedo_color = Color(1.0, 0.0, 0.0, 1.0)  # Red
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.no_depth_test = true
			bot_debug_throttle_sphere.material_override = material

			bot_debug_throttle_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			get_tree().root.add_child(bot_debug_throttle_sphere)

		bot_debug_throttle_sphere.global_position = ship_pos
		bot_debug_throttle_sphere.visible = true
		return

	# Non-zero throttle: hide sphere
	if bot_debug_throttle_sphere != null:
		bot_debug_throttle_sphere.visible = false

	# Determine arrow color and length
	var arrow_color: Color
	var arrow_length: float
	var full_length: float = 200.0

	if bot_debug_throttle == -1:
		# Reverse: yellow arrow pointing backward
		arrow_color = Color(1.0, 1.0, 0.0, 1.0)
		arrow_length = full_length * 0.5  # Half length for reverse
	elif bot_debug_throttle == 4:
		# Full throttle: blue, full length
		arrow_color = Color(0.0, 0.4, 1.0, 1.0)
		arrow_length = full_length
	else:
		# Throttle 1-3: green, proportional length
		arrow_color = Color(0.0, 1.0, 0.3, 1.0)
		arrow_length = full_length * (float(bot_debug_throttle) / 4.0)

	# Create or update the throttle arrow mesh
	if bot_debug_throttle_arrow == null:
		bot_debug_throttle_arrow = MeshInstance3D.new()
		bot_debug_throttle_arrow.name = "BotDebugThrottleArrow"

		var arrow_mesh = CylinderMesh.new()
		arrow_mesh.top_radius = 0.0
		arrow_mesh.bottom_radius = 9.0
		arrow_mesh.height = 1.0  # Will be scaled via node scale
		arrow_mesh.radial_segments = 8
		bot_debug_throttle_arrow.mesh = arrow_mesh

		var material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		bot_debug_throttle_arrow.material_override = material

		bot_debug_throttle_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(bot_debug_throttle_arrow)

	# Update color on the material each frame (throttle level can change)
	var mat := bot_debug_throttle_arrow.material_override as StandardMaterial3D
	mat.albedo_color = arrow_color

	# Use the ship's actual current forward direction (not desired heading)
	var ship_forward := -bot_debug_follow_ship.global_transform.basis.z
	var current_heading_vec := Vector3(ship_forward.x, 0.0, ship_forward.z).normalized()

	# For reverse, point arrow opposite to the ship's current heading
	var heading_vec: Vector3
	if bot_debug_throttle == -1:
		heading_vec = -current_heading_vec
	else:
		heading_vec = current_heading_vec

	var end_pos = ship_pos + heading_vec * arrow_length
	var mid_pos = (ship_pos + end_pos) / 2.0
	bot_debug_throttle_arrow.global_position = mid_pos

	var heading_angle = atan2(heading_vec.x, heading_vec.z)
	bot_debug_throttle_arrow.rotation = Vector3(PI / 2.0, heading_angle, 0)
	# Scale Y axis to control length (mesh height = 1.0 unit)
	bot_debug_throttle_arrow.scale = Vector3(1.0, arrow_length, 1.0)
	bot_debug_throttle_arrow.visible = true


func _clear_bot_debug_throttle_arrow() -> void:
	if bot_debug_throttle_arrow != null:
		bot_debug_throttle_arrow.visible = false


func _clear_bot_debug_throttle_indicator() -> void:
	_clear_bot_debug_throttle_arrow()
	if bot_debug_throttle_sphere != null:
		bot_debug_throttle_sphere.visible = false


func _draw_bot_debug_nav_path() -> void:
	# Clear existing path spheres
	_clear_bot_debug_nav_path()

	if bot_debug_nav_path.size() < 1:
		return

	# Draw spheres at each path point with a gradient from white to magenta.
	# Reverse waypoints use a darker color scheme.
	# First point is the ship's position (prepended on the server side),
	# so we skip drawing a sphere for index 0 and start the gradient from index 1.
	# Y channel encodes waypoint flags: 0=normal, 1=reverse, 2=departure, 3=reverse+departure
	var path_count = bot_debug_nav_path.size()
	for i in range(path_count):
		var point = bot_debug_nav_path[i]
		var wp_flags: int = int(point.y) if i > 0 else 0  # index 0 is prepended ship pos
		var is_reverse: bool = (wp_flags & 1) != 0
		point.y = 50.0  # Raise above water level for visibility

		var path_sphere = MeshInstance3D.new()
		path_sphere.name = "NavPathPoint_%d" % i

		# Waypoint spheres grow slightly toward destination
		var is_last = (i == path_count - 1)
		var sphere_radius = 30.0 if is_last else 20.0

		var sphere_mesh = SphereMesh.new()
		sphere_mesh.radius = sphere_radius
		sphere_mesh.height = sphere_radius * 2.0
		sphere_mesh.radial_segments = 8
		sphere_mesh.rings = 4
		path_sphere.mesh = sphere_mesh

		# Gradient from white (start) to magenta (end)
		# Reverse waypoints use a dark red/maroon color
		var t = float(i) / float(max(path_count - 1, 1))
		var color: Color
		if is_reverse:
			color = Color(0.5, 0.1, 0.1)  # Dark red for reverse
		else:
			color = Color(1.0, 1.0 - t, 1.0)  # White to magenta

		var material = StandardMaterial3D.new()
		material.albedo_color = color
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		path_sphere.material_override = material

		path_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(path_sphere)
		bot_debug_nav_path_spheres.append(path_sphere)
		path_sphere.global_position = point

	# Draw connecting lines between path points
	if path_count >= 2:
		var im := ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for i in range(path_count):
			var point = bot_debug_nav_path[i]
			im.surface_add_vertex(Vector3(point.x, 52.0, point.z))
		im.surface_end()

		var line_mat := StandardMaterial3D.new()
		line_mat.albedo_color = Color(1.0, 0.6, 1.0, 0.7)
		line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		line_mat.no_depth_test = true
		line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		var line_node := MeshInstance3D.new()
		line_node.name = "NavPathLine"
		line_node.mesh = im
		line_node.material_override = line_mat
		line_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(line_node)
		bot_debug_nav_path_spheres.append(line_node)



func _clear_bot_debug_nav_path() -> void:
	for path_sphere in bot_debug_nav_path_spheres:
		if is_instance_valid(path_sphere):
			path_sphere.queue_free()
	bot_debug_nav_path_spheres.clear()


# =============================================================================
# Forward simulation path — shows the physics-validated turning path to target
# Drawn as a connected line (cyan) with spheres at waypoint simplification points
# =============================================================================

func _draw_bot_debug_simulated_path() -> void:
	_clear_bot_debug_simulated_path()

	if bot_debug_simulated_path.size() < 2:
		return

	# --- Draw the full simulation path as a connected cyan line ---
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(bot_debug_simulated_path.size()):
		var point = bot_debug_simulated_path[i]
		im.surface_add_vertex(Vector3(point.x, 40.0, point.z))  # Raised above water
	im.surface_end()

	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.0, 0.9, 0.9, 0.8)  # Cyan, semi-transparent
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.no_depth_test = true
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	bot_debug_simulated_path_mesh = MeshInstance3D.new()
	bot_debug_simulated_path_mesh.name = "BotDebugSimulatedPathLine"
	bot_debug_simulated_path_mesh.mesh = im
	bot_debug_simulated_path_mesh.material_override = line_mat
	bot_debug_simulated_path_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(bot_debug_simulated_path_mesh)

	# --- Draw spheres at evenly sampled points along the path ---
	# Sample every Nth point to avoid clutter, plus always show first and last
	var point_count := bot_debug_simulated_path.size()
	var sample_stride := maxi(point_count / 30, 1)  # ~30 spheres max

	for i in range(0, point_count, sample_stride):
		var point = bot_debug_simulated_path[i]
		point.y = 40.0

		var sim_sphere := MeshInstance3D.new()
		sim_sphere.name = "SimPathPoint_%d" % i

		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 12.0
		sphere_mesh.height = 24.0
		sphere_mesh.radial_segments = 6
		sphere_mesh.rings = 3
		sim_sphere.mesh = sphere_mesh

		# Gradient from bright cyan (start) to deep teal (end)
		var t := float(i) / float(maxi(point_count - 1, 1))
		var color := Color(0.0, 1.0 - t * 0.5, 1.0 - t * 0.3, 0.9)

		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		sim_sphere.material_override = material

		sim_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(sim_sphere)
		bot_debug_simulated_path_spheres.append(sim_sphere)
		sim_sphere.global_position = point

	# Always draw the last point if it wasn't already drawn
	if point_count > 1 and (point_count - 1) % sample_stride != 0:
		var last_point = bot_debug_simulated_path[point_count - 1]
		last_point.y = 40.0

		var end_sphere := MeshInstance3D.new()
		end_sphere.name = "SimPathPoint_end"

		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 18.0
		sphere_mesh.height = 36.0
		sphere_mesh.radial_segments = 8
		sphere_mesh.rings = 4
		end_sphere.mesh = sphere_mesh

		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.0, 0.4, 0.7, 1.0)  # Deep teal for endpoint
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		end_sphere.material_override = material

		end_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(end_sphere)
		bot_debug_simulated_path_spheres.append(end_sphere)
		end_sphere.global_position = last_point


func _clear_bot_debug_simulated_path() -> void:
	if bot_debug_simulated_path_mesh != null:
		if is_instance_valid(bot_debug_simulated_path_mesh):
			bot_debug_simulated_path_mesh.queue_free()
		bot_debug_simulated_path_mesh = null
	for sim_sphere in bot_debug_simulated_path_spheres:
		if is_instance_valid(sim_sphere):
			sim_sphere.queue_free()
	bot_debug_simulated_path_spheres.clear()


func _update_turn_simulation_debug() -> void:
	if not bot_debug_active or bot_debug_follow_ship == null:
		return

	bot_debug_turn_sim_frame_counter += 1
	if bot_debug_turn_sim_frame_counter >= bot_debug_turn_sim_draw_interval:
		bot_debug_turn_sim_frame_counter = 0
		_draw_turn_simulation_points()
		_draw_bot_debug_nav_path()
		_draw_bot_debug_simulated_path()

	# SDF tile visualization at a slower rate (heavier)
	bot_debug_sdf_tile_frame_counter += 1
	if bot_debug_sdf_tile_frame_counter >= bot_debug_sdf_tile_draw_interval:
		bot_debug_sdf_tile_frame_counter = 0
		_draw_bot_debug_sdf_tiles()


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


# =============================================================================
# Debug drawable: Circle with radius and orientation
# =============================================================================

## Draw a debug circle (torus ring) at a world position.
## orientation: Euler angles (Vector3) — default Vector3(-PI/2, 0, 0) faces upward (XZ plane).
## segments: number of line segments used to approximate the circle.
func draw_circle_3d(center: Vector3, radius: float, orientation: Vector3 = Vector3.ZERO, color: Color = Color(0, 1, 0), line_width: float = 3.0, duration: float = 3.0) -> void:
	var node := _create_circle_mesh(radius, color, line_width)
	node.global_position = center
	# Default mesh lies in XZ (horizontal) — apply user orientation on top
	node.rotation = orientation
	_attach_lifetime(node, duration)
	get_tree().root.add_child(node)


## Create a MeshInstance3D ring (circle) using an ImmediateMesh of line segments.
func _create_circle_mesh(radius: float, color: Color, _line_width: float = 3.0, segments: int = 48) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(segments + 1):
		var angle = TAU * float(i) / float(segments)
		var x = cos(angle) * radius
		var z = sin(angle) * radius
		im.surface_add_vertex(Vector3(x, 0.0, z))
	im.surface_end()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var node := MeshInstance3D.new()
	node.mesh = im
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


# =============================================================================
# Debug drawable: Square/Rectangle with width, height, and orientation
# =============================================================================

## Draw a debug square/rectangle at a world position.
## width/height define the size in the local XZ plane before orientation is applied.
## orientation: Euler angles (Vector3) — default Vector3.ZERO means lying flat in XZ.
func draw_square_3d(center: Vector3, width: float, height: float, orientation: Vector3 = Vector3.ZERO, color: Color = Color(1, 1, 0), duration: float = 3.0, filled: bool = true) -> void:
	var node: MeshInstance3D
	if filled:
		node = _create_filled_square_mesh(width, height, color)
	else:
		node = _create_square_outline_mesh(width, height, color)
	node.global_position = center
	node.rotation = orientation
	_attach_lifetime(node, duration)
	get_tree().root.add_child(node)


## Create a filled square MeshInstance3D lying in the XZ plane centered at origin.
func _create_filled_square_mesh(width: float, height: float, color: Color) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	var hw := width * 0.5
	var hh := height * 0.5

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
	im.surface_add_vertex(Vector3(-hw, 0.0,  hh))
	im.surface_add_vertex(Vector3( hw, 0.0, -hh))
	im.surface_add_vertex(Vector3( hw, 0.0,  hh))
	im.surface_end()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # Visible from both sides

	var node := MeshInstance3D.new()
	node.mesh = im
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## Create a square outline (wireframe) MeshInstance3D lying in the XZ plane.
func _create_square_outline_mesh(width: float, height: float, color: Color) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	var hw := width * 0.5
	var hh := height * 0.5

	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
	im.surface_add_vertex(Vector3( hw, 0.0, -hh))
	im.surface_add_vertex(Vector3( hw, 0.0,  hh))
	im.surface_add_vertex(Vector3(-hw, 0.0,  hh))
	im.surface_add_vertex(Vector3(-hw, 0.0, -hh))  # Close the loop
	im.surface_end()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var node := MeshInstance3D.new()
	node.mesh = im
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## Attach a self-destructing timer to a node.
func _attach_lifetime(node: Node3D, duration: float) -> void:
	var t := Timer.new()
	t.wait_time = duration
	t.one_shot = true
	t.autostart = true
	t.timeout.connect(func(): node.queue_free())
	node.add_child(t)


# =============================================================================
# Clearance circle — horizontal ring showing ship's hard clearance zone
# =============================================================================

func _draw_bot_debug_clearance_circle() -> void:
	if bot_debug_follow_ship == null or bot_debug_clearance_radius <= 0.0:
		_clear_bot_debug_clearance_circle()
		return

	# Recreate each frame to keep mesh in sync with radius (radius rarely changes,
	# but re-creating an ImmediateMesh is cheap)
	if bot_debug_clearance_circle != null:
		if is_instance_valid(bot_debug_clearance_circle):
			bot_debug_clearance_circle.queue_free()
		bot_debug_clearance_circle = null

	bot_debug_clearance_circle = _create_circle_mesh(
		bot_debug_clearance_radius,
		Color(0.2, 0.8, 1.0, 0.7),  # Light blue, semi-transparent
		3.0,
		64
	)
	bot_debug_clearance_circle.name = "BotDebugClearanceCircle"

	get_tree().root.add_child(bot_debug_clearance_circle)

	# Position at ship, flat on water (Y slightly above 0 to avoid z-fighting)
	var ship_pos := bot_debug_follow_ship.global_position
	bot_debug_clearance_circle.global_position = Vector3(ship_pos.x, 5.0, ship_pos.z)
	# Default orientation is already XZ horizontal — no rotation needed
	bot_debug_clearance_circle.visible = true


func _clear_bot_debug_clearance_circle() -> void:
	if bot_debug_clearance_circle != null:
		if is_instance_valid(bot_debug_clearance_circle):
			bot_debug_clearance_circle.queue_free()
		bot_debug_clearance_circle = null


func _draw_bot_debug_soft_clearance_circle() -> void:
	if bot_debug_follow_ship == null or bot_debug_soft_clearance_radius <= 0.0:
		_clear_bot_debug_soft_clearance_circle()
		return

	if bot_debug_soft_clearance_circle != null:
		if is_instance_valid(bot_debug_soft_clearance_circle):
			bot_debug_soft_clearance_circle.queue_free()
		bot_debug_soft_clearance_circle = null

	bot_debug_soft_clearance_circle = _create_circle_mesh(
		bot_debug_soft_clearance_radius,
		Color(1.0, 0.8, 0.0, 0.5),  # Yellow, semi-transparent
		3.0,
		64
	)
	bot_debug_soft_clearance_circle.name = "BotDebugSoftClearanceCircle"

	get_tree().root.add_child(bot_debug_soft_clearance_circle)

	var ship_pos := bot_debug_follow_ship.global_position
	bot_debug_soft_clearance_circle.global_position = Vector3(ship_pos.x, 4.0, ship_pos.z)
	bot_debug_soft_clearance_circle.visible = true


func _clear_bot_debug_soft_clearance_circle() -> void:
	if bot_debug_soft_clearance_circle != null:
		if is_instance_valid(bot_debug_soft_clearance_circle):
			bot_debug_soft_clearance_circle.queue_free()
		bot_debug_soft_clearance_circle = null


# =============================================================================
# SDF tile squares — show navigable/non-navigable tiles near the ship
# =============================================================================

## Sample SDF tiles near a world position on the SERVER and pack into a float array.
## Returns PackedFloat32Array of triples: [world_x, world_z, sdf_value, ...]
## Only called on the server where NavigationMapManager has the built map.
func _sample_sdf_tiles_near(world_pos: Vector3, range_m: float, clearance: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()

	if not NavigationMapManager.is_map_ready():
		return result

	var nav_map := NavigationMapManager.get_map()
	if nav_map == null:
		return result

	var cell_size: float = nav_map.get_cell_size_value()
	if cell_size <= 0.0:
		return result

	# Snap the search area to the grid so tiles align
	var half_range := range_m
	var start_x := snappedf(world_pos.x - half_range, cell_size)
	var start_z := snappedf(world_pos.z - half_range, cell_size)
	var end_x := world_pos.x + half_range
	var end_z := world_pos.z + half_range

	# Limit tile count to keep RPC payload reasonable
	# With cell_size=50 and range=1000 this is (2000/50)^2 = 1600 tiles × 3 floats = 4800 floats
	# That's fine for an unreliable debug RPC sent every 100ms
	var cx := start_x
	while cx <= end_x:
		var cz := start_z
		while cz <= end_z:
			var dist := nav_map.get_distance(cx, cz)
			# Only include tiles that are somewhat interesting (near land)
			# Skip deep open water to reduce payload
			if dist < clearance * 3.0:
				result.append(cx)
				result.append(cz)
				result.append(dist)
			cz += cell_size
		cx += cell_size

	return result


## Draw SDF tiles as filled squares on the client. Called periodically from _physics_process.
func _draw_bot_debug_sdf_tiles() -> void:
	_clear_bot_debug_sdf_tiles()

	if bot_debug_follow_ship == null or bot_debug_sdf_tile_data.size() < 3:
		return
	if bot_debug_clearance_radius <= 0.0:
		return

	# Determine cell size from the data spacing (or default to 50)
	var cell_size: float = 50.0
	if NavigationMapManager.is_map_ready():
		var nav_map := NavigationMapManager.get_map()
		if nav_map != null:
			cell_size = nav_map.get_cell_size_value()

	var clearance := bot_debug_clearance_radius
	var tile_count := bot_debug_sdf_tile_data.size() / 3

	for i in range(tile_count):
		var idx := i * 3
		var wx: float = bot_debug_sdf_tile_data[idx]
		var wz: float = bot_debug_sdf_tile_data[idx + 1]
		var sdf_val: float = bot_debug_sdf_tile_data[idx + 2]

		# Determine tile color based on SDF value relative to clearance
		var color: Color
		if sdf_val < -clearance:
			# Deep inside land — black
			color = Color(0.1, 0.1, 0.1, 0.35)
			# Note: the actual land contour is somewhere between sdf=0 and sdf=-clearance,
			# so we use a stronger red for values well below zero to indicate definitely non-navigable areas.
		elif sdf_val < 0.0:
			# Inside land — solid red
			color = Color(0.9, 0.1, 0.1, 0.35)
		elif sdf_val < clearance:
			# Too close for this ship — orange/yellow gradient
			var t := sdf_val / clearance
			color = Color(1.0, 0.3 + t * 0.5, 0.0, 0.3)
		else:
			# Navigable — green, more transparent the further from land
			var t := clampf((sdf_val - clearance) / (clearance * 2.0), 0.0, 1.0)
			color = Color(0.0, 0.7, 0.3, 0.25 - t * 0.15)

		# Create filled square lying flat on water
		var tile_mesh := _create_filled_square_mesh(cell_size * 0.9, cell_size * 0.9, color)
		tile_mesh.name = "SDFTile_%d" % i
		get_tree().root.add_child(tile_mesh)
		tile_mesh.global_position = Vector3(wx, 3.0, wz)  # Slightly above water
		tile_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		bot_debug_sdf_tiles.append(tile_mesh)


func _clear_bot_debug_sdf_tiles() -> void:
	for tile in bot_debug_sdf_tiles:
		if is_instance_valid(tile):
			tile.queue_free()
	bot_debug_sdf_tiles.clear()


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


# =============================================================================
# Island cover debug — circles for island radius, safe distance, cover zone
# =============================================================================

func _draw_bot_debug_cover_circles() -> void:
	if not bot_debug_cover_zone_valid or bot_debug_cover_island_radius <= 0.0:
		_clear_bot_debug_cover_circles()
		return

	var island_pos = bot_debug_cover_island_center
	var draw_y = 6.0  # Slightly above water

	# --- Island radius circle (orange) — NOTE: this is the bounding circle,
	#     not the actual island shape. The SDF-cell-based search uses the real
	#     island contour, so the cover position may be well inside this circle. ---
	if bot_debug_cover_island_circle != null and is_instance_valid(bot_debug_cover_island_circle):
		bot_debug_cover_island_circle.queue_free()
	bot_debug_cover_island_circle = _create_circle_mesh(
		bot_debug_cover_island_radius,
		Color(1.0, 0.5, 0.0, 0.3),  # Orange, more transparent to indicate it's approximate
		2.0, 64
	)
	bot_debug_cover_island_circle.name = "CoverIslandRadius"
	get_tree().root.add_child(bot_debug_cover_island_circle)
	bot_debug_cover_island_circle.global_position = Vector3(island_pos.x, draw_y, island_pos.z)

	# --- Safe distance circle (red, the minimum distance ships must stay from center) ---
	if bot_debug_cover_safe_circle != null and is_instance_valid(bot_debug_cover_safe_circle):
		bot_debug_cover_safe_circle.queue_free()
	bot_debug_cover_safe_circle = _create_circle_mesh(
		bot_debug_cover_safe_dist,
		Color(1.0, 0.15, 0.15, 0.7),  # Red
		3.0, 64
	)
	bot_debug_cover_safe_circle.name = "CoverSafeDist"
	get_tree().root.add_child(bot_debug_cover_safe_circle)
	bot_debug_cover_safe_circle.global_position = Vector3(island_pos.x, draw_y + 1.0, island_pos.z)

	# --- Cover zone circle (color depends on state) ---
	if bot_debug_cover_zone_circle != null and is_instance_valid(bot_debug_cover_zone_circle):
		bot_debug_cover_zone_circle.queue_free()

	var zone_color: Color
	if bot_debug_cover_spotted_in_cover:
		zone_color = Color(1.0, 0.0, 0.0, 0.8)   # Red — spotted in cover
	elif bot_debug_cover_in_cover:
		zone_color = Color(0.0, 1.0, 0.0, 0.8)   # Green — safe in cover
	else:
		zone_color = Color(0.0, 0.7, 1.0, 0.6)   # Blue — en route to cover

	bot_debug_cover_zone_circle = _create_circle_mesh(
		bot_debug_cover_zone_radius,
		zone_color,
		3.0, 48
	)
	bot_debug_cover_zone_circle.name = "CoverZone"
	get_tree().root.add_child(bot_debug_cover_zone_circle)
	bot_debug_cover_zone_circle.global_position = Vector3(
		bot_debug_cover_zone_center.x, draw_y + 2.0, bot_debug_cover_zone_center.z
	)

	# --- Cover zone center marker sphere ---
	if bot_debug_cover_zone_center_sphere != null and is_instance_valid(bot_debug_cover_zone_center_sphere):
		bot_debug_cover_zone_center_sphere.queue_free()

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 20.0
	sphere_mesh.height = 40.0
	sphere_mesh.radial_segments = 8
	sphere_mesh.rings = 4
	var sphere_mat := StandardMaterial3D.new()
	sphere_mat.albedo_color = zone_color
	sphere_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere_mat.no_depth_test = true
	bot_debug_cover_zone_center_sphere = MeshInstance3D.new()
	bot_debug_cover_zone_center_sphere.name = "CoverZoneCenter"
	bot_debug_cover_zone_center_sphere.mesh = sphere_mesh
	bot_debug_cover_zone_center_sphere.material_override = sphere_mat
	bot_debug_cover_zone_center_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(bot_debug_cover_zone_center_sphere)
	bot_debug_cover_zone_center_sphere.global_position = Vector3(
		bot_debug_cover_zone_center.x, 30.0, bot_debug_cover_zone_center.z
	)


func _clear_bot_debug_cover_circles() -> void:
	if bot_debug_cover_island_circle != null and is_instance_valid(bot_debug_cover_island_circle):
		bot_debug_cover_island_circle.queue_free()
	bot_debug_cover_island_circle = null

	if bot_debug_cover_safe_circle != null and is_instance_valid(bot_debug_cover_safe_circle):
		bot_debug_cover_safe_circle.queue_free()
	bot_debug_cover_safe_circle = null

	if bot_debug_cover_zone_circle != null and is_instance_valid(bot_debug_cover_zone_circle):
		bot_debug_cover_zone_circle.queue_free()
	bot_debug_cover_zone_circle = null

	if bot_debug_cover_zone_center_sphere != null and is_instance_valid(bot_debug_cover_zone_center_sphere):
		bot_debug_cover_zone_center_sphere.queue_free()
	bot_debug_cover_zone_center_sphere = null

	_clear_cover_los_lines()
	bot_debug_cover_zone_valid = false


func _clear_cover_los_lines() -> void:
	for line in bot_debug_cover_los_lines:
		if is_instance_valid(line):
			line.queue_free()
	bot_debug_cover_los_lines.clear()


# ============================================================================
# World-space debug label — follows the tracked ship
# ============================================================================

func _draw_bot_debug_world_label() -> void:
	if bot_debug_follow_ship == null or not is_instance_valid(bot_debug_follow_ship):
		if bot_debug_world_label != null and is_instance_valid(bot_debug_world_label):
			bot_debug_world_label.queue_free()
			bot_debug_world_label = null
		return

	# Build label text
	var text = bot_debug_nav_state
	if text.is_empty():
		if bot_debug_world_label != null and is_instance_valid(bot_debug_world_label):
			bot_debug_world_label.visible = false
		return

	# Create label if needed
	if bot_debug_world_label == null or not is_instance_valid(bot_debug_world_label):
		bot_debug_world_label = Label3D.new()
		bot_debug_world_label.name = "BotDebugWorldLabel"
		bot_debug_world_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		bot_debug_world_label.no_depth_test = true
		bot_debug_world_label.fixed_size = true
		bot_debug_world_label.pixel_size = 0.001
		bot_debug_world_label.font_size = 16
		bot_debug_world_label.modulate = Color(1.0, 1.0, 1.0, 0.9)
		bot_debug_world_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
		bot_debug_world_label.outline_size = 4
		bot_debug_world_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		bot_debug_world_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		get_tree().root.add_child(bot_debug_world_label)

	bot_debug_world_label.text = text
	bot_debug_world_label.visible = true
	bot_debug_world_label.fixed_size = true
	bot_debug_world_label.pixel_size = 0.001
	bot_debug_world_label.global_position = bot_debug_follow_ship.global_position + Vector3(-100, 100, 0)


func _create_los_line(from_pos: Vector3, to_pos: Vector3, color: Color) -> MeshInstance3D:
	"""Create a line mesh between two world positions for LOS visualization."""
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	im.surface_add_vertex(Vector3(from_pos.x, 25.0, from_pos.z))
	im.surface_add_vertex(Vector3(to_pos.x, 25.0, to_pos.z))
	im.surface_end()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var node := MeshInstance3D.new()
	node.name = "CoverLOSLine"
	node.mesh = im
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


# =============================================================================
# CA Tactical Debug: Enemy Clusters + Nearby Islands
# =============================================================================

func _draw_ca_tactical_debug() -> void:
	_clear_ca_tactical_debug()

	var draw_y: float = 8.0

	# Draw enemy cluster markers (red/orange spheres with radius based on ship count)
	for cluster_data in bot_debug_ca_enemy_clusters:
		var center: Vector3 = cluster_data.get("center", Vector3.ZERO)
		var ship_count: int = cluster_data.get("ship_count", 1)

		# Sphere size scales with ship count
		var sphere_size: float = 30.0 + ship_count * 15.0

		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = sphere_size
		sphere_mesh.height = sphere_size * 2.0
		sphere_mesh.radial_segments = 12
		sphere_mesh.rings = 6

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.2, 0.0, 0.7)  # Red-orange
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		var node := MeshInstance3D.new()
		node.name = "CATacticalCluster"
		node.mesh = sphere_mesh
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(node)
		node.global_position = Vector3(center.x, draw_y + 30.0, center.z)
		bot_debug_ca_cluster_spheres.append(node)

		# Also draw a circle on the water showing cluster extent
		var cluster_radius: float = 300.0 + ship_count * 200.0
		var circle := _create_circle_mesh(cluster_radius, Color(1.0, 0.3, 0.0, 0.4), 2.0, 32)
		circle.name = "CATacticalClusterRadius"
		get_tree().root.add_child(circle)
		circle.global_position = Vector3(center.x, draw_y, center.z)
		bot_debug_ca_cluster_spheres.append(circle)

	# Draw nearby islands (cyan circles for bounding radius)
	for island_data in bot_debug_ca_nearby_islands:
		var center: Vector3 = island_data.get("center", Vector3.ZERO)
		var radius: float = island_data.get("radius", 0.0)
		if radius <= 0.0:
			continue

		var circle := _create_circle_mesh(radius, Color(0.0, 0.8, 0.9, 0.35), 2.0, 48)
		circle.name = "CATacticalIsland"
		get_tree().root.add_child(circle)
		circle.global_position = Vector3(center.x, draw_y + 1.0, center.z)
		bot_debug_ca_island_circles.append(circle)

		# Small center dot
		var dot_mesh := SphereMesh.new()
		dot_mesh.radius = 15.0
		dot_mesh.height = 30.0
		dot_mesh.radial_segments = 6
		dot_mesh.rings = 4
		var dot_mat := StandardMaterial3D.new()
		dot_mat.albedo_color = Color(0.0, 0.9, 1.0, 0.6)
		dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dot_mat.no_depth_test = true
		dot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var dot_node := MeshInstance3D.new()
		dot_node.name = "CATacticalIslandCenter"
		dot_node.mesh = dot_mesh
		dot_node.material_override = dot_mat
		dot_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(dot_node)
		dot_node.global_position = Vector3(center.x, draw_y + 20.0, center.z)
		bot_debug_ca_island_circles.append(dot_node)


func _clear_ca_tactical_debug() -> void:
	for node in bot_debug_ca_cluster_spheres:
		if node != null and is_instance_valid(node):
			node.queue_free()
	bot_debug_ca_cluster_spheres.clear()

	for node in bot_debug_ca_island_circles:
		if node != null and is_instance_valid(node):
			node.queue_free()
	bot_debug_ca_island_circles.clear()


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
