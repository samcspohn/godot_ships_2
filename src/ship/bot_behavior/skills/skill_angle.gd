class_name SkillAngle
extends BotSkill

static var _cache: Dictionary = {}
static var _cache_frame: int = -1

## Calculate the best heading by scoring candidates against all threats whose
## gun range * 0.8 encapsulates our ship.  Each threat uses its own ship class
## to determine the ideal presentation angle.
## - base_bearing: preferred direction (toward enemy for angle, away for kite)
## - ctx: SkillContext for access to behavior helpers and server
## - params: Dictionary, may contain "angle_ranges" overrides
static func calc_heading(base_bearing: float, ctx: SkillContext, params: Dictionary) -> float:
	var frame := Engine.get_physics_frames()
	if frame != _cache_frame:
		_cache.clear()
		_cache_frame = frame
	var key := str(ctx.ship.get_instance_id()) + "|" + str(base_bearing) + "|" + str(params.hash())
	if _cache.has(key):
		return _cache[key]

	var ship = ctx.ship

	var default_ranges = {
		Ship.ShipClass.BB: Vector2(deg_to_rad(25), deg_to_rad(29)),
		Ship.ShipClass.CA: Vector2(deg_to_rad(0), deg_to_rad(29)),
		Ship.ShipClass.DD: Vector2(deg_to_rad(0), deg_to_rad(40)),
	}
	var ranges = params.get("angle_ranges", default_ranges)

	# Class-based threat weights — heavier ships are more dangerous to angle against
	var class_weights = {
		Ship.ShipClass.BB: 3.0,
		Ship.ShipClass.CA: 2.0,
		Ship.ShipClass.DD: 0.2,
		Ship.ShipClass.CV: 0.5,
	}

	# Gather all enemy ships whose range * 0.8 encapsulates our ship
	var encapsulating_threats: Array = []
	var server_node = ctx.server
	if server_node != null:
		for enemy in server_node.get_valid_targets(ship.team.team_id):
			if is_instance_valid(enemy) and enemy.health_controller.is_alive():
				var enemy_range = enemy.artillery_controller.get_params()._range
				var dist = ship.global_position.distance_to(enemy.global_position)
				if dist <= enemy_range * 0.8:
					encapsulating_threats.append({
						"position": enemy.global_position,
						"ship_class": enemy.ship_class,
						"dist": dist,
						"enemy_range": enemy_range,
					})
		var unspotted = server_node.get_unspotted_enemies(ship.team.team_id)
		for enemy_ship in unspotted.keys():
			if is_instance_valid(enemy_ship) and enemy_ship.health_controller.is_alive():
				var enemy_range = enemy_ship.artillery_controller.get_params()._range
				var last_known_pos: Vector3 = unspotted[enemy_ship]
				var dist = ship.global_position.distance_to(last_known_pos)
				if dist <= enemy_range * 0.8:
					encapsulating_threats.append({
						"position": last_known_pos,
						"ship_class": enemy_ship.ship_class,
						"dist": dist,
						"enemy_range": enemy_range,
					})

	# For each threat compute the best ± offset heading (closest to base_bearing),
	# create a unit Vector2 for that heading scaled by weight, then sum and average.
	var heading_sum := Vector2.ZERO
	var total_weight: float = 0.0
	for threat in encapsulating_threats:
		var to_threat: Vector3 = threat["position"] - ship.global_position
		to_threat.y = 0.0
		if to_threat.length_squared() < 1.0:
			continue
		var bearing = atan2(to_threat.x, to_threat.z)
		var angle_range: Vector2 = ranges.get(threat["ship_class"], Vector2(0, deg_to_rad(30)))
		var ideal = (angle_range.x + angle_range.y) * 0.5
		# 4 candidates that all present 'ideal' degrees to this threat:
		# bow angling (toward threat): bearing ± ideal
		# stern angling (away from threat): bearing + PI ± ideal
		var candidates = [
			ctx.behavior._normalize_angle(bearing + ideal),
			ctx.behavior._normalize_angle(bearing - ideal),
			ctx.behavior._normalize_angle(bearing + PI + ideal),
			ctx.behavior._normalize_angle(bearing + PI - ideal),
		]
		# Pick whichever candidate is closest to base_bearing
		var chosen: float = candidates[0]
		var best_diff: float = absf(angle_difference(base_bearing, candidates[0]))
		for j in range(1, candidates.size()):
			var diff = absf(angle_difference(base_bearing, candidates[j]))
			if diff < best_diff:
				best_diff = diff
				chosen = candidates[j]
		# Weight: closer threats matter more, heavier classes matter more
		var normalized_dist = clampf(threat["dist"] / threat["enemy_range"], 0.0, 1.0)
		var dist_weight = exp(-6.0 * normalized_dist)
		var cw_weight: float = class_weights.get(threat["ship_class"], 1.0)
		var w = dist_weight * cw_weight
		heading_sum += Vector2(sin(chosen), cos(chosen)) * w
		total_weight += w

	var result := base_bearing
	if total_weight >= 0.000001:
		var avg = heading_sum / total_weight
		result = atan2(avg.x, avg.y)
	_cache[key] = result
	return result
