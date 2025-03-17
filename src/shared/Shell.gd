class_name Shell
extends Node3D


const shell_speed = 10.0
var id: int
# Projectile properties
@export var initial_velocity: float = 10.0
static var gravity: float = .98
static  var drag_coefficient: float = 0.05
static var mass: float = 1.0
@export var damage: float = 10.0
@export var lifetime: float = 10.0  # Maximum lifetime in seconds

# Internal variables
var velocity: Vector3 = Vector3.ZERO
var time_alive: float = 0.0
var previous_position: Vector3
var ray_query: PhysicsRayQueryParameters3D
var space_state: PhysicsDirectSpaceState3D

# Signal emitted when projectile hits something
signal hit(collision_info)
signal destroyed()

# Static method for calculating launch vector
static func calculate_launch_vector(
	start_position: Vector3, 
	target_position: Vector3, 
	target_velocity: Vector3, 
	projectile_speed: float, 
	gravity: float, 
	drag_coefficient: float,
	projectile_mass: float,
	max_iterations: int = 20,
	tolerance: float = 0.1
) -> Vector3:
	# This is a complex problem with drag, so we'll use an iterative approach
	
	# First attempt - ignore drag and use a simple first-order prediction
	var time_to_target = start_position.distance_to(target_position) / projectile_speed
	var predicted_target = target_position + target_velocity * time_to_target
	
	# Initial guess - direct vector to predicted position
	var direction = (predicted_target - start_position).normalized()
	var launch_vector = direction * projectile_speed
	
	# Iterative refinement
	var iteration = 0
	var error = Vector3.ONE * 999
	
	while iteration < max_iterations and error.length() > tolerance:
		iteration += 1
		
		# Simulate projectile path with current launch vector
		var simulated_position = start_position
		var simulated_velocity = launch_vector
		var simulated_time = 0.0
		var time_step = 0.05  # Small time step for simulation
		var max_sim_steps = 200  # Prevent infinite loops
		var sim_steps = 0
		
		while sim_steps < max_sim_steps:
			sim_steps += 1
			
			# Update position
			simulated_position += simulated_velocity * time_step
			
			# Apply forces
			# Gravity
			simulated_velocity.y -= gravity * time_step
			
			# Air resistance
			var speed = simulated_velocity.length()
			if speed > 0:
				var drag_force = simulated_velocity.normalized() * drag_coefficient * speed * speed / projectile_mass
				simulated_velocity -= drag_force * time_step
			
			simulated_time += time_step
			
			# Check if we're close to the target's predicted position at this time
			var target_at_time = target_position + target_velocity * simulated_time
			var distance_to_target = simulated_position.distance_to(target_at_time)
			
			if distance_to_target < 1.0:  # Hit within 1 unit
				break
			
			# Stop if we're clearly missing
			if simulated_position.y < min(start_position.y, target_position.y) - 50:
				break
		
		# Calculate error and adjust launch vector
		var final_target_pos = target_position + target_velocity * simulated_time
		error = final_target_pos - simulated_position
		
		# Adjust launch vector based on error
		launch_vector += error * 0.3 * (1.0 / (iteration + 1))
		
		# Ensure we maintain the desired initial speed
		launch_vector = launch_vector.normalized() * projectile_speed
	
	return launch_vector
	
# Static method for calculating launch vector
static func calculate_launch_vector2(
	start_position: Vector3, 
	target_position: Vector3, 
	target_velocity: Vector3, 
	projectile_speed: float, 
	#gravity: float, 
	drag_coefficient: float,
	projectile_mass: float,
	max_iterations: int = 20,
	tolerance: float = 0.1
) -> Vector3:
	# This is a complex problem with drag, so we'll use an iterative approach
	
	# First attempt - ignore drag and use a simple first-order prediction
	var time_to_target = start_position.distance_to(target_position) / projectile_speed
	var predicted_target = target_position + target_velocity * time_to_target
	
	# Initial guess - direct vector to predicted position
	var direction = (predicted_target - start_position).normalized()
	var launch_vector = direction * projectile_speed
	
	# Iterative refinement
	var iteration = 0
	var error = Vector3.ONE * 999
	
	while iteration < max_iterations and error.length() > tolerance:
		iteration += 1
		
		# Simulate projectile path with current launch vector
		var simulated_position = start_position
		var simulated_velocity = launch_vector
		var simulated_time = 0.0
		var time_step = 0.05  # Small time step for simulation
		var max_sim_steps = 200  # Prevent infinite loops
		var sim_steps = 0
		
		while sim_steps < max_sim_steps:
			sim_steps += 1
			
			# Update position
			simulated_position += simulated_velocity * time_step
			
			# Apply forces
			# Gravity
			simulated_velocity.y -= gravity * time_step
			
			# Air resistance
			var speed = simulated_velocity.length()
			if speed > 0:
				var drag_force = simulated_velocity.normalized() * drag_coefficient * speed * speed / projectile_mass
				simulated_velocity -= drag_force * time_step
			
			simulated_time += time_step
			
			# Check if we're close to the target's predicted position at this time
			var target_at_time = target_position + target_velocity * simulated_time
			var distance_to_target = simulated_position.distance_to(target_at_time)
			
			if distance_to_target < 1.0:  # Hit within 1 unit
				break
			
			# Stop if we're clearly missing
			if simulated_position.y < min(start_position.y, target_position.y) - 50:
				break
		
		# Calculate error and adjust launch vector
		var final_target_pos = target_position + target_velocity * simulated_time
		error = final_target_pos - simulated_position
		
		# Adjust launch vector based on error
		launch_vector += error * 0.3 * (1.0 / (iteration + 1))
		
		# Ensure we maintain the desired initial speed
		launch_vector = launch_vector.normalized() * projectile_speed
	
	return launch_vector
	
func _ready():
	previous_position = global_position
	
	# Create persistent ray query
	ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.collide_with_areas = true
	ray_query.collide_with_bodies = true
	
	# Get the physics space state for raycasting
	space_state = get_world_3d().direct_space_state

func initialize(direction: Vector3, spawn_velocity: float = initial_velocity):
	velocity = direction.normalized() * spawn_velocity
	previous_position = global_position

	
func _physics_process(delta):
	time_alive += delta
	
	# Destroy if lifetime exceeded
	if time_alive > lifetime:
		_destroy()
		return
	
	# Store current position for raycast start
	previous_position = global_position
	
	# Apply forces (gravity and air resistance)
	_apply_forces(delta)
	
	# Move the projectile
	global_position += velocity * delta
	
	# Check for collisions
	_check_collisions()
	
	# Update the rotation to face movement direction
	if velocity.length_squared() > 0.01:
		look_at(global_position + velocity.normalized(), Vector3.UP)

func _apply_forces(delta):
	# Apply gravity
	velocity.y -= gravity * delta
	
	# Apply air resistance (drag force = drag_coefficient * velocity^2)
	var speed = velocity.length()
	if speed > 0:
		var drag_force = velocity.normalized() * drag_coefficient * speed * speed / mass
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
		var expl = Node3D.new()
		expl.global_position = global_position
		var emitter = get_child(0)
		remove_child(emitter)
		expl.add_child(emitter)
		# Create a timer to delay the queue_free
		var timer = Timer.new()
		timer.one_shot = true
		timer.wait_time = 3.0
		timer.timeout.connect(func(): expl.queue_free())
		expl.add_child(timer)
		timer.start()
		queue_free()
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
