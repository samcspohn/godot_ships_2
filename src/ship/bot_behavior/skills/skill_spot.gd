class_name SkillSpot
extends SkillStation

## One walk, two goals. SPOT: outside detection, seeing targets a friend can
## shoot. COVER: out of every enemy's sight within our firing bloom, able to
## land shells over the terrain on a spotted target.
## Refine budget halves per target already held: more to lose, less to gain.

enum Mode { SPOT, COVER }

## Kept for DDBehavior.engagement_range and _is_gunboat, which band on it.
const SAFE_MARGIN := 1.15
const FRIENDS := 4
const REFINE_BUDGET_M := 8000.0

var mode: int = Mode.SPOT
var stealth_corridor: bool = true
var _count: int = 0
var _steps: int = 0
var _trails: Array[PackedVector2Array] = []

func _init(m: int = Mode.SPOT) -> void:
	mode = m

func _label() -> String:
	return "Cover" if mode == Mode.COVER else "Spot"

func reset() -> void:
	super()
	stealth_corridor = true
	_count = 0
	_trails = []

func trails() -> Array[PackedVector2Array]:
	return _trails

func debug_text() -> String:
	if not _has_station:
		return "%s: none" % _label()
	return "%s %d | last walk %d cells" % [_label(), _count, _steps]

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var vis: VisibilityGrid = NavigationMapManager.get_visibility()
	var field: ReachField = NavigationMapManager.get_reach_field()
	var ship: Ship = ctx.ship
	if vis == null or field == null or not field.is_built() or ship.team == null or ctx.server == null:
		return _decline()
	var team_id: int = ship.team.team_id
	var belief: Array[Dictionary] = ctx.server._team_belief(team_id)
	if belief.is_empty():
		return _decline()
	if mode == Mode.SPOT and ship.is_detected() \
			and ctx.behavior.get_threat_score(ctx) > ctx.behavior._doc().stealth_threat:
		return _decline()

	var inp := _inputs(ctx, field, team_id, belief)
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var danger3: Vector3 = ctx.behavior._get_positioning_danger_center()
	var danger := Vector2(danger3.x, danger3.z) if danger3 != Vector3.ZERO else field.get_team_danger_centre(team_id)
	var flank := _flank_dir(ctx)
	var clearance: float = ctx.behavior._get_ship_clearance()

	var opts := {"det_r": inp.det, "spot_r": inp.spot, "shootable": inp.shoot, "clearance": clearance,
		"avoid": VisibilityGrid.AVOID_DET, "flank": flank}
	if mode == Mode.COVER:
		var g: Dictionary = NavigationMapManager.reach_gun(ship)
		if g.is_empty():
			return _decline()
		opts.merge({"avoid": VisibilityGrid.AVOID_DET | VisibilityGrid.AVOID_LOS, "los_r": inp.los,
			"reach_field": field, "team": team_id, "hull_key": NavigationMapManager.reach_hull_key(g),
			"ids": inp.ids}, true)
	if _has_station:
		var ev: Dictionary = vis.hold_eval(Vector2(_station.x, _station.z), inp.pos, opts)
		_count = int(ev.count) if bool(ev.free) else 0
		if _count == 0:
			_drop()
	var r: Dictionary
	if _has_station:
		opts.need = _count + 1
		opts.budget_m = REFINE_BUDGET_M / pow(2.0, _count - 1)
		r = vis.hold_walk(Vector2(_station.x, _station.z), danger, false, inp.pos, opts)
	else:
		opts.need = 1
		opts.budget_m = 0.0
		r = vis.hold_walk(danger, here, true, inp.pos, opts)
		if not bool(r.get("has_start", false)):
			r = vis.hold_walk(_nearest(inp.pos, here), here, true, inp.pos, opts)
	_steps = int(r.get("steps", 0))
	_trails = [r.get("trail_a", PackedVector2Array()), r.get("trail_b", PackedVector2Array())]
	if bool(r.get("found", false)):
		var p: Vector2 = r.pos
		_count = int(r.count)
		_adopt(Vector3(p.x, 0.0, p.y), _count, {})
	if not _has_station:
		return _decline()
	stealth_corridor = true
	_claim(team_id, ship.get_instance_id(), SimClock.now_ms())
	return _intent(ctx, field, team_id, params)

func _decline() -> NavIntent:
	_drop()
	stealth_corridor = false
	return null

func _inputs(ctx: SkillContext, field: ReachField, team_id: int, belief: Array[Dictionary]) -> Dictionary:
	if mode == Mode.COVER:
		return _cover_inputs(ctx.ship, belief)
	var ship: Ship = ctx.ship
	var shootable_ids := {}
	var ids: PackedInt64Array = field.get_team_enemy_ids(team_id)
	for f in _nearest_friends(ctx, team_id):
		var g: Dictionary = NavigationMapManager.reach_gun(f)
		if g.is_empty():
			continue
		var mask: int = field.reach_mask(team_id, NavigationMapManager.reach_hull_key(g),
			Vector2(f.global_position.x, f.global_position.z))
		for i in ids.size():
			if mask & (1 << i):
				shootable_ids[ids[i]] = true
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
	var out := {"pos": PackedVector2Array(), "det": PackedFloat32Array(), "spot": PackedFloat32Array(), "shoot": PackedByteArray()}
	for b in belief:
		var e: Ship = b.ship
		out.pos.append(b.pos)
		out.det.append(maxf(conceal, float(b.force_spot)) + float(b.spread))
		var cp: ConcealmentParams = e.concealment.params.p() if e.concealment != null and e.concealment.params != null else null
		out.spot.append(cp.radius if cp != null else 0.0)
		out.shoot.append(1 if shootable_ids.has(e.get_instance_id()) else 0)
	return out

## Radar and hydro still see through the rock; everything else needs sight
## within the bloom our own guns give us. Only live contacts can be shot at.
func _cover_inputs(ship: Ship, belief: Array[Dictionary]) -> Dictionary:
	var g: Dictionary = NavigationMapManager.reach_gun(ship)
	var bloom: float = maxf(NavigationMapManager.reach_conceal_radius(ship), float(g.get("range", 0.0)))
	var out := {"pos": PackedVector2Array(), "det": PackedFloat32Array(), "spot": PackedFloat32Array(),
		"los": PackedFloat32Array(), "shoot": PackedByteArray(), "ids": PackedInt64Array()}
	for b in belief:
		var spread: float = b.spread
		out.pos.append(b.pos)
		out.det.append(float(b.force_spot) + spread if float(b.force_spot) > 0.0 else 0.0)
		out.los.append(maxf(bloom, float(b.force_spot)) + spread)
		out.spot.append(0.0)
		out.shoot.append(1 if int(b.source) == 0 else 0)
		out.ids.append((b.ship as Ship).get_instance_id())
	return out

func _nearest_friends(ctx: SkillContext, team_id: int) -> Array[Ship]:
	var me: Vector3 = ctx.ship.global_position
	var out: Array[Ship] = []
	for f in ctx.server.get_team_ships(team_id):
		if f != ctx.ship and is_instance_valid(f) and f.is_alive():
			out.append(f)
	out.sort_custom(func(a: Ship, b: Ship) -> bool:
		return a.global_position.distance_squared_to(me) < b.global_position.distance_squared_to(me))
	return out.slice(0, FRIENDS)

## Unit vector out along our side of the fleet line; zero inside the centreline deadband.
func _flank_dir(ctx: SkillContext) -> Vector2:
	var ff: FleetFrame = ctx.behavior.fleet_frame()
	var side: float = ff.side_of(ctx.ship.global_position)
	if absf(side) < FleetFrame.SIDE_DEADBAND:
		return Vector2.ZERO
	return Vector2(ff.right.x, ff.right.z).normalized() * signf(side)

static func _nearest(points: PackedVector2Array, to: Vector2) -> Vector2:
	var best := to
	var best_d := INF
	for p in points:
		if p.distance_squared_to(to) < best_d:
			best_d = p.distance_squared_to(to)
			best = p
	return best
