class_name SkillRetreat
extends BotSkill
## Pure disengagement — navigate directly away from the aggregate danger center.
## No broadside angle optimisation; heading is the raw away-bearing so the ship
## accelerates out of detection range as fast as possible.

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var nearest = ctx.behavior._get_nearest_enemy().ship
	var away_from = atan2(ctx.ship.global_position.x - nearest.global_position.x, ctx.ship.global_position.z - nearest.global_position.z)
	var dest = ctx.ship.global_position + Vector3(sin(away_from), 0.0, cos(away_from)) * max(3000.0, ctx.ship.movement_controller.turning_circle_radius * 8.0)
	dest.y = 0.0
	dest = ctx.behavior._get_valid_nav_point(dest)
	var intent := NavIntent.create(dest, away_from)
	intent.directional = true
	return intent
	# var ship = ctx.ship

	# var danger_center = ctx.behavior._get_spotted_danger_center()
	# if danger_center == Vector3.ZERO:
	# 	return null

	# var to_danger = danger_center - ship.global_position
	# to_danger.y = 0.0
	# if to_danger.length_squared() < 1.0:
	# 	return null

	# var away_bearing = atan2(-to_danger.x, -to_danger.z)

	# # Bias toward friendlies when low HP
	# var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
	# var friendly_threshold = params.get("friendly_bias_hp_threshold", 0.5)
	# var retreat_dir = Vector3(sin(away_bearing), 0.0, cos(away_bearing))
	# var desired_pos = ship.global_position + retreat_dir * max(3000.0, ship.movement_controller.turning_circle_radius * 4.0)

	# if hp_ratio < friendly_threshold:
	# 	var friendly_weight = params.get("friendly_bias_weight", 0.2)
	# 	var nearest_cluster = ctx.server.get_nearest_friendly_cluster(ship.global_position, ship.team.team_id)
	# 	var friendly_pos = Vector3.ZERO
	# 	if not nearest_cluster.is_empty():
	# 		friendly_pos = nearest_cluster.center
	# 	else:
	# 		friendly_pos = ctx.server.get_team_avg_position(ship.team.team_id)
	# 	if friendly_pos != Vector3.ZERO:
	# 		desired_pos = desired_pos * (1.0 - friendly_weight) + friendly_pos * friendly_weight

	# desired_pos.y = 0.0
	# desired_pos = ctx.behavior._get_valid_nav_point(desired_pos)

	# var final_bearing = atan2((desired_pos - ship.global_position).x, (desired_pos - ship.global_position).z)
	# var intent := NavIntent.create(desired_pos, final_bearing)
	# intent.directional = true
	# return intent
