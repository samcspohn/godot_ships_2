extends Node3D

# Simple test script to demonstrate ShipMovementV2 usage
# Attach this to a scene with a RigidBody3D that has ShipMovementV2 as a child

@onready var ship_movement = $RigidBody3D/ShipMovementV2

func _ready():
	print("Ship Movement Test initialized")
	print("Controls:")
	print("W/S - Throttle up/down")
	print("A/D - Turn left/right")
	print("Q - Emergency stop")

func _input(event):
	if not ship_movement:
		return
		
	# Handle throttle input
	if event.is_action_pressed("ui_up"):  # W key
		ship_movement.throttle_level = min(ship_movement.throttle_level + 1, 4)
		print("Throttle: ", ship_movement.throttle_level)
	elif event.is_action_pressed("ui_down"):  # S key
		ship_movement.throttle_level = max(ship_movement.throttle_level - 1, -1)
		print("Throttle: ", ship_movement.throttle_level)

func _process(_delta):
	if not ship_movement:
		return
		
	# Handle rudder input
	var rudder = 0.0
	if Input.is_action_pressed("ui_left"):  # A key
		rudder = -1.0
	elif Input.is_action_pressed("ui_right"):  # D key
		rudder = 1.0
	
	# Emergency stop
	if Input.is_action_just_pressed("ui_accept"):  # Enter key or Q
		ship_movement.emergency_stop()
		print("Emergency stop!")
	
	# Send input to movement system
	ship_movement.set_movement_input([ship_movement.throttle_level, rudder])
	
	# Display debug info every 60 frames
	if Engine.get_process_frames() % 60 == 0:
		var debug_info = ship_movement.get_movement_debug_info()
		print("Target: %.1f m/s, Current: %.1f m/s, Actual: %.1f m/s (%.1f km/h)" % [
			debug_info.target_speed,
			debug_info.current_speed,
			debug_info.actual_forward_speed,
			debug_info.speed_kmh
		])
		print("Throttle: %.0f%%, Rudder: %.2f, Total velocity: %.1f m/s" % [
			debug_info.throttle_percentage,
			debug_info.rudder_input,
			debug_info.total_velocity
		])
		if debug_info.collision_override:
			print("COLLISION OVERRIDE ACTIVE - Can reverse immediately: %s" % debug_info.can_reverse_immediately)
		if debug_info.actual_turning_radius > 0:
			print("Turning radius: %.1f m (target: %.1f m)" % [
				debug_info.actual_turning_radius,
				debug_info.target_turning_radius
			])
