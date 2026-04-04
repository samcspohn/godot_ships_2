class_name SkillHunt
extends BotSkill

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var friendly = ctx.server.get_team_ships(ctx.ship.team.team_id)
	var fallback = ctx.ship.global_position - ctx.ship.basis.z * 10000.0
	fallback.y = 0.0
	var dest = ctx.behavior._get_hunting_position(ctx.server, friendly, fallback)
	if dest == Vector3.ZERO:
		dest = ctx.behavior._get_valid_nav_point(fallback)
	var to_dest = dest - ctx.ship.global_position
	to_dest.y = 0.0
	var heading = atan2(to_dest.x, to_dest.z) if to_dest.length_squared() > 1.0 else ctx.behavior._get_ship_heading()
	var intent = NavIntent.create(dest, heading)
	intent.throttle_override = 4
	return intent
