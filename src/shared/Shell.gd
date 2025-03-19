class_name Shell
extends Node3D


const shell_speed = 10.0
var id: int
# Projectile properties
@export var initial_velocity: float = 10.0
static var gravity: float = .98
static var drag_factor: float = 0.05
static var mass: float = 50.0
@export var damage: float = 10.0
@export var lifetime: float = 10.0  # Maximum lifetime in seconds
var start_pos: Vector3
var launch_velocity: Vector3
var start_time: float



# Internal variables
var velocity: Vector3 = Vector3.ZERO
var time_alive: float = 0.0
var previous_position: Vector3
var ray_query: PhysicsRayQueryParameters3D
var space_state: PhysicsDirectSpaceState3D

# Signal emitted when projectile hits something
signal hit(collision_info)
signal destroyed()
	
func _ready():
	previous_position = global_position
	
	# Create persistent ray query
	ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	
	# Get the physics space state for raycasting
	space_state = get_world_3d().direct_space_state

func initialize(pos: Vector3, vel: Vector3, t: float):
	global_position = pos
	start_pos = pos
	self.start_time = t
	self.launch_velocity = vel
	previous_position = global_position

	
func _physics_process(delta):
	#time_alive += delta
	#
	## Destroy if lifetime exceeded
	#if time_alive > lifetime:
		#_destroy()
		#return
	
	# Store current position for raycast start
	previous_position = global_position
	
	# Apply forces (gravity and air resistance)
	# _apply_forces(delta)
	
	# # Move the projectile
	# global_position += velocity * delta
	var t = Time.get_ticks_msec() / 1000.0 - start_time
	# global_position = AnalyticalProjectileSystem.calculate_position_gravity_only(start_pos, launch_velocity, t)
	global_position = ProjectilePhysicsWithDrag.calculate_position_at_time(start_pos, launch_velocity, t)

	
	# Check for collisions
	_check_collisions()
	# if global_position.y < 0:
	# 	_destroy()
	
	# Update the rotation to face movement direction
	if velocity.length_squared() > 0.01:
		look_at(global_position + velocity.normalized(), Vector3.UP)

func _apply_forces(delta):
	# Apply gravity
	velocity.y -= gravity * delta
	
	# Apply air resistance (drag force = drag_factor * velocity^2)
	var speed = velocity.length()
	if speed > 0:
		var drag_force = velocity.normalized() * drag_factor * speed * speed / mass
		velocity -= drag_force * delta

func _check_collisions():
	# Set up raycast between previous and current position
	ray_query.from = previous_position
	ray_query.to = global_position
	
	# Perform the raycast
	var collision = space_state.intersect_ray(ray_query)
	
	if not collision.is_empty():
		# Position the projectile at the collision point
		global_position = collision.position
		
		# Stop physics processing
		set_physics_process(false)
		
		# Emit hit signal with collision information
		emit_signal("hit", collision)
		
		# Destroy the projectile with a delay
		_destroy(true)

func _destroy(with_delay: bool = false):
	emit_signal("destroyed")
	
	if with_delay:
		# Optionally make the projectile invisible or switch to impact effect
		# For example:
		# visible = false
		# $ImpactEffect.visible = true
		#var expl = Node3D.new()
		#get_tree().root.add_child(expl)
		#var emitter = get_child(0)
		#remove_child(emitter)
		#expl.add_child(emitter)
		#expl.visible = true
		#expl.global_position = global_position
		# Create a timer to delay the queue_free
		scale = Vector3(0.001,0.001,0.001)
		var timer = Timer.new()
		timer.one_shot = true
		timer.wait_time = 2.0
		timer.timeout.connect(func(): queue_free())
		add_child(timer)
		timer.start()
		#queue_free()
	else:
		# Immediate destruction
		queue_free()
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
