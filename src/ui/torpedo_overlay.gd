extends Node3D
class_name TorpedoOverlay

var arc_mesh: MeshInstance3D = null
var spread_mesh: MeshInstance3D = null
var lead_mesh: MeshInstance3D = null
var overlay_visible: bool = true
var torpedo_controller: TorpedoController = null
var player_controller: PlayerController = null
var target: RigidBody3D = null

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	arc_mesh = $AllowedArcs
	spread_mesh = $AimingArc
	lead_mesh = $LeadArc

	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false          # keep depth test ON — terrain occludes naturally
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from below water too
	mat.albedo_color = Color(0.2, 0.8, 1.0, 0.03)
	arc_mesh.material_override = mat
	spread_mesh.material_override = mat

	# Separate white material for lead arc (vertex colors multiply with white albedo)
	var lead_mat = mat.duplicate()
	lead_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.03)
	lead_mesh.material_override = lead_mat

	get_tree().create_timer(0.1).timeout.connect(setup_valid_arcs)

func setup_valid_arcs():
	var arcs: Array[TorpedoArc] = []
	for torp: TorpedoLauncher in torpedo_controller.launchers:
		var torp_arcs: Array[Vector2] = []
		for arc in torp.fire_arcs:
			var arc1 = Vector2(arc.min_angle, arc.max_angle)
			# var torp_arc = TorpedoArc(torp.position, [arc], torp.get_params()._range)
			torp_arcs.append(arc1)
			# arcs.append(Vector2(arc.min_angle, arc.max_angle)) # todo: arcs, should have a start + length, not min/max
		var torp_arc = TorpedoArc.new(torp.position, torp_arcs, torp.get_params()._range, torp.get_params().torpedo_params.arming_distance)
		arcs.append(torp_arc)
	arc_mesh.mesh = build_launcher_arcs(arcs)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if not overlay_visible:
		return

	# Hide overlay when not using torpedoes
	if player_controller and player_controller.current_weapon_controller != torpedo_controller:
		arc_mesh.visible = false
		spread_mesh.visible = false
		lead_mesh.visible = false
		return

	# Make meshes visible when using torpedoes
	arc_mesh.visible = true
	spread_mesh.visible = true
	lead_mesh.visible = true

	# Reposition at water level regardless of ship pitch/roll
	global_position = torpedo_controller._ship.global_position
	global_position.y = 0.2


	# Get tube world angle (XZ plane projection of tube's -Z forward)
	var tube_forward := -torpedo_controller.launchers[0].global_basis.z
	var tube_angle := atan2(tube_forward.x, tube_forward.z)
	global_rotation.y = torpedo_controller._ship.global_rotation.y
	tube_angle -= global_rotation.y  # convert to local space for easier arc construction

	# arc_mesh.mesh    = build_arc(global_position, tube_angle, deg_to_rad(35.0), torpedo_tube.get_params()._range)
	# spread_mesh.mesh = build_spread_lines(global_position, aim_angle, torpedo_count, spread_deg, 8000.0)

	var spread_arcs: Array[TorpedoArc] = []
	for torp: TorpedoLauncher in torpedo_controller.launchers:
		var spread_min_dist: float = torp.get_params().torpedo_params.arming_distance
		var torp_tube_forward := -torp.global_basis.z
		var torp_tube_angle := atan2(torp_tube_forward.x, torp_tube_forward.z) - global_rotation.y
		var spread_rad := deg_to_rad(2.0)
		var torp_arc = TorpedoArc.new(torp.position, [Vector2(torp_tube_angle - spread_rad, torp_tube_angle + spread_rad)], torp.get_params()._range, spread_min_dist)
		spread_arcs.append(torp_arc)
	spread_mesh.mesh = build_launcher_arcs(spread_arcs)

	# Calculate and draw target lead arc (white)
	if target and torpedo_controller.launchers.size() > 0:
		lead_mesh.mesh = build_target_lead(torpedo_controller.launchers, target)
	else:
		lead_mesh.mesh = null

class TorpedoArc:
	var position: Vector3           # ship-local XZ position, Y ignored (flattened to water plane)
	var arcs: Array[Vector2]        # (min_angle, max_angle) pairs in ship-local radians
	var range_m: float
	var min_distance_m: float = 0.0 # minimum distance from position before the arc renders
	var arc_color: Color = Color(0.2, 0.8, 1.0, 0.15)

	func _init(pos: Vector3, arc_list: Array[Vector2], range: float, min_dist: float = 0.0, color: Color = Color(0.2, 0.8, 1.0, 0.15)) -> void:
		position     = pos
		arcs         = arc_list
		range_m      = range
		min_distance_m = min_dist
		arc_color      = color


func build_launcher_arcs(
	launchers: Array[TorpedoArc],
	segments_per_arc: int = 48
) -> ArrayMesh:

	var verts   := PackedVector3Array()
	var colors  := PackedColorArray()
	var indices := PackedInt32Array()

	for launcher in launchers:
		var origin := Vector3(launcher.position.x, 0.0, launcher.position.z)

		for arc in launcher.arcs:
			var min_r: float = launcher.min_distance_m
			var max_r: float = launcher.range_m
			var skip_inner: bool = min_r <= 0.0

			# Build ring vertices: inner arc first, then outer arc
			var inner_verts := PackedVector3Array()
			var outer_verts := PackedVector3Array()

			for i in range(segments_per_arc + 1):
				var t     := float(i) / float(segments_per_arc)
				var angle := lerpf(arc.x, arc.y, t)
				var dir   := Vector3(sin(angle), 0.0, cos(angle))
				inner_verts.append(origin + dir * min_r)
				outer_verts.append(origin + dir * max_r)

			var base := verts.size()

			verts.append_array(inner_verts)
			verts.append_array(outer_verts)

			for v in inner_verts:
				var inner_col = launcher.arc_color
				inner_col.a = 0.5
				colors.append(inner_col)
			for v in outer_verts:
				colors.append(launcher.arc_color)

			# Build quads between inner and outer arcs
			var n := segments_per_arc
			if skip_inner:
				# Degenerate to wedge from origin
				for i in range(n):
					indices.append(base)           # inner[0] = origin
					indices.append(base + n + i + 1)   # outer[i+1]
					indices.append(base + n + i + 2)   # outer[i+2]
			else:
				for i in range(n):
					var ii  := base + i           # inner[i]
					var ji  := base + i + 1       # inner[i+1]
					var io  := base + n + i + 1   # outer[i+1]
					var jo  := base + n + i + 2   # outer[i+2]
					indices.append_array([ii, ji, jo])
					indices.append_array([ii, jo, io])

	var arr := Array()
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR]  = colors
	arr[Mesh.ARRAY_INDEX]  = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func build_target_lead(
	launchers: Array[TorpedoLauncher],
	tgt: RigidBody3D,
	segments_per_arc: int = 48
) -> ArrayMesh:

	if launchers.is_empty():
		var empty_mesh := ArrayMesh.new()
		return empty_mesh

	# Use first launcher's torpedo speed for lead calculation
	var torpedo_speed: float = launchers[0].get_params().torpedo_params.speed * TorpedoManager.TORPEDO_SPEED_MULTIPLIER
	var _range: float = launchers[0].get_params()._range
	var arming_distance: float = launchers[0].get_params().torpedo_params.arming_distance
	if torpedo_speed <= 0.0:
		var empty_mesh := ArrayMesh.new()
		return empty_mesh

	# Target position flattened to water plane (world space)
	var target_world_xz := Vector3(tgt.global_position.x, 0.0, tgt.global_position.z)

	# Target velocity in overlay-local XZ plane
	var target_vel_world := Vector3(tgt.linear_velocity.x, 0.0, tgt.linear_velocity.z)
	var target_vel_local := global_transform.basis.inverse() * target_vel_world

	# Distance in overlay-local space (overlay origin is at ship center)
	var target_local_xz := Vector3(
		(global_transform.inverse() * target_world_xz).x,
		0.0,
		(global_transform.inverse() * target_world_xz).z
	)
	var distance: float = Vector2(target_local_xz.x, target_local_xz.z).length()

	# Time for torpedo to reach target
	var time_to_impact: float = distance / torpedo_speed

	# Predicted target position at time of impact (in overlay-local XZ)
	var predicted_local_xz := Vector2(target_local_xz.x, target_local_xz.z) \
		+ Vector2(target_vel_local.x, target_vel_local.z) * time_to_impact

	# Direction to predicted position in overlay-local space
	var lead_angle: float = atan2(predicted_local_xz.x, predicted_local_xz.y)
	var lead_spread_rad := deg_to_rad(2.0)

	var lead_color := Color(1.0, 1.0, 1.0, 0.25)

	var lead_arc = TorpedoArc.new(
		Vector3.ZERO,
		[Vector2(lead_angle - lead_spread_rad, lead_angle + lead_spread_rad)],
		_range,
		arming_distance,
		lead_color
	)

	return build_launcher_arcs([lead_arc], segments_per_arc)

func build_arcs(
	arcs: Array[Vector2],  # each Vector2: (min_angle, max_angle) in radians
	range_m: float,
	segments_per_arc: int = 48) -> ArrayMesh:

	var verts  := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for arc in arcs:
		var min_angle: float = arc.x
		var max_angle: float = arc.y
		var base := verts.size()

		# Center vertex for this arc's fan
		verts.append(Vector3.ZERO)
		colors.append(Color(0.2, 0.8, 1.0, 0.5))

		for i in range(segments_per_arc + 1):
			var t := float(i) / float(segments_per_arc)
			var angle := lerpf(min_angle, max_angle, t)
			verts.append(Vector3(sin(angle), 0.0, cos(angle)) * range_m)
			colors.append(Color(0.2, 0.8, 1.0, 0.15))

		for i in range(segments_per_arc):
			indices.append(base)          # center
			indices.append(base + i + 1)
			indices.append(base + i + 2)

	var arr := Array()
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR]  = colors
	arr[Mesh.ARRAY_INDEX]  = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
