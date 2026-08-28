class_name SkillPush
extends BotSkill
## Aggressive push — drive toward the enemy at the optimal armor approach angle.
## Uses SkillAngle.calc_heading() to pick a course that arrives bow-angled rather
## than perfectly bow-on, but sets the NavIntent heading to enemy_bearing so the
## hull faces the threat during the approach.
##
## Params:
##   desired_range — stop closing at this distance from the target instead of
##     driving onto it.  This is where a ship's engagement range lives: a
##     torpedo boat passes its torpedo range and stops where it can launch, a
##     gunship passes 0 (the default) and closes all the way.

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var target = ctx.target
	if target == null:
		return null
	var ship = ctx.ship
	var to_enemy = target.global_position - ship.global_position
	to_enemy.y = 0.0
	if to_enemy.length_squared() < 1.0:
		return null
	var enemy_bearing = atan2(to_enemy.x, to_enemy.z)

	var heading = SkillAngle.calc_heading(ctx, params)
	# mix enemy bearing with threat bearing
	heading = lerp_angle(enemy_bearing, heading, 0.2)

	# var can_reverse = params.get("can_reverse", false)
	# if absf(angle_difference(heading, enemy_bearing)) > PI * 0.5:
	# 	heading = wrapf(heading + PI, -PI, PI)

	var fwd = Vector3(sin(heading), 0.0, cos(heading))
	var dest
	# if can_reverse:
	# 	dest = ship.global_position + fwd * ship.movement_controller.turning_circle_radius * 2.0
	# else:
	# Close only as far as the engagement range allows.  At or inside it the
	# push degenerates to a heading change, which is what we want — the ship
	# holds station at range and lets Broadside/Angle work the hull around.
	var desired_range: float = params.get("desired_range", 0.0)
	var close_dist: float = maxf(to_enemy.length() - desired_range, 0.0)
	dest = ship.global_position + fwd * close_dist
	dest.y = 0.0

	dest = ctx.behavior._get_valid_nav_point(dest)
	return NavIntent.create(dest, heading)
