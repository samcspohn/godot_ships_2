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
## In range of us, but not shown to be aiming here.
const BYSTANDER_WEIGHT: float = 0.5
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
var _astern_cost: float = 0.0
var _priced_at: float = -INF
var _juke: bool = false
## &"", &"guns" or &"torps".
var _fire: StringName = &""
var _fire_deadline: float = INF
var _fire_cooldown: float = -INF
## Shooter instance id -> [range bucket, dps per aspect step then repairable parts].
var _tables: Dictionary = {}
## bearing, rows, weight, reload, next (seconds to its next landing).
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
	var fire_h: float = _fire_heading(ctx, _heading if threatened else hdg, route, hdg)
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
	return "Stance %s %.0f° %s%s%s%s | turn %.0f astern %.0f | %d guns on us" % [lie, rad_to_deg(_heading), gear,
		" TURNING" if _turning else "", " " + _fire if _fire != &"" else "", " JUKE" if _juke else "",
		_turn_cost, _astern_cost, _shooters.size()]


func reset() -> void:
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
		_turning = _turning or _turn_beats_astern(ctx, hdg, near, far, goal, Vector2(to.x, to.z).length())
		end = far if _turning else near
		astern = not _turning
	var motion: float = wrapf(end + PI, -PI, PI) if astern else end
	_heading = wrapf(end + clampf(angle_difference(motion, goal), -AXIS_CONE, AXIS_CONE), -PI, PI)
	_throttle = -1.0 if astern else 1.0


## Turning round, either way the land leaves clear, against backing, each run
## until as far toward the goal: the salvos that land, in effective HP.
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
	for way in [short, -short]:
		var swing: float = absf(left) if way == short else TAU - absf(left)
		var track := _escape_track(start, hdg, goal, want, vmax, vmax, w * way, p.rudder_response_time, swing, false, clearance, reach)
		if not track.is_empty():
			_turn_cost = minf(_turn_cost, _track_taken(track, vmax, ctx.ship.team.team_id))
	var back := _escape_track(start, near, goal, want, vmax, vmax * p.reverse_speed_ratio, 0.0, 0.0, 0.0, true, clearance, reach)
	_astern_cost = _track_taken(back, vmax, ctx.ship.team.team_id) if not back.is_empty() else INF
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
func _track_taken(track: Array, vmax: float, team_id: int) -> float:
	var end: float = track.size() * ESCAPE_DT
	var sum: float = 0.0
	var field: ReachField = NavigationMapManager.get_reach_field()
	var masks := {}
	for sh in _shooters:
		var reload: float = sh.reload
		var t: float = float(sh.next)
		while t < end:
			var k: int = clampi(int(t / ESCAPE_DT), 0, track.size() - 1)
			var at: Vector2 = track[k][0]
			var to: Vector2 = sh.pos - at
			var bit: int = int(sh.bit)
			if bit >= 0 and field != null and not masks.has(k):
				masks[k] = field.exposure_mask(team_id, at)
			var shadowed: bool = bit >= 0 and field != null and int(masks[k]) & (1 << bit) == 0
			if to.length() <= float(sh.range) and not shadowed:
				var a: int = clampi(roundi(rad_to_deg(absf(angle_difference(float(track[k][1]), atan2(to.x, to.y)))) / ASPECT_STEP_DEG), 0, ASPECTS - 1)
				sum += reload * float(sh.weight) * sh.rows[a] * (1.0 - DODGE_AT_SPEED * float(track[k][2]) / vmax)
			t += reload
	return sum


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
		var arty = ctx.ship.artillery_controller
		_fire_cooldown = now + (arty.get_params().reload_time if want == &"guns" else TORP_RETRY_S)
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


## Dps of the worse ammo for us with citadel hits counted CITADEL_W extra; the
## table already shrinks a wide pattern against a small hull. -1 unknown.
static func _effective(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> float:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	if e.is_empty():
		return -1.0
	return maxf(float(e.ap_dps) * (1.0 + CITADEL_W * float(e.ap_cit)), float(e.he_dps) * (1.0 + CITADEL_W * float(e.he_cit)))


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


## Every gun that can reach us, weighted by how sure we are it is on us. False
## while unseen or while nothing shoots or aims here.
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
		weight[e] = BYSTANDER_WEIGHT
	if weight.is_empty():
		return false
	var now: float = SimClock.now()
	for s in weight.keys():
		if not (s is Ship) or not is_instance_valid(s) or not s.is_alive():
			continue
		var to: Vector3 = s.global_position - ship.global_position
		var rows := _rows(ship, s, Vector2(to.x, to.z).length())
		if rows.is_empty():
			continue
		var reload: float = maxf(s.artillery_controller.get_params().reload_time, 0.1)
		var next: float = ctx.behavior.salvo_clock.next_landing(s, now)
		var b: int = ids.find(s.get_instance_id())
		_shooters.append({"bearing": atan2(to.x, to.z), "rows": rows, "weight": float(weight[s]), "bit": b if b < 63 else -1,
			"threat": _threat(s, ship, Vector2(to.x, to.z).length()),
			"pos": Vector2(s.global_position.x, s.global_position.z), "range": s.artillery_controller.get_params()._range,
			"reload": reload, "next": next if is_finite(next) else reload * 0.5})
	return not _shooters.is_empty()


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


## Effective incoming dps per aspect step from `shooter`, cached per range bucket; empty unknown.
func _rows(ship: Ship, shooter: Ship, range_m: float) -> PackedFloat32Array:
	var id := shooter.get_instance_id()
	var bucket := int(range_m / RANGE_BUCKET_M)
	var cached: Array = _tables.get(id, [])
	if not cached.is_empty() and int(cached[0]) == bucket:
		return cached[1]
	var row := PackedFloat32Array()
	row.resize(ASPECTS)
	for i in ASPECTS:
		var e := _effective(ship, shooter, range_m, i * ASPECT_STEP_DEG)
		if e < 0.0:
			row = PackedFloat32Array()
			break
		row[i] = e
	_tables[id] = [bucket, row]
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
