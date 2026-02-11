extends BotBehavior
class_name BBBehavior

var ammo = ShellParams.ShellType.AP

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	var target = null
	var best_priority = -1
	var gun_range = _ship.artillery_controller.get_params()._range

	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
		# pick apparently biggest target + most broadside
		var priority = ship.movement_controller.ship_length / dist * abs(sin(angle)) + ship.movement_controller.ship_beam / dist * abs(cos(angle))
		priority *= 1.7 - hp_ratio
		priority = priority * 0.7 + dist / gun_range * priority * 0.3

		# Significantly boost priority for targets within gun range
		if dist <= gun_range:
			priority *= 10.0  # Strong preference for targets we can actually shoot

		if priority > best_priority:
			target = ship
			best_priority = priority
	return target

func pick_ammo(_target: Ship) -> int:
	# Ammo is set as side effect in target_aim_offset
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _target.global_position - _ship.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var offset = Vector3(0, 0, 0)
	angle = abs(angle)
	if angle > PI / 2.0:
		angle = PI - angle

	# Default to AP
	ammo = ShellParams.ShellType.AP

	match _target.ship_class:
		Ship.ShipClass.BB:
			if angle < deg_to_rad(10):
				# HE against heavily angled battleships (< 10 degrees from bow/stern)
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2.0  # superstructure
			elif angle < deg_to_rad(30):
				# AP at battleship superstructure when angled (but not heavily angled)
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 2.0  # superstructure
			else:
				ammo = ShellParams.ShellType.AP
				offset.y = 0.1
		Ship.ShipClass.CA:
			if angle < deg_to_rad(30):
				# AP at angled cruiser bow/stern when angled 30 degrees
				ammo = ShellParams.ShellType.AP
				offset.z -= _target.movement_controller.ship_length / 2.0 * 0.75  # bow/stern
			else:
				# AP at broadside cruisers waterline
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0  # waterline
		Ship.ShipClass.DD:
			# HE at destroyers
			ammo = ShellParams.ShellType.HE
			offset.y = 1.0
	return offset

func get_desired_position(friendly: Array[Ship], enemy: Array[Ship], target: Ship, current_destination: Vector3) -> Vector3:
	if target == null:
		return current_destination

	# Get cached data from server
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	var avg_enemy = Vector3.ZERO
	if server_node:
		avg_enemy = server_node.get_enemy_avg_position(_ship.team.team_id)
	else:
		for ship in enemy:
			avg_enemy += ship.global_position
		avg_enemy /= enemy.size()

	var target_disp = _ship.global_position - target.global_position
	var r = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
	var hp_damage = 1.0 - hp_ratio
	var base_range = 1.0
	match target.ship_class:
		Ship.ShipClass.CA:
			base_range = 0.5
		Ship.ShipClass.DD:
			base_range = 0.3
		Ship.ShipClass.BB:
			base_range = 0.7
	var min_range = base_range * r + 5_000 * clamp(hp_damage - 0.5, 0.0, 1.0)
	r = min(r, min_range)
	var desired_position = target.global_position + target_disp.normalized() * r

	# Calculate spread offset to avoid clumping with teammates
	var spread_offset = Vector3.ZERO
	var min_spread_distance = 500.0  # Minimum distance to maintain from teammates
	for ship in friendly:
		if ship == _ship:
			continue
		var to_teammate = _ship.global_position - ship.global_position
		var dist_to_teammate = to_teammate.length()
		if dist_to_teammate < min_spread_distance * 3.0 and dist_to_teammate > 0.1:
			# Push away from nearby teammates, stronger when closer
			var push_strength = 1.0 - (dist_to_teammate / (min_spread_distance * 3.0))
			spread_offset += to_teammate.normalized() * push_strength * min_spread_distance

	desired_position += spread_offset

	# Check if should retreat (below 50% HP or outnumbered)
	var is_outnumbered = enemy.size() > friendly.size()
	var should_retreat = hp_ratio < 0.5 or is_outnumbered

	if should_retreat:
		# Retreat toward nearest friendly cluster
		var retreat_direction = (_ship.global_position - avg_enemy).normalized()
		var retreat_strength = 0.3 if is_outnumbered else 0.5
		if hp_ratio < 0.5:
			retreat_strength = 0.5
			# When low HP, bias toward nearest friendly cluster
			if server_node:
				var nearest_cluster = server_node.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
				if not nearest_cluster.is_empty():
					var cluster_center: Vector3 = nearest_cluster.center
					var to_cluster = (cluster_center - _ship.global_position).normalized()
					# Blend retreat direction with cluster direction
					retreat_direction = (retreat_direction * 0.5 + to_cluster * 0.5).normalized()
		desired_position = desired_position + retreat_direction * r * retreat_strength

	return _get_valid_nav_point(desired_position)
