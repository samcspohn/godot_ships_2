extends BotBehavior
class_name CABehavior

var ammo = ShellParams.ShellType.HE

# Island cover state
var current_island: StaticBody3D = null
var island_position_valid: bool = false
var island_cache_timer: float = 0.0
const ISLAND_CACHE_DURATION: float = 5.0  # Re-evaluate island choice every 5 seconds

# Cover preference timer - prefer cover for first 60 seconds
var cover_preference_timer: float = 60.0
const COVER_PREFERENCE_DURATION: float = 60.0

# Track if we're in a good cover position
var is_in_cover: bool = false
const IN_COVER_THRESHOLD: float = 300.0  # Consider "in cover" if within this distance of cover position

# Island abandonment thresholds (as fraction of gun range)
const ABANDON_TOO_FAR: float = 0.80  # Abandon if enemies move beyond 80% range
const ABANDON_TOO_CLOSE: float = 0.35  # Abandon if enemies get within 35% range
const AGGRESSIVE_RANGE: float = 0.60  # High HP: position at 50% gun range
const DEFENSIVE_RANGE: float = 0.70  # Low HP: position at 70% gun range

# Approximate island radius cache
var island_radius_cache: Dictionary = {}  # StaticBody3D -> float

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
		var priority_mod = 1.0
		match ship.ship_class:
			Ship.ShipClass.DD:
				priority_mod = 1.5
			Ship.ShipClass.CA:
				priority_mod = 1.2
		priority *= priority_mod
		priority *= 1.5 - hp_ratio
		priority = priority * 0.6 + dist / gun_range * priority * 0.4

		# Significantly boost priority for targets within gun range
		if dist <= gun_range:
			priority *= 10.0  # Strong preference for targets we can actually shoot

		if priority > best_priority:
			target = ship
			best_priority = priority
	return target

func pick_ammo(_target: Ship) -> int:
	# Ammo is determined as a side effect of target_aim_offset
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var dist = disp.length()
	var offset = Vector3.ZERO

	# Default to HE
	ammo = ShellParams.ShellType.HE

	# Check if target is broadside (sin(angle) > ~60 degrees means showing side)
	var is_broadside = abs(sin(angle)) > sin(deg_to_rad(60))

	match _target.ship_class:
		Ship.ShipClass.BB:
			if is_broadside and dist < 6000:
				# AP at broadside battleships upper belt when < 6000
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 4  # Upper belt
			else:
				# HE at battleship superstructure when angled
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2  # Superstructure
		Ship.ShipClass.CA:
			if is_broadside:
				if dist < 7000:
					# AP at broadside cruisers lower belt when < 7000
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5  # Waterline/lower belt
				elif dist < 10000:
					# AP at broadside cruisers upper belt when < 10000
					ammo = ShellParams.ShellType.AP
					offset.y = _target.movement_controller.ship_height / 4  # Upper belt
				else:
					# HE at cruiser upper belt when angled or far
					ammo = ShellParams.ShellType.HE
					offset.y = _target.movement_controller.ship_height / 3
			else:
				# HE at cruiser upper belt when angled
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 3
		Ship.ShipClass.DD:
			# HE at destroyers always
			ammo = ShellParams.ShellType.HE
			offset.y = 1.0
	return offset


func get_desired_position(friendly: Array[Ship], enemy: Array[Ship], target: Ship, current_destination: Vector3) -> Vector3:
	if target == null:
		return current_destination

	# Get cached average enemy position from server
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	var avg_enemy = Vector3.ZERO
	if server_node:
		avg_enemy = server_node.get_enemy_avg_position(_ship.team.team_id)
	else:
		for ship in enemy:
			avg_enemy += ship.global_position
		avg_enemy /= enemy.size()

	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	# Check if we should abandon current island cover
	var should_find_new_island = false
	var dist_to_target = _ship.global_position.distance_to(target.global_position)

	if current_island != null and island_position_valid:
		# Check if enemies are too far (need closer cover)
		if dist_to_target > gun_range * ABANDON_TOO_FAR:
			should_find_new_island = true
			island_position_valid = false
		# Check if enemies are too close (need to kite and find farther cover)
		elif dist_to_target < gun_range * ABANDON_TOO_CLOSE:
			should_find_new_island = true
			island_position_valid = false
			# Force kiting behavior when enemies too close
			is_in_cover = false

	# Update island cache timer
	island_cache_timer -= 1.0 / Engine.physics_ticks_per_second
	if island_cache_timer <= 0 or should_find_new_island:
		island_cache_timer = ISLAND_CACHE_DURATION
		current_island = find_optimal_island(target, gun_range, hp_ratio, dist_to_target)
		island_position_valid = current_island != null

	# Update cover preference timer
	cover_preference_timer -= 1.0 / Engine.physics_ticks_per_second
	if cover_preference_timer < 0:
		cover_preference_timer = 0.0

	# If we have an island, use island cover logic
	if island_position_valid and current_island != null:
		var cover_pos = get_island_cover_position(current_island, avg_enemy, target, gun_range)
		if cover_pos != Vector3.ZERO:
			# Check if we're already in cover
			var dist_to_cover = _ship.global_position.distance_to(cover_pos)
			is_in_cover = dist_to_cover < IN_COVER_THRESHOLD

			# If in cover and not detected, stay put
			if is_in_cover and not _ship.visible_to_enemy:
				return _ship.global_position  # Don't move

			return cover_pos

	is_in_cover = false

	# Only fall back to kiting if cover preference timer has expired
	if cover_preference_timer > 0:
		# Still prefer cover, but no island found - try to find one more aggressively
		# For now just return current position to avoid kiting
		if not _ship.visible_to_enemy:
			return _ship.global_position

	# Fallback to normal positioning
	return get_fallback_position(friendly, enemy, target, avg_enemy, gun_range, hp_ratio)


func find_optimal_island(target: Ship, gun_range: float, hp_ratio: float, current_dist_to_target: float) -> StaticBody3D:
	"""Find the best island for cover based on HP and tactical situation."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null or server_node.map == null:
		return null

	var map: Map = server_node.map
	if map.islands.size() == 0:
		return null

	var target_pos = target.global_position
	var my_pos = _ship.global_position

	# Determine ideal range based on HP
	# High HP = aggressive (closer), Low HP = defensive (farther)
	var ideal_range_ratio = lerp(AGGRESSIVE_RANGE, DEFENSIVE_RANGE, 1.0 - hp_ratio)
	var ideal_distance = gun_range * ideal_range_ratio

	# If enemies too close, prefer islands that let us kite farther
	var prefer_farther = current_dist_to_target < gun_range * ABANDON_TOO_CLOSE

	var best_island: StaticBody3D = null
	var best_score = -INF

	for island in map.islands:
		if not is_instance_valid(island):
			continue

		var island_pos = island.global_position

		# Island must be within gun range of target (so we can shoot from behind it)
		var island_to_target = island_pos.distance_to(target_pos)
		if island_to_target > gun_range * 0.85:
			continue  # Too far from target to shoot over

		var dist_to_us = island_pos.distance_to(my_pos)

		# Calculate what our engagement distance would be from this island
		var potential_engagement_dist = island_to_target

		# Score based on how close to ideal range this island would put us
		var range_diff = abs(potential_engagement_dist - ideal_distance)
		var score = -range_diff  # Closer to ideal = higher score

		# Prefer closer islands (easier to reach) with a smaller weight
		score -= dist_to_us * 0.5

		# If we need to kite farther, strongly prefer islands farther from target
		if prefer_farther:
			score += island_to_target * 3.0

		# Bonus for islands that are roughly between us and enemies (good positioning)
		var to_target_dir = (target_pos - my_pos).normalized()
		var to_island_dir = (island_pos - my_pos).normalized()
		var alignment = to_target_dir.dot(to_island_dir)
		if alignment > 0:
			score += alignment * 300.0

		if score > best_score:
			best_score = score
			best_island = island

	return best_island


func get_island_cover_position(island: StaticBody3D, avg_enemy: Vector3, target: Ship, gun_range: float) -> Vector3:
	"""Get position behind island, approximating island as a circle."""
	var island_pos = island.global_position
	var island_radius = get_island_radius(island)

	# Direction from island to average enemy
	var to_enemy = (avg_enemy - island_pos).normalized()

	# We want to be on the opposite side
	var cover_dir = -to_enemy

	# Base cover distance - just outside the island
	var cover_distance = island_radius + 200.0

	# If we're detected, move further behind the island
	if _ship.visible_to_enemy:
		cover_distance = island_radius + 400.0

	var cover_pos = island_pos + cover_dir * cover_distance
	cover_pos.y = 0.0

	# Check if we can actually shoot the target from there
	var dist_to_target = cover_pos.distance_to(target.global_position)
	if dist_to_target > gun_range * 0.9:
		# Too far, move closer to island edge toward target
		var to_target = (target.global_position - island_pos).normalized()
		# Blend between cover direction and target direction
		var blended_dir = (cover_dir * 0.6 + to_target * 0.4).normalized()
		cover_pos = island_pos + blended_dir * cover_distance
		cover_pos.y = 0.0

	# Only check shell arcs if we're close to the island (within 500m of cover position)
	var dist_to_cover = _ship.global_position.distance_to(cover_pos)
	if dist_to_cover < 500.0:
		# We're near the island, verify we can shoot over it
		if not can_shoot_target_from_position(cover_pos, target):
			# Can't shoot from here, try moving along the island edge
			cover_pos = find_shootable_position_near_island(island, island_pos, island_radius, target, avg_enemy)
			if cover_pos == Vector3.ZERO:
				return Vector3.ZERO  # No valid position found

	return _get_valid_nav_point(cover_pos)


func get_island_radius(island: StaticBody3D) -> float:
	"""Get or compute approximate island radius."""
	if island_radius_cache.has(island):
		return island_radius_cache[island]

	# Compute from edge points if available
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node and server_node.map:
		var edge_points = server_node.map.get_edge_points_for_island(island)
		if edge_points.size() > 0:
			var island_pos = island.global_position
			var max_dist = 0.0
			for point in edge_points:
				var dist = island_pos.distance_to(point)
				if dist > max_dist:
					max_dist = dist
			island_radius_cache[island] = max_dist
			return max_dist

	# Fallback: estimate from position sampling
	var radius = 500.0  # Default
	island_radius_cache[island] = radius
	return radius


func find_shootable_position_near_island(_island: StaticBody3D, island_pos: Vector3, island_radius: float, target: Ship, avg_enemy: Vector3) -> Vector3:
	"""Find a position near the island where we can shoot the target."""
	var to_enemy = (avg_enemy - island_pos).normalized()
	var cover_distance = island_radius + 300.0

	# Sample a few positions around the back half of the island
	for angle_offset in [-0.3, 0.0, 0.3, -0.6, 0.6]:
		var sample_dir = (-to_enemy).rotated(Vector3.UP, angle_offset)
		var sample_pos = island_pos + sample_dir * cover_distance
		sample_pos.y = 0.0

		if can_shoot_target_from_position(sample_pos, target):
			return sample_pos

	return Vector3.ZERO


func can_shoot_target_from_position(pos: Vector3, target: Ship) -> bool:
	"""Check if we can shoot over terrain at the target from the given position."""
	var shell_params = _ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return false

	var target_pos = target.global_position + target_aim_offset(target)
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(pos, target_pos, shell_params)

	if sol[0] == null:
		return false

	var launch_vector = sol[0]
	var flight_time = sol[1]

	var can_shoot = Gun.sim_can_shoot_over_terrain_static(pos, launch_vector, flight_time, shell_params, _ship)
	return can_shoot.can_shoot_over_terrain


func get_fallback_position(friendly: Array[Ship], _enemy: Array[Ship], target: Ship, avg_enemy: Vector3, gun_range: float, hp_ratio: float) -> Vector3:
	"""Standard kiting/positioning when no island cover available."""
	var target_disp = _ship.global_position - target.global_position
	var hp_damage = 1.0 - hp_ratio
	var base_range = 1.0
	match target.ship_class:
		Ship.ShipClass.CA:
			base_range = 0.5
		Ship.ShipClass.DD:
			base_range = 0.3
		Ship.ShipClass.BB:
			base_range = 0.7
	var min_range = base_range * gun_range + 5_000 * clamp(hp_damage - 0.5, 0.0, 1.0)
	var r = min(gun_range, min_range)
	var desired_position = target.global_position + target_disp.normalized() * r

	# Calculate spread offset to avoid clumping with teammates
	var spread_offset = Vector3.ZERO
	var min_spread_distance = 500.0
	for ship in friendly:
		if ship == _ship:
			continue
		var to_teammate = _ship.global_position - ship.global_position
		var dist_to_teammate = to_teammate.length()
		if dist_to_teammate < min_spread_distance and dist_to_teammate > 0.1:
			spread_offset += to_teammate.normalized() * (min_spread_distance - dist_to_teammate)

	desired_position += spread_offset

	# Cruiser prefers to kite - bias away from enemies
	var away_from_enemy = (_ship.global_position - avg_enemy).normalized()
	desired_position += away_from_enemy * r * 0.2

	# Only retreat toward teammates if below 50% HP
	if hp_ratio < 0.5:
		var nearest_friendly_pos = Vector3.ZERO
		var server_ref: GameServer = _ship.get_node_or_null("/root/Server")
		if server_ref:
			var nearest_cluster = server_ref.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
			if nearest_cluster.size() > 0:
				nearest_friendly_pos = nearest_cluster.center
			else:
				nearest_friendly_pos = server_ref.get_team_avg_position(_ship.team.team_id)
		else:
			for ship in friendly:
				nearest_friendly_pos += ship.global_position
			nearest_friendly_pos /= friendly.size()
		var retreat_dir = away_from_enemy * 0.7 + (nearest_friendly_pos - _ship.global_position).normalized() * 0.3
		desired_position = _ship.global_position + retreat_dir.normalized() * r * 0.5

	return _get_valid_nav_point(desired_position)
