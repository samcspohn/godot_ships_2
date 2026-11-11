class_name SkillStance
extends BotSkill

## Owns heading and throttle while guns can reach us. The hull lies on the threat
## axis, bow or stern to the weighted fire: the end nearer the bow now, sailing
## ahead when the goal lies that way. When it lies the other way, the hull turns
## round only if the salvos landing on a simulated turn (the way the land
## allows) and run cost less than backing as far toward the goal. It leaves the axis only to bear loaded
## guns or tubes that would fire, by the least angle, and returns once they have.
## With shells in the air it takes the heading and throttle the fewest of them land on.

const ASPECT_STEP_DEG: float = 5.0
const ASPECTS: int = 37
static var _ASPECT_DEGS := PackedFloat64Array(range(ASPECTS).map(func(i): return i * ASPECT_STEP_DEG))
const RANGE_BUCKET_M: float = 250.0
## In range of us, but not shown to be aiming here (axis_now's unseen contacts).
const BYSTANDER_WEIGHT: float = 0.5
## An unspotted ship deduced to be spotting us is this much likelier than _switch_chance to be shooting at us.
const SPOTTER_TARGET_GAIN: float = 2.0
## An unspotted ship whose gunfire LKP is younger than this many reloads is still firing.
const GUNFIRE_ACTIVE_RELOADS: float = 1.5
## How far the route may pull the bow off the axis.
const AXIS_CONE: float = deg_to_rad(15.0)
## Bow-in and stern-in swap only when the other end is this much nearer.
const END_SWAP: float = deg_to_rad(20.0)
## Turning round and backing are each simulated until this far toward the goal, or this long.
const ESCAPE_M: float = 3000.0
const ESCAPE_MAX_S: float = 60.0
const ESCAPE_DT: float = 1.0
const ESCAPE_REPRICE_S: float = 1.0
## At full speed this share of what would land misses; slower, proportionally less.
const DODGE_AT_SPEED: float = 0.2
## Firing headings this close in turn are a tie, broken toward the route.
const SIDE_TIE: float = deg_to_rad(10.0)
## A request not fired by its turn plus this is dropped for a reload.
const FIRE_GRACE_S: float = 10.0
const TORP_RETRY_S: float = 10.0
const FIRE_RETRY_S: float = 5.0
## Land this close along a heading, in turning circles, leaves the helm to the navigator.
const CLEAR_AHEAD_TURNS: float = 1.5
const CLEAR_AHEAD_MIN_M: float = 800.0
const CLEAR_AHEAD_STEP_M: float = 100.0
const SHELL_QUERY_M: float = 1500.0
const SAIL_DT: float = 0.25
## Unseen, enemies this far past their gun range still set the axis: they are closing.
const AXIS_ADVANCE_M: float = 2000.0
## What a swing actually took over what it priced, by class (BB, CA, DD; CV as BB): GunneryCalibration
## probes over 50 12v12 matches, 2026-10-27. The veto weighs the swing at this.
const SWING_TAKEN := [0.70, 0.64, 0.53]
## Citadel box in shares of length and beam, when the hull has no citadel part.
const CITADEL_FALLBACK := Vector2(0.6, 0.5)

var _heading: float = 0.0
## Share of full ahead; -1 astern.
var _throttle: float = 1.0
var _active: bool = false
## Following the skill's route untouched.
var _on_route: bool = false
## Which end of the axis lies nearer the bow.
var _stern_in: bool = false
## Committed to turning round to the far end.
var _turning: bool = false
## Bearing of the weighted fire while under it, else INF (debug).
var _axis: float = INF
var _turn_cost: float = 0.0
## The cheaper turn's calibrated damage without the citadel weight: what it would take off our HP.
var _turn_hp: float = 0.0
var _astern_hp: float = 0.0
## Seconds the priced turn and astern runs take.
## The priced window (the turn's run) and the turn's exposed part (rudder lag and swing) in it.
var _window_s: float = 0.0
var _swing_s: float = 0.0
var _turn_track: Array = []
var _back_track: Array = []
var _vmax: float = 1.0
var _astern_cost: float = 0.0
var _priced_at: float = -INF
var _juke: bool = false
## &"", &"guns" or &"torps".
var _fire: StringName = &""
var _fire_deadline: float = INF
var _fire_cooldown: float = -INF
## Per shooter, range bucket -> [rows, raw, hit] over every aspect; a shooter's dropped when its _row_sig changes, or
## after TABLE_TTL_S.
var _store := StanceRows.new()
const TABLE_TTL_S: float = 30.0

## What a row's cells are built from, beyond range and aspect: our saturation and fires, the shooter's shell read, live
## guns, whether its tables are done, and before then our HP.
func _row_sig(shooter: Ship, read: int) -> int:
	var key := Vector2i(shooter.get_instance_id(), read)
	var c = _sig_cache.get(key)
	if c != null:
		return c
	var live := 0
	if shooter.artillery_controller != null:
		for g in shooter.artillery_controller.guns:
			live += int(not g.disabled)
	var ready: bool = BotGunnery.point_tables_ready(shooter, _me)
	# HP only moves the baked fallback the rows use before the shooter's point tables are built.
	var sig := hash([_me_live[0], read, live, ready, -1 if ready else _me_hpq])
	_sig_cache[key] = sig
	return sig

## _row_sig per (shooter id, read), cleared with each survey and redodge.
var _sig_cache: Dictionary = {}


var _me: Ship = null
var _clock: SalvoClock = null
## bearing, rows, weight, group (on, by, dark), spread (dark: believed-position radius), reload, next (seconds to its next landing).
var _shooters: Array[Dictionary] = []
## No gun reaches us now: the shooters are the ones land is stopping.
var _tucked := false
## Ship-local citadel footprint: x across, y along the bow.
var _citadel := Rect2()


var _did := PackedStringArray()

func apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	var t_all := Time.get_ticks_usec()
	_did.clear()
	_w = {"cells": 0, "fills": 0, "prices": 0, "incoming": 0, "parts": {}}
	var out := _apply(intent, ctx)
	var us := Time.get_ticks_usec() - t_all
	if us > 5000:
		BotTiming.add_us(StringName("spike:" + ",".join(_did)), us)
	if BotTiming.on and us > 3000:
		var groups := {"on": 0, "by": 0, "dark": 0}
		for sh in _shooters:
			groups[sh.group] += 1
		var ship := ctx.ship
		var arty = ship.artillery_controller
		var in_range := 0
		for b in ctx.server._team_belief(ship.team.team_id):
			if arty != null and Vector2(ship.global_position.x, ship.global_position.z).distance_to(b.pos) <= arty.get_params()._range:
				in_range += 1
		_w.merge({"ship": ship.ship_name, "class": Ship.ShipClass.keys()[ship.ship_class], "did": ",".join(_did),
			"shooters": groups, "torp_shooters": _torp_shooters.size(), "targets_in_range": in_range,
			"priorities": ctx.behavior.priorities.size(), "duel": _duel_name if is_finite(_duel_h) else "",
			"dodge_shells": _planner.shell_count() if _did.has("dodge") else 0, "hp": snappedf(ship.health_controller.current_hp / ship.health_controller.max_hp, 0.01)})
		BotTiming.worst(&"stance", us, _w)
	return out

## What the apply in progress did, for BotTiming.worst.
var _w: Dictionary = {}

func _part(name: String, t0: int) -> void:
	var p: Dictionary = _w.get("parts", {})
	p[name] = int(p.get(name, 0)) + Time.get_ticks_usec() - t0

func _apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	if intent == null or ctx.behavior.salvo_clock == null:
		reset()
		return intent
	var t0 := Time.get_ticks_usec()
	var threatened: bool = _survey(ctx)
	BotTiming.add(&"st_survey", t0)
	_part("survey", t0)
	var route: float = _route_bearing(intent, ctx)
	_route = route
	var hdg: float = ctx.behavior._get_ship_heading()
	if not threatened and not _quiet(ctx):
		reset()
		_base = {"off": true, "route": route, "ctx": ctx, "fields": _fields(intent)}
		return _dodge_off(intent, ctx, route, hdg)
	_active = true
	_throttle = 1.0
	_on_route = not threatened
	_axis = INF
	if threatened:
		t0 = Time.get_ticks_usec()
		_lie_on_axis(ctx, intent, route, hdg)
		BotTiming.add(&"st_lie", t0)
		_part("lie", t0)
		_to_cone(hdg)
		_on_route = _route_wins
		if _on_route:
			_throttle = 1.0
		t0 = Time.get_ticks_usec()
		_duel(ctx, hdg)
		BotTiming.add(&"st_duel", t0)
		_part("duel", t0)
		if is_finite(_duel_h):
			_on_route = false
		_setup(ctx, hdg)
	else:
		_duel_h = INF
		_duel_live = false
	t0 = Time.get_ticks_usec()
	var fire_h: float = INF if is_finite(_duel_h) or _set_up else _fire_heading(ctx, _heading if threatened and not _on_route else hdg, route, hdg)
	BotTiming.add(&"st_fire", t0)
	_part("fire", t0)
	if not is_finite(fire_h) and _fire == &"guns":
		_fire = &""
	var aimed := false
	if is_finite(fire_h) and not _in_cone(fire_h, maxf(_throttle, FIRE_HOLD_THROTTLE)):
		fire_h = INF
	if is_finite(fire_h) and _clear_ahead(ctx, fire_h, _throttle < 0.0):
		_heading = fire_h
		_on_route = false
		# The tubes bear: launching needs no way on.
		if _fire == &"torps" and _tubes_bear(ctx, hdg):
			_throttle = FIRE_HOLD_THROTTLE
			aimed = true
	elif threatened and not _clear_ahead(ctx, _heading, _throttle < 0.0):
		_on_route = true
	_base = {"off": false, "heading": _heading, "throttle": _throttle, "on_route": _on_route, "aimed": aimed, "ctx": ctx,
		"fields": _fields(intent)}
	t0 = Time.get_ticks_usec()
	var out := _dodge_tail(intent, ctx, hdg, aimed)
	BotTiming.add(&"st_tail", t0)
	_part("tail", t0)
	return out


## The intent fields apply writes after the dodge.
static func _fields(intent: NavIntent) -> Array:
	return [intent.target_heading, intent.heading_weight, intent.throttle_override, intent.force_reverse, intent.forbid_reverse]


## What apply left before its dodge, for redodge: {} while stance is off.
var _base: Dictionary = {}

## The dodge planned again over apply's last lie, for fresh shells between full updates; null with none to plan over.
func redodge() -> NavIntent:
	if _base.is_empty():
		return null
	var ctx: SkillContext = _base.ctx
	if ctx == null or not is_instance_valid(ctx.ship) or ctx.ship.team == null:
		return null
	var f: Array = _base.fields
	var intent := NavIntent.new()
	intent.target_heading = f[0]
	intent.heading_weight = f[1]
	intent.throttle_override = f[2]
	intent.force_reverse = f[3]
	intent.forbid_reverse = f[4]
	_refresh_me(ctx.ship)
	var hdg: float = ctx.behavior._get_ship_heading()
	if _base.off:
		return _dodge_off(intent, ctx, _base.route, hdg)
	_heading = _base.heading
	_throttle = _base.throttle
	_on_route = _base.on_route
	return _dodge_tail(intent, ctx, hdg, _base.aimed)


func _dodge_tail(intent: NavIntent, ctx: SkillContext, hdg: float, aimed: bool) -> NavIntent:
	_juke = _dodge(ctx)
	var o: PackedFloat64Array = _planner.tail(false, PackedFloat64Array([_heading, _throttle, float(_on_route), float(aimed),
		float(is_finite(_duel_h)), hdg, _route, PROGRESS_CONE, float(_turning), _turn_way, TURN_LEAD, float(_juke)]))
	return _apply_tail(intent, o)


## _planner.tail's answer into the stance and `intent`.
func _apply_tail(intent: NavIntent, o: PackedFloat64Array) -> NavIntent:
	_heading = o[0]
	_throttle = o[1]
	_on_route = o[2] != 0.0
	if o[3] == 0.0:
		return intent
	intent.target_heading = _heading
	intent.heading_weight = 1.0
	if o[4] >= 0.0:
		intent.throttle_override = int(o[4])
	intent.force_reverse = o[5] != 0.0
	intent.forbid_reverse = o[6] != 0.0
	return intent


## Highest forward throttle level (of 4) allowed.
func throttle_cap() -> int:
	return roundi(_throttle * 4.0) if _active and _throttle >= 0.0 else 4


## Torpedo launches wanted now: the hull is being turned to bear loaded tubes.
func wants_torpedoes() -> bool:
	return _active and _fire == &"torps"


## Held bow heading, and its length (throttle share); INF while following the route or off.
func debug_heading() -> Vector2:
	return Vector2(_heading, absf(_throttle)) if _active and not _on_route else Vector2(INF, 0.0)


## Bearing of the weighted fire as of the last tick; INF while not under it.
func threat_axis() -> float:
	return _axis


## Heading straight away from the fire; INF while not under it.
func debug_away() -> float:
	return wrapf(_axis + PI, -PI, PI) if is_finite(_axis) else INF


func debug_text() -> String:
	if not _active:
		return "Stance: off"
	var gear: String = "astern" if _throttle < 0.0 else "%d/4" % throttle_cap()
	var lie: String = "route" if _on_route else ("stern-in" if _stern_in != _turning else "bow-in") + _setup_tag()
	if is_finite(_duel_h):
		lie = "DUEL " + _duel_name + _setup_tag()
	return "Stance %s %.0f° %s%s%s%s%s | turn %.0f astern %.0f | %d guns on us" % [lie, rad_to_deg(_heading), gear,
		" TURNING" if _turning else "", "", " " + _fire if _fire != &"" else "", " DODGE %s %.1f>%.1f" % [_planner.kind(), _planner.cost().x, _planner.cost().y] if _juke else "",
		_turn_cost, _astern_cost, _shooters.size()]


func _setup_tag() -> String:
	return " SETUP %+.0f" % rad_to_deg(_setup_off) if _set_up else ""


func reset() -> void:
	_base = {}
	_duel_live = false
	_set_up = false
	_duel_h = INF
	_duel_then = INF
	_duel_until = -INF
	_axis = INF
	_active = false
	_on_route = false
	_route_wins = false
	_juke = false
	_turning = false
	_fire = &""
	_fire_deadline = INF


## Bow or stern on the fire axis: the end nearer the bow, ahead toward the goal;
## for a goal past the other end, turned round or backing, whichever costs less.
func _lie_on_axis(ctx: SkillContext, intent: NavIntent, route: float, hdg: float) -> void:
	var axis: float = _fire_axis(ctx)
	_axis = axis
	var goal: float = route
	if not is_finite(goal):
		var to: Vector3 = intent.target_position - ctx.ship.global_position
		if Vector2(to.x, to.z).length() > ctx.ship.movement_controller._p().turning_circle_radius:
			goal = atan2(to.x, to.z)
	var off_bow: float = absf(angle_difference(axis, hdg))
	var was: bool = _stern_in
	if _stern_in and off_bow < PI - off_bow - END_SWAP:
		_stern_in = false
	elif not _stern_in and PI - off_bow < off_bow - END_SWAP:
		_stern_in = true
	var near: float = wrapf(axis + PI, -PI, PI) if _stern_in else axis
	var far: float = wrapf(near + PI, -PI, PI)
	if _stern_in != was or not is_finite(goal) or cos(angle_difference(near, goal)) >= 0.0:
		_turning = false
	if not is_finite(goal):
		_heading = near
		_throttle = 0.25
		_route_or_lie(ctx, intent, hdg)
		return
	var end: float = near
	var astern: bool = false
	if cos(angle_difference(near, goal)) < 0.0:
		var to: Vector3 = intent.target_position - ctx.ship.global_position
		var cheaper := _turn_beats_astern(ctx, hdg, near, far, goal, Vector2(to.x, to.z).length())
		# A turn whose swing lands more than we have left is no way out, however it compares.
		var swing_hp: float = _turn_hp if DamageExpectation.learned() else _turn_hp * SWING_TAKEN[mini(ctx.ship.ship_class, 2)]
		_turning = (_turning or cheaper) and swing_hp < ctx.ship.health_controller.current_hp
		end = far if _turning else near
		astern = not _turning
		if SimClock.now() == _priced_at:
			if cheaper:
				GunneryCalibration.on_veto(ctx.ship, not _turning)
		if SimClock.now() == _priced_at and GunneryCalibration.can_open(ctx.ship):
			var track: Array = _turn_track if _turning else _back_track
			var split := _track_split(track, _vmax, ctx.ship.team.team_id, _window_s, _swing_s)
			split["learn"] = DamageExpectation.price(ctx.ship, "turn" if _turning else "astern", split.slices_on, split.slices_by,
				split.slices_dark, _window_s)
			GunneryCalibration.open_probe(ctx.ship, &"turn" if _turning else &"astern", split.on + split.by + split.dark,
				_window_s, _swing_s, split, _ids(&"on"), _ids(&"by"), _ids(&"dark"))
	var motion: float = wrapf(end + PI, -PI, PI) if astern else end
	_heading = wrapf(end + clampf(angle_difference(motion, goal), -AXIS_CONE, AXIS_CONE), -PI, PI)
	_throttle = -1.0 if astern else 1.0
	_route_or_lie(ctx, intent, hdg)
	# The navigator swings the short way to a heading: lead it round the way that was priced.
	var left: float = angle_difference(hdg, _heading)
	_lead_for = INF
	if _turning and not _route_wins and absf(left) > TURN_LEAD and signf(left) != _turn_way:
		_lead_for = _heading
		_heading = wrapf(hdg + _turn_way * TURN_LEAD, -PI, PI)


## Stance's lie against the route itself, sailed as the navigator would, both priced over the route's time to the
## destination (at least ROUTE_MIN_S): what lands, the lie's distance still to go charged as time at full speed.
## The route keeps the helm until the lie beats it by ROUTE_SWITCH, and the lie until the route does.
const ROUTE_MIN_S: float = 20.0
const ROUTE_SWITCH: float = 1.1
## Waypoints this near count as passed.
const ROUTE_WP_M: float = 150.0
const TURN_LEAD: float = PI / 2.0
var _route_wins: bool = false
var _route_track: Array = []
var _route_priced_at: float = -INF
## Which way the priced turn swings: +1 increasing heading.
var _turn_way: float = 1.0
## The heading a long-way turn is led round toward, while _heading holds only the lead; INF otherwise.
var _lead_for: float = INF

func _route_or_lie(ctx: SkillContext, intent: NavIntent, hdg: float) -> void:
	# Whether to leave a tuck is the route's planner's call, priced there; a lie would only stall it.
	if _tucked:
		_route_wins = true
		return
	var now: float = SimClock.now()
	if now - _route_priced_at < ESCAPE_REPRICE_S:
		return
	_route_priced_at = now
	var t_rl := Time.get_ticks_usec()
	_route_or_lie_priced(ctx, intent, hdg)
	BotTiming.add(&"st_route_lie", t_rl)
	_part("route_lie", t_rl)
	_did.append("rl")

func _route_or_lie_priced(ctx: SkillContext, intent: NavIntent, hdg: float) -> void:
	var mv = ctx.ship.movement_controller
	var p: MovementParams = mv._p()
	var vmax: float = maxf(mv.max_speed, 1.0)
	var dest := Vector2(intent.target_position.x, intent.target_position.z)
	_route_track = _sail_route(ctx, intent, hdg, vmax, p)
	var lie: Array = _turn_track if _turning else (_back_track if _throttle < 0.0 else _ahead_track(ctx, hdg, vmax, p))
	# A lie that runs aground is no lie.
	if _route_track.is_empty() or lie.is_empty():
		_route_wins = not _route_track.is_empty()
		return
	var window: float = clampf(_route_track.size() * ESCAPE_DT, ROUTE_MIN_S, ESCAPE_MAX_S)
	var team_id: int = ctx.ship.team.team_id
	var cost_r: float = _priced(ctx, "route", _held(_route_track, window), vmax, team_id, &"rows", window)
	var held_lie := _held(lie, window)
	var left: float = (held_lie[-1][0] as Vector2).distance_to(dest) - (_route_track[-1][0] as Vector2).distance_to(dest)
	var cost_l: float = _priced(ctx, "route", held_lie, vmax, team_id, &"rows", window) * (1.0 + maxf(left, 0.0) / vmax / window)
	_route_wins = cost_r * (1.0 if _route_wins else ROUTE_SWITCH) <= cost_l

## `track` cut or held at its last point, stopped, to `window_s`.
static func _held(track: Array, window_s: float) -> Array:
	var n: int = int(window_s / ESCAPE_DT)
	var out: Array = track.slice(0, n)
	while out.size() < n:
		out.append([out[-1][0], out[-1][1], 0.0])
	return out

## The navigator's path from its current waypoint to the destination, sailed at full speed (slowed in turns),
## the rudder answering after its lag at the turning rate.
func _sail_route(ctx: SkillContext, intent: NavIntent, hdg: float, vmax: float, p: MovementParams) -> Array:
	var pts := PackedVector2Array()
	var path: PackedVector3Array = ctx.navigator.get_current_path() if ctx.navigator != null else PackedVector3Array()
	var wp: Vector3 = ctx.navigator.get_current_waypoint() if ctx.navigator != null else intent.target_position
	var started := false
	for q in path:
		started = started or q.distance_to(wp) < 1.0
		if started:
			pts.append(Vector2(q.x, q.z))
	if pts.is_empty():
		pts.append(Vector2(intent.target_position.x, intent.target_position.z))
	if ctx.navigator == null:
		return []
	var start := Vector3(ctx.ship.global_position.x, ctx.ship.global_position.z, hdg)
	var tq := Time.get_ticks_usec()
	var paths: PackedVector3Array = StanceSim.route_path(ctx.navigator.get_debug_arc_inputs(), _hull_state(ctx.ship), pts,
		ROUTE_WP_M, ESCAPE_MAX_S, ESCAPE_DT)
	BotTiming.add(&"h_route_native", tq)
	tq = Time.get_ticks_usec()
	paths.insert(0, start)
	var tr := _as_track(paths, 0, paths.size())
	BotTiming.add(&"h_convert", tq)
	return tr

## The lie sailed ahead at its throttle: swinging onto _heading the short way, then on.
func _ahead_track(ctx: SkillContext, hdg: float, vmax: float, p: MovementParams) -> Array:
	var here := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	return _helm_cut(ctx, [[_heading, maxf(_throttle, 0.0), 0.0, INF, 0.0]], ESCAPE_MAX_S,
		[[here, Vector2.ZERO, INF, _heading, true]])[0][0]


## Per leg [heading, throttle, way (±1 round that way, 0 the short way), then, after_s], sailed on the navigator's hull
## from the hull as it is: [position, heading, speed] every ESCAPE_DT over `horizon`; empty without a navigator.
func _helm_tracks(ctx: SkillContext, legs: Array, horizon: float) -> Array:
	var flat := PackedFloat32Array()
	for l in legs:
		flat.append_array([l[0], _power(l[1]), l[2], l[3], l[4]])
	var paths := PackedVector3Array()
	var tq := Time.get_ticks_usec()
	if ctx.navigator != null:
		paths = StanceSim.helm_paths(ctx.navigator.get_debug_arc_inputs(), _hull_state(ctx.ship), flat, horizon, ESCAPE_DT)
	BotTiming.add(&"h_native", tq)
	tq = Time.get_ticks_usec()
	var m: int = int(horizon / ESCAPE_DT) + 1
	var out: Array = []
	for i in legs.size():
		out.append(_as_track(paths, i * m, m) if paths.size() >= (i + 1) * m else [])
	BotTiming.add(&"h_convert", tq)
	return out

## helm_paths / route_path points from `from`, `m` of them (the first the start), as [position, heading, speed].
static func _as_track(paths: PackedVector3Array, from: int, m: int) -> Array:
	var track: Array = []
	for k in range(1, m):
		var q: Vector3 = paths[from + k]
		var prev: Vector3 = paths[from + k - 1]
		track.append([Vector2(q.x, q.y), q.z, Vector2(q.x - prev.x, q.y - prev.y).length() / ESCAPE_DT])
	return track

## Legs as _helm_tracks, each ended by its `cuts` entry [start, goal dir, want, final, swung, then?, after_s?]: once
## `want` is made good along the goal dir (with `swung`, only after the bow is within 3° of `final`), empty when it runs
## aground within a turning circle and a half past that swing. Per leg [track, seconds the swing took].
func _helm_cut(ctx: SkillContext, legs: Array, horizon: float, cuts: Array) -> Array:
	var flat := PackedFloat32Array()
	for l in legs:
		flat.append_array([l[0], _power(l[1]), l[2], l[3], l[4]])
	var paths := PackedVector3Array()
	var tq := Time.get_ticks_usec()
	if ctx.navigator != null:
		paths = StanceSim.helm_paths(ctx.navigator.get_debug_arc_inputs(), _hull_state(ctx.ship), flat, horizon, ESCAPE_DT)
	BotTiming.add(&"h_native", tq)
	var m: int = int(horizon / ESCAPE_DT) + 1
	var p: MovementParams = ctx.ship.movement_controller._p()
	var reach: float = maxf(p.turning_circle_radius * CLEAR_AHEAD_TURNS, CLEAR_AHEAD_MIN_M)
	var clearance: float = ctx.behavior._get_ship_clearance()
	var map = NavigationMapManager.get_map()
	var out: Array = []
	for i in legs.size():
		if paths.size() < (i + 1) * m:
			out.append([[], 0.0])
			continue
		var c: Array = cuts[i]
		tq = Time.get_ticks_usec()
		var res: PackedFloat64Array = StanceSim.cut(paths, i * m, m, PackedFloat64Array([(c[0] as Vector2).x, (c[0] as Vector2).y,
			(c[1] as Vector2).x, (c[1] as Vector2).y, c[2], c[3], 1.0 if c[4] else 0.0, c[5] if c.size() > 5 else INF,
			c[6] if c.size() > 6 else 0.0, reach, clearance, ESCAPE_DT]), map)
		BotTiming.add(&"cut", tq)
		tq = Time.get_ticks_usec()
		out.append([_as_track(paths, i * m, int(res[0]) + 1) if res[0] >= 0.0 else [], res[1]])
		BotTiming.add(&"h_convert", tq)
	return out


## Turning round, either way the land leaves clear, run until as far toward the goal, against backing
## for as long, plus the time at full speed to make up the distance backing fell short: the salvos that
## land, in effective HP. _turn_hp is the swing's alone, unweighted.
func _turn_beats_astern(ctx: SkillContext, hdg: float, near: float, far: float, goal: float, dist: float) -> bool:
	var now: float = SimClock.now()
	if now - _priced_at < ESCAPE_REPRICE_S:
		return _turn_cost < _astern_cost
	_priced_at = now
	var t_ta := Time.get_ticks_usec()
	var r := _turn_beats_astern_priced(ctx, hdg, near, far, goal, dist, now)
	BotTiming.add(&"st_turn_astern", t_ta)
	_part("turn_astern", t_ta)
	_did.append("ta")
	return r

func _turn_beats_astern_priced(ctx: SkillContext, hdg: float, near: float, far: float, goal: float, dist: float, now: float) -> bool:
	var mv = ctx.ship.movement_controller
	var p: MovementParams = mv._p()
	var vmax: float = maxf(mv.max_speed, 1.0)
	var want: float = minf(dist, ESCAPE_M)
	var start := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var gdir := Vector2(sin(goal), cos(goal))
	var left: float = angle_difference(hdg, far)
	var short: float = signf(left) if left != 0.0 else 1.0
	_turn_cost = INF
	_turn_hp = INF
	_turn_track = []
	_vmax = vmax
	var team_id: int = ctx.ship.team.team_id
	var cuts := _helm_cut(ctx, [[far, 1.0, short, INF, 0.0], [far, 1.0, -short, INF, 0.0], [near, -1.0, 0.0, INF, 0.0]],
		ESCAPE_MAX_S, [[start, gdir, want, far, true], [start, gdir, want, far, true], [start, gdir, want, near, false]])
	for i in 2:
		var cut: Array = cuts[i]
		var track: Array = cut[0]
		if not track.is_empty():
			var both := _priced_with_raw(ctx, "turn", track, vmax, team_id, INF, cut[1])
			# Ended by the horizon short of `want`: the rest at full speed, as backing is charged.
			var made: float = ((track[-1][0] as Vector2) - start).dot(gdir)
			var cost: float = both[0] * (1.0 + maxf(want - made, 0.0) / vmax / (track.size() * ESCAPE_DT))
			if cost < _turn_cost:
				_turn_cost = cost
				_turn_way = short if i == 0 else -short
				_swing_s = cut[1]
				_turn_hp = _raw_price(ctx, "turn", track, both[1], _swing_s)
				_turn_track = track
	var back: Array = cuts[2][0]
	_back_track = back
	_window_s = _turn_track.size() * ESCAPE_DT if not _turn_track.is_empty() else back.size() * ESCAPE_DT
	if _turn_track.is_empty():
		_swing_s = 0.0
	_astern_cost = INF
	_astern_hp = INF
	if not back.is_empty():
		# Same window as the turn; what backing has not covered by its end is sailed on at this rate.
		var both := _priced_with_raw(ctx, "astern", back, vmax, team_id, _window_s, _window_s)
		_astern_cost = both[0]
		_astern_hp = _raw_price(ctx, "astern", back, both[1], _window_s)
		var k: int = mini(int(_window_s / ESCAPE_DT), back.size()) - 1
		var made: float = (back[k][0] as Vector2 - start).dot(Vector2(sin(goal), cos(goal))) if k >= 0 else 0.0
		var short_s: float = maxf(want - made, 0.0) / vmax
		if _window_s > 0.0:
			_astern_cost *= 1.0 + short_s / _window_s
	return _turn_cost < _astern_cost


## Whole salvos landing along `track`, each on its shooter's clock: at the hull's
## aspect to it then, nothing once out of its range or behind land from it, less what speed dodges.
## Unweighted salvos landing along `track` (each on its shooter's clock, at the hull's aspect to it, none once out of
## its range or behind land, less what speed dodges) in the first `window_s`, split by who it is booked to: {on (shooters
## on us), by (bystanders), dark (unspotted), early (all, landing in the first `early_s`), slices_on / _by / _dark (per
## DamageExpectation.TURNOUT_SLICES_S)}; for GunneryCalibration's probes.
func _track_split(track: Array, vmax: float, team_id: int, window_s: float, early_s: float) -> Dictionary:
	var slices: Array = DamageExpectation.TURNOUT_SLICES_S
	var out := {"on": 0.0, "by": 0.0, "dark": 0.0, "early": 0.0, "slices_on": [], "slices_by": [], "slices_dark": []}
	for i in slices.size():
		out.slices_on.append(0.0)
		out.slices_by.append(0.0)
		out.slices_dark.append(0.0)
	if track.is_empty():
		return out
	var end: float = minf(track.size() * ESCAPE_DT, window_s)
	var field: ReachField = NavigationMapManager.get_reach_field()
	for sh in _shooters:
		var t: float = float(sh.next)
		while t < end:
			var k: int = clampi(int(t / ESCAPE_DT), 0, track.size() - 1)
			var at: Vector2 = track[k][0]
			var to: Vector2 = sh.pos - at
			var bit: int = int(sh.bit)
			var shadowed: bool = bit >= 0 and field != null and field.exposure_mask(team_id, at) & (1 << bit) == 0
			var reach: float = _reach_share(sh, to.length())
			if reach > 0.0 and not shadowed:
				var a: int = clampi(roundi(rad_to_deg(absf(angle_difference(float(track[k][1]), atan2(to.x, to.y)))) / ASPECT_STEP_DEG), 0, ASPECTS - 1)
				var row := _row_at(sh, to.length(), &"raw")
				var d: float = float(sh.reload) * float(sh.weight) * reach * (row[a] if not row.is_empty() else 0.0) \
					* (1.0 - DODGE_AT_SPEED * float(track[k][2]) / vmax)
				var g: String = sh.group
				out[g] += d
				var si: int = 0
				while si < slices.size() - 1 and t >= slices[si]:
					si += 1
				out["slices_" + g][si] += d
				if t < early_s:
					out.early += d
			t += float(sh.reload)
	return out


## `kind`'s salvos along `track` in `window_s`, sliced and priced by DamageExpectation (learned turn-outs).
func _priced(ctx: SkillContext, kind: String, track: Array, vmax: float, team_id: int, rows: StringName, window_s: float,
		stops: Dictionary = {}, skip_s: float = 0.0) -> float:
	var r := _track_native(track, vmax, team_id, rows, window_s, stops, skip_s)
	var s: Array = _split_slices(r.slices)
	var torps: float = float(r.torps) if rows == &"rows" else 0.0
	BotTiming.add_us(&"de_price_n", 1)
	return DamageExpectation.price(ctx.ship, kind, s[0], s[1], s[2], minf(window_s, track.size() * ESCAPE_DT)) + torps


## _priced in rows over `window_s`, with the raw salvos over `raw_s` from the same pass: [cost, raw [on, by, dark]].
func _priced_with_raw(ctx: SkillContext, kind: String, track: Array, vmax: float, team_id: int, window_s: float,
		raw_s: float) -> Array:
	var r := _track_native(track, vmax, team_id, &"rows", window_s, {}, 0.0, raw_s)
	var s: Array = _split_slices(r.slices)
	var tq := Time.get_ticks_usec()
	var c: float = DamageExpectation.price(ctx.ship, kind, s[0], s[1], s[2], minf(window_s, track.size() * ESCAPE_DT)) + float(r.torps)
	BotTiming.add(&"de_price", tq)
	return [c, _split_slices(r.slices2)]

## _priced_with_raw's raw salvos priced as `kind` over `raw_s`.
static func _raw_price(ctx: SkillContext, kind: String, track: Array, raw: Array, raw_s: float) -> float:
	return DamageExpectation.price(ctx.ship, kind, raw[0], raw[1], raw[2], minf(raw_s, track.size() * ESCAPE_DT))


## [on, by, dark]: `rows` salvos along `track` (as _track_split) per DamageExpectation.TURNOUT_SLICES_S slice, from
## shooters on us, bystanders and unspotted enemies.
func _track_slices(track: Array, vmax: float, team_id: int, rows: StringName, window_s: float, stops: Dictionary = {},
		skip_s: float = 0.0) -> Array:
	return _split_slices(_track_native(track, vmax, team_id, rows, window_s, stops, skip_s).slices)


static func _split_slices(flat: PackedFloat64Array) -> Array:
	var n: int = DamageExpectation.TURNOUT_SLICES_S.size()
	return [flat.slice(0, n), flat.slice(n, 2 * n), flat.slice(2 * n, 3 * n)]


const _GROUP_INDEX := {&"on": 0, &"by": 1, &"dark": 2}
const _MISSING_ROUNDS: int = 8

## StanceSim.track_price over `track`, the rows it reaches filled as _row_at would.
func _track_native(track: Array, vmax: float, team_id: int, rows: StringName, window_s: float, stops: Dictionary,
		skip_s: float, raw_s: float = NAN) -> Dictionary:
	var tq := Time.get_ticks_usec()
	var flat := _pack_track(track)
	BotTiming.add(&"pack_track", tq)
	tq = Time.get_ticks_usec()
	var cfg := _price_cfg(vmax, team_id, rows, window_s, stops, skip_s)
	BotTiming.add(&"q_cfg", tq)
	if not is_nan(raw_s):
		cfg["kind2"] = _rows_index(&"raw")
		cfg["window2"] = raw_s
	tq = Time.get_ticks_usec()
	var r: Dictionary = StanceSim.track_price(flat, cfg)
	BotTiming.add(&"q_price_native", tq)
	var rounds := 0
	for i in _MISSING_ROUNDS:
		if (r.missing as PackedFloat64Array).is_empty():
			break
		rounds += 1
		BotTiming.add_us(&"q_missing_n", (r.missing as PackedFloat64Array).size() / 3)
		tq = Time.get_ticks_usec()
		_fill_rows(r.missing)
		BotTiming.add(&"q_fill", tq)
		_w["fills"] = int(_w.get("fills", 0)) + 1
		tq = Time.get_ticks_usec()
		r = StanceSim.track_price(flat, cfg)
		BotTiming.add(&"q_price_native", tq)
	BotTiming.add_us(&"q_rounds", rounds)
	_w["prices"] = int(_w.get("prices", 0)) + 1
	return r


static func _pack_track(track: Array) -> PackedFloat64Array:
	var flat := PackedFloat64Array()
	flat.resize(track.size() * 4)
	for k in track.size():
		var q: Array = track[k]
		flat[4 * k] = (q[0] as Vector2).x
		flat[4 * k + 1] = (q[0] as Vector2).y
		flat[4 * k + 2] = q[1]
		flat[4 * k + 3] = q[2]
	return flat


func _price_cfg(vmax: float, team_id: int, rows: StringName, window_s: float, stops: Dictionary, skip_s: float) -> Dictionary:
	var sh := PackedFloat64Array()
	var ids := PackedInt64Array()
	for s in _shooters:
		sh.append_array([(s.pos as Vector2).x, (s.pos as Vector2).y, s.weight, _GROUP_INDEX[s.group], s.bit, s.spread, s.range,
			s.reload, s.next, float(stops.get(s.id, INF))])
		ids.append(s.id)
	return {"shooters": sh, "store": _store, "ids": ids, "kind": _rows_index(rows), "pm": BotGunnery._projectile_native(),
		"slices": PackedFloat64Array(DamageExpectation.TURNOUT_SLICES_S), "vmax": vmax,
		"at_speed": DODGE_AT_SPEED, "team": team_id, "field": NavigationMapManager.get_reach_field(), "window": window_s,
		"skip": skip_s, "dt": ESCAPE_DT, "aspects": ASPECTS, "aspect_step": ASPECT_STEP_DEG, "bucket_m": RANGE_BUCKET_M,
		"torps": _torp_pack, "torp_hull": _torp_hull}


static func _rows_index(rows: StringName) -> int:
	return 0 if rows == &"rows" else 2 if rows == &"hit" else 1


## The row buckets track_price reported missing ([shooter, range, aspect] triples), built as _row_at builds them.
func _fill_rows(missing: PackedFloat64Array) -> void:
	var cells := {}
	for j in range(0, missing.size(), 3):
		var i: int = int(missing[j])
		var sh: Dictionary = _shooters[i]
		var r: float = missing[j + 1]
		if _me != null and is_instance_valid(sh.ship):
			var key: int = i * 1000000 + int(r / RANGE_BUCKET_M)
			if not cells.has(key):
				cells[key] = [sh.ship, r, []]
			(cells[key][2] as Array).append(int(missing[j + 2]))
		else:
			_store.copy_bucket(sh.id, int(sh.bucket), int(r / RANGE_BUCKET_M))
	for c in cells.values():
		_ensure(_me, c[0], c[1], PackedInt32Array(c[2]))


## Share of `sh`'s believed positions from which it reaches `dist` away: all or none for a gun we see.
static func _reach_share(sh: Dictionary, dist: float) -> float:
	var r: float = sh.spread
	if r <= 0.0:
		return 1.0 if dist <= float(sh.range) else 0.0
	return clampf((float(sh.range) - dist + r) / (2.0 * r), 0.0, 1.0)


func _ids(group: StringName) -> Array:
	return _shooters.filter(func(sh): return sh.group == group).map(func(sh): return sh.id)



## The heading to bear loaded tubes, else loaded guns idle at `base`; INF when
## there is nothing to fire. A request that cannot fire in time is dropped.
func _fire_heading(ctx: SkillContext, base: float, route: float, hdg: float) -> float:
	var now: float = SimClock.now()
	if now < _fire_cooldown:
		_fire = &""
		return INF
	var want: StringName = &"torps"
	var h: float = _tube_heading(ctx, base, route, hdg)
	if not is_finite(h) and not _duel_live:
		want = &"guns"
		h = _gun_heading(ctx, base, route, hdg)
	if not is_finite(h):
		_fire = &""
		return INF
	if want != _fire:
		_fire = want
		_fire_deadline = now + _turn_s(ctx, absf(angle_difference(hdg, h))) + FIRE_GRACE_S
	elif now > _fire_deadline:
		_fire_cooldown = now + (FIRE_RETRY_S if want == &"guns" else TORP_RETRY_S)
		_fire = &""
		return INF
	if _sails_into_sight(ctx, h, _fire_deadline - now):
		_fire_cooldown = now + (FIRE_RETRY_S if want == &"guns" else TORP_RETRY_S)
		_fire = &""
		return INF
	return h


## Unseen, sailing `h` at full speed for `secs` would bring us inside an enemy's sight of us we are now outside.
const SIGHT_MARGIN_M: float = 300.0

func _sails_into_sight(ctx: SkillContext, h: float, secs: float) -> bool:
	var ship: Ship = ctx.ship
	if ship.is_detected() or ship.team == null or ctx.server == null or secs <= 0.0:
		return false
	var seen: float = NavigationMapManager.reach_conceal_radius(ship) + SIGHT_MARGIN_M
	var a := Vector2(ship.global_position.x, ship.global_position.z)
	var b: Vector2 = a + Vector2(sin(h), cos(h)) * ship.movement_controller.max_speed * secs
	for e in ctx.server._team_belief(ship.team.team_id):
		var p: Vector2 = e.pos
		if a.distance_to(p) > seen and Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) <= seen:
			return true
	return false


func _tube_heading(ctx: SkillContext, base: float, route: float, hdg: float) -> float:
	if not ctx.behavior.would_fire_torpedoes():
		return INF
	var loaded := _loaded_tubes(ctx)
	if loaded.is_empty():
		return INF
	var aim: Vector3 = ctx.behavior.torpedo_target_position
	return _nearest(loaded, Vector2(aim.x, aim.z), base, route, hdg, false)


## Of the two least turns off `base` that bear every gun, the one whose guns idle at `base` fire soonest, the hull sailed
## and the turrets slewed from where they lie; only when they fire and the bow is back on `base` before the target's
## next salvo lands. Repriced every ESCAPE_REPRICE_S.
const GUN_PRICE_S: float = 60.0
var _gun_priced_at: float = -INF
var _gun_h: float = INF

func _gun_heading(ctx: SkillContext, base: float, route: float, hdg: float) -> float:
	var t: Ship = ctx.target
	var arty = ctx.ship.artillery_controller
	if t == null or not is_instance_valid(t) or not t.is_alive() or arty == null or not _guns_free(ctx):
		return INF
	var gp: GunParams = arty.get_params()
	if ctx.ship.global_position.distance_to(t.global_position) > gp._range:
		return INF
	var now: float = SimClock.now()
	if now - _gun_priced_at < ESCAPE_REPRICE_S:
		return _gun_h
	_gun_priced_at = now
	var pick := _gun_pick(ctx, t, arty, gp, base, hdg)
	_gun_h = INF
	if is_finite(pick.y) and pick.y + _turn_s(ctx, absf(angle_difference(pick.x, base))) <= ctx.behavior.salvo_clock.next_landing(t, now):
		_gun_h = pick.x
	return _gun_h

## (heading, seconds until the guns idle at `base` have all fired there); INF seconds with none idle or none to fire.
func _gun_pick(ctx: SkillContext, t: Ship, arty, gp: GunParams, base: float, hdg: float) -> Vector2:
	var at := Vector2(t.global_position.x, t.global_position.z)
	var hs: PackedFloat32Array = StanceSim.nearest_bearing(arty.guns, at, hdg, base, true)
	if hs.is_empty():
		return Vector2(INF, INF)
	var bearing: PackedByteArray = StanceSim.bearing_mask(arty.guns, at, hdg, base)
	var idle: Array = []
	for i in arty.guns.size():
		if not arty.guns[i].disabled and bearing[i] == 0:
			idle.append(i)
	if idle.is_empty():
		return Vector2(INF, INF)
	var t_gp := Time.get_ticks_usec()
	var throttle: float = _throttle if _throttle > 0.0 else 1.0
	var sailed := _helm_tracks(ctx, [[hs[0], throttle, 0.0, INF, 0.0], [hs[1], throttle, 0.0, INF, 0.0]], GUN_PRICE_S)
	var at0 := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var tv := Vector2(t.linear_velocity.x, t.linear_velocity.z)
	var best := INF
	var best_s := INF
	for c in 2:
		var track: Array = sailed[c]
		if track.is_empty():
			continue
		var pos := PackedVector2Array()
		var hdgs := PackedFloat32Array()
		var tpos := PackedVector2Array()
		for k in track.size():
			pos.append(track[k][0])
			hdgs.append(float(track[k][1]))
			tpos.append(at + tv * (k + 1) * ESCAPE_DT)
		var masks: PackedInt64Array = StanceSim.track_bearing(arty.guns, at0, hdg, pos, hdgs, tpos, gp.traverse_speed, ESCAPE_DT)
		var fire_s := 0.0
		for i in idle:
			var trained := INF
			for k in masks.size():
				if masks[k] & (1 << i) != 0:
					trained = (k + 1) * ESCAPE_DT
					break
			fire_s = maxf(fire_s, maxf(trained, (1.0 - clampf(arty.guns[i].reload, 0.0, 1.0)) * gp.reload_time))
		# Reload alone can tie the sides: then the smaller swing of the hull.
		if fire_s < best_s - ESCAPE_DT or (fire_s <= best_s + ESCAPE_DT and is_finite(best)
				and absf(angle_difference(hdg, hs[c])) < absf(angle_difference(hdg, best))):
			best_s = minf(fire_s, best_s)
			best = hs[c]
	BotTiming.add(&"st_gun_pick", t_gp)
	_part("gun_pick", t_gp)
	_did.append("gun")
	return Vector2(best, best_s)


## Of the least turns each way off `base` that bear the mounts, the smaller; near
## ties go to the side nearer the route (else the bow now).
func _nearest(mounts: Array, at: Vector2, base: float, route: float, hdg: float, all: bool) -> float:
	var hs: PackedFloat32Array = StanceSim.nearest_bearing(mounts, at, hdg, base, all)
	if hs.is_empty():
		return INF
	var da: float = absf(angle_difference(base, hs[0]))
	var db: float = absf(angle_difference(base, hs[1]))
	if absf(da - db) > SIDE_TIE:
		return hs[0] if da < db else hs[1]
	var ref: float = route if is_finite(route) else hdg
	return hs[0] if absf(angle_difference(hs[0], ref)) <= absf(angle_difference(hs[1], ref)) else hs[1]


## No land within the hull's clearance along `h` (astern: its reciprocal) for a turning circle and a half.
func _clear_ahead(ctx: SkillContext, h: float, astern: bool) -> bool:
	var ship: Ship = ctx.ship
	var clearance: float = ctx.behavior._get_ship_clearance()
	var reach: float = maxf(ship.movement_controller._p().turning_circle_radius * CLEAR_AHEAD_TURNS, CLEAR_AHEAD_MIN_M)
	var dir := Vector3(sin(h), 0.0, cos(h)) * (-1.0 if astern else 1.0)
	var d: float = clearance
	while d <= reach:
		if NavigationMapManager.get_distance(ship.global_position + dir * d) < clearance:
			return false
		d += maxf(clearance, CLEAR_AHEAD_STEP_M)
	return true


func _turn_s(ctx: SkillContext, angle: float) -> float:
	var mv = ctx.ship.movement_controller
	var p: MovementParams = mv._p()
	var v: float = maxf(ctx.ship.linear_velocity.length(), mv.max_speed * 0.5)
	return angle * p.turning_circle_radius / maxf(v, 1.0) + p.rudder_response_time


## Bearing of the weighted incoming fire, else of the target; INF with neither.
func _fire_axis(ctx: SkillContext) -> float:
	var v := Vector2.ZERO
	for sh in _shooters:
		if sh.group != &"dark":
			v += Vector2(sin(float(sh.bearing)), cos(float(sh.bearing))) * float(sh.weight) * float(sh.threat)
	if v.length_squared() < 1e-6:
		var t: Ship = ctx.target
		if t == null or not is_instance_valid(t):
			return ctx.behavior._get_ship_heading()
		var to: Vector3 = t.global_position - ctx.ship.global_position
		return atan2(to.x, to.z)
	return atan2(v.x, v.y)


## Stance off: the route's heading at full ahead is the lie the dodge leaves only for shells in the air.
func _dodge_off(intent: NavIntent, ctx: SkillContext, route: float, hdg: float) -> NavIntent:
	_heading = route if is_finite(route) else hdg
	_throttle = 1.0
	if not _dodge(ctx):
		return intent
	_active = true
	_juke = true
	return _apply_tail(intent, _planner.tail(true, PackedFloat64Array([_heading, _throttle, float(_on_route), 0.0, 0.0, hdg,
		_route, PROGRESS_CONE, float(_turning), _turn_way, TURN_LEAD, 1.0])))


## A citadel shell counts this many hull shells more; a shell weighs its caliber cubed over this one's.
const DODGE_CIT_W: float = 3.0
const DODGE_REF_CAL: float = 300.0
## Hull freeboard times this: the superstructure a falling shell can strike.
const DODGE_TOP: float = 2.0
## Shells per radian off the lie's heading and per full throttle off its throttle: the lie wins ties.
const DODGE_OFF_W: float = 0.3
const DODGE_GEAR_W: float = 0.2
## The dodge takes the helm only when it saves this many shells over the lie.
const DODGE_MIN_GAIN: float = 0.5
const DODGE_LAND_STEP: int = 4
## The salvos still to come are priced this long past the shells in the air, as turn and astern are.
const DODGE_PRICE_S: float = 20.0

## Whether an enemy shell lands near `ship` that the last dodge plan did not see.
func shells_fresh(ship: Ship) -> bool:
	return _planner.fresh(BotGunnery._projectile_native(), Vector2(ship.global_position.x, ship.global_position.z),
		SHELL_QUERY_M, ship.team.team_id, SimClock.now())

var _planner := DodgePlanner.new()

## The heading and throttle, held until its shells land, that the fewest enemy shells in the air hit; re-planned as new
## shells are fired. False when the lie does as well.
func _dodge(ctx: SkillContext) -> bool:
	var ship: Ship = ctx.ship
	var pm: Object = BotGunnery._projectile_native()
	var at := Vector2(ship.global_position.x, ship.global_position.z)
	var state: int = _planner.check(pm, at, SHELL_QUERY_M, ship.team.team_id, SimClock.now())
	if state < 2 or ctx.navigator == null:
		return state == 1
	var t_dg := Time.get_ticks_usec()
	var out := _dodge_plan(ctx, ship, at)
	BotTiming.add(&"st_dodge_plan", t_dg)
	_part("dodge_plan", t_dg)
	_did.append("dodge")
	return out

func _dodge_plan(ctx: SkillContext, ship: Ship, at: Vector2) -> bool:
	var tp := Time.get_ticks_usec()
	for sh in _shooters:
		if is_instance_valid(sh.ship):
			var read: int = _clock.shell_read(sh.ship) if _clock != null else SalvoClock.SHELL_UNKNOWN
			if _store.validate(sh.id, _row_sig(sh.ship, read), SimClock.now(), TABLE_TTL_S) > 0:
				_store.set_live(sh.id, _me_live[1], _me_live[2], read)
	var cfg := _price_cfg(maxf(ship.movement_controller.max_speed, 1.0), ship.team.team_id, &"rows", 0.0, {}, 0.0)
	var bearings := PackedFloat64Array()
	var cals := PackedFloat64Array()
	var dmgs := PackedFloat64Array()
	for sh in _shooters:
		var ok: bool = is_instance_valid(sh.ship)
		bearings.append(float(sh.bearing) if ok else NAN)
		var p: ShellParams = sh.ship.artillery_controller.guns[0].get_shell() if ok and not sh.ship.artillery_controller.guns.is_empty() else null
		cals.append(p.caliber if p != null else NAN)
		dmgs.append(p.damage if p != null else 0.0)
	cfg.merge({"params": ctx.navigator.get_debug_arc_inputs(), "state": _hull_state(ship), "hull": _hull_box(ship),
		"cit": _citadel_box(ship), "top": (ship.movement_controller.ship_height - ship.movement_controller.ship_draft) * DODGE_TOP,
		"ref_cal": DODGE_REF_CAL, "cit_w": DODGE_CIT_W, "heading": _heading, "throttle": _throttle, "off_w": DODGE_OFF_W,
		"gear_w": DODGE_GEAR_W, "min_gain": DODGE_MIN_GAIN, "route": _route, "cone": PROGRESS_CONE,
		"map": NavigationMapManager.get_map(), "clearance": ctx.behavior._get_ship_clearance(), "at": at,
		"bearings": bearings, "shell_cal": cals, "shell_dmg": dmgs, "source_match": SalvoClock.SOURCE_MATCH,
		"price_s": DODGE_PRICE_S, "coef_full": _price_coef(ship, "dodge")}, true)
	BotTiming.add(&"dp_cfg", tp)
	tp = Time.get_ticks_usec()
	var r := {}
	for i in _MISSING_ROUNDS + 1:
		r = _planner.plan(cfg, i == _MISSING_ROUNDS)
		if r.is_empty() or r.has("picked"):
			break
		if not (r.get("missing_hit", PackedFloat64Array()) as PackedFloat64Array).is_empty():
			_fill_rows(r.missing_hit)
		if not (r.missing as PackedFloat64Array).is_empty():
			_fill_rows(r.missing)
	BotTiming.add(&"dp_plan", tp)
	if r.is_empty():
		return false
	var out: bool = is_finite(_planner.heading())
	_dodge_why(ctx, "dodge" if out else "dodge_lie")
	return out

## DamageExpectation.price as per-slice [on, by, dark, constant] weights; DodgePlanner scales the constant to its window.
static func _price_coef(ship: Ship, kind: String) -> PackedFloat64Array:
	var f := DamageExpectation.turnout(ship, kind)
	var out := PackedFloat64Array()
	for i in DamageExpectation.TURNOUT_SLICES_S.size():
		if f.is_empty():
			out.append_array([1.0, 1.0, DamageExpectation.DARK_TAKEN[mini(ship.ship_class, 2)], 0.0])
		else:
			out.append_array([f[0][i], f[1][i], f[2][i], float(f[3][i])])
	return out


## Stance and duel only choose how to lie while making way toward the next waypoint: the motion they order stays
## within PROGRESS_CONE of its bearing (_route; INF, no route: free), and stopping is for when there is nowhere to go.
const PROGRESS_CONE: float = deg_to_rad(45.0)
## Way kept on while launching with the tubes already bearing.
const FIRE_HOLD_THROTTLE: float = 0.25
var _route: float = INF

## Whether `h` at `throttle` makes way inside the cone.
func _in_cone(h: float, throttle: float) -> bool:
	if not is_finite(_route):
		return true
	if throttle == 0.0:
		return false
	var motion: float = h if throttle > 0.0 else wrapf(h + PI, -PI, PI)
	return absf(angle_difference(_route, motion)) <= PROGRESS_CONE + 1e-4

## `h` (sailed ahead) moved to the nearest heading inside the cone.
func _cone_heading(h: float) -> float:
	if not is_finite(_route):
		return h
	return wrapf(_route + clampf(angle_difference(_route, h), -PROGRESS_CONE, PROGRESS_CONE), -PI, PI)

## The held _heading/_throttle brought inside the cone: astern only backing into it, a stop made way ahead; a turn
## round to it led the way it was priced.
func _to_cone(hdg: float) -> void:
	if not is_finite(_route) or _in_cone(_heading, _throttle):
		return
	if _throttle < 0.0:
		# Backing is way made only with the stern already toward the goal; else ahead.
		if absf(angle_difference(_route, wrapf(hdg + PI, -PI, PI))) <= PI / 2.0:
			_heading = wrapf(_cone_heading(wrapf(_heading + PI, -PI, PI)) + PI, -PI, PI)
			return
		_throttle = 1.0
	if _throttle == 0.0:
		_throttle = 1.0
	_heading = _cone_heading(_heading)
	var left: float = angle_difference(hdg, _heading)
	if _turning and absf(left) > TURN_LEAD and signf(left) != _turn_way:
		_heading = wrapf(hdg + _turn_way * TURN_LEAD, -PI, PI)


func _tubes_bear(ctx: SkillContext, hdg: float) -> bool:
	var aim: Vector3 = ctx.behavior.torpedo_target_position
	return StanceSim.bearing_mask(_loaded_tubes(ctx), Vector2(aim.x, aim.z), hdg, hdg).has(1)



## Enemies whose tubes could reach us, not seen launching within a reload: what one spread of theirs is made of.
var _torp_shooters: Array[Dictionary] = []

func _torp_survey(ctx: SkillContext) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ship: Ship = ctx.ship
	if ship.team == null or ctx.server == null:
		return out
	var at := Vector2(ship.global_position.x, ship.global_position.z)
	var now: float = SimClock.now()
	for b in ctx.server._team_belief(ship.team.team_id):
		var e: Ship = b.ship
		if not is_instance_valid(e) or not e.is_alive() or not is_instance_valid(e.torpedo_controller):
			continue
		var tc: TorpedoController = e.torpedo_controller
		if tc.launchers.is_empty() or tc.get_params() == null:
			continue
		if (b.pos as Vector2).distance_to(at) - float(b.spread) > tc.get_max_range() + ESCAPE_M:
			continue
		if now - float(ctx.behavior.torps_launched_at.get(e, -INF)) < tc.get_params().reload_time:
			continue
		var tp: TorpedoParams = tc.get_torp_params()
		var fan := 0
		for l in tc.launchers:
			fan = maxi(fan, l.muzzles.size())
		out.append({"pos": b.pos, "range": tc.get_max_range(), "dmg": tp.damage, "fan": fan, "det": tp.detection_range,
			"vt": maxf(tp.speed * _TorpedoManager.TORPEDO_SPEED_MULTIPLIER, 1.0), "bear": BotBehavior.torp_bear_s(e)})
	return out


var _torp_pack := PackedFloat64Array()
var _torp_hull := PackedFloat64Array()

## _torp_shooters and our hull as StanceSim reads them for _track_torps.
func _pack_torps(ship: Ship) -> void:
	_torp_pack = PackedFloat64Array()
	for sh in _torp_shooters:
		_torp_pack.append_array([(sh.pos as Vector2).x, (sh.pos as Vector2).y, sh.range, sh.fan, sh.dmg, sh.vt, sh.det, sh.bear])
	var mc = ship.movement_controller
	var p: MovementParams = mc._p()
	var reach: float = sqrt(2.0 * p.turning_circle_radius * mc.ship_length)
	_torp_hull = PackedFloat64Array([mc.ship_length, mc.ship_beam, reach,
		maxf(BotBehavior.TORP_COURSE_SHIFTS * reach / maxf(mc.max_speed, 1.0), 1.0), p.rudder_response_time,
		BotBehavior.TORP_LANE_RAD, BotBehavior.TORP_DODGE_KEEP])


## Per step of `track` (to `window_s`): HP from enemy spreads, BotBehavior.torpedo_curve's lanes at the hull shown,
## stepped aside from at its speed then; each shooter's spread arrives within its bear and run, one spread at most.
func _track_torps(track: Array, window_s: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(track.size())
	if _torp_shooters.is_empty() or _me == null:
		return out
	var mc = _me.movement_controller
	var p: MovementParams = mc._p()
	var reach: float = sqrt(2.0 * p.turning_circle_radius * mc.ship_length)
	var habit: float = maxf(BotBehavior.TORP_COURSE_SHIFTS * reach / maxf(mc.max_speed, 1.0), 1.0)
	var n: int = mini(track.size(), int(window_s / ESCAPE_DT))
	for sh in _torp_shooters:
		var got := 0.0
		var cap := 0.0
		for k in n:
			var to: Vector2 = (sh.pos as Vector2) - (track[k][0] as Vector2)
			var d: float = to.length()
			if d > float(sh.range) or d < 1.0:
				continue
			var a: float = angle_difference(float(track[k][1]), atan2(to.x, to.y))
			var width: float = mc.ship_length * absf(sin(a)) + mc.ship_beam
			var hits: float = minf(float(sh.fan), 1.0 + width / (d * BotBehavior.TORP_LANE_RAD))
			var run: float = d / float(sh.vt)
			var warn: float = minf(d, float(sh.det)) / float(sh.vt)
			var shift: float = reach / maxf(float(track[k][2]), 1.0)
			var react: float = clampf((warn - p.rudder_response_time) / maxf(shift, 0.1), 0.0, 1.0)
			var spread: float = hits * float(sh.dmg) * lerpf(1.0, BotBehavior.TORP_DODGE_KEEP, react) * exp(-run / habit)
			cap = maxf(cap, spread)
			var v: float = minf(spread * ESCAPE_DT / (float(sh.bear) + run), maxf(cap - got, 0.0))
			got += v
			out[k] += v
	return out


## A stance throttle as the hull's engine power: astern is the navigator's half power astern.
static func _power(throttle: float) -> float:
	return -0.5 if throttle < 0.0 else throttle

## [x, z, vx, vz, heading, yaw rate, rudder, power], as StanceSim's hull starts from.
func _hull_state(ship: Ship) -> PackedFloat32Array:
	var mv = ship.movement_controller
	var f: Vector3 = -ship.global_transform.basis.z
	return PackedFloat32Array([ship.global_position.x, ship.global_position.z, ship.linear_velocity.x, ship.linear_velocity.z,
		atan2(f.x, f.z), ship.angular_velocity.y, mv.rudder_input, mv.engine_power])


static func _clear_track(track: PackedVector3Array, clearance: float) -> bool:
	for k in range(0, track.size(), DODGE_LAND_STEP):
		if NavigationMapManager.get_distance(Vector3(track[k].x, 0.0, track[k].y)) < clearance:
			return false
	return true


## Weight of `shells` that strike the hull along `track`, up to `top` above the water (citadel ones DODGE_CIT_W
## extra); INF for a track that runs within `clearance` of land.
static func _shell_cost(shells: Array, track: PackedVector3Array, hull: Rect2, cit: Rect2, clearance: float, top: float) -> float:
	if not _clear_track(track, clearance):
		return INF
	var cost := 0.0
	for sh in shells:
		var at: Vector3 = track[clampi(roundi(float(sh.time_remaining) / SAIL_DT), 0, track.size() - 1)]
		var fwd := Vector2(sin(at.z), cos(at.z))
		var side := Vector2(-cos(at.z), sin(at.z))
		var w := Vector2(float(sh.landing_x) - at.x, float(sh.landing_z) - at.y)
		var v := Vector2(float(sh.landing_vx), float(sh.landing_vz))
		# threat_half_len encodes the sine of the fall's angle from vertical.
		var f: float = clampf((float(sh.threat_half_len) - 15.0) / 35.0, 0.0, 0.99)
		var d := v.normalized() if v.length_squared() > 1e-6 else Vector2.ZERO
		var up: Vector2 = w - d * top * f / sqrt(1.0 - f * f)
		var a := Vector2(up.dot(side), up.dot(fwd))
		var b := Vector2(w.dot(side), w.dot(fwd))
		if _segment_in(a, b, hull):
			cost += pow(float(sh.caliber) / DODGE_REF_CAL, 3.0) * (1.0 + (DODGE_CIT_W if _segment_in(a, b, cit) else 0.0))
	return cost


## Whether segment a-b crosses `r` (Liang-Barsky).
static func _segment_in(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var t0 := 0.0
	var t1 := 1.0
	var d: Vector2 = b - a
	for e in [[-d.x, a.x - r.position.x], [d.x, r.end.x - a.x], [-d.y, a.y - r.position.y], [d.y, r.end.y - a.y]]:
		var p: float = e[0]
		var q: float = e[1]
		if absf(p) < 1e-9:
			if q < 0.0:
				return false
			continue
		var t: float = q / p
		if p < 0.0:
			t0 = maxf(t0, t)
		else:
			t1 = minf(t1, t)
		if t0 > t1:
			return false
	return true


static func _hull_box(ship: Ship) -> Rect2:
	var mv = ship.movement_controller
	var size := Vector2(mv.ship_beam, mv.ship_length)
	return Rect2(-size * 0.5, size)


## Hull track (x, z, heading) every SAIL_DT for `horizon`, steering for `h` at `throttle`; from `from_h` with the
## rudder amidships and the speed we have when given, else from the hull as it lies.
func _sail(ctx: SkillContext, throttle: float, horizon: float, h: float, from_h: float = INF) -> PackedVector3Array:
	var ship: Ship = ctx.ship
	var mv = ship.movement_controller
	var p: MovementParams = mv._p()
	var vmax: float = maxf(mv.max_speed, 1.0)
	var radius: float = maxf(p.turning_circle_radius, 1.0)
	var accel: float = vmax / maxf(p.acceleration_time, 0.1) * SAIL_DT
	var hdg: float = ctx.behavior._get_ship_heading()
	var v: float = ship.linear_velocity.dot(Vector3(sin(hdg), 0.0, cos(hdg)))
	if is_finite(from_h):
		hdg = from_h
	var target_v: float = -vmax * p.reverse_speed_ratio if throttle < 0.0 else vmax * throttle
	var omega := func(s: float) -> float:
		return absf(s) / (radius * (p.slow_speed_turn_tightening + (1.0 - p.slow_speed_turn_tightening) * clampf(absf(s) / vmax, 0.0, 1.0)))
	var w0: float = omega.call(v)
	var rudder: float = clampf(ship.angular_velocity.y / w0, -1.0, 1.0) if w0 > 1e-6 and not is_finite(from_h) else 0.0
	var dr: float = SAIL_DT / maxf(p.rudder_response_time, 0.01)
	var pos := Vector2(ship.global_position.x, ship.global_position.z)
	var track := PackedVector3Array([Vector3(pos.x, pos.y, hdg)])
	var t: float = 0.0
	while t < horizon:
		v = minf(v + accel, target_v) if v < target_v else maxf(v - accel, target_v)
		var max_turn: float = omega.call(v) * SAIL_DT
		var want_r: float = clampf(angle_difference(hdg, h) / max_turn, -1.0, 1.0) if max_turn > 1e-6 else 0.0
		var r0: float = rudder
		rudder += clampf(want_r - r0, -dr, dr)
		hdg = wrapf(hdg + 0.5 * (r0 + rudder) * max_turn, -PI, PI)
		pos += Vector2(sin(hdg), cos(hdg)) * v * SAIL_DT
		track.append(Vector3(pos.x, pos.y, hdg))
		t += SAIL_DT
	return track


func _citadel_box(ship: Ship) -> Rect2:
	if _citadel.has_area():
		return _citadel
	var inv: Transform3D = ship.global_transform.affine_inverse()
	var c: ArmorPart = ship.citadel
	if c != null:
		for n in c.get_children() + [c.get_parent()]:
			var a := AABB()
			if n is MeshInstance3D:
				a = n.get_aabb()
			elif n is CollisionShape3D and n.shape != null:
				a = n.shape.get_debug_mesh().get_aabb()
			else:
				continue
			a = inv * n.global_transform * a
			_citadel = Rect2(a.position.x, -a.end.z, a.size.x, a.size.z)
			return _citadel
	var mv = ship.movement_controller
	var size := Vector2(mv.ship_beam, mv.ship_length) * CITADEL_FALLBACK
	_citadel = Rect2(-size * 0.5, size)
	return _citadel


## Incoming damage per second from `shooter` at `aspect_deg` off our bow, -1 unknown.
static func dps_at(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> float:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	return maxf(float(e.ap_dps), float(e.he_dps)) if not e.is_empty() else -1.0


## (dps, repairable dps) of the worse ammo for us, from `shooter`'s point table once built, else the baked summary;
## (-1, 0) unknown.
static func _expected(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> Vector2:
	var e: Dictionary = BotGunnery._expected_points(shooter, ship, range_m, aspect_deg) if BotGunnery.point_tables_on() else {}
	return _expected_of(e, ship, shooter, range_m, aspect_deg)


## _expected from a point-table answer `e` ({}: the baked summary).
static func _expected_of(e: Dictionary, ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> Vector2:
	if e.is_empty():
		var model := BotGunnery.damage_model(ship)
		BotGunnery.damage_model(shooter)
		e = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	if e.is_empty():
		return Vector2(-1.0, 0.0)
	var he: bool = float(e.he_dps) > float(e.ap_dps)
	var dps: float = float(e.he_dps) if he else float(e.ap_dps)
	return Vector2(dps, dps * float(e.get("he_heal" if he else "ap_heal", 0.5)))


## Main and secondary dps on us at this range; one closing from past its range counts at its range.
static func _threat(shooter: Ship, ship: Ship, d: float) -> float:
	var c := BotBehavior.dps_curve(shooter, ship)
	return BotBehavior._curve_at(c, minf(d, BotBehavior.POINT_BLANK_M + (c.size() - 1) * BotBehavior.DESIRED_STEP_M))


## threat_axis while under fire, else the same weighting over every enemy the
## team knows of within AXIS_ADVANCE_M of its gun range; INF with none.
func axis_now(ctx: SkillContext) -> float:
	if is_finite(_axis):
		return _axis
	var ship: Ship = ctx.ship
	if ship.team == null or ctx.server == null:
		return INF
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var v := Vector2.ZERO
	for b in ctx.server._team_belief(ship.team.team_id):
		var e: Ship = b.ship
		if not is_instance_valid(e) or e.artillery_controller == null:
			continue
		var to: Vector2 = b.pos - here
		if to.length() > e.artillery_controller.get_params()._range + AXIS_ADVANCE_M or to.length() < 1.0:
			continue
		v += to.normalized() * BYSTANDER_WEIGHT * float(b.weight) * _threat(e, ship, to.length())
	return atan2(v.x, v.y) if v.length_squared() > 1e-6 else INF


## Chance `e`, not on us, turns its guns on us from `at`: one in however many of our lit ships, us included, it reaches.
static func _switch_chance(ctx: SkillContext, e: Ship, at: Vector2) -> float:
	var reach: float = e.artillery_controller.get_params()._range
	var n := 1
	for f: Ship in ctx.server.get_team_ships(ctx.ship.team.team_id):
		if f != ctx.ship and is_instance_valid(f) and f.is_alive() and f.visible_to_enemy \
				and Vector2(f.global_position.x, f.global_position.z).distance_to(at) <= reach:
			n += 1
	return 1.0 / n


## Every gun that can reach us, weighted by how sure we are it is on us, and unspotted enemies at their
## chance of it. False while unseen or while no seen gun shoots or aims here.
func _survey(ctx: SkillContext) -> bool:
	var ship: Ship = ctx.ship
	_shooters = []
	_me = ship
	var tv := Time.get_ticks_usec()
	_refresh_me(ship)
	_clock = ctx.behavior.salvo_clock
	BotTiming.add(&"sv_sig", tv)
	tv = Time.get_ticks_usec()
	_torp_shooters = _torp_survey(ctx)
	_pack_torps(ship)
	BotTiming.add(&"sv_torps", tv)
	if not ship.is_detected() or ship.team == null or ctx.server == null:
		return false
	tv = Time.get_ticks_usec()
	var weight := {}
	for s in ctx.behavior.active_shooters_at_me.keys():
		weight[s] = 1.0
	for s in ctx.behavior.salvo_clock.aimers:
		weight[s] = 1.0
	# Nobody on us: only guns the land is stopping count, so leaving a tuck is priced.
	var tucked: bool = weight.is_empty()
	_tucked = tucked
	var field: ReachField = NavigationMapManager.get_reach_field()
	var ids: PackedInt64Array = field.get_team_enemy_ids(ship.team.team_id) if field != null and field.is_built() else PackedInt64Array()
	var here: int = field.exposure_mask(ship.team.team_id, Vector2(ship.global_position.x, ship.global_position.z)) if not ids.is_empty() else -1
	BotTiming.add(&"sv_mask", tv)
	tv = Time.get_ticks_usec()
	for e in ctx.server.get_valid_targets(ship.team.team_id):
		if weight.has(e) or not is_instance_valid(e) or e.artillery_controller == null:
			continue
		if ship.global_position.distance_to(e.global_position) > e.artillery_controller.get_params()._range:
			continue
		var bit: int = ids.find(e.get_instance_id())
		if tucked and (bit < 0 or bit >= 63 or here & (1 << bit) != 0):
			continue
		weight[e] = _switch_chance(ctx, e, Vector2(e.global_position.x, e.global_position.z))
	BotTiming.add(&"sv_weights", tv)
	if weight.is_empty():
		return false
	tv = Time.get_ticks_usec()
	var now: float = SimClock.now()
	var at := Vector2(ship.global_position.x, ship.global_position.z)
	var belief := {}
	for b in ctx.server._team_belief(ship.team.team_id):
		belief[b.ship] = b
	for s in weight.keys():
		if not (s is Ship) or not is_instance_valid(s) or not s.is_alive():
			continue
		# An unseen shooter is where its shells came from, not where it is.
		var seen: bool = int(belief.get(s, {}).get("source", 0)) == 0
		var pos: Vector2 = Vector2(s.global_position.x, s.global_position.z) if seen or not belief.has(s) else belief[s].pos
		var b: int = ids.find(s.get_instance_id())
		_add_shooter(ctx, s, pos, &"on" if float(weight[s]) >= 1.0 else &"by", float(weight[s]), b if b < 63 and seen else -1, 0.0, now)
	BotTiming.add(&"sv_add_seen", tv)
	tv = Time.get_ticks_usec()
	var sources: Dictionary = ctx.server.get_unspotted_enemy_sources(ship.team.team_id)
	var times: Dictionary = ctx.server.get_unspotted_enemy_times(ship.team.team_id)
	for b in belief.values():
		var e: Ship = b.ship
		if weight.has(e) or int(b.source) == 0 or not is_instance_valid(e) or not e.is_alive() or e.artillery_controller == null:
			continue
		var r: float = e.artillery_controller.get_params()._range
		if (b.pos as Vector2).distance_to(at) - float(b.spread) > r + ESCAPE_M:
			continue
		# An inferred spotter is the ship that has us lit.
		var chance: float = minf(_switch_chance(ctx, e, b.pos) * (SPOTTER_TARGET_GAIN if int(b.source) == 3 else 1.0), 1.0)
		# A gunfire LKP dates its last salvo: it is on that clock while it keeps firing.
		var next := NAN
		var reload: float = maxf(e.artillery_controller.get_params().reload_time, 0.1)
		if sources.get(e, "") == GameServer.LKP_SOURCE_GUNFIRE and now - float(times.get(e, -INF)) <= reload * GUNFIRE_ACTIVE_RELOADS:
			next = fposmod(float(times[e]) - now, reload)
		_add_shooter(ctx, e, b.pos, &"dark", chance, -1, float(b.spread), now, next)
	BotTiming.add(&"sv_dark", tv)
	return _shooters.any(func(sh): return sh.group != &"dark")


func _add_shooter(ctx: SkillContext, s: Ship, pos: Vector2, group: StringName, weight: float, bit: int, spread: float, now: float,
		next_s: float = NAN) -> void:
	var ta := Time.get_ticks_usec()
	var to: Vector2 = pos - Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var reach: float = s.artillery_controller.get_params()._range
	var rows := _rows(ctx.ship, s, minf(to.length(), reach))
	BotTiming.add(&"sa_rows", ta)
	ta = Time.get_ticks_usec()
	if rows.is_empty():
		return
	var reload: float = maxf(s.artillery_controller.get_params().reload_time, 0.1)
	var next: float = next_s if not is_nan(next_s) else ctx.behavior.salvo_clock.next_landing(s, now) if group != &"dark" else INF
	_shooters.append({"id": s.get_instance_id(), "ship": s, "bearing": atan2(to.x, to.y), "rows": rows,
		"raw": _store.row(s.get_instance_id(), int(minf(to.length(), reach) / RANGE_BUCKET_M), 1),
		"bucket": int(minf(to.length(), reach) / RANGE_BUCKET_M),
		"weight": weight, "group": group, "bit": bit, "spread": spread, "threat": _threat(s, ctx.ship, to.length()),
		"pos": pos, "range": reach, "reload": reload, "next": next if is_finite(next) else reload * 0.5})
	BotTiming.add(&"sa_rest", ta)


## No gun on us: true while a target is in reach of guns we will fire or of loaded tubes.
func _quiet(ctx: SkillContext) -> bool:
	var target: Ship = ctx.target
	if target == null or not is_instance_valid(target) or not target.is_alive():
		return false
	var d: float = ctx.ship.global_position.distance_to(target.global_position)
	var arty = ctx.ship.artillery_controller
	var guns: bool = _guns_free(ctx) and arty != null and d <= arty.get_params()._range
	var tubes: bool = ctx.behavior.would_fire_torpedoes() and not _loaded_tubes(ctx).is_empty()
	return guns or tubes


static func _guns_free(ctx: SkillContext) -> bool:
	return ctx.behavior.would_fire_guns()


## Calibrated effective incoming dps per aspect step from `shooter`, cached per range bucket; empty unknown.
func _rows(ship: Ship, shooter: Ship, range_m: float) -> PackedFloat32Array:
	return _store.row(shooter.get_instance_id(), _ensure(ship, shooter, range_m), 0)


## range_m's bucket of `shooter`'s rows, `cells` (aspect indices) filled; a new bucket is built at range_m.
static var _ALL_ASPECTS := PackedInt32Array(range(ASPECTS))

func _ensure(ship: Ship, shooter: Ship, range_m: float, cells: PackedInt32Array = _ALL_ASPECTS) -> int:
	var id := shooter.get_instance_id()
	var bucket := int(range_m / RANGE_BUCKET_M)
	var read: int = _clock.shell_read(shooter) if _clock != null else SalvoClock.SHELL_UNKNOWN
	var sig := _row_sig(shooter, read)
	var pm := BotGunnery._projectile_native()
	var tq := Time.get_ticks_usec()
	if _store.ensure(pm, id, bucket, range_m, sig, SimClock.now(), TABLE_TTL_S, read, _me_live[1], _me_live[2], cells,
			ASPECT_STEP_DEG, ASPECTS) < 0:
		_store.set_pack(id, BotGunnery.stance_cell_pack(shooter, ship), read)
		_store.ensure(pm, id, bucket, range_m, sig, SimClock.now(), TABLE_TTL_S, read, _me_live[1], _me_live[2], cells,
			ASPECT_STEP_DEG, ASPECTS)
	BotTiming.add(&"q_ensure", tq)
	return bucket


## Our point-table live inputs (BotGunnery._pt_live_inputs: [point_sig, saturation mask, fires]) and HP step, as of the
## last survey or redodge.
var _me_live: Array = [0, 0, PackedFloat32Array()]
var _me_hpq: int = 0

func _refresh_me(ship: Ship) -> void:
	_me_live = BotGunnery._pt_live_inputs(ship, 0.0)
	var hp = ship.health_controller
	_me_hpq = roundi(20.0 * hp.current_hp / maxf(hp.max_hp, 1.0)) if hp != null else 0
	_sig_cache.clear()


## `sh`'s rows (&"rows", &"raw" or &"hit": damage per hit over alpha) at `dist` from it, out to its reach; empty unknown.
func _row_at(sh: Dictionary, dist: float, rows: StringName) -> PackedFloat32Array:
	if _me == null or not is_instance_valid(sh.ship):
		return sh.get(rows, PackedFloat32Array())
	var r: float = minf(dist, float(sh.range))
	return _store.row(sh.id, _ensure(_me, sh.ship, r), _rows_index(rows))


static func _loaded_tubes(ctx: SkillContext) -> Array:
	var tc = ctx.ship.torpedo_controller
	if tc == null or tc.get_params() == null:
		return []
	return tc.launchers.filter(func(l): return is_instance_valid(l) and l.reload >= 1.0 and not l.disabled)

## Bearing the route runs toward, INF once there.
static func _route_bearing(intent: NavIntent, ctx: SkillContext) -> float:
	if ctx.navigator == null or ctx.navigator.is_arrived():
		return INF
	var to: Vector3 = ctx.navigator.get_current_waypoint() - ctx.ship.global_position
	to.y = 0.0
	if to.length_squared() < 1.0:
		to = intent.target_position - ctx.ship.global_position
		to.y = 0.0
	return atan2(to.x, to.z) if to.length_squared() >= 1.0 else INF


## Fight or flight with the target in our guns: over DUEL_WINDOW_S, our damage on it (each turret firing
## once loaded and trained, slewing at its traverse rate within its limits) as a share of its HP, less
## the fire on us as a share of ours, its own stopping once it would sink. Of the lie stance chose, the bow
## angled DUEL_ANGLE off the target and the nearest full broadside, the best is held until our next gun loads.
const DUEL_WINDOW_S: float = 60.0
const DUEL_ANGLE: float = deg_to_rad(20.0)
const DUEL_HOLD_MIN_S: float = 3.0
## A target salvo whose expected damage times this reaches our HP can sink us.
const LETHAL_SPREAD: float = 2.0
var _duel_then: float = INF
var _duel_turn_at: float = INF
var _duel_h: float = INF
var _duel_until: float = -INF
var _duel_name: String = ""
## The target is in reach of the duel: its options, turning out to bear the guns among them, own the helm.
var _duel_live := false
var _duel_throttle: float = 1.0
var _last_dealt := 0.0
var _last_taken := 0.0
var _last_kill_s := INF
var _last_die_s := INF
## The chosen option sinks the target before it would sink us, inside the window.
var _duel_wins: bool = false
## The last scored option's uncalibrated damage over the window: dealt (to its HP) and taken.
var _last_pred_d := 0.0
var _last_pred_t := 0.0
var _pred := {}
## Hull names whose duel options print each reprice (BotScenario's trace).
static var duel_trace: Dictionary = {}
## "<our class>><target class>" -> option -> choices, for match metrics.
static var duel_stats: Dictionary = {}

## A duel we expect to win: it holds Disengage off. One we would lose leaves the helm to it.
func dueling() -> bool:
	return _active and is_finite(_duel_h) and _duel_wins

func _duel(ctx: SkillContext, hdg: float) -> void:
	_duel_live = false
	var t: Ship = ctx.target
	var arty = ctx.ship.artillery_controller
	if t == null or not is_instance_valid(t) or not t.is_alive() or arty == null or not ctx.behavior._aimable(t):
		_duel_h = INF
		return
	var d: float = ctx.ship.global_position.distance_to(t.global_position)
	var tc: TorpedoController = _tubes(ctx)
	if not (_guns_free(ctx) and d <= arty.get_params()._range) and not (tc != null and d <= tc.get_max_range()):
		_duel_h = INF
		return
	_duel_live = true
	var now: float = SimClock.now()
	if now < _duel_until:
		if is_finite(_duel_h):
			_take_duel()
		return
	var t_dl := Time.get_ticks_usec()
	_duel_priced(ctx, hdg, t, arty, d, tc, now)
	BotTiming.add(&"st_duel_priced", t_dl)
	_part("duel_priced", t_dl)
	_did.append("duel")

func _duel_priced(ctx: SkillContext, hdg: float, t: Ship, arty, d: float, tc: TorpedoController, now: float) -> void:
	var at := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var tp := Vector2(t.global_position.x, t.global_position.z)
	var to_t: float = atan2(tp.x - at.x, tp.y - at.y)
	var away: float = wrapf(to_t + PI, -PI, PI)
	# [heading, throttle, then heading, after s]. Ties go to the first: bow-in shows the least.
	# Every option makes way inside the progress cone: turning away is Fight's call, made by where it puts the station.
	var options := {}
	var side: float = signf(angle_difference(to_t, hdg)) if angle_difference(to_t, hdg) != 0.0 else 1.0
	options["bow-in"] = [_cone_heading(wrapf(to_t + side * DUEL_ANGLE, -PI, PI)), 1.0, INF, 0.0]
	var bs := _bearing_in_cone(arty.guns, tp, hdg, _cone_heading(hdg), true)
	if is_finite(bs):
		options["broadside"] = [bs, 1.0, INF, 0.0]
	if not is_finite(_route):
		options["stop"] = [hdg, 0.0, INF, 0.0]
	# Backing off with the bow already near the target (caught mid turn), it is swung onto it; further off, backing shows the side.
	if absf(angle_difference(hdg, to_t)) <= REVERSE_OFF_MAX and _in_cone(to_t, -1.0):
		options["reverse"] = [to_t, -1.0, INF, 0.0]
	if tc != null:
		var out := _bearing_in_cone(tc.launchers, tp, hdg, _cone_heading(away), false)
		if is_finite(out):
			options["torp-out"] = [out, 1.0, INF, 0.0]
	# Guns idle at the lie: out to bear them, on the side they fire soonest from, and back once they have.
	if _guns_free(ctx) and d <= arty.get_params()._range:
		var gun := _gun_pick(ctx, t, arty, arty.get_params(), _heading, hdg)
		if is_finite(gun.y) and gun.y < DUEL_WINDOW_S and _in_cone(gun.x, 1.0):
			options["turn-out"] = [gun.x, 1.0, _heading, gun.y]
	options["lie"] = [_heading, _throttle, INF, 0.0]
	var tracks := {}
	var lethal := {}
	var t_tr := Time.get_ticks_usec()
	for name in options:
		var o: Array = options[name]
		var track: Array = _held(_route_track, DUEL_WINDOW_S) if name == "lie" and _route_wins and not _route_track.is_empty() \
			else _option_track(ctx, hdg, float(o[0]), float(o[1]), float(o[2]), float(o[3]))
		if not track.is_empty():
			tracks[name] = track
			lethal[name] = _lethal(ctx, t, track)
	BotTiming.add(&"st_duel_tracks", t_tr)
	_part("duel_tracks", t_tr)
	BotTiming.add_us(&"st_duel_nopts", options.size())
	# A salvo that can sink us rules an option out, unless every option shows one.
	var safe: bool = lethal.values().has(false)
	var late := _station_delay(ctx, tracks)
	_pred.clear()
	var wins := {}
	var scores := {}
	var best := "lie"
	var best_score := -INF
	var scored: Array = []
	for name in tracks:
		if not (safe and lethal[name]):
			scored.append(name)
	var t_sc := Time.get_ticks_usec()
	var res := _duel_scores(ctx, t, tracks, scored)
	BotTiming.add(&"st_duel_scores", t_sc)
	_part("duel_score", t_sc)
	for name in tracks:
		var sc: float = -INF
		if res.has(name):
			var r: PackedFloat64Array = res[name]
			sc = r[0]
			_last_pred_d = r[1]
			_last_pred_t = r[2]
			_last_kill_s = r[3]
			_last_die_s = r[4]
			_last_dealt = r[5]
			_last_taken = r[6]
		if is_finite(sc) and late.has(name):
			sc -= maxf(float(late.net) - sc / DUEL_WINDOW_S, 0.0) * float(late[name])
		scores[name] = sc
		if is_finite(sc):
			_pred[name] = Vector2(_last_pred_d, _last_pred_t)
			wins[name] = _last_kill_s < _last_die_s
		if duel_trace.has(ctx.ship.ship_name):
			print("DUEL %s>%s %s d=%.0f hdg=%.0f h=%.0f dealt=%.3f taken=%.3f kill=%.0fs lethal=%s score=%.3f" % [ctx.ship.ship_name,
				t.ship_name, name, d, rad_to_deg(hdg), rad_to_deg(float(options[name][0])), _last_dealt, _last_taken, _last_kill_s,
				lethal[name], sc])
		if sc > best_score:
			best_score = sc
			best = name
	_duel_wins = bool(wins.get(best, false))
	_duel_name = best
	if _pred.has(best):
		_probe(ctx, t, _pred[best])
	var key := "%s>%s" % [Ship.ShipClass.keys()[ctx.ship.ship_class], Ship.ShipClass.keys()[t.ship_class]]
	var row: Dictionary = duel_stats.get_or_add(key, {})
	row[best] = int(row.get(best, 0)) + 1
	_duel_h = INF if best == "lie" else float(options[best][0])
	_duel_throttle = float(options[best][1])
	_duel_then = float(options[best][2]) if best != "lie" else INF
	_duel_turn_at = now + float(options[best][3])
	_duel_until = now + maxf(minf(_next_gun_s(arty), float(options[best][3]) if float(options[best][3]) > 0.0 else INF), DUEL_HOLD_MIN_S)
	# A two-leg option is only what was priced once its second leg is sailed.
	if best != "lie" and is_finite(float(options[best][2])):
		_duel_until = maxf(_duel_until, _duel_turn_at + DUEL_HOLD_MIN_S)
	# Stopping or backing off is only real once the way is off her: held until she has stopped.
	if best != "lie" and float(options[best][1]) <= 0.0:
		var mv = ctx.ship.movement_controller
		var v: float = maxf(Vector2(ctx.ship.linear_velocity.x, ctx.ship.linear_velocity.z).dot(Vector2(sin(hdg), cos(hdg))), 0.0)
		_duel_until = maxf(_duel_until, now + v / maxf(mv.max_speed, 1.0) * mv._p().deceleration_time)
	if is_finite(_duel_h):
		_take_duel()

## Per option, the seconds its end leaves us later to Fight's station than the nearest option's end, at full speed and
## within the threat horizon the station is valued over; with "net", the station's worth per second. Empty off a
## Fight station.
func _station_delay(ctx: SkillContext, tracks: Dictionary) -> Dictionary:
	var fs: FightStation = ctx.behavior._skill_fight.station
	var at: Vector2 = fs.station_xz()
	var net: float = fs.station_net()
	if ctx.behavior._active_skill_name != &"Fight" or not at.is_finite() or net <= 0.0:
		return {}
	var vmax: float = maxf(ctx.ship.movement_controller.max_speed, 1.0)
	var horizon: float = ctx.behavior.threat_horizon(ctx.server)
	var arrive := {}
	var least := INF
	for name in tracks:
		arrive[name] = minf((tracks[name][-1][0] as Vector2).distance_to(at) / vmax, horizon)
		least = minf(least, float(arrive[name]))
	var out := {"net": net}
	for name in arrive:
		out[name] = float(arrive[name]) - least
	return out

## Reverse is offered only with the bow this near the target.
const REVERSE_OFF_MAX := deg_to_rad(30.0)

## The heading nearest `want` that bears `mounts` (all of them, or any) on `at`, when it is inside the cone; else INF.
func _bearing_in_cone(mounts: Array, at: Vector2, hdg: float, want: float, all: bool) -> float:
	var h := _nearer(StanceSim.nearest_bearing(mounts, at, hdg, want, all), want)
	return h if is_finite(h) and _in_cone(h, 1.0) else INF

## Of a nearest_bearing pair, the one nearer `ref`; INF with none.
static func _nearer(hs: PackedFloat32Array, ref: float) -> float:
	if hs.is_empty():
		return INF
	return hs[0] if absf(angle_difference(ref, hs[0])) <= absf(angle_difference(ref, hs[1])) else hs[1]

## Our torpedo controller when we would launch, else null.
static func _tubes(ctx: SkillContext) -> TorpedoController:
	var tc: TorpedoController = ctx.ship.torpedo_controller if is_instance_valid(ctx.ship.torpedo_controller) else null
	return tc if tc != null and not tc.launchers.is_empty() and ctx.behavior.would_fire_torpedoes() else null

## Whether a salvo of the target's, landing on its clock along `track`, at the aspect we show it then,
## could sink us: its expected damage LETHAL_SPREAD times over our HP.
func _lethal(ctx: SkillContext, t: Ship, track: Array) -> bool:
	var hp: float = ctx.ship.health_controller.current_hp
	for sh in _shooters:
		if int(sh.id) != t.get_instance_id():
			continue
		var land: float = float(sh.next)
		while land < track.size() * ESCAPE_DT:
			var k: int = clampi(int(land / ESCAPE_DT), 0, track.size() - 1)
			var to: Vector2 = sh.pos - (track[k][0] as Vector2)
			var a: int = clampi(roundi(rad_to_deg(absf(angle_difference(float(track[k][1]), atan2(to.x, to.y)))) / ASPECT_STEP_DEG), 0, ASPECTS - 1)
			if float(sh.reload) * float(sh.raw[a]) * LETHAL_SPREAD >= hp:
				return true
			land += float(sh.reload)
	return false

func _take_duel() -> void:
	if is_finite(_duel_then) and SimClock.now() >= _duel_turn_at:
		_duel_h = _duel_then
		_duel_then = INF
	_heading = _duel_h
	_throttle = _duel_throttle
	_turning = false

## Seconds until our first gun loads.
static func _next_gun_s(arty) -> float:
	var reload: float = arty.get_params().reload_time
	var s := INF
	for g in arty.guns:
		if not g.disabled:
			s = minf(s, (1.0 - clampf(g.reload, 0.0, 1.0)) * reload)
	return s if is_finite(s) else reload

## DUEL_WINDOW_S of sailing `h` at full ahead, turning onto it first; with `then`, turning onto that after
## `after_s`. Stopped or astern, the bow held as it lies.
func _option_track(ctx: SkillContext, hdg: float, h: float, throttle: float, then: float = INF, after_s: float = 0.0) -> Array:
	var bow: float = hdg if throttle == 0.0 else h
	return _helm_cut(ctx, [[bow, throttle, 0.0, then, after_s]], DUEL_WINDOW_S,
		[[Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z), Vector2.ZERO, INF, bow, true, then, after_s]])[0][0]

## Each of `names` in `tracks` scored in one native call: name -> [score, pred dealt, pred taken, kill s, die s,
## dealt share, taken share].
func _duel_scores(ctx: SkillContext, t: Ship, tracks: Dictionary, names: Array) -> Dictionary:
	if names.is_empty():
		return {}
	var ship: Ship = ctx.ship
	var arty = ship.artillery_controller
	var gp: GunParams = arty.get_params()
	var ready := PackedFloat32Array()
	var live := 0
	for g in arty.guns:
		ready.append(INF if g.disabled else (1.0 - clampf(g.reload, 0.0, 1.0)) * gp.reload_time)
		live += 0 if g.disabled else 1
	var price := _price_cfg(maxf(ship.movement_controller.max_speed, 1.0), ship.team.team_id, &"raw", INF, {}, 0.0)
	price["dark_w"] = DamageExpectation.DARK_TAKEN[mini(ship.ship_class, 2)]
	var free := _guns_free(ctx)
	var asp: float = BotBehavior.guns_bear_aspect(t)
	var cfg := {"price": price, "dt": ESCAPE_DT, "guns_free": free, "guns": arty.guns,
		"pos0": Vector2(ship.global_position.x, ship.global_position.z), "hdg0": ctx.behavior._get_ship_heading(),
		"traverse": gp.traverse_speed, "ready": ready, "live": live, "range": gp._range, "reload": gp.reload_time,
		"t0": Vector2(t.global_position.x, t.global_position.z), "tv": Vector2(t.linear_velocity.x, t.linear_velocity.z),
		"t_id": t.get_instance_id(), "hp_t": maxf(t.health_controller.current_hp, 1.0), "hp": maxf(ctx.behavior.trade_hp(), 1.0),
		"cal": calibration(ship, t), "asp": asp, "pb": BotBehavior.POINT_BLANK_M, "curve_step": BotBehavior.DESIRED_STEP_M,
		"team": ship.team.team_id, "field": NavigationMapManager.get_reach_field(), "window": DUEL_WINDOW_S}
	if free:
		var g_pack: Array = _gun_pack(ship, t, asp)
		cfg["gpack"] = g_pack[0]
		cfg["affine"] = g_pack[1]
	var tc: TorpedoController = _tubes(ctx)
	if tc != null:
		var lp: TorpedoLauncherParams = tc.get_params()
		var tr := PackedFloat32Array()
		for l in tc.launchers:
			tr.append(INF if l.disabled else (1.0 - clampf(l.reload, 0.0, 1.0)) * lp.reload_time)
		cfg.merge({"tubes": tc.launchers, "tube_traverse": lp.traverse_speed, "tube_ready": tr, "tube_reload": lp.reload_time,
			"tube_speed": maxf(tc.get_torp_params().speed * _TorpedoManager.TORPEDO_SPEED_MULTIPLIER, 1.0),
			"tube_curve": BotBehavior.torpedo_curve(ship, t), "tube_range": tc.get_max_range(), "tube_count": tc.launchers.size()})
	var ships: Array = []
	if is_instance_valid(ship.secondary_controller):
		var tv0 := Vector2(t.linear_velocity.x, t.linear_velocity.z)
		cfg["sec_out"] = PackedFloat64Array([ship.get_instance_id(), t.get_instance_id(), ship.secondary_controller.get_max_range(),
			1.0, 1, 0.0, t.global_position.x, t.global_position.z, tv0.x, tv0.y, -1, _ALL_STEPS, asp])
		ships.append([ship, t])
	var jobs := PackedFloat64Array()
	for sh in _shooters:
		var e: Ship = sh.get("ship")
		if not is_instance_valid(e) or not is_instance_valid(e.secondary_controller):
			continue
		var w: float = DamageExpectation.DARK_TAKEN[mini(ship.ship_class, 2)] if sh.group == &"dark" else 1.0
		var ep: Vector2 = sh.pos
		var ev := Vector2.ZERO
		if e == t:
			ep = Vector2(t.global_position.x, t.global_position.z)
			ev = Vector2(t.linear_velocity.x, t.linear_velocity.z)
		jobs.append_array([e.get_instance_id(), ship.get_instance_id(), e.secondary_controller.get_max_range(), w, 0,
			atan2(-e.global_transform.basis.z.x, -e.global_transform.basis.z.z), ep.x, ep.y, ev.x, ev.y, int(sh.bit), _ALL_STEPS, 0.0])
		ships.append([e, ship])
	if not jobs.is_empty():
		cfg["sec_in"] = jobs
	for pair in ships:
		_sec_ready(pair[0], pair[1])
	var flats: Array = []
	for name in names:
		flats.append(_pack_track(tracks[name]))
		_w["incoming"] = int(_w.get("incoming", 0)) + 1
	var pm := BotGunnery._projectile_native()
	var r: Dictionary = StanceSim.duel_scores(_sec_cache, pm, flats, cfg)
	for i in _MISSING_ROUNDS:
		var rows: PackedFloat64Array = r.rows
		var miss: PackedFloat64Array = r.sec
		if rows.is_empty() and miss.is_empty():
			break
		if not rows.is_empty():
			_fill_rows(rows)
		if not miss.is_empty():
			_fill_sec(ships, miss)
		r = StanceSim.duel_scores(_sec_cache, pm, flats, cfg)
	var o: PackedFloat64Array = r.out
	var out := {}
	for j in names.size():
		out[names[j]] = o.slice(j * 7, j * 7 + 7)
	return out

## Past any track's end: the job runs the whole track.
const _ALL_STEPS := 1000000

## The secondary cells stance_sec reported missing ([job, range, aspect, bearing, sat] each), `ships` [shooter, target] per job.
static func _fill_sec(ships: Array, miss: PackedFloat64Array) -> void:
	var q := PackedFloat64Array()
	var v := PackedFloat32Array()
	for j in range(0, miss.size(), 5):
		var pair: Array = ships[int(miss[j])]
		var e: Dictionary = BotGunnery.expected(pair[0], pair[1], miss[j + 1], miss[j + 2], BotGunnery.KIND_SECONDARY, miss[j + 3])
		q.append_array([(pair[0] as Ship).get_instance_id(), (pair[1] as Ship).get_instance_id(), miss[j + 4], miss[j + 1],
			miss[j + 2], miss[j + 3]])
		v.append(maxf(float(e.get("ap_dps", 0.0)), float(e.get("he_dps", 0.0))))
	_sec_cache.put(q, v)

## [stance_cell_pack of our guns on `t`, salvo_affine at `asp`], built once per target state and aspect.
var _gun_pack_at: Array = []

func _gun_pack(ship: Ship, t: Ship, asp: float) -> Array:
	var sig := [t.get_instance_id(), BotGunnery.point_sig(t), DamageExpectation.aspect_band(asp), SimClock.now()]
	if _gun_pack_at.size() == 3 and _gun_pack_at[0] == sig:
		return [_gun_pack_at[1], _gun_pack_at[2]]
	var bands: int = int(ship.artillery_controller.get_params()._range / DamageExpectation.RANGE_BAND_M) + 2
	_gun_pack_at = [sig, BotGunnery.stance_cell_pack(ship, t), DamageExpectation.salvo_affine(ship, t, bands, asp)]
	return [_gun_pack_at[1], _gun_pack_at[2]]


## Secondary dps cells from the secondary point tables (BotBehavior._secondary_dps), shared by every bot.
static var _sec_cache := SecCache.new()

## `shooter`'s secondaries' pack on `target` set in _sec_cache for its state now.
static func _sec_ready(shooter: Ship, target: Ship) -> void:
	var sig := hash([BotGunnery.point_sig(target), BotGunnery._rt_keys.size()])
	if not _sec_cache.has_pack(shooter.get_instance_id(), target.get_instance_id(), sig):
		_sec_cache.set_pack(shooter.get_instance_id(), target.get_instance_id(), sig, BotGunnery.sec_pack(shooter, target))

## _secondary_dps from the secondary point tables; NAN while they cannot answer.
static func sec_dps(shooter: Ship, target: Ship, range_m: float, aspect_deg: float, bearing_deg: float) -> float:
	_sec_ready(shooter, target)
	return _sec_cache.dps(BotGunnery._projectile_native(), shooter.get_instance_id(), target.get_instance_id(), range_m,
		aspect_deg, bearing_deg)

## _secondary_dps at each of `ranges`; NAN where the secondary tables cannot answer.
static func sec_curve(shooter: Ship, target: Ship, ranges: PackedFloat64Array, aspect_deg: float) -> PackedFloat32Array:
	var sec = shooter.secondary_controller
	if not is_instance_valid(sec):
		var none := PackedFloat32Array()
		none.resize(ranges.size())
		return none
	_sec_ready(shooter, target)
	return _sec_cache.curve(BotGunnery._projectile_native(), shooter.get_instance_id(), target.get_instance_id(), ranges,
		aspect_deg, BotBehavior.guns_bear_aspect(shooter), sec.get_max_range())

## Real over predicted damage per "<our class>><target class>", fitted by tools/botmatch/duel_cal.py from
## duel_cal probes: x scales what we deal, y what we take. Shrunk toward the all-pairs fit by CAL_PRIOR_N probes.
const CAL_PATH := "res://assets/duel_calibration.json"
const CAL_PRIOR_N := 20.0
static var _cal: Dictionary = {}
static var _cal_loaded := false

static func calibration(ship: Ship, t: Ship) -> Vector2:
	if not _cal_loaded:
		_cal_loaded = true
		var f := FileAccess.open(CAL_PATH, FileAccess.READ)
		if f != null:
			_cal = JSON.parse_string(f.get_as_text())
	if _cal.is_empty():
		return Vector2.ONE
	var all: Dictionary = _cal.get("all", {})
	var base := Vector2(float(all.get("out", 1.0)), float(all.get("in", 1.0)))
	var c: Dictionary = (_cal.get("pairs", {}) as Dictionary).get("%s>%s" % [Ship.ShipClass.keys()[ship.ship_class], Ship.ShipClass.keys()[t.ship_class]], {})
	var n: float = float(c.get("n", 0.0))
	if n <= 0.0:
		return base
	return (Vector2(float(c.out), float(c["in"])) * n + base * CAL_PRIOR_N) / (n + CAL_PRIOR_N)

## Open duel predictions, resolved DUEL_WINDOW_S on against what landed: {at, ship, target, pred, dealt0, taken0, enemies}.
static var _probes: Array = []
## "<our class>><target class>" -> [pred dealt, real dealt, pred taken, real taken, probes], for match metrics.
static var duel_cal: Dictionary = {}

func _probe(ctx: SkillContext, t: Ship, pred: Vector2) -> void:
	var now: float = SimClock.now()
	var enemies: Array = ctx.server.get_team_ships(1 - ctx.ship.team.team_id)
	_probes.append({"at": now, "ship": ctx.ship, "target": t, "pred": pred, "hp_t": t.health_controller.current_hp,
		"dealt0": float(ctx.ship.stats._ships_damaged.get(t, 0.0)), "taken0": _taken_from(ctx.ship, enemies), "enemies": enemies})
	var keep: Array = []
	for p in _probes:
		# Probes outlive a match on a server that starts the next one in-process: its ships are freed.
		if not is_instance_valid(p.ship) or not is_instance_valid(p.target) or float(p.at) > now:
			continue
		if now - float(p.at) < DUEL_WINDOW_S:
			keep.append(p)
			continue
		var ship: Ship = p.ship
		var tgt: Ship = p.target
		var real_d: float = minf(float(ship.stats._ships_damaged.get(tgt, 0.0)) - float(p.dealt0), float(p.hp_t))
		var real_t: float = _taken_from(ship, p.enemies) - float(p.taken0)
		var row: Array = duel_cal.get_or_add("%s>%s" % [Ship.ShipClass.keys()[ship.ship_class], Ship.ShipClass.keys()[tgt.ship_class]],
			[0.0, 0.0, 0.0, 0.0, 0])
		row[0] += (p.pred as Vector2).x
		row[1] += real_d
		row[2] += (p.pred as Vector2).y
		row[3] += real_t
		row[4] += 1
	_probes = keep

static func _taken_from(ship: Ship, enemies: Array) -> float:
	var sum := 0.0
	for e in enemies:
		if is_instance_valid(e) and e.stats != null:
			sum += float(e.stats._ships_damaged.get(ship, 0.0))
	return sum


## "<class>" -> whether each dodge plan left the lie, for match metrics.
static var dodge_stats: Dictionary = {}

func _dodge_why(ctx: SkillContext, why: String) -> void:
	var row: Dictionary = dodge_stats.get_or_add(Ship.ShipClass.keys()[ctx.ship.ship_class], {})
	row[why] = int(row.get(why, 0)) + 1

## A shell of the dominant shooter's main battery (at least SETUP_SALVO_CAL of its caliber) lands near us.
const SETUP_SALVO_CAL: float = 0.8

func _salvo_inbound(ctx: SkillContext) -> bool:
	var d: Ship = ctx.behavior.salvo_clock.dominant
	if d == null or not is_instance_valid(d) or d.artillery_controller == null:
		return false
	var sp = d.artillery_controller.get_params().shell1
	var cal: float = float(sp.caliber) * SETUP_SALVO_CAL if sp != null else 0.0
	var at := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	for sh in ProjectileManager.get_shells_near_position(at, SHELL_QUERY_M, ctx.ship.team.team_id):
		if float(sh.caliber) >= cal:
			return true
	return false


## Between the dominant shooter's salvos: of the lie's heading and SETUP_OFFS either side, the one from which the
## dodge best slips the salvo that shooter would fire now (aimed on our lead, its own dispersion, SETUP_GRID shells
## across it), less SETUP_GUN_W for the share of our guns bearing. Re-chosen every SETUP_REPRICE_S. Off unless STANCE_SETUP:
## measured no better than the dodge alone.
const SETUP_OPTIONS := ["broadside", "away", "torp-out", "reverse"]
const SETUP_OFFS := [-30.0, -20.0, -10.0, 0.0, 10.0, 20.0, 30.0]
const SETUP_DODGE_OFFS := [0.0, 25.0, -25.0, 50.0, -50.0]
const SETUP_DODGE_THROTTLES := [1.0, 0.5, 0.0]
const SETUP_GRID := [-0.6, 0.0, 0.6]
const SETUP_GUN_W: float = 2.0
const SETUP_REPRICE_S: float = 2.0
var _set_up: bool = false
var _setup_off: float = 0.0
var _setup_at: float = -INF

func _setup(ctx: SkillContext, hdg: float) -> void:
	_set_up = false
	if not OS.has_environment("STANCE_SETUP") or _turning or (_on_route and not is_finite(_duel_h)) \
			or (is_finite(_duel_h) and _duel_name not in SETUP_OPTIONS):
		return
	var d: Ship = ctx.behavior.salvo_clock.dominant
	if d == null or not is_instance_valid(d) or d.artillery_controller == null or _salvo_inbound(ctx):
		return
	var gp: GunParams = d.artillery_controller.get_params()
	var at := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var from := Vector2(d.global_position.x, d.global_position.z)
	var range_m: float = at.distance_to(from)
	if range_m > gp._range or gp.shell1 == null:
		return
	var now: float = SimClock.now()
	if now - _setup_at >= SETUP_REPRICE_S:
		_setup_at = now
		_setup_off = _pick_setup(ctx, d, gp, at, from, range_m)
	_heading = wrapf(_heading + _setup_off, -PI, PI)
	_set_up = true

func _pick_setup(ctx: SkillContext, d: Ship, gp: GunParams, at: Vector2, from: Vector2, range_m: float) -> float:
	var tof: float = ctx.behavior.salvo_clock.dominant_tof
	var speed: float = Vector2(ctx.ship.linear_velocity.x, ctx.ship.linear_velocity.z).length()
	var half: Vector2 = gp._disp().dispersion_at(range_m, gp._range) * 0.5
	var arty = ctx.ship.artillery_controller
	var t: Ship = ctx.target
	var tp := Vector2(t.global_position.x, t.global_position.z) if t != null and is_instance_valid(t) else Vector2.INF
	var hull := _hull_box(ctx.ship)
	var cit := _citadel_box(ctx.ship)
	var clearance: float = ctx.behavior._get_ship_clearance()
	var top: float = (ctx.ship.movement_controller.ship_height - ctx.ship.movement_controller.ship_draft) * DODGE_TOP
	var hdg_now: float = ctx.behavior._get_ship_heading()
	var best := INF
	var pick := 0.0
	for off in SETUP_OFFS:
		var h: float = wrapf(_heading + deg_to_rad(off), -PI, PI)
		var aim: Vector2 = at + Vector2(sin(h), cos(h)) * speed * tof
		var f: float = clampf((_planner.fall_half() - 15.0) / 35.0, 0.05, 0.99)
		var along: float = half.y * f / sqrt(1.0 - f * f)
		var fall: Vector2 = (aim - from).normalized()
		var across := Vector2(-fall.y, fall.x)
		var shells: Array = []
		for i in SETUP_GRID:
			for j in SETUP_GRID:
				var p: Vector2 = aim + across * half.x * i + fall * along * j
				shells.append({"landing_x": p.x, "landing_z": p.y, "landing_vx": fall.x, "landing_vz": fall.y,
					"time_remaining": tof, "threat_half_len": _planner.fall_half(), "caliber": gp.shell1.caliber})
		var dodge := INF
		for o2 in SETUP_DODGE_OFFS:
			for thr in SETUP_DODGE_THROTTLES:
				dodge = minf(dodge, _shell_cost(shells, _sail(ctx, thr, tof, wrapf(h + deg_to_rad(o2), -PI, PI), h), hull, cit, clearance, top))
		var guns := 0.0
		if tp.is_finite() and arty != null and not arty.guns.is_empty():
			var m: PackedByteArray = StanceSim.bearing_mask(arty.guns, tp, hdg_now, h)
			guns = float(Array(m).count(1)) / arty.guns.size()
		var c: float = dodge - SETUP_GUN_W * guns
		if c < best:
			best = c
			pick = deg_to_rad(off)
	return pick
