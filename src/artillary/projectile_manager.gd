extends Node
class_name _ProjectileManager

var shell_time_multiplier: float = 1.5 # Adjust to calibrate shell speed display
var nextId: int = 0;
var projectiles: Array[ProjectileData] = [];
var ids_reuse: Array[int] = []
var shell_param_ids: Dictionary[int, ShellParams] = {}
var bulletId: int = 0
#var shell_resource_path = "res://Shells/"
@onready var particles: GPUParticles3D
@onready var multi_mesh: MultiMeshInstance3D
var ray_query = PhysicsRayQueryParameters3D.new()
var mesh_ray_query = PhysicsRayQueryParameters3D.new() # For detailed mesh intersection

var transforms = PackedFloat32Array()
var colors = PackedColorArray()
var camera: Camera3D = null

# signal resource_registered(id: int, resource: ShellParams)

class ProjectileData:
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

	func initialize(pos: Vector3, vel: Vector3, t: float, p: ShellParams, _owner: Ship):
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
		# self.time_elapsed = 0.0


func _ready():
	# Run penetration formula validation on startup
	validate_penetration_formula()

	# Auto-register all bullet resources in the directory
	#register_all_bullet_resources()
	#particles = get_node("/root/ProjectileManager1/GPUParticles3D")
	#multi_mesh = get_node("/root/ProjectileManager1/MultiMeshInstance3D")
	particles = $GPUParticles3D
	multi_mesh = $MultiMeshInstance3D

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


	else:
		print("running client")
		set_physics_process(false)
		print("running client")

	transforms.resize(16)
	projectiles.resize(1)
	colors.resize(1)


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
	# var naval_constant = 0.0004282 # Update for metric units
	var naval_constant_metric = 0.557
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

class ShellData:
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

func transform_to_packed_float32array(transform: Transform3D) -> PackedFloat32Array:
	# Create a PackedFloat32Array with 16 elements (3x4 matrix)
	var array = PackedFloat32Array()
	array.resize(16)

	# Extract basis (3x3 rotation matrix)
	array[0] = transform.basis.x.x
	array[1] = transform.basis.x.y
	array[2] = transform.basis.x.z
	array[3] = transform.basis.y.x
	array[4] = transform.basis.y.y
	array[5] = transform.basis.y.z
	array[6] = transform.basis.z.x
	array[7] = transform.basis.z.y
	array[8] = transform.basis.z.z

	# Extract origin (translation)
	array[9] = transform.origin.x
	array[10] = transform.origin.y
	array[11] = transform.origin.z

	return array

func update_transform_pos(idx, pos):
	# Basis (3x3 rotation/scale matrix)
	var offset = idx * 16
	transforms[offset + 3] = pos.x
	transforms[offset + 7] = pos.y
	transforms[offset + 11] = pos.z

func update_transform_scale(idx, scale: float):
	# Calculate offset in the transforms array for this instance
	var offset = idx * 16

	# Get current x-basis direction and normalize it
	var x_basis = Vector3(transforms[offset + 0], transforms[offset + 1], transforms[offset + 2])
	if x_basis.length_squared() > 0.0001: # Avoid normalizing zero vectors
		x_basis = x_basis.normalized() * scale
	else:
		x_basis = Vector3(scale, 0, 0) # Default x-axis if current basis is effectively zero

	# Get current y-basis direction and normalize it
	var y_basis = Vector3(transforms[offset + 4], transforms[offset + 5], transforms[offset + 6])
	if y_basis.length_squared() > 0.0001:
		y_basis = y_basis.normalized() * scale
	else:
		y_basis = Vector3(0, scale, 0) # Default y-axis if current basis is effectively zero

	# Store the new scaled basis vectors
	transforms[offset + 0] = x_basis.x
	transforms[offset + 1] = x_basis.y
	transforms[offset + 2] = x_basis.z

	transforms[offset + 4] = y_basis.x
	transforms[offset + 5] = y_basis.y
	transforms[offset + 6] = y_basis.z

	# We don't modify z-basis as per billboard requirements

func __process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()

	var distance_factor = 0.0003 * deg_to_rad(camera.fov) # How much to compensate for distance
	var id = 0
	for p in self.projectiles:
		if p == null:
			id += 1
			continue

		var t = (current_time - p.start_time) * shell_time_multiplier
		p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		update_transform_pos(id, p.position)

		# Calculate distance-based scale to counter perspective shrinking
		var distance = camera.global_position.distance_to(p.position)
		var base_scale = p.params.size # Normal scale at close range
		var max_scale_factor = INF # Cap the maximum scale increase
		var scale_factor = min(base_scale * (1 + distance * distance_factor), max_scale_factor)
		update_transform_scale(id, scale_factor)

		id += 1
		var offset = p.position - p.trail_pos
		if (p.position - p.start_position).length_squared() < 80:
			continue
		var offset_length = offset.length()
		const step_size = 20
		var vel = offset.normalized()
		offset = vel * step_size

		var trans = Transform3D.IDENTITY.translated(p.trail_pos)
		while offset_length > step_size:
			# Pass width scale in color.r (red channel) - other channels unused for now
			var width_scale = p.params.size * 0.9 # Adjust this multiplier as needed
			var color_data = Color(width_scale, 1.0, 1.0, 1.0) # width_scale in red, others set to 1.0

			particles.emit_particle(trans, vel, color_data, Color.WHITE, 5 | 8) # Emit particle with color
			trans = trans.translated(offset)
			p.trail_pos += offset
			offset_length -= step_size

	self.multi_mesh.multimesh.instance_count = int(transforms.size() / 16.0)
	self.multi_mesh.multimesh.visible_instance_count = self.multi_mesh.multimesh.instance_count
	self.multi_mesh.multimesh.buffer = transforms


func find_ship(node: Node):
	if node is Ship or node == null:
		return node
	return find_ship(node.get_parent())

# var time_elapsed: float = 0.0

func _physics_process(delta: float) -> void:
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

		if hit_result.ship != null and p.owner != null:
			# var ship: Ship = collision.collider
			var ship: Ship = hit_result.ship
			var damage = 0.0
			# var sunk = false
			match hit_result.result_type:
				ArmorInteraction.HitResult.PENETRATION:
					damage = p.params.damage / 3.0
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.PENETRATION)
				ArmorInteraction.HitResult.CITADEL:
					damage = p.params.damage
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.CITADEL)
				ArmorInteraction.HitResult.CITADEL_OVERPEN:
					damage = p.params.damage * 0.5
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.PENETRATION)
					pass # todo
				ArmorInteraction.HitResult.OVERPENETRATION:
					damage = p.params.damage * 0.1
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.OVERPENETRATION)
				ArmorInteraction.HitResult.SHATTER:
					damage = p.params.damage * 0.0
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.SHATTER)
				ArmorInteraction.HitResult.RICOCHET:
					damage = 0.0
					var ricochet_velocity = hit_result.velocity
					var ricochet_position = hit_result.explosion_position + ricochet_velocity.normalized() * 0.1 # Offset slightly to avoid z-fighting

					var ricochet_id = fireBullet(ricochet_velocity, ricochet_position, p.params, current_time, null)
					for client in multiplayer.get_peers():
						createRicochetRpc.rpc_id(client, id, ricochet_id, ricochet_position, ricochet_velocity, current_time)
					
					if ship.health_controller.is_alive():
						track_ricochet(p)
						track_damage_event(p, 0, ship.global_position, hit_result.result_type)

					# Destroy the original shell
					destroyBulletRpc(id, hit_result.explosion_position, HitResult.RICOCHET)
			if ship.health_controller.is_alive():
				var dmg_sunk = ship.health_controller.take_damage(damage, hit_result.explosion_position)
				apply_fire_damage(p, ship, hit_result.explosion_position)

				# Track damage dealt for player's camera UI
				track_damage_dealt(p, dmg_sunk[0])
				if hit_result.result_type == ArmorInteraction.HitResult.PENETRATION:
					track_penetration(p)
				elif hit_result.result_type == ArmorInteraction.HitResult.CITADEL:
					track_citadel(p)
				elif hit_result.result_type == ArmorInteraction.HitResult.OVERPENETRATION:
					track_overpenetration(p)
				elif hit_result.result_type == ArmorInteraction.HitResult.SHATTER:
					track_shatter(p)
				if dmg_sunk[1]:
					track_frag(p)
				track_damage_event(p, dmg_sunk[0], ship.global_position, hit_result.result_type)
			# end process ship hit
		elif hit_result.result_type == ArmorInteraction.HitResult.WATER:
			destroyBulletRpc(id, hit_result.explosion_position, HitResult.WATER)
		elif hit_result.result_type == ArmorInteraction.HitResult.TERRAIN:
			destroyBulletRpc(id, hit_result.explosion_position, HitResult.PENETRATION)
		id += 1


func update_transform(idx, trans):
	# Fill buffer at correct position
	var offset = idx * 16
	# Basis (3x3 rotation/scale matrix)
	transforms[offset + 0] = trans.basis.x.x
	transforms[offset + 1] = trans.basis.x.y
	transforms[offset + 2] = trans.basis.x.z
	transforms[offset + 3] = trans.origin.x
	transforms[offset + 4] = trans.basis.y.x
	transforms[offset + 5] = trans.basis.y.y
	transforms[offset + 6] = trans.basis.y.z
	transforms[offset + 7] = trans.origin.y
	transforms[offset + 8] = trans.basis.z.x
	transforms[offset + 9] = trans.basis.z.y
	transforms[offset + 10] = trans.basis.z.z
	transforms[offset + 11] = trans.origin.z

func set_color(idx, color: Color):
	var offset = idx * 16
	# Set color at the correct position
	transforms[offset + 12] = color.r
	transforms[offset + 13] = color.g
	transforms[offset + 14] = color.b
	transforms[offset + 15] = color.a

#@rpc("authority","reliable")
func fireBullet(vel, pos, shell: ShellParams, t, _owner: Ship) -> int:
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

	var bullet: ProjectileData = ProjectileData.new()
	bullet.initialize(pos, vel, t, shell, _owner)

	self.projectiles.set(id, bullet)

	return id

func fireBulletClient(pos, vel, t, id, shell: ShellParams, _owner: Ship, muzzle_blast: bool = true) -> void:
	#var bullet: Shell = load("res://Shells/shell.tscn").instantiate()
	var bullet = ProjectileData.new()
	#print("type client ", shell.type)

	if id * 16 >= transforms.size():
		var np2 = next_pow_of_2(id + 1)
		resize_multimesh_buffers(np2)

	var s = shell.size # sqrt(shell.damage / 100)
	var trans = Transform3D.IDENTITY.scaled(Vector3(s, s, s)).translated(pos)
	update_transform(id, trans)

	if shell.type == ShellParams.ShellType.AP: # AP Shell
		set_color(id, Color(0.6, 0.6, 1.0, 1.0)) # Blue for AP shells
	else:
		set_color(id, Color(1.0, 0.8, 0.5, 1.0)) # Orange for HE shells

	bullet.initialize(pos, vel, t, shell, _owner)
	self.projectiles.set(id, bullet)
	#print("shell type: ", shell.type)
	if muzzle_blast:
		var expl: CSGSphere3D = preload("uid://bg8ewplv43885").instantiate()
		expl.radius = shell.damage / 500
		get_tree().root.add_child(expl)
		expl.global_position = pos
		#var shell = bullet.get_script()
		#pass

#func request_fire(dir: Vector3, pos: Vector3, shell: int, end_pos: Vector3, total_time: float) -> void:
		#fireBullet(dir,pos, shell, end_pos, total_time)

@rpc("call_remote", "reliable")
func destroyBulletRpc2(id, pos: Vector3, hit_result: int = HitResult.PENETRATION) -> void:
	var bullet: ProjectileData = self.projectiles.get(id)
	if bullet == null:
		print("bullet is null: ", id)
		return
	var radius = bullet.params.size * 5
	self.projectiles.set(id, null)
	#self.projectiles.erase(id)
	var b = Basis()
	b.x = Vector3.ZERO
	b.y = Vector3.ZERO
	b.z = Vector3.ZERO
	var t = Transform3D(b, Vector3.ZERO)
	update_transform(id, t) # set to invisible
	#self.multi_mesh.multimesh.set_instance_transform(id, t)

	# Create appropriate visual effects based on hit result
	var expl: CSGSphere3D = preload("uid://bg8ewplv43885").instantiate()
	get_tree().root.add_child(expl)
	expl.global_position = pos

	match hit_result:
		HitResult.WATER:
			expl.radius = radius # Smaller explosion for water impact
			expl.scale = Vector3(1,3.5,1)
			var water_material = StandardMaterial3D.new()
			water_material.albedo_color = Color.WHITE_SMOKE
			expl.material_override = water_material
		HitResult.PENETRATION:
			expl.radius = radius
			var pen_material = StandardMaterial3D.new()
			pen_material.albedo_color = Color.LIGHT_YELLOW
			pen_material.emission_enabled = true
			pen_material.emission = Color.YELLOW * 8.0
			expl.material_override = pen_material
		HitResult.CITADEL:
			expl.radius = radius * 2
			var citadel_material = StandardMaterial3D.new()
			citadel_material.albedo_color = Color.LIGHT_YELLOW
			citadel_material.emission_enabled = true
			citadel_material.emission = Color.YELLOW * 8.0
			expl.material_override = citadel_material
		HitResult.RICOCHET:
			expl.radius = radius * 0.3 # Smaller explosion for ricochet
			var ricochet_material = StandardMaterial3D.new()
			ricochet_material.albedo_color = Color.BLUE
			expl.material_override = ricochet_material
		HitResult.OVERPENETRATION:
			expl.radius = radius * 0.6 # Medium explosion
			var overpen_material = StandardMaterial3D.new()
			overpen_material.albedo_color = Color.CYAN
			expl.material_override = overpen_material
		HitResult.SHATTER:
			expl.radius = radius * 0.5 # Very small explosion
			var shatter_material = StandardMaterial3D.new()
			shatter_material.albedo_color = Color.RED
			expl.material_override = shatter_material
		HitResult.NOHIT:
			# No explosion for NOHIT - projectile passed through without hitting armor
			expl.queue_free() # Remove the explosion visual

func destroyBulletRpc(id, position, hit_result: int = HitResult.PENETRATION) -> void:
	# var bullet: ProjectileData = self.projectiles.get(id)
	self.projectiles.set(id, null)
	#self.projectiles.erase(id)
	self.ids_reuse.append(id)
	for p in multiplayer.get_peers():
		self.destroyBulletRpc2.rpc_id(p, id, position, hit_result)

func resize_multimesh_buffers(new_count: int):
	# Resize transform and color arrays
	transforms.resize(new_count * 16)
	colors.resize(new_count)
	projectiles.resize(new_count)
	multi_mesh.multimesh.instance_count = new_count
	# Assign buffers after setting instance_count
	multi_mesh.multimesh.buffer = transforms
	multi_mesh.multimesh.color_array = colors

func apply_fire_damage(projectile: ProjectileData, ship: Ship, hit_position: Vector3):
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

func track_damage_dealt(p: ProjectileData, damage: float):
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

func track_damage_event(p: ProjectileData, damage: float, position: Vector3, type: ArmorInteraction.HitResult):
	if not p or not is_instance_valid(p):
		return

	if p.owner.stats:
		p.owner.stats.damage_events.append({"type": type, "sec": p.params._secondary, "damage": damage, "position": position})

func track_penetration(p: ProjectileData):
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


func track_citadel(p: ProjectileData):
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

func track_overpenetration(p: ProjectileData):
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

func track_shatter(p: ProjectileData):
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

func track_ricochet(p: ProjectileData):
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

func track_frag(p: ProjectileData):
	if not p or not is_instance_valid(p):
		return

	# Add frag to the ship's stats module
	if p.owner.stats:
		p.owner.stats.frags += 1

@rpc("any_peer", "call_local", "reliable")
func createRicochetRpc(original_shell_id: int, new_shell_id: int, ricochet_position: Vector3, ricochet_velocity: Vector3, ricochet_time: float):
	var p = projectiles.get(original_shell_id)
	if p == null:
		print("Warning: Could not find original shell with ID ", original_shell_id, " for ricochet")
		return

	fireBulletClient(ricochet_position, ricochet_velocity, ricochet_time, new_shell_id, p.params, null, false)
