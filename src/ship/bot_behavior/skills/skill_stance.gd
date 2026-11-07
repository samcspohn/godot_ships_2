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
const ESCAPE_MAX_S: float = 300.0
const ESCAPE_DT: float = 1.0
const ESCAPE_REPRICE_S: float = 1.0
## At full speed this share of what would land misses; slower, proportionally less.
const DODGE_AT_SPEED: float = 0.2
## Citadel damage counts this much extra.
const CITADEL_W: float = 1.0
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
## Shooter instance id -> {"t": built at, range bucket: [rows, raw]}; dropped after TABLE_TTL_S.
var _tables: Dictionary = {}
const TABLE_TTL_S: float = 5.0
var _me: Ship = null
var _clock: SalvoClock = null
## bearing, rows, weight, group (on, by, dark), spread (dark: believed-position radius), reload, next (seconds to its next landing).
var _shooters: Array[Dictionary] = []
## No gun reaches us now: the shooters are the ones land is stopping.
var _tucked := false
## Ship-local citadel footprint: x across, y along the bow.
var _citadel := Rect2()


func apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	if intent == null or ctx.behavior.salvo_clock == null:
		reset()
		return intent
	var threatened: bool = _survey(ctx)
	var route: float = _route_bearing(intent, ctx)
	_route = route
	var hdg: float = ctx.behavior._get_ship_heading()
	if not threatened and not _quiet(ctx):
		reset()
		return _dodge_off(intent, ctx, route, hdg)
	_active = true
	_throttle = 1.0
	_on_route = not threatened
	_axis = INF
	if threatened:
		_lie_on_axis(ctx, intent, route, hdg)
		_to_cone(hdg)
		_on_route = _route_wins
		if _on_route:
			_throttle = 1.0
		_duel(ctx, hdg)
		if is_finite(_duel_h):
			_on_route = false
		_setup(ctx, hdg)
	else:
		_duel_h = INF
		_duel_live = false
	var fire_h: float = INF if is_finite(_duel_h) or _set_up else _fire_heading(ctx, _heading if threatened and not _on_route else hdg, route, hdg)
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
	_juke = _dodge(ctx)
	if _juke:
		_heading = _dodge_h
		_throttle = _dodge_t
		_on_route = false
	if _on_route:
		return intent
	_to_cone(hdg)
	intent.target_heading = _heading
	intent.heading_weight = 1.0
	# A duel is fought under way: the navigator would brake for a destination stance is not sailing to.
	if (_juke or aimed) and _throttle > 0.0:
		intent.throttle_override = maxi(roundi(_throttle * 4.0), 1)
	elif is_finite(_duel_h) and _throttle > 0.0:
		intent.throttle_override = 4
	intent.force_reverse = _throttle < 0.0
	intent.forbid_reverse = _throttle >= 0.0
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
		" TURNING" if _turning else "", "", " " + _fire if _fire != &"" else "", " DODGE %s %.1f>%.1f" % [_dodge_kind, _dodge_cost.x, _dodge_cost.y] if _juke else "",
		_turn_cost, _astern_cost, _shooters.size()]


func _setup_tag() -> String:
	return " SETUP %+.0f" % rad_to_deg(_setup_off) if _set_up else ""


func reset() -> void:
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
	var paths: PackedVector3Array = StanceSim.route_path(ctx.navigator.get_debug_arc_inputs(), _hull_state(ctx.ship), pts,
		ROUTE_WP_M, ESCAPE_MAX_S, ESCAPE_DT)
	paths.insert(0, start)
	return _as_track(paths, 0, paths.size())

## The lie sailed ahead at its throttle: swinging onto _heading the short way, then on.
func _ahead_track(ctx: SkillContext, hdg: float, vmax: float, p: MovementParams) -> Array:
	var sailed := _helm_tracks(ctx, [[_heading, maxf(_throttle, 0.0), 0.0, INF, 0.0]], ESCAPE_MAX_S)
	return _cut(ctx, sailed[0], Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z), Vector2.ZERO, INF, _heading, true)[0]


## Per leg [heading, throttle, way (±1 round that way, 0 the short way), then, after_s], sailed on the navigator's hull
## from the hull as it is: [position, heading, speed] every ESCAPE_DT over `horizon`; empty without a navigator.
func _helm_tracks(ctx: SkillContext, legs: Array, horizon: float) -> Array:
	var flat := PackedFloat32Array()
	for l in legs:
		flat.append_array([l[0], _power(l[1]), l[2], l[3], l[4]])
	var paths := PackedVector3Array()
	if ctx.navigator != null:
		paths = StanceSim.helm_paths(ctx.navigator.get_debug_arc_inputs(), _hull_state(ctx.ship), flat, horizon, ESCAPE_DT)
	var m: int = int(horizon / ESCAPE_DT) + 1
	var out: Array = []
	for i in legs.size():
		out.append(_as_track(paths, i * m, m) if paths.size() >= (i + 1) * m else [])
	return out

## helm_paths / route_path points from `from`, `m` of them (the first the start), as [position, heading, speed].
static func _as_track(paths: PackedVector3Array, from: int, m: int) -> Array:
	var track: Array = []
	for k in range(1, m):
		var q: Vector3 = paths[from + k]
		var prev: Vector3 = paths[from + k - 1]
		track.append([Vector2(q.x, q.y), q.z, Vector2(q.x - prev.x, q.y - prev.y).length() / ESCAPE_DT])
	return track

const SWUNG: float = deg_to_rad(3.0)

## `track` ended once `want` is made good along `gdir` (with `swung`, only after the bow is within SWUNG of `final`),
## empty when it runs aground before `reach` past that swing; with the seconds the swing took.
func _cut(ctx: SkillContext, track: Array, start: Vector2, gdir: Vector2, want: float, final: float, swung: bool,
		then: float = INF, after_s: float = 0.0) -> Array:
	var p: MovementParams = ctx.ship.movement_controller._p()
	var reach: float = maxf(p.turning_circle_radius * CLEAR_AHEAD_TURNS, CLEAR_AHEAD_MIN_M)
	var clearance: float = ctx.behavior._get_ship_clearance()
	var swing_k := -1
	var first_s := -1.0
	var after := 0.0
	for k in track.size():
		var at: Vector2 = track[k][0]
		# The second leg is a swing of its own, with its own reach of land checked past it.
		if is_finite(then) and (k + 1) * ESCAPE_DT >= after_s:
			first_s = (swing_k + 1) * ESCAPE_DT if swing_k >= 0 else (k + 1) * ESCAPE_DT
			final = then
			then = INF
			swing_k = -1
			after = 0.0
		if swing_k < 0 and absf(angle_difference(float(track[k][1]), final)) <= SWUNG:
			swing_k = k
		if swing_k >= 0:
			after += float(track[k][2]) * ESCAPE_DT
		if after <= reach and NavigationMapManager.get_distance(Vector3(at.x, 0.0, at.y)) < clearance:
			return [[], 0.0]
		if (swing_k >= 0 or not swung) and (at - start).dot(gdir) >= want:
			return [track.slice(0, k + 1), first_s if first_s >= 0.0 else (swing_k + 1) * ESCAPE_DT if swing_k >= 0 else (k + 1) * ESCAPE_DT]
	return [track, first_s if first_s >= 0.0 else (swing_k + 1) * ESCAPE_DT if swing_k >= 0 else track.size() * ESCAPE_DT]


## Turning round, either way the land leaves clear, run until as far toward the goal, against backing
## for as long, plus the time at full speed to make up the distance backing fell short: the salvos that
## land, in effective HP. _turn_hp is the swing's alone, unweighted.
func _turn_beats_astern(ctx: SkillContext, hdg: float, near: float, far: float, goal: float, dist: float) -> bool:
	var now: float = SimClock.now()
	if now - _priced_at < ESCAPE_REPRICE_S:
		return _turn_cost < _astern_cost
	_priced_at = now
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
	var sailed := _helm_tracks(ctx, [[far, 1.0, short, INF, 0.0], [far, 1.0, -short, INF, 0.0], [near, -1.0, 0.0, INF, 0.0]], ESCAPE_MAX_S)
	for i in 2:
		var cut := _cut(ctx, sailed[i], start, gdir, want, far, true)
		var track: Array = cut[0]
		if not track.is_empty():
			var cost := _priced(ctx, "turn", track, vmax, team_id, &"rows", INF)
			if cost < _turn_cost:
				_turn_cost = cost
				_turn_way = short if i == 0 else -short
				_swing_s = cut[1]
				_turn_hp = _priced(ctx, "turn", track, vmax, team_id, &"raw", _swing_s)
				_turn_track = track
	var back: Array = _cut(ctx, sailed[2], start, gdir, want, near, false)[0]
	_back_track = back
	_window_s = _turn_track.size() * ESCAPE_DT if not _turn_track.is_empty() else back.size() * ESCAPE_DT
	if _turn_track.is_empty():
		_swing_s = 0.0
	_astern_cost = INF
	_astern_hp = INF
	if not back.is_empty():
		# Same window as the turn; what backing has not covered by its end is sailed on at this rate.
		_astern_cost = _priced(ctx, "astern", back, vmax, team_id, &"rows", _window_s)
		_astern_hp = _priced(ctx, "astern", back, vmax, team_id, &"raw", _window_s)
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
	var s := _track_slices(track, vmax, team_id, rows, window_s, stops, skip_s)
	var torps: float = 0.0
	if rows == &"rows":
		for v in _track_torps(track, window_s):
			torps += v
	return DamageExpectation.price(ctx.ship, kind, s[0], s[1], s[2], minf(window_s, track.size() * ESCAPE_DT)) + torps


## [on, by, dark]: `rows` salvos along `track` (as _track_split) per DamageExpectation.TURNOUT_SLICES_S slice, from
## shooters on us, bystanders and unspotted enemies.
func _track_slices(track: Array, vmax: float, team_id: int, rows: StringName, window_s: float, stops: Dictionary = {},
		skip_s: float = 0.0) -> Array:
	var slices: Array = DamageExpectation.TURNOUT_SLICES_S
	var out := {"on": [], "by": [], "dark": []}
	for g in out:
		(out[g] as Array).resize(slices.size())
		(out[g] as Array).fill(0.0)
	var end: float = minf(track.size() * ESCAPE_DT, window_s)
	var field: ReachField = NavigationMapManager.get_reach_field()
	var masks := {}
	for sh in _shooters:
		var reload: float = sh.reload
		var t: float = float(sh.next)
		while t < skip_s:
			t += reload
		var into: Array = out[sh.group]
		var stop: float = minf(end, float(stops.get(sh.id, INF)))
		while t < stop:
			var k: int = clampi(int(t / ESCAPE_DT), 0, track.size() - 1)
			var at: Vector2 = track[k][0]
			var to: Vector2 = sh.pos - at
			var bit: int = int(sh.bit)
			if bit >= 0 and field != null and not masks.has(k):
				masks[k] = field.exposure_mask(team_id, at)
			var shadowed: bool = bit >= 0 and field != null and int(masks[k]) & (1 << bit) == 0
			var reach: float = _reach_share(sh, to.length())
			if reach > 0.0 and not shadowed:
				var a: int = clampi(roundi(rad_to_deg(absf(angle_difference(float(track[k][1]), atan2(to.x, to.y)))) / ASPECT_STEP_DEG), 0, ASPECTS - 1)
				var si: int = 0
				while si < slices.size() - 1 and t >= slices[si]:
					si += 1
				var row := _row_at(sh, to.length(), rows)
				if not row.is_empty():
					into[si] += reload * float(sh.weight) * reach * row[a] * (1.0 - DODGE_AT_SPEED * float(track[k][2]) / vmax)
			t += reload
	return [out.on, out.by, out.dark]


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
	_heading = _dodge_h
	_throttle = _dodge_t
	intent.target_heading = _heading
	intent.heading_weight = 1.0
	if _throttle > 0.0:
		intent.throttle_override = roundi(_throttle * 4.0)
	intent.force_reverse = _throttle < 0.0
	intent.forbid_reverse = _throttle >= 0.0
	return intent


## Rudder orders and throttles tried against the shells in the air.
## Full rudder held this long either way, then centred (0: centred now); the hull swings on as it answers.
const DODGE_HOLDS := [0.0, 1.0, 2.0, 3.0, 4.0, 6.0, 99.0]
const DODGE_THROTTLES := [1.0, 0.75, 0.5, 0.0, -1.0]
const DODGE_LAND_EVERY_S: float = 1.0
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
var _dodge_h: float = INF
var _dodge_t: float = 1.0
var _dodge_until: float = -INF
## Shell id and landing time of every shell the plan saw: ids are reused.
var _dodge_seen: Dictionary = {}
var _dodge_cost := Vector2.ZERO
var _dodge_kind: String = ""
var _dodge_kinds: PackedStringArray = []
## The salvos still to come are priced this long past the shells in the air, as turn and astern are.
const DODGE_PRICE_S: float = 20.0

## Whether an enemy shell lands near `ship` that the last dodge plan did not see.
func shells_fresh(ship: Ship) -> bool:
	var now: float = SimClock.now()
	for sh in ProjectileManager.get_shells_near_position(Vector2(ship.global_position.x, ship.global_position.z), SHELL_QUERY_M, ship.team.team_id):
		if not _dodge_seen.has(Vector2i(int(sh.shell_id), roundi((now + float(sh.time_remaining)) * 2.0))):
			return true
	return false


## The heading and throttle, held until its shells land, that the fewest enemy shells in the air hit; re-planned as new
## shells are fired. False when the lie does as well.
func _dodge(ctx: SkillContext) -> bool:
	var ship: Ship = ctx.ship
	var now: float = SimClock.now()
	var shells: Array = ProjectileManager.get_shells_near_position(
		Vector2(ship.global_position.x, ship.global_position.z), SHELL_QUERY_M, ship.team.team_id)
	var seen := {}
	var fresh := false
	var horizon: float = 0.0
	var big: float = 0.0
	for sh in shells:
		var key := Vector2i(int(sh.shell_id), roundi((now + float(sh.time_remaining)) * 2.0))
		seen[key] = true
		fresh = fresh or not _dodge_seen.has(key)
		horizon = maxf(horizon, float(sh.time_remaining))
		if float(sh.caliber) > big:
			big = float(sh.caliber)
			_fall_half = float(sh.threat_half_len)
	if not fresh and now < _dodge_until:
		return is_finite(_dodge_h)
	_dodge_seen = seen
	_dodge_h = INF
	if shells.is_empty():
		_dodge_until = -INF
		return false
	_dodge_until = now + horizon
	var hdg: float = ctx.behavior._get_ship_heading()
	var hull := _hull_box(ship)
	var cit := _citadel_box(ship)
	var clearance: float = ctx.behavior._get_ship_clearance()
	var top: float = (ship.movement_controller.ship_height - ship.movement_controller.ship_draft) * DODGE_TOP
	if ctx.navigator == null:
		return false
	var params: PackedFloat32Array = ctx.navigator.get_debug_arc_inputs()
	var state := _hull_state(ship)
	var cands := PackedVector3Array([Vector3(_heading, -1.0, _power(_throttle))])
	var throttles := PackedFloat32Array([_throttle])
	for hold in DODGE_HOLDS:
		for side in ([0.0] if hold == 0.0 else [-1.0, 1.0]):
			for thr in DODGE_THROTTLES:
				cands.append(Vector3(side, hold, _power(thr)))
				throttles.append(thr)
	var out: PackedFloat32Array = StanceSim.dodge_costs(_pack_shells(shells), hull, cit, top, DODGE_REF_CAL, DODGE_CIT_W,
		params, state, cands, horizon, _shell_aspects(ship, shells))
	var cost := _dodge_window_costs(ctx, shells, out, cands, throttles, params, state, horizon)
	var w: float = float(cost[cost.size() - 1])
	var score := func(i: int) -> float:
		return cost[i] + w * (DODGE_OFF_W * absf(angle_difference(_heading, out[2 * i + 1])) + DODGE_GEAR_W * absf(throttles[i] - _throttle))
	var order: Array = range(cands.size())
	order.sort_custom(func(i, j): return score.call(i) < score.call(j))
	# Land is checked only down the ranking: the rest never needs it.
	var lie_clear := true
	for i in order:
		if i != 0 and not _in_cone(out[2 * i + 1], throttles[i]):
			continue
		var clear := true
		for q in StanceSim.dodge_track(params, state, cands[i], horizon, DODGE_LAND_EVERY_S):
			if NavigationMapManager.get_distance(Vector3(q.x, 0.0, q.y)) < clearance:
				clear = false
				break
		if i == 0:
			lie_clear = clear
		if not clear:
			continue
		if i != 0 and (not lie_clear or score.call(i) <= cost[0] - DODGE_MIN_GAIN * w):
			_dodge_h = out[2 * i + 1]
			_dodge_t = throttles[i]
			_dodge_kind = _dodge_kinds[i]
		_dodge_cost = Vector2(cost[0], score.call(i)) / w
		break
	_dodge_why(ctx, "dodge" if is_finite(_dodge_h) else "dodge_lie")
	return is_finite(_dodge_h)


## Per candidate: the shells in the air that strike (dodge_costs' weight, made HP by the shooters' shell damage) plus the
## salvos after them over DODGE_PRICE_S along its track, range and aspect priced, the lie's way made good short of it charged
## as astern's is; last, HP per weight unit. Without a known shooter, the weights alone.
func _dodge_window_costs(ctx: SkillContext, shells: Array, out: PackedFloat32Array, cands: PackedVector3Array,
		throttles: PackedFloat32Array, params: PackedFloat32Array, state: PackedFloat32Array, horizon: float) -> PackedFloat32Array:
	var n: int = cands.size()
	var cost := PackedFloat32Array()
	cost.resize(n + 1)
	_dodge_kinds.resize(n)
	for i in n:
		cost[i] = out[2 * i]
		var c: Vector3 = cands[i]
		_dodge_kinds[i] = "lie" if i == 0 else "astern" if throttles[i] < 0.0 else "turn" if c.y > 0.0 \
			else "forward" if throttles[i] > 0.0 else "stop"
	cost[n] = 1.0
	var dmg := {}
	for sh in _shooters:
		if is_instance_valid(sh.ship) and not sh.ship.artillery_controller.guns.is_empty():
			var p: ShellParams = sh.ship.artillery_controller.guns[0].get_shell()
			dmg[roundi(p.caliber)] = p.damage
	var hp := 0.0
	var wt := 0.0
	for sh in shells:
		var cal: int = roundi(float(sh.caliber))
		if dmg.has(cal):
			hp += float(dmg[cal])
			wt += pow(float(sh.caliber) / DODGE_REF_CAL, 3.0)
	if wt <= 0.0:
		return cost
	var per_w: float = hp / wt
	var window: float = horizon + DODGE_PRICE_S
	var paths: PackedVector3Array = StanceSim.dodge_paths(params, state, cands, window, ESCAPE_DT)
	var m: int = int(window / ESCAPE_DT) + 1
	if paths.size() < n * m:
		return cost
	var vmax: float = maxf(ctx.ship.movement_controller.max_speed, 1.0)
	var start := Vector2(paths[0].x, paths[0].y)
	# Made good along the lie's heading, not along wherever its own track ends: a lie still turning round ends behind it.
	var lie_dir := Vector2(sin(_heading), cos(_heading)) * (-1.0 if _throttle < 0.0 else 1.0)
	var lie_made: float = (Vector2(paths[m - 1].x, paths[m - 1].y) - start).dot(lie_dir)
	var team_id: int = ctx.ship.team.team_id
	for i in n:
		var track: Array = []
		for k in m:
			var q: Vector3 = paths[i * m + k]
			var prev: Vector3 = paths[i * m + maxi(k - 1, 0)]
			track.append([Vector2(q.x, q.y), q.z, Vector2(q.x - prev.x, q.y - prev.y).length() / ESCAPE_DT])
		var made: float = ((track[-1][0] as Vector2) - start).dot(lie_dir)
		var short_s: float = maxf(lie_made - made, 0.0) / vmax
		var later: float = _priced(ctx, "dodge", track, vmax, team_id, &"rows", window, {}, horizon)
		cost[i] = (out[2 * i] * per_w + later) * (1.0 + short_s / window)
	cost[n] = per_w
	return cost


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


## get_shells_near_position entries as StanceSim.dodge_costs reads them.
## Per shell in `shells`, what a hit of it does at each aspect off our bow over its alpha, from the shooter it comes
## from (by bearing, as SalvoClock credits it) and the shell it is read to load; all 1 from an unknown one.
func _shell_aspects(ship: Ship, shells: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var at := Vector2(ship.global_position.x, ship.global_position.z)
	for s in shells:
		var from: float = atan2(-float(s.landing_vx), -float(s.landing_vz))
		var row := PackedFloat32Array()
		var best: float = SalvoClock.SOURCE_MATCH
		for sh in _shooters:
			var d: float = absf(angle_difference(from, float(sh.bearing)))
			if d < best and is_instance_valid(sh.ship):
				best = d
				row = _row_at(sh, (sh.pos as Vector2).distance_to(at), &"hit")
		if row.size() != ASPECTS:
			row = PackedFloat32Array()
			row.resize(ASPECTS)
			row.fill(1.0)
		out.append_array(row)
	return out

static func _pack_shells(shells: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for sh in shells:
		out.append_array([sh.landing_x, sh.landing_z, sh.landing_vx, sh.landing_vz, sh.time_remaining, sh.threat_half_len, sh.caliber])
	return out

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
	if e.is_empty():
		var model := BotGunnery.damage_model(ship)
		BotGunnery.damage_model(shooter)
		e = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	if e.is_empty():
		return Vector2(-1.0, 0.0)
	var he: bool = float(e.he_dps) > float(e.ap_dps)
	var dps: float = float(e.he_dps) if he else float(e.ap_dps)
	return Vector2(dps, dps * float(e.get("he_heal" if he else "ap_heal", 0.5)))


## Dps of `shooter`'s shell `read` (SalvoClock.shell_read; unknown: the worse for us at this aspect), from its point
## table (live pools, real dispersion) once built, else the baked summary; AP alone, without lighting fires first:
## (citadel hits counted CITADEL_W extra, as it takes HP); z, that shell's damage per hit over its alpha. x -1 unknown.
static func _effective(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float, read: int = SalvoClock.SHELL_UNKNOWN) -> Vector3:
	var e: Dictionary = BotGunnery._expected_points(shooter, ship, range_m, aspect_deg) if BotGunnery.point_tables_on() else {}
	if e.is_empty():
		var model := BotGunnery.damage_model(ship)
		BotGunnery.damage_model(shooter)
		e = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	if e.is_empty():
		return Vector3(-1.0, -1.0, 1.0)
	var ap_raw: float = float(e.get("ap_pure_dps", e.ap_dps))
	var ap := ap_raw * (1.0 + CITADEL_W * float(e.get("ap_cit", 0.0)))
	var he := float(e.he_dps) * (1.0 + CITADEL_W * float(e.get("he_cit", 0.0)))
	var p: GunParams = shooter.artillery_controller.get_params()
	var rate: float = float(e.ap_dps) / maxf(float(e.ap_ev), 1e-6)
	if read == SalvoClock.SHELL_AP or (read == SalvoClock.SHELL_UNKNOWN and ap >= he):
		var alpha_ap: float = p.shell1.damage if p.shell1 != null else 1.0
		return Vector3(ap, ap_raw, ap_raw / rate / maxf(float(e.get("ap_landed", 1.0)), 0.01) / maxf(alpha_ap, 1.0))
	var alpha_he: float = p.shell2.damage if p.shell2 != null else 1.0
	return Vector3(he, float(e.he_dps), float(e.he_dps) / rate / maxf(float(e.get("he_landed", 1.0)), 0.01) / maxf(alpha_he, 1.0))


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
	_clock = ctx.behavior.salvo_clock
	_torp_shooters = _torp_survey(ctx)
	if not ship.is_detected() or ship.team == null or ctx.server == null:
		return false
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
	for e in ctx.server.get_valid_targets(ship.team.team_id):
		if weight.has(e) or not is_instance_valid(e) or e.artillery_controller == null:
			continue
		if ship.global_position.distance_to(e.global_position) > e.artillery_controller.get_params()._range:
			continue
		var bit: int = ids.find(e.get_instance_id())
		if tucked and (bit < 0 or bit >= 63 or here & (1 << bit) != 0):
			continue
		weight[e] = _switch_chance(ctx, e, Vector2(e.global_position.x, e.global_position.z))
	if weight.is_empty():
		return false
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
	return _shooters.any(func(sh): return sh.group != &"dark")


func _add_shooter(ctx: SkillContext, s: Ship, pos: Vector2, group: StringName, weight: float, bit: int, spread: float, now: float,
		next_s: float = NAN) -> void:
	var to: Vector2 = pos - Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var reach: float = s.artillery_controller.get_params()._range
	var rows := _rows(ctx.ship, s, minf(to.length(), reach))
	if rows.is_empty():
		return
	var reload: float = maxf(s.artillery_controller.get_params().reload_time, 0.1)
	var next: float = next_s if not is_nan(next_s) else ctx.behavior.salvo_clock.next_landing(s, now) if group != &"dark" else INF
	_shooters.append({"id": s.get_instance_id(), "ship": s, "bearing": atan2(to.x, to.y), "rows": rows,
		"raw": _tables[s.get_instance_id()][int(minf(to.length(), reach) / RANGE_BUCKET_M)][1],
		"weight": weight, "group": group, "bit": bit, "spread": spread, "threat": _threat(s, ctx.ship, to.length()),
		"pos": pos, "range": reach, "reload": reload, "next": next if is_finite(next) else reload * 0.5})


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


## Calibrated effective incoming dps per aspect step from `shooter`, cached per range bucket (with the
## unweighted dps alongside); empty unknown.
func _rows(ship: Ship, shooter: Ship, range_m: float) -> PackedFloat32Array:
	var id := shooter.get_instance_id()
	var bucket := int(range_m / RANGE_BUCKET_M)
	var now: float = SimClock.now()
	var read: int = _clock.shell_read(shooter) if _clock != null else SalvoClock.SHELL_UNKNOWN
	var by: Dictionary = _tables.get(id, {})
	if by.is_empty() or now - float(by.t) > TABLE_TTL_S or int(by.read) != read:
		by = {"t": now, "read": read}
		_tables[id] = by
	if by.has(bucket):
		return by[bucket][0]
	var row := PackedFloat32Array()
	var raw := PackedFloat32Array()
	var hit := PackedFloat32Array()
	row.resize(ASPECTS)
	raw.resize(ASPECTS)
	hit.resize(ASPECTS)
	var cal: float = BotGunnery.calibration(shooter, ship, range_m)
	for i in ASPECTS:
		var e := _effective(ship, shooter, range_m, i * ASPECT_STEP_DEG, read)
		if e.x < 0.0:
			row = PackedFloat32Array()
			raw = PackedFloat32Array()
			hit = PackedFloat32Array()
			break
		row[i] = e.x * cal
		raw[i] = e.y * cal
		hit[i] = e.z * cal
	by[bucket] = [row, raw, hit]
	return row


## `sh`'s rows (&"rows", &"raw" or &"hit": damage per hit over alpha) at `dist` from it, out to its reach; empty unknown.
func _row_at(sh: Dictionary, dist: float, rows: StringName) -> PackedFloat32Array:
	if _me == null or not is_instance_valid(sh.ship):
		return sh.get(rows, PackedFloat32Array())
	var r: float = minf(dist, float(sh.range))
	var row := _rows(_me, sh.ship, r)
	if rows == &"rows" or row.is_empty():
		return row
	return _tables[sh.id][int(r / RANGE_BUCKET_M)][2 if rows == &"hit" else 1]


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
	for name in options:
		var o: Array = options[name]
		var track: Array = _held(_route_track, DUEL_WINDOW_S) if name == "lie" and _route_wins and not _route_track.is_empty() \
			else _option_track(ctx, hdg, float(o[0]), float(o[1]), float(o[2]), float(o[3]))
		if not track.is_empty():
			tracks[name] = track
			lethal[name] = _lethal(ctx, t, track)
	# A salvo that can sink us rules an option out, unless every option shows one.
	var safe: bool = lethal.values().has(false)
	var late := _station_delay(ctx, tracks)
	_pred.clear()
	var wins := {}
	var scores := {}
	var best := "lie"
	var best_score := -INF
	for name in tracks:
		var sc: float = -INF if safe and lethal[name] else _duel_score(ctx, t, tracks[name])
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
	var sailed := _helm_tracks(ctx, [[bow, throttle, 0.0, then, after_s]], DUEL_WINDOW_S)
	return _cut(ctx, sailed[0], Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z), Vector2.ZERO, INF, bow, true,
		then, after_s)[0]

func _duel_score(ctx: SkillContext, t: Ship, track: Array) -> float:
	var ship: Ship = ctx.ship
	var arty = ship.artillery_controller
	var gp: GunParams = arty.get_params()
	var n: int = track.size()
	var pos := PackedVector2Array()
	var hdgs := PackedFloat32Array()
	var tpos := PackedVector2Array()
	var t0 := Vector2(t.global_position.x, t.global_position.z)
	var tv := Vector2(t.linear_velocity.x, t.linear_velocity.z)
	for k in n:
		pos.append(track[k][0])
		hdgs.append(float(track[k][1]))
		tpos.append(t0 + tv * (k + 1) * ESCAPE_DT)
	var at0 := Vector2(ship.global_position.x, ship.global_position.z)
	var hdg0: float = ctx.behavior._get_ship_heading()
	var masks: PackedInt64Array = StanceSim.track_bearing(arty.guns, at0, hdg0, pos, hdgs, tpos, gp.traverse_speed, ESCAPE_DT) \
		if _guns_free(ctx) else PackedInt64Array()
	var live := 0
	var ready := PackedFloat32Array()
	for g in arty.guns:
		ready.append(INF if g.disabled else (1.0 - clampf(g.reload, 0.0, 1.0)) * gp.reload_time)
		live += 0 if g.disabled else 1
	var hp_t: float = maxf(t.health_controller.current_hp, 1.0)
	var dealt := PackedFloat32Array()
	dealt.resize(n)
	for k in mini(n, masks.size()):
		var time: float = (k + 1) * ESCAPE_DT
		var d: float = pos[k].distance_to(tpos[k])
		if d > gp._range or masks[k] == 0:
			continue
		# As dps_curve and the trade price it: the target angled to bear its guns, not as it lies now.
		var asp: float = BotBehavior.guns_bear_aspect(t)
		var per_gun: float = maxf(_expected(t, ship, d, asp).x, 0.0) * DamageExpectation.salvo_factor(ship, t, d, asp) \
			* gp.reload_time / maxf(live, 1)
		for i in ready.size():
			if ready[i] <= time and masks[k] & (1 << i) != 0:
				dealt[k] += per_gun
				ready[i] = time + gp.reload_time
	_add_torpedoes(ctx, t, at0, hdg0, pos, hdgs, tpos, dealt)
	var asp_t: float = BotBehavior.guns_bear_aspect(t)
	for k in n:
		var to_t: Vector2 = tpos[k] - pos[k]
		var brg: float = rad_to_deg(absf(angle_difference(hdgs[k], atan2(to_t.x, to_t.y))))
		dealt[k] += BotBehavior._secondary_dps(ship, t, to_t.length(), asp_t, brg) * ESCAPE_DT
	var sum := 0.0
	var kill_t := INF
	for k in n:
		sum += dealt[k]
		if sum >= hp_t:
			kill_t = (k + 1) * ESCAPE_DT
			break
	# Unlearned, as dealt is: the learned turn-out prices only one side of the trade.
	var taken := _track_incoming(track, maxf(ship.movement_controller.max_speed, 1.0), ship.team.team_id, {t.get_instance_id(): kill_t}, ship.ship_class)
	_add_secondaries_in(ship, track, t, kill_t, taken)
	var hp: float = maxf(ctx.behavior.trade_hp(), 1.0)
	_last_pred_d = minf(Array(dealt).reduce(func(a, x): return a + x, 0.0), hp_t)
	_last_pred_t = Array(taken).reduce(func(a, x): return a + x, 0.0)
	var cal := calibration(ship, t)
	for k in n:
		dealt[k] *= cal.x
		taken[k] *= cal.y
	var out := 0.0
	var inn := 0.0
	var die_k := -1
	var kill_k := -1
	for k in n:
		out += dealt[k]
		inn += taken[k]
		if out >= hp_t:
			kill_k = k
			break
		if inn >= hp:
			die_k = k
			break
	_last_dealt = minf(out / hp_t, 1.0)
	_last_taken = minf(inn / hp, 1.0)
	# Sunk inside the window: the sooner, the worse; past it, escapes and heals still count.
	var lost: float = (DUEL_WINDOW_S - (die_k + 1) * ESCAPE_DT) / DUEL_WINDOW_S if die_k >= 0 else 0.0
	# Sinking it inside the window: the sooner, the better; its guns and its friends' spotting stop with it.
	var won: float = (DUEL_WINDOW_S - (kill_k + 1) * ESCAPE_DT) / DUEL_WINDOW_S if kill_k >= 0 else 0.0
	_last_kill_s = (kill_k + 1) * ESCAPE_DT if kill_k >= 0 else INF
	_last_die_s = (die_k + 1) * ESCAPE_DT if die_k >= 0 else INF
	return _last_dealt - _last_taken - lost + won

## Secondaries of the shooters on us into `taken` along `track`, at the aspect we show each and the bearing it shows us,
## as _track_incoming books its guns: none behind land from it, the unspotted at DARK_TAKEN; `t` where it is going
## and silent once it sinks.
func _add_secondaries_in(ship: Ship, track: Array, t: Ship, kill_t: float, taken: PackedFloat32Array) -> void:
	var field: ReachField = NavigationMapManager.get_reach_field()
	var team_id: int = ship.team.team_id
	var masks := {}
	for sh in _shooters:
		var e: Ship = sh.get("ship")
		if not is_instance_valid(e) or not is_instance_valid(e.secondary_controller):
			continue
		var reach: float = e.secondary_controller.get_max_range()
		var w: float = DamageExpectation.DARK_TAKEN[mini(ship.ship_class, 2)] if sh.group == &"dark" else 1.0
		var e_hdg: float = atan2(-e.global_transform.basis.z.x, -e.global_transform.basis.z.z)
		var ep: Vector2 = sh.pos
		var ev := Vector2.ZERO
		if e == t:
			ep = Vector2(t.global_position.x, t.global_position.z)
			ev = Vector2(t.linear_velocity.x, t.linear_velocity.z)
		var bit: int = int(sh.bit)
		var stop: int = mini(track.size(), int(kill_t / ESCAPE_DT) if e == t and is_finite(kill_t) else track.size())
		for k in stop:
			var at: Vector2 = track[k][0]
			var to: Vector2 = ep + ev * (k + 1) * ESCAPE_DT - at
			if to.length() > reach:
				continue
			if bit >= 0 and field != null:
				if not masks.has(k):
					masks[k] = field.exposure_mask(team_id, at)
				if int(masks[k]) & (1 << bit) == 0:
					continue
			var a: float = rad_to_deg(absf(angle_difference(float(track[k][1]), atan2(to.x, to.y))))
			var brg: float = rad_to_deg(absf(angle_difference(e_hdg, atan2(-to.x, -to.y))))
			taken[k] += w * BotBehavior._secondary_dps(e, ship, to.length(), a, brg) * ESCAPE_DT

## Our spreads into `dealt`: each launcher once loaded and trained, its share of torpedo_curve (the
## target's dodge priced in) landing a run's time after launch.
func _add_torpedoes(ctx: SkillContext, t: Ship, at0: Vector2, hdg0: float, pos: PackedVector2Array, hdgs: PackedFloat32Array,
		tpos: PackedVector2Array, dealt: PackedFloat32Array) -> void:
	var tc: TorpedoController = _tubes(ctx)
	if tc == null:
		return
	var lp: TorpedoLauncherParams = tc.get_params()
	var masks: PackedInt64Array = StanceSim.track_bearing(tc.launchers, at0, hdg0, pos, hdgs, tpos, lp.traverse_speed, ESCAPE_DT)
	var speed: float = maxf(tc.get_torp_params().speed * _TorpedoManager.TORPEDO_SPEED_MULTIPLIER, 1.0)
	var curve := BotBehavior.torpedo_curve(ctx.ship, t)
	var ready := PackedFloat32Array()
	for l in tc.launchers:
		ready.append(INF if l.disabled else (1.0 - clampf(l.reload, 0.0, 1.0)) * lp.reload_time)
	for k in mini(dealt.size(), masks.size()):
		var time: float = (k + 1) * ESCAPE_DT
		var d: float = pos[k].distance_to(tpos[k])
		if d > tc.get_max_range() or masks[k] == 0:
			continue
		var land: int = k + int(d / speed / ESCAPE_DT)
		var per: float = BotBehavior._curve_at(curve, d) / tc.launchers.size()
		for i in ready.size():
			if ready[i] <= time and masks[k] & (1 << i) != 0:
				ready[i] = time + lp.reload_time
				if land < dealt.size():
					dealt[land] += per

## Raw HP landing on us at each step of `track`, as _track_slices books it (unspotted shooters at DARK_TAKEN).
func _track_incoming(track: Array, vmax: float, team_id: int, stops: Dictionary, ship_class: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(track.size())
	var end: float = track.size() * ESCAPE_DT
	var field: ReachField = NavigationMapManager.get_reach_field()
	var masks := {}
	for sh in _shooters:
		var t: float = float(sh.next)
		var stop: float = minf(end, float(stops.get(sh.id, INF)))
		var w: float = float(sh.weight) * (DamageExpectation.DARK_TAKEN[mini(ship_class, 2)] if sh.group == &"dark" else 1.0)
		while t < stop:
			var k: int = clampi(int(t / ESCAPE_DT), 0, track.size() - 1)
			var at: Vector2 = track[k][0]
			var to: Vector2 = sh.pos - at
			var bit: int = int(sh.bit)
			if bit >= 0 and field != null and not masks.has(k):
				masks[k] = field.exposure_mask(team_id, at)
			var shadowed: bool = bit >= 0 and field != null and int(masks[k]) & (1 << bit) == 0
			var reach: float = _reach_share(sh, to.length())
			if reach > 0.0 and not shadowed:
				var a: int = clampi(roundi(rad_to_deg(absf(angle_difference(float(track[k][1]), atan2(to.x, to.y)))) / ASPECT_STEP_DEG), 0, ASPECTS - 1)
				var row := _row_at(sh, to.length(), &"raw")
				if not row.is_empty():
					out[k] += float(sh.reload) * w * reach * row[a] * (1.0 - DODGE_AT_SPEED * float(track[k][2]) / vmax)
			t += float(sh.reload)
	var torps := _track_torps(track, track.size() * ESCAPE_DT)
	for k in out.size():
		out[k] += torps[k]
	return out


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
## threat_half_len of the heaviest shell last seen coming at us: how flat the made-up salvo falls.
var _fall_half: float = 30.0
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
		var f: float = clampf((_fall_half - 15.0) / 35.0, 0.05, 0.99)
		var along: float = half.y * f / sqrt(1.0 - f * f)
		var fall: Vector2 = (aim - from).normalized()
		var across := Vector2(-fall.y, fall.x)
		var shells: Array = []
		for i in SETUP_GRID:
			for j in SETUP_GRID:
				var p: Vector2 = aim + across * half.x * i + fall * along * j
				shells.append({"landing_x": p.x, "landing_z": p.y, "landing_vx": fall.x, "landing_vz": fall.y,
					"time_remaining": tof, "threat_half_len": _fall_half, "caliber": gp.shell1.caliber})
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
