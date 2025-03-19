extends Node3D
class_name ArtilleryPlotter

@export var barrel: Node3D
@export var muzzle: Node3D
var prev_offset: Vector2
var max_range: float
var flight_time: float
var elevation_delta: float

func calculate_max_range() -> float:
	# Get the shell's initial speed
	var initial_speed = Shell.shell_speed
	var gravity = Shell.gravity
	var drag_factor = Shell.drag_factor
	var mass = Shell.mass
	
	# For maximum range in a vacuum (no drag), we use the 45-degree angle formula
	# var theoretical_vacuum_range = (initial_speed * initial_speed) / gravity
	
	# But with drag, we need to simulate the trajectory
	
	# Start with the optimal launch angle (usually around 45° without drag,
	# but lower with drag - typically 30-40° depending on drag amount)
	var optimal_angles = [deg_to_rad(30)]
	# var max_range = 0.0
	
	for test_angle in optimal_angles:
		# Initialize simulation variables
		var sim_pos = Vector2(0, 0)
		var sim_vel = Vector2(cos(test_angle), sin(test_angle)) * initial_speed
		var shell_drag = drag_factor / mass
		var time_step = 0.05
		var max_sim_time = 120.0  # Maximum simulation time in seconds
		var sim_time = 0.0
		var highest_range = 0.0
		
		# Simulate until shell hits ground or max time reached
		while sim_pos.y >= 0 && sim_time < max_sim_time:
			var speed = sim_vel.length()
			var drag_force = sim_vel.normalized() * shell_drag * speed * speed
			
			sim_vel -= drag_force * time_step
			sim_vel.y -= gravity * time_step
			
			sim_pos += sim_vel * time_step
			sim_time += time_step
			
			# Update highest range if shell is still flying
			if sim_pos.y >= 0 && sim_pos.x > highest_range:
				highest_range = sim_pos.x
		
		# Keep track of the best range across different angles
		if highest_range > max_range:
			max_range = highest_range
	
	return max_range
	
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	max_range = calculate_max_range()
	if barrel == null:
		barrel = Node3D.new()
		add_child(barrel)
	if muzzle == null:
		muzzle = Node3D.new()
		barrel.add_child(muzzle)

func _elavate(aim_point: Vector3, max_degrees: float = 1000000.0, delta: float = 1.0):
	
	# Cache constants
	# const BARREL_ELEVATION_SPEED_DEG: float = 40.0
	
	var ap1 = aim_point - muzzle.global_position
	var ap: Vector2 = Vector2(sqrt(ap1.x * ap1.x + ap1.z * ap1.z), ap1.y)
	if ap.x > max_range:
		ap = Vector2(max_range, 0)
	
	var dir = self.barrel.global_basis.z
	var sim_shell = Vector2(0,0)
	var sim_time = 0.0
	var sim_vel = Vector2(sqrt(dir.x * dir.x + dir.z * dir.z), dir.y) * Shell.shell_speed
	var diff = ap
	var prev_diff = diff
	var shell_drag = Shell.drag_factor / Shell.mass
	
	var time_step:float = ap.length() / Shell.shell_speed * 0.7 / 10.0
	# var time_step: float = 1.0 / 10.0
	# var min_time_step2 = time_step2 / 5
	# var time_step = time_step2 / 15
	var min_time_step = 1.0 / 30.0
	var speed: float
	var drag_force: Vector2

	while diff.length_squared() <= prev_diff.length_squared():
		speed = sim_vel.length()
		drag_force = sim_vel.normalized() * shell_drag * speed * speed
		sim_vel -= drag_force * time_step
		sim_vel.y -= Shell.gravity * time_step
		sim_shell += sim_vel * time_step
		sim_time += time_step
		if time_step > min_time_step:
			time_step *= 0.8
		if time_step < min_time_step:
			time_step = min_time_step
		prev_diff = diff
		diff = ap - sim_shell
		
		if sim_time > 25:
			break
		
	
	# Calculate barrel elevation - IMPROVED SECTION
	var barrel_speed_rad: float = deg_to_rad(max_degrees)
	var max_barrel_angle: float = barrel_speed_rad * delta

	# Use a weighted combination of x and y error components with proportional control
	#var adjustment_factor: float = 0.5 # Adjustment sensitivity factor
	var adjustment_factor: float = prev_diff.length() / ap.length()
	var error_y_weight: float = 0.7 # Weight for vertical error (higher priority)
	var error_x_weight: float = 0.3 # Weight for horizontal error

	# Calculate weighted error
	var weighted_error: float = (-prev_diff.y * error_y_weight) + (-prev_diff.x * error_x_weight)


	# Calculate vectors from the aim point to both error positions
	var vector_to_prev_offset = prev_offset - ap
	var vector_to_prev_diff = prev_diff - ap

	# Check if they're pointing in opposite directions using dot product
	var dot_product = vector_to_prev_offset.dot(vector_to_prev_diff)

	var desired_angle: float
	# If dot product is negative, vectors are pointing in opposite directions
	var is_oscillating = dot_product < 0
	if is_oscillating:
		desired_angle = clamp(weighted_error * adjustment_factor * vector_to_prev_diff.length() / prev_offset.length(), -max_barrel_angle, max_barrel_angle)
	else:
		desired_angle = clamp(weighted_error * adjustment_factor / prev_diff.length(), -max_barrel_angle, max_barrel_angle)
	elevation_delta = desired_angle
	prev_offset = prev_diff
	flight_time = sim_time
	barrel.rotate(Vector3.RIGHT, desired_angle)

# Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta: float) -> void:
# 	pass
