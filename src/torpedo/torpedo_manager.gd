extends Node
class_name _TorpedoManager
var nextId: int = 0;
var torpedos: Array[TorpedoData] = [];
var ids_reuse: Array[int] = []
var bulletId: int = 0
#var shell_resource_path = "res://Shells/"
# @onready var particles: GPUParticles3D
@onready var multi_mesh: MultiMeshInstance3D
var ray_query = PhysicsRayQueryParameters3D.new()
const TORPEDO_SPEED_MULTIPLIER = 3.0
var transforms = PackedFloat32Array()
var camera: Camera3D = null

# Wake particle system
@export var wake_template: ParticleTemplate


# Torpedo indicators UI
var _torpedo_indicators: Control = null

var server: GameServer = null

class TorpedoData:
	var position: Vector3
	var start_position: Vector3
	var direction: Vector3
	var _range: float
	var t: float
	var params: TorpedoParams
	var owner: Ship
	var visible_to_enemy: bool = false
	var emitter_id: int = -1  # GPU wake particle emitter ID
	var launcher: TorpedoLauncher
	var armed: bool = false

	func initialize(pos: Vector3, dir: Vector3, _params: TorpedoParams, _t: float, _owner: Ship, __range: float, tl: TorpedoLauncher, _armed: bool = false) -> void:
		self.position = pos
		self.start_position = pos
		self.direction = dir.normalized()
		self.t = _t
		self.params = _params
		self.owner = _owner
		self._range = __range
		self.emitter_id = -1
		self.launcher = tl
		self.armed = _armed


func _ready():
	# Auto-register all bullet resources in the directory
	#register_all_bullet_resources()
	#particles = $GPUParticles3D
	multi_mesh = $MultiMeshInstance3D
	if OS.get_cmdline_args().find("--server") != -1:
		print("running server")
		set_process(false)
		ray_query.collide_with_areas = true
		ray_query.collide_with_bodies = true
		ray_query.collision_mask = 1 | (1 << 1)

		(func():
			# Wait for server node to be ready
			while get_tree().root.get_node_or_null("/root/Server") == null:
				await get_tree().process_frame
			server = get_tree().root.get_node("/root/Server") as GameServer
		).call_deferred()
	else:
		set_physics_process(false)
		transforms.resize(12)
		torpedos.resize(1)
		# Initialize torpedo indicators overlay
		_setup_torpedo_indicators()


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
	# Create a PackedFloat32Array with 12 elements (3x4 matrix)
	var array = PackedFloat32Array()
	array.resize(12)

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
	var offset = idx * 12
	transforms[offset + 3] = pos.x
	transforms[offset + 7] = pos.y
	transforms[offset + 11] = pos.z

func update_transform_scale(idx, scale: float):
	# Calculate offset in the transforms array for this instance
	var offset = idx * 12

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

func _setup_torpedo_indicators() -> void:
	var canvas_layer = CanvasLayer.new()
	canvas_layer.name = "TorpedoIndicatorLayer"
	canvas_layer.layer = 100
	add_child(canvas_layer)

	var indicators = preload("res://src/torpedo/torpedo_indicators.gd").new()
	indicators.name = "TorpedoIndicators"
	indicators.torpedo_manager = self
	canvas_layer.add_child(indicators)
	_torpedo_indicators = indicators

func _process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()

	if camera == null:
		return
	# var distance_factor = 0.0003 * deg_to_rad(camera.fov) # How much to compensate for distance
	var id = 0

	for p in self.torpedos:
		if p == null:
			id += 1
			continue

		var t = (current_time - p.t) * TORPEDO_SPEED_MULTIPLIER
		#p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		#var prev_pos = p.position
		p.position = p.direction * p.params.speed * t + p.start_position
		p.position.y = max(p.position.y - t * 10, 0.1)
		update_transform_pos(id, p.position)

		# # Client-side arming check (mirrors server _physics_process logic)
		# if not p.armed:
		# 	if p.start_position.distance_to(p.position) > p.params.arming_distance:
		# 		p.armed = true

		## Calculate distance-based scale to counter perspective shrinking
		#var distance = camera.global_position.distance_to(p.position)
		#var base_scale = p.params.size # Normal scale at close range
		#var max_scale_factor = INF # Cap the maximum scale increase
		#var scale_factor = min(base_scale * (1 + distance * distance_factor), max_scale_factor)
		#update_transform_scale(id, scale_factor)

		# Update wake particle emitter position
		if p.emitter_id >= 0:
			ParticleTemplate.update_emitter_position(p.emitter_id, p.position)

		id += 1
		#var offset = p.position - p.trail_pos
		#if (p.position - p.start_position).length_squared() < 80:
			#continue
		#var offset_length = offset.length()
		const step_size = 20
		#var vel = offset.normalized()
		#offset = vel * step_size

		var trans = Transform3D.IDENTITY.translated(p.position)
		#while :
		# particles.emit_particle(trans, (p.position - prev_pos).normalized() , Color.WHITE,Color.WHITE, 5)
		#trans = trans.translated(p.position)
		#p.trail_pos += offset
		#offset_length -= step_size

	self.multi_mesh.multimesh.instance_count = int(transforms.size() / 12.0)
	self.multi_mesh.multimesh.visible_instance_count = self.multi_mesh.multimesh.instance_count
	self.multi_mesh.multimesh.buffer = transforms

	# Update torpedo indicators
	if _torpedo_indicators:
		_torpedo_indicators.queue_redraw()


func _physics_process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var id = 0
	var collision: Dictionary = {}
	if server == null:
		return
	for p in self.torpedos:
		if p == null:
			id += 1
			continue
		var t = (current_time - p.t) * TORPEDO_SPEED_MULTIPLIER
		ray_query.from = p.position
		#p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		p.position = p.direction * p.params.speed * t + p.start_position
		p.position.y = max(p.position.y - t * 10, 0.1)
		if !p.armed:
			if p.start_position.distance_to(p.position) > p.params.arming_distance:
				p.armed = true
				notify_armed(id)

		if !p.visible_to_enemy:
			if server != null:
				var enemy_ships = server.get_team_ships(0 if p.owner.team.team_id == 1 else 1)
				for ship in enemy_ships:
					if p.position.distance_squared_to(ship.global_position) < p.params.detection_range * p.params.detection_range: # Visibility range
						p.visible_to_enemy = true
						for player in server._get_team_ships(0 if p.owner.team.team_id == 1 else 1):
							if not player.team.is_bot:
								p.launcher.fire_client.rpc_id(player.peer_id, p.position, p.direction, current_time, id, p.armed)
						if p.armed:
							notify_armed(id) # Update indicators for enemy teams
						break

		if p.position.distance_to(p.start_position) > p._range:
			# Out of range
			self.destroyTorpedo(id, p.position)
			id += 1
			continue

		ray_query.to = p.position

		# Perform the raycast
		collision = space_state.intersect_ray(ray_query)

		if not collision.is_empty():
			#global_position = collision.position
			var ship = null
			var armor_part = null
			if collision.has("collider"):
				armor_part = collision.collider
				if armor_part is ArmorPart:
					ship = armor_part.ship

			if ship != null:
				if ship == p.owner:
					# Ignore self-hit
					id += 1
					continue
				var hp: HPManager = ship.health_controller
				if hp.is_alive() and ship.team.team_id != p.owner.team.team_id and p.armed:
					var damage = p.params.damage
					if armor_part is ArmorPart:
						if armor_part.type == ArmorPart.Type.CASEMATE or armor_part.type == ArmorPart.Type.CITADEL:
							damage *= (1.0 - hp.params.p().torpedo_protection)
							armor_part = ship.citadel
					var dmg_sunk = hp.apply_damage(damage, p.params.damage, armor_part, true, 1)

					if dmg_sunk[1]:
						# Ship sunk
						if p.owner:
							p.owner.stats.frags += 1
					# Track torpedo damage dealt
					track_torpedo_damage_dealt(p.owner, dmg_sunk[0], collision.position)
					# Apply flooding damage
					apply_flood_damage(p, ship, collision.position)
			self.destroyTorpedo(id, collision.position)
		id += 1


func notify_armed(id: int):
	var torpedo: TorpedoData = self.torpedos[id]
	var friendly_ships = server.get_team_ships(torpedo.owner.team.team_id)
	for f in friendly_ships:
		if !f.team.is_bot:
			arm_torp.rpc_id(f.peer_id, id)
	if torpedo.visible_to_enemy:
		var enemy_ships = server.get_team_ships(0 if torpedo.owner.team.team_id == 1 else 1)
		for e in enemy_ships:
			if !e.team.is_bot:
				arm_torp.rpc_id(e.peer_id, id)


@rpc("call_remote", "reliable", "authority")
func arm_torp(id: int):
	if id < 0 or id >= self.torpedos.size():
		return
	if torpedos[id] != null:
		torpedos[id].armed = true

func update_transform(idx, trans):
	# Fill buffer at correct position
	var offset = idx * 12
	# Basis (3x3 rotation/scale matrix)
	transforms[offset + 0] = trans.basis.x.x
	transforms[offset + 1] = trans.basis.y.x
	transforms[offset + 2] = trans.basis.z.x
	transforms[offset + 3] = trans.origin.x
	transforms[offset + 4] = trans.basis.x.y
	transforms[offset + 5] = trans.basis.y.y
	transforms[offset + 6] = trans.basis.z.y
	transforms[offset + 7] = trans.origin.y
	transforms[offset + 8] = trans.basis.x.z
	transforms[offset + 9] = trans.basis.y.z
	transforms[offset + 10] = trans.basis.z.z
	transforms[offset + 11] = trans.origin.z

@rpc("any_peer", "reliable")
func fireTorpedoClient(pos, vel, t, id, params: TorpedoParams, _owner: Ship, launcher: TorpedoLauncher, armed: bool) -> void:
	#var bullet: Shell = load("res://Shells/shell.tscn").instantiate()
	var torp = TorpedoData.new()
	#bullet.params = shell_param_ids[shells]
	#bullet.id = id
	#bullet.radius = bullet.params.size
	if id >= transforms.size() / 12:
		var np2 = next_pow_of_2(id + 1)
		transforms.resize(np2 * 12)
		self.torpedos.resize(np2)

	#var s = shell.size # sqrt(shell.damage / 100)
	var vel_norm = vel.normalized()
	# Create basis with Y axis aligned to velocity
	# Use a fallback "up" vector when direction is nearly parallel to Vector3.RIGHT
	var basis = Basis()
	basis.y = vel_norm
	var cross_result = basis.y.cross(Vector3.RIGHT)
	# If cross product is too small (direction nearly parallel to RIGHT), use UP instead
	if cross_result.length_squared() < 0.001:
		cross_result = basis.y.cross(Vector3.UP)
	basis.z = cross_result.normalized()
	basis.x = basis.y.cross(basis.z).normalized()
	#basis.y = vel_norm

	var trans = Transform3D(basis, pos)
	update_transform(id, trans)

	torp.initialize(pos, vel, params, t, _owner, 0.0, launcher, armed)

	# Allocate wake particle emitter
	if wake_template != null:
		torp.emitter_id = wake_template.allocate_emitter(pos, 1.0, 0.2, 1.0, 0.0)

	if self.torpedos.get(id) != null:
		push_error("Torpedo ID already exists")
	self.torpedos.set(id, torp)

#@rpc("authority","reliable")
func fireTorpedo(vel,pos, params: TorpedoParams, t, _owner: Ship, _range: float, launcher: TorpedoLauncher) -> int:
	var id = self.ids_reuse.pop_back()
	if id == null:
		id = self.nextId
		self.nextId += 1

	if id >= torpedos.size():
		var np2 = next_pow_of_2(id + 1)
		self.torpedos.resize(np2)

	var torp: TorpedoData = TorpedoData.new()
	torp.initialize(pos, vel, params, t, _owner, _range, launcher)
	self.torpedos.set(id, torp)
	return id
	#for p in multiplayer.get_peers():
		#self.fireBulletClient.rpc_id(p, pos, vel, t, id, shell, end_pos, total_time)


func _clear_torpedo_transform(idx: int) -> void:
	"""Helper to clear a torpedo's transform to make it invisible."""
	if idx >= 0 and idx < transforms.size() / 12:
		var zero_basis = Basis()
		zero_basis.x = Vector3.ZERO
		zero_basis.y = Vector3.ZERO
		zero_basis.z = Vector3.ZERO
		var zero_transform = Transform3D(zero_basis, Vector3.ZERO)
		update_transform(idx, zero_transform)
		self.multi_mesh.multimesh.set_instance_transform(idx, zero_transform)

@rpc("call_remote", "reliable")
func destroyTorpedo_c(id, pos: Vector3) -> void:
	# Check array bounds first to handle race conditions where destroy arrives before fire
	if id < 0 or id >= self.torpedos.size():
		# Destroy arrived before fire RPC - this can happen due to different RPC channels
		# Just clear the transform in case it was partially set up
		_clear_torpedo_transform(id)
		return

	var torp: TorpedoData = self.torpedos.get(id)
	if torp == null:
		# Torpedo already destroyed or never created - clear transform just in case
		_clear_torpedo_transform(id)
		return

	var radius = torp.params.damage * 8 / 20000.0

	# Free wake particle emitter
	if torp.emitter_id >= 0:
		ParticleTemplate.free_emitter(torp.emitter_id)
		torp.emitter_id = -1

	HitEffects.he_explosion_effect(pos, radius, Vector3.UP)
	HitEffects.sparks_effect(pos, radius, Vector3.UP)
	HitEffects.splash_effect(pos, radius)

	self.torpedos.set(id, null)
	_clear_torpedo_transform(id)

	#var expl: CSGSphere3D = preload("uid://bg8ewplv43885").instantiate()
	#get_tree().root.add_child(expl)
	#expl.global_position = pos
	#expl.radius = radius

#@rpc("authority", "reliable")
func destroyTorpedo(id, position) -> void:
	# var bullet: ProjectileData = self.projectiles.get(id)

	self.torpedos.set(id, null)
	#self.projectiles.erase(id)
	self.ids_reuse.append(id)
	destroyTorpedo_c.rpc(id, position)

func track_torpedo_damage_dealt(owner_ship: Ship, damage: float, position: Vector3):
	"""Track torpedo damage dealt using the ship's stats module"""
	if not owner_ship or not is_instance_valid(owner_ship):
		return

	# Add damage to the ship's stats module
	if owner_ship.stats:
		owner_ship.stats.torpedo_count += 1
		owner_ship.stats.torpedo_damage += damage
		owner_ship.stats.total_damage += damage
		owner_ship.stats.damage_events.append({
			"type": "torp",
			"damage": damage,
			"position": position
		})

func apply_flood_damage(torpedo: TorpedoData, ship: Ship, hit_position: Vector3) -> void:
	"""Apply flooding buildup to the ship when hit by a torpedo"""
	if torpedo == null or ship == null:
		return

	var flood_buildup: float = torpedo.params.flood_buildup
	if flood_buildup <= 0:
		return

	# Get flood manager from ship
	var flood_manager = ship.flood_manager
	if flood_manager == null:
		return

	# Find closest flood point
	var floods = flood_manager.floods
	var closest_flood: Flood = null
	var closest_flood_dist: float = 1e9

	for f in floods:
		if f == null:
			continue
		var flood_pos: Vector3 = f.global_position
		var dist: float = flood_pos.distance_squared_to(hit_position)
		if dist < closest_flood_dist:
			closest_flood_dist = dist
			closest_flood = f

	if closest_flood != null:
		closest_flood._apply_build_up(flood_buildup, torpedo.owner)
