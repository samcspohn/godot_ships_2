class_name TorpedoLauncher
extends Turret

# Properties for editor
# @export var rotation_limits_enabled: bool = true
# @export var min_rotation_angle: float = deg_to_rad(45)
# @export var max_rotation_angle: float = deg_to_rad(180 + 45)

# var _aim_point: Vector3
# var reload: float = 0.0
# var can_fire: bool = false
# var muzzles: Array[Node3D] = []
# var gun_id: int
# var disabled: bool = true

# var max_range: float
# var max_flight: float
# var _ship: Ship

# @export var params: TorpedoLauncherParams
# var my_params: TorpedoLauncherParams = TorpedoLauncherParams.new()
func get_params() -> TorpedoLauncherParams:
	return controller.get_params()

func get_torp() -> TorpedoParams:
	return controller.get_torp_params()

func to_bytes(full: bool) -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(rotation.y)

	if full:
		writer.put_u8(1 if can_fire else 0)
		writer.put_u8(1 if _valid_target else 0)
		writer.put_float(reload)

	return writer.get_data_array()

func from_bytes(b: PackedByteArray, full: bool) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	rotation.y = reader.get_float()
	if full:
		can_fire = reader.get_u8() == 1
		_valid_target = reader.get_u8() == 1
		reload = reader.get_float()

func _ready() -> void:
	# my_params.from_params(params)
	# max_range = my_params._range
	# _ship = ProjectileManager.find_ship(self)
	#var a = ProjectilePhysicsWithDrag.calculate_absolute_max_range(my_params.shell.speed, my_params.shell.drag)
	#max_range = min(a[0], my_params._range)
	#max_flight = a[2]

	#if max_range < a[0]:
		#max_flight = ProjectilePhysicsWithDrag.calculate_launch_vector(Vector3.ZERO, Vector3(0, 0, max_range), my_params.shell.speed, my_params.shell.drag)[1]
		#
#
	#print("max range: ", a)

	# Set up muzzles
	update_barrels()

	# # Set processing mode based on authority
	# if _Utils.authority():
	# 	process_mode = Node.PROCESS_MODE_INHERIT
	# else:
	# 	# We still need to receive updates, just not run physics
	# 	process_mode = Node.PROCESS_MODE_INHERIT
	# 	set_physics_process(false)

	super._ready()
	#min_rotation_angle = deg_to_rad(90 - 60)
	#max_rotation_angle = deg_to_rad(270 + 60)

# Function to update barrels based on editor properties
func update_barrels() -> void:
	# Clear existing muzzles array
	muzzles.clear()

	# Set up muzzles from existing barrels
	for t in get_child(0).get_children():
		# if t.name.contains("Tube"):
		muzzles.append(t)

# @rpc("any_peer", "call_remote")
# func _set_reload(r):
# 	reload = r

func _physics_process(delta: float) -> void:
	if _Utils.authority():
		if !disabled && reload < 1.0:
			reload = min(reload + delta / get_params().reload_time, 1.0)

# Implement on server
func _aim(aim_point: Vector3, delta: float, return_to_base: bool = false) -> float:
	if disabled:
		return INF

	var desired_local_angle = super._aim(aim_point, delta, return_to_base)

	if abs(desired_local_angle) < 0.01:
		can_fire = true
	else:
		can_fire = false
	return desired_local_angle

@rpc("any_peer", "call_remote")
func fire() -> void:
	if _Utils.authority():
		if !disabled and reload >= 1.0 and can_fire:
			# Fire torpedo
			reload = 0.0
			can_fire = false
			var offset:Vector3 = -muzzles[0].global_basis.x * 0.012 * (float(muzzles.size() -1) / 2.0)
			for m in muzzles:
				#var dispersion_point = dispersion_calculator.calculate_dispersion_point(_aim_point, self.global_position)
				#var aim = ProjectilePhysicsWithDrag.calculate_launch_vector(m.global_position, dispersion_point, my_params.shell.speed, my_params.shell.drag)
				#if aim[0] != null:
				var t = float(Time.get_unix_time_from_system())
				var _id = (TorpedoManager as _TorpedoManager).fireTorpedo(-m.global_basis.z + offset,m.global_position, get_torp(), t, _ship, get_params()._range)
				#var id = ProjectileManager1.fireBullet(aim[0], m.global_position, my_params.shell, dispersion_point, aim[1], t)
				for p in multiplayer.get_peers():
					self.fire_client.rpc_id(p, m.global_position, -m.global_basis.z + offset, t, _id)
				offset += muzzles[0].global_basis.x * 0.012
					#self.fire_client.rpc_id(p, aim[0],m.global_position, t, aim[1], dispersion_point, id)
			reload = 0

@rpc("any_peer","reliable")
func fire_client(pos, vel, t, _id):
	(TorpedoManager as _TorpedoManager).fireTorpedoClient(pos, vel, t, _id, get_torp(), _ship)
