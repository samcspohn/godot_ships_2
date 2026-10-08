class_name SkillFight
extends SkillPosition

## SkillHold's FIGHT mode: the firing station on the edge of the bands round
## every enemy that shoots, at the cell that wins the best single fight: the
## spotted target it reaches that dies fastest (our fire plus the friends
## already on it, over its HP), less what every enemy whose fire covers the
## cell does to us (over our HP). A 1v1 or a target the team already has under
## fire beats a cell that sees more of them. The route is walled out of the
## bands; from inside one the way out comes first. Declines with no such cell.
## Params: band_m (else desired_range, else the engagement range), needs_los
## (the station must see its target), radius (ride the band edge within this
## of the chosen station instead of parking; 0 parks), away (bow away from the
## danger on arrival).

const EXIT_STEP_M := 200.0
const EXIT_MAX_STEPS := 100
const EXIT_MARGIN_M := 300.0
## Patrol leg along the band edge, at least, and in turning circles.
const PATROL_STEP_M := 1500.0
const PATROL_STEP_TURNS := 3.0
## Band edge walked each way when looking for a better fight.
const WALK_BUDGET_M := 6000.0
## A new station must beat the held one's score by this share.
const SWITCH_GAIN := 0.1
## Aspect assumed for fire between ships whose heading over the hold is unknown.
const TYPICAL_ASPECT_DEG := 45.0

var band_m: float = 0.0
var _patrol_sign: float = 0.0
var _target: Ship = null
var _radius: float = 0.0
## The station the search chose; riding the band moves _station, not this.
var _anchor: Vector2 = Vector2.ZERO

func reset() -> void:
	super()
	_patrol_sign = 0.0

func _label() -> String:
	return "Fight"

func debug_text() -> String:
	if not _has_station:
		return "%s: none | band %.0f m" % [_label(), band_m]
	return "%s on %s %.4f | band %.0f m | last walk %d cells" % [_label(),
		_target.ship_name if is_instance_valid(_target) else "?", _station_score, band_m, _steps]

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var vis: VisibilityGrid = NavigationMapManager.get_visibility()
	var field: ReachField = NavigationMapManager.get_reach_field()
	var ship: Ship = ctx.ship
	if vis == null or field == null or not field.is_built() or ship.team == null or ctx.server == null:
		return _decline()
	var team_id: int = ship.team.team_id
	var belief: Array[Dictionary] = ctx.server._team_belief(team_id)
	var g: Dictionary = NavigationMapManager.reach_gun(ship)
	if belief.is_empty() or g.is_empty():
		return _decline()
	var gun_range: float = float(g.range)
	band_m = _band(ctx, clampf(ctx.behavior.get_threat_score(ctx), 0.0, 1.0), params)
	_radius = float(params.get("radius", 0.0))
	var pos := PackedVector2Array()
	var band := PackedFloat32Array()
	var reach := PackedFloat32Array()
	var live := PackedByteArray()
	var ids := PackedInt64Array()
	var value := PackedFloat32Array()
	var harm := PackedFloat32Array()
	var friends: Array = ctx.server.get_team_ships(team_id)
	var hp: float = maxf(ship.health_controller.current_hp, 1.0)
	for b in belief:
		var e: Ship = b.ship
		pos.append(b.pos)
		band.append(band_m + float(b.spread) if threatens(e) else 0.0)
		reach.append(gun_range)
		# A remembered or presumed contact has nothing to shoot at: it is
		# kept out of, never stationed on.
		var is_live: bool = int(b.source) == 0
		live.append(1 if is_live else 0)
		ids.append(e.get_instance_id())
		var r: float = Vector2(ship.global_position.x, ship.global_position.z).distance_to(b.pos)
		harm.append(maxf(SkillStance._expected(ship, e, r, TYPICAL_ASPECT_DEG).x, 0.0) / hp * float(b.weight))
		value.append(_kill_rate(ship, e, friends) if is_live else 0.0)
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var danger := _belief_centre(ctx, belief, here)
	_hull_key = NavigationMapManager.reach_hull_key(g)
	var opts := {"det_r": band, "spot_r": reach, "shootable": live, "reach_field": field, "team": team_id,
		"hull_key": _hull_key, "ids": ids, "reach_needs_los": bool(params.get("needs_los", false)),
		"clearance": ctx.behavior._get_ship_clearance(), "avoid": VisibilityGrid.AVOID_DET, "flank": _flank_dir(ctx),
		"value": value, "harm": harm, "budget_m": WALK_BUDGET_M}
	_walk_engage(vis, danger, here, pos, opts, belief)
	if not _has_station:
		return null
	_claim(team_id, ship.get_instance_id(), SimClock.now_ms())
	var intent := _intent(ctx, field, team_id, params.merged({"away_from": danger}) if bool(params.get("away", false)) else params)
	_shape(intent, ctx, vis, here, pos, opts)
	return intent

## Keeps the held station unless the walk finds a better fight by SWITCH_GAIN.
func _walk_engage(vis: VisibilityGrid, danger: Vector2, here: Vector2, pos: PackedVector2Array,
		opts: Dictionary, belief: Array[Dictionary]) -> void:
	var held := -INF
	if _has_station:
		var ev: Dictionary = vis.engage_eval(Vector2(_station.x, _station.z), pos, opts)
		held = float(ev.score)
		if not is_finite(held):
			_drop()
		else:
			_station_score = held
			_set_target(belief, int(ev.target))
	var r: Dictionary
	if _has_station:
		r = vis.engage_walk(Vector2(_station.x, _station.z), danger, false, pos, opts)
	else:
		r = vis.engage_walk(danger, here, true, pos, opts)
		if not bool(r.get("has_start", false)):
			r = vis.engage_walk(_nearest(pos, here), here, true, pos, opts)
	_steps = int(r.get("steps", 0))
	_trails = [r.get("trail_a", PackedVector2Array()), r.get("trail_b", PackedVector2Array())]
	if not bool(r.get("found", false)):
		return
	var score: float = r.score
	if _has_station and score <= held + absf(held) * SWITCH_GAIN:
		return
	var p: Vector2 = r.pos
	_adopt(Vector3(p.x, 0.0, p.y), score, {})
	_anchor = p
	_set_target(belief, int(r.target))

func _set_target(belief: Array[Dictionary], i: int) -> void:
	_target = belief[i].ship if i >= 0 and i < belief.size() else null

## How fast `target` dies with us on it as well as every friend in range of it: share of its HP per second.
static func _kill_rate(ship: Ship, target: Ship, friends: Array) -> float:
	var dps := 0.0
	for f in friends:
		if not is_instance_valid(f) or not f.is_alive() or f.artillery_controller == null:
			continue
		var r: float = f.global_position.distance_to(target.global_position)
		if f != ship and r > f.artillery_controller.get_params()._range:
			continue
		dps += maxf(SkillStance._expected(target, f, r, TYPICAL_ASPECT_DEG).x, 0.0)
	return dps / maxf(target.health_controller.current_hp, 1.0)

func _decline() -> NavIntent:
	_drop()
	return null

## Standoff from every enemy that shoots.
static func _band(ctx: SkillContext, threat: float, params: Dictionary) -> float:
	var r: float = float(params.get("band_m", params.get("desired_range", 0.0)))
	return r if r > 0.0 else ctx.behavior.engagement_range(ctx.ship, threat)

## A destroyer out front spotting, guns quiet, is a target to close on, not a band to keep out of.
static func threatens(e: Ship) -> bool:
	return e.ship_class != Ship.ShipClass.DD or (e.concealment != null and e.concealment.bloom_value > 0.0)

## Out of any band first; with a radius a boat that reaches its station then
## rides the band edge, turning back at the radius, instead of parking.
func _shape(intent: NavIntent, ctx: SkillContext, vis: VisibilityGrid, here: Vector2,
		pos: PackedVector2Array, opts: Dictionary) -> void:
	var radii: PackedFloat32Array = opts.det_r
	intent.avoid_origins = pos
	intent.avoid_radii = radii
	var out := _exit_point(here, pos, radii)
	if out != here:
		_point(intent, here, out)
		return
	if _radius <= 0.0 or not _has_station:
		return
	var tcr: float = ctx.ship.movement_controller._p().turning_circle_radius
	if here.distance_to(Vector2(_station.x, _station.z)) > tcr * 2.0:
		return
	var step: float = maxf(PATROL_STEP_M, tcr * PATROL_STEP_TURNS)
	if _patrol_sign == 0.0:
		var ahead := _patrol_point(here, pos, radii, step) - here
		_patrol_sign = -1.0 if ahead.dot(_flank_dir(ctx)) < 0.0 else 1.0
	for attempt in 2:
		var next := _patrol_point(here, pos, radii, step * _patrol_sign)
		var ev: Dictionary = vis.hold_eval(next, pos, opts)
		if next != here and next.distance_to(_anchor) <= _radius \
				and bool(ev.get("free", false)) and int(ev.get("count", 0)) > 0:
			_station = Vector3(next.x, 0.0, next.y)
			_point(intent, here, next)
			return
		_patrol_sign = -_patrol_sign

static func _point(intent: NavIntent, here: Vector2, to: Vector2) -> void:
	intent.target_position = Vector3(to.x, 0.0, to.y)
	intent.target_heading = atan2(to.x - here.x, to.y - here.y)

## `arc` metres along the edge of the band we ride (the one whose edge is nearest).
static func _patrol_point(here: Vector2, centres: PackedVector2Array, radii: PackedFloat32Array, arc: float) -> Vector2:
	var best := -1
	var best_gap := INF
	for i in centres.size():
		if radii[i] <= 0.0:
			continue
		var gap: float = absf(here.distance_to(centres[i]) - radii[i])
		if gap < best_gap:
			best_gap = gap
			best = i
	if best < 0:
		return here
	var c: Vector2 = centres[best]
	var r: float = maxf(radii[best], here.distance_to(c))
	return c + (here - c).normalized().rotated(arc / r) * r

## Along the depth-weighted push of every band holding us, to clear water.
static func _exit_point(here: Vector2, centres: PackedVector2Array, radii: PackedFloat32Array) -> Vector2:
	var push := Vector2.ZERO
	for i in centres.size():
		var d: float = here.distance_to(centres[i])
		if radii[i] > 0.0 and d < radii[i]:
			push += (here - centres[i]).normalized() * (radii[i] - d) if d > 1.0 else Vector2.RIGHT * radii[i]
	if push == Vector2.ZERO:
		return here
	var dir := push.normalized()
	var p := here
	for _step in EXIT_MAX_STEPS:
		p += dir * EXIT_STEP_M
		var clear := true
		for i in centres.size():
			if radii[i] > 0.0 and p.distance_to(centres[i]) < radii[i]:
				clear = false
				break
		if clear:
			return p + dir * EXIT_MARGIN_M
	return p
