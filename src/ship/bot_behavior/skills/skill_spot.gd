class_name SkillSpot
extends SkillPosition

## Outside detection, seeing targets a friend can shoot. Refine budget halves
## per target already held: more to lose, less to gain.

## Kept for DDBehavior.engagement_range and _is_gunboat, which band on it.
const SAFE_MARGIN := 1.15
const FRIENDS := 4
const BELIEF_SCALE_M := 10000.0
var stealth_corridor: bool = true

func reset() -> void:
	super()
	stealth_corridor = true

func _label() -> String:
	return "Spot"

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
	var danger := _belief_centre(ctx, belief, here)
	opts.merge({"clearance": ctx.behavior._get_ship_clearance(), "avoid": VisibilityGrid.AVOID_DET,
		"flank": _flank_dir(ctx)}, true)
	_walk_station(vis, danger, here, pos, opts)
	if not _has_station:
		return _decline()
	stealth_corridor = true
	_claim(team_id, ship.get_instance_id(), SimClock.now_ms())
	# Bow out: lit, the boat sprints straight away; torpedoes from the threat meet its stern.
	var intent := _intent(ctx, field, team_id, params.merged({"away_from": danger}))
	_shape(intent, ctx, vis, here, pos, opts)
	return intent

func _decline() -> NavIntent:
	_drop()
	stealth_corridor = false
	return null

## Every contact, presumed ones included, by certainty and nearness: the
## spotted centre alone drags the walk to whichever flank happens to be lit.
func _belief_centre(ctx: SkillContext, belief: Array[Dictionary], here: Vector2) -> Vector2:
	var g: Dictionary = NavigationMapManager.reach_gun(ctx.ship)
	var scale: float = float(g.range) if not g.is_empty() else BELIEF_SCALE_M
	var sum := Vector2.ZERO
	var total := 0.0
	for b in belief:
		var p: Vector2 = b.pos
		var w: float = float(b.weight) * exp(-p.distance_to(here) / scale)
		sum += p * w
		total += w
	return sum / total if total > 0.0 else _nearest(PackedVector2Array(belief.map(func(b): return b.pos)), here)

## Last say over the intent once the station is held.
func _shape(_intent: NavIntent, _ctx: SkillContext, _vis: VisibilityGrid, _here: Vector2,
		_pos: PackedVector2Array, _opts: Dictionary) -> void:
	pass

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
