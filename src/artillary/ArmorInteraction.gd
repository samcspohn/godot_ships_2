extends Node

class_name _ArmorInteraction

enum HitResult {
	PENETRATION,
	RICOCHET,
	OVERPENETRATION,
	SHATTER,
	CITADEL,
	CITADEL_OVERPEN,
	WATER,
	TERRAIN
}

enum ArmorResult {
	RICOCHET,
	OVERPEN,
	PEN,
	CITADEL,
	SHATTER,
}

class ArmorResultData:
	var result_type: HitResult
	var explosion_position: Vector3
	var armor_part: ArmorPart
	var velocity: Vector3
	var ship: Ship
	func _init(_result_type: HitResult, _explosion_position: Vector3, _armor_part: ArmorPart, _velocity: Vector3, _ship: Ship) -> void:
		result_type = _result_type
		explosion_position = _explosion_position
		armor_part = _armor_part
		velocity = _velocity
		ship = _ship

func process_travel(projectile: ProjectileManager.ProjectileData, prev_pos: Vector3, t: float, space_state: PhysicsDirectSpaceState3D) -> ArmorResultData:
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.from = prev_pos
	ray_query.to = projectile.position
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 | (1 << 1) # 1 = terrain, 1<<1 = armor
	var result = space_state.intersect_ray(ray_query)

	# var aabb = AABB()
	# aabb.size = abs(ray_query.to - ray_query.from)
	# var absolute_pos = (ray_query.from + ray_query.to) / 2.0
	# aabb.position = absolute_pos - aabb.size / 2.0

	# var server: GameServer = get_node_or_null("/root/Server")
	# if server != null:
	# 	for p in server.players.values():
	# 		var ship: Ship = p[0] as Ship
	# 		aabb.position = ship.to_local(absolute_pos) - aabb.size / 2.0
	# 		if ship.aabb.intersects(aabb):
	# 			# print("Ship %s AABB intersects with shell path AABB" % ship.name)
	# 			# back off a bit to ensure we start outside the ship
	# 			var dir = (ray_query.to - ray_query.from).normalized()
	# 			ray_query.from -= dir * 1.2
	# 			break
	
	if projectile.owner == null:
		# No owner do not process ship hits, do terrain and water only
		if !result.is_empty():
			if result.get('position').y <= 0.0001:
				return ArmorResultData.new(HitResult.WATER, result.get('position'), null, Vector3.ZERO, null)
			else:
				return ArmorResultData.new(HitResult.TERRAIN, result.get('position'), null, Vector3.ZERO, null)
		else:
			return null
				

	if (result.is_empty() and projectile.position.y < 0.0) or (!result.is_empty() and abs(result.get('position').y) < 0.0001 and !(result.get('collider') is ArmorPart)):
		# Check for water hit
		var dir = projectile.position - prev_pos
		var distance_to_water = - ray_query.from.y / dir.y if abs(dir.y) > 0.0001 else 0
		if distance_to_water <= (projectile.position - prev_pos).length():
			var water_hit_pos = ray_query.from + dir * distance_to_water
			var impact_vel = ProjectilePhysicsWithDrag.calculate_velocity_at_time(
				projectile.launch_velocity,
				t,
				projectile.params.drag
			)
			var fuzed_position = ProjectilePhysicsWithDrag.calculate_position_at_time(
				water_hit_pos,
				impact_vel,
				projectile.params.fuze_delay,
				projectile.params.drag * 800.0
			)
			var ship_ray_query = PhysicsRayQueryParameters3D.new()
			ship_ray_query.from = water_hit_pos
			ship_ray_query.to = fuzed_position
			ship_ray_query.hit_back_faces = true
			ship_ray_query.hit_from_inside = false
			ship_ray_query.collision_mask = 1 << 1 # 1<<1 = armor
			var ship_result = space_state.intersect_ray(ship_ray_query)
			if ship_result.is_empty():
				return ArmorResultData.new(HitResult.WATER, water_hit_pos, null, impact_vel, null)
			else:
				var hit_pos = ship_result.get('position')
				var total_dist = (fuzed_position - water_hit_pos).length()
				var hit_dist = (hit_pos - water_hit_pos).length()
				var t_impact = projectile.params.fuze_delay * (hit_dist / total_dist)
				var water_impact_vel = ProjectilePhysicsWithDrag.calculate_velocity_at_time(
					impact_vel,
					t_impact,
					projectile.params.drag * 800.0
				)
				return process_hit(ship_result['collider'],
				hit_pos,
				ship_result['normal'],
				projectile,
				water_impact_vel,
				ship_result['face_index'],
				t_impact,
				space_state,
				true
			)
	elif !result.is_empty():
		var hit_node = result.get('collider')
		if hit_node is ArmorPart:
			return process_hit(hit_node,
			result.get('position'),
			result.get('normal'),
			projectile,
			ProjectilePhysicsWithDrag.calculate_velocity_at_time(
				projectile.launch_velocity,
				t,
				projectile.params.drag
			),
			result.get('face_index'),
			-1.0,
			space_state,
			false
			)
		elif result.get('position').y <= 0.0001:
			return ArmorResultData.new(HitResult.WATER, result.get('position'), null, Vector3.ZERO, null)
		else:
			return ArmorResultData.new(HitResult.TERRAIN, result.get('position'), null, Vector3.ZERO, null)
	return null

class ShellData:
	var position: Vector3
	var end_position: Vector3
	var velocity: Vector3
	var params: ShellParams
	var fuze: float = -1.0 # Time since impact, negative means not yet armed
	var pen: float = 0.0

	func calc_end_position():
		var fuze_left = params.fuze_delay - fuze
		if fuze < 0.0:
			fuze_left = 1.0
		end_position = position + velocity * fuze_left


func get_next_hit(ray_query: PhysicsRayQueryParameters3D, space_state: PhysicsDirectSpaceState3D) -> Dictionary:
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.exclude = []
	ray_query.collision_mask = 1 << 1 # 1<<1 = armor

	var result = space_state.intersect_ray(ray_query)
	var exclude = []

	if result.is_empty():
		return {}
	var closest_result = result
	while !result.is_empty():
		exclude.append(result.get('collider'))
		ray_query.exclude = exclude
		result = space_state.intersect_ray(ray_query)
		if !result.is_empty() and (result.get('position') - ray_query.from).length() < (closest_result.get('position') - ray_query.from).length():
			closest_result = result
		# return result if !result.empty() else {}
	var armor: ArmorPart = closest_result.get('collider') if closest_result.get('collider') is ArmorPart else null
	if armor != null:
		return {'armor': armor, 'position': closest_result.get('position'), 'normal': closest_result.get('normal'), 'face_index': closest_result.get('face_index')}
	return {}

func get_part_hit(_ship: Ship, shell_pos: Vector3, space_state: PhysicsDirectSpaceState3D) -> ArmorPart:
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.from = shell_pos + _ship.global_basis.x.normalized() * 60.0
	ray_query.to = shell_pos
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 << 1 # 1<<1 = armor

	var exclude = []
	var armor_hit = space_state.intersect_ray(ray_query)
	var right_armor_list = []
	while !armor_hit.is_empty():
		right_armor_list.append(armor_hit.get('collider') as ArmorPart)
		exclude.append(armor_hit.get('collider'))
		ray_query.exclude = exclude
		armor_hit = space_state.intersect_ray(ray_query)
	
	if right_armor_list.size() == 0:
		return null # outside ship
	else:
		var left_armor_list = []
		ray_query.from = shell_pos + _ship.global_basis.x.normalized() * -60.0
		ray_query.to = shell_pos
		exclude = []
		ray_query.exclude = exclude # Reset the ray query's exclude list
		armor_hit = space_state.intersect_ray(ray_query)
		while !armor_hit.is_empty():
			left_armor_list.append(armor_hit.get('collider') as ArmorPart)
			exclude.append(armor_hit.get('collider'))
			ray_query.exclude = exclude
			armor_hit = space_state.intersect_ray(ray_query)
		if left_armor_list.size() == 0:
			return null # outside ship
		var a = right_armor_list if right_armor_list.size() < left_armor_list.size() else left_armor_list
		return a[a.size() - 1] if a.size() > 0 else null

func armor_result_to_string(result: ArmorResult) -> String:
	match result:
		ArmorResult.RICOCHET:
			return "RICOCHET"
		ArmorResult.OVERPEN:
			return "OVERPEN"
		ArmorResult.PEN:
			return "PENETRATION"
		ArmorResult.CITADEL:
			return "CITADEL"
		ArmorResult.SHATTER:
			return "SHATTER"
	return "UNKNOWN"

func process_hit(hit_node: ArmorPart, hit_position: Vector3, hit_normal: Vector3, projectile: ProjectileManager.ProjectileData, impact_velocity: Vector3, face_index: int, fuze: float, space_state: PhysicsDirectSpaceState3D, hit_water: bool) -> ArmorResultData:
	var armor_ray = PhysicsRayQueryParameters3D.new()
	armor_ray.hit_back_faces = true
	armor_ray.hit_from_inside = false
	armor_ray.collision_mask = 1 << 1 # 1<<1 = armor

	var first_hit_pos = hit_position
	var shell = ShellData.new()
	shell.position = hit_position # always starts on armor
	shell.velocity = impact_velocity
	shell.fuze = fuze
	shell.params = projectile.params
	shell.calc_end_position()
	var params = projectile.params
	var result = null
	var hit_cit = false
	var over_pen = false
	var ship = hit_node.ship

	var events = []
	events.append("Processing Shell: %s %s " % [projectile.params.caliber, projectile.params.type])
	events.append("Ship: %s pos=(%.1f, %.1f, %.1f), rot=(%.1f, %.1f, %.1f)" % [ship.name, ship.global_transform.origin.x, ship.global_transform.origin.y, ship.global_transform.origin.z, rad_to_deg(ship.global_transform.basis.get_euler().x), rad_to_deg(ship.global_transform.basis.get_euler().y), rad_to_deg(ship.global_transform.basis.get_euler().z)])
	if hit_water:
		events.append(" - Hit water first, fuze: %.3f s" % [shell.fuze])
		if shell.params.type == ShellParams.ShellType.HE:
			return ArmorResultData.new(HitResult.WATER, shell.position, null, shell.velocity, null)

	if shell.params.type == ShellParams.ShellType.HE:
		var armor = hit_node.get_armor(face_index)
		if shell.params.overmatch >= armor:
			var hit_result = HitResult.PENETRATION
			if hit_node.is_citadel:
				hit_result = HitResult.CITADEL
			return ArmorResultData.new(hit_result, shell.position, hit_node, shell.velocity, ship)
		else:
			return ArmorResultData.new(HitResult.SHATTER, shell.position, hit_node, Vector3.ZERO, ship)

	while shell.fuze <= params.fuze_delay and result != ArmorResult.SHATTER and hit_node.ship == ship:
		var armor = hit_node.get_armor(face_index)
		var impact_angle = ProjectileManager.calculate_impact_angle(shell.velocity.normalized(), hit_normal)
		var e_armor = armor / cos(impact_angle)
		if e_armor < 0.0:
			print(" ⚠️ Warning: negative effective armor calculated")
		shell.pen = ProjectileManager.calculate_penetration_power(projectile.params, shell.velocity.length())
		shell.position = hit_position


		# if shell.fuze < 0.0:
		# 	if (e_armor + armor) / 2.0 > params.arming_threshold:
		# 		shell.fuze = 0.0
				
		events.append("Shell: speed=%.1f vel=(%.1f, %.1f, %.1f) m/s, fuze=%.3f s, pos=(%.1f, %.1f, %.1f), pen: %.1f" % [shell.velocity.length(), shell.velocity.x, shell.velocity.y, shell.velocity.z, shell.fuze, shell.position.x, shell.position.y, shell.position.z, shell.pen])

		if armor < params.overmatch:
			if hit_node.is_citadel:
				hit_cit = true
			result = ArmorResult.OVERPEN
			over_pen = true
			if shell.fuze < 0.0:
				if e_armor > params.arming_threshold:
					shell.fuze = 0.0 # Arm the fuze if over arming threshold
			# if shell.pen > e_armor:
			# 	shell.velocity *= (1.0 - e_armor / shell.pen) * 0.1
			# else:
			# 	shell.velocity = Vector3.ZERO
		elif impact_angle > params.auto_bounce or (impact_angle > params.ricochet_angle and shell.pen < e_armor):
			result = ArmorResult.RICOCHET
			shell.velocity = shell.velocity.bounce(hit_normal.normalized())
			shell.velocity *= cos(PI / 2.0 - impact_angle) # Lose some velocity on ricochet
			shell.position += hit_normal * 0.01 # Back off a bit to avoid immediate re-hit
			if deg_to_rad(20) > (PI - impact_angle):
				if shell.fuze < 0.0:
					shell.fuze = 0.0 # Arm the fuze on ricochet if it was armed already
		elif shell.pen < e_armor:
			result = ArmorResult.SHATTER
			shell.position -= -shell.velocity.normalized() * 0.01
			shell.velocity = Vector3.ZERO
			shell.position += hit_normal * 0.01 # Back off a bit to avoid immediate re-hit
			shell.fuze = params.fuze_delay
			
		else:
			if hit_node.is_citadel:
				hit_cit = true
			result = ArmorResult.OVERPEN
			over_pen = true
			shell.velocity *= (1.0 - e_armor / shell.pen)
			if shell.fuze < 0.0:
				if e_armor > params.arming_threshold:
					shell.fuze = 0.0 # Arm the fuze if over arming threshold
		events.append("Armor: %s, %s with %.1f/%.1fmm (angle %.1f°), normal: (%.1f, %.1f, %.1f), ship: %s" % [armor_result_to_string(result), hit_node.armor_path, armor, e_armor, rad_to_deg(impact_angle), hit_normal.x, hit_normal.y, hit_normal.z, hit_node.ship.name])

		if result == ArmorResult.SHATTER or shell.velocity.length() < 0.5:
			shell.calc_end_position()
			break

		armor_ray.from = shell.position + shell.velocity.normalized() * 0.1
		shell.calc_end_position()
		armor_ray.to = shell.end_position

		var next_hit = get_next_hit(armor_ray, space_state)

		if next_hit.is_empty(): # void or outside ship
			if shell.fuze >= 0.0:
				shell.fuze = params.fuze_delay
			break

		hit_node = next_hit.get('armor')
		hit_position = next_hit.get('position')
		hit_normal = next_hit.get('normal')
		face_index = next_hit.get('face_index')

		var fuze_elapsed = shell.position.distance_to(hit_position) / shell.velocity.length()
		if shell.fuze >= 0.0: # only advance fuze if armed
			shell.fuze += fuze_elapsed

	events.append("Shell: speed=%.1f vel=(%.1f, %.1f, %.1f) m/s, fuze=%.3f s, pos=(%.1f, %.1f, %.1f), pen: %.1f" % [shell.velocity.length(), shell.velocity.x, shell.velocity.y, shell.velocity.z, shell.fuze, shell.end_position.x, shell.end_position.y, shell.end_position.z, shell.pen])
	# final processing
	var d: ArmorPart = get_part_hit(hit_node.ship, shell.end_position, space_state)
	
	var damage_result = HitResult.WATER
	if d != null and d.armor_path.find("Citadel") != -1:
		damage_result = HitResult.CITADEL
	elif hit_cit: # overpen citadel but still could be inside hull
		damage_result = HitResult.CITADEL_OVERPEN
	elif d != null: # inside hull
		damage_result = HitResult.PENETRATION
	elif over_pen: # not ricochet but outside hull
		damage_result = HitResult.OVERPENETRATION
	elif result == ArmorResult.RICOCHET:
		damage_result = HitResult.RICOCHET
	elif result == ArmorResult.SHATTER:
		damage_result = HitResult.SHATTER
	events.append("Final Hit Result: %s" % [HitResult.keys()[HitResult.values().find(damage_result)]])

	if damage_result == HitResult.CITADEL:
	# if true:
		for e in events:
			print(e)

	# return ArmorResultData.new(damage_result, first_hit_pos, d, shell.velocity, ship)
	return ArmorResultData.new(damage_result, first_hit_pos, d, shell.velocity, ship)
