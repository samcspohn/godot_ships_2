class_name SkillFight
extends SkillPosition

## SkillHold's FIGHT mode: the firing station on the edge of the bands round
## every enemy that shoots (pulled in where an island blocks that enemy's
## shells), hitting as many of our top PRIORITY_COUNT priorities as it can.
## Held while it still hits every one of them that is still a priority, however
## their order shuffles; with none hittable anywhere, any lit enemy. The route is
## walled out of the bands. Declines with
## no such cell. Params: band_m (else desired_range, else each enemy's own radius),
## needs_los (the station must see its target), radius (ride the band edge within
## this of the chosen station instead of parking; 0 parks), away (bow away from
## the danger on arrival).

## A station in an island's shadow pulls that enemy's route wall in to this short of it.
const SHADOW_MARGIN_M := 200.0
## Patrol leg along the band edge, at least, and in turning circles.
const PATROL_STEP_M := 1500.0
const PATROL_STEP_TURNS := 3.0
## A free station further than this outside that ring is pulled back in to it.
const SETTLE_SLACK_M := 400.0
## How far past the station a settle looks for water no enemy can shoot.
const SETTLE_REACH_M := 4000.0

var band_m: float = 0.0
var _patrol_sign: float = 0.0
var _target: Ship = null
## Instance ids of the priorities the held station was chosen to hit.
var _held: Dictionary = {}
var _prio_lit: int = 0
var _radius: float = 0.0
## The station the search chose; riding the band moves _station, not this.
var _anchor: Vector2 = Vector2.ZERO

func reset() -> void:
	super()
	_patrol_sign = 0.0
	_held = {}

func _label() -> String:
	return "Fight"

func debug_text() -> String:
	if not _has_station:
		return "%s: none | P1 band %.0f m" % [_label(), band_m]
	return "%s on %s | hits %d/%d priorities | P1 band %.0f m | last walk %d cells" % [_label(),
		_target.ship_name if is_instance_valid(_target) else "?", _held.size(), _prio_lit, band_m, _steps]

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
	_radius = float(params.get("radius", 0.0))
	var pos := PackedVector2Array()
	var band := PackedFloat32Array()
	var reach := PackedFloat32Array()
	var live := PackedByteArray()
	var prio := PackedByteArray()
	var ids := PackedInt64Array()
	var heavy := PackedByteArray()
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var pp: Vector3 = ctx.behavior.priority_point()
	var flank := Vector2(pp.x, pp.z) if pp.is_finite() else here
	var top := {}
	for c in ctx.behavior.priorities:
		if top.size() >= BotBehavior.PRIORITY_COUNT:
			break
		if c.ship != null and is_instance_valid(c.ship):
			top[c.ship] = true
	for b in belief:
		var e: Ship = b.ship
		pos.append(b.pos)
		band.append(radius_for(ctx, e, b.pos, params) + float(b.spread) if threatens(e) else 0.0)
		reach.append(gun_range)
		# A remembered or presumed contact has nothing to shoot at: it is
		# kept out of, never stationed on.
		# Lit across the map is someone else's: only this flank's enemies make a station.
		var is_live: bool = int(b.source) == 0 and (b.pos.distance_to(flank) <= gun_range or b.pos.distance_to(here) <= gun_range)
		live.append(1 if is_live else 0)
		prio.append(1 if is_live and top.has(e) else 0)
		ids.append(e.get_instance_id())
		heavy.append(1 if threatens(e) and ctx.behavior.dangerous(e) else 0)
	var pt: Ship = ctx.behavior.priority_target()
	var pp2 := Vector2(pp.x, pp.z) if pp.is_finite() else here
	band_m = radius_for(ctx, pt, pp2, params) if pt != null else 0.0
	var danger := flank if pp.is_finite() else _belief_centre(ctx, belief, here)
	_hull_key = NavigationMapManager.reach_hull_key(g)
	var opts := {"det_r": band, "spot_r": reach, "shootable": live, "reach_field": field, "team": team_id,
		"hull_key": _hull_key, "ids": ids, "reach_needs_los": bool(params.get("needs_los", false)),
		"clearance": ctx.behavior._get_ship_clearance(), "flank": _flank_dir(ctx),
		"avoid": VisibilityGrid.AVOID_DET | VisibilityGrid.AVOID_DET_SHOT, "heavy": heavy}
	_walk_fight(vis, danger, here, pos, opts, prio, live, belief)
	if not _has_station:
		return null
	opts.shootable = _union(prio, live)
	opts.prio_bits = _bits(prio)
	_claim(team_id, ship.get_instance_id(), SimClock.now_ms())
	var intent := _intent(ctx, field, team_id, params.merged({"away_from": danger}) if bool(params.get("away", false)) else params)
	_shape(intent, ctx, vis, here, pos, opts)
	return intent

## Holds the station while it hits every priority it was chosen for that is
## still one; then looks for one more of them, else searches afresh: priorities
## first, any lit enemy failing that.
func _walk_fight(vis: VisibilityGrid, danger: Vector2, here: Vector2, pos: PackedVector2Array,
		opts: Dictionary, prio: PackedByteArray, live: PackedByteArray, belief: Array[Dictionary]) -> void:
	var prio_ids := _ids_in(belief, _bits(prio))
	_prio_lit = prio_ids.size()
	if _has_station:
		opts.shootable = _union(prio, live)
		_settle(vis, pos, opts)
		var ev: Dictionary = vis.hold_eval(Vector2(_station.x, _station.z), pos, opts)
		var hit := _ids_in(belief, int(ev.mask))
		var keep: bool = bool(ev.free) and not hit.is_empty()
		for id in _held:
			keep = keep and (not prio_ids.has(id) or hit.has(id))
		if keep:
			_held = _ids_in(belief, int(ev.mask) & _bits(prio))
			_count = _held.size() + 1
			_set_target(belief, prio, int(ev.mask))
		else:
			_drop()
	# Searches look first for cells out of the fire of enemies that out-trade us, then anywhere.
	var base: int = opts.avoid
	var tries: Array = [base | VisibilityGrid.AVOID_FIRE, base] if _bits(opts.heavy) != 0 else [base]
	if _has_station:
		if prio_ids.size() > _held.size():
			opts.shootable = prio
			opts.need = _held.size() + 1
			opts.budget_m = REFINE_BUDGET_M
			for avoid in tries:
				opts.avoid = avoid
				if _take(vis.hold_walk(Vector2(_station.x, _station.z), danger, false, pos, opts), prio, belief):
					break
		opts.avoid = base
		return
	for shoot in [prio, live]:
		if _bits(shoot) == 0:
			continue
		opts.shootable = shoot
		opts.need = 1
		for avoid in tries:
			opts.avoid = avoid
			opts.budget_m = REFINE_BUDGET_M
			var r := _fresh_walk(vis, danger, here, pos, opts)
			if _take(r, prio, belief):
				opts.avoid = base
				return
	opts.avoid = base

## When the bands move, the held station follows the nearest one along the ray
## from it, a cell at a time: out until no enemy can shoot it when a band grew
## over it, in for as long as none can when the band drew back. Where shells
## cannot land (an island's shadow) counts as out, whatever the ring says.
func _settle(vis: VisibilityGrid, pos: PackedVector2Array, opts: Dictionary) -> void:
	var st := Vector2(_station.x, _station.z)
	var radii: PackedFloat32Array = opts.det_r
	var best := -1
	for i in pos.size():
		if radii[i] > 0.0 and (best < 0 or st.distance_squared_to(pos[i]) < st.distance_squared_to(pos[best])):
			best = i
	if best < 0:
		return
	var c: Vector2 = pos[best]
	var d0: float = st.distance_to(c)
	var r: Dictionary
	if not bool(vis.hold_eval(st, pos, opts).free):
		# Its fire reaches the station now: out along the ray to the first cell it cannot shoot.
		r = vis.ray_free(c, st, d0, d0 + SETTLE_REACH_M, pos, opts)
	elif d0 - radii[best] > SETTLE_SLACK_M:
		# Its ring drew back: in along the ray for as long as it still cannot shoot us.
		r = vis.ray_last_free(st, c, d0, pos, opts)
	if r.is_empty() or not bool(r.found):
		return
	var p: Vector2 = r.pos
	if p.distance_to(st) > 1.0:
		_adopt(Vector3(p.x, 0.0, p.y), _station_score, {})
		_anchor = p

func _take(r: Dictionary, prio: PackedByteArray, belief: Array[Dictionary]) -> bool:
	_steps = int(r.get("steps", 0))
	_trails = [r.get("trail_a", PackedVector2Array()), r.get("trail_b", PackedVector2Array())]
	_trail_counts = [r.get("trail_a_n", PackedInt32Array()), r.get("trail_b_n", PackedInt32Array())]
	if not bool(r.get("found", false)):
		return false
	var p: Vector2 = r.pos
	var mask := int(r.mask)
	_held = _ids_in(belief, mask & _bits(prio))
	_adopt(Vector3(p.x, 0.0, p.y), _held.size() + 1, {})
	_count = _held.size() + 1
	_anchor = p
	_set_target(belief, prio, mask)
	return true

## The first priority the mask hits, else whatever it hits first.
func _set_target(belief: Array[Dictionary], prio: PackedByteArray, mask: int) -> void:
	_target = null
	for i in mini(belief.size(), 64):
		if mask & (1 << i) != 0 and (_target == null or prio[i] != 0):
			_target = belief[i].ship
			if prio[i] != 0:
				return

static func _popcount(m: int) -> int:
	var n := 0
	while m != 0:
		m &= m - 1
		n += 1
	return n

static func _bits(flags: PackedByteArray) -> int:
	var m := 0
	for i in mini(flags.size(), 64):
		if flags[i] != 0:
			m |= 1 << i
	return m

static func _union(a: PackedByteArray, b: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray(a)
	for i in out.size():
		out[i] = out[i] | b[i]
	return out

static func _ids_in(belief: Array[Dictionary], mask: int) -> Dictionary:
	var out := {}
	for i in mini(belief.size(), 64):
		if mask & (1 << i) != 0:
			out[belief[i].ship.get_instance_id()] = true
	return out

func _decline() -> NavIntent:
	_drop()
	return null

## How close to fight `e`, believed `at`: an explicit band_m or desired_range, else the ship's own ring for it.
static func radius_for(ctx: SkillContext, e: Ship, at: Vector2, params: Dictionary) -> float:
	var r: float = float(params.get("band_m", params.get("desired_range", 0.0)))
	return r if r > 0.0 else ctx.behavior.ring(ctx, e, at)

## A destroyer out front spotting, guns quiet, is a target to close on, not a band to keep out of.
static func threatens(e: Ship) -> bool:
	return e.ship_class != Ship.ShipClass.DD or (e.concealment != null and e.concealment.bloom_value > 0.0)

## Out of any band first; with a radius a boat that reaches its station then
## rides the band edge, turning back at the radius, instead of parking.
func _shape(intent: NavIntent, ctx: SkillContext, vis: VisibilityGrid, here: Vector2,
		pos: PackedVector2Array, opts: Dictionary) -> void:
	var radii := _walls(opts.det_r, pos)
	if not ctx.ship.visible_to_enemy:
		radii = _short_of(radii, pos, here)
	intent.avoid_origins = pos
	intent.avoid_radii = radii
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
		var prio_hit := _popcount(int(ev.get("mask", 0)) & int(opts.prio_bits))
		if next != here and next.distance_to(_anchor) <= _radius \
				and bool(ev.get("free", false)) and int(ev.get("count", 0)) > 0 and prio_hit >= _held.size():
			_station = Vector3(next.x, 0.0, next.y)
			_point(intent, here, next)
			return
		_patrol_sign = -_patrol_sign

## The bands as route walls, each pulled in short of a station inside it (an island's shadow).
func _walls(bands: PackedFloat32Array, pos: PackedVector2Array) -> PackedFloat32Array:
	var out := bands.duplicate()
	if not _has_station:
		return out
	var st := Vector2(_station.x, _station.z)
	for i in out.size():
		out[i] = minf(out[i], maxf(st.distance_to(pos[i]) - SHADOW_MARGIN_M, 0.0))
	return out

## A band only matters to a ship they can see: unseen, each one holding `at` is pulled in short of it.
static func _short_of(radii: PackedFloat32Array, pos: PackedVector2Array, at: Vector2) -> PackedFloat32Array:
	var out := radii.duplicate()
	for i in out.size():
		out[i] = minf(out[i], maxf(at.distance_to(pos[i]) - SHADOW_MARGIN_M, 0.0))
	return out

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
