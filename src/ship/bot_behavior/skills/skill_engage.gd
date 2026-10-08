class_name SkillEngage
extends BotSkill

## Pushing forward: straight in on the danger bearing to the band edge of the
## engagement range, routed round every enemy's band and out of any band
## holding us first. What SkillHold's FIGHT runs when it finds no station.
## Params as SkillFight's band: band_m, else desired_range, else the engagement range.

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	if ship.team == null or ctx.server == null:
		return null
	var belief: Array[Dictionary] = ctx.server._team_belief(ship.team.team_id)
	if belief.is_empty():
		return null
	var band_m: float = SkillFight._band(ctx, clampf(ctx.behavior.get_threat_score(ctx), 0.0, 1.0), params)
	var pos := PackedVector2Array()
	var radii := PackedFloat32Array()
	for b in belief:
		pos.append(b.pos)
		radii.append(band_m + float(b.spread) if SkillFight.threatens(b.ship) else 0.0)
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var danger := SkillPosition._belief_centre(ctx, belief, here)
	var off := here - danger
	if off.length() <= band_m or off.length_squared() < 1.0:
		return null
	var to := danger + off.normalized() * band_m
	var intent := NavIntent.create(ctx.behavior._get_valid_nav_point(Vector3(to.x, 0.0, to.y)), atan2(-off.x, -off.y))
	intent.avoid_origins = pos
	intent.avoid_radii = radii
	var out := SkillFight._exit_point(here, pos, radii)
	if out != here:
		SkillFight._point(intent, here, out)
	return intent
