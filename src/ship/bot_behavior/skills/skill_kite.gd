class_name SkillKite
extends BotSkill
## Fighting retreat — maintain guns on target while pulling away.
## Heading uses SkillAngle.calc_heading with the away-bearing so the angle
## is always directed away from the danger center.

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship

	var spotted_center = ctx.behavior._get_spotted_danger_center()
	var danger_center = spotted_center if spotted_center != Vector3.ZERO else ctx.behavior._get_danger_center()
	if danger_center == Vector3.ZERO:
		return null

	var to_danger = danger_center - ship.global_position
	to_danger.y = 0.0
	if to_danger.length_squared() < 1.0:
		return null

	var danger_bearing = atan2(to_danger.x, to_danger.z)
	var away_bearing = ctx.behavior._normalize_angle(danger_bearing + PI)

	var heading = SkillAngle.calc_heading(away_bearing, ctx, params)

	var fwd = Vector3(sin(heading), 0.0, cos(heading))
	var dest = ship.global_position + fwd * max(2000.0, ship.movement_controller.turning_circle_radius * 2.0)
	dest.y = 0.0
	dest = ctx.behavior._get_valid_nav_point(dest)

	var intent := NavIntent.create(dest, heading)
	intent.directional = true
	return intent
