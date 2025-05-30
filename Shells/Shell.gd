class_name Shell
extends CSGSphere3D


#const shell_speed = 820.0
@export var params: ShellParams
@onready var trail: Trail
var id: int
var start_pos: Vector3
var end_pos: Vector3
var last_pos: Vector3
var launch_velocity: Vector3
var start_time: float
var total_time: float

# Internal variables
var velocity: Vector3 = Vector3.ZERO
var ray_query: PhysicsRayQueryParameters3D
static var particles: GPUParticles3D
#var space_state: PhysicsDirectSpaceState3D

# Signal emitted when projectile hits something
signal hit(collision_info)
signal destroyed()
	
func _ready():
	# Create persistent ray query
	ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	if !multiplayer.is_server():
		set_physics_process(false)
		if particles == null:
			particles = preload("res://Shells/trail.tscn").instantiate()
			get_tree().root.add_child(particles)
	else:
		set_process(false)
	
	
	# Get the physics space state for raycasting
	#space_state = get_world_3d().direct_space_state

func initialize(pos: Vector3, vel: Vector3, t: float, ep: Vector3, t2: float):
	global_position = pos
	start_pos = pos
	end_pos = ep
	last_pos = pos + vel.normalized() * 25
	total_time = t2
	self.start_time = t
	self.launch_velocity = vel
	ray_query.from = global_position
	ray_query.to = global_position
	
	#if !multiplayer.is_server():
		#trail = preload("res://scenes/Shells/trail.tscn").instantiate()
		#trail.set_process(false)
		#get_tree().root.add_child(trail)
		#trail.global_position = global_position
	
	
func _update_position():
	var t = (Time.get_unix_time_from_system() - start_time) * 2.0
	#var pos = global_position
	global_position = ProjectilePhysicsWithDrag.calculate_position_at_time(start_pos, launch_velocity, t, params.drag)
	
	if !multiplayer.is_server():
		var offset = global_position - last_pos
		if (global_position - start_pos).length_squared() < 25 * 25:
			return
		#if offset == Vector3.ZERO:
			#return
		var offset_length = offset.length()
		const step_size = 50
		var vel = offset.normalized()
		offset = vel * step_size
		var trans = Transform3D.IDENTITY.translated(last_pos)
		while offset_length > step_size:
			particles.emit_particle(trans, vel, Color.WHITE,Color.WHITE, 5)
			trans = trans.translated(offset)
			last_pos += offset
			offset_length -= step_size
		# particles.emit_particle(Transform3D.IDENTITY.translated(pos),Vector3.ZERO,Color.WHITE,Color.WHITE,1)
	#global_position = ProjectilePhysicsWithDrag.calculate_precise_shell_position(start_pos, end_pos, launch_velocity, t, total_time, params.drag)
	#if is_nan(global_position.x) or is_nan(global_position.y) or is_nan(global_position.z) or !global_position.is_finite():
		#global_position = Vector3.ZERO

func _physics_process(delta):
	#if !multiplayer.is_server():
		#return
		
	_update_position()

	#if multiplayer.is_server():
	_check_collisions()
	

		
func _process(delta: float) -> void:
	#if multiplayer.is_server():
		#return
	# # Move the projectile

	_update_position()
	#trail.global_position = global_position
	
	
	## Update the rotation to face movement direction
	#if velocity.length_squared() > 0.01:
		#look_at(global_position + velocity.normalized(), Vector3.UP)


func _check_collisions():
	# Set up raycast between previous and current position
	ray_query.from = ray_query.to
	ray_query.to = global_position
	
	# Perform the raycast
	var collision: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray_query)
	
	if not collision.is_empty():
		#print("hit", collision)
		# Position the projectile at the collision point
		global_position = collision.position

		# Emit hit signal with collision information
		#emit_signal("hit", collision)
		
		# Destroy the projectile with a delay
		#_destroy(true)
		#ProjectileManager.destroyBulletRpc(id)
		
		#ProjectileManager.destroyBulletRpc2(id)

func _destroy():
	emit_signal("destroyed")
	
	set_process(false)
	set_physics_process(false)
	
	#var trail = get_child(0)
	#remove_child(trail)
	#var n = Node3D.new()
	#
	#get_tree().root.add_child(n)
	#n.global_position = global_position
	#n.add_child(trail)
	#trail.top_level = true  # Ensure transform independence
	#trail.global_position = global_position  # Fix typo in 'global_postion'
	
	## Ensure trail isn't culled
	#if trail is VisualInstance3D:
		#trail.visibility_range_end = 10000.0  # Large value to prevent distance culling
		#trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # Disable shadow casting to improve performance
	
	# material_override = null
	#var timer = Timer.new()
	##timer.one_shot = true
	#timer.wait_time = 2.0
	#timer.autostart = true
	#timer.timeout.connect(func(): trail.queue_free())
	#trail.add_child(timer)
	#timer.start()
	#get_tree().create_timer(2.0).timeout.connect(func(): trail.queue_free())
	if trail != null:
		trail.timeout = Time.get_ticks_msec() + 2000
		trail.set_process(true)
	
	var expl: CSGSphere3D = preload("res://scenes/explosion.tscn").instantiate()
	var s = self.params.damage / 500
	expl.scale = Vector3(s, s, s)
	get_tree().root.add_child(expl)
	expl.global_position = global_position

	queue_free()
