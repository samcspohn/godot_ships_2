class_name SkillPush
extends BotSkill
## Aggressive push — drive toward the enemy at the optimal armor approach angle.
## Uses SkillAngle.calc_heading() to pick a course that arrives bow-angled rather
## than perfectly bow-on, but sets the NavIntent heading to enemy_bearing so the
## hull faces the threat during the approach.
##
## Params:
##   desired_range — stop closing at this distance instead of driving onto the
##     enemy.  This is where a ship's engagement range lives: a torpedo boat
##     passes its torpedo range and stops where it can launch, a gunship passes
##     0 (the default) and closes all the way.  Held against the danger centre
##     AND against whatever the approach would otherwise walk into first — see
##     _standoff_breach().
##   line_of_fire — refuse a stop point the guns cannot actually fire from, and
##     swing around the standoff arc until one is found.  Opt-in because it
##     costs a ballistic solve and it is the wrong question for a boat whose
##     desired_range is a torpedo range: that one is not stopping to shoot.
##   equalize_threat, equalize_floor — override the doctrine's
##     push_equalize_threat / push_equalize_floor for this call.  See
##     _equalized_range() below: desired_range is what the push stops on when
##     the fight is as hard as this bot is willing to fight it, and less threat
##     than that buys a shorter standoff.

## How far around the standoff arc a blocked push will look, and in what steps.
## Four probes at 20 degrees sweeps 80 degrees either side, which is about as
## far as a ship can swing and still be taking the ground it was sent to take.
## Past that it is not pushing any more, and the arm above should be choosing a
## different skill rather than this one choosing a different errand.
const LOF_ARC_STEP: float = deg_to_rad(20.0)
const LOF_ARC_STEPS: int = 4

## Time constant for the standoff following a change in threat, and the gap in
## activity after which it stops following and simply snaps.
##
## Threat is not a smooth signal - a contact spotting, a shooter picking someone
## else, a citadel taken - and the standoff is a distance the navigator plans a
## path to, so a step in threat would otherwise be a step in the destination.
## Lagging it a couple of seconds keeps the approach reading as a ship slowing
## down rather than as one changing its mind, and costs nothing that matters:
## the equalisation is a station-keeping loop, not a reflex.
##
## The gap covers coming back to Push after a spell in another skill, where the
## last ratio is a reading from a fight that has since moved on. Sized past
## BotControllerV4.MAX_BEHAVIOR_INTERVAL so a bot merely ticking slowly still
## gets the smoothing; only a real absence from the skill snaps it.
const EQUALIZE_TAU: float = 2.0
const EQUALIZE_RESUME_GAP: float = 3.0

## Smoothed fraction of desired_range currently being held, and when it was last
## updated. Time rather than frames because the ladder runs on a staggered
## interval and a bot can miss ticks.
var _range_ratio: float = 1.0
var _ratio_time: float = -1.0


## Drop the smoothing so the next push reads its standoff fresh.
func reset() -> void:
	_ratio_time = -1.0

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship

	# Push onto the weighted danger centre rather than onto the single ship the
	# targeting code happens to be holding — closing on one contact walks the
	# hull past everything else that is shooting.  The target is the fallback
	# for the moment before anything is confirmed, when the centre reads ZERO.
	#
	# And only the fallback.  This used to decline outright on a null target,
	# which put the whole ladder at the mercy of the gunnery: ctx.target is
	# pick_target()'s answer, and pick_target() returns null whenever nothing has
	# a firing solution — masked by terrain, or simply out of range.  That is the
	# situation a push is FOR, and refusing it left the arms above with no
	# aggressive option at exactly the moment closing was the only thing that
	# would restore the shot.
	var target = ctx.target
	var danger_center: Vector3 = ctx.behavior._get_spotted_danger_center()
	var confirmed_center: bool = danger_center != Vector3.ZERO
	if not confirmed_center:
		if target == null or not is_instance_valid(target):
			return null
		danger_center = target.global_position

	# Relative to the ship.  This used to read the danger centre as though it
	# were already a vector from the hull — atan2() and length() taken straight
	# off a world position — which measured both the bearing and the distance
	# still to close from the map ORIGIN.  A ship anywhere but the middle of the
	# map was handed a compass bearing that had nothing to do with the enemy and
	# a closing distance that was mostly its own coordinate, and it stopped
	# wherever that ran out.
	var to_enemy: Vector3 = danger_center - ship.global_position
	to_enemy.y = 0.0
	if to_enemy.length_squared() < 1.0:
		return null
	var enemy_bearing := atan2(to_enemy.x, to_enemy.z)

	# Where the hull POINTS, which is a different question from where it goes.
	# SkillAngle answers with an attitude — the armour angle it wants against the
	# guns that can actually reach it — and the mix keeps most of the bearing so
	# the ship still arrives facing the fight rather than beam-on to it.
	#
	# Only when the centre is confirmed. SkillAngle reads the same danger centre
	# this skill does, and on ZERO it does not decline: it hands back the bearing
	# to the map ORIGIN. Blending that swung every push away from the contact it
	# had just fallen back to, by however far the origin happened to lie off it.
	var heading := enemy_bearing
	if confirmed_center:
		heading = lerp_angle(enemy_bearing, SkillAngle.calc_heading(ctx, params), 0.2)

	# Close only as far as the standoff allows — the engagement range the caller
	# asked for, pulled in by _equalized_range() for however much of the fight
	# the bot is not currently having.  At or inside it the push degenerates to a
	# heading change, which is what we want — the ship holds station at range and
	# lets Broadside/Angle work the hull around.
	var desired_range: float = _equalized_range(ctx, params, float(params.get("desired_range", 0.0)))
	var center_dist: float = to_enemy.length()
	var close_dist: float = maxf(center_dist - desired_range, 0.0)

	# Down the BEARING, not down the heading.  Walking close_dist along the
	# angled heading answered neither question: the stop point came out off the
	# line to the enemy, and therefore not at desired_range from it, by more the
	# harder the ship was angling.
	var dir: Vector3 = to_enemy / center_dist

	# The centre says which WAY to go; what stands in front says how FAR.  A
	# weighted centroid sits behind the ships that make it — a fleet spread
	# across the map centres well past its own vanguard — so a standoff measured
	# only to the centre spends that whole gap, and the push walks the hull to
	# arm's length of a point in the middle of the enemy line, straight past
	# everything standing between here and it.
	#
	# So the standoff is held against every contact rather than just the
	# centroid: how far the approach can run before the ship is inside
	# desired_range of any of them.  See _standoff_breach().
	if desired_range > 0.0:
		close_dist = minf(close_dist, _standoff_breach(ctx, dir, desired_range, close_dist))

	var dest: Vector3 = ship.global_position + dir * close_dist
	dest.y = 0.0

	if params.get("line_of_fire", false):
		dest = _clear_firing_position(ctx, dest, danger_center)

	dest = ctx.behavior._get_valid_nav_point(dest)
	return NavIntent.create(dest, heading)


## How far the ship may run along `dir` before it is within `radius` of a known
## enemy; `limit` when none of them constrains the run.
##
## Ray against a circle per contact, which is the exact question and costs a dot
## product and a square root to answer.  Two cases deliberately constrain
## nothing:
##
##   - a contact the line passes wide of (perpendicular offset already past the
##     standoff).  The approach never enters its bubble, so it has no opinion
##     about how far the approach goes.
##   - a contact the ship is ALREADY inside the standoff of.  Forward is the way
##     out of that bubble, not further into it, and clamping the run to zero here
##     would park a push for as long as anything at all sat close aboard — which
##     for a battleship is every destroyer on the map.  The arms above are what
##     decide whether a fight this close is still worth having.
func _standoff_breach(ctx: SkillContext, dir: Vector3, radius: float, limit: float) -> float:
	var ship_pos: Vector3 = ctx.ship.global_position
	var team_id: int = ctx.ship.team.team_id
	var r_sq: float = radius * radius
	var out: float = limit
	var positions: Array = []
	for e in ctx.server.get_valid_targets(team_id):
		if is_instance_valid(e):
			positions.append(e.global_position)
	positions.append_array(ctx.server.get_unspotted_enemies(team_id).values())

	for pos in positions:
		var to_contact: Vector3 = (pos as Vector3) - ship_pos
		to_contact.y = 0.0
		var along: float = to_contact.dot(dir)
		if along <= 0.0:
			continue
		var perp_sq: float = maxf(to_contact.length_squared() - along * along, 0.0)
		if perp_sq >= r_sq:
			continue
		var entry: float = along - sqrt(r_sq - perp_sq)
		if entry > 0.0:
			out = minf(out, entry)
	return out


## Shrink the standoff toward the threat the bot is willing to fight at.
##
## The engagement range says how close this hull wants to be against a fight it
## is only just winning; it says nothing about a fight it is winning easily.
## Stopping on it either way made the push a single decision taken at one
## distance, and the only thing that ever gave ground back was the arm above
## trading Push for Kite at its threshold.
##
## So the range is negotiated instead.  Threat rises as the ship closes -
## range_pressure in get_threat_score() is 1 at point-blank and 0 at the enemy's
## own range edge - which makes this a loop that settles: at low threat the stop
## point is short and the ship keeps coming, and every metre it takes raises the
## threat that pushes the stop point back out.  It comes to rest where threat
## sits at the equalise point, which is also where the ladder above stops
## pushing, so the two agree at the boundary instead of meeting at a step.  Take
## damage or pick up a second shooter and the same loop hands the water back.
##
## The floor keeps an unopposed push honest: with nothing in range to be
## frightened of, threat reads 0 and an unfloored ratio would aim the stop point
## at the enemy's waterline.
func _equalized_range(ctx: SkillContext, params: Dictionary, desired_range: float) -> float:
	if desired_range <= 0.0:
		return desired_range
	var d: BotDoctrine = ctx.behavior._doc()
	var equalize: float = float(params.get("equalize_threat", d.push_equalize_threat))
	if equalize <= 0.0:
		# Not a negotiable range: this caller's desired_range is a distance
		# something else already decided (a concealment band, a launch envelope)
		# and threat is not an argument against it.
		_ratio_time = -1.0
		return desired_range

	var floor_ratio: float = clampf(float(params.get("equalize_floor", d.push_equalize_floor)), 0.0, 1.0)
	# Cached per physics frame, so this costs nothing the ladder has not already
	# paid for on this tick.
	var threat: float = ctx.behavior.get_threat_score(ctx)
	var wanted: float = clampf(threat / equalize, floor_ratio, 1.0)

	var now: float = Time.get_ticks_msec() / 1000.0
	if _ratio_time < 0.0 or now - _ratio_time > EQUALIZE_RESUME_GAP:
		_range_ratio = wanted
	else:
		_range_ratio = lerpf(_range_ratio, wanted, clampf((now - _ratio_time) / EQUALIZE_TAU, 0.0, 1.0))
	_ratio_time = now
	return desired_range * _range_ratio


## Slide a stop point around the standoff arc until the guns can reach the
## target from it.
##
## desired_range is a distance and nothing more — it says nothing about what is
## between the ship and the enemy.  Stopping at it behind an island is a stop
## that ends the engagement: the ship holds a standoff it cannot fire from and
## waits for somebody else to change the picture.
##
## Sideways, not forwards.  The blocked case is terrain on the bearing, and
## walking further up that same bearing puts the ship NEARER the thing masking
## it, which needs a steeper arc rather than a shallower one — the shot only
## comes back once the ship has sailed past the island altogether, which is well
## inside any standoff worth the name.  Swinging around the arc keeps the range
## the doctrine asked for and changes the only thing that was wrong with the
## position, which is where it was standing.
##
## The target's own led point is the test rather than every spotted enemy: this
## is a push onto something, and being able to shell a different ship is not the
## push succeeding.  It also keeps the accepted case at a single ballistic solve.
func _clear_firing_position(ctx: SkillContext, dest: Vector3, danger_center: Vector3) -> Vector3:
	var ship = ctx.ship
	if ship.artillery_controller == null:
		return dest
	var shell_params = ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return dest
	var points: Array[Vector3] = ctx.behavior.led_target_points([ctx.target])
	if points.is_empty():
		return dest
	var aim: Vector3 = points[0]
	var gun_range: float = ship.artillery_controller.get_params()._range
	var gun_range_sq: float = gun_range * gun_range

	dest = ctx.behavior._get_valid_nav_point(dest)
	if ctx.behavior._can_shoot_point_from(dest, aim, shell_params, gun_range_sq):
		return dest

	# The arc is centred on the danger centre so the sweep holds the range the
	# caller asked for; only the bearing to it moves.
	var arm := dest - danger_center
	arm.y = 0.0
	var radius := arm.length()
	if radius < 1.0:
		return dest
	var base_angle := atan2(arm.x, arm.z)

	# Outward in step order, both sides at each step, so the least deviation
	# that restores a shot wins.
	for i in range(1, LOF_ARC_STEPS + 1):
		for side in [1.0, -1.0]:
			var a: float = base_angle + side * float(i) * LOF_ARC_STEP
			var cand := danger_center + Vector3(sin(a), 0.0, cos(a)) * radius
			cand.y = 0.0
			cand = ctx.behavior._get_valid_nav_point(cand)
			if ctx.behavior._can_shoot_point_from(cand, aim, shell_params, gun_range_sq):
				return cand

	# Nothing on the arc works.  Keep the nominal point rather than inventing a
	# worse one — the ship still closes, and the arms above get to notice on a
	# later tick that this ground is not worth holding.
	return dest
