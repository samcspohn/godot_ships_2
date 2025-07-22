extends Node

var nextId: int = 0;
var projectiles: Array[ProjectileData] = [];
var ids_reuse: Array[int] = []
var shell_param_ids: Dictionary[int, ShellParams] = {}
var bulletId: int = 0
#var shell_resource_path = "res://Shells/"
@onready var particles: GPUParticles3D
@onready var multi_mesh: MultiMeshInstance3D
var ray_query = PhysicsRayQueryParameters3D.new()

var transforms = PackedFloat32Array()
var colors = PackedColorArray()
var camera: Camera3D = null

signal resource_registered(id: int, resource: ShellParams)

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
		set_process(false)
		ray_query.collide_with_areas = true
		ray_query.collide_with_bodies = true
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
	SHATTER
}

# Armor calculation functions
func calculate_penetration_power(shell_params: ShellParams, velocity: float, impact_angle_deg: float) -> float:
	# Physically realistic naval armor penetration formula
	# Based on historical naval gunnery research and empirical data
	
	var weight_kg = shell_params.mass  # Use mass directly from shell params
	var caliber_mm = shell_params.caliber
	var velocity_ms = velocity
	var angle_modifier = cos(deg_to_rad(abs(impact_angle_deg)))
	
	# Modified naval armor penetration formula based on historical data
	# This version uses empirically derived constants for realistic results
	# Penetration (mm) = K * W^0.55 * V^1.1 / D^0.65
	# Where W is weight in kg, V is velocity in m/s, D is caliber in mm
	var naval_constant = 0.0004689  # Empirically calibrated for realistic naval penetration
	
	# Base penetration calculation
	# var base_penetration = naval_constant * pow(weight_kg, 0.55) * pow(velocity_ms, 1.1) / pow(caliber_mm, 0.65)
	# Convert metric to imperial for calculation (weight: kg -> lbs, caliber: mm -> inches, velocity: m/s -> ft/s)
	var weight_lbs = weight_kg * 2.20462
	var caliber_in = caliber_mm * 0.0393701
	var velocity_fps = velocity_ms * 3.28084

	# Imperial formula: Penetration (inches) = K * W^0.55 * V^1.1 / D^0.65
	var base_penetration_in = naval_constant * pow(weight_lbs, 0.55) * pow(velocity_fps, 1.1) / pow(caliber_in, 0.65)
	# Convert result back to mm
	var base_penetration = base_penetration_in * 25.4
	
	# Apply shell type modifiers
	var shell_quality_factor = 1.0
	if shell_params.type == 1:  # AP shell
		shell_quality_factor = 1.0  # AP shells are the baseline
	else:  # HE shell
		shell_quality_factor = 0.4  # HE shells have much reduced penetration
	
	# Apply shell-specific penetration modifier
	shell_quality_factor *= shell_params.penetration_modifier
	
	# Apply angle modifier (oblique impact reduces penetration)
	var final_penetration = base_penetration * shell_quality_factor * angle_modifier
	
	# Debug output for penetration validation
	print("Penetration Debug: Caliber:", caliber_mm, "mm, Weight:", weight_kg, "kg, Velocity:", velocity_ms, "m/s")
	print("Base penetration:", base_penetration, "mm, Final penetration:", final_penetration, "mm")
	
	return final_penetration

func calculate_impact_angle(velocity: Vector3, surface_normal: Vector3) -> float:
	# Calculate angle between velocity vector and surface normal
	var angle_rad = velocity.normalized().angle_to(surface_normal)
	# Convert to degrees and get acute angle
	var angle_deg = rad_to_deg(angle_rad)
	return min(angle_deg, 180.0 - angle_deg)

func get_armor_thickness_at_point(ship: Ship, hit_position: Vector3) -> float:
	# Get armor thickness based on ship type and hit location
	# This is a simplified system - in reality you'd have detailed armor schemes
	
	var base_armor = 0.0
	var _ship_name = ship.get_script().get_global_name() if ship.get_script() else "Ship"
	
	# Determine base armor by ship class (based on HP as a rough indicator)
	var max_hp = ship.health_controller.max_hp
	if max_hp > 40000:  # Battleship
		base_armor = 300.0  # 300mm base armor
	elif max_hp > 15000:  # Cruiser
		base_armor = 150.0  # 150mm base armor
	else:  # Destroyer
		base_armor = 20.0   # 20mm base armor
	
	# Apply location modifiers
	var ship_local_pos = ship.to_local(hit_position)
	var armor_modifier = 1.0
	
	# Check if hit is on the sides (citadel area)
	if abs(ship_local_pos.x) < ship.get_node("Hull").size.x * 0.3:
		armor_modifier = 1.5  # Citadel armor is thicker
	
	# Check if hit is on bow/stern
	if abs(ship_local_pos.z) > ship.get_node("Hull").size.z * 0.3:
		armor_modifier = 0.6  # Bow/stern armor is thinner
	
	return base_armor * armor_modifier

func calculate_armor_interaction(projectile: ProjectileData, collision: Dictionary, ship: Ship) -> Dictionary:
	var shell_params = projectile.params
	var current_velocity = projectile.launch_velocity.length()  # Simplified - should account for drag over time
	var impact_angle = calculate_impact_angle(projectile.launch_velocity.normalized(), collision.normal)
	var armor_thickness = get_armor_thickness_at_point(ship, collision.position)
	
	var penetration_power = calculate_penetration_power(shell_params, current_velocity, impact_angle)
	
	# Ricochet check (high angle impacts tend to ricochet)
	if impact_angle > 60.0 and penetration_power < armor_thickness:
		return {
			"result_type": HitResult.RICOCHET,
			"damage": 0.0,
			"penetration_power": penetration_power,
			"armor_thickness": armor_thickness,
			"impact_angle": impact_angle
		}
	
	# Shatter check (insufficient penetration)
	elif penetration_power < armor_thickness:
		return {
			"result_type": HitResult.SHATTER,
			"damage": shell_params.damage * 0.05,  # Minimal damage from fragments
			"penetration_power": penetration_power,
			"armor_thickness": armor_thickness,
			"impact_angle": impact_angle
		}
	
	# Shell penetrates armor - fuze will determine final damage based on location when it explodes
	else:
		return {
			"result_type": HitResult.PENETRATION,
			"damage": shell_params.damage,  # Full damage potential (may be reduced later based on fuze location)
			"penetration_power": penetration_power,
			"armor_thickness": armor_thickness,
			"impact_angle": impact_angle
		}

func calculate_ricochet_vector(incoming_velocity: Vector3, surface_normal: Vector3) -> Vector3:
	# Calculate ricochet direction using reflection
	var reflected = incoming_velocity.bounce(surface_normal)
	# Add some randomness to the ricochet
	var random_deviation = Vector3(
		randf_range(-0.1, 0.1),
		randf_range(-0.05, 0.1),  # Slightly upward bias
		randf_range(-0.1, 0.1)
	) * 10.0
	# return (reflected + random_deviation).normalized() * incoming_velocity.length()
	# Reduce velocity due to energy loss in ricochet
	var velocity_loss = 0.3
	return (reflected + random_deviation).normalized() * incoming_velocity.length() * (1.0 - velocity_loss)

class ProjectileData:
	var position: Vector3
	var start_position: Vector3
	var start_time: float
	var launch_velocity: Vector3
	#var p_position: Vector3
	var params: ShellParams
	var trail_pos: Vector3
	var type: int
	var active: bool
		
	func initialize( pos: Vector3, vel: Vector3, t: float, p: ShellParams):
		self.position = pos
		self.start_position = pos
		#end_pos = ep
		trail_pos = pos + vel.normalized() * 25
		#total_time = t2
		self.params = p
		self.start_time = t
		self.launch_velocity = vel

#var active_projectiles: Array[ProjectileData] = []

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
	if x_basis.length_squared() > 0.0001:  # Avoid normalizing zero vectors
		x_basis = x_basis.normalized() * scale
	else:
		x_basis = Vector3(scale, 0, 0)  # Default x-axis if current basis is effectively zero
	
	# Get current y-basis direction and normalize it
	var y_basis = Vector3(transforms[offset + 4], transforms[offset + 5], transforms[offset + 6])
	if y_basis.length_squared() > 0.0001:
		y_basis = y_basis.normalized() * scale
	else:
		y_basis = Vector3(0, scale, 0)  # Default y-axis if current basis is effectively zero
	
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
			
		var t = (current_time - p.start_time) * 2.0
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
			var width_scale = p.params.size * 0.9  # Adjust this multiplier as needed
			var color_data = Color(width_scale, 1.0, 1.0, 1.0)  # width_scale in red, others set to 1.0
			
			particles.emit_particle(trans, vel, color_data, Color.WHITE, 5 | 8)  # Emit particle with color
			trans = trans.translated(offset)
			p.trail_pos += offset
			offset_length -= step_size
		
	self.multi_mesh.multimesh.instance_count = int(transforms.size() / 16.0)
	self.multi_mesh.multimesh.visible_instance_count = self.multi_mesh.multimesh.instance_count
	self.multi_mesh.multimesh.buffer = transforms


func _physics_process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var id = 0
	for p in self.projectiles:
		if p == null:
			id += 1
			continue
		
		var t = (current_time - p.start_time) * 2.0
		ray_query.from = p.position
		p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		ray_query.to = p.position
		
		# Perform the raycast
		var collision: Dictionary = space_state.intersect_ray(ray_query)
		
		if not collision.is_empty():
			if collision.collider is Ship:
				var ship: Ship = collision.collider
				var armor_result = calculate_armor_interaction(p, collision, ship)
				
				match armor_result.result_type:
					HitResult.PENETRATION:
						# Shell penetrates - simulate fuze delay within this frame
						var current_velocity = ProjectilePhysicsWithDrag.calculate_velocity_at_time(p.launch_velocity, t, p.params.drag)
						var explosion_position = ProjectilePhysicsWithDrag.calculate_position_at_time(
							collision.position, 
							current_velocity, 
							p.params.fuze_delay,  # Use full time to account for drag
							p.params.drag
						)
						
						# Check if shell is inside ship at explosion time using point query
						var point_query = PhysicsPointQueryParameters3D.new()
						point_query.position = explosion_position
						point_query.collide_with_areas = false
						point_query.collide_with_bodies = true
						point_query.collision_mask = 1
						
						var point_results = space_state.intersect_point(point_query)
						var is_inside_ship = false
						
						for result in point_results:
							if result.collider == ship:
								is_inside_ship = true
								break
						
						var final_damage = armor_result.damage
						var hit_type = HitResult.PENETRATION
						
						if is_inside_ship:
							# Shell explodes inside ship - full penetration damage
							final_damage = armor_result.damage * 0.33
							hit_type = HitResult.PENETRATION
							armor_result.result_type = HitResult.PENETRATION
							apply_fire_damage(p, ship, explosion_position)
							print("Shell exploded INSIDE ship after ", p.params.fuze_delay, "s - full damage: ", final_damage)
						else:
							# Shell explodes outside ship - overpenetration
							final_damage = armor_result.damage * 0.1
							hit_type = HitResult.OVERPENETRATION
							armor_result.result_type = HitResult.OVERPENETRATION
							print("Shell exploded OUTSIDE ship after ", p.params.fuze_delay, "s - overpenetration: ", final_damage)
						
						ship.health_controller.take_damage(final_damage, explosion_position)
						destroyBulletRpc(id, explosion_position, hit_type)
						print_armor_debug(armor_result, ship)
					
					HitResult.RICOCHET:
						# Shell ricochets - create new shell with reflected trajectory
						var current_velocity = ProjectilePhysicsWithDrag.calculate_velocity_at_time(p.launch_velocity, t, p.params.drag)
						var ricochet_velocity = calculate_ricochet_vector(current_velocity, collision.normal)
						var ricochet_position = collision.position + collision.normal * 0.1  # Offset slightly to avoid z-fighting

						# ricochet_velocity = collision.normal * ricochet_velocity.length()  # Ensure ricochet is in the correct direction
						var ricochet_id = fireBullet(ricochet_velocity, ricochet_position, p.params, current_time)
						for client in multiplayer.get_peers():
							createRicochetRpc.rpc_id(client, id, ricochet_id, ricochet_position, ricochet_velocity, current_time)

						# Destroy the original shell
						destroyBulletRpc(id, collision.position, HitResult.RICOCHET)
						print_armor_debug(armor_result, ship)
						print("armor normal: ", collision.normal, " ricochet velocity: ", ricochet_velocity)
					
					HitResult.SHATTER:
						# Shell shatters on impact - minimal damage
						ship.health_controller.take_damage(armor_result.damage, collision.position)
						apply_fire_damage(p, ship, collision.position)
						destroyBulletRpc(id, collision.position, HitResult.SHATTER)
						print_armor_debug(armor_result, ship)
			else:
				# Hit something that's not a ship (water, terrain)
				destroyBulletRpc(id, collision.position)
				
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
func fireBullet(vel,pos, shell: ShellParams, t) -> int:
	#var bullet: Shell = preload("res://Shells/shell.tscn").instantiate()
	#bullet.params = shell_param_ids[shell]
	#bullet.radius = bullet.params.size
	print("params.fire_buildup ", shell.fire_buildup)
	print("type server ", shell.type)
	var id = self.ids_reuse.pop_back()
	if id == null:
		id = self.nextId
		self.nextId += 1
	
	if id >= projectiles.size():
		var np2 = next_pow_of_2(id + 1)
		self.projectiles.resize(np2)

	var expl: CSGSphere3D = preload("res://scenes/explosion.tscn").instantiate()
	expl.radius = shell.damage / 500
	get_tree().root.add_child(expl)
	expl.global_position = pos
		
	var bullet: ProjectileData = ProjectileData.new()
	bullet.initialize(pos, vel, t, shell)

	self.projectiles.set(id, bullet)
	
	return id

@rpc("any_peer", "reliable")
func fireBulletClient(pos, vel, t, id, shell: ShellParams) -> void:
	#var bullet: Shell = load("res://Shells/shell.tscn").instantiate()
	var bullet = ProjectileData.new()
	print("type client ", shell.type)

	if id * 16 >= transforms.size():
		var np2 = next_pow_of_2(id + 1)
		resize_multimesh_buffers(np2)
	
	var s = shell.size # sqrt(shell.damage / 100)
	var trans = Transform3D.IDENTITY.scaled(Vector3(s,s,s)).translated(pos)
	update_transform(id,trans)

	if shell.type == 1: # AP Shell
		set_color(id, Color(0.6, 0.6, 1.0, 1.0)) # Blue for AP shells
	else:
		set_color(id, Color(1.0, 0.8, 0.5, 1.0)) # Red for HE shells
		
	bullet.initialize(pos, vel, t, shell)
	self.projectiles.set(id, bullet)
	print("shell type: ", shell.type)

	var expl: CSGSphere3D = preload("res://scenes/explosion.tscn").instantiate()
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
	var radius = bullet.params.damage / 200
	self.projectiles.set(id, null)
	#self.projectiles.erase(id)
	var b = Basis()
	b.x = Vector3.ZERO
	b.y = Vector3.ZERO
	b.z = Vector3.ZERO
	var t = Transform3D(b,Vector3.ZERO)
	update_transform(id, t) # set to invisible
	#self.multi_mesh.multimesh.set_instance_transform(id, t)

	# Create appropriate visual effects based on hit result
	var expl: CSGSphere3D = preload("res://scenes/explosion.tscn").instantiate()
	get_tree().root.add_child(expl)
	expl.global_position = pos
	
	match hit_result:
		HitResult.PENETRATION:
			expl.radius = radius
			expl.material_override = null  # Default explosion
		HitResult.RICOCHET:
			expl.radius = radius * 0.3  # Smaller explosion for ricochet
			var ricochet_material = StandardMaterial3D.new()
			ricochet_material.albedo_color = Color.YELLOW
			expl.material_override = ricochet_material
		HitResult.OVERPENETRATION:
			expl.radius = radius * 0.6  # Medium explosion
			var overpen_material = StandardMaterial3D.new()
			overpen_material.albedo_color = Color.CYAN
			expl.material_override = overpen_material
		HitResult.SHATTER:
			expl.radius = radius * 0.2  # Very small explosion
			var shatter_material = StandardMaterial3D.new()
			shatter_material.albedo_color = Color.ORANGE
			expl.material_override = shatter_material
	
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
		var fires: Array[Fire] = []
		for i in range(4):
			if i == 0:
				var f = ship.get_node_or_null("Fire")
				if f:
					fires.append(f)
			else:
				var f = ship.get_node_or_null("Fire" + str(i + 1))
				if f:
					fires.append(f)
		var closest_fire: Fire = null
		var closest_fire_dist = 1000000000.0
		for f in fires:
			var dist = f.global_position.distance_squared_to(hit_position)
			if dist < closest_fire_dist:
				closest_fire_dist = dist
				closest_fire = f
		if closest_fire:
			closest_fire._apply_build_up(projectile.params.fire_buildup)

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
	
	print("%s vs %s: %s (%.0fmm pen vs %.0fmm armor at %.1f°) - %.0f damage" % [
		result_name, ship_class, result_name, 
		armor_result.penetration_power, armor_result.armor_thickness, 
		armor_result.impact_angle, armor_result.damage
	])

# Validation function for testing penetration formula
func validate_penetration_formula():
	print("=== Penetration Formula Validation ===")
	
	# Test 380mm BB shell (similar to historical 15" shells)
	var bb_shell = ShellParams.new()
	bb_shell.caliber = 380.0
	bb_shell.mass = 800.0  # Historical 380mm AP shell mass in kg
	bb_shell.type = 1  # AP
	bb_shell.penetration_modifier = 1.0
	
	var bb_penetration = calculate_penetration_power(bb_shell, 820.0, 0.0)
	print("380mm AP shell at 820 m/s, 0° impact: ", bb_penetration, "mm penetration")
	print("Expected: ~500-600mm for battleship shells")
	
	# Test 203mm CA shell (similar to 8" shells)  
	var ca_shell = ShellParams.new()
	ca_shell.caliber = 203.0
	ca_shell.mass = 118.0  # Historical 203mm AP shell mass in kg
	ca_shell.type = 1  # AP
	ca_shell.penetration_modifier = 1.0
	
	var ca_penetration = calculate_penetration_power(ca_shell, 760.0, 0.0)
	print("203mm AP shell at 760 m/s, 0° impact: ", ca_penetration, "mm penetration")
	print("Expected: ~200-300mm for cruiser shells")
	
	# Test 152mm secondary shell
	var sec_shell = ShellParams.new()
	sec_shell.caliber = 152.0
	sec_shell.mass = 45.3  # Historical 152mm AP shell mass in kg
	sec_shell.type = 1  # AP
	sec_shell.penetration_modifier = 1.0
	
	var sec_penetration = calculate_penetration_power(sec_shell, 900.0, 0.0)
	print("152mm AP shell at 900 m/s, 0° impact: ", sec_penetration, "mm penetration")
	print("Expected: ~150-200mm for secondary guns")
	
	# Test oblique impact (45 degrees)
	var oblique_penetration = calculate_penetration_power(bb_shell, 820.0, 45.0)
	print("380mm AP shell at 820 m/s, 45° impact: ", oblique_penetration, "mm penetration")
	print("Expected: ~70% of normal impact due to angle")
	
	print("=== End Validation ===")

@rpc("any_peer", "call_local", "reliable")
func createRicochetRpc(original_shell_id: int, new_shell_id: int, ricochet_position: Vector3, ricochet_velocity: Vector3, ricochet_time: float):
	# Find the original shell by ID
	# var original_projectile = null
	# for p in projectiles:
	# 	if p.id == original_shell_id:
	# 		original_projectile = p
	# 		break
	
	# if original_projectile == null:
	# 	print("Warning: Could not find original shell with ID ", original_shell_id, " for ricochet")
	# 	return
	
	# # Create ricochet shell with modified parameters based on original
	# var ricochet_params = ShellParams.new()
	# ricochet_params.speed = original_projectile.params.speed * 0.8  # Reduced speed after ricochet
	# ricochet_params.drag = original_projectile.params.drag
	# ricochet_params.damage = original_projectile.params.damage * 0.7  # Reduced damage after ricochet
	# ricochet_params.size = original_projectile.params.size  # Keep visual size
	# ricochet_params.caliber = original_projectile.params.caliber  # Keep caliber for physics
	# ricochet_params.mass = original_projectile.params.mass  # Keep mass for physics
	# ricochet_params.fire_buildup = 0  # No fire chance on ricochet
	# ricochet_params.type = original_projectile.params.type
	# ricochet_params.penetration_modifier = original_projectile.params.penetration_modifier * 0.8  # Reduced penetration after ricochet
	
	# # Create the ricochet projectile locally (this runs on both server and clients)
	# var ricochet_id = create_projectile_local(ricochet_velocity, ricochet_position, ricochet_params, ricochet_position + ricochet_velocity * 10.0, 5.0, ricochet_time)
	
	# print("Created ricochet shell with ID ", ricochet_id, " from original shell ", original_shell_id)
	var p = projectiles.get(original_shell_id)
	if p == null:
		print("Warning: Could not find original shell with ID ", original_shell_id, " for ricochet")
		return
	
	fireBulletClient(ricochet_position, ricochet_velocity, ricochet_time, new_shell_id, p.params)

# # Local projectile creation (no RPC, for use by createRicochetRpc)
# func create_projectile_local(launch_velocity: Vector3, position: Vector3, params: ShellParams, end_position: Vector3, flight_time: float, start_time: float) -> int:
# 	# Same logic as fireBullet but without RPC calls
# 	var new_bullet = ProjectileData.new()
# 	new_bullet.initialize(position, launch_velocity, start_time, end_position, flight_time, params)
	
# 	var new_id = nextId
# 	nextId += 1
# 	new_bullet.id = new_id
# 	projectiles.append(new_bullet)
	
# 	return new_id
