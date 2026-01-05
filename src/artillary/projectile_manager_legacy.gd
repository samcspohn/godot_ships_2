extends Node
class_name _ProjectileManagerLegacy

const GPUProjectileRendererClass = preload("res://src/artillary/GPUProjectileRenderer.gd")

var shell_time_multiplier: float = 2.0 # Adjust to calibrate shell speed display
var nextId: int = 0;
var projectiles: Array[LegacyProjectileData] = [];
var ids_reuse: Array[int] = []
var shell_param_ids: Dictionary[int, ShellParams] = {}
var bulletId: int = 0
#var shell_resource_path = "res://Shells/"
var gpu_renderer: Node = null # GPU-based renderer (GPUProjectileRenderer)
var ray_query = PhysicsRayQueryParameters3D.new()
var mesh_ray_query = PhysicsRayQueryParameters3D.new() # For detailed mesh intersection

# Compute particle system for trails (optional upgrade path)
var _compute_particle_system: UnifiedParticleSystem = null
var _trail_template_id: int = -1  # Template ID for shell trails
var camera: Camera3D = null

# signal resource_registered(id: int, resource: ShellParams)

class LegacyProjectileData:
	var position: Vector3
	var start_position: Vector3
	var start_time: float
	# var time_elapsed: float
	var launch_velocity: Vector3
	#var p_position: Vector3
	var params: ShellParams
	var trail_pos: Vector3
	var owner: Ship
	var frame_count: int = 0
	var exclude: Array[Ship] = []
	var emitter_id: int = -1  # GPU emitter ID for trail emission

	func initialize(pos: Vector3, vel: Vector3, t: float, p: ShellParams, _owner: Ship, _exclude: Array[Ship] = []):
		self.position = pos
		self.start_position = pos
		#end_pos = ep
		trail_pos = pos + vel.normalized() * 25
		#total_time = t2
		self.params = p
		self.start_time = t
		self.launch_velocity = vel
		self.owner = _owner
		self.frame_count = 0
		self.exclude = _exclude
		self.emitter_id = -1
		# self.time_elapsed = 0.0


func _ready():
	# Run penetration formula validation on startup
	validate_penetration_formula()

	# Auto-register all bullet resources in the directory
	#register_all_bullet_resources()
	#particles = get_node("/root/ProjectileManager1/GPUParticles3D")
	#multi_mesh = get_node("/root/ProjectileManager1/MultiMeshInstance3D")
	#particles = $GPUParticles3D
	#multi_mesh = $MultiMeshInstance3D

	if OS.get_cmdline_args().find("--server") != -1:
		print("running server")
		# set_process(false)
		ray_query.collide_with_areas = true
		ray_query.collide_with_bodies = true
		ray_query.collision_mask = 1 | (1 << 1) # world and detailed mesh collision
		ray_query.hit_back_faces = true
		# ray_query.hit_from_inside = true

		# Configure mesh ray query for detailed armor intersection
		mesh_ray_query.collide_with_areas = false
		mesh_ray_query.collide_with_bodies = true
		mesh_ray_query.collision_mask = 1 << 1 # Second physics layer for detailed mesh collision
		mesh_ray_query.hit_back_faces = true
		set_process(false)


	else:
		print("running client")
		set_physics_process(false)
		# Initialize GPU-based renderer
		gpu_renderer = GPUProjectileRendererClass.new()
		gpu_renderer.set_time_multiplier(shell_time_multiplier)
		add_child(gpu_renderer)
		print("Using GPU-based projectile rendering")

		# Initialize compute particle system for trails (deferred to ensure it exists)
		get_tree().create_timer(0.5).timeout.connect(_init_compute_trails)

	projectiles.resize(1)


func _init_compute_trails() -> void:
	print("ProjectileManager: Initializing compute trails...")

	# Find the UnifiedParticleSystem in the scene tree
	_compute_particle_system = _find_particle_system()

	if _compute_particle_system == null:
		push_warning("ProjectileManager: UnifiedParticleSystem not found, trails disabled")
		return

	print("ProjectileManager: Found UnifiedParticleSystem")

	# Get or register the shell trail template
	# The template should be pre-registered by ParticleSystemInit with align_to_velocity = true
	if _compute_particle_system.template_manager:
		_trail_template_id = _compute_particle_system.template_manager.get_template_id("shell_trail")
		print("ProjectileManager: shell_trail template_id = %d" % _trail_template_id)
		if _trail_template_id < 0:
			push_warning("ProjectileManager: 'shell_trail' template not found, trails disabled")
			return
	else:
		push_warning("ProjectileManager: Template manager not found, trails disabled")
		return

	print("ProjectileManager: Using compute shader trails (template_id=%d)" % _trail_template_id)


func _find_particle_system() -> UnifiedParticleSystem:
	# Check common locations
	if has_node("/root/UnifiedParticleSystem"):
		return get_node("/root/UnifiedParticleSystem")

	# Search in root children
	var root = get_tree().root
	for child in root.get_children():
		if child is UnifiedParticleSystem:
			return child
		# Check one level deeper
		for grandchild in child.get_children():
			if grandchild is UnifiedParticleSystem:
				return grandchild

	return null


# Historical naval armor penetration formula based on empirical data and ballistics research
# References: Nathan Okun's armor penetration studies, naval gunnery manuals

# Hit result types
enum HitResult {
	PENETRATION,
	RICOCHET,
	OVERPENETRATION,
	SHATTER,
	NOHIT,
	CITADEL,
	WATER,
}

# Armor calculation functions
func calculate_penetration_power(shell_params: ShellParams, velocity: float) -> float:
	# Physically realistic naval armor penetration formula
	# Based on historical naval gunnery research and empirical data
	var weight_kg = shell_params.mass # Use mass directly from shell params
	var caliber_mm = shell_params.caliber
	var velocity_ms = velocity
	# var angle_modifier = cos(deg_to_rad(abs(impact_angle_deg)))

	# Modified naval armor penetration formula based on historical data
	# This version uses empirically derived constants for realistic results
	# Penetration (mm) = K * W^0.55 * V^1.1 / D^0.65
	# Where W is weight in kg, V is velocity in m/s, D is caliber in mm
	# 	var naval_constant = 0.000469 # Update for metric units
	var naval_constant_metric = 0.55664
	# Base penetration calculation
	# var base_penetration = naval_constant * pow(weight_kg, 0.55) * pow(velocity_ms, 1.1) / pow(caliber_mm, 0.65)
	# Convert metric to imperial for calculation (weight: kg -> lbs, caliber: mm -> inches, velocity: m/s -> ft/s)
	# var weight_lbs = weight_kg * 2.20462
	# var caliber_in = caliber_mm * 0.0393701
	# var velocity_fps = velocity_ms * 3.28084

	# Imperial formula: Penetration (inches) = K * W^0.55 * V^1.1 / D^0.65
	# var base_penetration_in = naval_constant * pow(weight_lbs, 0.55) * pow(velocity_fps, 1.1) / pow(caliber_in, 0.65)
	# Convert result back to mm
	# var base_penetration = base_penetration_in * 25.4
	var base_penetration = naval_constant_metric * pow(weight_kg, 0.55) * pow(velocity_ms, 1.1) / pow(caliber_mm, 0.65)
	# Apply shell type modifiers
	var shell_quality_factor = 1.0
	if shell_params.type == ShellParams.ShellType.AP: # AP shell
		shell_quality_factor = 1.0 # AP shells are the baseline
	else: # HE shell
		shell_quality_factor = 0.4 # HE shells have much reduced penetration
	# Apply shell-specific penetration modifier
	shell_quality_factor *= shell_params.penetration_modifier
	# Apply angle modifier (oblique impact reduces penetration)
	var final_penetration = base_penetration * shell_quality_factor # * angle_modifier
	# # Debug output for penetration validation
	# print("Penetration Debug: Caliber:", caliber_mm, "mm, Weight:", weight_kg, "kg, Velocity:", velocity_ms, "m/s, type:", "AP" if shell_params.type == 1 else "HE")
	# print("Base penetration:", base_penetration, "mm, Final penetration:", final_penetration, "mm")

	return final_penetration


# return radians
func calculate_impact_angle(velocity: Vector3, surface_normal: Vector3) -> float:
	# Calculate angle between velocity vector and surface normal
	var angle_rad = velocity.normalized().angle_to(surface_normal)
	return min(angle_rad, PI - angle_rad)

class LegacyShellData:
	var params: ShellParams
	var velocity: Vector3
	var position: Vector3
	var end_position: Vector3
	var fuse: float
	var hit_result: HitResult

# Returns the next power of 2 that is >= value
func next_pow_of_2(value: int) -> int:
	if value <= 0:
		return 1

	# Bit manipulation to find next power of 2
	var result = value
	result -= 1
	result |= result >> 1
	result |= result >> 2
	result |= result >> 4
	result |= result >> 8
	result |= result >> 16
	result += 1
	return result

func _process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()

	if camera == null:
		return

	# GPU renderer handles shell position/rendering automatically via shader
	# We only need to update trail particles here
	_process_trails_only(current_time)

## Process only trail particles when using GPU renderer (shells are rendered by GPU)
func _process_trails_only(current_time: float) -> void:
	for p in self.projectiles:
		if p == null:
			continue

		var t = (current_time - p.start_time) * shell_time_multiplier
		# Calculate position for trail emission (still needed for trails)
		p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)

		# Skip trail emission near spawn point
		if (p.position - p.start_position).length_squared() < 80:
			continue

		# Use GPU emitter system for trails if available
		if _compute_particle_system != null and p.emitter_id >= 0:
			# Simply update the emitter position - GPU handles emission automatically
			_compute_particle_system.update_emitter_position(p.emitter_id, p.position)

func find_ship(node: Node):
	if node is Ship or node == null:
		return node
	return find_ship(node.get_parent())

# var time_elapsed: float = 0.0

func _physics_process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var id = 0
	for p in self.projectiles:
		if p == null:
			id += 1
			continue

		p.frame_count += 1

		var t = (current_time - p.start_time) * shell_time_multiplier
		# while p.time_elapsed < current_time - p.start_time:
			# var t = (p.time_elapsed + delta) * shell_time_multiplier
		ray_query.from = p.position
		p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		ray_query.to = p.position

		var hit_result = ArmorInteraction.process_travel(p, ray_query.from, t, space_state)

		if hit_result == null:
			id += 1
			continue

		if hit_result.ship != null and p.owner != null and hit_result.ship not in p.exclude and hit_result.ship != p.owner:
			if p.exclude.size() >= 1:
				print("ricochet exclude ships: ", p.exclude.size())
			# var ship: Ship = collision.collider
			var ship: Ship = hit_result.ship
			var damage = 0.0
			# var sunk = false
			match hit_result.result_type:
				ArmorInteraction.HitResult.PENETRATION:
					damage = p.params.damage / 3.0
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.PENETRATION, hit_result.collision_normal)
				ArmorInteraction.HitResult.CITADEL:
					damage = p.params.damage
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.CITADEL, hit_result.collision_normal)
				ArmorInteraction.HitResult.CITADEL_OVERPEN:
					damage = p.params.damage * 0.5
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.PENETRATION, hit_result.collision_normal)
					pass # todo
				ArmorInteraction.HitResult.OVERPENETRATION:
					damage = p.params.damage * 0.1
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.OVERPENETRATION, hit_result.collision_normal)
				ArmorInteraction.HitResult.SHATTER:
					damage = p.params.damage * 0.0
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.SHATTER, hit_result.collision_normal)
				ArmorInteraction.HitResult.RICOCHET:
					damage = 0.0
					var ricochet_velocity = hit_result.velocity
					var normal = hit_result.collision_normal
					var ricochet_position = hit_result.explosion_position + normal * 0.2 + ricochet_velocity.normalized() * 0.2 # Offset slightly

					var exclude = p.exclude.duplicate()
					exclude.append(ship)
					var ricochet_id = fireBullet(ricochet_velocity, ricochet_position, p.params, current_time, null, exclude)
					TcpThreadPool.send_ricochet(id, ricochet_id, ricochet_position, ricochet_velocity, current_time)

					# if ship.health_controller.is_alive():
					# 	track_ricochet(p)
					# 	# track_damage_event(p, 0, ship.global_position, hit_result.result_type)

					# Destroy the original shell
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.RICOCHET, hit_result.collision_normal)
			if ship.health_controller.is_alive():

				# if hit_result.armor_part.hp:
				# 	var dmg = hit_result.armor_part.hp.apply_damage(damage)
				# 	if dmg <
				# else:
				# 	dmg_sunk = ship.health_controller.apply_damage(min(p.params.damage * 0.1, damage))
				# var dmg = 0.0
				# if hit_result.armor_part.hp:
				# 	dmg = hit_result.armor_part.hp.apply_damage(damage)
				# 	if hit_result.result_type == ArmorInteraction.HitResult.PENETRATION:
				# 		dmg = max(dmg, p.params.damage * 0.1)
				# 	else:
				# 		dmg = damage # citadel, citadel_overpen, overpen, shatter always apply full damage to ship
				# else:
				# 	dmg = min(damage, p.params.damage * 0.1) # non-hull/gun parts apply max 10% of damage to ship
				# var dmg_sunk = ship.health_controller.apply_damage(dmg)
				var dmg_sunk = ship.health_controller.apply_damage(damage,
					 p.params.damage,
					hit_result.armor_part,
					hit_result.result_type == ArmorInteraction.HitResult.PENETRATION)
				apply_fire_damage(p, ship, hit_result.explosion_position)

				# Track damage dealt for player's camera UI
				track_damage_dealt(p, dmg_sunk[0])
				match hit_result.result_type:
					ArmorInteraction.HitResult.PENETRATION:
						track_penetration(p)
					ArmorInteraction.HitResult.CITADEL:
						track_citadel(p)
					ArmorInteraction.HitResult.OVERPENETRATION:
						track_overpenetration(p)
					ArmorInteraction.HitResult.SHATTER:
						track_shatter(p)
					ArmorInteraction.HitResult.RICOCHET:
						track_ricochet(p)
				if dmg_sunk[1]:
					track_frag(p)
				track_damage_event(p, dmg_sunk[0], ship.global_position, hit_result.result_type)
			# end process ship hit
		elif hit_result.result_type == ArmorInteraction.HitResult.WATER:
			destroyBulletRpc(id, hit_result.explosion_position, HitResult.WATER, hit_result.collision_normal)
		elif hit_result.result_type == ArmorInteraction.HitResult.TERRAIN:
			destroyBulletRpc(id, hit_result.explosion_position, HitResult.PENETRATION, hit_result.collision_normal)
		id += 1


#@rpc("authority","reliable")
func fireBullet(vel, pos, shell: ShellParams, t, _owner: Ship, exclude: Array[Ship] = []) -> int:
	var id = self.ids_reuse.pop_back()
	if id == null:
		id = self.nextId
		self.nextId += 1

	if id >= projectiles.size():
		var np2 = next_pow_of_2(id + 1)
		self.projectiles.resize(np2)

	# var expl: CSGSphere3D = preload("res://src/Shells/explosion.tscn").instantiate()
	# expl.radius = shell.damage / 500
	# get_tree().root.add_child(expl)
	# expl.global_position = pos

	var bullet: LegacyProjectileData = LegacyProjectileData.new()
	bullet.initialize(pos, vel, t, shell, _owner, exclude)

	self.projectiles.set(id, bullet)

	return id

func fireBulletClient(pos, vel, t, id, shell: ShellParams, _owner: Ship, muzzle_blast: bool = true, basis: Basis = Basis()) -> void:
	var bullet = ProjectileData.new()

	# Determine shell color based on type (matches original shell colors)
	# The shader will multiply by albedo uniform (3.29) for HDR brightness
	var shell_color: Color
	if shell.type == ShellParams.ShellType.AP:
		shell_color = Color(0.05, 0.1, 1.0, 1.0)  # Blue for AP
	else:
		shell_color = Color(1.0, 0.2, 0.05, 1.0)  # Orange for HE

	# Fire shell through GPU renderer (it manages its own IDs internally)
	var gpu_id = gpu_renderer.fire_shell(pos, vel, shell.drag, shell.size, shell.type, shell_color)

	# Still track in projectiles array for trail emission and ID mapping
	if id >= projectiles.size():
		var np2 = next_pow_of_2(id + 1)
		projectiles.resize(np2)

	bullet.initialize(pos, vel, t, shell, _owner)
	bullet.frame_count = gpu_id  # Store GPU renderer ID in frame_count for mapping

	# Allocate GPU emitter for trail emission
	if _compute_particle_system != null and _trail_template_id >= 0:
		var width_scale = shell.size * 0.9
		# emit_rate = 0.05 means 1 particle per 20 units (matching old step_size)
		bullet.emitter_id = _compute_particle_system.allocate_emitter(
			_trail_template_id,  # template_id
			pos,                 # starting_position
			width_scale,         # size_multiplier
			0.05,                # emit_rate (1/20 = 0.05 particles per unit)
			1.0,                 # speed_scale
			0.0                  # velocity_boost
		)

	self.projectiles.set(id, bullet)

	if muzzle_blast:
		HitEffects.muzzle_blast_effect(pos, basis, shell.size * shell.size)
	#print("shell type: ", shell.type)
	# if muzzle_blast:
	# 	var expl: CSGSphere3D = preload("uid://bg8ewplv43885").instantiate()
	# 	expl.radius = shell.damage / 500
	# 	get_tree().root.add_child(expl)
	# 	expl.global_position = pos
	# 	#var shell = bullet.get_script()
	# 	#pass

#func request_fire(dir: Vector3, pos: Vector3, shell: int, end_pos: Vector3, total_time: float) -> void:
		#fireBullet(dir,pos, shell, end_pos, total_time)

# @rpc("authority", "call_remote", "reliable", 2)
func destroyBulletRpc2(id, pos: Vector3, hit_result: int, normal: Vector3) -> void:
	var bullet: LegacyProjectileData = self.projectiles.get(id)
	if bullet == null:
		print("bullet is null: ", id)
		return
	var radius = bullet.params.size

	# Free the GPU emitter if one was allocated
	if bullet.emitter_id >= 0 and _compute_particle_system != null:
		_compute_particle_system.free_emitter(bullet.emitter_id)
		bullet.emitter_id = -1

	# Destroy in GPU renderer
	var gpu_id = bullet.frame_count  # GPU renderer ID was stored here
	gpu_renderer.destroy_shell(gpu_id)

	self.projectiles.set(id, null)

	match hit_result:
		HitResult.WATER:
			HitEffects.splash_effect(pos, radius)
		HitResult.PENETRATION:
			# radius
			HitEffects.he_explosion_effect(pos, radius * 0.8, normal)
			HitEffects.sparks_effect(pos, radius * 0.5, normal)
		HitResult.CITADEL:
			radius *= 1.2
			HitEffects.he_explosion_effect(pos, radius, normal)
			HitEffects.sparks_effect(pos, radius * 0.6, normal)
		HitResult.RICOCHET:
			HitEffects.sparks_effect(pos, radius * 0.5, normal)
		HitResult.OVERPENETRATION:
			HitEffects.sparks_effect(pos, radius * 0.5, normal)
		HitResult.SHATTER:
			HitEffects.sparks_effect(pos, radius * 0.5, normal)
		HitResult.NOHIT:
			# No explosion for NOHIT - projectile passed through without hitting armor
			pass

func destroyBulletRpc(id, position, hit_result: int, normal: Vector3) -> void:
	# var bullet: ProjectileData = self.projectiles.get(id)
	self.projectiles.set(id, null)
	#self.projectiles.erase(id)
	self.ids_reuse.append(id)
	# TcpThreadPool.enqueue_broadcast(JSON.stringify({
	# 	"type": "1",
	# 	"i": id,
	# 	"p": position,
	# 	"r": hit_result,
	# }))
	TcpThreadPool.send_destroy_shell(id, position, hit_result, normal)
	# for p in multiplayer.get_peers():
	# 		self.destroyBulletRpc2.rpc_id(p, id, position, hit_result)
	# var stream = StreamPeerBuffer.new()
	# stream.put_32(id)
	# stream.put_float(position.x)
	# stream.put_float(position.y)
	# stream.put_float(position.z)
	# stream.put_8(hit_result)
	# var data = stream.data_array
	# for p in multiplayer.get_peers():
	# 	destroyBulletRpc3.rpc_id(p, data)

@rpc("authority", "call_remote", "reliable", 2)
func destroyBulletRpc3(data: PackedByteArray) -> void:
	if data.size() < 17:
		print("Invalid data size for destroyBulletRpc3")
		return
	var stream = StreamPeerBuffer.new()
	stream.data_array = data
	var id = stream.get_32()
	var pos = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
	var hit_result = stream.get_8()
	var normal = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
	destroyBulletRpc2(id, pos, hit_result, normal)

func apply_fire_damage(projectile: LegacyProjectileData, ship: Ship, hit_position: Vector3):
	# Apply fire damage (only for HE shells or normal penetrations)
	if projectile.params.fire_buildup > 0:
		var closest_fire: Fire = null
		var closest_fire_dist = 1000000000.0
		for f in ship.fire_manager.fires:
			var dist = f.global_position.distance_squared_to(hit_position)
			if dist < closest_fire_dist:
				closest_fire_dist = dist
				closest_fire = f
		if closest_fire:
			if closest_fire._apply_build_up(projectile.params.fire_buildup, projectile.owner):
				# increment fire stats
				pass

func print_armor_debug(armor_result: Dictionary, ship: Ship):
	var ship_class = "Unknown"
	if ship.health_controller.max_hp > 40000:
		ship_class = "Battleship"
	elif ship.health_controller.max_hp > 15000:
		ship_class = "Cruiser"
	else:
		ship_class = "Destroyer"

	var result_name = ""
	match armor_result.result_type:
		HitResult.PENETRATION: result_name = "PENETRATION"
		HitResult.RICOCHET: result_name = "RICOCHET"
		HitResult.OVERPENETRATION: result_name = "OVERPENETRATION"
		HitResult.SHATTER: result_name = "SHATTER"
		HitResult.NOHIT: result_name = "NOHIT"

	var armor_data = armor_result.get("armor_data", {})
	var hit_location = armor_data.get("node_path", "unknown")
	var face_index = armor_data.get("face_index", 0)

	print("🛡️ %s vs %s: %s | Target: %s face %d | %.0fmm pen vs %.0fmm armor at %.1f° | %.0f damage" % [
		result_name, ship_class, result_name, hit_location, face_index,
		armor_result.penetration_power, armor_result.armor_thickness,
		armor_result.impact_angle, armor_result.damage
	])

# Validation function for testing penetration formula
func validate_penetration_formula():
	print("=== Penetration Formula Validation ===")

	# Test 380mm BB shell (similar to historical 15" shells)
	var bb_shell = ShellParams.new()
	bb_shell.caliber = 380.0
	bb_shell.mass = 800.0 # Historical 380mm AP shell mass in kg
	bb_shell.type = ShellParams.ShellType.AP # AP
	bb_shell.penetration_modifier = 1.0

	var bb_penetration = calculate_penetration_power(bb_shell, 820.0)
	print("380mm AP shell at 820 m/s, 0° impact: ", bb_penetration, "mm penetration")
	print("Expected: ~700-800mm for battleship shells")

	var super_bb_shell = ShellParams.new()
	super_bb_shell.caliber = 500.0
	super_bb_shell.mass = 1850.0 # Hypothetical 500mm AP shell
	super_bb_shell.type = ShellParams.ShellType.AP # AP
	super_bb_shell.penetration_modifier = 1.0

	var super_bb_penetration = calculate_penetration_power(super_bb_shell, 810.0)
	print("500mm AP shell at 810 m/s, 0° impact: ", super_bb_penetration, "mm penetration")
	print("Expected: ~1200-1300mm for super battleship shells")

	# Test 203mm CA shell (similar to 8" shells)
	var ca_shell = ShellParams.new()
	ca_shell.caliber = 203.0
	ca_shell.mass = 118.0 # Historical 203mm AP shell mass in kg
	ca_shell.type = ShellParams.ShellType.AP # AP
	ca_shell.penetration_modifier = 1.0

	var ca_penetration = calculate_penetration_power(ca_shell, 760.0)
	print("203mm AP shell at 760 m/s, 0° impact: ", ca_penetration, "mm penetration")
	print("Expected: ~200-300mm for cruiser shells")

	# Test 152mm secondary shell
	var sec_shell = ShellParams.new()
	sec_shell.caliber = 152.0
	sec_shell.mass = 45.3 # Historical 152mm AP shell mass in kg
	sec_shell.type = ShellParams.ShellType.AP # AP
	sec_shell.penetration_modifier = 1.0

	var sec_penetration = calculate_penetration_power(sec_shell, 900.0)
	print("152mm AP shell at 900 m/s, 0° impact: ", sec_penetration, "mm penetration")
	print("Expected: ~150-200mm for secondary guns")

	# Test oblique impact (45 degrees)
	var oblique_penetration = calculate_penetration_power(bb_shell, 820.0)
	print("380mm AP shell at 820 m/s, 45° impact: ", oblique_penetration, "mm penetration")
	print("Expected: ~70% of normal impact due to angle")


	# test air drag vs water drag
	print("=== End of Penetration Formula Validation ===")

	var air_pos_after_0_035s = ProjectilePhysicsWithDrag.calculate_position_at_time(Vector3.ZERO, Vector3(0,0,820), 0.035, 0.009)
	var water_pos_after_0_035s = ProjectilePhysicsWithDrag.calculate_position_at_time(Vector3.ZERO, Vector3(0,0,820), 0.035, 0.009 * ArmorInteraction.WATER_DRAG)
	print("Position after 0.035s in air drag: ", air_pos_after_0_035s)
	print("Position after 0.035s in water drag: ", water_pos_after_0_035s)

	var speed_at_0_035s_air = ProjectilePhysicsWithDrag.calculate_velocity_at_time(Vector3(0,0,820), 0.035, 0.009)
	var speed_at_0_035s_water = ProjectilePhysicsWithDrag.calculate_velocity_at_time(Vector3(0,0,820), 0.035, 0.009 * ArmorInteraction.WATER_DRAG)
	print("Speed after 0.035s in air drag: ", speed_at_0_035s_air)
	print("Speed after 0.035s in water drag: ", speed_at_0_035s_water)

func track_damage_dealt(p: LegacyProjectileData, damage: float):
	"""Track damage dealt using the ship's stats module"""
	if not p or not is_instance_valid(p):
		return

	# Add damage to the ship's stats module
	if p.owner.stats:
		p.owner.stats.total_damage += damage
		if p.params._secondary:
			p.owner.stats.sec_damage += damage
		else:
			p.owner.stats.main_damage += damage

func track_damage_event(p: LegacyProjectileData, damage: float, position: Vector3, type: ArmorInteraction.HitResult):
	if not p or not is_instance_valid(p):
		return

	if p.owner.stats:
		p.owner.stats.damage_events.append({"type": type, "sec": p.params._secondary, "damage": damage, "position": position})

func track_penetration(p: LegacyProjectileData):
	if not p or not is_instance_valid(p):
		return

	# Add penetration to the ship's stats module
	if p.owner.stats:
		if !p.params._secondary:
			p.owner.stats.penetration_count += 1
			p.owner.stats.main_hits += 1
		else:
			p.owner.stats.sec_penetration_count += 1
			p.owner.stats.secondary_count += 1


func track_citadel(p: LegacyProjectileData):
	if not p or not is_instance_valid(p):
		return

	# Add citadel hits to the ship's stats module
	if p.owner.stats:
		if !p.params._secondary:
			p.owner.stats.citadel_count += 1
			p.owner.stats.main_hits += 1
		else:
			p.owner.stats.sec_citadel_count += 1
			p.owner.stats.secondary_count += 1

func track_overpenetration(p: LegacyProjectileData):
	if not p or not is_instance_valid(p):
		return

	# Add overpenetration to the ship's stats module
	if p.owner.stats:
		if !p.params._secondary:
			p.owner.stats.overpen_count += 1
			p.owner.stats.main_hits += 1
		else:
			p.owner.stats.sec_overpen_count += 1
			p.owner.stats.secondary_count += 1

func track_shatter(p: LegacyProjectileData):
	if not p or not is_instance_valid(p):
		return

	# Add shatter to the ship's stats module
	if p.owner.stats:
		if !p.params._secondary:
			p.owner.stats.shatter_count += 1
			p.owner.stats.main_hits += 1
		else:
			p.owner.stats.sec_shatter_count += 1
			p.owner.stats.secondary_count += 1

func track_ricochet(p: LegacyProjectileData):
	if not p or not is_instance_valid(p):
		return

	# Add ricochet to the ship's stats module
	if p.owner.stats:
		if !p.params._secondary:
			p.owner.stats.ricochet_count += 1
			p.owner.stats.main_hits += 1
		else:
			p.owner.stats.sec_ricochet_count += 1
			p.owner.stats.secondary_count += 1

func track_frag(p: LegacyProjectileData):
	if not p or not is_instance_valid(p):
		return

	# Add frag to the ship's stats module
	if p.owner.stats:
		p.owner.stats.frags += 1

@rpc("authority", "call_remote", "reliable", 2)
func createRicochetRpc(original_shell_id: int, new_shell_id: int, ricochet_position: Vector3, ricochet_velocity: Vector3, ricochet_time: float):
	var p = projectiles.get(original_shell_id)
	if p == null:
		print("Warning: Could not find original shell with ID ", original_shell_id, " for ricochet")
		return

	fireBulletClient(ricochet_position, ricochet_velocity, ricochet_time, new_shell_id, p.params, null, false)

@rpc("authority", "call_remote", "reliable", 2)
func createRicochetRpc2(data: PackedByteArray):
	if data.size() < 32:
		print("Warning: Invalid ricochet data size")
		return
	var stream = StreamPeerBuffer.new()
	stream.data_array = data
	var original_shell_id = stream.get_32()
	var new_shell_id = stream.get_32()
	var ricochet_position = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
	var ricochet_velocity = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
	var ricochet_time = stream.get_double()
	createRicochetRpc(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time)
