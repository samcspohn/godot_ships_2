extends Node3D
class_name Aircraft

# Aircraft never navigate independently - they only ever try to reach and
# match this formation slot (owned by the Squadron; moves/rotates as the
# squadron flies). The squadron controls all flight and attack timing, and
# calls fire_ordnance() directly once it reaches the attack point.
var target: Node3D
var _ship: Ship
var params: AircraftParams
var should_recall: bool = false
# set by the squadron each tick: true while it's on its attack run, so
# aircraft snap into the tighter attack formation faster (see fly_toward()).
var attacking: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if not _Utils.authority():
		return

	if target == null:
		return

	fly_toward(target.global_position, delta)

# distance over which the catch-up speed boost ramps from none (at the
# target) to max (at or beyond this range). There's no dead zone: any nonzero
# lag gets a proportional speed boost, so a lagging aircraft always has some
# excess speed over its target and its distance error converges to zero
# instead of settling into a permanent pursuit-curve offset.
const CATCHUP_RANGE: float = 300.0

func fly_toward(pos: Vector3, delta: float) -> void:
	var p = params.p() as AircraftParams
	var dist := global_position.distance_to(pos)
	var t: float = clampf(dist / CATCHUP_RANGE, 0.0, 1.0)
	var mult: float = p.attack_catch_up_speed_mult if attacking else p.catch_up_speed_mult
	var speed: float = lerpf(p.speed, p.speed * mult, t)
	attract(self, pos, speed, delta)

# Aircraft are magnetically attracted to their target position: move straight
# toward it at the given speed (never overshooting) and face the direction of
# travel. No turn-rate simulation, so there's nothing to oscillate or
# overshoot around.
static func attract(node: Node3D, target_pos: Vector3, speed: float, delta: float) -> void:
	var disp: Vector3 = target_pos - node.global_position
	var dist := disp.length()
	if dist < 0.0001:
		return
	var dir := disp / dist
	var move_dist: float = minf(speed * delta, dist)
	node.global_position += dir * move_dist
	node.look_at(node.global_position + dir)

# Turn-rate-limited flight simulation used by the squadron leader node: turns
# toward the target heading at a constant angular rate (speed / turning_radius)
# and advances at constant speed, so the formation flies (and turns) like a
# real aircraft rather than snapping straight at its next waypoint.
#
# Altitude is deliberately handled separately from the horizontal turn: the
# node climbs/descends toward target_altitude at a constant climb_rate,
# independent of how far away target_xz is. Coupling the two (steering
# straight at a 3D point including altitude) would only reach the target
# altitude by the time the horizontal distance also reaches zero - fine for a
# short final approach, but a squadron cruising for kilometers home would
# barely climb until the very end.
static func steer(node: Node3D, target_xz: Vector2, target_altitude: float, speed: float, turning_radius: float, climb_rate: float, delta: float) -> void:
	var current_pos: Vector3 = node.global_position
	var forward_xz := Vector2(-node.global_transform.basis.z.x, -node.global_transform.basis.z.z)
	if forward_xz.length_squared() < 0.0001:
		forward_xz = Vector2(0.0, 1.0)
	forward_xz = forward_xz.normalized()

	var disp_xz: Vector2 = target_xz - Vector2(current_pos.x, current_pos.z)
	if disp_xz.length_squared() > 0.0001:
		var desired_dir := disp_xz.normalized()
		# constant-speed turn: angular rate = speed / turning_radius
		var max_turn_angle: float = (speed / turning_radius) * delta
		var turn_angle: float = clampf(forward_xz.angle_to(desired_dir), -max_turn_angle, max_turn_angle)
		forward_xz = forward_xz.rotated(turn_angle)

	var horizontal_move: Vector2 = forward_xz * speed * delta
	var new_y: float = move_toward(current_pos.y, target_altitude, climb_rate * delta)
	var new_pos := Vector3(current_pos.x + horizontal_move.x, new_y, current_pos.z + horizontal_move.y)
	node.global_position = new_pos

	var look_dir := Vector3(horizontal_move.x, new_y - current_pos.y, horizontal_move.y)
	if look_dir.length_squared() > 0.0001:
		node.look_at(new_pos + look_dir.normalized())

# Called once by the squadron when it reaches the attack point. Subclasses
# implement their actual ordnance drop / spotting behavior here, firing from
# wherever they currently are (their formation slot, which the squadron has
# already spread out for the attack run).
# Returns true if this aircraft should be recalled after firing (one-shot
# ordnance runs), or false to keep it on station (e.g. spotting).
func fire_ordnance(_direction: Vector2) -> bool:
	return true

# Abreast line, centered on the leader, perpendicular to travel - used while
# making an attack run so slots track the squadron's turn toward the target
# instead of aircraft beelining individually to a fixed spread point. Also
# used to space out this aircraft type's live drop-pattern preview shapes
# (see attack_lateral_offset() below) so the preview always matches the
# actual attack formation.
static func attack_offset(i: int, count: int, spacing: float) -> Vector3:
	if i == 0:
		return Vector3.ZERO
	var row := (i + 1) / 2
	var side := -1.0 if i % 2 == 1 else 1.0
	return Vector3(side * spacing * row, 0.0, 0.0)

# --- Live drop-pattern preview (aiming UI) ---
# Squadron only ever holds a flat Array[MeshInstance3D] per preview
# ("reticle" for the live pre-commit aim, "committed" for the frozen
# post-commit pattern) and asks aircraft[0] to build/update it - it has no
# idea what the meshes represent. Each aircraft subclass that carries
# aimable ordnance overrides both methods below to describe its own preview
# shape; the base Aircraft (and SpottingAircraft) keeps the defaults: no
# meshes, and update_preview() hides whatever it's handed.

# Builds a fresh set of preview meshes (parented under `parent`) sized for a
# squadron of `count` aircraft of this type. Called once per preview set in
# Squadron.setup().
static func make_preview_meshes(_parent: Node3D, _count: int) -> Array[MeshInstance3D]:
	return []

# Positions (show=true) or hides (show=false) `meshes` (as returned by this
# same aircraft type's make_preview_meshes()) to depict the live drop
# pattern centered on drop_center, facing direction. formation_spacing is
# supplied by the squadron, since only it knows the formation spacing.
# Height is fixed (see PREVIEW_HEIGHT) rather than sampled from the terrain -
# the meshes render with depth testing disabled (see make_flat_marker())
# so they always draw over world geometry regardless of exact altitude,
# which lets this run in _process() every frame instead of needing a
# physics-thread raycast to find the ground height under the cursor.
func update_preview(meshes: Array[MeshInstance3D], _do_show: bool, _drop_center: Vector2, _direction: Vector2, _formation_spacing: float) -> void:
	for m in meshes:
		m.visible = false

# Shared building blocks for subclasses' make_preview_meshes()/
# update_preview() overrides - a flat, semi-transparent box reoriented and
# rescaled every frame rather than rebuilt (see position_flat_rect()).
const PREVIEW_THICKNESS: float = 0.5
const PREVIEW_HEIGHT: float = 1.0 # fixed height above sea level

static func make_flat_marker(color: Color) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Draws over terrain/water/ships regardless of the mesh actual altitude -
	# lets the preview skip the ground-height raycast entirely (see
	# update_preview() above).
	material.no_depth_test = true
	box.material = material
	mesh_instance.mesh = box
	mesh_instance.visible = false
	return mesh_instance

# Lays a flat marker down flush with the ground, `length` long along
# `forward2` (world XZ) and `width` wide across it, centered on `center`.
static func position_flat_rect(mesh_instance: MeshInstance3D, center: Vector3, forward2: Vector2, width: float, length: float) -> void:
	if length < 0.001 or width < 0.001:
		mesh_instance.visible = false
		return
	mesh_instance.visible = true
	var forward3 := Vector3(forward2.x, 0.0, forward2.y)
	var right3 := Vector3(-forward2.y, 0.0, forward2.x)
	mesh_instance.global_transform = Transform3D(Basis(right3, Vector3.UP, forward3), center)
	(mesh_instance.mesh as BoxMesh).size = Vector3(width, PREVIEW_THICKNESS, length)

# World-space (XZ) lateral offset of aircraft `i` (of `count`) from the
# formation center, perpendicular to `direction` - mirrors attack_offset()'s
# abreast spread, but rotated to match a direction that isn't necessarily the
# squadron's current heading (the preview can be shown before the squadron
# even turns onto the attack run).
static func attack_lateral_offset(i: int, count: int, spacing: float, direction: Vector2) -> Vector2:
	var local := attack_offset(i, count, spacing)
	var right := Vector2(-direction.y, direction.x)
	return right * local.x
