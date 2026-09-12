class_name SkillEvade
extends BotSkill

## Post-processing skill that makes a ship under gunfire expensive to predict.
##
## Usage:  intent = _skill_evade.apply(intent, ctx, params)
##
## This replaces shell evasion in the navigator, which optimised the wrong
## thing.  "Reach the waypoint as fast as possible, subject to not being hit"
## has a degenerate optimum -- stop -- and the enemy's fire control closes the
## loop around it: the bot slows, the next salvo lands short, and the locally
## optimal response to a short salvo is to keep the speed change.  Bots
## converged on zero speed, which is the easiest state in the game to hit.
##
## The objective here is inverted.  The mission track is held; what varies is
## how predictable the ship's state is at the enemy's impact time.  Stopping is
## then the worst answer available rather than the best, because a stopped ship
## is maximally predictable.
##
## TWO MODES, chosen by what the hull can actually do inside one enemy time of
## flight.  The exported movement params make this stark:
##
##   hull        rudder hard-over   360 deg    accel spool   displaces in 20 s
##   Shimakaze   3.5 s              37 s       9 s           ~500 m
##   DesMoines   5 s                55 s       15 s          ~300 m
##   Yamato      15 s               72 s       40 s          ~145 m
##   H45         15 s               218 s      50 s          ~40 m
##
## A serpentine CYCLE costs four rudder-response-times at minimum (two
## reversals).  That is 14 s for a Shimakaze and 60 s for a Yamato, against a
## battleship flight time of 15-25 s.  A battleship physically cannot weave
## against incoming fire, and its speed cannot move either: 40 s of engine spool
## does not change where the ship is in 20 s.
##
##   DISPLACEMENT -- when achievable cross-track inside one flight time exceeds
##   the shooter's dispersion at this range.  Genuinely not being where the
##   shell was aimed.  Weaves the destination and varies speed.
##
##   PRESENTATION -- otherwise.  The ship cannot leave the ellipse, so it stops
##   trying and works on the shells that WILL arrive instead: it holds an
##   angled aspect so they bounce.  The navigator's own hit model prices this at
##   GRAZE_MIN_FACTOR 0.15 end-on versus 1.0 broadside -- a 6.6x damage swing,
##   far more than any displacement a battleship could buy.  Speed is left
##   alone; a hull that needs 40 s to spool has no speed play to make.
##
## COMMITMENT is the property that keeps the old failure from coming back.  A
## chosen serpentine phase is held for at least one enemy flight time.  Deciding
## faster than the enemy can re-aim is exactly what produced the paralysis.

enum Mode { PRESENTATION, DISPLACEMENT }

## Serpentine amplitude for presentation mode: the ship yaws +/- this much about
## its base heading.  Enough to keep a meaningful angle on and to deny a steady
## aspect, without throwing the mission track away or costing so much heading
## that the guns stop bearing.
const PRESENTATION_AMPLITUDE: float = deg_to_rad(30.0)

## Displacement mode can afford a much wider swing -- the whole point is to be
## somewhere else, and a destroyer reverses course inside a battleship's flight
## time anyway.
const DISPLACEMENT_AMPLITUDE: float = deg_to_rad(60.0)

## A serpentine half-cycle cannot be shorter than the time to swing the rudder
## from one side to the other, or the ship simply tracks the average and sails
## straight.  Multiplied in a little slack so the ship actually reaches the
## commanded rudder before being asked to reverse it.
const HALF_CYCLE_RUDDER_FACTOR: float = 2.2

## Speed scalars for displacement mode.  Kept well above zero: the point is to
## be unpredictable, not slow, and a bot that bleeds speed under fire dies to
## the next salvo rather than this one.
const SPEED_MULT_MIN: float = 0.55
const SPEED_MULT_MAX: float = 1.0

## A hull whose engine spool exceeds this multiple of the enemy flight time
## cannot change its position by varying throttle, so it does not try.
const SPEED_USEFUL_SPOOL_RATIO: float = 1.5

## Heading authority each mode claims.  Displacement asks for more because the
## weave is the whole manoeuvre; presentation asks for less because it only
## needs the aspect, and the ship should still be going somewhere.
const DISPLACEMENT_HEADING_WEIGHT: float = 0.75
const PRESENTATION_HEADING_WEIGHT: float = 0.5

## Phase state.  Advanced by wall clock so it stays continuous regardless of the
## staggered cadence the behaviour ladder runs on.
var _phase: float = 0.0
var _last_tick: float = -1.0

## Which way the current half-cycle is swinging, and when it may next flip.
var _swing: float = 1.0
var _swing_locked_until: float = -INF

## Cached for get_speed_multiplier(), which BotControllerV4 reads every frame
## while this skill only runs on the intent cadence.
var _speed_mult: float = 1.0
var _speed_active: bool = false

var _mode: int = Mode.PRESENTATION


func apply(intent: NavIntent, ctx: SkillContext, params: Dictionary) -> NavIntent:
	if intent == null:
		return null
	var ship: Ship = ctx.ship
	if ship == null or not is_instance_valid(ship):
		return intent

	var clock: SalvoClock = ctx.behavior.salvo_clock
	if clock == null or not clock.under_fire:
		reset()
		return intent

	# The navigator has hard-overridden navigation to dodge a torpedo and has
	# solved for a specific arc.  Scaling its throttle behind its back, or
	# dragging its destination sideways, would invalidate the dodge it just
	# computed -- and a torpedo is worth more than a shell.  Stand down; the
	# navigator's own candidate set varies speed against shells as a tiebreak
	# inside the override.
	if ctx.navigator != null and ctx.navigator.is_torpedo_override_active():
		_speed_active = false
		_speed_mult = 1.0
		return intent

	var movement = ship.movement_controller
	if movement == null:
		return intent
	var mp: MovementParams = movement._p()
	if mp == null:
		return intent

	var now: float = Time.get_ticks_msec() / 1000.0
	var tof: float = maxf(clock.dominant_tof, 1.0)

	_mode = _select_mode(ship, mp, clock, tof)
	_advance_phase(mp, tof, now)

	if _mode == Mode.DISPLACEMENT:
		_apply_displacement(intent, ctx, ship, mp, params)
	else:
		_apply_presentation(intent, ctx, ship, clock, params)

	return intent


## Speed scalar for BotControllerV4's per-frame throttle shaping.  1.0 when this
## skill is not driving speed.
func speed_multiplier() -> float:
	return _speed_mult if _speed_active else 1.0


func current_mode() -> int:
	return _mode


func reset() -> void:
	_speed_active = false
	_speed_mult = 1.0
	_swing_locked_until = -INF


# ---------------------------------------------------------------------------
# Mode selection
# ---------------------------------------------------------------------------

## Displacement is only worth attempting when the ship can leave the shooter's
## dispersion ellipse inside one flight time.  Below that it is spending heading
## and speed to move around inside the same ellipse, which buys nothing and
## costs the angle that would have made the hits bounce.
func _select_mode(ship: Ship, mp: MovementParams, clock: SalvoClock, tof: float) -> int:
	var reach: float = _cross_track_reach(ship, mp, tof)
	return Mode.DISPLACEMENT if reach > clock.dominant_dispersion else Mode.PRESENTATION


## Cross-track distance this hull can generate in `tof` seconds from a standing
## rudder, in metres.
##
## The rudder ramps linearly (ShipMovementV4 move_towards the commanded value
## over rudder_response_time), and turn rate is speed/radius scaled by rudder,
## so heading integrates as a ramp then a constant.  Cross-track is then the
## sagitta of the turn, R * (1 - cos(theta)) -- exact for the circular part and
## conservative during the ramp, which is the right way to be wrong here.
func _cross_track_reach(ship: Ship, mp: MovementParams, tof: float) -> float:
	var radius: float = maxf(mp.turning_circle_radius, 1.0)
	var speed: float = maxf(ship.linear_velocity.length(), 1.0)
	var rrt: float = maxf(mp.rudder_response_time, 0.001)
	var omega_max: float = speed / radius

	var theta: float = 0.0
	if tof <= rrt:
		# Still ramping: integral of omega_max * (t/rrt) dt
		theta = omega_max * tof * tof / (2.0 * rrt)
	else:
		theta = omega_max * rrt * 0.5 + omega_max * (tof - rrt)
	theta = minf(theta, PI)
	return radius * (1.0 - cos(theta))


# ---------------------------------------------------------------------------
# Serpentine phase
# ---------------------------------------------------------------------------

## Half-cycle length: one enemy flight time, so the ship's state at impact is
## never the state the solution was computed against -- but floored by what the
## rudder can physically follow, because commanding a weave faster than the
## rudder can reverse produces a straight line with extra steps.
func _half_cycle(mp: MovementParams, tof: float) -> float:
	var rudder_floor: float = mp.rudder_response_time * HALF_CYCLE_RUDDER_FACTOR
	return maxf(tof, rudder_floor)


func _advance_phase(mp: MovementParams, tof: float, now: float) -> void:
	var half: float = _half_cycle(mp, tof)
	if _last_tick < 0.0:
		_last_tick = now
	var dt: float = clampf(now - _last_tick, 0.0, 1.0)
	_last_tick = now

	_phase += dt * PI / maxf(half, 0.1)
	if _phase > TAU:
		_phase -= TAU

	# Commitment: the swing direction may only flip once the previous half-cycle
	# has run its course.  Without this the ship re-decides every intent tick as
	# the shell picture refreshes, which is precisely the behaviour that let a
	# single enemy freeze a bot in place.
	if now >= _swing_locked_until:
		var wave_slope: float = cos(_phase)
		var want: float = 1.0 if wave_slope >= 0.0 else -1.0
		if want != _swing:
			_swing = want
			_swing_locked_until = now + half


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

## Apply the serpentine on the HEADING CHANNEL ONLY.
##
## Nothing here touches target_position, and that is deliberate.  An oscillating
## destination wrecks path-finding: BotControllerV4 forces _execute_nav_intent()
## the moment the destination moves PATH_SIGNIFICANT_MOVE, and navigate_to()
## unconditionally calls run_plan_sync() -- so weaving the destination bought a
## full synchronous replan against a genuinely different goal on every single
## intent tick.  Weaving the heading instead leaves the destination stable, so
## _is_intent_similar() keeps holding (it compares position and hold_radius, not
## heading), navigate_to() runs only on its own PATH_UPDATE_INTERVAL cadence,
## and the planner retargets rather than replanning.  The skill's route and
## destination survive intact; only the course along it oscillates.
func _weave(intent: NavIntent, ctx: SkillContext, ship: Ship, amplitude: float, weight: float) -> void:
	var base: float = _base_heading(intent, ship)
	intent.target_heading = ctx.behavior._normalize_angle(base + sin(_phase) * amplitude)
	intent.heading_weight = maxf(intent.heading_weight, weight)


## What the weave oscillates about.
##
## When the upstream skill asserted a heading (heading_weight > 0) that heading
## is its actual intent and the weave centres on it.  When it did not, its
## target_heading is only an arrival preference -- the navigator ignores it en
## route -- so centring on it would activate a heading the skill never meant to
## be pursued and pull the ship off its route.  The bearing to the destination
## is that skill's real course, so the weave centres on that instead: hold the
## track, oscillate about it.
func _base_heading(intent: NavIntent, ship: Ship) -> float:
	if intent.heading_weight > 0.001:
		return intent.target_heading
	var to_dest: Vector3 = intent.target_position - ship.global_position
	to_dest.y = 0.0
	if to_dest.length_squared() > 1.0:
		return atan2(to_dest.x, to_dest.z)
	return intent.target_heading


## Presentation: yaw +/- PRESENTATION_AMPLITUDE about the ship's own course.
##
## The centre is deliberately the ship's existing intent rather than a
## threat-derived angle of our own.  SkillBroadside does the real angling work
## against the danger centre, and two post-processors both computing "the right
## angle" from scratch is how they end up fighting each other.
func _apply_presentation(intent: NavIntent, ctx: SkillContext, ship: Ship, clock: SalvoClock, params: Dictionary) -> void:
	var amplitude: float = params.get("presentation_amplitude", PRESENTATION_AMPLITUDE)
	# Scaled by how imminent the threat is: a ship with shells in the air commits
	# to the angle, a ship in the reload gap lets navigation lead again.
	var urgency: float = 1.0 if clock.phase == SalvoClock.Phase.INCOMING else 0.5
	_weave(intent, ctx, ship, amplitude, PRESENTATION_HEADING_WEIGHT * urgency)

	_speed_active = false
	_speed_mult = 1.0


## Displacement: swing the course either side of the mission track and vary
## speed, both on the same committed phase so they reinforce rather than cancel.
func _apply_displacement(intent: NavIntent, ctx: SkillContext, ship: Ship, mp: MovementParams, params: Dictionary) -> void:
	var amplitude: float = params.get("displacement_amplitude", DISPLACEMENT_AMPLITUDE)
	_weave(intent, ctx, ship, amplitude, DISPLACEMENT_HEADING_WEIGHT)

	# Speed, a quarter cycle out of phase with the weave so the ship is not
	# simultaneously slowest and straightest -- that combination is the one an
	# enemy fire-control solution handles best.
	var spool: float = mp.acceleration_time
	var tof: float = maxf(ctx.behavior.salvo_clock.dominant_tof, 1.0)
	if spool <= tof * SPEED_USEFUL_SPOOL_RATIO:
		var wave: float = (cos(_phase) + 1.0) * 0.5
		_speed_mult = lerpf(SPEED_MULT_MIN, SPEED_MULT_MAX, wave)
		_speed_active = true
	else:
		_speed_active = false
		_speed_mult = 1.0
