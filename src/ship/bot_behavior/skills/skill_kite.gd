class_name SkillKite
extends BotSkill

## Fighting retreat: a heading, not a place. The angled away-bearing from
## SkillAngle is the centre of a fan of candidate headings; each ray is scored
## by integrating the station terms (who can shoot it, how wide they sit) over
## the next few kilometres of the reach field, and the ray that runs down the
## threat gradient fastest wins, with a cost per degree it leans off the
## angled heading. The hull therefore never turns broadside to get somewhere.

const RAY_LENGTH_M: float = 3000.0
const FAN_HALF_DEG: float = 45.0
const FAN_STEP_DEG: float = 15.0
## Score lost per full fan half-width of lean off the angled away-heading.
const LEAN_WEIGHT: float = 0.4
const RESCORE_MS: int = 1000
## A new ray must beat the held one by this much: no zigzag on a flat field.
const SWITCH_MARGIN: float = 0.1

var _bearing: float = 0.0
var _has_bearing: bool = false
var _last_ms: int = -100000
var _ray_score: float = -INF
var _ray_end: Vector3 = Vector3.ZERO

func reset() -> void:
	_has_bearing = false
	_last_ms = -100000

func has_ray() -> bool:
	return _has_bearing

func ray_end() -> Vector3:
	return _ray_end

func debug_text() -> String:
	return "Kite %.0f deg score %.2f" % [rad_to_deg(_bearing), _ray_score] if _has_bearing else "Kite: directional"

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var angled: float = wrapf(SkillAngle.calc_heading(ctx, params) + PI, -PI, PI)
	var now: int = Time.get_ticks_msec()
	if not _has_bearing or now - _last_ms >= RESCORE_MS:
		_last_ms = now
		_pick_bearing(ctx, params, angled)
	if not _has_bearing:
		return _directional(ctx, angled)
	var fwd := Vector3(sin(_bearing), 0.0, cos(_bearing))
	var dest: Vector3 = ship.global_position + fwd * maxf(RAY_LENGTH_M, ship.movement_controller._p().turning_circle_radius * 8.0)
	dest.y = 0.0
	var intent := NavIntent.create(ctx.behavior._get_valid_nav_point(dest), _bearing)
	intent.directional = true
	return intent

func _pick_bearing(ctx: SkillContext, _params: Dictionary, angled: float) -> void:
	var field: ReachField = NavigationMapManager.get_reach_field()
	var ship: Ship = ctx.ship
	if field == null or not field.is_built() or ship.team == null:
		_has_bearing = false
		return
	var g: Dictionary = NavigationMapManager.reach_gun(ship)
	if g.is_empty():
		_has_bearing = false
		return
	var team_id: int = ship.team.team_id
	var d: BotDoctrine = ctx.behavior.doctrine()
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var radius: float = NavigationMapManager.reach_conceal_radius(ship)
	var danger3: Vector3 = ctx.behavior._get_positioning_danger_center()
	var danger := Vector2(danger3.x, danger3.z) if danger3 != Vector3.ZERO else field.get_team_danger_centre(team_id)
	var price: Array = SkillStation.price_for(d)
	var id: int = ship.get_instance_id()
	if field.plan_ship(team_id, id, here, radius, price[0], ctx.behavior._get_ship_clearance(),
			SkillStation.PLAN_BOX_M, price[1], danger).is_empty():
		_has_bearing = false
		return
	var opts := {
		"weights": PackedFloat32Array([d.kite_w_reach, d.kite_w_exposed, d.kite_w_cone, d.kite_w_detect, 0.0, 0.0, d.kite_w_escape]),
		"gun_range": g.range,
		"radius": radius,
		"fire_radius": maxf(radius, g.range),
		"toward": danger,
		"enemy_weights": SkillStation._enemy_weights(ctx, field, team_id),
	}
	var bearings := PackedFloat32Array()
	var off: float = -FAN_HALF_DEG
	while off <= FAN_HALF_DEG + 0.01:
		bearings.append(wrapf(angled + deg_to_rad(off), -PI, PI))
		off += FAN_STEP_DEG
	if _has_bearing:
		bearings.append(_bearing)
	var r: Dictionary = field.score_rays(team_id, id, NavigationMapManager.reach_hull_key(g), opts, here, bearings, RAY_LENGTH_M)
	var scores: PackedFloat32Array = r.get("scores", PackedFloat32Array())
	var ends: PackedVector2Array = r.get("ends", PackedVector2Array())
	var best_i := -1
	var best := -INF
	var held := -INF
	for i in range(scores.size()):
		if not is_finite(scores[i]):
			continue
		var lean: float = absf(angle_difference(angled, bearings[i])) / deg_to_rad(FAN_HALF_DEG)
		var sc: float = scores[i] - LEAN_WEIGHT * lean
		if _has_bearing and i == scores.size() - 1:
			held = sc
		if sc > best:
			best = sc
			best_i = i
	if best_i < 0:
		_has_bearing = false
		return
	if _has_bearing and is_finite(held) and best - held < SWITCH_MARGIN:
		_ray_score = held
		return
	_bearing = bearings[best_i]
	_ray_score = best
	_ray_end = Vector3(ends[best_i].x, 0.0, ends[best_i].y)
	_has_bearing = true

## The field-free kite: the angled away-bearing, reprojected every tick.
func _directional(ctx: SkillContext, heading: float) -> NavIntent:
	var ship: Ship = ctx.ship
	var fwd := Vector3(sin(heading), 0.0, cos(heading))
	var dest: Vector3 = ship.global_position + fwd * maxf(RAY_LENGTH_M, ship.movement_controller._p().turning_circle_radius * 8.0)
	dest.y = 0.0
	var intent := NavIntent.create(ctx.behavior._get_valid_nav_point(dest), heading)
	intent.directional = true
	return intent
