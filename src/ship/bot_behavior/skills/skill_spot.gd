class_name SkillSpot
extends BotSkill

## Position to reveal enemies for teammates.
## Navigates toward unspotted enemies or screens between fleets.

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var concealment_radius = (ship.concealment.params.p() as ConcealmentParams).radius
	var approach_dist = params.get("approach_distance", concealment_radius)
	var screen_offset = params.get("screen_offset", 3000.0)

	# Find nearest unspotted enemy
	var unspotted = ctx.server.get_unspotted_enemies(ship.team.team_id)
	var best_pos = Vector3.ZERO
	var best_dist = INF
	for s in unspotted.keys():
		var pos: Vector3 = unspotted[s]
		var d = pos.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = pos

	var desired_pos: Vector3
	if best_pos != Vector3.ZERO:
		# Navigate toward unspotted enemy, stop at approach distance
		var to_enemy = best_pos - ship.global_position
		to_enemy.y = 0.0
		if to_enemy.length() > approach_dist:
			desired_pos = best_pos - to_enemy.normalized() * approach_dist * 0.5
		else:
			desired_pos = best_pos
	else:
		# Screen position: between friendly fleet and enemy cluster
		var friendly_avg = ctx.server.get_team_avg_position(ship.team.team_id)
		var enemy_avg = ctx.server.get_enemy_avg_position(ship.team.team_id)
		if friendly_avg == Vector3.ZERO or enemy_avg == Vector3.ZERO:
			return null
		var mid = (friendly_avg + enemy_avg) * 0.5
		var toward_enemy = (enemy_avg - friendly_avg).normalized()
		desired_pos = mid + toward_enemy * screen_offset

	desired_pos.y = 0.0
	desired_pos = ctx.behavior._get_valid_nav_point(desired_pos)
	var to_dest = desired_pos - ship.global_position
	to_dest.y = 0.0
	var heading = atan2(to_dest.x, to_dest.z) if to_dest.length_squared() > 1.0 else ctx.behavior._get_ship_heading()
	var intent = NavIntent.create(desired_pos, heading)
	intent.throttle_override = 4
	return intent
