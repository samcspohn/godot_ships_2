class_name SkillStance
extends BotSkill

## The heading and gear that show every gun on us the least, weighted by what
## each one does to this hull at each aspect (the damage table), traded
## against route progress and turning. At a station the hold creeps along the
## heading, so closing on the shooters is charged instead of progress.
## SkillEvade weaves inside the cone of headings nearly as cheap.

## Choice index for following the route's own heading, whatever it shows.
const FREE: int = -2

const STEP: float = deg_to_rad(5.0)
const HEADINGS: int = 72
const ASPECT_STEP_DEG: float = 5.0
const ASPECTS: int = 37
const RANGE_BUCKET_M: float = 250.0
## Headings costing no more than this over the chosen one are its cone.
const CONE_TOL: float = 0.25
const MIN_CONE: float = deg_to_rad(5.0)
const MAX_CONE: float = deg_to_rad(45.0)
## Weight of incoming damage, as a share of all-broadside, against progress.
const DAMAGE_COST: float = 1.0
## Cost of a second spent en route, in the same units as broadside damage.
const TIME_COST: float = 0.5
const MIN_PROGRESS: float = 0.05
const REVERSE_FACTOR: float = 0.5
## Cost of a half-circle of turning, in units of full progress.
const TURN_COST: float = 0.5
## Held at a station: sitting astern, and creeping straight at the guns.
const ASTERN_COST: float = 1.0
const CLOSING_COST: float = 0.5
const SWITCH_MARGIN: float = 0.25
## Taking the helm from the route must buy at least this much.
const FREE_MARGIN: float = 0.15
## The held heading follows the geometry one STEP a tick, for at least this gain:
## several shooters close together make a flat optimum it would otherwise wander.
const TRACK_GAIN: float = 0.02

var _heading: float = 0.0
var _astern_held: bool = false
var _has_choice: bool = false
var _hold_until: float = -INF
var _active: bool = false
var _cone: float = MIN_CONE
## Shooter instance id -> [range bucket, PackedFloat32Array dps per aspect step].
var _tables: Dictionary = {}

var _bearings: PackedFloat32Array = PackedFloat32Array()
var _rows: Array[PackedFloat32Array] = []
var _broadside: float = 0.0


func apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	var clock: SalvoClock = ctx.behavior.salvo_clock
	if intent == null or clock == null or not _survey(ctx):
		reset()
		return intent
	var here: float = ctx.behavior._get_ship_heading()
	var route: float = _route_bearing(intent, ctx)
	var best_h: float = 0.0
	var best_astern: bool = false
	var best: float = -INF
	for i in HEADINGS:
		var h: float = wrapf(-PI + i * STEP, -PI, PI)
		for astern in [false, true]:
			var s: float = _score(h, astern, here, route)
			if s > best:
				best = s
				best_h = h
				best_astern = astern
	var free: float = _score(route, false, here, route) + FREE_MARGIN if is_finite(route) else -INF
	var now: float = SimClock.now()
	if _has_choice and _heading != FREE:
		_track_held(here, route)
	var held: float = -INF
	if _has_choice:
		held = free if _heading == FREE else _score(_heading, _astern_held, here, route)
	var top: float = maxf(best, free)
	# Held for a flight time: flipping ends mid-salvo shows the side the angle was hiding.
	if not _has_choice or not is_finite(held) or (now >= _hold_until and top > held + SWITCH_MARGIN):
		_has_choice = true
		_hold_until = now + maxf(clock.dominant_tof, 1.0)
		if free >= best:
			_heading = FREE
		else:
			_heading = best_h
			_astern_held = best_astern
	if _heading == FREE:
		_active = false
		return intent
	_active = true
	_cone = _cone_at(_heading)
	intent.target_heading = _heading
	intent.heading_weight = 1.0
	intent.force_reverse = _astern_held
	return intent


func reset() -> void:
	_has_choice = false
	_hold_until = -INF
	_active = false


## `h` pulled back inside the held heading's cone; unchanged when idle.
func clamp_heading(h: float) -> float:
	if not _active:
		return h
	return wrapf(_heading + clampf(angle_difference(_heading, h), -_cone, _cone), -PI, PI)


## Incoming damage per second from `shooter` at `aspect_deg` off our bow, -1 unknown.
static func dps_at(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> float:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	return maxf(float(e.ap_dps), float(e.he_dps)) if not e.is_empty() else -1.0


## Bearings and per-aspect dps rows of every gun on us; false when none is known.
func _survey(ctx: SkillContext) -> bool:
	var ship: Ship = ctx.ship
	var clock: SalvoClock = ctx.behavior.salvo_clock
	var seen := {}
	var shooters: Array[Ship] = []
	var pool: Array = clock.aimers.duplicate()
	pool.append_array(ctx.behavior.active_shooters_at_me.keys())
	pool.append(clock.dominant)
	for s in pool:
		if s is Ship and is_instance_valid(s) and s.is_alive() and not seen.has(s):
			seen[s] = true
			shooters.append(s)
	_bearings = PackedFloat32Array()
	_rows = []
	_broadside = 0.0
	for s in shooters:
		var to: Vector3 = s.global_position - ship.global_position
		var row := _table(ship, s, Vector2(to.x, to.z).length())
		if row.is_empty():
			continue
		_bearings.append(atan2(to.x, to.z))
		_rows.append(row)
		_broadside += row[ASPECTS / 2]
	return _broadside > 0.0


func _table(ship: Ship, shooter: Ship, range_m: float) -> PackedFloat32Array:
	var id := shooter.get_instance_id()
	var bucket := int(range_m / RANGE_BUCKET_M)
	var cached: Array = _tables.get(id, [])
	if not cached.is_empty() and int(cached[0]) == bucket:
		return cached[1]
	var row := PackedFloat32Array()
	for i in ASPECTS:
		var d := dps_at(ship, shooter, range_m, i * ASPECT_STEP_DEG)
		if d < 0.0:
			row = PackedFloat32Array()
			break
		row.append(d)
	_tables[id] = [bucket, row]
	return row


## Incoming damage at heading `h`, as a share of every shooter seeing our beam.
func _cost(h: float) -> float:
	var total: float = 0.0
	for k in _rows.size():
		var aspect: float = rad_to_deg(absf(angle_difference(h, _bearings[k])))
		total += _rows[k][clampi(roundi(aspect / ASPECT_STEP_DEG), 0, ASPECTS - 1)]
	return total / _broadside


## Mean cosine between `motion` and the shooters, weighted by their broadside dps.
func _closing(motion: float) -> float:
	var total: float = 0.0
	for k in _rows.size():
		total += _rows[k][ASPECTS / 2] * cos(angle_difference(motion, _bearings[k]))
	return total / _broadside


func _score(h: float, astern: bool, here: float, route: float) -> float:
	var s: float = -TURN_COST * absf(angle_difference(here, h)) / PI
	var motion: float = wrapf(h + PI, -PI, PI) if astern else h
	if is_finite(route):
		var progress: float = cos(angle_difference(motion, route)) * (REVERSE_FACTOR if astern else 1.0)
		return s - (DAMAGE_COST * _cost(h) + TIME_COST) / maxf(progress, MIN_PROGRESS)
	return s - DAMAGE_COST * _cost(h) - (ASTERN_COST if astern else 0.0) - CLOSING_COST * _closing(motion)


## Slides the held heading onto a better neighbour, as the shooters move.
func _track_held(here: float, route: float) -> void:
	var best: float = _score(_heading, _astern_held, here, route) + TRACK_GAIN
	var pick: float = _heading
	for k in [-1, 1]:
		var h: float = wrapf(_heading + k * STEP, -PI, PI)
		var s: float = _score(h, _astern_held, here, route)
		if s > best:
			best = s
			pick = h
	_heading = pick


func _cone_at(h: float) -> float:
	var limit: float = _cost(h) * (1.0 + CONE_TOL)
	var half: float = 0.0
	while half + STEP <= MAX_CONE:
		var next: float = half + STEP
		if _cost(h + next) > limit or _cost(h - next) > limit:
			break
		half = next
	return maxf(half, MIN_CONE)


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

