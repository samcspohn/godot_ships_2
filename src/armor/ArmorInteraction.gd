extends Node

class_name _ArmorInteraction

## Physically-based armor penetration for naval combat
## Supports APC (Armor-Piercing Capped) and HE (High Explosive) shells

enum HitResult {
	PENETRATION,
	PARTIAL_PEN,      # Shell stopped inside armor but still does damage
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
	PARTIAL_PEN,
	SHATTER,
}

#region Physics Constants

## de Marre constant for metric units (kg, m/s, mm)
## P(mm) = K * m^0.55 * v^1.43 / d^0.65
const DE_MARRE_K: float = 0.06

## Velocity decay exponent for post-penetration speed
const VELOCITY_DECAY_BETA: float = 1.8

## Base critical ricochet angle (degrees) for APC shells
const BASE_CRIT_ANGLE_APC: float = 75.0

## Ricochet sigmoid sharpness (per degree)
const RICOCHET_SIGMOID_K: float = 0.25

## Reference velocity for angle corrections (m/s)
const VELOCITY_REFERENCE: float = 500.0

## Ricochet energy retention
const RICOCHET_RETENTION: float = 0.75

## Minimum velocity to continue (m/s)
const MIN_VELOCITY: float = 10.0

## Shell deflection coefficient during penetration
const DEFLECTION_ALPHA: float = 0.35

#endregion

const WATER_DRAG: float = 3000.0

class ArmorResultData:
	var result_type: HitResult
	var explosion_position: Vector3
	var armor_part: ArmorPart
	var velocity: Vector3
	var ship: Ship
	var collision_normal: Vector3
	var shell_integrity: float
	
	func _init(_result_type: HitResult, _explosion_position: Vector3, _armor_part: ArmorPart, 
			_velocity: Vector3, _ship: Ship, _collision_normal: Vector3, _integrity: float = 1.0) -> void:
		result_type = _result_type
		explosion_position = _explosion_position
		armor_part = _armor_part
		velocity = _velocity
		ship = _ship
		collision_normal = _collision_normal
		shell_integrity = _integrity


class ShellData:
	var position: Vector3
	var end_position: Vector3
	var velocity: Vector3
	var params: ShellParams
	var fuze: float = -1.0
	var pen: float = 0.0
	var integrity: float = 1.0

	func calc_end_position() -> void:
		var fuze_left := params.fuze_delay - fuze
		if fuze < 0.0:
			fuze_left = 1.0
		end_position = position + velocity * fuze_left
	
	func get_speed() -> float:
		return velocity.length()


#region Penetration Physics

## Calculate penetration using de Marre formula (metric)
## mass_kg: shell mass in kg
## velocity_ms: impact velocity in m/s  
## caliber_mm: shell diameter in mm
## Returns: penetration in mm
static func calculate_de_marre_penetration(mass_kg: float, velocity_ms: float, caliber_mm: float) -> float:
	if velocity_ms < 1.0:
		return 0.0
	return DE_MARRE_K * pow(mass_kg, 0.55) * pow(velocity_ms, 1.43) / pow(caliber_mm, 0.65)


static func calculate_effective_thickness(thickness_mm: float, impact_angle_rad: float) -> float:
	var cos_angle := cos(impact_angle_rad)
	cos_angle = maxf(cos_angle, 0.05)
	return thickness_mm / cos_angle


static func calculate_critical_angle(velocity_ms: float, armor_mm: float, caliber_mm: float) -> float:
	var base_deg := BASE_CRIT_ANGLE_APC
	var vel_correction := 5.0 * (velocity_ms - VELOCITY_REFERENCE) / VELOCITY_REFERENCE
	var td_ratio := armor_mm / caliber_mm
	var td_correction := -8.0 * (td_ratio - 0.5) / 0.5
	var crit_deg := clampf(base_deg + vel_correction + td_correction, 55.0, 85.0)
	return deg_to_rad(crit_deg)


static func calculate_ricochet_probability(impact_angle_rad: float, critical_angle_rad: float) -> float:
	var angle_diff_deg := rad_to_deg(impact_angle_rad - critical_angle_rad)
	return 1.0 / (1.0 + exp(-RICOCHET_SIGMOID_K * angle_diff_deg))


static func calculate_exit_velocity(entry_speed: float, pen_capability_mm: float, effective_armor_mm: float) -> float:
	if pen_capability_mm <= 0.0:
		return 0.0
	var pen_ratio := effective_armor_mm / pen_capability_mm
	if pen_ratio >= 1.0:
		return 0.0
	return entry_speed * sqrt(1.0 - pow(pen_ratio, VELOCITY_DECAY_BETA))


static func calculate_shell_integrity(pen_ratio: float, current_integrity: float) -> float:
	var degradation := pen_ratio * 0.4
	return clampf(current_integrity - degradation, 0.1, 1.0)


static func calculate_deflected_direction(entry_dir: Vector3, armor_normal: Vector3, pen_ratio: float) -> Vector3:
	var deflection_amount := DEFLECTION_ALPHA * pen_ratio * 0.5
	return entry_dir.slerp(-armor_normal, deflection_amount).normalized()


static func calculate_ricochet_velocity(velocity: Vector3, normal: Vector3, impact_angle_rad: float) -> Vector3:
	var reflected := velocity.bounce(normal.normalized())
	var retention := RICOCHET_RETENTION * sin(impact_angle_rad)
	return reflected * retention

#endregion


#region Main Processing

func process_travel(projectile: ProjectileManager.ProjectileData, prev_pos: Vector3, t: float, 
		space_state: PhysicsDirectSpaceState3D) -> ArmorResultData:
	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.from = prev_pos
	ray_query.to = projectile.position
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 | (1 << 1)
	
	var result := space_state.intersect_ray(ray_query)

	if projectile.owner == null:
		if not result.is_empty():
			if result.get('position').y <= 0.0001:
				return ArmorResultData.new(HitResult.WATER, result.get('position'), null, Vector3.ZERO, null, Vector3.ZERO)
			else:
				return ArmorResultData.new(HitResult.TERRAIN, result.get('position'), null, Vector3.ZERO, null, result.get('normal'))
		return null

	# Water hit check
	if (result.is_empty() and projectile.position.y < 0.0) or \
	   (not result.is_empty() and abs(result.get('position').y) < 0.0001 and not (result.get('collider') is ArmorPart)):
		var dir: Vector3 = projectile.position - prev_pos
		var distance_to_water := -ray_query.from.y / dir.y if abs(dir.y) > 0.0001 else 0.0
		
		if distance_to_water <= dir.length():
			var water_hit_pos := ray_query.from + dir * distance_to_water
			var impact_vel := ProjectilePhysicsWithDrag.calculate_velocity_at_time(
				projectile.launch_velocity, t, projectile.params.drag)
			var fuzed_position := ProjectilePhysicsWithDrag.calculate_position_at_time(
				water_hit_pos, impact_vel, projectile.params.fuze_delay, 
				projectile.params.drag * WATER_DRAG)
			
			var ship_ray := PhysicsRayQueryParameters3D.new()
			ship_ray.from = water_hit_pos
			ship_ray.to = fuzed_position
			ship_ray.hit_back_faces = true
			ship_ray.hit_from_inside = false
			ship_ray.collision_mask = 1 << 1
			
			var ship_result := space_state.intersect_ray(ship_ray)
			if ship_result.is_empty():
				return ArmorResultData.new(HitResult.WATER, water_hit_pos, null, impact_vel, null, Vector3.ZERO)
			else:
				var hit_pos: Vector3 = ship_result.get('position')
				var total_dist := (fuzed_position - water_hit_pos).length()
				var hit_dist := (hit_pos - water_hit_pos).length()
				var t_impact: float= projectile.params.fuze_delay * (hit_dist / total_dist)
				var water_impact_vel := ProjectilePhysicsWithDrag.calculate_velocity_at_time(
					impact_vel, t_impact, projectile.params.drag * WATER_DRAG)
				return process_hit(ship_result['collider'], hit_pos, ship_result['normal'],
					projectile, water_impact_vel, ship_result['face_index'], t_impact, space_state, true)
	
	elif not result.is_empty():
		var hit_node = result.get('collider')
		if hit_node is ArmorPart:
			if hit_node.ship == projectile.owner or hit_node.ship in projectile.exclude:
				return null
			var impact_vel := ProjectilePhysicsWithDrag.calculate_velocity_at_time(
				projectile.launch_velocity, t, projectile.params.drag)

			# acount for case where projectile starts inside ship geometry
			var inside = false
			while get_part_hit(hit_node.ship, prev_pos, space_state) != null:
				prev_pos -= prev_pos.direction_to(projectile.position)
				inside = true
			if inside: # recalculate ray cast hit
				ray_query.from = prev_pos
				result = space_state.intersect_ray(ray_query)
				hit_node = result.get('collider')
				if not (hit_node is ArmorPart):
					printerr("⚠️ ArmorInteraction: projectile started inside ship but no armor part found on re-cast")

			return process_hit(hit_node, result.get('position'), result.get('normal'),
				projectile, impact_vel, result.get('face_index'), -1.0, space_state, false)
		elif result.get('position').y <= 0.0001:
			return ArmorResultData.new(HitResult.WATER, result.get('position'), null, Vector3.ZERO, null, Vector3.ZERO)
		else:
			return ArmorResultData.new(HitResult.TERRAIN, result.get('position'), null, Vector3.ZERO, null, result.get('normal'))
	
	return null


func process_hit(hit_node: ArmorPart, hit_position: Vector3, hit_normal: Vector3, 
		projectile: ProjectileManager.ProjectileData, impact_velocity: Vector3, 
		face_index: int, fuze: float, space_state: PhysicsDirectSpaceState3D, 
		hit_water: bool) -> ArmorResultData:
	
	var first_hit_normal := hit_normal
	var first_hit_pos := hit_position
	var params:ShellParams = projectile.params
	var ship := hit_node.ship
	
	var shell := ShellData.new()
	shell.position = hit_position
	shell.velocity = impact_velocity
	shell.fuze = fuze
	shell.params = params
	shell.calc_end_position()
	
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	
	var armor_ray := PhysicsRayQueryParameters3D.new()
	armor_ray.hit_back_faces = true
	armor_ray.hit_from_inside = false
	armor_ray.collision_mask = 1 << 1
	
	var result: ArmorResult = ArmorResult.OVERPEN
	var hit_cit := false
	var over_pen := false
	
	var events: Array[String] = []
	events.append("Processing Shell: %s %s " % [params.caliber, params.type])
	var ship_scene_path := ship.scene_file_path
	events.append("Ship: %s pos=(%.1f, %.1f, %.1f), rot=(%.1f, %.1f, %.1f), scene=%s" % [
		ship.name, 
		ship.global_transform.origin.x, ship.global_transform.origin.y, ship.global_transform.origin.z,
		rad_to_deg(ship.global_transform.basis.get_euler().x), 
		rad_to_deg(ship.global_transform.basis.get_euler().y), 
		rad_to_deg(ship.global_transform.basis.get_euler().z),
		ship_scene_path])
	
	if hit_water:
		events.append(" - Hit water first, fuze: %.3f s" % [shell.fuze])
		if params.type == ShellParams.ShellType.HE:
			return ArmorResultData.new(HitResult.WATER, shell.position, null, shell.velocity, null, first_hit_normal)

	# HE Shell Processing
	if params.type == ShellParams.ShellType.HE:
		var armor_mm: float = hit_node.get_armor(face_index)
		# var pen_mm := calculate_de_marre_penetration(params.mass, shell.get_speed(), params.caliber)
		
		if params.overmatch >= armor_mm:
			var hit_result := HitResult.CITADEL if hit_node.is_citadel else HitResult.PENETRATION
			return ArmorResultData.new(hit_result, shell.position, hit_node, shell.velocity, ship, first_hit_normal)
		else:
			return ArmorResultData.new(HitResult.SHATTER, shell.position, hit_node, Vector3.ZERO, ship, first_hit_normal)

	# APC Shell Processing Loop
	var iteration := 0
	var max_iterations := 20
	
	while shell.fuze <= params.fuze_delay and result != ArmorResult.SHATTER and \
		  hit_node.ship == ship and iteration < max_iterations:
		iteration += 1
		
		var armor_mm: float = hit_node.get_armor(face_index)
		var speed := shell.get_speed()
		
		var impact_angle := _calculate_impact_angle(shell.velocity.normalized(), hit_normal)
		var e_armor := calculate_effective_thickness(armor_mm, impact_angle)
		
		if e_armor < 0.0:
			print(" ⚠️ Warning: negative effective armor calculated")
		
		shell.pen = calculate_de_marre_penetration(params.mass, speed, params.caliber)
		shell.position = hit_position
		
		events.append("Shell: speed=%.1f vel=(%.1f, %.1f, %.1f) m/s, fuze=%.3f s, pos=(%.1f, %.1f, %.1f), pen: %.1f" % [
			shell.get_speed(), shell.velocity.x, shell.velocity.y, shell.velocity.z,
			shell.fuze, shell.position.x, shell.position.y, shell.position.z, shell.pen])
		
		# Overmatch Check
		if armor_mm < params.overmatch:
			if hit_node.is_citadel:
				hit_cit = true
			result = ArmorResult.OVERPEN
			over_pen = true
			
			var pen_ratio := e_armor / maxf(shell.pen, 1.0)
			shell.velocity *= (1.0 - pen_ratio * 0.3)
			shell.integrity = calculate_shell_integrity(pen_ratio * 0.5, shell.integrity)
			
			if shell.fuze < 0.0 and e_armor > params.arming_threshold:
				shell.fuze = 0.0
		
		# Ricochet Check
		elif _should_ricochet(shell, params, impact_angle, e_armor, rng):
			result = ArmorResult.RICOCHET
			shell.velocity = calculate_ricochet_velocity(shell.velocity, hit_normal, impact_angle)
			shell.position += hit_normal * 0.01
			
			if shell.fuze < 0.0 and impact_angle > deg_to_rad(70.0):
				shell.fuze = 0.0
		
		# Shatter / Partial Pen Check
		elif shell.pen < e_armor:
			var pen_ratio := shell.pen / e_armor
			
			if pen_ratio > 0.7:
				result = ArmorResult.PARTIAL_PEN
				shell.velocity *= 0.1
				shell.integrity *= 0.5
			else:
				result = ArmorResult.SHATTER
				shell.velocity = Vector3.ZERO
				shell.fuze = params.fuze_delay
			
			shell.position += hit_normal * 0.001
		
		# Full Penetration
		else:
			if hit_node.is_citadel:
				hit_cit = true
			result = ArmorResult.PEN
			over_pen = true
			
			var pen_ratio := e_armor / shell.pen
			var exit_speed := calculate_exit_velocity(speed, shell.pen, e_armor)
			var exit_dir := calculate_deflected_direction(shell.velocity.normalized(), hit_normal, pen_ratio)
			
			shell.velocity = exit_dir * exit_speed
			shell.integrity = calculate_shell_integrity(pen_ratio, shell.integrity)
			
			if shell.fuze < 0.0 and e_armor > params.arming_threshold:
				shell.fuze = 0.0
		
		events.append("Armor: %s, %s with %.1f/%.1fmm (angle %.1f°), normal: (%.1f, %.1f, %.1f), ship: %s, is_citadel: %s" % [
			armor_result_to_string(result), hit_node.armor_path, armor_mm, e_armor, 
			rad_to_deg(impact_angle), hit_normal.x, hit_normal.y, hit_normal.z,
			hit_node.ship.name, hit_node.is_citadel])
		
		# Check termination
		if result == ArmorResult.SHATTER or result == ArmorResult.PARTIAL_PEN or shell.get_speed() < MIN_VELOCITY:
			shell.calc_end_position()
			break
		
		if result == ArmorResult.RICOCHET:
			shell.calc_end_position()
			break
		
		# Find next armor layer
		armor_ray.from = shell.position + shell.velocity.normalized() * 0.01
		shell.calc_end_position()
		armor_ray.to = shell.end_position
		
		var next_hit := get_next_hit(armor_ray, space_state)
		
		if next_hit.is_empty():
			if shell.fuze >= 0.0:
				shell.fuze = params.fuze_delay
			break
		
		var old_pos := shell.position
		hit_node = next_hit.get('armor')
		hit_position = next_hit.get('position')
		hit_normal = next_hit.get('normal')
		face_index = next_hit.get('face_index')
		
		var fuze_elapsed := old_pos.distance_to(hit_position) / shell.get_speed()
		if shell.fuze >= 0.0:
			shell.fuze += fuze_elapsed
	
	events.append("Shell: speed=%.1f vel=(%.1f, %.1f, %.1f) m/s, fuze=%.3f s, pos=(%.1f, %.1f, %.1f), pen: %.1f" % [
		shell.get_speed(), shell.velocity.x, shell.velocity.y, shell.velocity.z,
		shell.fuze, shell.end_position.x, shell.end_position.y, shell.end_position.z, shell.pen])
	
	var d: ArmorPart = get_part_hit(hit_node.ship, shell.end_position, space_state)
	
	events.append("get_part_hit result: %s (citadel=%s)" % [
		d.armor_path if d != null else "null", 
		str(d.armor_path.find("Citadel") != -1) if d != null else "N/A"])
	events.append("hit_cit flag: %s, over_pen flag: %s" % [hit_cit, over_pen])
	
	var damage_result := _resolve_hit_result(result, d, hit_cit, over_pen)
	
	events.append("Final Hit Result: %s" % [HitResult.keys()[HitResult.values().find(damage_result)]])
	
	if damage_result == HitResult.CITADEL or damage_result == HitResult.CITADEL_OVERPEN:
		for e in events:
			print(e)
	
	return ArmorResultData.new(damage_result, first_hit_pos, d, shell.velocity, ship, first_hit_normal, shell.integrity)


func _should_ricochet(shell: ShellData, params: ShellParams, impact_angle: float, 
		e_armor: float, rng: RandomNumberGenerator) -> bool:
	if impact_angle > params.auto_bounce:
		return true
	
	if impact_angle < params.ricochet_angle:
		return false
	
	var crit_angle := calculate_critical_angle(shell.get_speed(), e_armor, params.caliber)
	var ricochet_prob := calculate_ricochet_probability(impact_angle, crit_angle)
	
	if shell.pen < e_armor:
		ricochet_prob = minf(ricochet_prob + 0.3, 0.95)
	
	return rng.randf() < ricochet_prob


func _resolve_hit_result(armor_result: ArmorResult, final_part: ArmorPart, 
		hit_cit: bool, over_pen: bool) -> HitResult:
	
	# Only shatter and partial pen are definitive outcomes
	match armor_result:
		ArmorResult.SHATTER:
			return HitResult.SHATTER
		ArmorResult.PARTIAL_PEN:
			return HitResult.PARTIAL_PEN
	
	# For ricochet and penetration, check where shell ended up
	var in_citadel := final_part != null and \
		(final_part.is_citadel or final_part.armor_path.find("Citadel") != -1)
	
	if in_citadel:
		return HitResult.CITADEL
	elif hit_cit and over_pen:
		return HitResult.CITADEL_OVERPEN
	elif final_part != null:
		return HitResult.PENETRATION
	elif over_pen:
		return HitResult.OVERPENETRATION
	elif armor_result == ArmorResult.RICOCHET:
		# Only return ricochet if shell ended up outside the ship
		return HitResult.RICOCHET
	
	return HitResult.OVERPENETRATION


func _calculate_impact_angle(velocity_dir: Vector3, surface_normal: Vector3) -> float:
	var cos_angle: float = abs(velocity_dir.dot(surface_normal))
	return acos(clampf(cos_angle, 0.0, 1.0))


func armor_result_to_string(result: ArmorResult) -> String:
	match result:
		ArmorResult.RICOCHET:
			return "RICOCHET"
		ArmorResult.OVERPEN:
			return "OVERPEN"
		ArmorResult.PEN:
			return "PENETRATION"
		ArmorResult.PARTIAL_PEN:
			return "PARTIAL_PEN"
		ArmorResult.SHATTER:
			return "SHATTER"
	return "UNKNOWN"

#endregion


#region Utility Functions

func get_next_hit(ray_query: PhysicsRayQueryParameters3D, 
		space_state: PhysicsDirectSpaceState3D) -> Dictionary:
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.exclude = []
	ray_query.collision_mask = 1 << 1
	
	var result := space_state.intersect_ray(ray_query)
	if result.is_empty():
		return {}
	
	var closest_result := result
	var exclude: Array[RID] = []
	
	while not result.is_empty():
		exclude.append(result.get('rid'))
		ray_query.exclude = exclude
		result = space_state.intersect_ray(ray_query)
		if not result.is_empty():
			var new_dist: float = (result.get('position') - ray_query.from).length()
			var old_dist: float = (closest_result.get('position') - ray_query.from).length()
			if new_dist < old_dist:
				closest_result = result
	
	var armor: ArmorPart = closest_result.get('collider') as ArmorPart
	if armor != null:
		return {
			'armor': armor, 
			'position': closest_result.get('position'), 
			'normal': closest_result.get('normal'), 
			'face_index': closest_result.get('face_index')
		}
	return {}


func get_part_hit(_ship: Ship, shell_pos: Vector3, 
		space_state: PhysicsDirectSpaceState3D) -> ArmorPart:
	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.to = shell_pos
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	ray_query.collision_mask = 1 << 1
	
	var directions := [
		_ship.global_basis.x.normalized(),
		-_ship.global_basis.x.normalized(),
		_ship.global_basis.y.normalized(),
		-_ship.global_basis.y.normalized(),
		_ship.global_basis.z.normalized(),
		-_ship.global_basis.z.normalized()
	]
	
	var hits: Array[Array] = []
	for dir in directions:
		ray_query.from = shell_pos + dir * 400.0
		ray_query.exclude = []
		var side_hits: Array[ArmorPart] = []
		var armor_hit := space_state.intersect_ray(ray_query)
		var exclude: Array[RID] = []
		
		while not armor_hit.is_empty():
			var armor_part := armor_hit.get('collider') as ArmorPart
			if armor_part != null and armor_part.ship == _ship:
				side_hits.append(armor_part)
			exclude.append(armor_hit.get('rid'))
			ray_query.exclude = exclude
			armor_hit = space_state.intersect_ray(ray_query)
		hits.append(side_hits)
	
	for side_hits in hits:
		if side_hits.size() == 0:
			return null
	
	var min_hits := INF
	var hit_part: ArmorPart = null
	for side_hits in hits:
		if side_hits.size() < min_hits:
			min_hits = side_hits.size()
			hit_part = side_hits[-1]
	
	return hit_part

#endregion
