class_name SkillFlank
extends BotSkill

const MAP_HALF_WIDTH: float = 17500.0
const MIN_RADIUS: float = 2000.0  # Prevent radius collapsing to zero near the battle center

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var ship_pos = ship.global_position

	# var enemy_avg = ctx.server.get_enemy_avg_position(ship.team.team_id)
	# if enemy_avg == Vector3.ZERO:
	# 	return null

	# --- Dynamic battle center ---
	# Average the positions of all ships (friendly + known enemies) within gun range.
	# This anchors the flanking arc around the local fight rather than the map origin.
	var gun_range: float = MAP_HALF_WIDTH
	if ship.artillery_controller != null:
		gun_range = ship.artillery_controller.get_params()._range

	var enemy_pos: Array = []
	var friendly_pos: Array = []

	# Friendly ships within gun range (exclude self)
	for friendly in ctx.server.get_team_ships(ship.team.team_id):
		if friendly == ship or not is_instance_valid(friendly):
			continue
		if friendly.global_position.distance_to(ship_pos) <= gun_range:
			friendly_pos.append(friendly.global_position)

	# Spotted enemies within gun range
	for enemy in ctx.server.get_valid_targets(ship.team.team_id):
		if not is_instance_valid(enemy):
			continue
		if enemy.global_position.distance_to(ship_pos) <= gun_range:
			enemy_pos.append(enemy.global_position)

	# Last-known unspotted enemies within gun range
	var unspotted = ctx.server.get_unspotted_enemies(ship.team.team_id)
	for enemy in unspotted.keys():
		var last_pos: Vector3 = unspotted[enemy]
		if last_pos.distance_to(ship_pos) <= gun_range:
			enemy_pos.append(last_pos)

	# # Compute battle center; fall back to map center when no nearby ships found
	# var battle_center: Vector3
	# if enemy_pos.is_empty():
	# 	battle_center = Vector3.ZERO
	# else:
	# 	var sum = Vector3.ZERO
	# 	for p in enemy_pos:
	# 		sum += p
	# 	battle_center = sum / float(enemy_pos.size())
	var battle_center = ctx.behavior._get_danger_center()
	var friendly_center: Vector3
	if friendly_pos.is_empty():
		friendly_center = Vector3.ZERO
	else:
		var sum = Vector3.ZERO
		for p in friendly_pos:
			sum += p
		friendly_center = sum / float(friendly_pos.size())
	battle_center.y = 0.0

	# Dynamic radius: preserve the ship's current distance from the battle center.
	# This means the ship stays on the same conceptual orbit and just slides along it.
	var to_center = Vector3(ship_pos.x - battle_center.x, 0.0, ship_pos.z - battle_center.z)
	var dynamic_radius = max(to_center.length(), MIN_RADIUS)

	# destination is point on the circle defined by battle_center + dynamic_radius
	# the destination is 45 deg from the ships current position away from friendly average
	# figure out what side of the line defined by battle_center + friendly_center the ship is on, then step along the circle in that direction
	var to_friendly_from_center = Vector3(friendly_center.x - battle_center.x, 0.0, friendly_center.z - battle_center.z)
	var side = sign(to_center.x * to_friendly_from_center.z - to_center.z * to_friendly_from_center.x)
	var step = deg_to_rad(params.get("flank_angle_deg", 45.0))
	var ship_angle = atan2(to_center.x, to_center.z)
	var target_angle = ship_angle + step * side
	var flank_pos = battle_center + Vector3(sin(target_angle), 0.0, cos(target_angle)) * dynamic_radius

	flank_pos = ctx.behavior._get_valid_nav_point(flank_pos)
	return NavIntent.create(flank_pos, target_angle + PI)

	# # Angle of this ship on the dynamic circle (from battle center)
	# var ship_angle = atan2(to_center.x, to_center.z)

	# # Angle of the enemy average relative to battle center
	# var to_enemy_from_center = Vector3(enemy_avg.x - battle_center.x, 0.0, enemy_avg.z - battle_center.z)
	# var enemy_angle = atan2(to_enemy_from_center.x, to_enemy_from_center.z)

	# # Angular difference wrapped to [-PI, PI] to find the shortest flanking direction
	# var angle_diff = enemy_angle - ship_angle
	# while angle_diff > PI:
	# 	angle_diff -= TAU
	# while angle_diff < -PI:
	# 	angle_diff += TAU

	# # Step along the circle toward the enemy average
	# var step = deg_to_rad(params.get("flank_angle_deg", 45.0)) * sign(angle_diff)
	# var target_angle = ship_angle + step

	# # Target point on the dynamic circle around the battle center
	# var flank_pos = battle_center + Vector3(sin(target_angle), 0.0, cos(target_angle)) * dynamic_radius

	# flank_pos = ctx.behavior._get_valid_nav_point(flank_pos)

	# var to_dest = flank_pos - ship_pos
	# to_dest.y = 0.0

	# # Face toward the enemy average from the flank position
	# var to_enemy = enemy_avg - flank_pos
	# to_enemy.y = 0.0
	# var heading = atan2(to_enemy.x, to_enemy.z) if to_enemy.length_squared() > 1.0 else ctx.behavior._get_ship_heading()

	# return NavIntent.create(flank_pos, heading)
