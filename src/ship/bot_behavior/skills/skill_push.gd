class_name SkillPush
extends BotSkill
## Aggressive push — drive toward the enemy at the optimal armor approach angle.
## Uses SkillAngle.calc_heading() to pick a course that arrives bow-angled rather
## than perfectly bow-on, but sets the NavIntent heading to enemy_bearing so the
## hull faces the threat during the approach.

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var target = ctx.target
	if target == null:
		return null
	var ship = ctx.ship
	var to_enemy = target.global_position - ship.global_position
	to_enemy.y = 0.0
	if to_enemy.length_squared() < 1.0:
		return null
	# var enemy_bearing = atan2(to_enemy.x, to_enemy.z)

	var heading = SkillAngle.calc_heading(ctx, params)
	# if absf(angle_difference(heading, enemy_bearing)) > PI * 0.5:
	# 	heading = wrapf(heading + PI, -PI, PI)

	var fwd = Vector3(sin(heading), 0.0, cos(heading))
	var dest = ship.global_position + fwd * to_enemy.length()
	dest.y = 0.0

	dest = ctx.behavior._get_valid_nav_point(dest)
	return NavIntent.create(dest, heading)
