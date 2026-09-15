class_name SkillSpot
extends BotSkill

const SPOT_MARGIN            := 1.0
const SAFE_MARGIN            := 1.15

## Probe spacing along the escape bearing, as a fraction of the router's own
## detection radius, and how many probes the walk may take.  Together they cap
## the walk at 2x that radius: enough to leave a bubble entered at its centre
## plus an overlapping one, and short enough that running out still leaves the
## station on our side of the contacts rather than past them.
const PUSH_STEP_RATIO := 0.25
const MAX_PUSH_PASSES := 8

## True when the station ended up outside the router's threat picture, false
## when the walk ran out of passes with the station still inside it.  Read by
## DDBehavior to decide whether stealth routing is achievable at all - asking
## the navigator to avoid detection zones while sending it to a goal inside one
## produces an unreachable destination.
var stealth_corridor: bool = true

var current_pos: Vector3 = Vector3.ZERO

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var behavior = ctx.behavior
	var ship_pos = ship.global_position
	if current_pos == Vector3.ZERO:
		current_pos = ship_pos

	# var danger_center: Vector3 = behavior._get_spotted_danger_center()
	# var dist := NavigationMapManager.get_distance(current_pos)

	# return NavIntent.create(current_pos, ship.global_transform.basis.get_euler().y)
	var danger_center: Vector3 = behavior._get_spotted_danger_center()

	var reach: float = behavior.threat_effective_radius()
	if reach <= 0.0:
		return null

	var fpfc = SkillFlank.flank_position(ctx, ship_pos, 60.0)
	var flank_pos: Vector3 = fpfc[0]
	var friendly_center: Vector3 = fpfc[1]
	if flank_pos == Vector3.ZERO:
		return null

	if flank_pos.distance_to(friendly_center) > flank_pos.distance_to(danger_center) * 0.75:
		var friendly_to_danger = (friendly_center - danger_center)
		var flank_to_friendly = (flank_pos - friendly_center).normalized()
		flank_pos = flank_to_friendly * friendly_to_danger.length() * 0.75 + friendly_center


	flank_pos = _push_clear_of_threats(ctx, danger_center, flank_pos, reach)
	var away_dir = (flank_pos - danger_center).normalized()
	var away_heading: float = atan2(away_dir.x, away_dir.z)
	var intent := NavIntent.create(flank_pos, away_heading)
	# BotControllerV4._adjust_destination_for_threats() would otherwise run the
	# station back through ShipNavigator.adjust_destination_for_threats() on
	# every stealth tick, and that is the function the walk above exists to
	# avoid - it would shove a point we just verified off its bearing, possibly
	# onto land or past the contacts. Either outcome of the walk is final: a
	# clear probe is already the nearest usable station on the bearing, and a
	# walk that ran out of budget has proved there is no better one on it.
	intent.skip_threat_adjustment = true
	return intent

## Slide `pos` straight out along the bearing that already points away from the
## danger centre until it lands somewhere the stealth router can actually use.
##
## The walk is done here rather than through
## ShipNavigator.adjust_destination_for_threats() because that function solves a
## different problem: it pushes a point out of each circle that contains it
## radially away from THAT circle's origin, so with a contact sitting out along
## our escape bearing the escape hatch it finds is the far side of that contact.
## It also never looks at terrain, and it tests the exact point against the
## circles while the router blocks whole clusters - so a point it calls clear can
## still be a goal inside the planner's own wall.
##
## Walking outward and stopping at the FIRST clear probe gives the station
## closest to the enemy that still routes, and can never return a point behind
## the contacts: every probe is further from the danger centre than the last, and
## the walk gives up instead of stepping past its budget.
func _push_clear_of_threats(ctx: SkillContext, danger_center: Vector3,
		pos: Vector3, reach: float) -> Vector3:
	stealth_corridor = true

	var nav: ShipNavigator = ctx.navigator
	if nav == null or nav.get_threat_circle_count() == 0:
		return pos

	var center_2d := Vector2(danger_center.x, danger_center.z)
	var away := Vector2(pos.x, pos.z) - center_2d
	if danger_center == Vector3.ZERO or away.length_squared() < 1.0:
		return pos

	var dir := away.normalized()
	var dist := away.length()
	var step: float = maxf(reach * PUSH_STEP_RATIO, SPOT_MARGIN)

	for _pass in MAX_PUSH_PASSES + 1:
		var probe := center_2d + dir * dist
		if not nav.is_point_blocked(probe):
			return Vector3(probe.x, pos.y, probe.y)
		dist += step

	# Out of budget with every probe blocked: the bearing runs through a contact
	# that sits along it, or into land, and the only clear water left on it is
	# behind one of them.  Hand back the unshifted station and tell DDBehavior
	# there is no stealth corridor to ask the router for.
	stealth_corridor = false
	return pos
