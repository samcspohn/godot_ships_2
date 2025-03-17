extends Node3D

@onready var smoke_trail = $SmokeTrail

func _ready():
	# Setup the smoke trail particles
	setup_smoke_trail()

func setup_smoke_trail():
	# Create a new GPUParticles3D if it doesn't exist
	if not smoke_trail:
		smoke_trail = GPUParticles3D.new()
		add_child(smoke_trail)
		
	# Configure the particles
	smoke_trail.emitting = true
	smoke_trail.amount = 64  # Increased for trail effect
	smoke_trail.lifetime = 1.0
	smoke_trail.one_shot = false
	smoke_trail.local_coords = true  # Keep particles attached to the bullet
	smoke_trail.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Y_TO_VELOCITY
	
	# Create the particle material
	var material = ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	material.particle_flag_align_y = true
	material.direction = Vector3(0, 0, 0)  # No initial direction
	material.spread = 0.0
	material.gravity = Vector3.ZERO
	
	# Use a small amount of initial velocity to create trail effect
	material.initial_velocity_min = 0.1
	material.initial_velocity_max = 0.2
	
	# Make particles drag behind in global space
	material.damping_min = 5.0  # High damping to slow particles quickly
	material.damping_max = 5.0
	
	# Create a gradient for fading out the trail
	var gradient = Gradient.new()
	gradient.add_point(0.0, Color(1, 1, 1, 0.8))
	gradient.add_point(1.0, Color(1, 1, 1, 0))
	
	# Apply the gradient to the material
	material.color_ramp = gradient
	
	# Set the material to use with the particles
	smoke_trail.process_material = material
	
	# Create a ribbon trail mesh
	var ribbon_mesh = RibbonTrailMesh.new()
	ribbon_mesh.size = 0.2  # Width of the trail
	ribbon_mesh.sections = 20  # Number of segments
	ribbon_mesh.section_length = 0.1  # Length of each segment
	
	# Create a standard material for the ribbon
	var ribbon_material = StandardMaterial3D.new()
	#ribbon_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ribbon_material.albedo_color = Color(0.8, 0.8, 0.8, 0.5)  # Smoke color
	ribbon_material.emission_enabled = true
	ribbon_material.emission = Color(0.2, 0.2, 0.2)
	ribbon_material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	ribbon_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	# Apply the material to the ribbon mesh
	ribbon_mesh.material = ribbon_material
	
	# Set up the draw pass for the particles
	smoke_trail.draw_pass_1 = ribbon_mesh
	smoke_trail.draw_passes = 1
	
	# Set up a continuous emission to ensure the trail stays connected
	smoke_trail.fixed_fps = 60  # Higher FPS for smoother trail
	
	# Configure the trail to display in global space
	# This requires a trick: we use local_coords, but we'll update the
	# position of the particle system in _physics_process

func _physics_process(delta):
	# Your bullet movement code here
	# For example:
	#velocity = Vector3(0, 0, -30)  # Adjust bullet speed as needed
	#move_and_slide()
	
	# Important: Update the smoke trail's global transform
	# This keeps the origin of the particle system at the bullet's position
	# while allowing previously emitted particles to stay in global space
	if smoke_trail:
		# Store the current global position
		var current_global_pos = smoke_trail.global_position
		
		# Reset the smoke trail's local position to maintain attachment to bullet
		smoke_trail.position = Vector3.ZERO
		
		# This technique makes the trail appear to drag behind in global space
		# even though we're using local_coords=true
