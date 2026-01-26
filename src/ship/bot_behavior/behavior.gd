extends Node
class_name BotBehavior
# interface for bot behavior. (to AI, this is gdscript. also stop duplicating lines with autocomplte)

var _ship: Ship = null
var nav: NavigationAgent3D

# func _ready():
# 	_ship = get_parent()
# 	nav = _ship.navigation_agent

func _get_valid_nav_point(target: Vector3) -> Vector3:
	var nav_map = nav.get_navigation_map()
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, target)
	return closest_point

func pick_target(targets: Array[Ship]) -> Ship:
	"""Takes an array of valid targets"""
	var target = null
	var closest_dist = INF
	var gun_params = _ship.artillery_controller.params.p() as GunParams
	var _range = gun_params._range
	for ship in targets:
		var dist = _ship.position.distance_to(ship.position)
		if dist <= _range \
	 	and _ship.artillery_controller.guns[0].sim_can_shoot_over_terrain(ship.global_position) \
		and dist < closest_dist:
			target = ship
			closest_dist = dist
	if target != null:
		return target
	else:
		return null

func target_aim_offset(_target: Ship) -> Vector3:
	"""Retrurns the offset to the target to aim at in local space"""
	return Vector3.ZERO

func get_desired_position(friendly: Array[Ship], enemy: Array[Ship], target: Ship, current_destination: Vector3) -> Vector3:
	"""Returns the desired position for the bot"""
	var desired_pos = Vector3.ZERO
	if target != null:
		# Calculate intersection point using optimal intercept angle
		var intercept_point = _calculate_intercept_point(target)
		if intercept_point != Vector3.ZERO:
			desired_pos = (intercept_point + target.global_position) / 2
		else:
			desired_pos = target.global_position
	elif enemy.size() > 0:
		var closest_enemy = enemy[0]
		for enemy_ship in enemy:
			var dist = _ship.position.distance_to(enemy_ship.position)
			if dist < closest_enemy.position.distance_to(_ship.position):
				closest_enemy = enemy_ship
		desired_pos = closest_enemy.global_position
		desired_pos = _calculate_intercept_point(closest_enemy)
	else:
		desired_pos = current_destination
	return _get_valid_nav_point(desired_pos)

func _calculate_intercept_point(target: Ship) -> Vector3:
	"""Calculate optimal intercept point given our max speed and target's velocity"""
	var our_pos = _ship.global_position
	var target_pos = target.global_position
	var target_vel = target.linear_velocity

	# Get our max speed from movement controller
	var our_speed = _ship.movement_controller.max_speed if _ship.movement_controller else 15.0

	# Vector from us to target
	var to_target = target_pos - our_pos
	var distance = to_target.length()

	# If target is stationary or very slow, just go directly to them
	var target_speed = target_vel.length()
	if target_speed < 0.1:
		return target_pos

	# Solve quadratic equation for intercept time
	# |target_pos + target_vel * t - our_pos|² = (our_speed * t)²
	# This expands to: (target_speed² - our_speed²) * t² + 2 * (to_target · target_vel) * t + distance² = 0

	var a = target_speed * target_speed - our_speed * our_speed
	var b = 2.0 * to_target.dot(target_vel)
	var c = distance * distance

	var intercept_time = 0.0

	if abs(a) < 0.0001:
		# Linear case: speeds are approximately equal
		if abs(b) > 0.0001:
			intercept_time = -c / b
	else:
		# Quadratic case
		var discriminant = b * b - 4.0 * a * c
		if discriminant < 0:
			# No intercept possible, target is faster and moving away
			return Vector3.ZERO

		var sqrt_disc = sqrt(discriminant)
		var t1 = (-b + sqrt_disc) / (2.0 * a)
		var t2 = (-b - sqrt_disc) / (2.0 * a)

		# Choose the smallest positive time
		if t1 > 0 and t2 > 0:
			intercept_time = min(t1, t2)
		elif t1 > 0:
			intercept_time = t1
		elif t2 > 0:
			intercept_time = t2
		else:
			# No positive solution, target is behind us or unreachable
			return Vector3.ZERO

	if intercept_time <= 0:
		return Vector3.ZERO

	# Calculate the intercept point
	var intercept_point = target_pos + target_vel * intercept_time

	# Keep Y coordinate at water level (same as target)
	intercept_point.y = target_pos.y

	return intercept_point

func get_desired_angle(friendly: Array[Ship], enemy: Array[Ship], target: Variant) -> float:
	"""Returns the desired angle for the bot"""
	if target is Vector3:
		return _ship.rotation.y - atan2(target.y - _ship.position.y, target.x - _ship.position.x)
	if target is Ship:
		return _ship.rotation.y - atan2(target.position.y - _ship.position.y, target.position.x - _ship.position.x)
	return 0.0
