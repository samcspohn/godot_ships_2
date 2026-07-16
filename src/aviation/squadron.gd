extends RefCounted
class_name Squadron

# A squadron owns a formation leader node (`node`) with child "slot" markers
# (`targets`), spaced apart so aircraft can each be assigned one to follow.
# Flying the squadron (waypoints/orbit) simply moves & orients `node`; the
# slots move with it, keeping the formation spaced correctly apart.
var node: Node3D
var targets: Array[Node3D] = []
var aircraft: Array[Aircraft] = []
var params: AircraftParams
var active: bool = false
var launcher_node: Node3D
var ground_marker: MeshInstance3D
var ground_line: MeshInstance3D
# Two fully independent sets of drop-pattern preview meshes (see
# update_reticle_preview and update_committed_attack_preview) so the local,
# pre-commit reticle preview and the synced, post-commit committed
# preview never fight over the same mesh instances. Built by
# aircraft[0].make_preview_meshes and driven every frame through
# aircraft[0].update_preview - Squadron itself has no idea what these
# meshes represent (squares, rectangles, or nothing at all). Both parented
# directly under the game world at setup and never reparented, since the
# reticle in particular has to be visible before the squadron even launches.
var _reticle_meshes: Array[MeshInstance3D] = []
var _committed_meshes: Array[MeshInstance3D] = []
# Node the waypoint/next-target visuals reparent into while active (the same
# game_world passed to launch()) - null while parked at the launcher, since
# waypoints are always cleared on recall() anyway.
var world_node: Node3D
# Pools of client-side visual markers/lines, resized every frame in
# _update_waypoint_indicators() to match the current waypoints array.
var waypoint_markers: Array[MeshInstance3D] = []
var waypoint_connector_lines: Array[MeshInstance3D] = []
var next_target_line: MeshInstance3D

var waypoints: Array[Vector2] = []
var idle_pos: Vector2
# Clearing this always returns the formation to the cruise wedge. It does NOT
# switch to the attack layout on its own - that only happens once the
# squadron closes within attack_descent_radius (see in_attack_run below), so
# the formation stays in cruise for the whole approach, not just from the
# moment fire is called.
var attack_point = null:
	set(value):
		attack_point = value
		if attack_point == null:
			in_attack_run = false
			_set_cruise_formation()
			_apply_squadron_preview(_committed_meshes, false, Vector2.ZERO, Vector2.ZERO)
var attack_direction: Vector2 = Vector2.ZERO
var attack_fired: bool = false
# true once the squadron has flown through the virtual entry point set up
# ahead of the attack run (see update_flight()) - only after this is it
# allowed to head straight for attack_point and fire, guaranteeing every
# approach commits to attack_direction first instead of cutting the corner.
var passed_entry_point: bool = false
# true once the squadron has closed within attack_descent_radius of the
# attack point and switched onto its final low attack-formation run. Setting
# this (from update_flight() on the authority, or from_bytes() on other
# peers) keeps the formation in sync with the actual approach state instead
# of switching the instant an attack is commanded.
var in_attack_run: bool = false:
	set(value):
		if value == in_attack_run:
			return
		in_attack_run = value
		if attack_point != null:
			if in_attack_run:
				_set_attack_formation()
			else:
				_set_cruise_formation()
# true once the squadron has arrived and is holding station over the attack
# point (e.g. spotting) rather than patrolling near the carrier - determines
# which orbit radius to use (circle_range vs idle_radius)
var holding_attack: bool = false
# true once a one-shot attack run has fired and the squadron is flying itself
# back to the launcher instead of being teleported home instantly. While
# returning, the squadron ignores any further attack commands.
var returning: bool = false
# true once a returning squadron has closed within landing_descent_radius of
# the launcher and switched onto its final landing formation/altitude.
var in_landing_approach: bool = false:
	set(value):
		if value == in_landing_approach:
			return
		in_landing_approach = value
		if in_landing_approach:
			_set_landing_formation()
		else:
			_set_cruise_formation()

# distance from the attack point at which the squadron fires its planes
const ARRIVAL_RADIUS: float = 1.0
# distance from the attack point within which turn-rate-limited steering is
# abandoned in favor of magnetizing (attracting) straight onto the point, the
# same way aircraft snap onto their formation slots - this guarantees an
# accurate final approach instead of risking a near-miss on the last stretch.
const MAGNETIZE_RADIUS: float = 500.0
# distance from the launcher a returning squadron must actually reach before
# it despawns/reparents back into the launcher (not just get close)
const LANDING_RADIUS: float = 50.0

func setup(_params: AircraftParams, launcher: Node3D, ship: Ship, game_world: Node3D) -> void:
	params = _params
	launcher_node = launcher
	node = Node3D.new()
	node.name = params.type
	launcher.add_child(node)
	# node.add_child(_make_debug_sphere())

	ground_marker = _make_sphere_marker(GROUND_MARKER_COLOR, GROUND_MARKER_RADIUS)
	launcher.add_child(ground_marker)
	ground_line = _make_line_mesh(GROUND_MARKER_COLOR)
	launcher.add_child(ground_line)
	next_target_line = _make_line_mesh(WAYPOINT_COLOR)
	launcher.add_child(next_target_line)

	var p = params.p() as AircraftParams
	for i in range(p.squadron_size):
		var slot := Node3D.new()
		slot.name = "Slot%d" % i
		slot.position = _formation_offset(i, p.formation_spacing)
		node.add_child(slot)
		# var debug_sphere := _make_debug_sphere()
		# slot.add_child(debug_sphere)
		# debug_sphere.position = Vector3.ZERO
		targets.append(slot)

		var plane := params.plane_scene.instantiate() as Aircraft
		plane.visible = false
		plane.set_physics_process(false)
		plane.params = params
		plane._ship = ship
		plane.target = slot
		plane._setup_hitbox()
		launcher.add_child(plane)
		plane.position = Vector3.ZERO
		aircraft.append(plane)

	if aircraft.size() > 0:
		_reticle_meshes = aircraft[0].make_preview_meshes(game_world, aircraft.size())
		_committed_meshes = aircraft[0].make_preview_meshes(game_world, aircraft.size())

# small red marker sphere for visualizing the squadron leader node and its
# formation slots
static func _make_debug_sphere() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 2.0
	sphere.height = 4.0
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.RED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = material
	mesh_instance.mesh = sphere
	return mesh_instance

# Client-side UI only (not synced over the network - purely visual, derived
# every frame from state that is already synced, so it is the same on every
# peer). Colors: white for the squadron own ground indicator, green for
# waypoints, orange for the attack point (matching the attack marker).
const GROUND_MARKER_COLOR := Color(1.0, 1.0, 1.0)
const WAYPOINT_COLOR := Color(1.0, 1.0, 1.0)
const ATTACK_LINE_COLOR := Color(1.0, 0.35, 0.0)
const GROUND_MARKER_RADIUS: float = 6.0

static func _make_sphere_marker(color: Color, radius: float) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = material
	mesh_instance.mesh = sphere
	mesh_instance.visible = false
	return mesh_instance

# A thin cylinder used as a generic line segment between two arbitrary
# points - see _position_line(), which orients/scales it every frame.
static func _make_line_mesh(color: Color) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.5
	cylinder.bottom_radius = 1.5
	cylinder.height = 1.0
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cylinder.material = material
	mesh_instance.mesh = cylinder
	mesh_instance.visible = false
	return mesh_instance

static func _set_line_color(line: MeshInstance3D, color: Color) -> void:
	var material := (line.mesh as CylinderMesh).material as StandardMaterial3D
	material.albedo_color = color

# Orients/scales a line mesh (built by _make_line_mesh()) to run between two
# arbitrary world points - not just vertical, so it can be used both for the
# ground indicator and for waypoint-to-waypoint connectors.
static func _position_line(line: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var diff := to - from
	var length := diff.length()
	if length < 0.001:
		line.visible = false
		return
	line.visible = true
	var y_axis := diff / length
	var helper_axis := Vector3.RIGHT
	if absf(y_axis.dot(Vector3.RIGHT)) > 0.99:
		helper_axis = Vector3.FORWARD
	var x_axis := helper_axis.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	line.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis), (from + to) * 0.5)
	(line.mesh as CylinderMesh).height = length

# Raycasts straight down from (x, node's current altitude, z), capped at
# water level (y = 0). Used to place the ground marker/waypoint markers on
# the water/terrain below.
func _ground_height_at(x: float, z: float) -> float:
	var space_state := node.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(Vector3(x, node.global_position.y, z), Vector3(x, 0.0, z))
	query.collision_mask = 1 # terrain layer
	var result := space_state.intersect_ray(query)
	return result.position.y if not result.is_empty() else 0.0

# Vertical clearance kept between the squadron and the top of its ground line.
const GROUND_LINE_CLEARANCE: float = 20.0

# Positions the ground marker/line below the squadron. Purely client-side
# visual - safe to call on every peer every frame since it only reads the
# already-synced node.global_position.
func _update_ground_indicator() -> void:
	if ground_marker == null or ground_line == null or not active:
		return
	ground_marker.visible = true

	var pos := node.global_position
	var ground_y := _ground_height_at(pos.x, pos.z)
	ground_marker.global_position = Vector3(pos.x, ground_y, pos.z)

	var line_top := Vector3(pos.x, pos.y - GROUND_LINE_CLEARANCE, pos.z)
	var line_bottom := Vector3(pos.x, ground_y, pos.z)
	_position_line(ground_line, line_bottom, line_top)

# Draws green spheres at each waypoint and green connector lines between
# consecutive waypoints, plus a single line from the squadron's own ground
# marker to whatever it's currently heading toward next - green for a
# waypoint, orange for the attack point. Purely client-side visual, safe on
# every peer since it only reads already-synced state.
func _update_waypoint_indicators() -> void:
	if not active or world_node == null:
		return

	while waypoint_markers.size() < waypoints.size():
		var marker := _make_sphere_marker(WAYPOINT_COLOR, GROUND_MARKER_RADIUS)
		world_node.add_child(marker)
		waypoint_markers.append(marker)
	while waypoint_markers.size() > waypoints.size():
		waypoint_markers.pop_back().queue_free()

	var connector_count: int = maxi(waypoints.size() - 1, 0)
	while waypoint_connector_lines.size() < connector_count:
		var line := _make_line_mesh(WAYPOINT_COLOR)
		world_node.add_child(line)
		waypoint_connector_lines.append(line)
	while waypoint_connector_lines.size() > connector_count:
		waypoint_connector_lines.pop_back().queue_free()

	var ground_ys: Array[float] = []
	for i in range(waypoints.size()):
		var wp: Vector2 = waypoints[i]
		var gy := _ground_height_at(wp.x, wp.y)
		ground_ys.append(gy)
		waypoint_markers[i].visible = true
		waypoint_markers[i].global_position = Vector3(wp.x, gy, wp.y)

	for i in range(connector_count):
		var a: Vector2 = waypoints[i]
		var b: Vector2 = waypoints[i + 1]
		_position_line(waypoint_connector_lines[i], Vector3(a.x, ground_ys[i], a.y), Vector3(b.x, ground_ys[i + 1], b.y))

	if waypoints.size() > 0:
		var wp0: Vector2 = waypoints[0]
		_position_line(next_target_line, ground_marker.global_position, Vector3(wp0.x, ground_ys[0], wp0.y))
		_set_line_color(next_target_line, WAYPOINT_COLOR)
	elif attack_point != null:
		var ap: Vector2 = attack_point
		var ap_ground := _ground_height_at(ap.x, ap.y)
		_position_line(next_target_line, ground_marker.global_position, Vector3(ap.x, ap_ground, ap.y))
		_set_line_color(next_target_line, ATTACK_LINE_COLOR)
	else:
		next_target_line.visible = false

# Positions/hides one set of drop-pattern preview meshes (either the
# reticle or committed set) by delegating to aircraft[0], which alone knows
# what these meshes represent (see Aircraft.update_preview()). Squadron only
# supplies what it alone knows: the formation spacing. No raycast/ground
# height lookup - the preview meshes render with depth testing disabled
# (see Aircraft.make_flat_marker()) so they always draw over world geometry,
# which lets this run every frame from _process() instead of requiring the
# physics thread.
func _apply_squadron_preview(meshes: Array[MeshInstance3D], show: bool, drop_center: Vector2, direction: Vector2) -> void:
	if aircraft.size() == 0:
		return
	if not show:
		aircraft[0].update_preview(meshes, false, Vector2.ZERO, Vector2.ZERO, 0.0)
		return
	var p = params.p() as AircraftParams
	var drop_point = aircraft[0].process_attack_point(drop_center, direction)
	aircraft[0].update_preview(meshes, true, drop_point, direction, p.formation_spacing)

# Local, pre-commit reticle preview - only ever driven by AviationController
# for whichever squadron is selected by the local player (hidden for every
# other squadron/peer). Uses its own dedicated meshes so it never fights with
# update_committed_attack_preview() below over the same instances.
func update_reticle_preview(show: bool, drop_center: Vector2, direction: Vector2) -> void:
	_apply_squadron_preview(_reticle_meshes, show, drop_center, direction)

# Continuously shows the frozen drop pattern at the commanded attack_point,
# facing attack_direction, once an attack has actually been commanded -
# replaces the old pole and arrow attack marker. Purely derived from
# already-synced state (attack_point/attack_direction), so it is safe to call
# on every peer every tick, same as _update_ground_indicator(). Visible to
# everyone, unlike update_reticle_preview() above which only the controlling
# player sees.
func update_committed_attack_preview() -> void:
	if attack_point == null:
		_apply_squadron_preview(_committed_meshes, false, Vector2.ZERO, Vector2.ZERO)
		return
	_apply_squadron_preview(_committed_meshes, true, attack_point, attack_direction)

# Wedge/V formation trailing behind the leader node (local +Z is behind, since
# forward is -Z).
static func _formation_offset(i: int, spacing: float) -> Vector3:
	if i == 0:
		return Vector3.ZERO
	var row := (i + 1) / 2
	var side := -1.0 if i % 2 == 1 else 1.0
	return Vector3(side * spacing * row, 0.0, row * spacing)

func _set_cruise_formation() -> void:
	var p = params.p() as AircraftParams
	for i in range(targets.size()):
		targets[i].position = _formation_offset(i, p.formation_spacing)

func _set_attack_formation() -> void:
	var p = params.p() as AircraftParams
	for i in range(targets.size()):
		targets[i].position = Aircraft.attack_offset(i, targets.size(), p.formation_spacing)

# Landing formation: every slot collapses onto the leader node so the
# formation stacks up tight for the final approach to the launcher.
func _set_landing_formation() -> void:
	for slot in targets:
		slot.position = Vector3.ZERO

func launch(game_world: Node3D, launch_pos: Vector3, launch_rotation: Vector3) -> void:
	var p = params.p() as AircraftParams
	node.reparent(game_world)
	node.global_position = launch_pos
	node.global_rotation = launch_rotation
	ground_marker.reparent(game_world)
	ground_line.reparent(game_world)
	next_target_line.reparent(game_world)
	world_node = game_world
	idle_pos = Vector2(launch_pos.x, launch_pos.z)
	active = true
	holding_attack = false
	returning = false
	in_landing_approach = false
	attack_point = null
	for plane in aircraft:
		plane.visible = true
		plane.set_physics_process(true)
		plane.should_recall = false
		plane.dead = false
		plane.hp = p.hp
		plane.set_hitbox_enabled(true)
		plane.reparent(game_world)
		plane.global_position = launch_pos

func recall(launcher: Node3D) -> void:
	active = false
	attack_point = null
	attack_fired = false
	holding_attack = false
	returning = false
	in_landing_approach = false
	waypoints.clear()
	for plane in aircraft:
		plane.visible = false
		plane.set_physics_process(false)
		plane.should_recall = false
		plane.set_hitbox_enabled(false)
		plane.reparent(launcher)
		plane.position = Vector3.ZERO
	node.reparent(launcher)
	node.position = Vector3.ZERO
	ground_marker.reparent(launcher)
	ground_marker.position = Vector3.ZERO
	ground_marker.visible = false
	ground_line.reparent(launcher)
	ground_line.position = Vector3.ZERO
	ground_line.visible = false
	next_target_line.reparent(launcher)
	next_target_line.position = Vector3.ZERO
	next_target_line.visible = false
	for marker in waypoint_markers:
		marker.queue_free()
	waypoint_markers.clear()
	for line in waypoint_connector_lines:
		line.queue_free()
	waypoint_connector_lines.clear()
	world_node = null

func all_finished_attack() -> bool:
	if aircraft.size() == 0:
		return false
	for plane in aircraft:
		if not plane.should_recall:
			return false
	return true

# true once every aircraft in the squadron has been shot down by AA - the
# squadron has nothing left to fly home, so it's recalled immediately instead
# of going through the normal return-to-base flight.
func all_dead() -> bool:
	if aircraft.size() == 0:
		return false
	for plane in aircraft:
		if not plane.dead:
			return false
	return true

func set_waypoint(waypoint: Vector2, append: bool) -> void:
	# ignore new waypoints while flying itself home after a completed run
	if returning:
		return
	if append:
		waypoints.append(waypoint)
	else:
		waypoints.clear()
		waypoints.append(waypoint)
	attack_point = null
	idle_pos = waypoint

# Squadron owns the attack point/direction and turns the whole formation onto
# the attack run; switching to the abreast attack formation spreads aircraft
# out perpendicular to the attack direction so their ordnance lands in a
# spread once fired (see _fire).
func set_attack(point: Vector2, direction: Vector2) -> void:
	# ignore new attack orders while flying itself home after a completed run
	if returning:
		return
	attack_direction = direction
	attack_fired = false
	holding_attack = false
	in_attack_run = false
	passed_entry_point = false
	attack_point = aircraft[0].process_attack_point(point, direction)
	# add append flag
	waypoints.clear()

func update_flight(delta: float, ship: Ship) -> void:
	var p = params.p() as AircraftParams
	var wp: Vector2
	var altitude: float = p.altitude
	var climb_rate: float = p.climb_rate
	var checking_arrival := false
	var magnetizing := false
	if returning:
		var launcher_global := launcher_node.global_position
		var launcher_pos := Vector2(launcher_global.x, launcher_global.z)
		wp = launcher_pos
		var dist_home := Vector2(node.global_position.x, node.global_position.z).distance_to(launcher_pos)
		in_landing_approach = dist_home < p.landing_descent_radius
		altitude = launcher_global.y if in_landing_approach else p.altitude * p.return_altitude_mult
		if in_landing_approach:
			var altitude_diff := absf(altitude - node.global_position.y)
			if dist_home > 0.001:
				var required_climb_rate: float = altitude_diff * p.speed / dist_home
				climb_rate = maxf(climb_rate, required_climb_rate)
		if node.global_position.distance_to(launcher_global) < LANDING_RADIUS:
			for plane in aircraft:
				plane.should_recall = true
	elif attack_point != null:
		# fly the formation itself onto the attack heading; the slots (children
		# of node) turn with it so aircraft chase a moving/rotating formation
		# instead of beelining individually toward the target
		wp = attack_point
		if not attack_fired:
			var attack_pt: Vector2 = attack_point
			var squadron_pos := Vector2(node.global_position.x, node.global_position.z)
			var dist := squadron_pos.distance_to(attack_pt)
			# cruise at normal altitude/formation until closing in, then descend
			# and switch onto the attack formation for the final run (e.g.
			# torpedo bombers going low and spreading out)
			in_attack_run = dist < p.attack_descent_radius

			var line_dir := attack_direction
			if line_dir.length_squared() < 0.0001:
				line_dir = Vector2(0.0, 1.0)
			else:
				line_dir = line_dir.normalized()
			# Fixed point behind attack_point, opposite attack_direction, exactly
			# attack_descent_radius away. The squadron always flies through this
			# point first - whether it starts outside attack_descent_radius or is
			# already inside it - so it always commits to the final run already
			# aligned with attack_direction instead of cutting across at whatever
			# angle it happened to arrive at.
			var entry_point: Vector2 = attack_pt - line_dir * p.attack_descent_radius

			if not passed_entry_point:
				wp = entry_point
				if squadron_pos.distance_to(entry_point) < 100.0:
					passed_entry_point = true

			# only once the entry point has actually been flown through is the
			# squadron allowed to head straight for attack_point and fire
			if passed_entry_point:
				checking_arrival = true
				wp = attack_pt
				if in_attack_run and dist < MAGNETIZE_RADIUS:
					# Too close for turn-rate-limited steering to reliably land
					# exactly on the point - magnetize straight onto it instead,
					# the same way aircraft snap onto their formation slots, so
					# the final approach always lines up for an accurate drop.
					magnetizing = true

			if in_attack_run:
				altitude = p.attack_altitude if p.attack_altitude >= 0.0 else p.altitude
				# boost the climb rate (never below the configured baseline) so the
				# descent to attack_altitude actually finishes by the time the
				# squadron reaches its current nav target, instead of only getting
				# partway down over the whole approach.
				var dist_to_wp := squadron_pos.distance_to(wp)
				if dist_to_wp > 0.001:
					var altitude_diff := absf(altitude - node.global_position.y)
					var required_climb_rate: float = altitude_diff * p.speed / dist_to_wp
					climb_rate = maxf(climb_rate, required_climb_rate)
	else:
		var wp_or_null = _process_waypoints(ship, p)
		if wp_or_null == null:
			var orbit_radius: float = p.circle_range if holding_attack else p.idle_radius
			wp = _orbit_target(idle_pos, orbit_radius, p.speed, delta)
		else:
			wp = wp_or_null
	for plane in aircraft:
		plane.attacking = in_attack_run
	if magnetizing:
		Aircraft.attract(node, Vector3(wp.x, altitude, wp.y), p.speed, delta)
	else:
		Aircraft.steer(node, wp, altitude, p.speed, p.turning_radius, climb_rate, delta)

	if checking_arrival:
		var dist_after := Vector2(node.global_position.x, node.global_position.z).distance_to(attack_point)
		if dist_after < 0.001:
			_fire()
			waypoints.clear()

# Fires every aircraft's ordnance once the squadron arrives at the attack
# point. If every aircraft reports a one-shot run, the whole squadron is
# recalled; otherwise (e.g. spotting) the squadron holds station over the
# target by turning the attack point into its new loiter position.
func _fire() -> void:
	attack_fired = true
	var recall_after := true
	for plane in aircraft:
		if plane.dead: # shot down - can't fire
			continue
		recall_after = plane.fire_ordnance(attack_direction) and recall_after
	if recall_after:
		returning = true
		attack_point = null
	else:
		idle_pos = attack_point
		attack_fired = false
		holding_attack = true
		attack_point = null

# clamp waypoints to within range of ship and return current waypoint;
# remove waypoints once the formation leader reaches them
func _process_waypoints(ship: Ship, p: AircraftParams):
	if waypoints.size() == 0:
		return null
	var ship_pos := Vector2(ship.global_position.x, ship.global_position.z)
	for i in range(waypoints.size()):
		var wp: Vector2 = waypoints[i]
		var disp := wp - ship_pos
		if disp.length_squared() > p._range * p._range:
			disp = disp.normalized() * p._range
			wp = ship_pos + disp
			waypoints[i] = wp

	var wp: Vector2 = waypoints[0]
	var disp := wp - Vector2(node.global_position.x, node.global_position.z)
	if disp.length_squared() < 100.0: # reached waypoint
		waypoints.remove_at(0)
	if waypoints.size() == 0:
		return null
	return waypoints[0]

# point on a circle around orbit_pos, advanced this frame's step; keeps the
# formation circling its last commanded position when it has no waypoint
func _orbit_target(orbit_pos: Vector2, radius: float, speed: float, delta: float) -> Vector2:
	var pos := Vector2(node.global_position.x, node.global_position.z)
	var from_center := pos - orbit_pos
	if from_center.length_squared() < 0.0001:
		from_center = Vector2(radius, 0.0)

	var angle := atan2(from_center.y, from_center.x)
	angle += (speed * delta) / radius
	return orbit_pos + Vector2(cos(angle), sin(angle)) * radius
