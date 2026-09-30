class_name SkillStance
extends BotSkill

## Bow or stern at the dominant shooter while its salvo is due: whichever of
## the four (end, gear) choices keeps the route moving at the least incoming
## damage, backing up when the route runs away from the bow. Each end's cone is
## read off the damage table: a few degrees off the bow can already let raking
## AP through, so no fixed angle is safe. SkillEvade weaves inside the cone.

## Presentation offsets off each end sampled from the damage table, degrees.
const OFFSETS: Array[float] = [0.0, 5.0, 10.0, 15.0, 20.0, 30.0]
## An end's cone is the widest offset costing no more than this over its best.
const CONE_TOL: float = 0.25
const DEFAULT_CONE: float = deg_to_rad(10.0)
const MIN_CONE: float = deg_to_rad(2.0)
## Weight of an end's incoming damage, as a share of broadside's, against progress.
const DAMAGE_COST: float = 1.0

## Progress made going astern is worth this much of the same progress ahead.
const REVERSE_FACTOR: float = 0.5
## Cost of a half-circle of turning, in units of full progress.
const TURN_COST: float = 0.5
## A new choice must beat the held one by this much before the ship commits to it.
const SWITCH_MARGIN: float = 0.25

var _choice: int = -1
var _hold_until: float = -INF
var _centre: float = 0.0
var _active: bool = false
## Per end (bow, stern): cone half-width, and best damage over broadside's.
var _cones: Array[float] = [DEFAULT_CONE, DEFAULT_CONE]
var _cost: Array[float] = [0.0, 0.0]


func apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	var clock: SalvoClock = ctx.behavior.salvo_clock
	if intent == null or clock == null or clock.dominant == null or not is_instance_valid(clock.dominant):
		reset()
		return intent
	var threat: float = clock.dominant_bearing
	var here: float = ctx.behavior._get_ship_heading()
	var route: float = _route_bearing(intent, ctx)
	_survey(ctx.ship, clock.dominant)
	var scores: Array[float] = []
	var headings: Array[float] = []
	var best: int = 0
	for c in 4:
		var h: float = _heading(threat, c, route if is_finite(route) else here, _cones[_end_index(c)])
		var s: float = -TURN_COST * absf(angle_difference(here, h)) / PI - DAMAGE_COST * _cost[_end_index(c)]
		if is_finite(route):
			var progress: float = cos(angle_difference(h, route))
			s += -progress * REVERSE_FACTOR if _astern(c) else progress
		elif _astern(c):
			s -= 1.0
		scores.append(s)
		headings.append(h)
		if s > scores[best]:
			best = c
	var now: float = SimClock.now()
	# Held for a flight time: flipping ends mid-salvo shows the side the angle was hiding.
	if _choice < 0 or (now >= _hold_until and scores[best] > scores[_choice] + SWITCH_MARGIN):
		_choice = best
		_hold_until = now + maxf(clock.dominant_tof, 1.0)
	_centre = _end(threat, _choice)
	_active = true
	intent.target_heading = headings[_choice]
	intent.heading_weight = 1.0
	intent.force_reverse = _astern(_choice)
	return intent


func reset() -> void:
	_choice = -1
	_hold_until = -INF
	_active = false


## `h` pulled back inside the cone this tick's stance chose; unchanged when idle.
func clamp_heading(h: float) -> float:
	if not _active:
		return h
	var cone: float = _cones[_end_index(_choice)]
	return wrapf(_centre + clampf(angle_difference(_centre, h), -cone, cone), -PI, PI)


## Incoming damage per second from `shooter` at `aspect_deg` off our bow, -1 unknown.
static func dps_at(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> float:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	return maxf(float(e.ap_dps), float(e.he_dps)) if not e.is_empty() else -1.0


func _survey(ship: Ship, shooter: Ship) -> void:
	var range_m: float = ship.global_position.distance_to(shooter.global_position)
	var broadside: float = dps_at(ship, shooter, range_m, 90.0)
	for end in 2:
		var dps: Array[float] = []
		for off in OFFSETS:
			dps.append(dps_at(ship, shooter, range_m, off if end == 0 else 180.0 - off))
		var floor_dps: float = dps.min()
		if floor_dps < 0.0 or broadside <= 0.0:
			_cones[end] = DEFAULT_CONE
			_cost[end] = 0.0
			continue
		var cone: float = 0.0
		for i in OFFSETS.size():
			if dps[i] > floor_dps * (1.0 + CONE_TOL):
				break
			cone = OFFSETS[i]
		_cones[end] = maxf(deg_to_rad(cone), MIN_CONE)
		_cost[end] = floor_dps / broadside


## 0 bow ahead, 1 bow astern, 2 stern ahead, 3 stern astern.
static func _end(threat: float, c: int) -> float:
	return threat if c < 2 else wrapf(threat + PI, -PI, PI)


static func _end_index(c: int) -> int:
	return 0 if c < 2 else 1


## Heading inside the chosen end's cone nearest the way the hull must point to
## make `route` progress in that gear.
static func _heading(threat: float, c: int, route: float, cone: float) -> float:
	var centre := _end(threat, c)
	var want: float = wrapf(route + PI, -PI, PI) if _astern(c) else route
	return wrapf(centre + clampf(angle_difference(centre, want), -cone, cone), -PI, PI)


static func _astern(c: int) -> bool:
	return c % 2 == 1


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
