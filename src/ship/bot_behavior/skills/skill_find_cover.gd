class_name SkillFindCover
extends SkillStation

## Cover is the station search with cover weights: fewest enemies able to
## land shells here, unseen where the hull cares, still with something in
## reach. The island sweep this used to run is gone; the reach field already
## knows which cells are masked from whom, with belief spread and certainty
## folded in.

## Arrival hysteresis in clearances: inside the first the ship is on station,
## and it stays so until it drifts past the second.
const ARRIVE_CLEARANCES: float = 2.0
const LEAVE_CLEARANCES: float = 3.5

var _arrived: bool = false
var _dist_to_dest: float = 0.0
var can_shoot: bool = false

## Kept for the cover debug overlay (CABehavior._sync_cover_debug): the island
## the station leans on, or the station itself with no radius.
var _nav_destination: Vector3 = Vector3.ZERO
var _nav_destination_valid: bool = false
var _target_island_pos: Vector3 = Vector3.ZERO
var _target_island_radius: float = 0.0

func _label() -> String:
	return "Cover"

func _weights(d: BotDoctrine) -> PackedFloat32Array:
	return PackedFloat32Array([d.cover_w_reach, d.cover_w_exposed, d.cover_w_cone,
		d.cover_w_detect, d.cover_w_travel, d.cover_w_range, d.cover_w_escape])

## The dark arm asks for cover with nothing to shoot at; everyone else wants a
## firing position.
func _accepts_no_reach(params: Dictionary) -> bool:
	return bool(params.get("prioritize_cover", false))

func _detour_weight(d: BotDoctrine, params: Dictionary) -> float:
	return d.cover_w_detour if bool(params.get("prefer_on_the_way", false)) else 0.0

func _max_exposed(d: BotDoctrine) -> float:
	return d.cover_max_exposed

func _require_unseen(d: BotDoctrine) -> bool:
	return d.cover_require_unseen

func execute(ctx: SkillContext, params: Dictionary, prioritize_cover: bool = false) -> NavIntent:
	var p := params
	if prioritize_cover and not params.get("prioritize_cover", false):
		p = params.duplicate()
		p["prioritize_cover"] = true
	var intent: NavIntent = super.execute(ctx, p)
	if intent == null:
		_nav_destination_valid = false
		_arrived = false
		can_shoot = false
		return null
	_update_arrival(ctx)
	can_shoot = float(_terms.get("reach", 0.0)) > 0.0
	return intent

func _adopt(dest: Vector3, best_score: float, best_terms: Dictionary) -> void:
	if not _has_station or dest.distance_to(_station) > 1.0:
		_arrived = false
	super._adopt(dest, best_score, best_terms)
	_nav_destination = dest
	_nav_destination_valid = true
	var isl: Dictionary = NavigationMapManager.get_nearest_island(dest)
	if _refined and bool(isl.get("valid", false)):
		var c2: Vector2 = isl.center
		_target_island_pos = Vector3(c2.x, 0.0, c2.y)
		_target_island_radius = float(isl.radius)
	else:
		_target_island_pos = dest
		_target_island_radius = 0.0

func _update_arrival(ctx: SkillContext) -> void:
	var to_dest: Vector3 = _station - ctx.ship.global_position
	to_dest.y = 0.0
	_dist_to_dest = to_dest.length()
	var clearance: float = ctx.behavior._get_ship_clearance()
	if _arrived:
		_arrived = _dist_to_dest < clearance * LEAVE_CLEARANCES
	else:
		_arrived = _dist_to_dest < clearance * ARRIVE_CLEARANCES

func is_complete(_ctx: SkillContext) -> bool:
	return _arrived

func get_dist() -> float:
	return _dist_to_dest

func reset() -> void:
	super.reset()
	_arrived = false
	_dist_to_dest = 0.0
	can_shoot = false
	_nav_destination_valid = false
	_target_island_radius = 0.0

## Whether the station costs a detour off the line through the ship and the
## danger centre. A line, not a ray: ground on the way out is as free as
## ground on the way in. Tolerance narrows with distance, 37.5 deg close in to
## 17.5 deg at 5 km. Call after execute() so the station is current.
func is_cover_on_the_way(ctx: SkillContext) -> bool:
	if not _has_station:
		return false
	var ship: Ship = ctx.ship
	var to_cover: Vector3 = _station - ship.global_position
	to_cover.y = 0.0
	var dist_to_cover: float = to_cover.length()
	if dist_to_cover < 1.0:
		return true
	var axis: Vector3 = ctx.behavior._get_positioning_danger_center() - ship.global_position
	axis.y = 0.0
	if axis.length_squared() < 1.0:
		return true
	var t := clampf(dist_to_cover / 5000.0, 0.0, 1.0)
	var angle_tol := lerpf(deg_to_rad(37.5), deg_to_rad(17.5), t)
	return absf(axis.normalized().dot(to_cover / dist_to_cover)) >= cos(angle_tol)
