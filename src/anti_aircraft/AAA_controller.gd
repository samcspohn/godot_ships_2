extends WeaponController
class_name AAAController

@export var dps: float = 0.0
@export var _range: float = 0.0

# Vertical extent of the cylinder cast - tall enough to catch aircraft at any
# attack/cruise altitude, since AA range is purely horizontal.
const CYLINDER_HEIGHT: float = 20000.0
const CYLINDER_CENTER_Y: float = 5000.0

# Pre-allocated ONCE and reused every tick. This is required, not an
# optimization: with physics/3d/run_on_separate_thread=true, PhysicsServer3D
# commands are queued to the physics thread, so a Shape3D created the same
# tick it is queried has no geometry applied yet and the query silently
# degenerates to a point test at the transform origin (returns nothing).
# Same pattern as torpedo_manager.gd's pre-allocated proximity sphere.
var _aa_shape := CylinderShape3D.new()
var _aa_query := PhysicsShapeQueryParameters3D.new()
var _los_ray := PhysicsRayQueryParameters3D.new()

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship

	_aa_shape.radius = _range
	_aa_shape.height = CYLINDER_HEIGHT
	_aa_query.shape = _aa_shape
	_aa_query.collision_mask = Aircraft.AIRCRAFT_COLLISION_LAYER
	_aa_query.collide_with_areas = true
	_aa_query.collide_with_bodies = false

	_los_ray.collision_mask = 1 # terrain
	_los_ray.collide_with_areas = false
	_los_ray.collide_with_bodies = true

	set_physics_process(_Utils.authority())

# Runs once per second (offset by ship id, same "one tick per second" pattern
# as the rest of the codebase): cylinder-cast for enemy aircraft hitboxes
# within `_range` of this ship, then raycast to each - aircraft behind terrain
# (e.g. below an island ridgeline) are safe from AA fire.
func _physics_process(_delta: float) -> void:
	if Engine.get_physics_frames() % Engine.physics_ticks_per_second != _ship.id % Engine.physics_ticks_per_second:
		return
	if not _ship.team:
		return

	var ship_pos := _ship.global_position
	_aa_query.transform = Transform3D(Basis.IDENTITY, Vector3(ship_pos.x, CYLINDER_CENTER_Y, ship_pos.z))

	var space_state := _ship.get_world_3d().direct_space_state
	# collider is the plane's Area3D hitbox; the Aircraft itself rides on it as
	# metadata (see Aircraft._setup_hitbox)
	var planes: Array = space_state.intersect_shape(_aa_query, 64).map(func(result):
		return result.get("collider").get_meta("aircraft", null) as Aircraft
	).filter(func(a: Aircraft):
		return a != null and is_instance_valid(a) and not a.dead \
			and a._ship != null and a._ship.team != null \
			and a._ship.team.team_id != _ship.team.team_id
	)

	# apply full dps to one random plane in range; planes masked by terrain
	# are dropped from the pool and another is drawn
	while planes.size() > 0:
		var i := randi() % planes.size()
		var aircraft: Aircraft = planes[i]

		# line-of-sight: fire from deck height so an island between ship and
		# plane blocks the damage
		_los_ray.from = ship_pos + Vector3(0.0, _ship.movement_controller.ship_draft * 0.5, 0.0)
		_los_ray.to = aircraft.global_position
		if not space_state.intersect_ray(_los_ray).is_empty():
			planes.remove_at(i)
			continue

		aircraft.apply_aa_damage(dps)
		break
