class_name FleetFrame
extends RefCounted

## Where the battle is, right now, derived only from current ship positions
## rather than a flank side rolled once at spawn - so it stays correct as the
## shape of the fight changes. Distinct from EnemyPresumption's spawn geometry:
## that anchors unseen ships to the spawn line, and must not be fed this frame
## or the guesses would chase our own fleet's facing.

## Below this separation the fleets are effectively coincident (melee, last
## ships circling) and there's no meaningful axis, so fall back to spawn_forward.
const MIN_SEPARATION: float = 500.0

## Floor on lateral spread so a bunched-up team doesn't divide by ~0 in side_of().
const MIN_SPREAD: float = 2000.0

## Gaussian falloff (not a cutoff) so a ship crossing the locality radius
## doesn't pop in/out of the local axis in one frame. Tail matters more than
## near-focus shape here: with 1/(1+r^2) a distant six-ship line still dragged
## the local axis 74 degrees off target in test_fleet_frame's pocket case.
## `scale` is the e-folding distance (0.37 at 1x, 0.018 at 2x, 0.0001 at 3x).
const LOCALITY_FLOOR: float = 0.0001

static func locality_weight(d: float, scale: float) -> float:
	if scale <= 0.0:
		return 1.0
	var r: float = d / scale
	return maxf(exp(-r * r), LOCALITY_FLOOR)


## Deadband (in units of team spread) inside which a position belongs to
## everyone. Needed because this frame is stateless and rotates continuously -
## a hard sign comparison would flip a ship's flank every time the axis
## crossed it, which is the thrash a stored flank identity used to prevent.
const SIDE_DEADBAND: float = 0.35

## True when the poles resolved far enough apart to trust forward/right;
## false means the frame fell back to the spawn axis.
var live: bool = false

var friendly_center: Vector3 = Vector3.ZERO
var enemy_center: Vector3 = Vector3.ZERO
## Unit vector from our fleet toward theirs.
var forward: Vector3 = Vector3(0.0, 0.0, -1.0)
## Unit vector 90 degrees clockwise of forward. Positive side_of() is this way.
var right: Vector3 = Vector3(1.0, 0.0, 0.0)
## RMS (not full-span) spread along `right`, so an outermost ship's death
## doesn't jump-rescale everyone else's side.
var spread: float = MIN_SPREAD
var separation: float = 0.0


## Build the frame for `my_team`. `presumed` is the caller's own
## EnemyPresumption.contacts(), passed per-bot rather than shared team-wide
## since aptitude decides whether a bot believes in unseen ships.
##
## `locality` == 0 gives a global frame (whole battle; "is this my business,
## which flank am I holding"); > 0 weights ships by nearness to `focus`
## (the engagement in front of me; "which side of THIS fight do I take" -
## needed so an isolated pincer reads as two opposite sides instead of
## whatever the far-away main-line axis says). Global frame should decide
## involvement, local frame should decide execution - swapping them either
## makes a ship chase whatever's nearest, or puts two ships on the same side
## because the fleet axis calls them both "right flank".
static func build(my_team: int, server, presumed: Array, spawn_forward: Vector3,
		focus: Vector3 = Vector3.ZERO, locality: float = 0.0) -> FleetFrame:
	var f := FleetFrame.new()
	if server == null:
		return f

	# Self included in the friendly pole: excluding self from our own pole
	# makes two ships converging on one enemy read as an asymmetric +1/-1 pair
	# that both chase the same side, instead of the pincer it actually is.
	var fsum := Vector3.ZERO
	var fweight := 0.0
	var friendly: Array = server.get_team_ships(my_team)
	for s in friendly:
		if not is_instance_valid(s) or not s.is_alive():
			continue
		var w: float = locality_weight(s.global_position.distance_to(focus), locality)
		fsum += s.global_position * w
		fweight += w
	if fweight <= 0.00001:
		return f
	f.friendly_center = fsum / fweight
	f.friendly_center.y = 0.0

	# Enemy pole blends observation and presumption rather than switching to
	# confirmed-only on first contact, which would pivot the whole team onto
	# one spotted ship and drop the rest of the presumed line.
	var esum := Vector3.ZERO
	var eweight := 0.0
	for s in server.get_valid_targets(my_team):
		if not is_instance_valid(s) or not s.is_alive():
			continue
		var w: float = locality_weight(s.global_position.distance_to(focus), locality)
		esum += s.global_position * w
		eweight += w
	for guess in presumed:
		var gp: Vector3 = guess.position
		var w: float = maxf(EnemyPresumption.certainty(guess), 0.05) \
			* locality_weight(gp.distance_to(focus), locality)
		esum += gp * w
		eweight += w
	if eweight > 0.00001:
		f.enemy_center = esum / eweight
		f.enemy_center.y = 0.0

	var axis: Vector3 = f.enemy_center - f.friendly_center
	axis.y = 0.0
	if eweight > 0.00001 and axis.length() >= MIN_SEPARATION \
			and not (is_nan(axis.x) or is_nan(axis.z)):
		f.separation = axis.length()
		f.forward = axis / f.separation
		f.live = true
	else:
		var fallback: Vector3 = spawn_forward
		fallback.y = 0.0
		if fallback.length_squared() > 0.001:
			f.forward = fallback.normalized()
		f.separation = maxf(axis.length(), 0.0)
	f.right = Vector3.UP.cross(f.forward).normalized()

	# Spread uses the same locality kernel so a local frame is normalised
	# against the local group, not a fleet most of it isn't part of.
	var var_sum := 0.0
	for s in friendly:
		if not is_instance_valid(s) or not s.is_alive():
			continue
		var w: float = locality_weight(s.global_position.distance_to(focus), locality)
		var d: float = (s.global_position - f.friendly_center).dot(f.right)
		var_sum += d * d * w
	f.spread = maxf(sqrt(var_sum / fweight), MIN_SPREAD)
	return f


## Which side of our own fleet `pos` is on, normalised by spread. Roughly
## -1..1 in the line, beyond that for outliers. A scalar, not a side - see
## SIDE_DEADBAND.
func side_of(pos: Vector3) -> float:
	return (pos - friendly_center).dot(right) / spread


## How far up-field `pos` is: 0 at our own fleet, 1 at the enemy's.
func depth_of(pos: Vector3) -> float:
	if separation < MIN_SEPARATION:
		return 0.0
	return (pos - friendly_center).dot(forward) / separation


## True when two positions are on the same flank, or either is within the
## deadband of the centreline.
func same_flank(a: Vector3, b: Vector3) -> bool:
	return sides_agree(side_of(a), side_of(b))


## same_flank() on pre-computed sides.
func sides_agree(a_side: float, b_side: float) -> bool:
	if absf(a_side) < SIDE_DEADBAND or absf(b_side) < SIDE_DEADBAND:
		return true
	return (a_side > 0.0) == (b_side > 0.0)
