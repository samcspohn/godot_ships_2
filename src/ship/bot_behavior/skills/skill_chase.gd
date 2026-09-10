class_name SkillChase
extends BotSkill
## Run down the nearest known enemy, spotted or not, at flank speed.
##
## Both halves of the picture count.  This used to decline outright whenever the
## unspotted list was empty, which reads as "nothing to run down" but is not:
## the ladder also reaches Chase with contacts lit and simply out of reach —
## beyond the guns, or behind an island — and that is precisely a distance
## problem, which is the thing this skill is for.  Declining there left the bot
## with nothing to do about an enemy it could see and could not shoot.

func execute(ctx: SkillContext, _params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var unspotted: Dictionary = ctx.server.get_unspotted_enemies(ship.team.team_id)
	var spotted = ctx.server.get_valid_targets(ship.team.team_id)
	if unspotted.is_empty() and spotted.is_empty():
		return null

	# TODO: implement displacement prediction for unspotted targets, rather than just chasing the last known position. This is especially important for fast ships like Interceptors that can quickly outpace the bot's pursuit.
	# Find the nearest unspotted enemy by last known position
	var best_pos: Vector3
	var best_dist := INF
	for s in unspotted.keys():
		var pos: Vector3 = unspotted[s]
		var d := pos.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = pos
	for s in spotted:
		if not is_instance_valid(s) or not s.health_controller.is_alive():
			continue
		var pos: Vector3 = s.global_position
		var d := pos.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = pos
	if best_dist == INF:
		return null

	best_pos.y = 0.0
	best_pos = ctx.behavior._get_valid_nav_point(best_pos)

	var to_dest: Vector3 = best_pos - ship.global_position
	to_dest.y = 0.0
	var heading := atan2(to_dest.x, to_dest.z) if to_dest.length_squared() > 1.0 else ctx.behavior._get_ship_heading()

	var intent := NavIntent.create(best_pos, heading)
	intent.throttle_override = 4
	return intent

func reset() -> void:
	pass
