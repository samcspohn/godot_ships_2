class_name SalvoClock
extends RefCounted

## The enemy's firing cycle, as this ship can observe it.
##
## Two post-processing skills need the same clock and must not disagree about
## it.  SkillBroadside wants to know when it is safe to unmask -- the reload gap
## after a salvo splashes -- and SkillEvade wants to know when it is under fire
## and how long the enemy's shells spend in the air.  Those are the same
## question asked from two sides, so they read one shared answer here rather
## than each running their own shell query and drifting apart.
##
## The cycle a competent player runs:
##
##   enemy fires ──flight──> shells land ──────reload gap──────> enemy fires
##                 INCOMING              WINDOW          INCOMING
##                 (angle, evade)        (unmask, fire)  (angle again)
##
## `phase` names which of those we are in.  QUIET means nobody observable is
## shooting at us, which is neither an invitation to show broadside (we may
## simply not have seen the salvo) nor a reason to evade.

enum Phase {
	## No tracked shells and no live shooter: nothing to time against.
	QUIET,
	## Enemy shells are in the air toward us.
	INCOMING,
	## A salvo has splashed and the next one is not yet airborne.
	WINDOW,
}

## How far out to look for shells aimed at us.  Wider than BotControllerV4's
## navigator feed (which only wants shells that can actually hit) because a
## salvo that misses by 800 m still means we are being shot at, and a bot that
## dodges well would otherwise conclude nobody was shooting.
const QUERY_RADIUS: float = 1200.0

## Stop trusting a measured flight time older than this.
const SOLUTION_MAX_AGE: float = 5.0

## Close the broadside window this long before the next salvo is due, to leave
## time to swing back to an angled heading.
const WINDOW_SAFETY_MARGIN: float = 2.0

## Fallback flight time when no ballistic solution is available.
const DEFAULT_TOF: float = 6.0

var phase: int = Phase.QUIET

## The enemy whose gunnery currently sets our timing: the one whose shells hurt
## most, soonest.  May be null.
var dominant: Ship = null

## Dominant shooter's full reload cycle, seconds.
var dominant_reload: float = 20.0

## Measured time of flight from the dominant shooter to us, seconds.  This is
## the ship's single most important number for evasion: it is how long the
## enemy's firing solution stays committed, and therefore how long any evasive
## state change has to survive to be worth making.
var dominant_tof: float = DEFAULT_TOF

## Horizontal dispersion of the dominant shooter's salvo at our range, metres.
## An evasive manoeuvre that displaces us less than this is not a dodge.
var dominant_dispersion: float = 200.0

## Bearing from us to the dominant shooter, radians.
var dominant_bearing: float = 0.0

## Seconds until the earliest tracked shell lands; INF when none are tracked.
var next_impact: float = INF

## True when anything is shooting at us -- tracked shells OR a live entry in
## active_shooters_at_me.  Survives the reload gap, unlike `next_impact`.
var under_fire: bool = false

## Wall-clock second at which the last splash was observed.
var last_splash: float = -INF

var _tracked: Dictionary = {}
var _solution_at: float = -INF


func tick(ship: Ship, server: GameServer, behavior: BotBehavior) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var my_team: int = ship.team.team_id if ship.team else -1

	# --- Track shells aimed near us, and notice when they stop existing ---
	var shells: Array = ProjectileManager.get_shells_near_position(
		Vector2(ship.global_position.x, ship.global_position.z), QUERY_RADIUS, my_team
	)
	var current: Dictionary = {}
	next_impact = INF
	for s in shells:
		current[s["shell_id"]] = true
		var t: float = s["time_remaining"]
		if t < next_impact:
			next_impact = t

	# A shell id that was in the list and no longer is has either landed or
	# expired.  Either way the salvo it belonged to is no longer a reason to
	# stay angled.
	for old_id in _tracked:
		if not current.has(old_id):
			last_splash = now
			break
	_tracked = current

	_pick_dominant(ship, server, behavior, now)

	under_fire = not shells.is_empty() or not behavior.active_shooters_at_me.is_empty()

	# --- Phase ---
	if not shells.is_empty():
		phase = Phase.INCOMING
	elif under_fire and now - last_splash <= window_duration():
		phase = Phase.WINDOW
	elif under_fire:
		# Under fire, no shells tracked, window expired: the next salvo is due
		# and we have no splash to time from.  Treat as INCOMING -- assuming we
		# are about to be shot at is the cheap mistake.
		phase = Phase.INCOMING
	else:
		phase = Phase.QUIET


## How long the broadside window stays open after a splash: the enemy's reload,
## less the flight time of the salvo we must be angled for again, less a margin
## to swing back.  Goes to zero at knife range -- correct, since there is no
## safe moment to show broadside to a ship that can hit you before you finish
## turning.
func window_duration() -> float:
	return maxf(dominant_reload - dominant_tof - WINDOW_SAFETY_MARGIN, 0.0)


## Whether it is safe to unmask right now.
func broadside_window_open() -> bool:
	return phase == Phase.WINDOW


func _pick_dominant(ship: Ship, server: GameServer, behavior: BotBehavior, now: float) -> void:
	if server == null:
		return
	var best_w: float = 0.0
	var best: Ship = null
	for enemy in server.get_valid_targets(ship.team.team_id):
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		if enemy.artillery_controller == null:
			continue
		var gp: GunParams = enemy.artillery_controller.get_params()
		var dist: float = ship.global_position.distance_to(enemy.global_position)
		if dist > gp._range:
			continue
		# Weighted the same way the rest of the behaviour weighs guns: caliber
		# squared for citadel potential, damage, rate of fire, proximity.  A
		# confirmed shooter outranks a merely-in-range one by an order of
		# magnitude -- it is the ship whose reload we actually need to track.
		var w: float = pow(gp.shell1.caliber / 100.0, 2.0)
		w *= gp.shell1.damage / 1000.0
		w *= 30.0 / maxf(gp.reload_time, 1.0)
		w *= 1.0 - clampf(dist / maxf(gp._range, 1.0), 0.0, 1.0)
		if behavior.active_shooters_at_me.has(enemy):
			w *= 10.0
		if w > best_w:
			best_w = w
			best = enemy

	if best == null:
		dominant = null
		return

	var changed: bool = best != dominant
	dominant = best
	dominant_reload = best.artillery_controller.get_params().reload_time

	var to_enemy: Vector3 = best.global_position - ship.global_position
	dominant_bearing = atan2(to_enemy.x, to_enemy.z)

	# The ballistic solve is the expensive part, so it is refreshed on a timer
	# rather than every tick -- range changes slowly compared to how fast this
	# runs, and a stale flight time by a fraction of a second changes nothing.
	if changed or now - _solution_at > SOLUTION_MAX_AGE:
		_solution_at = now
		_refresh_solution(ship, best)


func _refresh_solution(ship: Ship, enemy: Ship) -> void:
	var gp: GunParams = enemy.artillery_controller.get_params()
	var solution: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(
		enemy.global_position, ship.global_position, gp.shell1
	)
	var tof: float = solution[1] if solution.size() > 1 else -1.0
	dominant_tof = tof if tof > 0.0 else DEFAULT_TOF

	# Dispersion at this range, in metres of ellipse width, sampled off the same
	# curves the shooter's own gunnery uses.
	var dist: float = ship.global_position.distance_to(enemy.global_position)
	var t: float = maxf(dist / maxf(gp._range, 1.0), 0.0)
	dominant_dispersion = DispersionCalculator.sample_dispersion(gp.dispersion_, t, gp.max_h_disp)
