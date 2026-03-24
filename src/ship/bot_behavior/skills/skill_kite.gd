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

	var desired_range = ship.artillery_controller.get_params()._range * params.get("desired_range_ratio", 0.75)

	var heading = SkillAngle.calc_heading(away_bearing, ctx, params)

	# Ray-circle intersection: cast a ray from the ship along the heading
	# direction and find where it hits the circle (danger_center, desired_range).
	# Inside the circle  → t1 < 0, t2 > 0 → use t2 (forward exit).
	# Outside the circle → both positive  → use t1 (near side).
	var ship_pos_2d = Vector2(ship.global_position.x, ship.global_position.z)
	var center_2d = Vector2(danger_center.x, danger_center.z)
	var dist_to_danger = ship_pos_2d.distance_to(center_2d)
	var inside = dist_to_danger < desired_range

	var ray_dir = Vector2(sin(heading), cos(heading))

	var oc = ship_pos_2d - center_2d
	var a = ray_dir.dot(ray_dir)
	var b = 2.0 * oc.dot(ray_dir)
	var c = oc.dot(oc) - desired_range * desired_range

	var discriminant = b * b - 4.0 * a * c

	var dest: Vector3
	if discriminant < 0.0:
		# Ray misses the circle — fall back to projecting along heading.
		var fwd = Vector2(sin(heading), cos(heading))
		dest = ship.global_position + Vector3(fwd.x, 0.0, fwd.y) * desired_range
		print("Kite: ray misses circle, using fallback destination")
	else:
		var sqrt_disc = sqrt(discriminant)
		var t1 = (-b - sqrt_disc) / (2.0 * a)
		var t2 = (-b + sqrt_disc) / (2.0 * a)
		# Inside: t1 behind, t2 ahead → use t2 (forward to the circle edge).
		# Outside: both ahead → use t1 (near side of the circle).
		var t = t2 if inside else t1
		if t < 0.0:
			var fwd = Vector2(sin(heading), cos(heading))
			dest = ship.global_position + Vector3(fwd.x, 0.0, fwd.y) * desired_range
		else:
			var hit = ship_pos_2d + ray_dir * t
			dest = Vector3(hit.x, 0.0, hit.y)

	dest.y = 0.0
	dest = ctx.behavior._get_valid_nav_point(dest)

	return NavIntent.create(dest, heading)
