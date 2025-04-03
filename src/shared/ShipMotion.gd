extends RigidBody3D
class_name ShipMotion

var initialized: bool = false
# Child components
var movement_controller: ShipMovement
var artillery_controller: ShipArtillery

func _ready() -> void:
	
	# Get references to child components
	movement_controller = $ShipMovement
	artillery_controller = $ArtilleryController
	
	initialized = true
	if !multiplayer.is_server():
		initialized_client.rpc_id(1)

func set_input(input_array: Array, aim_point: Vector3) -> void:
	# Split the input between movement and artillery controllers
	movement_controller.set_movement_input([input_array[0], input_array[1]])
	artillery_controller.set_aim_input(aim_point)

func _physics_process(delta: float) -> void:
	if !multiplayer.is_server():
		return
	# Sync ship data to all clients
	sync_ship_data()

func sync_ship_data() -> void:
	var d = {
		'y': movement_controller.throttle_level, 
		't': movement_controller.thrust_vector, 
		'r': movement_controller.rudder_value,
		'v': linear_velocity,
		'b': global_basis, 
		'p': global_position, 
		'g': [], 
		's': []
	}
	
	for g in artillery_controller.guns:
		d.g.append({'b': g.basis, 'c': g.barrel.basis})
	
	var secondaries = get_node("Secondaries")
	for s: Gun in secondaries.get_children():
		d.s.append({'b': s.basis,'c': s.barrel.basis})
		
	sync.rpc(d)

@rpc("any_peer","reliable")
func initialized_client():
	self.initialized = true

@rpc("any_peer", "call_remote")
func sync(d: Dictionary):
	if !self.initialized:
		return
	
	self.global_position = d.p
	self.global_basis = d.b
	movement_controller.rudder_value = d.r
	movement_controller.thrust_vector = d.t
	movement_controller.throttle_level = d.y
	linear_velocity = d.v
	
	var i = 0
	for g in artillery_controller.guns:
		g.basis = d.g[i].b
		g.barrel.basis = d.g[i].c
		i += 1
		
	var _s = get_node("Secondaries")
	i = 0
	for s: Gun in _s.get_children():
		s.basis = d.s[i].b
		s.barrel.basis = d.s[i].c
		i += 1
