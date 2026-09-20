class_name SkillStation
extends BotSkill

## Holds the field cell that scores best on the team's reach, fire, cone,
## detection and route layers (ReachField.score_station), refined to the
## shoreline when it sits against an island. Replaces Camp: the same hold,
## but the spot is chosen on what can be shot from it and what can shoot back.

const RESCORE_MS: int = 2000
const PLAN_BOX_M: float = 8000.0
## Shore refinement is only tried this close to an island's bounding radius.
const SHORE_REACH_CLEARANCES: float = 3.0
## A shore point may lose this much score against the cell it refines.
const SHORE_SCORE_SLACK: float = 0.05
## Each enemy able to land shells on a step adds this much to its length.
const FIRE_PRICE_GAIN: float = 0.25

var _station: Vector3 = Vector3.ZERO
var _has_station: bool = false
var _station_score: float = -INF
var _terms: Dictionary = {}
var _refined: bool = false
var _last_ms: int = -100000
var _plan_us: float = 0.0
var _score_us: float = 0.0

## [gain, price_mode] for ReachField.plan_ship: a hull that trades on
## concealment prices detection at its router's gain, anyone else prices the
## number of enemies able to land shells on the step.
static func price_for(d: BotDoctrine) -> Array:
	if d.trades_on_concealment:
		return [d.detection_cost_gain, 0]
	return [FIRE_PRICE_GAIN, 1]

func reset() -> void:
	_has_station = false
	_station_score = -INF
	_terms = {}
	_refined = false
	_last_ms = -100000

func station_position() -> Vector3:
	return _station

func has_station() -> bool:
	return _has_station

func debug_text() -> String:
	if not _has_station:
		return "Station: none"
	return "Station %.2f%s | reach %d exposed %d cone %.0f deg det %.2f travel %.2f range %.2f esc %.2f | plan %.1f ms score %.1f ms" % [
		_station_score, " shore" if _refined else "",
		int(_terms.get("reach", 0)), int(_terms.get("exposed", 0)), float(_terms.get("cone_deg", 0.0)),
		float(_terms.get("detect", 0.0)), float(_terms.get("travel", 0.0)), float(_terms.get("range_err", 0.0)),
		float(_terms.get("escape", 0.0)), _plan_us / 1000.0, _score_us / 1000.0]

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var field: ReachField = NavigationMapManager.get_reach_field()
	if field == null or not field.is_built():
		return null
	var ship: Ship = ctx.ship
	if ship.team == null:
		return null
	var g: Dictionary = NavigationMapManager.reach_gun(ship)
	if g.is_empty():
		return null
	var team_id: int = ship.team.team_id
	var now: int = Time.get_ticks_msec()
	if _has_station and now - _last_ms < RESCORE_MS:
		return _intent(ctx, field, team_id, params)
	_last_ms = now

	var d: BotDoctrine = ctx.behavior.doctrine()
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var radius: float = NavigationMapManager.reach_conceal_radius(ship)
	var clearance: float = ctx.behavior._get_ship_clearance()
	var danger3: Vector3 = ctx.behavior._get_positioning_danger_center()
	var danger := Vector2(danger3.x, danger3.z) if danger3 != Vector3.ZERO else field.get_team_danger_centre(team_id)
	var price: Array = price_for(d)
	var st: Dictionary = field.plan_ship(team_id, ship.get_instance_id(), here, radius, price[0], clearance,
		PLAN_BOX_M, price[1], danger)
	if st.is_empty():
		return null
	_plan_us = float(st.get("us", 0.0)) if not bool(st.get("cached", false)) else 0.0

	var key: int = NavigationMapManager.reach_hull_key(g)
	var gun_range: float = g.range
	var weights := PackedFloat32Array([d.station_w_reach, d.station_w_exposed, d.station_w_cone,
		d.station_w_detect, d.station_w_travel, d.station_w_range, d.station_w_escape])
	var held := Vector2(_station.x, _station.z) if _has_station else Vector2(INF, INF)
	var sc: Dictionary = field.score_station(team_id, ship.get_instance_id(), key, weights, gun_range,
		gun_range * d.station_range_ratio, radius, danger, held)
	_score_us = float(sc.get("us", 0.0))
	if not bool(sc.get("has_best", false)):
		return _intent(ctx, field, team_id, params) if _has_station else null
	var best_terms: Dictionary = sc.best_terms
	var best_score: float = sc.best_score
	if float(best_terms.get("reach", 0.0)) <= 0.0 and not _has_station:
		return null

	var held_score: float = float(sc.get("held_score", -INF))
	if _has_station and is_finite(held_score):
		_station_score = held_score
		_terms = sc.get("held_terms", _terms)
		if best_score - held_score < d.station_switch_margin:
			return _intent(ctx, field, team_id, params)

	var best2: Vector2 = sc.best
	var dest := Vector3(best2.x, 0.0, best2.y)
	_refined = false
	var shore: Vector3 = _refine_to_shore(dest, clearance)
	if shore != Vector3.ZERO:
		var probe: Dictionary = field.station_score_at(team_id, ship.get_instance_id(), key, weights,
			gun_range, gun_range * d.station_range_ratio, radius, danger, Vector2(shore.x, shore.z))
		if not probe.is_empty() and float(probe.score) >= best_score - SHORE_SCORE_SLACK:
			dest = shore
			best_terms = probe
			best_score = float(probe.score)
			_refined = true
	_station = dest
	_has_station = true
	_station_score = best_score
	_terms = best_terms
	return _intent(ctx, field, team_id, params)

## Walks the best cell out to the shoreline of the island it leans on, so the
## hull sits against the rock instead of at a cell centre 50 m off it.
func _refine_to_shore(cell: Vector3, clearance: float) -> Vector3:
	var isl: Dictionary = NavigationMapManager.get_nearest_island(cell)
	if not bool(isl.get("valid", false)):
		return Vector3.ZERO
	var c2: Vector2 = isl.center
	var centre := Vector3(c2.x, 0.0, c2.y)
	var isl_radius: float = isl.radius
	var away: Vector3 = cell - centre
	away.y = 0.0
	if away.length() > isl_radius + clearance * SHORE_REACH_CLEARANCES or away.length_squared() < 1.0:
		return Vector3.ZERO
	return NavigationMapManager.reach_shore_point(centre, away.normalized(), isl_radius, clearance)

## Heading: bow or stern into the centre of the shooters' cone, whichever is
## the smaller turn; the angling skill's answer when nothing can reach here.
func _intent(ctx: SkillContext, field: ReachField, team_id: int, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var cone: Dictionary = field.cone_at(team_id, Vector2(_station.x, _station.z))
	var heading: float
	if float(cone.get("half", -1.0)) >= 0.0:
		heading = float(cone.heading)
	else:
		heading = SkillAngle.calc_heading(ctx, params)
	var current: float = ctx.behavior._get_ship_heading()
	if absf(angle_difference(current, heading)) > PI / 2.0:
		heading = ctx.behavior._normalize_angle(heading + PI)
	var hold: float = params.get("jitter_radius", ship.movement_controller._p().turning_circle_radius * 2.0)
	var intent := NavIntent.create(_station, heading, hold)
	intent.skip_threat_adjustment = true
	intent.near_terrain = _refined
	return intent
