extends Node3D

var nextId: int = 0;
var projectiles: Array[ProjectileData] = [];
var ids_reuse: Array[int] = []
var shell_param_ids: Dictionary[int, ShellParams] = {}
var bulletId: int = 0
var shell_resource_path = "res://Shells/"
@onready var particles: GPUParticles3D
@onready var multi_mesh: MultiMeshInstance3D
var ray_query = PhysicsRayQueryParameters3D.new()

var transforms = PackedFloat32Array()


signal resource_registered(id: int, resource: ShellParams)

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
		
	func initialize( pos: Vector3, vel: Vector3, t: float, ep: Vector3, t2: float, p: ShellParams):
		self.position = pos
		self.start_position = pos
		#end_pos = ep
		trail_pos = pos + vel.normalized() * 25
		#total_time = t2
		self.params = p
		self.start_time = t
		self.launch_velocity = vel
		#ray_query.from = global_position
		#ray_query.to = global_position

#var active_projectiles: Array[ProjectileData] = []

func _ready():
	# Auto-register all bullet resources in the directory
	register_all_bullet_resources()
	particles = get_node("/root/ProjectileManager1/GPUParticles3D")
	multi_mesh = get_node("/root/ProjectileManager1/MultiMeshInstance3D")
	if OS.get_cmdline_args().find("--server") != -1:
		print("running server")
		set_process(false)
		ray_query.collide_with_areas = true
		ray_query.collide_with_bodies = true
	else:
		set_physics_process(false)
		transforms.resize(12)
		projectiles.resize(1)
	
func register_all_bullet_resources() -> void:
	var dir = DirAccess.open(shell_resource_path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".tres"):
				var bullet_res = load(shell_resource_path + file_name)
				if bullet_res is ShellParams:
					register_bullet_resource(bullet_res)
			file_name = dir.get_next()
	else:
		push_error("Could not access bullet resources directory")


# Register a bullet resource and assign it an ID
func register_bullet_resource(bullet_params: ShellParams) -> int:
	## If this resource is already registered, return its ID
	#for id in shell_param_ids.keys():
		#if shell_param_ids[id] == bullet_params:
			#return id
	
	# Assign a new ID
	var assigned_id = bulletId
	bullet_params.id = assigned_id
	shell_param_ids[assigned_id] = bullet_params
	bulletId += 1
	
	emit_signal("resource_registered", assigned_id, bullet_params)
	return assigned_id

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

func _process(_delta: float) -> void:
	var current_time = Time.get_unix_time_from_system()
	
	var id = 0
	for p in self.projectiles:
		if p == null:
			id += 1
			continue
			
		var t = current_time - p.start_time
		p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		update_transform_pos(id, p.position)
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
			particles.emit_particle(trans, vel, Color.WHITE,Color.WHITE, 5)
			trans = trans.translated(offset)
			p.trail_pos += offset
			offset_length -= step_size
		
	self.multi_mesh.multimesh.instance_count = transforms.size() / 12
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
		var t = current_time - p.start_time
		ray_query.from = p.position
		p.position = ProjectilePhysicsWithDrag.calculate_position_at_time(p.start_position, p.launch_velocity, t, p.params.drag)
		ray_query.to = p.position
		
		# Perform the raycast
		var collision: Dictionary = space_state.intersect_ray(ray_query)
		
		if not collision.is_empty():
			#global_position = collision.position
			self.destroyBulletRpc(id, collision.position)
		id += 1
		
		
func update_transform(idx, trans):
	# Fill buffer at correct position
	var offset = idx * 12
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
		
@rpc("any_peer", "reliable")
func fireBulletClient(pos, vel, t, id, shell: int, end_pos, total_time) -> void:
	#var bullet: Shell = load("res://Shells/shell.tscn").instantiate()
	var bullet = ProjectileData.new()
	#bullet.params = shell_param_ids[shell]
	#bullet.id = id
	#bullet.radius = bullet.params.size
	if id >= transforms.size() / 12:
		var np2 = next_pow_of_2(id + 1)
		transforms.resize(np2 * 12)
		self.projectiles.resize(np2)
	
	var s = sqrt(shell_param_ids[shell].damage / 100)
	var trans = Transform3D.IDENTITY.scaled(Vector3(s,s,s)).translated(pos)
	update_transform(id,trans)
	
	bullet.initialize(pos, vel, t, end_pos, total_time, shell_param_ids[shell])
	self.projectiles.set(id, bullet)

	var expl: CSGSphere3D = preload("res://scenes/explosion.tscn").instantiate()
	expl.radius = shell_param_ids[shell].damage / 500
	get_tree().root.add_child(expl)
	expl.global_position = pos
	#var shell = bullet.get_script()
	#pass
	
func request_fire(dir: Vector3, pos: Vector3, shell: int, end_pos: Vector3, total_time: float) -> void:
		fireBullet(dir,pos, shell, end_pos, total_time)

#@rpc("authority","reliable")
func fireBullet(vel,pos, shell: int, end_pos, total_time) -> void:
	#var bullet: Shell = preload("res://Shells/shell.tscn").instantiate()
	#bullet.params = shell_param_ids[shell]
	#bullet.radius = bullet.params.size
	var id = self.ids_reuse.pop_back()
	if id == null:
		id = self.nextId
		self.nextId += 1
	var t = float(Time.get_unix_time_from_system())
	
	if id >= projectiles.size():
		var np2 = next_pow_of_2(id + 1)
		self.projectiles.resize(np2)

	var expl: CSGSphere3D = preload("res://scenes/explosion.tscn").instantiate()
	expl.radius = shell_param_ids[shell].damage / 500
	get_tree().root.add_child(expl)
	expl.global_position = pos
		
	var bullet: ProjectileData = ProjectileData.new()
	bullet.initialize(pos, vel, t, end_pos, total_time, shell_param_ids[shell])
	self.projectiles.set(id, bullet)
	for p in multiplayer.get_peers():
		self.fireBulletClient.rpc_id(p, pos, vel, t, id, shell, end_pos, total_time)
	

@rpc("call_remote", "reliable")
func destroyBulletRpc2(id, pos: Vector3) -> void:
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

	var expl: CSGSphere3D = preload("res://scenes/explosion.tscn").instantiate()
	get_tree().root.add_child(expl)
	expl.global_position = pos
	expl.radius = radius
	
@rpc("authority", "reliable")
func destroyBulletRpc(id, position) -> void:
	# var bullet: ProjectileData = self.projectiles.get(id)
	self.projectiles.set(id, null)
	#self.projectiles.erase(id)
	self.ids_reuse.append(id)
	for p in multiplayer.get_peers():
		self.destroyBulletRpc2.rpc_id(p,id, position)
