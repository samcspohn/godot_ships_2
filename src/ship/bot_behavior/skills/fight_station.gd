class_name FightStation
extends SkillPosition

## SkillFight's open-water station: the point on the enemies' rings (or our gun range
## round a target without one) within WINDOW_M dealing the most less what it
## takes, outside every ring whose owner's shells land there; with none, a step
## toward the most valued target's. The route is walled out of the rings. Params:
## band_m (else desired_range, else each enemy's own ring), away (bow away from
## the danger on arrival), presumed (fight where unseen enemies are guessed to
## be, worth and threatening by their belief weight: the opening).

## A station in an island's shadow pulls that enemy's route wall in to this short of it.
const SHADOW_MARGIN_M := 200.0
const WINDOW_M := 6000.0
static var _tm: Array = []
static var _tc: Array = []
## Stations sit this far outside a ring, and this far inside our gun range round a target without one.
const WALK_MARGIN_M := 150.0
## Sailing to a station that costs this share of our HP on the way is not worth starting.
const SURVIVE_SHARE := 0.8
## A chase leg must close on its target by this much, or Fight gives the ship up to spotting.
const CHASE_MIN_PROGRESS_M := 500.0
const CHASE_RETRY_S := 10.0
## Harm grows by this share for each enemy past the first that can shoot the cell.
const MARCH_FOCUS := 0.25
## Harm doubles as the shooters' arc widens from 60° to 180°: a cell where we cannot angle to them all.
const MARCH_CROSSFIRE := 1.0
## What reaching each of the top priorities is worth, in order; any other lit enemy.
const MARCH_PRIORITY_COUNT := 4
const MARCH_OTHER_VALUE := 0.3
## A cell gives up this share of the held station's net value per km from the last station.
const MOVE_COST_PER_KM := 0.1
const MOVE_COST_FLOOR := 0.002
## A chase cell counts this many metres nearer its target per metre from the last station.
const CHASE_ANCHOR_W := 0.5
## A flank ship walks out no farther than this share of our gun range past the local enemy centre.
const PINCER_RANGE_SHARE := 0.4
## A new station may lie this far back against the walk.
const WALK_SLACK_M := 300.0
## Inside this of a team-mate's station a cell gives up to this share of the held net value.
const SPACING_M := 1500.0
const SPACING_COST := 0.5
const HARM_PRICE_FULL := 0.5
const HARM_PRICE_MIN := 0.3
const HARM_PRIOR_LIFE_S := 900.0
const HARM_PRIOR_S := 300.0

var _presumed := false
## A new cell must beat the held one's score by this share of it, or this much.
const MARCH_SWITCH_REL := 0.2
const MARCH_SWITCH_ABS := 0.02
const MARCH_MS := 1000

var band_m: float = 0.0
var _target: Ship = null
## Instance ids of the priorities the held station was chosen to hit.
var _held: Dictionary = {}
var _prio_lit: int = 0
var _marched_ms: int = -100000
var _march_score: float = 0.0
var _march_value: float = 0.0
var _march_harm: float = 0.0
var _chasing := false
## Share of our HP the straight run to the station costs, at the last search.
var _route_hp: float = 0.0
var _chase_to := Vector2.INF
var _chase_failed_at: float = -INF
var _harm_price: float = 1.0
var _cells: int = 0

func reset() -> void:
	super()
	_held = {}
	_chasing = false
	_route_hp = 0.0

func _label() -> String:
	return "Fight"

func debug_text() -> String:
	if not _has_station:
		return "%s: none | %d cells" % [_label(), _cells]
	if _chasing:
		return "%s: chasing | route %.0f%% hp | %d cells" % [_label(), _route_hp * 100.0, _cells]
	return "%s on %s | hits %d/%d priorities | %.2f - %.2f %%/s at %.2f, net %.1f%% | route %.0f%% hp | %d cells" % [_label(),
		_target.ship_name if is_instance_valid(_target) else "?", _held.size(), _prio_lit,
		_march_value * 100.0, _march_harm * 100.0, _harm_price, _march_score * 100.0, _route_hp * 100.0, _cells]

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
	_presumed = bool(params.get("presumed", false))
	var pos := PackedVector2Array()
	var band := PackedFloat32Array()
	var reach := PackedFloat32Array()
	var live := PackedByteArray()
	var prio := PackedByteArray()
	var ids := PackedInt64Array()
	var heavy := PackedByteArray()
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
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
		band.append(_ring_for(ctx, b, params, gun_range, conceal) + float(b.spread) if threatens(e) else 0.0)
		reach.append(gun_range)
		# Lit, only this flank's enemies make a station; remembered and presumed
		# ones are kept out of, except when fighting the presumed, at any range.
		var is_live: bool = (int(b.source) == 0 and (b.pos.distance_to(flank) <= gun_range or b.pos.distance_to(here) <= gun_range)) \
			or (_presumed and int(b.source) != 0)
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
	_march(ctx, vis, here, pos, band, prio, live, belief)
	if _has_station and _chasing and (_route_hp >= SURVIVE_SHARE or not _chase_to.is_finite()
			or here.distance_to(_chase_to) - Vector2(_station.x, _station.z).distance_to(_chase_to) < CHASE_MIN_PROGRESS_M):
		_chase_failed_at = SimClock.now()
		return _decline()
	if not _has_station:
		return null
	opts.shootable = _union(prio, live)
	opts.prio_bits = _bits(prio)
	_claim(team_id, ship.get_instance_id(), SimClock.now_ms())
	var intent := _intent(ctx, field, team_id, params.merged({"away_from": danger}) if bool(params.get("away", false)) else params)
	intent.target_position = ctx.behavior._get_valid_nav_point(intent.target_position)
	_shape(intent, ctx, here, pos, opts)
	return intent

## Holds the station while it still has a target outside the rings and nothing
## in the window scores better by the switch margin; searches at most every MARCH_MS.
func _march(ctx: SkillContext, vis: VisibilityGrid, here: Vector2, pos: PackedVector2Array, rings: PackedFloat32Array,
		prio: PackedByteArray, live: PackedByteArray, belief: Array[Dictionary]) -> void:
	var mo := _march_opts(ctx, belief, live, rings)
	_prio_lit = _ids_in(belief, _bits(prio)).size()
	if _has_station and not _chasing and not bool(vis.fight_eval(Vector2(_station.x, _station.z), pos, mo).ok):
		_drop()
	var now_ms: int = SimClock.now_ms()
	if _has_station and now_ms - _marched_ms < MARCH_MS:
		return
	_marched_ms = now_ms
	_pick(vis, here, pos, mo, prio, belief)
	_route_hp = vis.fight_route_harm(here, Vector2(_station.x, _station.z), pos, mo) / maxf(_harm_price, 0.01) \
		if _has_station else 0.0

func _pick(vis: VisibilityGrid, here: Vector2, pos: PackedVector2Array, mo: Dictionary,
		prio: PackedByteArray, belief: Array[Dictionary]) -> void:
	var holding: bool = _has_station and not _chasing
	mo.held = Vector2(_station.x, _station.z) if holding else Vector2.INF
	var t0 := Time.get_ticks_usec()
	var r: Dictionary = vis.fight_search(here, pos, mo)
	_tm.append(Time.get_ticks_usec() - t0)
	_tc.append(int(r.get("cells", 0)))
	if _tm.size() % 1000 == 0:
		var a := _tm.duplicate(); a.sort()
		var c := _tc.duplicate(); c.sort()
		print("FTIME n=%d p50=%d p99=%d max=%d cand p50=%d max=%d" % [a.size(), a[a.size()/2], a[int(a.size()*0.99)], a[-1], c[c.size()/2], c[-1]])
	_cells = int(r.get("cells", 0))
	if holding and bool(r.held_ok):
		_mark(float(r.held_score), float(r.held_value), float(r.held_harm), int(r.held_mask), prio, belief)
	if not bool(r.found):
		return
	var p: Vector2 = r.pos
	if bool(r.chase):
		if not holding:
			_chasing = true
			_chase_to = r.get("chase_to", Vector2.INF)
			_target = null
			_adopt(Vector3(p.x, 0.0, p.y), 0.0, {})
		return
	var held: float = float(r.held_score) if holding and bool(r.held_ok) else -INF
	if holding and float(r.score) <= held + maxf(MARCH_SWITCH_ABS, absf(held) * MARCH_SWITCH_REL):
		return
	_chasing = false
	_adopt(Vector3(p.x, 0.0, p.y), float(r.score), {})
	_mark(float(r.score), float(r.value), float(r.harm), int(r.mask), prio, belief)

## The threat score the held station's exposure alone would give; 1 while chasing in the open.
func station_threat() -> float:
	if not _has_station or _chasing:
		return 1.0
	return 1.0 - exp(-BotBehavior.THREAT_HORIZON_S * _march_harm / maxf(_harm_price, 0.01))

## A chase failed lately: Fight sits out CHASE_RETRY_S so the fallback can hold.
func resting() -> bool:
	return SimClock.now() - _chase_failed_at < CHASE_RETRY_S

## Whether the run to the station would cost more of our HP than SURVIVE_SHARE.
func doomed() -> bool:
	return _has_station and _route_hp >= SURVIVE_SHARE

func station_xz() -> Vector2:
	return Vector2(_station.x, _station.z) if _has_station else Vector2.INF

func _mark(score: float, value: float, harm: float, mask: int, prio: PackedByteArray, belief: Array[Dictionary]) -> void:
	_march_score = score
	_march_value = value
	_march_harm = harm
	_held = _ids_in(belief, mask & _bits(prio))
	_count = _held.size() + 1
	_set_target(belief, prio, mask)

## What a share of our HP is worth against a share of theirs: half at full HP,
## whole when empty; less again by the HP the match will not leave time to lose,
## at the rate lost so far (from a prior of a full hull over HARM_PRIOR_LIFE_S).
static func harm_price(ctx: SkillContext) -> float:
	var hc = ctx.ship.health_controller
	var frac: float = clampf(hc.current_hp / maxf(hc.max_hp, 1.0), 0.0, 1.0)
	var by_hp: float = lerpf(HARM_PRICE_FULL, 1.0, 1.0 - frac)
	var elapsed: float = ctx.server.match_elapsed
	var rate: float = (hc.max_hp - hc.current_hp + hc.max_hp * HARM_PRIOR_S / HARM_PRIOR_LIFE_S) / (elapsed + HARM_PRIOR_S)
	var by_time: float = clampf(rate * ctx.server.get_match_time_remaining() / maxf(hc.current_hp, 1.0), HARM_PRICE_MIN, 1.0)
	return maxf(by_hp * by_time, HARM_PRICE_MIN)

## fight_search's opts: the trade curves per contact from BotBehavior._trade, padded to one length.
func _march_opts(ctx: SkillContext, belief: Array[Dictionary], live: PackedByteArray, rings: PackedFloat32Array) -> Dictionary:
	var ship: Ship = ctx.ship
	var g: Dictionary = NavigationMapManager.reach_gun(ship)
	var rank := {}
	for c in ctx.behavior.priorities:
		if c.ship != null and rank.size() < MARCH_PRIORITY_COUNT:
			rank[c.ship] = rank.size()
	var trades: Array[Dictionary] = []
	var steps := 0
	for b in belief:
		var t: Dictionary = ctx.behavior._trade(b.ship)
		trades.append(t)
		steps = maxi(steps, (t.out as PackedFloat32Array).size())
	var outs := PackedFloat32Array()
	var ins := PackedFloat32Array()
	var value := PackedFloat32Array()
	var det := PackedFloat32Array()
	var threat := PackedByteArray()
	var aggro := PackedFloat32Array()
	var front := PackedFloat32Array()
	var front_hp := PackedFloat32Array()
	var chase_ring := PackedFloat32Array()
	var walk_r := PackedFloat32Array()
	var friends: Array = ctx.server.get_team_ships(ship.team.team_id)
	var conceal: float = (ship.concealment.params.p() as ConcealmentParams).radius if ship.concealment != null else 0.0
	_harm_price = harm_price(ctx)
	for i in belief.size():
		var o: PackedFloat32Array = (trades[i].out as PackedFloat32Array).duplicate()
		var n: PackedFloat32Array = (trades[i].in as PackedFloat32Array).duplicate()
		o.resize(steps)
		n.resize(steps)
		var e: Ship = belief[i].ship
		var guess: bool = _presumed and int(belief[i].source) != 0
		var price: float = _harm_price * (float(belief[i].weight) if guess else 1.0)
		for k in steps:
			n[k] *= price
		outs.append_array(o)
		ins.append_array(n)
		value.append(0.0 if live[i] == 0 else float(belief[i].weight) if guess
			else 1.0 if rank.has(e) else MARCH_OTHER_VALUE)
		det.append(maxf(conceal, float(belief[i].force_spot)) + float(belief[i].spread))
		threat.append(1 if threatens(e) else 0)
		aggro.append(_aggro(ctx, e, belief[i].pos, friends))
		var f := _front(ctx.ship, belief[i].pos, friends)
		front.append(f.x)
		front_hp.append(f.y)
		chase_ring.append(conceal + float(belief[i].spread) if threatens(e) and float(trades[i].push) < 0.0 else 0.0)
		walk_r.append(rings[i] + WALK_MARGIN_M if rings[i] > 0.0 else (float(g.range) - WALK_MARGIN_M if live[i] != 0 else 0.0))
	return _walk_opts(ctx, ship, float(g.range)).merged({"det_r": det, "spot_r": PackedFloat32Array(), "shootable": live, "heavy": threat,
		"reach_field": NavigationMapManager.get_reach_field(), "team": ship.team.team_id,
		"hull_key": NavigationMapManager.reach_hull_key(g), "ids": PackedInt64Array(belief.map(func(b): return b.ship.get_instance_id())),
		"clearance": ctx.behavior._get_ship_clearance(), "curve_out": outs, "curve_in": ins, "curve_steps": steps,
		"curve_p0_m": BotBehavior.POINT_BLANK_M, "curve_step_m": BotBehavior.RADIUS_STEP_M, "value": value, "aggro": aggro,
		"front": front, "front_hp": front_hp, "focus": MARCH_FOCUS, "crossfire": MARCH_CROSSFIRE, "ring": rings, "walk_r": walk_r,
		"chase_ring": chase_ring, "window_m": WINDOW_M, "speed": ship.movement_controller.max_speed,
		"dark": not ship.visible_to_enemy, "anchor": _anchor_for(ship), "chase_anchor_w": CHASE_ANCHOR_W,
		"move_cost": MOVE_COST_PER_KM / 1000.0 * maxf(_march_score, MOVE_COST_FLOOR),
		"walk_slack": WALK_SLACK_M,
		"claims": _other_claims(ship.team.team_id, ship.get_instance_id(), SimClock.now_ms()), "claim_r": SPACING_M,
		"claim_cost": SPACING_COST * maxf(_march_score, MOVE_COST_FLOOR)})

## Which way stations may walk, on the fleet line local to us (FleetFrame at
## gun-range locality). A flank ship walks only outward on its own side, to at
## most PINCER_RANGE_SHARE of our range past the local enemy centre, then back
## in; a middle ship walks toward the side with fewer friends but stays inside
## the centre deadband, between the flanks.
static func _walk_opts(ctx: SkillContext, ship: Ship, gun_range: float) -> Dictionary:
	var ff: FleetFrame = ctx.behavior.local_frame(ship.global_position, gun_range)
	var right := Vector2(ff.right.x, ff.right.z).normalized()
	var origin := Vector2(ff.friendly_center.x, ff.friendly_center.z)
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var lat: float = (here - origin).dot(right)
	var side: float = ff.side_of(ship.global_position)
	var out := {"walk_from": here, "lat_axis": right, "lat_origin": origin}
	if absf(side) >= FleetFrame.SIDE_DEADBAND:
		var s: float = signf(side)
		var bound: float = s * (Vector2(ff.enemy_center.x, ff.enemy_center.z) - origin).dot(right) + PINCER_RANGE_SHARE * gun_range
		var u_max: float = maxf(bound, s * lat)
		out.walk_axis = right * (s if s * lat <= bound else -s)
		out.lat_min = -u_max if s < 0.0 else -INF
		out.lat_max = u_max if s > 0.0 else INF
		return out
	var band: float = FleetFrame.SIDE_DEADBAND * ff.spread
	var lean := 0
	for f in ctx.server.get_team_ships(ship.team.team_id):
		if f != ship and is_instance_valid(f) and f.is_alive():
			var fs: float = ff.side_of(f.global_position)
			if absf(fs) >= FleetFrame.SIDE_DEADBAND:
				lean += 1 if fs > 0.0 else -1
	out.walk_axis = right * -signf(lean)
	out.lat_min = -band
	out.lat_max = band
	return out

## The last station, while it is within the window.
func _anchor_for(ship: Ship) -> Vector2:
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	return _last_adopted if _last_adopted.is_finite() and _last_adopted.distance_to(here) <= WINDOW_M else Vector2.INF

## How likely `e` (believed `at`) is shooting us: certain while it is, else
## one in however many of our lit ships, us included, its guns reach.
static func _aggro(ctx: SkillContext, e: Ship, at: Vector2, friends: Array) -> float:
	if ctx.behavior.active_shooters_at_me.has(e):
		return 1.0
	if e.artillery_controller == null:
		return 0.0
	var reach: float = e.artillery_controller.get_params()._range
	var n := 1
	for f: Ship in friends:
		if f != ctx.ship and is_instance_valid(f) and f.is_alive() and f.visible_to_enemy \
				and at.distance_to(Vector2(f.global_position.x, f.global_position.z)) <= reach:
			n += 1
	return 1.0 / n

## Range from `at` to our nearest lit ship but `me` (inside it, `me` is the
## nearest target there), and our HP over that ship's: 0 unless we are the tankier.
static func _front(me: Ship, at: Vector2, friends: Array) -> Vector2:
	var d := INF
	var hp := 0.0
	for f: Ship in friends:
		if f != me and is_instance_valid(f) and f.is_alive() and f.visible_to_enemy:
			var df := at.distance_to(Vector2(f.global_position.x, f.global_position.z))
			if df < d:
				d = df
				hp = f.health_controller.current_hp
	var ratio: float = me.health_controller.current_hp / hp if hp > 0.0 else 0.0
	return Vector2(d, ratio if ratio > 1.0 else 0.0)

## The first priority the mask hits, else whatever it hits first.
func _set_target(belief: Array[Dictionary], prio: PackedByteArray, mask: int) -> void:
	_target = null
	for i in mini(belief.size(), 64):
		if mask & (1 << i) != 0 and (_target == null or prio[i] != 0):
			_target = belief[i].ship
			if prio[i] != 0:
				return

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

## `b`'s ring, never past our own guns.
static func _ring_for(ctx: SkillContext, b: Dictionary, params: Dictionary, gun_range: float, _conceal: float) -> float:
	return minf(radius_for(ctx, b.ship, b.pos, params), gun_range)

## A destroyer out front spotting, guns quiet, is a target to close on, not a band to keep out of.
static func threatens(e: Ship) -> bool:
	return e.ship_class != Ship.ShipClass.DD or (e.concealment != null and e.concealment.bloom_value > 0.0)

## The route is walled out of the rings, each pulled in short of the station inside it.
func _shape(intent: NavIntent, ctx: SkillContext, here: Vector2, pos: PackedVector2Array, opts: Dictionary) -> void:
	var radii := _walls(opts.det_r, pos)
	if not ctx.ship.visible_to_enemy:
		radii = _short_of(radii, pos, here)
	intent.avoid_origins = pos
	intent.avoid_radii = radii

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


