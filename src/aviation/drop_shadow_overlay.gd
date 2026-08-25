extends MeshInstance3D
class_name DropShadowOverlay

# Client-side UI for the ordnance dead zone (see DropShadow): the water a
# squadron cannot be ordered to drop on because terrain breaks its run-in from
# the carrier, plus the islands doing the breaking.
#
# Drawn as a full-screen quad that reads each pixel's world position back out of
# the depth buffer and evaluates the zone there - a decal, projected in screen
# space rather than baked into a texture, so it drapes over island slopes
# instead of being clipped by them. See the shader for why Godot's Decal node
# cannot do this one.
#
# Purely visual and purely local - the ruling itself is made on the authority in
# AviationController._physics_process.

## Mirrors MAX_CULL_DISCS/MAX_STEPS in drop_shadow_overlay.gdshader.
const MAX_CULL_DISCS: int = 64
const MAX_STEPS: int = 256
## Half-extent of the cull box kept on the camera. Only has to contain the
## camera itself, so that the box always intersects the frustum.
const CULL_BOX_HALF: float = 500.0

var _material: ShaderMaterial

static func create(world: Node3D) -> DropShadowOverlay:
	var overlay := DropShadowOverlay.new()
	world.add_child(overlay)
	overlay._build()
	return overlay

func _build() -> void:
	var map: NavigationMap = NavigationMapManager.get_map()
	var grid_w := map.get_grid_width()
	var grid_h := map.get_grid_height()
	var cell := map.get_cell_size_value()
	var grid_min := Vector2(map.get_min_x(), map.get_min_z())

	# Clip-space quad: the shader writes POSITION directly, so where this node
	# sits in the world has no bearing on what gets drawn. It does decide whether
	# the quad is drawn at all though - Godot still frustum-culls it by its AABB -
	# and update() keeps a small box parked on the camera for exactly that. An
	# AABB stretched big enough to cover the map instead is big enough for the
	# cull test to lose precision and drop the whole overlay from some camera
	# positions, which is not a subtle failure: the zones vanish outright.
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	custom_aabb = AABB(Vector3.ONE * -CULL_BOX_HALF, Vector3.ONE * (CULL_BOX_HALF * 2.0))

	var height_image := Image.create_from_data(
		grid_w, grid_h, false, Image.FORMAT_RF, map.get_shadow_height_data().to_byte_array())

	_material = ShaderMaterial.new()
	_material.shader = preload("res://src/aviation/drop_shadow_overlay.gdshader")
	# Behind the drop-pattern reticle, which is also depth-test-free and has to
	# stay readable over the zone.
	_material.render_priority = -1
	_material.set_shader_parameter("height_tex", ImageTexture.create_from_image(height_image))
	_material.set_shader_parameter("grid_min", grid_min)
	_material.set_shader_parameter("grid_dims", Vector2(grid_w, grid_h))
	_material.set_shader_parameter("cell_size", cell)
	_material.set_shader_parameter("slope", DropShadow.SLOPE)
	# Matches NavigationMap::terrain_shadow_depth's half-cell walk, so the shaded
	# region and the drop the authority actually refuses agree. Only coarsens if
	# a map's terrain is tall enough that the full reach needs more than the
	# shader's step budget.
	_material.set_shader_parameter("step_size",
		maxf(cell * 0.5, DropShadow.max_shadow_length() / float(MAX_STEPS)))
	_material.set_shader_parameter("cull_discs", _cull_discs(map))
	_material.set_shader_parameter("cull_count", mini(map.get_island_count(), MAX_CULL_DISCS))
	material_override = _material
	visible = false

## One disc per island, covering everywhere that island can possibly shadow: its
## own extent plus how far its tallest point throws a shadow, with that height
## carried along so the shader can bound its walk by the terrain actually in
## reach rather than by the tallest thing on the map. The array is always sent
## full length - a shader array uniform is sized at compile time - so unused
## slots are given a zero radius and never match.
func _cull_discs(map: NavigationMap) -> PackedVector4Array:
	var islands := map.get_islands()
	if islands.size() > MAX_CULL_DISCS:
		push_error("DropShadowOverlay: map has %d islands, shader holds %d - the excess will not be shaded"
			% [islands.size(), MAX_CULL_DISCS])
	var discs := PackedVector4Array()
	discs.resize(MAX_CULL_DISCS)
	for i in range(mini(islands.size(), MAX_CULL_DISCS)):
		var island: Dictionary = islands[i]
		var center: Vector2 = island["center"]
		var peak: float = island["max_height"]
		var reach: float = island["radius"] + peak / DropShadow.SLOPE
		discs[i] = Vector4(center.x, center.y, reach, peak)
	return discs

## Shows the zones as they stand for a squadron flying off `carrier`, or hides
## the overlay entirely.
func update(show_zones: bool, carrier: Vector2) -> void:
	visible = show_zones
	if not show_zones:
		return
	_material.set_shader_parameter("carrier_xz", carrier)
	# Keep the cull box on the camera. A box containing the camera always
	# intersects the frustum, so the quad can never be culled - see _build() for
	# why the obvious alternative, one AABB big enough to cover the map, does not
	# survive the cull test.
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		global_position = cam.global_position
