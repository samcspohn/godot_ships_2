class_name Shell
extends Node3D


const shell_speed = 820.0
var id: int
# Projectile properties
@export var initial_velocity: float = 10.0
var start_pos: Vector3
var launch_velocity: Vector3
var start_time: float



# Internal variables
var velocity: Vector3 = Vector3.ZERO
var ray_query: PhysicsRayQueryParameters3D
#var space_state: PhysicsDirectSpaceState3D

# Signal emitted when projectile hits something
signal hit(collision_info)
signal destroyed()
	
func _ready():
	# Create persistent ray query
	ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	
	# Get the physics space state for raycasting
	#space_state = get_world_3d().direct_space_state

func initialize(pos: Vector3, vel: Vector3, t: float):
	global_position = pos
	start_pos = pos
	self.start_time = t
	self.launch_velocity = vel
	ray_query.from = global_position
	ray_query.to = global_position
	
	
func _update_position():
	var t = (Time.get_unix_time_from_system() - start_time) * 2.0
	global_position = ProjectilePhysicsWithDrag.calculate_position_at_time(start_pos, launch_velocity, t)
	
func _physics_process(delta):
	if !multiplayer.is_server():
		return
		
	_check_collisions()
	
	# Store current position for raycast start
	# # Move the projectile
	_update_position()

		
func _process(delta: float) -> void:
	if multiplayer.is_server():
		return
	# # Move the projectile

	_update_position()
	
	# Update the rotation to face movement direction
	if velocity.length_squared() > 0.01:
		look_at(global_position + velocity.normalized(), Vector3.UP)


func _check_collisions():
	# Set up raycast between previous and current position
	ray_query.from = ray_query.to
	ray_query.to = global_position
	
	# Perform the raycast
	var collision: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray_query)
	
	if not collision.is_empty():
		print("hit", collision)
		# Position the projectile at the collision point
		global_position = collision.position
		
		# Stop physics processing
		#set_physics_process(false)
		
		# Emit hit signal with collision information
		emit_signal("hit", collision)
		
		# Destroy the projectile with a delay
		#_destroy(true)
		ProjectileManager.destroyBulletRpc(id)
		
		#ProjectileManager.destroyBulletRpc2(id)

func _destroy(with_delay: bool = true):
	emit_signal("destroyed")
	
	#if with_delay:
	set_process(false)
	set_physics_process(false)
	scale = Vector3(0.0001,0.0001,0.0001)
	var timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = 4.0
	timer.timeout.connect(func(): queue_free())
	add_child(timer)
	timer.start()
	
	#var timer2 = Timer.new()
	#timer2.one_shot = true
	#timer2.wait_time = 0.001
	#timer2.timeout.connect(func():
		#set_process(false)
		#)
	#add_child(timer2)
	#timer2.start()
	
	var expl = preload("res://scenes/explosion.tscn").instantiate()
	get_tree().root.add_child(expl)
	expl.global_position = global_position
	#queue_free()
	#else:
		## Immediate destruction
		#queue_free()
#var vel: Vector3 = Vector3(0,0,0)
#var id: int
#const shell_speed = 10
##var init = false
###var prev_pos: Vector3
#var query: PhysicsRayQueryParameters3D
## Called when the node enters the scene tree for the first time.
#func _ready() -> void:
	##prev_pos = position
	#query = PhysicsRayQueryParameters3D.create(position, position)
	#query.collide_with_areas = true
	#self.position += self.vel * 0.01
	##var p = ParticleProcessMaterial.new()
	##var p: ParticleProcessMaterial = $GPUParticles3D.process_material
	##p.direction = vel
	##p.initial_velocity_min = vel.length()
	##$GPUParticles3D.process_material = p
	#
#
#
## Called every frame. 'delta' is the elapsed time since the previous frame.
#func _physics_process(delta: float) -> void:
	#self.position += delta * self.vel
	#self.vel += Vector3(0,-.981,0) * delta
	#if multiplayer.is_server():
		##if position.y < 0:
		##var query = PhysicsRayQueryParameters3D.create(prev_pos, position)
		#query.from = query.to
		#query.to = position
		#if not init:
			#init = true
		#else:
			#var a = get_world_3d().direct_space_state.intersect_ray(query)
			#if not a.is_empty():
				#ProjectileManager.destroyBulletRpc(self.id)
	#elif not init:
		#init = true
		##$GPUParticles3D.emitting = true
