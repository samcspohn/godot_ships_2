class_name SkillRetreat
extends BotSkill

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var enemies = ctx.server.get_valid_targets(ship.team.team_id)
	if enemies.is_empty():
		return null

	# Find closest enemy
	var closest = enemies[0]
	var closest_dist = (closest.global_position - ship.global_position).length()
	for e in enemies:
		var d = (e.global_position - ship.global_position).length()
		if d < closest_dist:
			closest = e
			closest_dist = d

	var concealment_radius = (ship.concealment.params.p() as ConcealmentParams).radius
	var retreat_mult = params.get("retreat_multiplier", 2.0)
	var retreat_dir = (ship.global_position - closest.global_position).normalized()
	var desired_pos = ship.global_position + retreat_dir * concealment_radius * retreat_mult

	# Bias toward friendlies when low HP
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
	var friendly_threshold = params.get("friendly_bias_hp_threshold", 0.5)
	if hp_ratio < friendly_threshold:
		var friendly_weight = params.get("friendly_bias_weight", 0.2)
		var nearest_cluster = ctx.server.get_nearest_friendly_cluster(ship.global_position, ship.team.team_id)
		var friendly_pos = Vector3.ZERO
		if not nearest_cluster.is_empty():
			friendly_pos = nearest_cluster.center
		else:
			friendly_pos = ctx.server.get_team_avg_position(ship.team.team_id)
		if friendly_pos != Vector3.ZERO:
			desired_pos = desired_pos * (1.0 - friendly_weight) + friendly_pos * friendly_weight

	desired_pos.y = 0.0
	desired_pos = ctx.behavior._get_valid_nav_point(desired_pos)
	var heading = atan2((desired_pos - ship.global_position).x, (desired_pos - ship.global_position).z)
	return NavIntent.create(desired_pos, heading)
