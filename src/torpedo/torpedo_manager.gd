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

class TorpedoData:
	var position: Vector3
	var start_position: Vector3
	var direction: Vector3
	var _range: float
	var t: float
	var params: TorpedoParams
	var owner: Ship

	func initialize(pos: Vector3, dir: Vector3, _params: TorpedoParams, _t: float, _owner: Ship, __range: float):
		self.position = pos
		self.start_position = pos
		self.direction = dir.normalized()
		self.t = _t
		self.params = _params
		self.owner = _owner
		self._range = __range


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
	else:
		set_physics_process(false)
		transforms.resize(12)
		torpedos.resize(1)

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
		if p.position.y > 0.01:
			p.position.y = max(p.position.y - t * 10, 0.01)
		update_transform_pos(id, p.position)

		## Calculate distance-based scale to counter perspective shrinking
		#var distance = camera.global_position.distance_to(p.position)
		#var base_scale = p.params.size # Normal scale at close range
		#var max_scale_factor = INF # Cap the maximum scale increase
		#var scale_factor = min(base_scale * (1 + distance * distance_factor), max_scale_factor)
		#update_transform_scale(id, scale_factor)

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


func _physics_process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var id = 0
	var collision: Dictionary = {}
	for p in self.torpedos:
		if p == null:
			id += 1
			continue
		var t = (current_time - p.t) * TORPEDO_SPEED_MULTIPLIER
		ray_query.from = p.position
		#p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		p.position = p.direction * p.params.speed * t + p.start_position
		if p.position.y > 0.01:
			p.position.y = max(p.position.y - t * 10, 0.01)

		if p.position.distance_to(p.start_position) > p._range:
			# Out of range
			self.destroyTorpedoRpc(id, p.position)
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
				if hp.is_alive():
					var dmg_sunk = hp.apply_damage(p.params.damage, p.params.damage, armor_part, true, 1)
					if dmg_sunk[1]:
						# Ship sunk
						if p.owner:
							p.owner.stats.frags += 1
					# Track torpedo damage dealt
					track_torpedo_damage_dealt(p.owner, dmg_sunk[0])
				self.destroyTorpedoRpc(id, collision.position)
		id += 1


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
func fireTorpedoClient(pos, vel, t, id, params: TorpedoParams, owner: Ship) -> void:
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
	var basis = Basis()
	basis.y = vel_norm
	basis.z = basis.y.cross(Vector3.RIGHT).normalized()
	basis.x = basis.y.cross(basis.z).normalized()
	#basis.y = vel_norm

	var trans = Transform3D(basis, pos)
	update_transform(id, trans)

	torp.initialize(pos, vel, params, t, owner, 0.0)
	self.torpedos.set(id, torp)

#@rpc("authority","reliable")
func fireTorpedo(vel,pos, params: TorpedoParams, t, owner: Ship, _range: float) -> int:
	var id = self.ids_reuse.pop_back()
	if id == null:
		id = self.nextId
		self.nextId += 1

	if id >= torpedos.size():
		var np2 = next_pow_of_2(id + 1)
		self.torpedos.resize(np2)

	var torp: TorpedoData = TorpedoData.new()
	torp.initialize(pos, vel, params, t, owner, _range)
	self.torpedos.set(id, torp)
	return id
	#for p in multiplayer.get_peers():
		#self.fireBulletClient.rpc_id(p, pos, vel, t, id, shell, end_pos, total_time)


@rpc("call_remote", "reliable")
func destroyTorpedoRpc2(id, pos: Vector3) -> void:
	var torp: TorpedoData = self.torpedos.get(id)
	if torp == null:
		print("bullet is null: ", id)
		return
	var radius = torp.params.damage * 8 / 20000.0


	HitEffects.he_explosion_effect(pos, radius, Vector3.UP)
	HitEffects.sparks_effect(pos, radius, Vector3.UP)
	HitEffects.splash_effect(pos, radius)

	self.torpedos.set(id, null)
	#self.projectiles.erase(id)
	var b = Basis()
	b.x = Vector3.ZERO
	b.y = Vector3.ZERO
	b.z = Vector3.ZERO
	var t = Transform3D(b,Vector3.ZERO)
	update_transform(id, t) # set to invisible
	self.multi_mesh.multimesh.set_instance_transform(id, t)

	#var expl: CSGSphere3D = preload("uid://bg8ewplv43885").instantiate()
	#get_tree().root.add_child(expl)
	#expl.global_position = pos
	#expl.radius = radius

#@rpc("authority", "reliable")
func destroyTorpedoRpc(id, position) -> void:
	# var bullet: ProjectileData = self.projectiles.get(id)

	self.torpedos.set(id, null)
	#self.projectiles.erase(id)
	self.ids_reuse.append(id)
	destroyTorpedoRpc2.rpc(id, position)

func track_torpedo_damage_dealt(owner_ship: Ship, damage: float):
	"""Track torpedo damage dealt using the ship's stats module"""
	if not owner_ship or not is_instance_valid(owner_ship):
		return

	# Add damage to the ship's stats module
	if owner_ship.stats:
		owner_ship.stats.total_damage += damage
