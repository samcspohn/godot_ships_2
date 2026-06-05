class_name ReplayBallistics

## Static helper that wraps ProjectilePhysicsWithDragV2 for replay shell rendering.
##
## The game runs projectile physics at TIME_MULTIPLIER × real (wall-clock) time,
## so replay-relative elapsed seconds are scaled before being passed to the
## physics function.  All position results exactly match what the server computed.
##
## Usage:
##   var params := ReplayBallistics.make_shell_params(drag_coeff)
##   var pos    := ReplayBallistics.position_at(muzzle, vel, params, t_real)
##   var alive  := ReplayBallistics.is_shell_alive(muzzle, vel, params, fire_ts, current_ts)

## Projectiles run at this multiple of real (wall-clock) time.
## Matches ProjectileManager.get_shell_time_multiplier() in the live game.
const TIME_MULTIPLIER: float = 2.0

## Any shell whose Y position is below this is considered to have hit the water.
## Set to the visible water surface (y = 0) so shells are removed the moment
## they cross the waterline rather than lingering up to 5 m below it.
const WATER_LEVEL: float = 0.0

## Hard upper bound on physics flight time before a shell is considered dead.
const MAX_FLIGHT_SECONDS: float = 60.0


## Build a minimal ShellParams with only drag set.
## The drag setter auto-computes vt and tau, which is all
## ProjectilePhysicsWithDragV2 needs for position/velocity calculations.
## Call once per shell at spawn time and cache the result.
static func make_shell_params(drag: float) -> ShellParams:
	var p := ShellParams.new()
	p.drag = drag
	return p


## Returns the world-space position of a shell at `t_flight_real` seconds of
## real (wall-clock) elapsed time since it was fired.
##
## Delegates directly to ProjectilePhysicsWithDragV2 — the same function used
## by the live game — so the arc matches the recorded trajectory exactly.
static func position_at(muzzle: Vector3, vel: Vector3, params: ShellParams,
		t_flight_real: float) -> Vector3:
	if t_flight_real <= 0.0:
		return muzzle
	var t_physics: float = t_flight_real * TIME_MULTIPLIER
	return ProjectilePhysicsWithDragV2.calculate_position_at_time(muzzle, vel, t_physics, params)


## Returns true if the shell is still in the air at `current_ts`.
## Both timestamps are replay-relative wall-clock seconds.
static func is_shell_alive(muzzle: Vector3, vel: Vector3, params: ShellParams,
		fire_ts: float, current_ts: float) -> bool:
	var t_real: float = current_ts - fire_ts
	if t_real < 0.0:
		return false
	if t_real * TIME_MULTIPLIER > MAX_FLIGHT_SECONDS:
		return false
	var pos: Vector3 = position_at(muzzle, vel, params, t_real)
	return pos.y >= WATER_LEVEL


## Convenience: position from a SHELL_FIRED event dict at current_ts.
static func shell_position_from_event(evt: Dictionary, params: ShellParams,
		current_ts: float) -> Vector3:
	if not evt.has("muzzle_pos") or not evt.has("velocity"):
		push_warning("ReplayBallistics.shell_position_from_event: incomplete event dict")
		return Vector3.ZERO
	var t_real: float = current_ts - evt.get("timestamp", 0.0)
	return position_at(evt["muzzle_pos"], evt["velocity"], params, t_real)
