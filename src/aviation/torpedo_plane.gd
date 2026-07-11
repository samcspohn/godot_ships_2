extends Aircraft
class_name TorpedoAircraft

@export var torpedo_params: TorpedoParams
@export var torpedo_range: float = 1000.0 # max run distance of an air-dropped torpedo
const TORPEDO_DEAD_ZONE_COLOR := Color(0.5, 0.5, 0.5, 0.25)
const TORPEDO_LIVE_ZONE_COLOR := Color(1.0, 0.35, 0.0, 0.4)
const TORPEDO_PREVIEW_WIDTH: float = 20.0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

# Fires a single torpedo from wherever this aircraft currently is (its
# formation slot, spread out by the squadron for the attack run), then
# reports back that it should be recalled - a torpedo run is one-shot.
func fire_ordnance(direction: Vector2) -> bool:
	var torp_vel = Vector3(direction.x, 0.0, direction.y).normalized()
	var t = ProjectileManager.get_current_time()
	var t_id = TorpedoManager.fireTorpedo(torp_vel, global_position, torpedo_params, t, _ship, torpedo_range)
	TorpedoManager.notify_fired(t_id, global_position, torp_vel, t, torpedo_params, _ship, false)
	return true

static func make_preview_meshes(parent: Node3D, count: int) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for i in range(count):
		var dead := Aircraft.make_flat_marker(TORPEDO_DEAD_ZONE_COLOR)
		var live := Aircraft.make_flat_marker(TORPEDO_LIVE_ZONE_COLOR)
		parent.add_child(dead)
		parent.add_child(live)
		meshes.append(dead)
		meshes.append(live)
	return meshes

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
	var arming: float = torpedo_params.arming_distance
	var live_len: float = maxf(torpedo_range - arming, 0.0)
	var fwd3 := Vector3(dir.x, 0.0, dir.y)
	var count := meshes.size() / 2
	for i in range(count):
		var dead := meshes[i * 2]
		var live := meshes[i * 2 + 1]
		var lateral := Aircraft.attack_lateral_offset(i, count, formation_spacing, dir)
		var base_xz := drop_center + lateral
		var base := Vector3(base_xz.x, Aircraft.PREVIEW_HEIGHT, base_xz.y)
		Aircraft.position_flat_rect(dead, base + fwd3 * (arming * 0.5), dir, TORPEDO_PREVIEW_WIDTH, arming)
		Aircraft.position_flat_rect(live, base + fwd3 * (arming + live_len * 0.5), dir, TORPEDO_PREVIEW_WIDTH, live_len)
