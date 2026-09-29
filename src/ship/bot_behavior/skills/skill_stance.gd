class_name SkillStance
extends BotSkill

## Bow or stern within CONE of the dominant shooter while its salvo is due:
## whichever of the four (end, gear) choices keeps the route moving, backing up
## when the route runs away from the bow. SkillEvade weaves inside the cone.

const CONE: float = deg_to_rad(30.0)

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


func apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	var clock: SalvoClock = ctx.behavior.salvo_clock
	if intent == null or clock == null or clock.dominant == null or not is_instance_valid(clock.dominant):
		reset()
		return intent
	var threat: float = clock.dominant_bearing
	var here: float = ctx.behavior._get_ship_heading()
	var route: float = _route_bearing(intent, ctx)
	var scores: Array[float] = []
	var headings: Array[float] = []
	var best: int = 0
	for c in 4:
		var h: float = _heading(threat, c, route if is_finite(route) else here)
		var s: float = -TURN_COST * absf(angle_difference(here, h)) / PI
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
	return wrapf(_centre + clampf(angle_difference(_centre, h), -CONE, CONE), -PI, PI)


## 0 bow ahead, 1 bow astern, 2 stern ahead, 3 stern astern.
static func _end(threat: float, c: int) -> float:
	return threat if c < 2 else wrapf(threat + PI, -PI, PI)


## Heading inside the chosen end's cone nearest the way the hull must point to
## make `route` progress in that gear.
static func _heading(threat: float, c: int, route: float) -> float:
	var centre := _end(threat, c)
	var want: float = wrapf(route + PI, -PI, PI) if _astern(c) else route
	return wrapf(centre + clampf(angle_difference(centre, want), -CONE, CONE), -PI, PI)


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
