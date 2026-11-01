class_name SkillStance
extends BotSkill

## Owns heading and throttle while guns can reach us. The hull lies on the threat
## axis, bow or stern to the weighted fire: the end nearer the bow now, sailing
## ahead when the goal lies that way. When it lies the other way, the hull turns
## round only if the salvos landing on a simulated turn (the way the land
## allows) and run cost less than backing as far toward the goal. It leaves the axis only to bear loaded
## guns or tubes that would fire, by the least angle, and returns once they have.
## It stops only when that clears the citadel of every salvo in the air.

const ASPECT_STEP_DEG: float = 5.0
const ASPECTS: int = 37
const RANGE_BUCKET_M: float = 250.0
## In range of us, but not shown to be aiming here (axis_now's unseen contacts).
const BYSTANDER_WEIGHT: float = 0.5
## An unspotted ship deduced to be spotting us is this much likelier than _switch_chance to be shooting at us.
const SPOTTER_TARGET_GAIN: float = 2.0
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
const TURN_SPEED_FRAC: float = 0.75
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
## Shells landing this close in time, from this close in bearing, are one salvo.
const SALVO_GAP_S: float = 1.0
const SALVO_BEARING: float = deg_to_rad(10.0)
const MIN_SPREAD_M: float = 5.0
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
## Shooter instance id -> [range bucket, dps per aspect step then repairable parts].
var _tables: Dictionary = {}
## bearing, rows, weight, group (on, by, dark), spread (dark: believed-position radius), reload, next (seconds to its next landing).
var _shooters: Array[Dictionary] = []
## Ship-local citadel footprint: x across, y along the bow.
var _citadel := Rect2()


func apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	if intent == null or ctx.behavior.salvo_clock == null:
		reset()
		return intent
	var threatened: bool = _survey(ctx)
	if not threatened and not _quiet(ctx):
		reset()
		return intent
	var route: float = _route_bearing(intent, ctx)
	var hdg: float = ctx.behavior._get_ship_heading()
	_active = true
	_throttle = 1.0
	_on_route = not threatened
	_axis = INF
	if threatened:
		_lie_on_axis(ctx, intent, route, hdg)
		_duel(ctx, hdg)
		_jink(ctx, hdg)
	else:
		_duel_h = INF
	var fire_h: float = INF if is_finite(_duel_h) else _fire_heading(ctx, _heading if threatened else hdg, route, hdg)
	if is_finite(fire_h) and _clear_ahead(ctx, fire_h, _throttle < 0.0):
		_heading = fire_h
		_on_route = false
	elif threatened and not _clear_ahead(ctx, _heading, _throttle < 0.0):
		_on_route = true
	_juke = threatened and _throttle != 0.0 and _stop_dodges(ctx)
	if _juke:
		_throttle = 0.0
	if _on_route:
		return intent
	intent.target_heading = _heading
	intent.heading_weight = 1.0
	# A duel is fought under way: the navigator would brake for a destination stance is not sailing to.
	if is_finite(_duel_h):
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
	var lie: String = "route" if _on_route else ("stern-in" if _stern_in != _turning else "bow-in")
	if is_finite(_duel_h):
		lie = "DUEL " + _duel_name + (" JINK" if _jinking else "")
	return "Stance %s %.0f° %s%s%s%s | turn %.0f astern %.0f | %d guns on us" % [lie, rad_to_deg(_heading), gear,
		" TURNING" if _turning else "", " " + _fire if _fire != &"" else "", " JUKE" if _juke else "",
		_turn_cost, _astern_cost, _shooters.size()]


func reset() -> void:
	_duel_h = INF
	_duel_then = INF
	_duel_until = -INF
	_axis = INF
	_active = false
	_on_route = false
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
	var v: float = vmax * TURN_SPEED_FRAC
	var w: float = v / (maxf(p.turning_circle_radius, 1.0) * (p.slow_speed_turn_tightening + (1.0 - p.slow_speed_turn_tightening) * TURN_SPEED_FRAC))
	var want: float = minf(dist, ESCAPE_M)
	var start := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var clearance: float = ctx.behavior._get_ship_clearance()
	var reach: float = maxf(p.turning_circle_radius * CLEAR_AHEAD_TURNS, CLEAR_AHEAD_MIN_M)
	var left: float = angle_difference(hdg, far)
	var short: float = signf(left) if left != 0.0 else 1.0
	_turn_cost = INF
	_turn_hp = INF
	_turn_track = []
	_vmax = vmax
	var team_id: int = ctx.ship.team.team_id
	for way in [short, -short]:
		var swing: float = absf(left) if way == short else TAU - absf(left)
		var track := _escape_track(start, hdg, goal, want, vmax, vmax, w * way, p.rudder_response_time, swing, false, clearance, reach)
		if not track.is_empty():
			var cost := _priced(ctx, "turn", track, vmax, team_id, &"rows", INF)
			if cost < _turn_cost:
				_turn_cost = cost
				_swing_s = p.rudder_response_time + swing / maxf(w, 1e-3)
				_turn_hp = _priced(ctx, "turn", track, vmax, team_id, &"raw", _swing_s)
				_turn_track = track
	var back := _escape_track(start, near, goal, want, vmax, vmax * p.reverse_speed_ratio, 0.0, 0.0, 0.0, true, clearance, reach)
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


## Samples every ESCAPE_DT of [position, bow heading, speed] from `at`: the
## rudder lag, a swing of `swing` at `w` rad/s, then on at `run` until `want`
## along `goal` (astern: backing at `run` throughout). Empty when it runs aground
## in the swing or within `reach` after it: past that the route steers round land.
func _escape_track(at: Vector2, hdg: float, goal: float, want: float, vmax: float, run: float, w: float,
		lag: float, swing: float, astern: bool, clearance: float, reach: float) -> Array:
	var track: Array = []
	var gdir := Vector2(sin(goal), cos(goal))
	var start := at
	var turned: float = 0.0
	var after: float = 0.0
	var t: float = 0.0
	while t < ESCAPE_MAX_S:
		var speed: float = run
		if not astern and turned < swing:
			speed = vmax * TURN_SPEED_FRAC
			if t >= lag:
				var step: float = minf(absf(w) * ESCAPE_DT, swing - turned)
				hdg += step * signf(w)
				turned += step
		var dir := Vector2(sin(hdg), cos(hdg)) * (-1.0 if astern else 1.0)
		at += dir * speed * ESCAPE_DT
		t += ESCAPE_DT
		if turned >= swing:
			after += speed * ESCAPE_DT
		if after <= reach and NavigationMapManager.get_distance(Vector3(at.x, 0.0, at.y)) < clearance:
			return []
		track.append([at, hdg, speed])
		if turned >= swing and (at - start).dot(gdir) >= want:
			break
	return track


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
				var d: float = float(sh.reload) * float(sh.weight) * reach * sh.raw[a] * (1.0 - DODGE_AT_SPEED * float(track[k][2]) / vmax)
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
		stops: Dictionary = {}) -> float:
	var s := _track_slices(track, vmax, team_id, rows, window_s, stops)
	return DamageExpectation.price(ctx.ship, kind, s[0], s[1], s[2], minf(window_s, track.size() * ESCAPE_DT))


## [on, by, dark]: `rows` salvos along `track` (as _track_split) per DamageExpectation.TURNOUT_SLICES_S slice, from
## shooters on us, bystanders and unspotted enemies.
func _track_slices(track: Array, vmax: float, team_id: int, rows: StringName, window_s: float, stops: Dictionary = {}) -> Array:
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
				into[si] += reload * float(sh.weight) * reach * sh[rows][a] * (1.0 - DODGE_AT_SPEED * float(track[k][2]) / vmax)
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
	if not is_finite(h):
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
	return h


func _tube_heading(ctx: SkillContext, base: float, route: float, hdg: float) -> float:
	if not ctx.behavior.would_fire_torpedoes():
		return INF
	var loaded := _loaded_tubes(ctx)
	if loaded.is_empty():
		return INF
	var aim: Vector3 = ctx.behavior.torpedo_target_position
	return _nearest(loaded, Vector2(aim.x, aim.z), base, route, hdg, false)


## The least turn off `base` that bears every gun, when the guns idle there are loaded by the time it is made.
func _gun_heading(ctx: SkillContext, base: float, route: float, hdg: float) -> float:
	var t: Ship = ctx.target
	var arty = ctx.ship.artillery_controller
	if t == null or not is_instance_valid(t) or not t.is_alive() or arty == null or not _guns_free(ctx):
		return INF
	var gp: GunParams = arty.get_params()
	if ctx.ship.global_position.distance_to(t.global_position) > gp._range:
		return INF
	var at := Vector2(t.global_position.x, t.global_position.z)
	var h: float = _nearest(arty.guns, at, base, route, hdg, true)
	if not is_finite(h):
		return INF
	var bearing: PackedByteArray = StanceSim.bearing_mask(arty.guns, at, hdg, base)
	var turn_s: float = _turn_s(ctx, absf(angle_difference(hdg, h)))
	var idle: bool = false
	for i in arty.guns.size():
		var g = arty.guns[i]
		if g.disabled or bearing[i] == 1:
			continue
		if (1.0 - clampf(g.reload, 0.0, 1.0)) * gp.reload_time > turn_s:
			return INF
		idle = true
	return h if idle else INF


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


## True when a salvo in the air hits the citadel sailing on and every one misses it stopped.
func _stop_dodges(ctx: SkillContext) -> bool:
	var ship: Ship = ctx.ship
	var shells: Array = ProjectileManager.get_shells_near_position(
		Vector2(ship.global_position.x, ship.global_position.z), SHELL_QUERY_M, ship.team.team_id)
	if shells.is_empty():
		return false
	var salvos := _salvos(shells)
	var horizon: float = 0.0
	for s in salvos:
		horizon = maxf(horizon, s.t)
	var box := _citadel_box(ship)
	var on := _sail(ctx, _throttle, horizon)
	if not salvos.any(func(s): return _hits(s, on, box)):
		return false
	var stopped := _sail(ctx, 0.0, horizon)
	return not salvos.any(func(s): return _hits(s, stopped, box))


## Shells grouped into salvos, each an ellipse along its line of fall: centre c,
## travel dir, semi-axes a (along, stretched by how far the fall crosses a hull)
## and b (across), landing at t, sized to hold every shell in it.
static func _salvos(shells: Array) -> Array:
	shells.sort_custom(func(x, y): return float(x.time_remaining) < float(y.time_remaining))
	var groups: Array = []
	for s in shells:
		var from: float = atan2(-float(s.landing_vx), -float(s.landing_vz))
		var g: Dictionary = {}
		for o in groups:
			if float(s.time_remaining) - float(o.t0) <= SALVO_GAP_S and absf(angle_difference(from, o.from)) <= SALVO_BEARING:
				g = o
				break
		if g.is_empty():
			g = {"t0": float(s.time_remaining), "from": from, "shells": []}
			groups.append(g)
		g.shells.append(s)
	var out: Array = []
	for g in groups:
		var n: float = g.shells.size()
		var c := Vector2.ZERO
		var v := Vector2.ZERO
		var t: float = 0.0
		var reach: float = 0.0
		for s in g.shells:
			c += Vector2(s.landing_x, s.landing_z) / n
			v += Vector2(s.landing_vx, s.landing_vz)
			t += float(s.time_remaining) / n
			reach += float(s.threat_half_len) / n
		var d := v.normalized() if v.length_squared() > 1e-6 else Vector2(0.0, 1.0)
		var across := Vector2(-d.y, d.x)
		var sa: float = 0.0
		var sc: float = 0.0
		for s in g.shells:
			var w := Vector2(s.landing_x, s.landing_z) - c
			sa += w.dot(d) * w.dot(d) / n
			sc += w.dot(across) * w.dot(across) / n
		sa = maxf(sqrt(sa), MIN_SPREAD_M)
		sc = maxf(sqrt(sc), MIN_SPREAD_M)
		var k2: float = 4.0
		for s in g.shells:
			var w := Vector2(s.landing_x, s.landing_z) - c
			k2 = maxf(k2, pow(w.dot(d) / sa, 2.0) + pow(w.dot(across) / sc, 2.0))
		out.append({"c": c, "d": d, "t": t, "a": sqrt(k2) * sa + reach, "b": sqrt(k2) * sc})
	return out


## Hull track (x, z, heading) every SAIL_DT for `horizon`, holding _heading at `throttle`.
func _sail(ctx: SkillContext, throttle: float, horizon: float) -> PackedVector3Array:
	var ship: Ship = ctx.ship
	var mv = ship.movement_controller
	var p: MovementParams = mv._p()
	var vmax: float = maxf(mv.max_speed, 1.0)
	var radius: float = maxf(p.turning_circle_radius, 1.0)
	var accel: float = vmax / maxf(p.acceleration_time, 0.1) * SAIL_DT
	var hdg: float = ctx.behavior._get_ship_heading()
	var v: float = ship.linear_velocity.dot(Vector3(sin(hdg), 0.0, cos(hdg)))
	var target_v: float = -vmax * p.reverse_speed_ratio if throttle < 0.0 else vmax * throttle
	var omega := func(s: float) -> float:
		return absf(s) / (radius * (p.slow_speed_turn_tightening + (1.0 - p.slow_speed_turn_tightening) * clampf(absf(s) / vmax, 0.0, 1.0)))
	var w0: float = omega.call(v)
	var rudder: float = clampf(ship.angular_velocity.y / w0, -1.0, 1.0) if w0 > 1e-6 else 0.0
	var dr: float = SAIL_DT / maxf(p.rudder_response_time, 0.01)
	var pos := Vector2(ship.global_position.x, ship.global_position.z)
	var track := PackedVector3Array([Vector3(pos.x, pos.y, hdg)])
	var t: float = 0.0
	while t < horizon:
		v = minf(v + accel, target_v) if v < target_v else maxf(v - accel, target_v)
		var max_turn: float = omega.call(v) * SAIL_DT
		var want_r: float = clampf(angle_difference(hdg, _heading) / max_turn, -1.0, 1.0) if max_turn > 1e-6 else 0.0
		var r0: float = rudder
		rudder += clampf(want_r - r0, -dr, dr)
		hdg = wrapf(hdg + 0.5 * (r0 + rudder) * max_turn, -PI, PI)
		pos += Vector2(sin(hdg), cos(hdg)) * v * SAIL_DT
		track.append(Vector3(pos.x, pos.y, hdg))
		t += SAIL_DT
	return track


## Whether salvo `s` falls on the citadel `box` where `track` has the hull when it lands.
static func _hits(s: Dictionary, track: PackedVector3Array, box: Rect2) -> bool:
	var at: Vector3 = track[clampi(roundi(float(s.t) / SAIL_DT), 0, track.size() - 1)]
	var fwd := Vector2(sin(at.z), cos(at.z))
	var side := Vector2(-cos(at.z), sin(at.z))
	var d: Vector2 = s.d
	var across := Vector2(-d.y, d.x)
	var quad := PackedVector2Array()
	for k in [box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y)]:
		var w: Vector2 = Vector2(at.x, at.y) + side * k.x + fwd * k.y - s.c
		quad.append(Vector2(w.dot(d) / float(s.a), w.dot(across) / float(s.b)))
	if Geometry2D.is_point_in_polygon(Vector2.ZERO, quad):
		return true
	for i in 4:
		if Geometry2D.get_closest_point_to_segment(Vector2.ZERO, quad[i], quad[(i + 1) % 4]).length() <= 1.0:
			return true
	return false


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


## (dps, repairable dps) of the worse ammo for us, or (-1, 0) unknown.
static func _expected(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> Vector2:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	if e.is_empty():
		return Vector2(-1.0, 0.0)
	var he: bool = float(e.he_dps) > float(e.ap_dps)
	var dps: float = float(e.he_dps) if he else float(e.ap_dps)
	return Vector2(dps, dps * float(e.get("he_heal" if he else "ap_heal", 0.5)))


## Dps of the worse ammo for us: (citadel hits counted CITADEL_W extra, as it takes HP); the
## table already shrinks a wide pattern against a small hull. x -1 unknown.
static func _effective(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> Vector2:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	if e.is_empty():
		return Vector2(-1.0, -1.0)
	var ap := float(e.ap_dps) * (1.0 + CITADEL_W * float(e.ap_cit))
	var he := float(e.he_dps) * (1.0 + CITADEL_W * float(e.he_cit))
	return Vector2(ap, float(e.ap_dps)) if ap >= he else Vector2(he, float(e.he_dps))


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
	if not ship.is_detected() or ship.team == null or ctx.server == null:
		return false
	var weight := {}
	for s in ctx.behavior.active_shooters_at_me.keys():
		weight[s] = 1.0
	for s in ctx.behavior.salvo_clock.aimers:
		weight[s] = 1.0
	# Nobody on us: only guns the land is stopping count, so leaving a tuck is priced.
	var tucked: bool = weight.is_empty()
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
	for b in belief.values():
		var e: Ship = b.ship
		if weight.has(e) or int(b.source) == 0 or not is_instance_valid(e) or not e.is_alive() or e.artillery_controller == null:
			continue
		var r: float = e.artillery_controller.get_params()._range
		if (b.pos as Vector2).distance_to(at) - float(b.spread) > r + ESCAPE_M:
			continue
		# An inferred spotter is the ship that has us lit.
		var chance: float = minf(_switch_chance(ctx, e, b.pos) * (SPOTTER_TARGET_GAIN if int(b.source) == 3 else 1.0), 1.0)
		_add_shooter(ctx, e, b.pos, &"dark", chance, -1, float(b.spread), now)
	return _shooters.any(func(sh): return sh.group != &"dark")


func _add_shooter(ctx: SkillContext, s: Ship, pos: Vector2, group: StringName, weight: float, bit: int, spread: float, now: float) -> void:
	var to: Vector2 = pos - Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var reach: float = s.artillery_controller.get_params()._range
	var rows := _rows(ctx.ship, s, minf(to.length(), reach))
	if rows.is_empty():
		return
	var reload: float = maxf(s.artillery_controller.get_params().reload_time, 0.1)
	var next: float = ctx.behavior.salvo_clock.next_landing(s, now) if group != &"dark" else INF
	_shooters.append({"id": s.get_instance_id(), "bearing": atan2(to.x, to.y), "rows": rows, "raw": _tables[s.get_instance_id()][2],
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
	var cached: Array = _tables.get(id, [])
	if not cached.is_empty() and int(cached[0]) == bucket:
		return cached[1]
	var row := PackedFloat32Array()
	var raw := PackedFloat32Array()
	row.resize(ASPECTS)
	raw.resize(ASPECTS)
	var cal: float = BotGunnery.calibration(shooter, ship, range_m)
	for i in ASPECTS:
		var e := _effective(ship, shooter, range_m, i * ASPECT_STEP_DEG)
		if e.x < 0.0:
			row = PackedFloat32Array()
			raw = PackedFloat32Array()
			break
		row[i] = e.x * cal
		raw[i] = e.y * cal
	_tables[id] = [bucket, row, raw]
	return row


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
	var now: float = SimClock.now()
	if now < _duel_until:
		if is_finite(_duel_h) and not _duel_wins and ctx.behavior._active_skill_name == &"Disengage":
			_duel_h = INF
		if is_finite(_duel_h):
			_take_duel()
		return
	var at := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var tp := Vector2(t.global_position.x, t.global_position.z)
	var to_t: float = atan2(tp.x - at.x, tp.y - at.y)
	var away: float = wrapf(to_t + PI, -PI, PI)
	# [heading, astern, then heading, after s]. Ties go to the first: bow-in shows the least.
	var options := {}
	var side: float = signf(angle_difference(to_t, hdg)) if angle_difference(to_t, hdg) != 0.0 else 1.0
	var bow_in: float = wrapf(to_t + side * DUEL_ANGLE, -PI, PI)
	options["bow-in"] = [bow_in, false, INF, 0.0]
	var bs := _nearer(StanceSim.nearest_bearing(arty.guns, tp, hdg, hdg, true), hdg)
	if is_finite(bs):
		options["broadside"] = [bs, false, INF, 0.0]
	options["away"] = [away, false, INF, 0.0]
	var out := INF
	if tc != null:
		out = _nearer(StanceSim.nearest_bearing(tc.launchers, tp, hdg, away, false), away)
		if is_finite(out):
			options["torp-out"] = [out, false, INF, 0.0]
	# Its next salvo: show the bow until it lands, then turn to launch (or bear the guns).
	var due: float = ctx.behavior.salvo_clock.next_landing(t, now)
	var then: float = out if is_finite(out) else bs
	if is_finite(due) and due > 0.0 and due < DUEL_WINDOW_S and is_finite(then):
		options["angle-then-turn"] = [bow_in, false, then, due]
	options["lie"] = [_heading, _throttle < 0.0, INF, 0.0]
	var tracks := {}
	var lethal := {}
	for name in options:
		var o: Array = options[name]
		var track := _option_track(ctx, hdg, float(o[0]), bool(o[1]), float(o[2]), float(o[3]))
		if not track.is_empty():
			tracks[name] = track
			lethal[name] = _lethal(ctx, t, track)
	# A salvo that can sink us rules an option out, unless every option shows one.
	var safe: bool = lethal.values().has(false)
	_pred.clear()
	var wins := {}
	var best := "lie"
	var best_score := -INF
	for name in tracks:
		var sc: float = -INF if safe and lethal[name] else _duel_score(ctx, t, tracks[name], bool(options[name][1]))
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
	# Getting out, a duel we would lose is no reason to turn back: Disengage keeps its heading.
	if ctx.behavior._active_skill_name == &"Disengage" and not _duel_wins:
		best = "lie"
	_duel_name = best
	if _pred.has(best):
		_probe(ctx, t, _pred[best])
	var key := "%s>%s" % [Ship.ShipClass.keys()[ctx.ship.ship_class], Ship.ShipClass.keys()[t.ship_class]]
	var row: Dictionary = duel_stats.get_or_add(key, {})
	row[best] = int(row.get(best, 0)) + 1
	_duel_h = INF if best == "lie" else float(options[best][0])
	_duel_then = float(options[best][2]) if best != "lie" else INF
	_duel_turn_at = now + float(options[best][3])
	_duel_until = now + maxf(minf(_next_gun_s(arty), float(options[best][3]) if float(options[best][3]) > 0.0 else INF), DUEL_HOLD_MIN_S)
	if is_finite(_duel_h):
		_take_duel()

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
	_throttle = 1.0
	_turning = false

## Seconds until our first gun loads.
static func _next_gun_s(arty) -> float:
	var reload: float = arty.get_params().reload_time
	var s := INF
	for g in arty.guns:
		if not g.disabled:
			s = minf(s, (1.0 - clampf(g.reload, 0.0, 1.0)) * reload)
	return s if is_finite(s) else reload

## DUEL_WINDOW_S of sailing `h` (backing on it when `astern`), turning onto it first; with `then`, turning
## onto that after `after_s`.
func _option_track(ctx: SkillContext, hdg: float, h: float, astern: bool, then: float = INF, after_s: float = 0.0) -> Array:
	var mv = ctx.ship.movement_controller
	var p: MovementParams = mv._p()
	var vmax: float = maxf(mv.max_speed, 1.0)
	var v: float = vmax * TURN_SPEED_FRAC
	var w: float = v / (maxf(p.turning_circle_radius, 1.0) * (p.slow_speed_turn_tightening + (1.0 - p.slow_speed_turn_tightening) * TURN_SPEED_FRAC))
	var start := Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z)
	var reach: float = maxf(p.turning_circle_radius * CLEAR_AHEAD_TURNS, CLEAR_AHEAD_MIN_M)
	var swing: float = absf(angle_difference(hdg, h))
	var way: float = signf(angle_difference(hdg, h)) if swing > 0.0 else 1.0
	var run: float = vmax * p.reverse_speed_ratio if astern else vmax
	var goal: float = wrapf(h + PI, -PI, PI) if astern else h
	var track := _escape_track(start, hdg, goal, DUEL_WINDOW_S * vmax * 2.0, vmax, run, w * way,
		p.rudder_response_time, swing, astern, ctx.behavior._get_ship_clearance(), reach)
	if is_finite(then) and not track.is_empty():
		var k: int = clampi(int(after_s / ESCAPE_DT), 0, track.size() - 1)
		var last: Array = track[k]
		var turn: float = absf(angle_difference(float(last[1]), then))
		var w2: float = signf(angle_difference(float(last[1]), then)) if turn > 0.0 else 1.0
		var rest := _escape_track(last[0], float(last[1]), then, DUEL_WINDOW_S * vmax * 2.0, vmax, vmax, w * w2,
			p.rudder_response_time, turn, false, ctx.behavior._get_ship_clearance(), reach)
		if rest.is_empty():
			return []
		track = track.slice(0, k + 1) + rest
	return track.slice(0, int(DUEL_WINDOW_S / ESCAPE_DT))

func _duel_score(ctx: SkillContext, t: Ship, track: Array, _astern: bool) -> float:
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
	var sum := 0.0
	var kill_t := INF
	for k in n:
		sum += dealt[k]
		if sum >= hp_t:
			kill_t = (k + 1) * ESCAPE_DT
			break
	# Unlearned, as dealt is: the learned turn-out prices only one side of the trade.
	var taken := _track_incoming(track, maxf(ship.movement_controller.max_speed, 1.0), ship.team.team_id, {t.get_instance_id(): kill_t}, ship.ship_class)
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
				out[k] += float(sh.reload) * w * reach * sh.raw[a] * (1.0 - DODGE_AT_SPEED * float(track[k][2]) / vmax)
			t += float(sh.reload)
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


## Off a broadside, away or torp-out duel heading: weave JINK_ANGLE_MIN..MAX either side, changing side every
## JINK_HOLD swings (at least JINK_MIN_S..JINK_MAX_S) at random and at once when a salvo of the dominant shooter's is
## seen in the air, so a lead taken from our velocity when they fire is wrong when it lands. Only for a hull whose swing
## (rudder lag and JINK_ANGLE_MAX) takes at most JINK_SWING_MAX_S.
const JINK_ANGLE_MIN: float = deg_to_rad(15.0)
const JINK_ANGLE_MAX: float = deg_to_rad(30.0)
const JINK_MIN_S: float = 4.0
const JINK_MAX_S: float = 8.0
const JINK_HOLD := Vector2(1.5, 3.0)
const JINK_SWING_MAX_S: float = 8.0
const JINK_OPTIONS := ["broadside", "away", "torp-out"]
var _jink_side: float = 0.0
var _jink_angle: float = 0.0
var _jink_until: float = -INF
var _jink_salvo: float = -INF
var _jinking: bool = false
## "<class>" -> why the jink did not run (or "jink"), per stance tick, for match metrics.
static var jink_stats: Dictionary = {}

func _jink_why(ctx: SkillContext, why: String) -> void:
	var row: Dictionary = jink_stats.get_or_add(Ship.ShipClass.keys()[ctx.ship.ship_class], {})
	row[why] = int(row.get(why, 0)) + 1

func _jink(ctx: SkillContext, hdg: float) -> void:
	_jinking = false
	if not is_finite(_duel_h) or _duel_name not in JINK_OPTIONS or OS.has_environment("STANCE_NO_JINK"):
		_jink_why(ctx, "no_duel" if not is_finite(_duel_h) else "option_" + _duel_name)
		return
	var mv = ctx.ship.movement_controller
	var p: MovementParams = mv._p()
	var w: float = maxf(ctx.ship.linear_velocity.length(), 1.0) / maxf(p.turning_circle_radius, 1.0)
	var swing: float = p.rudder_response_time + JINK_ANGLE_MAX / w
	if swing > JINK_SWING_MAX_S:
		_jink_why(ctx, "sluggish")
		return
	var now: float = SimClock.now()
	var sc: SalvoClock = ctx.behavior.salvo_clock
	var s: Ship = sc.dominant
	var land: float = sc.next_landing(s, now) if s != null and is_instance_valid(s) else INF
	var new_salvo: bool = is_finite(land) and land > 0.0 and land <= sc.dominant_tof and absf(now + land - _jink_salvo) > 1.0
	if new_salvo:
		_jink_salvo = now + land
	if now >= _jink_until or new_salvo:
		_jink_side = -_jink_side if _jink_side != 0.0 else (1.0 if angle_difference(hdg, _duel_h) <= 0.0 else -1.0)
		_jink_angle = randf_range(JINK_ANGLE_MIN, JINK_ANGLE_MAX)
		_jink_until = now + randf_range(maxf(JINK_MIN_S, swing * JINK_HOLD.x), maxf(JINK_MAX_S, swing * JINK_HOLD.y))
	_heading = wrapf(_duel_h + _jink_side * _jink_angle, -PI, PI)
	_jinking = true
	_jink_why(ctx, "jink")
