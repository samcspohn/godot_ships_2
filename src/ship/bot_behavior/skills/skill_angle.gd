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
static func calc_heading(ctx: SkillContext, params: Dictionary) -> float:
	# var frame := Engine.get_physics_frames()
	# if frame != _cache_frame:
	# 	_cache.clear()
	# 	_cache_frame = frame
	# var key := str(ctx.ship.get_instance_id()) + "|" + str(base_bearing) + "|" + str(params.hash())
	# if _cache.has(key):
	# 	return _cache[key]

	# var ship = ctx.ship

	# var default_ranges = {
	# 	Ship.ShipClass.BB: Vector2(deg_to_rad(25), deg_to_rad(29)),
	# 	Ship.ShipClass.CA: Vector2(deg_to_rad(0), deg_to_rad(29)),
	# 	Ship.ShipClass.DD: Vector2(deg_to_rad(0), deg_to_rad(40)),
	# }
	# var ranges = params.get("angle_ranges", default_ranges)

	# # Class-based threat weights — heavier ships are more dangerous to angle against
	# var class_weights = {
	# 	Ship.ShipClass.BB: 3.0,
	# 	Ship.ShipClass.CA: 2.0,
	# 	Ship.ShipClass.DD: 0.2,
	# 	Ship.ShipClass.CV: 0.5,
	# }

	# # Gather all enemy ships whose range * 0.8 encapsulates our ship
	# var encapsulating_threats: Array = []
	# var server_node = ctx.server
	# if server_node != null:
	# 	for enemy in server_node.get_valid_targets(ship.team.team_id):
	# 		if is_instance_valid(enemy) and enemy.health_controller.is_alive():
	# 			var enemy_range = enemy.artillery_controller.get_params()._range
	# 			var dist = ship.global_position.distance_to(enemy.global_position)
	# 			if dist <= enemy_range * 0.8:
	# 				encapsulating_threats.append({
	# 					"position": enemy.global_position,
	# 					"ship_class": enemy.ship_class,
	# 					"dist": dist,
	# 					"enemy_range": enemy_range,
	# 				})
	# 	var unspotted = server_node.get_unspotted_enemies(ship.team.team_id)
	# 	for enemy_ship in unspotted.keys():
	# 		if is_instance_valid(enemy_ship) and enemy_ship.health_controller.is_alive():
	# 			var enemy_range = enemy_ship.artillery_controller.get_params()._range
	# 			var last_known_pos: Vector3 = unspotted[enemy_ship]
	# 			var dist = ship.global_position.distance_to(last_known_pos)
	# 			if dist <= enemy_range * 0.8:
	# 				encapsulating_threats.append({
	# 					"position": last_known_pos,
	# 					"ship_class": enemy_ship.ship_class,
	# 					"dist": dist,
	# 					"enemy_range": enemy_range,
	# 				})

	# # For each threat compute the best ± offset heading (closest to base_bearing),
	# # create a unit Vector2 for that heading scaled by weight, then sum and average.
	# var heading_sum := Vector2.ZERO
	# var total_weight: float = 0.0
	# for threat in encapsulating_threats:
	# 	var to_threat: Vector3 = threat["position"] - ship.global_position
	# 	to_threat.y = 0.0
	# 	if to_threat.length_squared() < 1.0:
	# 		continue
	# 	var bearing = atan2(to_threat.x, to_threat.z)
	# 	var angle_range: Vector2 = ranges.get(threat["ship_class"], Vector2(0, deg_to_rad(30)))
	# 	var ideal = (angle_range.x + angle_range.y) * 0.5
	# 	# 4 candidates that all present 'ideal' degrees to this threat:
	# 	# bow angling (toward threat): bearing ± ideal
	# 	# stern angling (away from threat): bearing + PI ± ideal
	# 	var candidates = [
	# 		ctx.behavior._normalize_angle(bearing + ideal),
	# 		ctx.behavior._normalize_angle(bearing - ideal),
	# 		ctx.behavior._normalize_angle(bearing + PI + ideal),
	# 		ctx.behavior._normalize_angle(bearing + PI - ideal),
	# 	]
	# 	# Pick whichever candidate is closest to base_bearing
	# 	var chosen: float = candidates[0]
	# 	var best_diff: float = absf(angle_difference(base_bearing, candidates[0]))
	# 	for j in range(1, candidates.size()):
	# 		var diff = absf(angle_difference(base_bearing, candidates[j]))
	# 		if diff < best_diff:
	# 			best_diff = diff
	# 			chosen = candidates[j]
	# 	# Weight: closer threats matter more, heavier classes matter more
	# 	var normalized_dist = clampf(threat["dist"] / threat["enemy_range"], 0.0, 1.0)
	# 	var dist_weight = exp(-6.0 * normalized_dist)
	# 	var cw_weight: float = class_weights.get(threat["ship_class"], 1.0)
	# 	var w = dist_weight * cw_weight
	# 	heading_sum += Vector2(sin(chosen), cos(chosen)) * w
	# 	total_weight += w

	# var result := base_bearing
	# if total_weight >= 0.000001:
	# 	var avg = heading_sum / total_weight
	# 	result = atan2(avg.x, avg.y)
	# _cache[key] = result
	# return result

	# # binary search towards threat bearings that optimally angles armor to as many ships as well as possible
	# var threat_bearing = ctx.behavior._get_spotted_danger_center()
	# var left = threat_bearing - deg_to_rad(30) # base autobounce
	# var right = threat_bearing + deg_to_rad(30)
	var frame := Engine.get_physics_frames()
	if frame != _cache_frame:
		_cache.clear()
		_cache_frame = frame
	var key := str(ctx.ship.get_instance_id())
	if _cache.has(key):
		return _cache[key]
	var danger_center = ctx.behavior._get_spotted_danger_center()
	var danger_heading = atan2(danger_center.x - ctx.ship.global_position.x, danger_center.z - ctx.ship.global_position.z)

	_cache[key] = danger_heading # default to heading directly away from threat if no valid targets
	return danger_heading




	var spotted = ctx.server.get_valid_targets(ctx.ship.team.team_id)
	var unspotted = ctx.server.get_unspotted_enemies(ctx.ship.team.team_id)
	# # var enemies = spotted + unspotted.keys()

	# for s in spotted:
	# 	if is_instance_valid(s) and s.health_controller.is_alive():
	# 		var enemy_range = s.artillery_controller.get_params()._range
	# 		var dist = ctx.ship.global_position.distance_to(s.global_position)
	# 		if dist <= enemy_range * 0.8:
	# 			threat_bearing = atan2(s.global_position.x - ctx.ship.global_position.x, s.global_position.z - ctx.ship.global_position.z)
	# 			break
	var threat_center := Vector3.ZERO
	var total_weight := 0.0
	var optimal_heading1 := Vector2.ZERO
	# var optimal_heading2 := Vector2.ZERO
	for s in spotted:
		if is_instance_valid(s) and s.health_controller.is_alive():
			var result = process_enemy(ctx, s, s.global_position, danger_heading)
			if result != null:
				optimal_heading1 += result[0]
				# optimal_heading2 += result[1]
				threat_center += result[1]
				total_weight += result[2]
			# var gun_params: GunParams = s.artillery_controller.get_params()
			# var enemy_range = gun_params._range
			# var dist = ctx.ship.global_position.distance_to(s.global_position)
			# if dist <= enemy_range * 0.9:
			# 	var damage = gun_params.shell1.damage
			# 	var auto_bounce = PI / 2.0 - gun_params.shell1.auto_bounce
			# 	var w = 10_000 / pow(dist, 1.05) # superlinear dropoff with distance
			# 	w *= damage / 1000.0 # scale by damage (relative to a baseline of 1000)
			# 	# var w = 1.0 / (dist * dist / 100_000_000.0 + 1.0) # quadratic dropoff with dithreat_center += s.global_position * w
			# 	var left = atan2(s.global_position.x - ctx.ship.global_position.x, s.global_position.z - ctx.ship.global_position.z) - auto_bounce
			# 	var right = left + auto_bounce * 2.0
			# 	var optimal1 = ctx.behavior._normalize_angle(left)
			# 	var optimal2 = ctx.behavior._normalize_angle(right)
			# 	optimal_heading1 += Vector2(sin(optimal1), cos(optimal1)) * w
			# 	optimal_heading2 += Vector2(sin(optimal2), cos(optimal2)) * w

			# 	threat_center += s.global_position * w
			# 	total_weight += w

	for u in unspotted.keys():
		if is_instance_valid(u) and u.health_controller.is_alive():
			var result = process_enemy(ctx, u, unspotted[u], danger_heading)
			if result != null:
				var uw = 0.7
				optimal_heading1 += result[0] * uw
				# optimal_heading2 += result[1] * uw
				threat_center += result[1] * uw
				total_weight += result[2] * uw

	# var result := base_bearing
	if total_weight >= 0.000001:
		var avg1 = optimal_heading1 / total_weight
		# var avg2 = optimal_heading2 / total_weight
		# var avg_center = threat_center / total_weight
		# var threat_bearing = atan2(avg_center.x - ctx.ship.global_position.x, avg_center.z - ctx.ship.global_position.z)
		var angle1 = atan2(avg1.x, avg1.y)
		# var angle2 = atan2(avg2.x, avg2.y)
		# Pick whichever optimal angle is closer to theat_bearing
		# var diff1 = absf(angle_difference(threat_bearing, angle1))
		# var diff2 = absf(angle_difference(threat_bearing, angle2))
		# return angle1 if diff1 < diff2 else angle2
		_cache[key] = angle1
		return angle1
	return 0.0
		# result = angle1 if diff1 < diff2 else angle2

static func process_enemy(ctx: SkillContext, e: Ship, e_pos: Vector3, danger_heading: float) -> Variant:
	var gun_params: GunParams = e.artillery_controller.get_params()
	var enemy_range = gun_params._range
	var dist = ctx.ship.global_position.distance_to(e_pos)
	if dist <= enemy_range * 0.9:
		# dynamically calculate effective dpm
		var damage = gun_params.shell1.damage
		var reload = gun_params.reload_time
		var caliber = gun_params.shell1.caliber
		var auto_bounce = PI / 2.0 - gun_params.shell1.auto_bounce
		var w = 10_000 / pow(dist, 1.05) # superlinear dropoff with distance
		w *= damage / 1000.0 # scale by damage (relative to a baseline of 1000)
		w *= pow(caliber / 100.0, 2.0) # scale by caliber (relative to a baseline of 100mm, squared for citadel damage)
		w *= 30 / reload # scale by rate of fire (relative to a baseline of 2 rounds per second)
		w *= ctx.behavior.get_threat_class_weight(e.ship_class)
		# Enemies confirmed to be actively shooting at us are higher priority to angle against.
		if ctx.behavior.active_shooters_at_me.has(e):
			w *= 10.0  # Double weight for confirmed shooters
		# var w = 1.0 / (dist * dist / 100_000_000.0 + 1.0) # quadratic dropoff with distance
		var left = atan2(e_pos.x - ctx.ship.global_position.x, e_pos.z - ctx.ship.global_position.z) - auto_bounce
		var right = left + auto_bounce * 2.0
		var optimal1 = ctx.behavior._normalize_angle(left)
		var optimal2 = ctx.behavior._normalize_angle(right)
		# var optimal_heading1 = Vector2(sin(optimal1), cos(optimal1)) * w
		# var optimal_heading2 = Vector2(sin(optimal2), cos(optimal2)) * w
		var diff1 = absf(angle_difference(danger_heading, optimal1))
		var diff2 = absf(angle_difference(danger_heading, optimal2))
		var optimal_heading = Vector2.ZERO
		if diff1 < diff2:
			optimal_heading = Vector2(sin(optimal1), cos(optimal1)) * w
		else:
			optimal_heading = Vector2(sin(optimal2), cos(optimal2)) * w

		var threat_center = e_pos * w
		var total_weight = w

		return [optimal_heading, threat_center, total_weight]
	return null
