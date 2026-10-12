class_name SalvoClock
extends RefCounted

## The enemy's firing cycle, as this ship can observe it: when each shooter's
## next salvo lands, who aims here, and the main shooter's flight time.

## How far out to look for shells aimed at us.
const QUERY_RADIUS: float = 1200.0

## Stop trusting a measured flight time older than this.
const SOLUTION_MAX_AGE: float = 5.0

## Fallback flight time when no ballistic solution is available.
const DEFAULT_TOF: float = 6.0

## An enemy whose aim point is this close is aiming at us (the 6th sense test).
const AIM_RADIUS: float = 500.0

## The enemy whose gunnery currently sets our timing: the one whose shells hurt
## most, soonest.  May be null.
var dominant: Ship = null

## Measured time of flight from the dominant shooter to us, seconds: how long
## its firing solution stays committed.
var dominant_tof: float = DEFAULT_TOF

## Enemies we can see with their guns on us, gathered only while we are
## detected. A player sees no more than this without the 6th sense skill.
var aimers: Array[Ship] = []

var _solution_at: float = -INF
## Ship -> seconds until its earliest shell in the air lands.
var _in_air: Dictionary = {}
## Ship -> when its latest observed salvo lands (SimClock seconds).
var _landed: Dictionary = {}

## A shell is credited to the visible enemy within this of the bearing it comes from.
const SOURCE_MATCH: float = deg_to_rad(10.0)


func tick(ship: Ship, server: GameServer, behavior: BotBehavior) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	var now: float = SimClock.now()
	var my_team: int = ship.team.team_id if ship.team else -1

	var shells: Array = ProjectileManager.get_shells_near_position(
		Vector2(ship.global_position.x, ship.global_position.z), QUERY_RADIUS, my_team
	)
	_attribute(ship, server, shells, now)
	_gather_aimers(ship, server)
	_pick_dominant(ship, server, behavior, now)


## Seconds until `shooter`'s next salvo lands here: the one in the air, else a
## reload after the last; INF when it has not been seen firing at us lately.
func next_landing(shooter: Ship, now: float) -> float:
	if _in_air.has(shooter):
		return _in_air[shooter]
	if not _landed.has(shooter) or shooter.artillery_controller == null:
		return INF
	var reload: float = shooter.artillery_controller.get_params().reload_time
	var due: float = float(_landed[shooter]) + reload - now
	return maxf(due, 0.0) if due > -reload else INF


func _attribute(ship: Ship, server: GameServer, shells: Array, now: float) -> void:
	_in_air.clear()
	if shells.is_empty() or server == null:
		return
	var enemies: Array[Ship] = server.get_valid_targets(ship.team.team_id)
	var bearings := PackedFloat32Array()
	for e in enemies:
		var to: Vector3 = e.global_position - ship.global_position
		bearings.append(atan2(to.x, to.z))
	for s in shells:
		var from: float = atan2(-float(s["landing_vx"]), -float(s["landing_vz"]))
		var best := -1
		var best_d: float = SOURCE_MATCH
		for i in enemies.size():
			var d: float = absf(angle_difference(from, bearings[i]))
			if d < best_d:
				best_d = d
				best = i
		if best < 0:
			continue
		var e: Ship = enemies[best]
		var t: float = s["time_remaining"]
		_in_air[e] = minf(_in_air.get(e, INF), t)
		_landed[e] = maxf(_landed.get(e, -INF), now + t)


func _gather_aimers(ship: Ship, server: GameServer) -> void:
	aimers.clear()
	if server == null or not ship.is_detected():
		return
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	for enemy in server.get_valid_targets(ship.team.team_id):
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive() or enemy.artillery_controller == null:
			continue
		var aim: Vector3 = enemy.artillery_controller.aim_point
		if Vector2(aim.x, aim.z).distance_to(here) < AIM_RADIUS:
			aimers.append(enemy)


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
		elif aimers.has(enemy):
			w *= 5.0
		if w > best_w:
			best_w = w
			best = enemy

	if best == null:
		dominant = null
		return

	var changed: bool = best != dominant
	dominant = best

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
