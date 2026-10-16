class_name SkillSpot
extends SkillPosition

## Outside detection (an island's shadow counts), lighting this ship's own
## nearest dark priorities, spawn references included, or for one that may hide
## better than we do, just outside the ring it would see us from; with none or
## no such station, the enemies
## only it would light (no friend holds them, no other spotter claimed them);
## with none such, any enemy. Refine budget halves per target already held.

## Kept for DDBehavior.engagement_range and _is_gunboat, which band on it.
const SAFE_MARGIN := 1.15
const SPOT_CLAIM_TTL_MS := 6000
## At zero HP the detection and radar/hydro zones a spotter keeps out of are this much wider.
const HURT_MARGIN := 0.5
## A dark contact counts as looked at from this far outside the ring it would see us from.
const LOOK_M := 1000.0
## team_id -> enemy instance id -> [spotter instance id, ms].
static var _spot_claims: Dictionary = {}
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
	var refs: Array[Dictionary] = ctx.server.anonymous_refs(team_id)
	if belief.is_empty() and refs.is_empty():
		return _decline()

	var inp := _inputs(ctx, team_id, belief, refs)
	var pos: PackedVector2Array = inp.pos
	var opts := {"det_r": inp.det, "los_r": inp.always, "spot_r": inp.spot, "shootable": inp.shoot}
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var pp: Vector3 = ctx.behavior.priority_point()
	var danger := Vector2(pp.x, pp.z) if pp.is_finite() else _belief_centre(ctx, belief, here)
	opts.merge({"clearance": ctx.behavior._get_ship_clearance(),
		"avoid": VisibilityGrid.AVOID_DET | VisibilityGrid.AVOID_DET_SEEN,
		"flank": _flank_dir(ctx)}, true)
	_walk_station(vis, danger, here, pos, opts)
	if not _has_station and inp.mine:
		opts.shootable = _team_wanted(team_id, ship, belief, refs.size())
		_walk_station(vis, danger, here, pos, opts)
	if not _has_station:
		return _decline()
	stealth_corridor = true
	_claim(team_id, ship.get_instance_id(), SimClock.now_ms())
	_claim_spots(team_id, ship, belief)
	# Bow out: lit, the boat sprints straight away; torpedoes from the threat meet its stern.
	return _intent(ctx, field, team_id, params.merged({"away_from": danger}))

func _decline() -> NavIntent:
	_drop()
	stealth_corridor = false
	return null

func _inputs(ctx: SkillContext, team_id: int, belief: Array[Dictionary], refs: Array[Dictionary]) -> Dictionary:
	var ship: Ship = ctx.ship
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
	# Hurt, the spotter keeps further out: one more detection is worth less than the hull.
	var hp_frac: float = clampf(ship.health_controller.current_hp / maxf(ship.health_controller.max_hp, 1.0), 0.0, 1.0)
	var margin: float = 1.0 + HURT_MARGIN * (1.0 - hp_frac)
	var out := {"pos": PackedVector2Array(), "det": PackedFloat32Array(), "always": PackedFloat32Array(),
		"spot": PackedFloat32Array(), "shoot": PackedByteArray()}
	var mine := {}
	for c in ctx.behavior.priorities:
		if mine.size() >= BotBehavior.PRIORITY_COUNT:
			break
		var pe = c.ship
		if pe == null:
			mine[c.ref] = true
		elif is_instance_valid(pe) and not pe.visible_to_enemy:
			mine[pe] = true
	for b in belief:
		var e: Ship = b.ship
		out.pos.append(b.pos)
		out.det.append(maxf(conceal, float(b.force_spot)) * margin + float(b.spread))
		# Radar and hydro see through islands.
		out.always.append(float(b.force_spot) * margin + float(b.spread) if float(b.force_spot) > 0.0 else 0.0)
		var cp: ConcealmentParams = e.concealment.params.p() if e.concealment != null and e.concealment.params != null else null
		var sr: float = cp.radius if cp != null else 0.0
		# Somewhere in its spread, it may hide better than we do: going to look is the station.
		if not e.visible_to_enemy:
			sr = maxf(sr + float(b.spread), out.det[out.det.size() - 1] + LOOK_M)
		out.spot.append(sr)
		out.shoot.append(1 if mine.has(e) else 0)
	for r in refs:
		out.pos.append(r.pos)
		out.det.append(conceal * margin)
		out.always.append(0.0)
		out.spot.append(conceal * margin + LOOK_M)
		out.shoot.append(1 if mine.has(r.id) else 0)
	out.mine = not mine.is_empty()
	if not out.mine:
		out.shoot = _team_wanted(team_id, ship, belief, refs.size())
	return out


## Enemies only this ship would light: no friend holds them, no other spotter claimed them; with none, all.
static func _team_wanted(team_id: int, ship: Ship, belief: Array[Dictionary], n_refs: int) -> PackedByteArray:
	var now: int = SimClock.now_ms()
	var out := PackedByteArray()
	out.resize(belief.size() + n_refs)
	var any_wanted := false
	for i in belief.size():
		var e: Ship = belief[i].ship
		var claimer := spot_claimer(team_id, e, now)
		var wanted: bool = not lit_by_other(e, ship) and (claimer == null or claimer == ship)
		any_wanted = any_wanted or wanted
		out[i] = 1 if wanted else 0
	if not any_wanted:
		out.fill(1)
	return out

## Held this frame by a friend other than `me`.
static func lit_by_other(e: Ship, me: Ship) -> bool:
	if not e.visible_to_enemy or e.concealment == null:
		return false
	for f in e.concealment.spotters:
		if f != me and is_instance_valid(f) and f.is_alive():
			return true
	return false

## The live friend whose Spot station is set to light `e`, else null.
static func spot_claimer(team_id: int, e: Ship, now: int) -> Ship:
	var c: Array = _spot_claims.get(team_id, {}).get(e.get_instance_id(), [])
	if c.is_empty() or now - int(c[1]) > SPOT_CLAIM_TTL_MS:
		return null
	var f := instance_from_id(int(c[0])) as Ship
	return f if f != null and f.is_alive() else null

func _claim_spots(team_id: int, ship: Ship, belief: Array[Dictionary]) -> void:
	var claims: Dictionary = _spot_claims.get_or_add(team_id, {})
	var now: int = SimClock.now_ms()
	for i in mini(belief.size(), 64):
		if _mask & (1 << i) == 0:
			continue
		var e: Ship = belief[i].ship
		var held := spot_claimer(team_id, e, now)
		if held == null or held == ship:
			claims[e.get_instance_id()] = [ship.get_instance_id(), now]
