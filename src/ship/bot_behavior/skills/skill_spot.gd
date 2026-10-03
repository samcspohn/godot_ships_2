class_name SkillSpot
extends SkillStation

## Outside detection, seeing targets a friend can shoot. Refine budget halves
## per target already held: more to lose, less to gain.

## Kept for DDBehavior.engagement_range and _is_gunboat, which band on it.
const SAFE_MARGIN := 1.15
const FRIENDS := 4
const REFINE_BUDGET_M := 8000.0
var stealth_corridor: bool = true
var _count: int = 0
var _steps: int = 0
var _trails: Array[PackedVector2Array] = []

func reset() -> void:
	super()
	stealth_corridor = true
	_count = 0
	_trails = []

func trails() -> Array[PackedVector2Array]:
	return _trails

func debug_text() -> String:
	if not _has_station:
		return "Spot: none"
	return "Spot %d | last walk %d cells" % [_count, _steps]

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var vis: VisibilityGrid = NavigationMapManager.get_visibility()
	var field: ReachField = NavigationMapManager.get_reach_field()
	var ship: Ship = ctx.ship
	if vis == null or field == null or not field.is_built() or ship.team == null or ctx.server == null:
		return _decline()
	var team_id: int = ship.team.team_id
	var belief: Array[Dictionary] = ctx.server._team_belief(team_id)
	if belief.is_empty() or _declines(ctx):
		return _decline()

	var walk := _walk_inputs(ctx, field, team_id, belief)
	if walk.is_empty():
		return _decline()
	var pos: PackedVector2Array = walk.pos
	var opts: Dictionary = walk.opts
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var danger3: Vector3 = ctx.behavior._get_positioning_danger_center()
	var danger := Vector2(danger3.x, danger3.z) if danger3 != Vector3.ZERO else field.get_team_danger_centre(team_id)
	opts.merge({"clearance": ctx.behavior._get_ship_clearance(), "avoid": VisibilityGrid.AVOID_DET,
		"flank": _flank_dir(ctx)}, true)
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
		r = _walk_out(vis, danger, here, pos, opts)
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
	# Bow out: lit, the boat sprints straight away; torpedoes from the threat meet its stern.
	return _intent(ctx, field, team_id, params.merged({"away_from": danger}))

## Outward from the danger centre toward us, else from the nearest contact.
func _walk_out(vis: VisibilityGrid, danger: Vector2, here: Vector2, pos: PackedVector2Array, opts: Dictionary) -> Dictionary:
	opts.need = 1
	opts.budget_m = 0.0
	var r: Dictionary = vis.hold_walk(danger, here, true, pos, opts)
	if not bool(r.get("has_start", false)):
		r = vis.hold_walk(_nearest(pos, here), here, true, pos, opts)
	return r

func _decline() -> NavIntent:
	_drop()
	stealth_corridor = false
	return null

## Lit under real threat a spotter has nothing left to hide.
func _declines(ctx: SkillContext) -> bool:
	return ctx.ship.is_detected() and ctx.behavior.get_threat_score(ctx) > ctx.behavior._doc().stealth_threat

## {pos, opts} for the walk: the zone to stay out of and the goal per contact.
func _walk_inputs(ctx: SkillContext, field: ReachField, team_id: int, belief: Array[Dictionary]) -> Dictionary:
	var inp := _inputs(ctx, field, team_id, belief)
	return {"pos": inp.pos, "opts": {"det_r": inp.det, "spot_r": inp.spot, "shootable": inp.shoot}}

func _inputs(ctx: SkillContext, field: ReachField, team_id: int, belief: Array[Dictionary]) -> Dictionary:
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
