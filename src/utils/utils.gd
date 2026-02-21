extends Node3D
class_name Utils

var debug_instance: MeshInstance3D
var debug_mesh: ImmediateMesh

func setup_debug_visualization() -> void:
	debug_mesh = ImmediateMesh.new()
	debug_instance = MeshInstance3D.new()
	debug_instance.mesh = debug_mesh
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(1, 0, 0)  # Red color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	#material.CULL_BACK = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	material.render_priority = -100
	debug_instance.material_override = material
	get_tree().root.add_child(debug_instance)

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

var cached_authority: bool = false
var current_frame: int = -1
func authority() -> bool:
	if Engine.get_process_frames() != current_frame:
		current_frame = Engine.get_process_frames()
		cached_authority = multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and multiplayer.is_server() and "--server" in OS.get_cmdline_args()
	return cached_authority

func is_multiplayer_active() -> bool:
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
