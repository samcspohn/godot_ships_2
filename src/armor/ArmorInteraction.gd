extends Node

class_name _ArmorInteraction

## Physically-based armor penetration for naval combat
## Supports APC (Armor-Piercing Capped) and HE (High Explosive) shells

enum HitResult {
	PENETRATION = 0,
	PARTIAL_PEN = 1,      # Shell stopped inside armor but still does damage
	RICOCHET = 2,
	OVERPENETRATION = 3,
	SHATTER = 4,
	CITADEL = 5,
	CITADEL_OVERPEN = 6,
	WATER = 7,
	TERRAIN = 8,
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
const VELOCITY_DECAY_BETA: float = 0.8

## Minimum velocity to continue (m/s)
const MIN_VELOCITY: float = 10.0

## Shell deflection coefficient during penetration
const DEFLECTION_ALPHA: float = 0.35

#endregion

#region Deflection Energy-Balance Ricochet Model
## Based on the Thompson/Okun framework: ricochet emerges from the obliquity
## multiplier diverging beyond what the shell's energy can overcome.
## M(Ob) = (1/cos(Ob))^alpha * (1 + K_nose * tan(Ob)^gamma * f(T/D))
## The first term is geometric LOS thickness increase (de Marre family).
## The second term is the deflection torque energy penalty from asymmetric
## contact forces on the nose during oblique impact.

## de Marre thickness-to-velocity exponent ratio for the geometric term.
## ~1.0 for homogeneous ductile armor, ~0.9 for face-hardened.
const OBLIQUITY_ALPHA: float = 1.0

## Deflection torque exponent. Controls how steeply the deflection penalty
## rises with obliquity. Derived from Thompson F-value curve fits against
## M79APCLC data (Okun). ~3.0 for typical WWII APC ogival noses.
const DEFLECTION_GAMMA: float = 3.0

## Nose shape deflection coefficients (K_nose).
## Lower = better at maintaining nose-first bite at obliquity.
## APC hard cap digs into plate, resisting rotation.
## Uncapped pointed noses deflect easily.
const K_NOSE_APC: float = 0.06      ## APC / APCBC (hard cap catches plate edge)
const K_NOSE_AP_UNCAPPED: float = 0.15  ## Uncapped pointed ogival
const K_NOSE_COMMON: float = 0.10    ## Common/SAP (intermediate nose)

## T/D modulation: thicker plates relative to caliber give the deflection
## torque more angular impulse (shell spends more time in contact).
## f(T/D) = 1.0 + TD_MOD_SCALE * clamp(T/D - TD_MOD_ONSET, 0, TD_MOD_MAX)
const TD_MOD_SCALE: float = 0.3
const TD_MOD_ONSET: float = 0.5
const TD_MOD_MAX: float = 1.5

## When the deflection multiplier exceeds this threshold, a failed penetration
## is classified as ricochet (shell deflected off) rather than shatter/embed
## (shell stopped inside the plate by raw thickness).
const DEFLECTION_RICOCHET_THRESHOLD: float = 1.15

#endregion

const WATER_DRAG: float = 2500.0

class ArmorResultData:
	var result_type: HitResult
	var explosion_position: Vector3
	var armor_part: ArmorPart
	var velocity: Vector3
	var ship: Ship
	var collision_normal: Vector3
	var shell_integrity: float
	var overmatch_first_armor: bool = false

	func _init(_result_type: HitResult, _explosion_position: Vector3, _armor_part: ArmorPart,
			_velocity: Vector3, _ship: Ship, _collision_normal: Vector3, _integrity: float = 1.0) -> void:
		result_type = _result_type
		explosion_position = _explosion_position
		armor_part = _armor_part
		velocity = _velocity
		ship = _ship
		collision_normal = _collision_normal
		shell_integrity = _integrity


class _ShellData:
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


## Compute the full obliquity multiplier including deflection torque penalty.
## Returns the factor by which the required penetration velocity increases at
## this obliquity vs normal incidence. Based on Thompson F-value empirical data.
static func calculate_obliquity_multiplier(impact_angle_rad: float, armor_mm: float,
		caliber_mm: float, k_nose: float) -> Dictionary:
	var cos_a := maxf(cos(impact_angle_rad), 0.05)
	var tan_a := tan(clampf(impact_angle_rad, 0.0, deg_to_rad(89.0)))

	# Geometric LOS term: (1/cos)^alpha
	var geometric := pow(1.0 / cos_a, OBLIQUITY_ALPHA)

	# T/D modulation: thick plates give deflection torque more angular impulse
	var td_ratio := armor_mm / maxf(caliber_mm, 1.0)
	var f_td := 1.0 + TD_MOD_SCALE * clampf(td_ratio - TD_MOD_ONSET, 0.0, TD_MOD_MAX)

	# Deflection torque penalty: 1 + K * tan^gamma * f(T/D)
	var deflection := 1.0 + k_nose * pow(tan_a, DEFLECTION_GAMMA) * f_td

	return {
		"multiplier": geometric * deflection,
		"geometric": geometric,
		"deflection": deflection,
	}


## Get the nose deflection coefficient for a shell type.
static func get_k_nose(params: ShellParams) -> float:
	# Use APC for capped AP shells, COMMON for HE/SAP, AP_UNCAPPED as fallback.
	# If ShellParams has a nose_k override, prefer that.
	if params.type == ShellParams.ShellType.HE:
		return K_NOSE_COMMON
	# Default: APC (most WWII naval AP shells were capped)
	return K_NOSE_APC


static func calculate_exit_velocity(entry_speed: float, pen_capability_mm: float, effective_armor_mm: float) -> float:
	# if pen_capability_mm <= 0.0:
	# 	return 0.0
	# var pen_ratio := effective_armor_mm / pen_capability_mm
	# if pen_ratio >= 1.0:
	# 	return 0.0
	# return entry_speed * sqrt(1.0 - pow(pen_ratio, VELOCITY_DECAY_BETA))
	if pen_capability_mm <= 0.0:
		return 0.0
	var pen_ratio := effective_armor_mm / pen_capability_mm
	if pen_ratio >= 1.0:
		return 0.0
	return entry_speed * (1.0 - pen_ratio)


static func calculate_shell_integrity(pen_ratio: float, current_integrity: float) -> float:
	var degradation := pen_ratio * 0.4
	return clampf(current_integrity - degradation, 0.1, 1.0)


static func calculate_deflected_direction(entry_dir: Vector3, armor_normal: Vector3, pen_ratio: float) -> Vector3:
	var deflection_amount := DEFLECTION_ALPHA * pen_ratio * 0.5
	return entry_dir.slerp(-armor_normal, deflection_amount).normalized()


static func calculate_ricochet_velocity(velocity: Vector3, normal: Vector3, impact_angle_rad: float,
		energy_loss_fraction: float) -> Vector3:
	## Physics-based ricochet: the shell retains most of its tangential velocity
	## and loses a fraction of its normal (into-plate) velocity component based on
	## how deeply the nose gouged before deflecting.
	var n := normal.normalized()
	var v_normal_mag := velocity.dot(n)
	var v_normal := n * v_normal_mag
	var v_tangential := velocity - v_normal

	# The normal component reverses direction (bounce) with energy loss from
	# the plate gouge. At grazing angles most energy is tangential anyway.
	var retained_normal := -v_normal * (1.0 - energy_loss_fraction)
	var result := v_tangential + retained_normal
	return result

#endregion


#region Main Processing

func process_travel(projectile: ProjectileData, prev_pos: Vector3, t: float,
		space_state: PhysicsDirectSpaceState3D, events = []) -> ArmorResultData:

	if prev_pos.y < -1.2:
		return ArmorResultData.new(HitResult.WATER, prev_pos, null, Vector3.ZERO, null, Vector3.ZERO)

	var curr_pos := projectile.position
	var travel := curr_pos - prev_pos

	# Extend the ray length by extending the start backwards by 10m in the direction of travel.
	# This handles cases where prev_pos ended up inside geometry (e.g. fast-moving
	# shells skipping past a hull surface in a single frame).
	var extended_from := prev_pos if projectile.frame_count == 0 else prev_pos - travel.normalized() * 10.0

	return _process_travel_precision(projectile, prev_pos, curr_pos, extended_from, t, space_state, events)





## Precision two-phase path: broadphase OBB check in the main world, then
## narrowphase armor raycast in the origin-local precision world.
func _process_travel_precision(projectile: ProjectileData, prev_pos: Vector3,
		curr_pos: Vector3, extended_from: Vector3, t: float,
		space_state: PhysicsDirectSpaceState3D, events) -> ArmorResultData:

	# ------------------------------------------------------------------
	# Phase 1: Broadphase — cast against terrain (layer 0), OBB ship
	# bounding boxes (layer 4), and the sea collision layer (layer 3).
	# Armor parts (layer 1) are NOT tested here; we rely on the coarse
	# OBBs instead, then refine in the precision world.
	# ------------------------------------------------------------------
	var ray_query := PhysicsRayQueryParameters3D.new()
	ray_query.from = extended_from
	ray_query.to = curr_pos
	ray_query.hit_back_faces = true
	ray_query.hit_from_inside = false
	# Layers: 0 = terrain, 3 = sea, 4 = OBB broadphase
	ray_query.collision_mask = 1 | (1 << 3) | PrecisionPhysicsWorld.OBB_COLLISION_LAYER

	# Build exclude list for OBBs belonging to owner / excluded ships
	var exclude = []
	if projectile.owner != null:
		var owner_entry := PrecisionPhysicsWorld.get_ship_entry(projectile.owner as Ship)
		if not owner_entry.is_empty():
			exclude.append((owner_entry["obb_body"] as StaticBody3D).get_rid())
	for e in projectile.exclude:
		if e is Ship:
			var entry := PrecisionPhysicsWorld.get_ship_entry(e as Ship)
			if not entry.is_empty():
				exclude.append((entry["obb_body"] as StaticBody3D).get_rid())
	ray_query.exclude = exclude

	# OBBs and terrain live in the main world — always cast broadphase there,
	# even when called from a SubViewport context (e.g. shell_replay validation).
	var _main_space: PhysicsDirectSpaceState3D = null
	if PrecisionPhysicsWorld.get_tree() != null:
		var root_world := PrecisionPhysicsWorld.get_tree().root.world_3d
		if root_world != null:
			_main_space = root_world.direct_space_state
	if _main_space == null:
		return null
	var result := _main_space.intersect_ray(ray_query)

	# --- Owner-less projectiles (e.g. debug / visual-only) ---
	if projectile.owner == null:
		if not result.is_empty():
			if result.get('position').y <= 0.0001:
				return ArmorResultData.new(HitResult.WATER, result.get('position'), null, Vector3.ZERO, null, Vector3.ZERO)
			# OBB hit with no owner — treat as miss
			elif PrecisionPhysicsWorld.get_ship_from_obb(result.get('collider')) != null:
				return null
			else:
				return ArmorResultData.new(HitResult.TERRAIN, result.get('position'), null, Vector3.ZERO, null, result.get('normal'))
		return null

	# --- Check broadphase hit ---
	if not result.is_empty():
		var hit_node = result.get('collider')

		# Did the ray hit an OBB bounding box?
		var obb_ship: Ship = PrecisionPhysicsWorld.get_ship_from_obb(hit_node)
		if obb_ship != null:
			# Ignore own ship or excluded ships (redundant safety check)
			if obb_ship == projectile.owner or obb_ship in projectile.exclude:
				return null

			var obb_hit_pos: Vector3 = result.get('position')
			if PrecisionPhysicsWorld.debug_log_obb:
				print("[OBB HIT] Shell from %s -> OBB of %s at (%.1f, %.1f, %.1f), ray: (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f)" % [
					projectile.owner.ship_name if projectile.owner != null else "?",
					obb_ship.ship_name,
					obb_hit_pos.x, obb_hit_pos.y, obb_hit_pos.z,
					extended_from.x, extended_from.y, extended_from.z,
					curr_pos.x, curr_pos.y, curr_pos.z])
			PrecisionPhysicsWorld.notify_obb_hit(obb_ship)

			# -------------------------------------------------------
			# Phase 2: Narrowphase — transform the original world-space
			# ray into the ship's local space and cast against the full
			# armor detail in the precision world at the origin.
			# -------------------------------------------------------
			var local_ray := PrecisionPhysicsWorld.world_ray_to_local(obb_ship, extended_from, curr_pos)
			var local_from: Vector3 = local_ray[0]
			var local_to: Vector3 = local_ray[1]

			var precision_result := PrecisionPhysicsWorld.precision_raycast(obb_ship, local_from, local_to)

			if not precision_result.is_empty():
				var armor_part := precision_result.get('collider') as ArmorPart
				if armor_part != null:
					# Transform hit data back to world space
					var world_hit_pos: Vector3 = PrecisionPhysicsWorld.local_to_world(obb_ship, precision_result.get('position'))
					var world_hit_normal: Vector3 = PrecisionPhysicsWorld.local_dir_to_world(obb_ship, precision_result.get('normal')).normalized()

					if PrecisionPhysicsWorld.debug_log_obb:
						print("[OBB NARROWPHASE HIT] %s armor '%s' at local(%.2f,%.2f,%.2f) world(%.1f,%.1f,%.1f)" % [
							obb_ship.ship_name, armor_part.armor_path,
							precision_result.get('position').x, precision_result.get('position').y, precision_result.get('position').z,
							world_hit_pos.x, world_hit_pos.y, world_hit_pos.z])

					var impact_vel := ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
						projectile.launch_velocity, t, projectile.params)

					return _process_hit(armor_part, world_hit_pos, world_hit_normal,
						projectile, impact_vel, precision_result.get('face_index'),
						-1.0, space_state, false, events)
			# OBB was hit but no armor detail inside — miss
			if PrecisionPhysicsWorld.debug_log_obb:
				var ray_len := local_from.distance_to(local_to)
				var body_count := PrecisionPhysicsWorld.get_precision_body_count(obb_ship)
				print("[OBB NARROWPHASE MISS] OBB of %s hit but precision raycast found NO armor." % obb_ship.ship_name)
				print("  local_ray: (%.2f,%.2f,%.2f)->(%.2f,%.2f,%.2f)  len=%.2f" % [
					local_from.x, local_from.y, local_from.z,
					local_to.x, local_to.y, local_to.z, ray_len])
				print("  world_ray: (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f)" % [
					extended_from.x, extended_from.y, extended_from.z,
					curr_pos.x, curr_pos.y, curr_pos.z])
				print("  obb_hit_pos: (%.1f,%.1f,%.1f)  ship_pos: (%.1f,%.1f,%.1f)" % [
					obb_hit_pos.x, obb_hit_pos.y, obb_hit_pos.z,
					obb_ship.global_position.x, obb_ship.global_position.y, obb_ship.global_position.z])
				print("  precision_body_count=%d" % body_count)
				var world_ray_from := PrecisionPhysicsWorld.local_to_world(obb_ship, local_from)
				var world_ray_to := PrecisionPhysicsWorld.local_to_world(obb_ship, local_to)
				Debug.draw_line(world_ray_from, world_ray_to, Color.RED)
			return null

		# Hit non-armor, non-OBB objects (terrain / islands)
		elif result.get('position').y > 0.0001:
			return ArmorResultData.new(HitResult.TERRAIN, result.get('position'), null, Vector3.ZERO, null, result.get('normal'))

	# ------------------------------------------------------------------
	# Containment fallback: if the broadphase ray found no OBB surface
	# intersection, the ray segment may be fully inside an OBB.  Check
	# the midpoint against all registered OBBs.
	# ------------------------------------------------------------------
	var excluded_ship_ids: Array = []
	if projectile.owner != null:
		excluded_ship_ids.append(projectile.owner.get_instance_id())
	for e in projectile.exclude:
		if e is Ship:
			excluded_ship_ids.append(e.get_instance_id())

	var midpoint := (extended_from + curr_pos) * 0.5
	var containing_ship: Ship = PrecisionPhysicsWorld.get_ship_containing_point(midpoint, excluded_ship_ids)
	if containing_ship != null:
		if PrecisionPhysicsWorld.debug_log_obb:
			print("[OBB CONTAINMENT] Ray fully inside OBB of %s, midpoint (%.1f,%.1f,%.1f)" % [
				containing_ship.ship_name, midpoint.x, midpoint.y, midpoint.z])
		PrecisionPhysicsWorld.notify_obb_hit(containing_ship)

		var local_ray := PrecisionPhysicsWorld.world_ray_to_local(containing_ship, extended_from, curr_pos)
		var local_from: Vector3 = local_ray[0]
		var local_to: Vector3 = local_ray[1]

		var precision_result := PrecisionPhysicsWorld.precision_raycast(containing_ship, local_from, local_to)

		if not precision_result.is_empty():
			var armor_part := precision_result.get('collider') as ArmorPart
			if armor_part != null:
				var world_hit_pos: Vector3 = PrecisionPhysicsWorld.local_to_world(containing_ship, precision_result.get('position'))
				var world_hit_normal: Vector3 = PrecisionPhysicsWorld.local_dir_to_world(containing_ship, precision_result.get('normal')).normalized()

				if PrecisionPhysicsWorld.debug_log_obb:
					print("[OBB CONTAINMENT HIT] %s armor '%s' at world(%.1f,%.1f,%.1f)" % [
						containing_ship.ship_name, armor_part.armor_path,
						world_hit_pos.x, world_hit_pos.y, world_hit_pos.z])

				var impact_vel := ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
					projectile.launch_velocity, t, projectile.params)

				return _process_hit(armor_part, world_hit_pos, world_hit_normal,
					projectile, impact_vel, precision_result.get('face_index'),
					-1.0, space_state, false, events)

		if PrecisionPhysicsWorld.debug_log_obb:
			print("[OBB CONTAINMENT MISS] Inside OBB of %s but precision raycast found no armor" % containing_ship.ship_name)

	# ------------------------------------------------------------------
	# No direct hit — check for underwater penetration (prev_pos→curr_pos)
	# ------------------------------------------------------------------
	if curr_pos.y < 0.0 and prev_pos.y > 0.0:
		var dir := curr_pos - prev_pos
		# Parametric t_water: 0 = at prev_pos, 1 = at curr_pos
		var t_water := -prev_pos.y / dir.y if abs(dir.y) > 0.0001 else 0.0

		if t_water > 0.0 and t_water <= 1.0:
			var water_hit_pos := prev_pos + dir * t_water
			var impact_vel := ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
				projectile.launch_velocity, t, projectile.params)

			var p = projectile.params.duplicate(true)
			p.drag *= WATER_DRAG
			var fuzed_position := ProjectilePhysicsWithDragV2.calculate_position_at_time(
				water_hit_pos, impact_vel, projectile.params.fuze_delay,
				p)

			# Broadphase underwater: cast against OBBs
			var ship_ray := PhysicsRayQueryParameters3D.new()
			ship_ray.from = water_hit_pos
			ship_ray.to = fuzed_position
			ship_ray.hit_back_faces = true
			ship_ray.hit_from_inside = false
			ship_ray.collision_mask = PrecisionPhysicsWorld.OBB_COLLISION_LAYER
			ship_ray.exclude = exclude  # reuse owner/excluded OBB list

			var ship_result := _main_space.intersect_ray(ship_ray)
			if ship_result.is_empty():
				return ArmorResultData.new(HitResult.WATER, water_hit_pos, null, impact_vel, null, Vector3.ZERO)
			else:
				var underwater_ship: Ship = PrecisionPhysicsWorld.get_ship_from_obb(ship_result['collider'])
				if underwater_ship == null or underwater_ship == projectile.owner or underwater_ship in projectile.exclude:
					return ArmorResultData.new(HitResult.WATER, water_hit_pos, null, impact_vel, null, Vector3.ZERO)

				# Narrowphase: precision cast the underwater ray in local space
				var local_ray := PrecisionPhysicsWorld.world_ray_to_local(underwater_ship, water_hit_pos, fuzed_position)
				var precision_result := PrecisionPhysicsWorld.precision_raycast(underwater_ship, local_ray[0], local_ray[1])

				if precision_result.is_empty():
					return ArmorResultData.new(HitResult.WATER, water_hit_pos, null, impact_vel, null, Vector3.ZERO)

				var hit_armor := precision_result['collider'] as ArmorPart
				if hit_armor == null:
					return ArmorResultData.new(HitResult.WATER, water_hit_pos, null, impact_vel, null, Vector3.ZERO)

				var local_hit_pos: Vector3 = precision_result.get('position')
				var world_hit_pos: Vector3 = PrecisionPhysicsWorld.local_to_world(underwater_ship, local_hit_pos)
				var world_hit_normal: Vector3 = PrecisionPhysicsWorld.local_dir_to_world(underwater_ship, precision_result.get('normal')).normalized()

				var total_dist := (fuzed_position - water_hit_pos).length()
				var hit_dist := (world_hit_pos - water_hit_pos).length()
				var t_impact: float = projectile.params.fuze_delay * (hit_dist / total_dist)
				var water_p = projectile.params.duplicate(true)
				water_p.drag *= WATER_DRAG
				var water_impact_vel := ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
					impact_vel, t_impact, water_p)

				return _process_hit(hit_armor, world_hit_pos, world_hit_normal,
					projectile, water_impact_vel, precision_result.get('face_index'),
					t_impact, space_state, true, events)

	return null

const EPSILON: float = 0.0001
func _process_hit(hit_node: ArmorPart, hit_position: Vector3, hit_normal: Vector3,
		projectile: ProjectileData, impact_velocity: Vector3,
		face_index: int, fuze: float, space_state: PhysicsDirectSpaceState3D,
		hit_water: bool, events) -> ArmorResultData:

	var first_hit_normal := hit_normal
	var first_hit_pos := hit_position
	var params:ShellParams = projectile.params
	var ship := hit_node.ship
	var first_hit_node := hit_node
	var overmatch_first_armor := false

	# Transform everything into ship-local space so that floating-point
	# precision is maximised (the precision world sits at the origin).
	var ship_xform := ship.global_transform
	var ship_inv_xform := ship_xform.affine_inverse()
	var ship_basis := ship_xform.basis
	var ship_basis_inv := ship_inv_xform.basis

	hit_position = ship_inv_xform * hit_position
	hit_normal = (ship_basis_inv * hit_normal).normalized()

	var shell := _ShellData.new()
	shell.position = hit_position
	shell.velocity = ship_basis_inv * impact_velocity
	shell.fuze = fuze
	shell.params = params
	shell.calc_end_position()

	# Energy-balance ricochet model is deterministic — no RNG needed.
	# Ricochet emerges from the obliquity multiplier exceeding the shell's
	# available penetration energy.

	var result: ArmorResult = ArmorResult.OVERPEN
	var hit_cit := false
	var over_pen := false

	# var events: Array[String] = []
	events.append("Processing Shell: %s %s " % [params.caliber, params.type])
	var ship_scene_path := ship.scene_file_path
	events.append("Ship: %s pos=(%.15f, %.15f, %.15f), rot=(%.10f, %.10f, %.10f), scene=%s [%s]" % [
		ship.name,
		ship.global_transform.origin.x, ship.global_transform.origin.y, ship.global_transform.origin.z,
		rad_to_deg(ship.global_transform.basis.get_euler().x),
		rad_to_deg(ship.global_transform.basis.get_euler().y),
		rad_to_deg(ship.global_transform.basis.get_euler().z),
		ship_scene_path,
		"PRECISION"])

	if hit_water:
		events.append(" - Hit water first, fuze: %.3f s" % [shell.fuze])
		if params.type == ShellParams.ShellType.HE:
			return ArmorResultData.new(HitResult.WATER, first_hit_pos, null, impact_velocity, null, first_hit_normal)

	# HE Shell Processing
	if params.type == ShellParams.ShellType.HE:
		var armor_mm: float = hit_node.get_armor(face_index)

		var result_armor := hit_node

		if params.overmatch >= armor_mm:
			var hit_result := HitResult.CITADEL if hit_node.is_citadel else HitResult.PENETRATION
			return ArmorResultData.new(hit_result, first_hit_pos, result_armor, impact_velocity, ship, first_hit_normal)
		else:
			return ArmorResultData.new(HitResult.SHATTER, first_hit_pos, result_armor, Vector3.ZERO, ship, first_hit_normal)

	# APC Shell Processing Loop
	var iteration := 0
	var max_iterations := 20

	var offset = Vector3.ZERO
	while shell.fuze <= params.fuze_delay and result != ArmorResult.SHATTER and \
		  hit_node.ship == ship and iteration < max_iterations:
		iteration += 1
		var armor_mm: float = hit_node.get_armor(face_index)
		var speed: float = shell.get_speed()

		# hit_normal here is already in local space (local_hit_normal on first
		# iteration, updated from precision raycast results on subsequent ones)
		var impact_angle := _calculate_impact_angle(shell.velocity.normalized(), hit_normal)
		var e_armor := calculate_effective_thickness(armor_mm, impact_angle)

		shell.pen = calculate_de_marre_penetration(params.mass, speed, params.caliber) * params.penetration_modifier
		shell.position = hit_position + offset

		var _log_vel := ship_basis * shell.velocity
		var _log_pos := ship_xform * shell.position
		events.append("Shell: speed=%.15f vel=(%.15f, %.15f, %.15f) m/s, fuze=%.3f s, pos=(%.15f, %.15f, %.15f), pen: %.1f" % [
			shell.get_speed(), _log_vel.x, _log_vel.y, _log_vel.z,
			shell.fuze, _log_pos.x, _log_pos.y, _log_pos.z, shell.pen])
		offset = Vector3.ZERO
		var deflection_mult := 1.0

		# --- Overmatch: caliber vastly exceeds plate thickness ---
		# Shell punches through with minimal resistance. Historically justified:
		# a 460mm shell hitting 19mm plating is not going to be stopped or deflected.
		# The energy-balance model mostly handles this (low T/D = low deflection),
		# but this avoids wasting cycles on the multiplier math for trivial plates.
		if armor_mm <= params.overmatch:
			if hit_node.is_citadel:
				hit_cit = true
			result = ArmorResult.OVERPEN
			over_pen = true
			if iteration == 1:
				overmatch_first_armor = true

			var pen_ratio := e_armor / maxf(shell.pen, 1.0)
			shell.velocity *= (1.0 - pen_ratio * 0.3)
			shell.integrity = calculate_shell_integrity(pen_ratio * 0.5, shell.integrity)
			offset += shell.velocity.normalized() * EPSILON

			if shell.fuze < 0.0 and e_armor > params.arming_threshold:
				shell.fuze = 0.0

		# --- Autobounce: hard physics ceiling ---
		# Above ~80° no realistic naval shell can maintain nose-first penetration.
		# The energy model already makes this near-impossible, but the hard cap
		# prevents numerical edge cases at extreme grazing angles.
		elif impact_angle > params.auto_bounce:
			result = ArmorResult.RICOCHET
			# Grazing hit — very little energy transferred to plate
			var energy_loss := 0.1
			shell.velocity = calculate_ricochet_velocity(
				shell.velocity, hit_normal, impact_angle, energy_loss)
			offset += hit_normal * EPSILON

			if shell.fuze < 0.0 and impact_angle > deg_to_rad(70.0):
				shell.fuze = 0.0

		# --- Energy-balance armor interaction ---
		else:
			var interaction := _evaluate_armor_interaction(shell, params, impact_angle, armor_mm, e_armor)
			result = interaction["result"]
			deflection_mult = interaction["deflection_mult"]

			match result:
				ArmorResult.RICOCHET:
					var energy_loss: float = interaction["energy_loss_fraction"]
					shell.velocity = calculate_ricochet_velocity(
						shell.velocity, hit_normal, impact_angle, energy_loss)
					offset += hit_normal * EPSILON

					if shell.fuze < 0.0 and impact_angle > deg_to_rad(70.0):
						shell.fuze = 0.0

				ArmorResult.SHATTER:
					shell.velocity = Vector3.ZERO
					shell.fuze = params.fuze_delay
					shell.position += hit_normal * EPSILON

				ArmorResult.PARTIAL_PEN:
					shell.velocity *= 0.1
					shell.integrity *= 0.5
					offset += shell.velocity.normalized() * EPSILON

				ArmorResult.PEN, ArmorResult.OVERPEN:
					if hit_node.is_citadel:
						hit_cit = true
					over_pen = true

					var pen_ratio: float = interaction["pen_ratio"]
					var exit_speed := calculate_exit_velocity(speed, shell.pen, e_armor)
					var exit_dir := calculate_deflected_direction(
						shell.velocity.normalized(), hit_normal, pen_ratio)

					shell.velocity = exit_dir * exit_speed
					shell.integrity = calculate_shell_integrity(pen_ratio, shell.integrity)
					offset += shell.velocity.normalized() * EPSILON

					if shell.fuze < 0.0 and e_armor > params.arming_threshold:
						shell.fuze = 0.0


		var _log_normal := ship_basis * hit_normal
		events.append("Armor: %s, %s with %.1f/%.1fmm (angle %.1f°, defl_mult %.2f), normal: (%.1f, %.1f, %.1f), ship: %s, is_citadel: %s" % [
			armor_result_to_string(result), hit_node.armor_path, armor_mm, e_armor,
			rad_to_deg(impact_angle), deflection_mult, _log_normal.x, _log_normal.y, _log_normal.z,
			hit_node.ship.name, hit_node.is_citadel])

		# Check termination
		if result == ArmorResult.SHATTER or result == ArmorResult.PARTIAL_PEN or shell.get_speed() < MIN_VELOCITY:
			shell.calc_end_position()
			break

		# if result == ArmorResult.RICOCHET:
		# 	shell.calc_end_position()
		# 	break

		# Find next armor layer
		var next_ray_from: Vector3 = shell.position + offset
		shell.calc_end_position()
		var next_ray_to := shell.end_position

		var next_hit := PrecisionPhysicsWorld.precision_get_next_hit(ship, next_ray_from, next_ray_to)

		if next_hit.is_empty():
			if shell.fuze >= 0.0:
				shell.fuze = params.fuze_delay
			break

		var old_pos := hit_position
		hit_node = next_hit.get('armor')
		hit_position = next_hit.get('position')
		hit_normal = next_hit.get('normal')
		face_index = next_hit.get('face_index')

		var fuze_elapsed := old_pos.distance_to(hit_position) / shell.get_speed()
		if shell.fuze >= 0.0:
			shell.fuze += fuze_elapsed

	# Transform velocity / position back to world space for logging (precision mode)
	# or use them directly (legacy mode).
	var log_vel := ship_basis * shell.velocity
	var log_pos := ship_xform * shell.end_position

	events.append("Shell: speed=%.10f vel=(%.10f, %.10f, %.10f) m/s, fuze=%.3f s, pos=(%.15f, %.15f, %.15f), pen: %.1f" % [
		shell.get_speed(), log_vel.x, log_vel.y, log_vel.z,
		shell.fuze, log_pos.x, log_pos.y, log_pos.z, shell.pen])

	# Determine which part the shell ended up inside
	var d: ArmorPart = PrecisionPhysicsWorld.precision_get_part_hit(ship, shell.end_position)
	events.append("get_part_hit result: %s (citadel=%s)" % [
		d.armor_path if d != null else "null",
		str(d.type == ArmorPart.Type.CITADEL) if d != null else "N/A"])
	events.append("hit_cit flag: %s, over_pen flag: %s" % [hit_cit, over_pen])

	var damage_result := _resolve_hit_result(result, d, hit_cit, over_pen)
	if damage_result == HitResult.CITADEL_OVERPEN:
		d = hit_node.ship.citadel

	events.append("Final Hit Result: %s" % [HitResult.keys()[HitResult.values().find(damage_result)]])

	if (damage_result == HitResult.CITADEL or damage_result == HitResult.CITADEL_OVERPEN) and (ship.ship_name == "Yamato" or ship.ship_name == "Wotan"):
	# if true:
		for e in events:
			print(e)

	# Transform shell velocity back to world space for the result
	var final_world_vel := ship_basis * shell.velocity
	return ArmorResultData.new(damage_result, first_hit_pos, d if d else first_hit_node, final_world_vel, ship, first_hit_normal, shell.integrity)


## Energy-balance ricochet/penetration decision.
## Returns a dictionary with the result and supporting data.
## The obliquity multiplier makes the required penetration energy diverge
## continuously with angle — no autobounce cutoff or sigmoid probability.
## Ricochet vs shatter is determined by whether the deflection penalty
## or raw thickness is what defeated the shell.
func _evaluate_armor_interaction(shell: _ShellData, params: ShellParams,
		impact_angle: float, armor_mm: float, e_armor: float) -> Dictionary:

	var k_nose := get_k_nose(params)
	var obliquity := calculate_obliquity_multiplier(impact_angle, armor_mm, params.caliber, k_nose)
	var deflection_mult: float = obliquity["deflection"]

	# Physics-effective armor: geometric LOS thickness × deflection penalty.
	# This is the thickness the shell "experiences" including the energy cost
	# of fighting the deflection torque.
	var physics_armor := e_armor * deflection_mult

	# Pen ratio against the physics-effective thickness
	var pen_ratio := shell.pen / maxf(physics_armor, 0.1)

	if pen_ratio >= 1.0:
		# Shell has enough energy to overcome both thickness and deflection
		return {
			"result": ArmorResult.OVERPEN,
			"pen_ratio": e_armor / maxf(shell.pen, 0.1),  # ratio against geometric armor for exit velocity
			"deflection_mult": deflection_mult,
			"physics_armor": physics_armor,
		}
	else:
		# Shell failed to penetrate. Was it deflected (ricochet) or stopped (shatter)?
		# If the deflection term is what pushed it over the edge, it's a ricochet.
		# If the shell couldn't even penetrate the geometric LOS thickness, it's
		# a shatter or partial pen.
		var would_pen_without_deflection := shell.pen >= e_armor
		var is_deflection_dominated := deflection_mult >= DEFLECTION_RICOCHET_THRESHOLD

		if is_deflection_dominated and (would_pen_without_deflection or impact_angle > deg_to_rad(55.0)):
			# Deflection torque defeated the shell — it skipped off
			var energy_loss := clampf(shell.pen * cos(impact_angle) / maxf(physics_armor, 0.1), 0.0, 0.8)
			return {
				"result": ArmorResult.RICOCHET,
				"pen_ratio": pen_ratio,
				"deflection_mult": deflection_mult,
				"energy_loss_fraction": energy_loss,
				"physics_armor": physics_armor,
			}
		else:
			# Raw thickness defeated the shell
			var raw_pen_ratio := shell.pen / maxf(e_armor, 0.1)
			if raw_pen_ratio > 0.7:
				return {
					"result": ArmorResult.PARTIAL_PEN,
					"pen_ratio": raw_pen_ratio,
					"deflection_mult": deflection_mult,
					"physics_armor": physics_armor,
				}
			else:
				return {
					"result": ArmorResult.SHATTER,
					"pen_ratio": raw_pen_ratio,
					"deflection_mult": deflection_mult,
					"physics_armor": physics_armor,
				}


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
		(final_part.type == ArmorPart.Type.CITADEL)

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

#endregion


#region Armor Interaction Model Test Output

func _ready() -> void:
	_run_armor_model_tests()


## Test the energy-balance ricochet model with historical shell parameters.
## For each shell/armor combination, sweeps obliquity 0–85° and finds:
##   - The angle where penetration first fails
##   - Whether failure is ricochet (deflection-dominated) or shatter (thickness-dominated)
##   - The deflection multiplier at that angle
## Also shows the "effective overmatch" behavior: shells vs thin armor at extreme angles.
func _run_armor_model_tests() -> void:
	# Historical shell data
	# Sources: NavWeaps gun pages, Okun penetration tables
	var shells := [
		{
			"name": "Yamato 46cm/45 Type 91 APC",
			"mass_kg": 1460.0,
			"velocity_ms": 780.0,   # MV; typical striking ~720 at 20km
			"caliber_mm": 460.0,
			"k_nose": K_NOSE_APC,
			"pen_mod": 1.0,
			"test_velocities": [780.0, 720.0, 650.0],  # MV, ~20km, ~30km
		},
		{
			"name": "Bismarck 38cm/52 SK C/34 APC",
			"mass_kg": 800.0,
			"velocity_ms": 820.0,
			"caliber_mm": 380.0,
			"k_nose": K_NOSE_APC,
			"pen_mod": 1.0,
			"test_velocities": [820.0, 720.0, 620.0],
		},
		{
			"name": "Des Moines 8\"/55 Mk 21 Super Heavy APC",
			"mass_kg": 152.0,
			"velocity_ms": 762.0,
			"caliber_mm": 203.0,
			"k_nose": K_NOSE_APC,
			"pen_mod": 1.0,
			"test_velocities": [762.0, 670.0, 580.0],
		},
	]

	var armor_values := [19.0, 25.0, 32.0, 50.0, 76.0, 100.0, 127.0, 150.0, 200.0, 250.0, 305.0, 380.0, 410.0]

	print("")
	print("=" .repeat(100))
	print("  ARMOR INTERACTION MODEL TEST — Energy-Balance Ricochet (Thompson/Okun Framework)")
	print("=" .repeat(100))
	print("  Obliquity α=%.1f  Deflection γ=%.1f  Ricochet threshold=%.2f" % [
		OBLIQUITY_ALPHA, DEFLECTION_GAMMA, DEFLECTION_RICOCHET_THRESHOLD])
	print("")

	for shell in shells:
		var name: String = shell["name"]
		var mass: float = shell["mass_kg"]
		var caliber: float = shell["caliber_mm"]
		var k_nose: float = shell["k_nose"]
		var pen_mod: float = shell["pen_mod"]
		var test_vels: Array = shell["test_velocities"]

		print("-" .repeat(100))
		print("  %s" % name)
		print("  Mass: %.0f kg  Caliber: %.0f mm  K_nose: %.3f" % [mass, caliber, k_nose])
		print("-" .repeat(100))

		for vel in test_vels:
			var pen_normal := calculate_de_marre_penetration(mass, vel, caliber) * pen_mod

			print("")
			print("  Striking velocity: %.0f m/s  |  Penetration at normal: %.0f mm" % [vel, pen_normal])
			print("  %s | %s | %s | %s | %s | %s | %s" % [
				"Armor(mm)".rpad(10),
				"T/D".rpad(6),
				"Ricochet°".rpad(10),
				"Type".rpad(10),
				"Defl@rico".rpad(10),
				"Max pen°".rpad(10),
				"75° result".rpad(12),
			])
			print("  " + "-" .repeat(80))

			for armor_mm in armor_values:
				var td_ratio: float = armor_mm / caliber
				var ricochet_angle := -1.0
				var ricochet_type := ""
				var ricochet_defl := 0.0
				var max_pen_angle := -1.0

				# Sweep obliquity 0°–85° in 1° steps
				for deg in range(0, 86):
					var angle_rad := deg_to_rad(float(deg))
					var e_armor := calculate_effective_thickness(armor_mm, angle_rad)
					var obliq := calculate_obliquity_multiplier(angle_rad, armor_mm, caliber, k_nose)
					var physics_armor: float = e_armor * obliq["deflection"]

					if pen_normal * pen_mod >= physics_armor:
						max_pen_angle = float(deg)
					elif ricochet_angle < 0.0:
						# First angle where pen fails
						ricochet_angle = float(deg)
						ricochet_defl = obliq["deflection"]

						# Classify: ricochet vs shatter
						var would_pen_geo := pen_normal * pen_mod >= e_armor
						var defl_dominated: bool = obliq["deflection"] >= DEFLECTION_RICOCHET_THRESHOLD
						if defl_dominated and (would_pen_geo or angle_rad > deg_to_rad(55.0)):
							ricochet_type = "RICOCHET"
						elif pen_normal * pen_mod / maxf(e_armor, 0.1) > 0.7:
							ricochet_type = "PARTIAL"
						else:
							ricochet_type = "SHATTER"

				# Check 75° specifically
				var test_75_rad := deg_to_rad(75.0)
				var e_75 := calculate_effective_thickness(armor_mm, test_75_rad)
				var obliq_75 := calculate_obliquity_multiplier(test_75_rad, armor_mm, caliber, k_nose)
				var phys_75: float = e_75 * obliq_75["deflection"]
				var result_75 := "PEN" if pen_normal * pen_mod >= phys_75 else "FAIL"
				if result_75 == "PEN":
					result_75 = "PEN (d=%.2f)" % obliq_75["deflection"]
				else:
					var ratio_75 := pen_normal * pen_mod / maxf(phys_75, 0.1)
					result_75 = "FAIL %.0f%%" % (ratio_75 * 100.0)

				# Format output
				var rico_str := "%.0f°" % ricochet_angle if ricochet_angle >= 0.0 else "NEVER"
				var max_pen_str := "%.0f°" % max_pen_angle if max_pen_angle >= 0.0 else "NONE"
				var defl_str := "%.3f" % ricochet_defl if ricochet_angle >= 0.0 else "---"

				if ricochet_angle < 0.0:
					ricochet_type = "---"

				print("  %s | %s | %s | %s | %s | %s | %s" % [
					("%.0f" % armor_mm).rpad(10),
					("%.2f" % td_ratio).rpad(6),
					rico_str.rpad(10),
					ricochet_type.rpad(10),
					defl_str.rpad(10),
					max_pen_str.rpad(10),
					result_75.rpad(12),
				])

		print("")

	# Additional detail: show the obliquity multiplier curve for APC at various T/D
	print("")
	print("=" .repeat(100))
	print("  OBLIQUITY MULTIPLIER CURVES — K_nose=%.3f (APC)" % K_NOSE_APC)
	print("  M(Ob) = (1/cos)^%.1f × (1 + %.3f × tan^%.1f × f(T/D))" % [
		OBLIQUITY_ALPHA, K_NOSE_APC, DEFLECTION_GAMMA])
	print("=" .repeat(100))

	var td_test_values := [0.1, 0.25, 0.5, 1.0, 1.5, 2.0]
	var angle_steps := [0, 10, 20, 30, 40, 45, 50, 55, 60, 65, 70, 75, 80]

	# Header
	var header := "  Ob°   | 1/cos   "
	for td in td_test_values:
		header += "| T/D=%.2f " % td
	print(header)
	print("  " + "-" .repeat(88))

	for deg in angle_steps:
		var angle_rad := deg_to_rad(float(deg))
		var cos_inv := 1.0 / maxf(cos(angle_rad), 0.05)
		var line := "  %s| %s" % [
			("%d°" % deg).rpad(8),
			("%.3f" % cos_inv).rpad(8),
		]
		for td in td_test_values:
			# Use representative values: caliber=380mm, armor = td * 380
			var armor_mm: float = td * 380.0
			var obliq := calculate_obliquity_multiplier(angle_rad, armor_mm, 380.0, K_NOSE_APC)
			line += "| %s" % ("%.3f" % obliq["multiplier"]).rpad(9)
		print(line)

	# Show the deflection component separately
	print("")
	print("  Deflection component only (multiplier on top of geometric 1/cos):")
	var header2 := "  Ob°   "
	for td in td_test_values:
		header2 += "| T/D=%.2f " % td
	print(header2)
	print("  " + "-" .repeat(72))

	for deg in angle_steps:
		var angle_rad := deg_to_rad(float(deg))
		var line := "  %s" % ("%d°" % deg).rpad(8)
		for td in td_test_values:
			var armor_mm: float = td * 380.0
			var obliq := calculate_obliquity_multiplier(angle_rad, armor_mm, 380.0, K_NOSE_APC)
			line += "| %s" % ("%.4f" % obliq["deflection"]).rpad(9)
		print(line)

	print("")
	print("=" .repeat(100))
	print("  Notes:")
	print("  - 'Ricochet°' = lowest obliquity where shell fails to penetrate")
	print("  - 'Type' = whether failure is RICOCHET (deflection-dominated) or SHATTER (raw thickness)")
	print("  - 'Defl@rico' = deflection multiplier at the ricochet angle (1.0 = pure geometry)")
	print("  - 'Max pen°' = highest angle where shell still penetrates")
	print("  - '75° result' = outcome at 75° obliquity (extreme plunging fire angle)")
	print("  - NEVER = shell penetrates at all tested angles (0–85°)")
	print("  - Old overmatch behavior emerges naturally at low T/D ratios")
	print("=" .repeat(100))
	print("")

#endregion
