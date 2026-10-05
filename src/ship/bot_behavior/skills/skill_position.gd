class_name SkillPosition
extends BotSkill

## A held station, its team claim, and the intent that sails to it. Searches
## are the subclasses' business; `_walk_station` is the shared perimeter walk.

## Shore refinement is only tried this close to an island's bounding radius.
const SHORE_REACH_CLEARANCES: float = 3.0
## A shore point may lose this much score against the cell it refines.
const SHORE_SCORE_SLACK: float = 0.05
const CLAIM_TTL_MS: int = 6000
## Team-mates' stations are kept this many clearances apart.
const CLAIM_SEPARATION_CLEARANCES: float = 3.0
const REFINE_BUDGET_M := 8000.0

## team_id -> ship instance id -> {pos: Vector2, ms: int, key: int}
static var _claims: Dictionary = {}

var _station: Vector3 = Vector3.ZERO
var _has_station: bool = false
var _station_score: float = -INF
var _terms: Dictionary = {}
var _refined: bool = false
var _claim_team: int = -1
var _claim_ship: int = -1
var _hull_key: int = 0
var _count: int = 0
var _steps: int = 0
var _trails: Array[PackedVector2Array] = []

func reset() -> void:
	release_claim()
	_has_station = false
	_station_score = -INF
	_terms = {}
	_refined = false
	_count = 0
	_trails = []

func station_position() -> Vector3:
	return _station

func has_station() -> bool:
	return _has_station

func score() -> float:
	return _station_score

func terms() -> Dictionary:
	return _terms

func trails() -> Array[PackedVector2Array]:
	return _trails

func debug_text() -> String:
	if not _has_station:
		return "%s: none" % _label()
	return "%s %d | last walk %d cells" % [_label(), _count, _steps]

func _label() -> String:
	return "Position"

func _adopt(dest: Vector3, best_score: float, best_terms: Dictionary) -> void:
	_station = dest
	_has_station = true
	_station_score = best_score
	_terms = best_terms

func _drop() -> void:
	release_claim()
	_has_station = false
	_station_score = -INF

## Keeps the held station while it still sees `_count` goals, else walks out
## from the danger for one. `opts` are hold_walk's; need and budget are set here.
func _walk_station(vis: VisibilityGrid, danger: Vector2, here: Vector2, pos: PackedVector2Array, opts: Dictionary) -> void:
	if _has_station:
		var ev: Dictionary = vis.hold_eval(Vector2(_station.x, _station.z), pos, opts)
		_count = int(ev.count) if bool(ev.free) else 0
		if _count == 0:
			_drop()
	var r: Dictionary
	if _has_station:
		opts.need = _count + 1
		opts.budget_m = REFINE_BUDGET_M / pow(2.0, maxi(_count - 1, 0))
		r = vis.hold_walk(Vector2(_station.x, _station.z), danger, false, pos, opts)
	else:
		opts.need = 1
		opts.budget_m = 0.0
		r = vis.hold_walk(danger, here, true, pos, opts)
		if not bool(r.get("has_start", false)):
			r = vis.hold_walk(_nearest(pos, here), here, true, pos, opts)
	_steps = int(r.get("steps", 0))
	_trails = [r.get("trail_a", PackedVector2Array()), r.get("trail_b", PackedVector2Array())]
	if bool(r.get("found", false)):
		var p: Vector2 = r.pos
		_count = int(r.count)
		_adopt(Vector3(p.x, 0.0, p.y), _count, {})

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

## Heading: away from `away_from` when given, else bow or stern into the
## shooters' cone, whichever is the smaller turn; the angling skill's answer
## when nothing can reach here.
func _intent(ctx: SkillContext, field: ReachField, team_id: int, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var heading: float
	var away = params.get("away_from")
	if away is Vector2 and Vector2(_station.x, _station.z).distance_to(away) > 1.0:
		var out: Vector2 = Vector2(_station.x, _station.z) - away
		heading = atan2(out.x, out.y)
	else:
		var cone: Dictionary = field.cone_at(team_id, Vector2(_station.x, _station.z))
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

static func _nearest(points: PackedVector2Array, to: Vector2) -> Vector2:
	var best := to
	var best_d := INF
	for p in points:
		if p.distance_squared_to(to) < best_d:
			best_d = p.distance_squared_to(to)
			best = p
	return best

# --- team claims -------------------------------------------------------------

func _claim(team_id: int, ship_id: int, now: int) -> void:
	if not _claims.has(team_id):
		_claims[team_id] = {}
	_claims[team_id][ship_id] = {"pos": Vector2(_station.x, _station.z), "ms": now, "key": _hull_key}
	_claim_team = team_id
	_claim_ship = ship_id

func release_claim() -> void:
	if _claim_team >= 0 and _claims.has(_claim_team):
		_claims[_claim_team].erase(_claim_ship)
	_claim_team = -1
	_claim_ship = -1

static func _other_claims(team_id: int, ship_id: int, now: int) -> PackedVector2Array:
	return _other_claims_keyed(team_id, ship_id, now)[0]

## [positions, hull keys] of team-mates' live claims.
static func _other_claims_keyed(team_id: int, ship_id: int, now: int) -> Array:
	var pos := PackedVector2Array()
	var keys := PackedInt64Array()
	if not _claims.has(team_id):
		return [pos, keys]
	var team: Dictionary = _claims[team_id]
	for sid in team.keys():
		if now - int(team[sid].ms) > CLAIM_TTL_MS:
			team.erase(sid)
		elif sid != ship_id:
			pos.append(team[sid].pos as Vector2)
			keys.append(int(team[sid].get("key", 0)))
	return [pos, keys]
