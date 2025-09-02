extends RigidBody3D
class_name Ship

var initialized: bool = false
# Child components
var movement_controller: ShipMovement
var artillery_controller: ShipArtillery
@export var secondary_controllers: Array[SecondaryController]
var health_controller: HitPointsManager
var torpedo_launcher: TorpedoLauncher
var control
var team: TeamEntity
var visible_to_enemy: bool = false
var armor_system: ArmorSystemV2
@export var citadel: StaticBody3D
@export var hull: StaticBody3D

# Armor system configuration
@export_file("*.glb") var ship_model_glb_path: String
@export var auto_extract_armor: bool = true


func _enable_guns():
	if !initialized:
		await Engine.get_main_loop().process_frame
	for g: Gun in artillery_controller.guns:
		g.disabled = false
	for c in secondary_controllers:
		for g: Gun in c.guns:
			g.disabled = false

func _disable_guns():
	if !initialized:
		await Engine.get_main_loop().process_frame
	for g: Gun in artillery_controller.guns:
		g.disabled = true
	for c in secondary_controllers:
		for g: Gun in c.guns:
			g.disabled = true


func _ready() -> void:
	# Get references to child components
	movement_controller = $Modules/MovementController
	artillery_controller = $Modules/ArtilleryController
	health_controller = $Modules/HPManager
	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	
	# Initialize armor system
	initialize_armor_system()
	
	initialized = true
	if !multiplayer.is_server():
		initialized_client.rpc_id(1)
	
	self.collision_layer = 1 << 2
	self.collision_mask = 1 | 1 << 2


func set_input(input_array: Array, aim_point: Vector3) -> void:
	# Split the input between movement and artillery controllers
	movement_controller.set_movement_input([input_array[0], input_array[1]])
	artillery_controller.set_aim_input(aim_point)

func _physics_process(delta: float) -> void:
	if !multiplayer.is_server():
		return
	if torpedo_launcher != null:
		torpedo_launcher._aim(artillery_controller.aim_point, delta)
	# Sync ship data to all clients
	sync_ship_data()

func sync_ship_data() -> Dictionary:
	var d = {
		'y': movement_controller.throttle_level, 
		't': movement_controller.thrust_vector, 
		'r': movement_controller.rudder_value,
		'v': linear_velocity,
		'b': global_basis, 
		'p': global_position,
		'h': health_controller.current_hp,
		'g': [], 
		's': []
	}
	
	for g in artillery_controller.guns:
		d.g.append({'b': g.basis, 'c': g.barrel.basis})
	
	for controller in secondary_controllers:
		for s: Gun in controller.guns:
			d.s.append({'b': s.basis, 'c': s.barrel.basis})

	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	if torpedo_launcher != null:
		d['tl'] = torpedo_launcher.global_basis
		
	return d

@rpc("any_peer","reliable")
func initialized_client():
	self.initialized = true

@rpc("any_peer", "call_remote")
func sync(d: Dictionary):
	if !self.initialized:
		return
	self.visible = true
	self.global_position = d.p
	self.global_basis = d.b
	movement_controller.rudder_value = d.r
	movement_controller.thrust_vector = d.t
	movement_controller.throttle_level = d.y
	linear_velocity = d.v
	health_controller.current_hp = d.h
	
	var i = 0
	for g in artillery_controller.guns:
		g.basis = d.g[i].b
		g.barrel.basis = d.g[i].c
		i += 1
		
	for controller in secondary_controllers:
		i = 0
		for s: Gun in controller.guns:
			s.basis = d.s[i].b
			s.barrel.basis = d.s[i].c
			i += 1
		
	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	if torpedo_launcher != null:
		torpedo_launcher.global_basis = d.tl

@rpc("any_peer", "reliable")
func _hide():
	self.visible = false

func enable_backface_collision_recursive(node: Node) -> void:
	var path: String = ""
	var n = node
	while n != self:
		path = n.name + "/" + path
		n = n.get_parent()
	path = path.rstrip("/")
	if armor_system.armor_data.has(path) and node is MeshInstance3D:
		var static_body: StaticBody3D = node.find_child("StaticBody3D", false)
		var collision_shape: CollisionShape3D = static_body.find_child("CollisionShape3D", false)
		#curr_static.queue_free()
		# Set up physics body and collision shape
		#var collision_mesh = (node as MeshInstance3D).mesh.create_trimesh_shape()
		#var collision_shape = CollisionShape3D.new()
		#collision_shape.shape = collision_mesh
		#var collision_shape = create_ordered_collision(node as MeshInstance3D)
		#var static_body = StaticBody3D.new()
		#static_body.get_child(0).queue_free()
		#static_body.add_child(collision_shape)
		# Enable backface collision for better hit detection
		if collision_shape.shape is ConcavePolygonShape3D:
			collision_shape.shape.backface_collision = true
		#static_body.add_child(collision_shape)
		#node.add_child(static_body)
		# Enable physics processing for the static body
		static_body.collision_layer = 1 << 1
		static_body.collision_mask = 0
		#static_body.set_collision_layer(1 << 1)
		#static_body.set_collision_mask(0)
		if node.name == "Hull":
			hull = static_body
			print("static_body.collision_layer: ", static_body.collision_layer)
			print("static_body.collision_mask: ", static_body.collision_mask)
		elif node.name == "Citadel":
			citadel = static_body
		
	for child in node.get_children():
		enable_backface_collision_recursive(child)

func initialize_armor_system() -> void:
	"""Initialize the armor system - extract and load armor data"""
	print("🛡️ Initializing armor system for ship...")
	
	# Validate and resolve the GLB path
	var resolved_glb_path = resolve_glb_path(ship_model_glb_path)
	if resolved_glb_path.is_empty():
		print("   ❌ Invalid or missing GLB path: ", ship_model_glb_path)
		return
	
	# Create armor system instance
	armor_system = ArmorSystemV2.new()
	add_child(armor_system)
	
	# Determine paths
	var model_name = resolved_glb_path.get_file().get_basename()
	var ship_dir = resolved_glb_path.get_base_dir()
	var armor_json_path = ship_dir + "/" + model_name + "_armor.json"
	
	print("   Ship model: ", resolved_glb_path)
	print("   Armor data: ", armor_json_path)
	
	# Check if armor JSON already exists
	if FileAccess.file_exists(armor_json_path):
		print("   ✅ Found existing armor data, loading...")
		var success = armor_system.load_armor_data(armor_json_path)
		if success:
			print("   ✅ Armor system initialized successfully")
		else:
			print("   ❌ Failed to load existing armor data")
	elif auto_extract_armor:
		print("   🔧 No armor data found, extracting from GLB...")
		extract_and_load_armor_data(resolved_glb_path, armor_json_path)
	else:
		print("   ⚠️ No armor data found and auto-extraction disabled")

	enable_backface_collision_recursive(self)
	print("done")
	

func resolve_glb_path(path: String) -> String:
	"""Resolve GLB path from UID or direct path"""
	if path.is_empty():
		return ""
	
	# Check if it's a UID (starts with "uid://")
	if path.begins_with("uid://"):
		# Try to resolve the UID to actual path
		var resource = load(path)
		if resource != null:
			var resource_path = resource.resource_path
			if resource_path.ends_with(".glb"):
				print("   📂 Resolved UID to path: ", resource_path)
				return resource_path
			else:
				print("   ⚠️ UID resolved to non-GLB resource: ", resource_path)
				return ""
		else:
			print("   ❌ Failed to resolve UID: ", path)
			return ""
	
	# Direct path - validate it exists and is GLB
	if path.ends_with(".glb") and FileAccess.file_exists(path):
		return path
	else:
		print("   ❌ Invalid GLB path: ", path)
		return ""

func extract_and_load_armor_data(glb_path: String, armor_json_path: String) -> void:
	"""Extract armor data from GLB and save it locally"""
	# Load the extractor
	var extractor_script = load("res://enhanced_armor_extractor_v2.gd")
	var extractor = extractor_script.new()
	
	print("      Extracting armor data from GLB...")
	var success = extractor.extract_armor_with_mapping_to_json(glb_path, armor_json_path)
	
	if success:
		print("      ✅ Armor extraction completed")
		print("      📁 Saved to: ", armor_json_path)
		
		# Load the newly extracted data
		success = armor_system.load_armor_data(armor_json_path)
		if success:
			print("      ✅ Armor system initialized successfully")
		else:
			print("      ❌ Failed to load extracted armor data")
	else:
		print("      ❌ Armor extraction failed")

func get_armor_at_hit_point(hit_node: Node3D, face_index: int) -> int:
	"""Get armor thickness at a specific hit point"""
	if armor_system == null:
		return 0
	
	# Convert scene node to armor data path
	var node_path = armor_system.get_node_path_from_scene(hit_node, self.name)
	return armor_system.get_face_armor_thickness(node_path, face_index)

func calculate_damage_from_hit(hit_node: Node3D, face_index: int, shell_penetration: int) -> Dictionary:
	"""Calculate damage from a shell hit"""
	if armor_system == null:
		return {"penetrated": true, "damage_ratio": 1.0, "damage_type": "no_armor"}

	var node_path = armor_system.get_node_path_from_scene(hit_node, self.name)
	return armor_system.calculate_penetration_damage(node_path, face_index, shell_penetration)
