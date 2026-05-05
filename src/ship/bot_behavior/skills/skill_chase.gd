class_name SkillChase
extends BotSkill

func execute(ctx: SkillContext, _params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var unspotted: Dictionary = ctx.server.get_unspotted_enemies(ship.team.team_id)
	var spotted = ctx.server.get_valid_targets(ship.team.team_id)
	if unspotted.is_empty():
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
		var pos: Vector3 = s.global_position
		var d := pos.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = pos

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
