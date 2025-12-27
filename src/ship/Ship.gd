extends RigidBody3D
class_name Ship

var initialized: bool = false
# Child components
@onready var movement_controller: ShipMovementV2 = $Modules/MovementController
@onready var artillery_controller: ArtilleryController = $Modules/ArtilleryController
@onready var secondary_controller: SecondaryController_ = $Modules/SecondaryController
@onready var health_controller: HitPointsManager = $Modules/HPManager
@onready var consumable_manager: ConsumableManager = $Modules/ConsumableManager
@onready var fire_manager: FireManager = $Modules/FireManager
@onready var upgrades: Upgrades = $Modules/Upgrades
@onready var skills: SkillsManager = $Modules/Skills
var torpedo_launcher: TorpedoLauncher
var stats: Stats
var control
var team: TeamEntity
var visible_to_enemy: bool = false
var armor_system: ArmorSystemV2
@export var citadel: StaticBody3D
@export var hull: StaticBody3D
var armor_parts: Array[ArmorPart] = []
var aabb: AABB
var static_mods: Array = [] # applied on _init and when reset_static_mods signal is emitted
var dynamic_mods: Array = [] # checked every frame for changes, affects _params

var peer_id: int = -1 # our unique peer ID assigned by server

var frustum_planes: Array[Plane] = []

# @export var fires: Array[Fire] = []

# Armor system configuration
@export_file("*.glb") var ship_model_glb_path: String
@export var auto_extract_armor: bool = true

signal reset_mods # resets static and dynamic to base
signal reset_dynamic_mods

var update_static_mods: bool = false
var update_dynamic_mods: bool = false

func add_static_mod(mod_func):
	static_mods.append(mod_func)
	update_static_mods = true
	#_update_static_mods()

func remove_static_mod(mod_func):
	static_mods.erase(mod_func)
	update_static_mods = true
	#_update_static_mods()

func add_dynamic_mod(mod_func):
	dynamic_mods.append(mod_func)
	update_dynamic_mods = true

func remove_dynamic_mod(mod_func):
	dynamic_mods.erase(mod_func)
	update_dynamic_mods = true


func _enable_guns():
	if !initialized:
		await Engine.get_main_loop().process_frame
	for g: Gun in artillery_controller.guns:
		g.disabled = false
	for c in secondary_controller.sub_controllers:
		for g: Gun in c.guns:
			g.disabled = false

func _disable_guns():
	if !initialized:
		await Engine.get_main_loop().process_frame
	for g: Gun in artillery_controller.guns:
		g.disabled = true
	for c in secondary_controller.sub_controllers:
		for g: Gun in c.guns:
			g.disabled = true

func _update_static_mods(): # called when changed
	reset_mods.emit()
	for mod in static_mods:
		mod.call(self)
	#reset_dynamic_mods.emit()
	_update_dynamic_mods()
	# update_static_mods.emit()

func _update_dynamic_mods(): # called when updated by signal
	reset_dynamic_mods.emit()
	for mod in dynamic_mods:
		mod.call(self)
	# update_static_mods.emit()

func _ready() -> void:
	# Get references to child components
	# movement_controller = $Modules/MovementController
	# artillery_controller = $Modules/ArtilleryController
	# health_controller = $Modules/HPManager
	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	# consumable_manager = $Modules/ConsumableManager
	consumable_manager.ship = self
	# fire_manager = $Modules/FireManager
	fire_manager._ship = self
	skills._ship = self
	stats = Stats.new()
	$Modules.add_child(stats)


	# for f in fires:
	# 	f._ship = self
	# Initialize armor system
	initialize_armor_system()

	initialized = true
	if !(_Utils.authority()):
		initialized_client.rpc_id(1)
		set_physics_process(false)
		# self.freeze = true
		# # Disable all collision shapes under the node
		# for child in get_children():
		# 	if child is CollisionShape3D:
		# 		child.disabled = true


	self.collision_layer = 1 << 2
	self.collision_mask = 1 | 1 << 2


func set_input(input_array: Array, aim_point: Vector3) -> void:
	# Split the input between movement and artillery controllers
	movement_controller.set_movement_input([input_array[0], input_array[1]])
	artillery_controller.set_aim_input(aim_point)

func _physics_process(delta: float) -> void:
	if !(_Utils.authority()):
		return
	if torpedo_launcher != null:
		torpedo_launcher._aim(artillery_controller.aim_point, delta)

	for skill in skills.skills:
		skill._proc(delta)
	if update_static_mods:
		_update_static_mods()
		update_static_mods = false
	if update_dynamic_mods:
		_update_dynamic_mods()
		update_dynamic_mods = false

	# Sync ship data to all clients
	# sync_ship_data()

	#_update_dynamic_mods()

func get_aabb() -> AABB:
	return self.aabb * global_transform

func sync_ship_data2(vs: bool, friendly: bool) -> PackedByteArray:
	var pb = PackedByteArray()
	var writer = StreamPeerBuffer.new()

	# writer.put_32(movement_controller.throttle_level)
	#writer.put_float_array(movement_controller.thrust_vector.to_array())
	# writer.put_float(movement_controller.rudder_input)
	writer.put_var(linear_velocity)
	var euler = global_basis.get_euler()
	writer.put_var(euler)
	# writer.put_var(global_basis)
	writer.put_var(global_position)
	writer.put_float(health_controller.current_hp)

	# Consumables data
	if friendly:
		writer.put_var(consumable_manager.to_bytes())

	# Artillery data
	# writer.put_var(artillery_controller.to_bytes())
	# Guns data
	writer.put_32(artillery_controller.guns.size())
	for g in artillery_controller.guns:
		writer.put_var(g.to_bytes(false))

	# Secondary controllers data
	writer.put_32(secondary_controller.sub_controllers.size())
	for controller in secondary_controller.sub_controllers:
		# writer.put_var(controller.to_bytes())
		writer.put_32(controller.guns.size())
		for g: Gun in controller.guns:
			writer.put_var(g.to_bytes(false))

	# Torpedo launcher data
	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	writer.put_32(1 if torpedo_launcher != null else 0)
	if torpedo_launcher != null:
		var euler_tl = torpedo_launcher.global_basis.get_euler()
		writer.put_var(euler_tl)

	writer.put_32(multiplayer.get_unique_id())

	# # Ship stats data
	# var stats_bytes = stats.to_bytes()
	# writer.put_var(stats_bytes)
	writer.put_u8(1 if vs else 0)

	pb = writer.get_data_array()
	return pb

func sync_ship_transform() -> PackedByteArray:
	var pb = PackedByteArray()
	var writer = StreamPeerBuffer.new()
	writer.put_float(rotation.y)
	writer.put_float(global_position.x)
	writer.put_float(global_position.z)
	writer.put_float(health_controller.current_hp)
	writer.put_float(health_controller.max_hp)
	writer.put_u8(1 if visible_to_enemy else 0)
	pb = writer.get_data_array()
	return pb

func parse_ship_transform(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	rotation.y = reader.get_float()
	global_position.x = reader.get_float()
	global_position.y = 0
	global_position.z = reader.get_float()
	health_controller.current_hp = reader.get_float()
	health_controller.max_hp = reader.get_float()
	visible_to_enemy = reader.get_u8() == 1

func sync_player_data() -> PackedByteArray:
	var pb = PackedByteArray()
	var writer = StreamPeerBuffer.new()

	writer.put_32(movement_controller.throttle_level)
	#writer.put_float_array(movement_controller.thrust_vector.to_array())
	writer.put_float(movement_controller.rudder_input)
	writer.put_var(linear_velocity)
	var euler = global_basis.get_euler()
	writer.put_var(euler)
	# writer.put_var(global_basis)
	writer.put_var(global_position)
	writer.put_float(health_controller.current_hp)

	# Consumables data
	writer.put_var(consumable_manager.to_bytes())

	# Artillery data
	writer.put_var(artillery_controller.to_bytes())
	# Guns data
	# writer.put_32(artillery_controller.guns.size())
	for g in artillery_controller.guns:
		writer.put_var(g.to_bytes(true))

	# Secondary controllers data
	# writer.put_32(secondary_controller.sub_controllers.size())
	for controller in secondary_controller.sub_controllers:
		writer.put_var(controller.to_bytes())
		# writer.put_32(controller.guns.size())
		for g: Gun in controller.guns:
			writer.put_var(g.to_bytes(true))

	# Torpedo launcher data
	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	if torpedo_launcher != null:
		var euler_tl = torpedo_launcher.global_basis.get_euler()
		writer.put_var(euler_tl)
		# writer.put_var(torpedo_launcher.global_basis)

	writer.put_32(multiplayer.get_unique_id())

	# Ship stats data
	var stats_bytes = stats.to_bytes()
	writer.put_var(stats_bytes)

	pb = writer.get_data_array()
	return pb


@rpc("any_peer", "reliable")
func initialized_client():
	self.initialized = true

# @rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func sync2(b: PackedByteArray, friendly: bool):
	# print("here")

	if !self.initialized:
		return
	self.visible = true
	# print("here2")

	var reader = StreamPeerBuffer.new()
	reader.data_array = b

	# movement_controller.throttle_level = reader.get_32()
	#movement_controller.thrust_vector = Vector3(reader.get_float_array())
	# movement_controller.rudder_input = reader.get_float()
	linear_velocity = reader.get_var()
	# global_basis = reader.get_var()
	var euler: Vector3 = reader.get_var()
	global_basis = Basis.from_euler(euler)
	global_position = reader.get_var()
	health_controller.current_hp = reader.get_float()
	# max hp

	# Consumables data
	if friendly:
		var cons_bytes: PackedByteArray = reader.get_var()
		consumable_manager.from_bytes(cons_bytes) # bytes is broken

	# Artillery data
	# var art_bytes: PackedByteArray = reader.get_var()
	# artillery_controller.from_bytes(art_bytes)
	# Guns data
	var gun_count: int = reader.get_32()
	for g in artillery_controller.guns:
		var gun_bytes: PackedByteArray = reader.get_var()
		g.from_bytes(gun_bytes, false)

	# Secondary controllers data
	var sc_count: int = reader.get_32()
	for controller in secondary_controller.sub_controllers:
		# var sc_bytes: PackedByteArray = reader.get_var()
		# controller.from_bytes(sc_bytes)
		var sc_gun_count: int = reader.get_32()
		for g: Gun in controller.guns:
			var gun_bytes: PackedByteArray = reader.get_var()
			g.from_bytes(gun_bytes, false)

	# Torpedo launcher data
	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	if torpedo_launcher != null:
		var euler_tl: Vector3 = reader.get_var()
		torpedo_launcher.global_basis = Basis.from_euler(euler_tl)
		# torpedo_launcher.global_basis = reader.get_var()
	var p_id: int = reader.get_32()
	# var stats_bytes: PackedByteArray = reader.get_var()
	# stats.from_bytes(stats_bytes)
	self.visible_to_enemy = reader.get_u8() == 1


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func sync_player(b: PackedByteArray):
	if !self.initialized:
		return
	self.visible = true
	var reader = StreamPeerBuffer.new()
	reader.data_array = b

	movement_controller.throttle_level = reader.get_32()
	#movement_controller.thrust_vector = Vector3(reader.get_float_array())
	movement_controller.rudder_input = reader.get_float()
	linear_velocity = reader.get_var()
	# global_basis = reader.get_var()
	var euler: Vector3 = reader.get_var()
	global_basis = Basis.from_euler(euler)
	global_position = reader.get_var()
	health_controller.current_hp = reader.get_float()
	# max hp

	# Consumables data
	var cons_bytes: PackedByteArray = reader.get_var()
	consumable_manager.from_bytes(cons_bytes) # bytes is broken

	# Artillery data
	var art_bytes: PackedByteArray = reader.get_var()
	artillery_controller.from_bytes(art_bytes)

	# Guns data
	# var gun_count: int = reader.get_32()
	for g in artillery_controller.guns:
		var gun_bytes: PackedByteArray = reader.get_var()
		g.from_bytes(gun_bytes, true)

	# Secondary controllers data
	# var sc_count: int = reader.get_32()
	for controller in secondary_controller.sub_controllers:
		var sc_bytes: PackedByteArray = reader.get_var()
		controller.from_bytes(sc_bytes)
		# var sc_gun_count: int = reader.get_32()
		for g: Gun in controller.guns:
			var gun_bytes: PackedByteArray = reader.get_var()
			g.from_bytes(gun_bytes, true)

	# Torpedo launcher data
	torpedo_launcher = get_node_or_null("TorpedoLauncher")
	if torpedo_launcher != null:
		var euler_tl: Vector3 = reader.get_var()
		torpedo_launcher.global_basis = Basis.from_euler(euler_tl)
		# torpedo_launcher.global_basis = reader.get_var()
	var p_id: int = reader.get_32()
	var stats_bytes: PackedByteArray = reader.get_var()
	stats.from_bytes(stats_bytes)
	# self.visible_to_enemy = reader.get_u8() == 1


@rpc("any_peer", "reliable")
func _hide():
	self.visible = false
	self.visible_to_enemy = false

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
		static_body.remove_child(collision_shape)
		if collision_shape.shape is ConcavePolygonShape3D:
			collision_shape.shape.backface_collision = true
		static_body.queue_free()

		var armor_part = ArmorPart.new()
		armor_part.add_child(collision_shape)
		armor_part.collision_layer = 1 << 1
		armor_part.collision_mask = 0
		armor_part.armor_system = armor_system
		armor_part.armor_path = path
		armor_part.ship = self
		node.add_child(armor_part)
		armor_parts.append(armor_part)
		self.aabb = self.aabb.merge((node as MeshInstance3D).get_aabb())
		# static_body.collision_layer = 1 << 1
		# static_body.collision_mask = 0
		if node.name == "Hull":
			hull = armor_part
			print("armor_part.collision_layer: ", armor_part.collision_layer)
			print("armor_part.collision_mask: ", armor_part.collision_mask)
		elif node.name == "Citadel":
			citadel = armor_part

	if armor_system.armor_data.has(path) and node is StaticBody3D:
		var collision_shape: CollisionShape3D = node.find_child("CollisionShape3D", false)
		if collision_shape.shape is ConcavePolygonShape3D:
			collision_shape.shape.backface_collision = true

		var armor_part = ArmorPart.new()
		armor_part.add_child(collision_shape)
		armor_part.collision_layer = 1 << 1
		armor_part.collision_mask = 0
		armor_part.armor_system = armor_system
		armor_part.armor_path = path
		armor_part.ship = self
		node.get_parent().add_child(armor_part)
		armor_parts.append(armor_part)
		self.aabb = self.aabb.merge((node as StaticBody3D).get_aabb())
		# node.collision_layer = 1 << 1
		# node.collision_mask = 0
		if node.name == "Hull":
			hull = armor_part
			print("armor_part.collision_layer: ", armor_part.collision_layer)
			print("armor_part.collision_mask: ", armor_part.collision_mask)
		elif node.name == "Citadel":
			citadel = armor_part

	for child in node.get_children():
		enable_backface_collision_recursive(child)

func initialize_armor_system() -> void:
	"""Initialize the armor system - extract and load armor data"""
	# print("🛡️ Initializing armor system for ship...")

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

	# print("   Ship model: ", resolved_glb_path)
	# print("   Armor data: ", armor_json_path)

	# Check if armor JSON already exists
	if FileAccess.file_exists(armor_json_path):
		# print("   ✅ Found existing armor data, loading...")
		var success = armor_system.load_armor_data(armor_json_path)
		if success:
			pass
			# print("   ✅ Armor system initialized successfully")
		else:
			print("   ❌ Failed to load existing armor data")
	elif auto_extract_armor:
		# print("   🔧 No armor data found, extracting from GLB...")
		extract_and_load_armor_data(resolved_glb_path, armor_json_path)
	# else:
		# print("   ⚠️ No armor data found and auto-extraction disabled")

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
				# print("   📂 Resolved UID to path: ", resource_path)
				return resource_path
			else:
				# print("   ⚠️ UID resolved to non-GLB resource: ", resource_path)
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
	var extractor_script = load("res://src/armor/enhanced_armor_extractor_v2.gd")
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
