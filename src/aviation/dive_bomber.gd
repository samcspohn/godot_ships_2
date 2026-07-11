extends Aircraft
class_name DiveBomberAircraft

@export var shell_params: ShellParams

# Dispersion parameters normally supplied by GunParams - baked in here since a
# dive bomber has no gun/turret/target-mod to source them from.
@export var grouping: float = 1.8
@export var h_spread: float = 0.01
@export var v_spread: float = 0.005
@export var dispersion_curve: Curve = preload("res://src/artillary/default_dispersion.tres")
@export var max_dispersion: float = 270.0
@export var max_range: float = 3000.0  # used only to sample dispersion_curve (t = dist / max_range)

var _dispersion_calculator: DispersionCalculator

# Color of this aircraft preview square (see make_preview_meshes and
# update_preview below).
const BOMB_PREVIEW_COLOR := Color(1.0, 0.65, 0.0, 0.35)

func _ready() -> void:
	_dispersion_calculator = DispersionCalculator.new()

# Drops a single HE shell straight down from wherever this aircraft currently
# is (its formation slot, spread out by the squadron for the attack run).
# Mirrors Gun.fire()'s dispersion + fireBullet usage, minus the gun/target-mod
# plumbing that doesn't apply to an aircraft-dropped bomb.
func fire_ordnance(_direction: Vector2) -> bool:

	var aim_point := Vector3(global_position.x, 0.0, global_position.z)
	for i in range(2):
		var dispersed_velocity: Variant = _dispersion_calculator.calculate_dispersed_launch(
				aim_point, global_position, shell_params,
				grouping, grouping, h_spread, v_spread,
				max_range, dispersion_curve, max_dispersion)
		if dispersed_velocity == null:
			return true
		var t = ProjectileManager.get_current_time()
		var id = ProjectileManager.fireBullet(dispersed_velocity, global_position, shell_params, t, _ship)
		TcpThreadPool.send_display_shell(id, global_position, dispersed_velocity, t, shell_params, self, true)
	return true

# One preview square per aircraft, sized to the actual dispersion ellipse
# (see update_preview below).
static func make_preview_meshes(parent: Node3D, count: int) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for i in range(count):
		var m := Aircraft.make_flat_marker(BOMB_PREVIEW_COLOR)
		parent.add_child(m)
		meshes.append(m)
	return meshes

# Lays out one square per aircraft abreast of drop_center, facing direction,
# sized to twice max_dispersion (matching the actual bomb spread).
func update_preview(meshes: Array[MeshInstance3D], do_show: bool, drop_center: Vector2, direction: Vector2, formation_spacing: float) -> void:
	if not do_show:
		for m in meshes:
			m.visible = false
		return
	var dir := direction
	if dir.length_squared() < 0.0001:
		dir = Vector2(0.0, 1.0)
	else:
		dir = dir.normalized()
	var side: float = max_dispersion * 2.0
	for i in range(meshes.size()):
		var lateral := Aircraft.attack_lateral_offset(i, meshes.size(), formation_spacing, dir)
		var pos_xz := drop_center + lateral
		var pos := Vector3(pos_xz.x, Aircraft.PREVIEW_HEIGHT, pos_xz.y)
		Aircraft.position_flat_rect(meshes[i], pos, dir, side, side)
