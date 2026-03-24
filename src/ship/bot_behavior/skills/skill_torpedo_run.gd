class_name SkillTorpedoRun
extends BotSkill

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var target = ctx.target
	if target == null:
		return null

	var concealment_radius = (ship.concealment.params.p() as ConcealmentParams).radius
	var approach_ratio = params.get("approach_ratio", 1.5)

	# Choose flank side
	var right = target.transform.basis.x * concealment_radius * approach_ratio
	var right_of = ctx.behavior._get_valid_nav_point(target.global_position + right)
	var left_of = ctx.behavior._get_valid_nav_point(target.global_position - right)

	var desired_pos: Vector3
	if right_of.distance_to(ship.global_position) < left_of.distance_to(ship.global_position):
		desired_pos = right_of
	else:
		desired_pos = left_of
	desired_pos = ctx.behavior._get_valid_nav_point(desired_pos)

	# Calculate heading
	var heading: float
	if ship.torpedo_controller != null:
		# Beam-on heading for torpedo launch
		var target_pos = target.global_position
		if target.linear_velocity.length() > 0.5:
			var torp_speed = ship.torpedo_controller.get_torp_params().speed
			if torp_speed > 0:
				var dist = desired_pos.distance_to(target_pos)
				target_pos = target_pos + target.linear_velocity * (dist / torp_speed) * 0.5
		var to_target = target_pos - desired_pos
		to_target.y = 0.0
		var target_bearing = atan2(to_target.x, to_target.z)
		var current_heading = ctx.behavior._get_ship_heading()
		var pr = ctx.behavior._normalize_angle(target_bearing + PI / 2.0)
		var pl = ctx.behavior._normalize_angle(target_bearing - PI / 2.0)
		# Prefer perpendicular closer to current heading, biased toward escape
		var away = ctx.behavior._normalize_angle(target_bearing + PI)
		var rs = abs(ctx.behavior._normalize_angle(pr - current_heading)) * 0.6 + abs(ctx.behavior._normalize_angle(pr - away)) * 0.4
		var ls = abs(ctx.behavior._normalize_angle(pl - current_heading)) * 0.6 + abs(ctx.behavior._normalize_angle(pl - away)) * 0.4
		heading = pr if rs <= ls else pl
	else:
		var to_dest = desired_pos - ship.global_position
		to_dest.y = 0.0
		heading = atan2(to_dest.x, to_dest.z) if to_dest.length_squared() > 1.0 else ctx.behavior._get_ship_heading()

	return NavIntent.create(desired_pos, heading)
