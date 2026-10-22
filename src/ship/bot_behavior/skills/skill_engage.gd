class_name SkillEngage
extends BotSkill

## Pushing forward: straight in on the priority (else the danger bearing) to the band edge of the
## engagement range, routed round every enemy's band. Unused since SkillFight.
## Params as FightStation's band: band_m, else desired_range, else each enemy's own radius.

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	if ship.team == null or ctx.server == null:
		return null
	var belief: Array[Dictionary] = ctx.server._team_belief(ship.team.team_id)
	if belief.is_empty():
		return null
	var pos := PackedVector2Array()
	var radii := PackedFloat32Array()
	for b in belief:
		pos.append(b.pos)
		radii.append(FightStation.radius_for(ctx, b.ship, b.pos, params) + float(b.spread) if FightStation.threatens(b.ship) else 0.0)
	var pt: Ship = ctx.behavior.priority_target()
	var pp: Vector3 = ctx.behavior.priority_point()
	var band_m: float = FightStation.radius_for(ctx, pt, Vector2(pp.x, pp.z), params) if pt != null and pp.is_finite() else radii[0]
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var danger := Vector2(pp.x, pp.z) if pp.is_finite() else SkillPosition._belief_centre(ctx, belief, here)
	var off := here - danger
	if off.length() <= band_m or off.length_squared() < 1.0:
		return null
	var to := danger + off.normalized() * band_m
	var intent := NavIntent.create(ctx.behavior._get_valid_nav_point(Vector3(to.x, 0.0, to.y)), atan2(-off.x, -off.y))
	intent.avoid_origins = pos
	intent.avoid_radii = radii if ship.visible_to_enemy else FightStation._short_of(radii, pos, here)
	return intent
