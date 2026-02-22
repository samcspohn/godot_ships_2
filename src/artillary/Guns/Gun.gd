@tool
class_name Gun
extends Turret

# Properties for editor
# @export var rotation_limits_enabled: bool = true
# @export var min_rotation_angle: float = deg_to_rad(90)
# @export var max_rotation_angle: float = deg_to_rad(180)

@onready var barrel: Node3D = get_child(0).get_child(0)
var dispersion_calculator: DispersionCalculator
var sound: AudioStreamPlayer3D
@export_category("Sound")
@export var _sound: AudioStream
@export var pitch: float = 1.0
@export var volume: float = 1.0
@export var variance: float = 0.05
@export_tool_button("Preview Sound") var _preview_sound_button = _preview_sound
@export_tool_button("Stop Preview") var _stop_preview_sound_button = _stop_preview_sound
var preview_player: AudioStreamPlayer3D
var wake_template: ParticleTemplate
var _particle_system: UnifiedParticleSystem = null

func _preview_sound() -> void:
	if _sound == null:
		push_warning("No sound assigned to preview")
		return

	if preview_player != null:
		preview_player.stop()
		preview_player.queue_free()
		preview_player = null

	preview_player = AudioStreamPlayer3D.new()
	preview_player.stream = _sound
	preview_player.pitch_scale = pitch * randf_range(1.0 - variance, 1.0 + variance)
	preview_player.max_db = linear_to_db(volume * randf_range(1.0 - variance, 1.0 + variance))
	preview_player.volume_db = preview_player.max_db
	preview_player.unit_size = 100
	add_child(preview_player)
	preview_player.play()
	preview_player.finished.connect(preview_player.queue_free)

func _stop_preview_sound() -> void:
	if preview_player != null:
		preview_player.stop()
		preview_player.queue_free()
		preview_player = null

class SimShell:
	var start_position: Vector3 = Vector3.ZERO
	var position: Vector3 = Vector3.ZERO

var shell_sim: SimShell = SimShell.new()
var sim_shell_in_flight: bool = false

func to_dict() -> Dictionary:
	return {
		"r": basis,
		"e": barrel.basis,
		"c": can_fire,
		"v": _valid_target,
		"rl": reload
	}

func to_bytes(full: bool) -> PackedByteArray:
	var writer = StreamPeerBuffer.new()

	writer.put_float(rotation.y)

	writer.put_float(barrel.rotation.x)

	if full:
		writer.put_u8(1 if can_fire else 0)
		writer.put_u8(1 if _valid_target else 0)

		writer.put_float(reload)

	return writer.get_data_array()

func from_dict(d: Dictionary) -> void:
	basis = d.r
	barrel.basis = d.e
	can_fire = d.c
	_valid_target = d.v
	reload = d.rl

func from_bytes(b: PackedByteArray, full: bool) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b

	rotation.y = reader.get_float()

	barrel.rotation.x = reader.get_float()

	if not full:
		return
	can_fire = reader.get_u8() == 1
	_valid_target = reader.get_u8() == 1

	reload = reader.get_float()

func get_params() -> GunParams:
	return controller.get_params()

func get_shell() -> ShellParams:
	return controller.get_shell_params()

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if !_Utils.authority():
		var init = get_node("/root/ParticleSystemInit")
		wake_template = init.get_template_by_name("torpedo_wake")
	# 	if sound == null:
	# 		sound = AudioStreamPlayer3D.new()
	# 		if _sound == null:
	# 			sound.stream = preload("res://audio/explosion1.wav")
	# 		else:
	# 			sound.stream = _sound
	# 		sound.max_polyphony = 1
	# 		sound.unit_size = 200.0 * volume
	# 		sound.max_db = linear_to_db(volume * (1.0 + variance))
	# 		add_child(sound)
	# 	# get_tree().root.add_child(sound)
	setup_audio.call_deferred()


	# Set up muzzles
	update_barrels()

	super._ready()

func setup_audio():
	if Engine.is_editor_hint():
		return

	if !_Utils.authority():
		if sound == null:
			sound = AudioStreamPlayer3D.new()
			if _sound == null:
				sound.stream = preload("res://audio/explosion1.wav")
			else:
				sound.stream = _sound
			sound.max_polyphony = 4
			sound.unit_size = 100.0 * get_shell().caliber / 100.0 + 100.0
			sound.max_db = linear_to_db(volume * (1.0 + variance))
			var shell_params: ShellParams = get_shell()
			if shell_params._secondary:
				sound.bus = "Sec"
			else:
				sound.bus = "Main"
				# pitch *= 2.0
			add_child(sound)
		# get_tree().root.add_child(sound)


# Function to update barrels based on editor properties
func update_barrels() -> void:
	# Clear existing muzzles array
	muzzles.clear()

	# Check if barrel exists
	if not is_node_ready():
		# We might be in the editor, just return
		return

	for muzzle in barrel.get_children():
		# if muzzle.name.contains("Muzzle"):
		muzzles.append(muzzle)

	# print("Muzzles updated: ", muzzles.size())

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if _Utils.authority():
		if !disabled && reload < 1.0:
			reload = min(reload + delta / get_params().reload_time, 1.0)

func get_dist(target: Vector3) -> float:
	var dist = (target - _ship.global_position)
	dist.y = 0.0
	return dist.length() - 0.001

func valid_target(target: Vector3) -> bool:
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(global_position, target, get_shell())
	if sol[0] != null and get_dist(target) < get_params()._range:
		var desired_local_angle_delta: float = get_angle_to_target(target)
		var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
		if a[1]:
			return false
		return true
	return false

func get_leading_position(target: Vector3, target_velocity: Vector3):
	var sol = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(global_position, target, target_velocity, get_shell())
	if sol[0] != null and get_dist(sol[2]) < get_params()._range:
		return sol[2]
	return null

func valid_target_leading(target: Vector3, target_velocity: Vector3) -> bool:
	var sol = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(global_position, target, target_velocity, get_shell())
	if sol[0] != null and get_dist(sol[2]) < get_params()._range:
		var desired_local_angle_delta: float = get_angle_to_target(sol[2])
		var a = apply_rotation_limits(rotation.y, desired_local_angle_delta)
		if a[1]:
			return false
		return true
	return false

func get_muzzles_position() -> Vector3:
	var muzzles_pos: Vector3 = Vector3.ZERO
	for m in muzzles:
		muzzles_pos += m.global_position
	muzzles_pos /= muzzles.size()
	return muzzles_pos

# Implement on server
func _aim(aim_point: Vector3, delta: float, _return_to_base: bool = false) -> float:
	if disabled:
		return INF
	var desired_local_angle_delta = super._aim(aim_point, delta, _return_to_base) # rotate turret
	# # Calculate elevation
	var muzzles_pos = get_muzzles_position()

	# Existing aiming logic for elevation
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(muzzles_pos, aim_point, get_shell())
	if sol[0] != null and (aim_point - _ship.global_position).length() < get_params()._range:
		self._aim_point = aim_point
	else:
		var g = Vector3(global_position.x, 0, global_position.z)
		self._aim_point = g + (Vector3(aim_point.x, 0, aim_point.z) - g).normalized() * (get_params()._range - 500)
		sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(muzzles_pos, self._aim_point, get_shell())

	# launch_vector = sol[0]
	# flight_time = sol[1]

	var turret_elev_speed_rad: float = deg_to_rad(get_params().elevation_speed)
	var max_elev_angle: float = turret_elev_speed_rad * delta
	var elevation_delta: float = max_elev_angle
	var desired_elevation_delta: float = INF
	if _ship.name == "1":
			pass
	if sol[1] != -1:
		var barrel_dir = sol[0]
		# var elevation = Vector2(Vector2(barrel_dir.x, barrel_dir.z).length(), barrel_dir.y).normalized()
		# var curr_elevation = Vector2(Vector2(barrel.global_basis.z.x, barrel.global_basis.z.z).length(), -barrel.global_basis.z.y).normalized()
		var desired_elevation = atan2(barrel_dir.y, Vector2(barrel_dir.x, barrel_dir.z).length())
		var curr_elevation = atan2(-barrel.global_basis.z.y, Vector2(-barrel.global_basis.z.x, -barrel.global_basis.z.z).length())
		desired_elevation_delta = desired_elevation - curr_elevation
		# desired_elevation_delta = (-barrel.global_basis.z).signed_angle_to(barrel_dir.normalized(), barrel.global_basis.x)
		elevation_delta = clamp(desired_elevation_delta, -max_elev_angle, max_elev_angle)
	if sol[0] == null:

		elevation_delta = - max_elev_angle

	if !is_nan(elevation_delta):
		barrel.rotate(Vector3.RIGHT, elevation_delta)
	# barrel.rotation.x = clamp(barrel.rotation.x, deg_to_rad(-5), deg_to_rad(30))

	if abs(desired_elevation_delta) < 0.015 and abs(desired_local_angle_delta) < 0.02 and _valid_target:
		can_fire = true
	else:
		can_fire = false
	return desired_local_angle_delta


	# # Ensure we stay within allowed elevation range
	# barrel.rotation_degrees.x = clamp(barrel.rotation_degrees.x, -30, 10)

# Normalize angle to the range [-PI, PI]
func normalize_angle(angle: float) -> float:
	return wrapf(angle, -PI, PI)

func _aim_leading(aim_point: Vector3, vel: Vector3, delta: float):
	var muzzles_pos = get_muzzles_position()
	var sol = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(muzzles_pos, aim_point, vel, get_shell())
	if sol[0] == null or (aim_point - muzzles_pos).length() > get_params()._range:
		can_fire = false
		return
	_aim(sol[2], delta, true)


func fire(mod: TargetMod = null) -> void:
	if _Utils.authority():
		if !disabled && reload >= 1.0 and can_fire:
			var muzzles_pos = get_muzzles_position()
			for m in muzzles:
				# var dispersed_velocity = get_params().calculate_dispersed_launch(_aim_point, muzzles_pos, get_shell(), mod)
				var h_grouping = get_params().h_grouping * (mod.h_grouping if mod else 1.0)
				var v_grouping = get_params().v_grouping * (mod.v_grouping if mod else 1.0)
				var base_spread = get_params().base_spread * (mod.base_spread if mod else 1.0)
				var dispersed_velocity = dispersion_calculator.calculate_dispersed_launch(_aim_point, muzzles_pos, get_shell(), h_grouping, v_grouping, base_spread)
				# var aim = ProjectilePhysicsWithDrag.calculate_launch_vector(m.global_position, _aim_point, get_shell().speed, get_shell().drag)
				if dispersed_velocity != null:
					var t = Time.get_unix_time_from_system()
					var _id = ProjectileManager.fireBullet(dispersed_velocity, m.global_position, get_shell(), t, _ship)
					TcpThreadPool.send_fire_gun(id, dispersed_velocity, m.global_position, t, _id)
				else:
					pass
					# print(aim)
			_ship.concealment.bloom(get_params()._range)
			reload = 0

# @rpc("authority", "reliable")
func fire_client(vel, pos, t, _id):
	ProjectileManager.fireBulletClient(pos, vel, t, _id, get_shell(), _ship, true, barrel.global_basis)
	# sound.global_position = pos
	# var size_factor = get_shell().caliber * get_shell().caliber / 10000.0
	# 380 -> 14.44
	# 500 -> 25.0
	# 150 -> 2.25
	# 100 -> 1.0
	# var pitch_scale = 7.0 / size_factor
	# 6 / 25 = 0.24
	# 6 / 14.44 = 0.415
	# 6 / 2.25 = 2.66
	# 6 / 1 = 6.0
	# smaller shells need more variance than larger ones
	# var dispersion
	if get_viewport().get_audio_listener_3d().global_position.distance_to(global_position) < volume * 2000: # TODO, make unique to gun
		sound.pitch_scale = pitch * randf_range(1.0 - variance, 1.0 + variance)
		sound.volume_db = linear_to_db(volume * randf_range(1.0 - variance, 1.0 + variance))
		sound.unit_size = 100.0 * sqrt(get_shell().caliber / 100.0) + 100.0
		# if get_shell().caliber == 203:
		# 	sound.unit_size = 0
		sound.play()

	if wake_template != null:
		if _particle_system == null:
			var init = get_node("/root/ParticleSystemInit")
			_particle_system = init.get_particle_system()
		var wake_pos = pos
		wake_pos.y = 0.01
		var size = get_shell().caliber / 100.0
		size = size ** 2 * 2.0
		var dir = vel
		dir.y = 0.0
		wake_pos = wake_pos + dir.normalized() * size / 2.0
		var time_mod = lerp(3.0, 1.2, size / 50)
		# print(size)
		# dir = dir.normalized()
		_particle_system.emit_particles(wake_pos, dir, wake_template.template_id, size, 1, time_mod)

func sim_can_shoot_over_terrain(aim_point: Vector3) -> bool:

	var muzzles_pos = get_muzzles_position()
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(muzzles_pos, aim_point, get_shell())
	if sol[0] == null:
		return false
	var launch_vector = sol[0]
	var flight_time = sol[1]
	var can_shoot = sim_can_shoot_over_terrain_static(muzzles_pos, launch_vector, flight_time, get_shell(), _ship)
	return can_shoot.can_shoot_over_terrain and can_shoot.can_shoot_over_ship

class ShootOver:
	var can_shoot_over_terrain: bool
	var can_shoot_over_ship: bool

	func _init(_terrain: bool, _ship: bool):
		can_shoot_over_terrain = _terrain
		can_shoot_over_ship = _ship

static func sim_can_shoot_over_terrain_static(
	pos: Vector3,
	launch_vector: Vector3,
	flight_time: float,
	shell_params: ShellParams,
	ship: Ship
) -> ShootOver:
	flight_time = min(flight_time, 100)
	var shell_sim_position: Vector3 = pos
	var space_state = Engine.get_main_loop().get_root().get_world_3d().direct_space_state
	var ray = PhysicsRayQueryParameters3D.new()
	ray.collide_with_bodies = true
	ray.collision_mask = 1 | (1 << 1) | (1 << 3) # Collide with terrain | armor | water
	var t = 0.5
	while t < flight_time + 0.5:
		ray.from = shell_sim_position
		ray.to = ProjectilePhysicsWithDragV2.calculate_position_at_time(
			pos,
			launch_vector,
			t,
			shell_params,
		)
		var result = space_state.intersect_ray(ray)
		if not result.is_empty():
			if result.has("collider") and result["collider"] is ArmorPart:
				var armor_part: ArmorPart = result["collider"] as ArmorPart
				if armor_part.ship.team.team_id != ship.team.team_id:
					return ShootOver.new(true, true)
				elif armor_part.ship == ship:
					# Hitting own ship, ignore
					pass
				elif armor_part.ship.team.team_id == ship.team.team_id:
					return ShootOver.new(true, false)
					# return false # dont hit friendly ships
				# var armor_part: ArmorPart = result["collider"] as ArmorPart
				# if armor_part.ship.team.team_id != ship.team.team_id:
				# 	return true
				# elif armor_part.ship.team.team_id == ship.team.team_id:
				# 	return false # dont hit friendly ships
				# elif armor_part.ship == ship:
				# 	# Hitting own ship, ignore
				# 	pass
			elif result["position"].y > 0.00001: # Hit terrain
				return ShootOver.new(false, true)
		shell_sim_position = ray.to
		t += 0.5
	return ShootOver.new(true, true)
