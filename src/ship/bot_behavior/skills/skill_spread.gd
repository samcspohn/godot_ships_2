class_name SkillSpread
extends BotSkill

func apply(intent: NavIntent, ctx: SkillContext, params: Dictionary) -> NavIntent:
	if intent == null:
		return null
	var friendly = ctx.server.get_team_ships(ctx.ship.team.team_id)
	var spread_dist = params.get("spread_distance", 500.0)
	var multiplier = params.get("spread_multiplier", 2.0)
	var offset = ctx.behavior._calculate_spread_offset(friendly, spread_dist, multiplier)
	intent.target_position += offset
	intent.target_position = ctx.behavior._get_valid_nav_point(intent.target_position)
	return intent
