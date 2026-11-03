class_name EnemyForecast
extends RefCounted

## Where a sighted enemy will be: its speed held, its turn fading out, steered along any coast ahead of it.

const TIMES: PackedFloat32Array = [0.0, 10.0, 20.0, 30.0, 45.0, 60.0]
## Cover and fight stations must hold this long after we arrive.
const HOLD_S := 20.0
const STEP_S := 2.0
const TURN_KEEP_S := 10.0
const LOOK_S := 20.0
const LOOK_MIN_M := 400.0
const COAST_M := 400.0
const GRAD_M := 50.0
## Tangent plus this much of the outward normal, so a coast-follower drifts off the rock.
const OFF_COAST := 0.3
const REFRESH_S := 1.0

## Ship -> [next refresh, forecast]
var _held: Dictionary = {}
## Ship -> [next refresh, forecast, sighting time]: from its last-known position.
var _sighted: Dictionary = {}

## `enemy`'s positions at TIMES, refreshed at most every REFRESH_S.
func of(enemy: Ship, now: float) -> PackedVector2Array:
	var h: Array = _held.get(enemy, [])
	if not h.is_empty() and now < float(h[0]):
		return h[1]
	var v := Vector2(enemy.linear_velocity.x, enemy.linear_velocity.z)
	var fc := ahead(Vector2(enemy.global_position.x, enemy.global_position.z), v, enemy.angular_velocity.y)
	_held[enemy] = [now + REFRESH_S, fc]
	return fc

## `enemy` from its last sighting, `seen_at` seconds of match clock old by now, at TIMES from now; empty past the horizon.
func of_sighting(enemy: Ship, pos: Vector2, vel: Vector2, rot: float, seen_at: float, now: float) -> PackedVector2Array:
	var age: float = now - seen_at
	if age > TIMES[-1]:
		return PackedVector2Array()
	var h: Array = _sighted.get(enemy, [])
	if not h.is_empty() and now < float(h[0]) and float(h[2]) == seen_at:
		return h[1]
	var fc := ahead(pos, vel, rot, age)
	_sighted[enemy] = [now + REFRESH_S, fc, seen_at]
	return fc

func forget(enemy: Ship) -> void:
	_held.erase(enemy)
	_sighted.erase(enemy)

## Positions at `skip` + TIMES seconds from `p`, `v`, `rot`.
static func ahead(p: Vector2, v: Vector2, rot: float, skip: float = 0.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	var speed: float = v.length()
	var hdg: float = atan2(v.x, v.y)
	var t := 0.0
	var next := 0
	if skip <= 0.0:
		out.append(p)
		next = 1
	while next < TIMES.size():
		var dir := Vector2(sin(hdg), cos(hdg))
		var look: Vector2 = p + dir * maxf(speed * LOOK_S, LOOK_MIN_M)
		if speed > 0.5 and _land(look) < COAST_M:
			var g := _grad(look)
			if g != Vector2.ZERO:
				var tan := Vector2(-g.y, g.x)
				if tan.dot(dir) < 0.0:
					tan = -tan
				dir = (tan + g * OFF_COAST).normalized()
				hdg = atan2(dir.x, dir.y)
				rot = 0.0
		var dt: float = minf(STEP_S, skip + TIMES[next] - t)
		var q: Vector2 = p + dir * speed * dt
		if _land(q) > 0.0:
			p = q
		hdg += rot * dt
		rot *= exp(-dt / TURN_KEEP_S)
		t += dt
		if t >= skip + TIMES[next] - 1e-3:
			out.append(p)
			next += 1
	return out

## Forecasts of `belief` enemy-major for the nav opts, then `extra` stationary points.
static func pack(belief: Array[Dictionary], extra: PackedVector2Array = PackedVector2Array()) -> PackedVector2Array:
	var out := PackedVector2Array()
	for b in belief:
		if b.has("fc"):
			out.append_array(b.fc)
		else:
			for i in TIMES.size():
				out.append(b.pos)
	for p in extra:
		for i in TIMES.size():
			out.append(p)
	return out

## Enemy `i` of a packed forecast `s` seconds ahead.
static func at(fc: PackedVector2Array, i: int, s: float) -> Vector2:
	var n: int = TIMES.size()
	var j: int = 1
	while j < n - 1 and TIMES[j] < s:
		j += 1
	var f: float = clampf((s - TIMES[j - 1]) / (TIMES[j] - TIMES[j - 1]), 0.0, 1.0)
	return fc[i * n + j - 1].lerp(fc[i * n + j], f)

static func _land(p: Vector2) -> float:
	return NavigationMapManager.get_distance(Vector3(p.x, 0.0, p.y))

## Away from land.
static func _grad(p: Vector2) -> Vector2:
	var g := Vector2(_land(p + Vector2(GRAD_M, 0.0)) - _land(p - Vector2(GRAD_M, 0.0)),
		_land(p + Vector2(0.0, GRAD_M)) - _land(p - Vector2(0.0, GRAD_M)))
	return g.normalized() if g.length_squared() > 1e-6 else Vector2.ZERO
