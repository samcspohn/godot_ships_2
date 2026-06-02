@tool
class_name Gun
extends Turret

# Properties for editor
# @export var slew_limits_enabled: bool = true
# @export var slew_min_angle: float = deg_to_rad(90)
# @export var slew_max_angle: float = deg_to_rad(180)

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
var wake_template: ParticleTemplate = preload("res://src/particles/templates/torpedo_wake_template.tres")

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

# Toggle via PlayerController (F11). When enabled, every server-side Gun._aim
# that has reload>=1.0 but can_fire=false logs the exact gate that denied firing
# (azimuth, validity, elevation, snap). Server-only print.
static var debug_fire_log: bool = false
# Optional ship-name filter (set to "" to log all ships). Use the authoritative
# ship name as it appears server-side (typically the multiplayer peer id).
static var debug_fire_log_ship: String = ""

const MIN_ELEVATION_ANGLE: float = deg_to_rad(-5)
var _max_elevation_angle: float = NAN  # lazily cached; NAN = not yet computed

func _get_max_elevation_angle() -> float:
	if is_nan(_max_elevation_angle):
		var max_range: float = get_params()._range
		var muzzles_pos: Vector3 = get_muzzles_position()
		# Shoot at max range on a flat plane to find the required elevation angle.
		var max_range_target: Vector3 = muzzles_pos + Vector3(max_range, 0, 0)
		var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(muzzles_pos, max_range_target, get_shell())
		assert(sol[0] != null, "Gun._get_max_elevation_angle: no valid launch solution for max range — check shell params and _range")
		var dir: Vector3 = sol[0]
		_max_elevation_angle = atan2(dir.y, Vector2(dir.x, dir.z).length())
	return _max_elevation_angle

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

func get_base_params() -> GunParams:
	return controller.get_base_params()

func get_shell() -> ShellParams:
	return controller.get_shell_params() # did you setup the secondary subcontroller(s)/ artillery controller?

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	setup_audio.call_deferred()
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
		return is_angle_in_fire_arcs(rotation.y + desired_local_angle_delta)
	return false

func get_leading_position(target: Vector3, target_velocity: Vector3, range_check_target_pos: bool = false):
	var sol = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(global_position, target, target_velocity, get_shell())
	if sol[0] == null:
		return null
	# When range_check_target_pos is true, the gun's _range is checked against the
	# target's current position instead of the computed lead position. This lets
	# callers (e.g. secondary battery) engage targets that are in range even when
	# their lead position falls just outside the gun's max range. Defaults to false
	# so main-gun / bot logic keeps its stricter behavior.
	var dist_check_pos: Vector3 = target if range_check_target_pos else sol[2]
	if get_dist(dist_check_pos) < get_params()._range:
		return sol[2]
	return null

func valid_target_leading(target: Vector3, target_velocity: Vector3) -> bool:
	var sol = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(global_position, target, target_velocity, get_shell())
	if sol[0] != null and get_dist(sol[2]) < get_params()._range:
		var desired_local_angle_delta: float = get_angle_to_target(sol[2])
		return is_angle_in_fire_arcs(rotation.y + desired_local_angle_delta)
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
	# Capture pre-rotation diagnostics so we can detect long-way-around slewing
	# and dead-zone snaps after super._aim runs.
	var _dbg_active: bool = debug_fire_log and (debug_fire_log_ship == "" or _ship.name == debug_fire_log_ship)
	var _dbg_pre_rot_y: float = rotation.y
	var _dbg_desired_pre: float = 0.0
	var _dbg_max_delta: float = 0.0
	var _dbg_adjusted: float = 0.0
	var _dbg_blocked: bool = false
	var _dbg_case: String = ""
	var _dbg_arc: float = 0.0
	var _dbg_off: float = 0.0
	var _dbg_target_off: float = 0.0
	if _dbg_active:
		_dbg_desired_pre = get_angle_to_target(aim_point)
		_dbg_max_delta = deg_to_rad(get_params().traverse_speed) * delta
		var _dbg_a = apply_rotation_limits(rotation.y, _dbg_desired_pre)
		_dbg_adjusted = _dbg_a[0]
		_dbg_blocked = _dbg_a[1]
		_dbg_case = _dbg_a[2]
		_dbg_arc = wrapf(slew_max_angle - slew_min_angle, 0.0, TAU)
		_dbg_off = wrapf(rotation.y - slew_min_angle, 0.0, TAU)
		_dbg_target_off = wrapf(_dbg_off + _dbg_desired_pre, 0.0, TAU)

	super._aim(aim_point, delta, _return_to_base) # rotate turret
	# Recompute post-rotation azimuth error so the grace window is checked against
	# the remaining error *after* this frame's movement, not before.
	var desired_local_angle_delta := get_angle_to_target(aim_point)
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
	# Pre-rotation copy of desired_elevation_delta. Used below to detect that the
	# barrel was rate-limited toward the target this frame — i.e. it physically
	# can't elevate fast enough to fully close the residual in one step.
	var desired_elevation_delta_pre: float = INF
	if _ship.name == "1":
			pass
	var desired_elevation: float = NAN
	if sol[1] != -1:
		var barrel_dir = sol[0]
		desired_elevation = atan2(barrel_dir.y, Vector2(barrel_dir.x, barrel_dir.z).length())
		var curr_elevation = atan2(-barrel.global_basis.z.y, Vector2(-barrel.global_basis.z.x, -barrel.global_basis.z.z).length())
		desired_elevation_delta = desired_elevation - curr_elevation
		desired_elevation_delta_pre = desired_elevation_delta
		elevation_delta = clamp(desired_elevation_delta, -max_elev_angle, max_elev_angle)
	if sol[0] == null:

		elevation_delta = - max_elev_angle

	if !is_nan(elevation_delta):
		barrel.rotate(Vector3.RIGHT, elevation_delta)

	# Clamp elevation: never depress below -5°; never elevate beyond max-range angle.
	barrel.rotation.x = clamp(barrel.rotation.x, MIN_ELEVATION_ANGLE, _get_max_elevation_angle())

	# Recompute elevation error against the barrel's post-rotation state so the
	# grace window is checked against the remaining error after this frame's movement.
	if not is_nan(desired_elevation):
		var curr_elevation_after = atan2(-barrel.global_basis.z.y, Vector2(-barrel.global_basis.z.x, -barrel.global_basis.z.z).length())
		desired_elevation_delta = desired_elevation - curr_elevation_after

	# Elevation is "satisfied" when aimed closely enough, OR when the barrel is pinned
	# at a physical hard-stop (min depression or max elevation) and ship roll is
	# creating world-frame error in that same direction — fire anyway since the
	# shell uses aim_point, not barrel orientation.
	var at_min_depression: bool = barrel.rotation.x <= MIN_ELEVATION_ANGLE + 0.001 and desired_elevation_delta < 0
	var at_max_elevation: bool = barrel.rotation.x >= _get_max_elevation_angle() - 0.001 and desired_elevation_delta > 0

	# Ship roll/pitch during a turn rotates the barrel's world-frame elevation
	# (curr_elevation is read from barrel.global_basis), but the barrel's local
	# elevation only rotates at elevation_speed. When that rate can't keep up
	# with world-frame roll, the residual settles into a non-zero steady-state
	# lag that exceeds the 0.015 grace window — this stalls firing during turns,
	# especially at longer ranges where the ballistic curve is steeper.
	#
	# The actual shell is launched from _aim_point via the dispersion calculator,
	# not from the visual barrel direction (see fire()), so visual barrel lag
	# does not affect shell accuracy. Allow firing when the barrel is rate-
	# limited toward the target this frame, capped at a tolerable visual error.
	var chasing_at_rate: bool = (
		desired_elevation_delta_pre != INF
		and abs(desired_elevation_delta_pre) > max_elev_angle
		and sign(elevation_delta) == sign(desired_elevation_delta_pre)
		and abs(desired_elevation_delta) < 0.05  # ~2.86° visual misalignment cap
	)
	var elevation_satisfied: bool = desired_elevation_delta != INF and (
		abs(desired_elevation_delta) < 0.015
		or at_min_depression
		or at_max_elevation
		or chasing_at_rate
	)

	if elevation_satisfied and abs(desired_local_angle_delta) < 0.02 and _valid_target:
		can_fire = true
	else:
		can_fire = false

	if _dbg_active and reload >= 1.0 and not can_fire:
		# Reload-complete guns that won't fire — this is exactly the symptom the
		# user reports. Log every gate so we can see which one denied firing.
		var _dbg_rot_delta_applied: float = wrapf(rotation.y - _dbg_pre_rot_y, -PI, PI)
		var _dbg_long_way: bool = abs(_dbg_adjusted) > abs(_dbg_desired_pre) + 0.001 and sign(_dbg_adjusted) != sign(_dbg_desired_pre)
		var _dbg_in_range: bool = (aim_point - _ship.global_position).length() < get_params()._range
		print({
			"ship": _ship.name,
			"gun": name,
			"traverse_dps": get_params().traverse_speed,
			"ship_omega_y": _ship.angular_velocity.y if _ship is RigidBody3D else 0.0,
			# Azimuth gates
			"desired_pre": _dbg_desired_pre,
			"desired_post": desired_local_angle_delta,
			"azimuth_ok": abs(desired_local_angle_delta) < 0.02,
			# Slew-limit forensics
			"rotation_y": _dbg_pre_rot_y,
			"slew_min": slew_min_angle,
			"slew_max": slew_max_angle,
			"arc": _dbg_arc,
			"off": _dbg_off,
			"target_off": _dbg_target_off,
			"case": _dbg_case,
			"max_delta": _dbg_max_delta,
			"adjusted": _dbg_adjusted,
			"blocked": _dbg_blocked,
			"long_way": _dbg_long_way,
			"applied": _dbg_rot_delta_applied,
			# Fire arc / validity
			"valid_target": _valid_target,
			# Elevation gates
			"elevation_ok": elevation_satisfied,
			"chasing_at_rate": chasing_at_rate,
			"desired_elev_delta_pre": desired_elevation_delta_pre,
			"desired_elev_delta": desired_elevation_delta,
			"max_elev_angle": max_elev_angle,
			"at_min_depression": at_min_depression,
			"at_max_elevation": at_max_elevation,
			"barrel_x": barrel.rotation.x,
			# Range / ballistic
			"in_range": _dbg_in_range,
			"sol_ok": sol[0] != null,
		})
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
			var first_shell := true
			for m in muzzles:
				# var dispersed_velocity = get_params().calculate_dispersed_launch(_aim_point, muzzles_pos, get_shell(), mod)
				var grouping = get_params().grouping * (mod.grouping if mod else 1.0)
				var h_spread = get_params().h_spread * (mod.h_spread if mod else 1.0)
				var v_spread = get_params().v_spread * (mod.v_spread if mod else 1.0)
				var dispersed_velocity = dispersion_calculator.calculate_dispersed_launch(_aim_point, muzzles_pos, get_shell(), grouping, grouping, h_spread, v_spread, get_params()._range)
				# var aim = ProjectilePhysicsWithDrag.calculate_launch_vector(m.global_position, _aim_point, get_shell().speed, get_shell().drag)
				if dispersed_velocity != null:
					var t = ProjectileManager.get_current_time()
					var _id = ProjectileManager.fireBullet(dispersed_velocity, m.global_position, get_shell(), t, _ship)
					# --- replay hook ---
					var _gun_index: int = controller.guns.find(self) if controller else -1
					ReplayRecorder.record_shell_fired(
							_ship, _gun_index, muzzles.find(m),
							m.global_position, dispersed_velocity, t, get_shell(),
							ProjectileManager.get_last_shell_uid())
					TcpThreadPool.send_display_shell(_id, m.global_position, dispersed_velocity, t, get_shell(), self, first_shell)
					first_shell = false
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
		var wake_pos = pos
		wake_pos.y = 0.01
		var size = get_shell().caliber / 100.0
		size = size ** 2 * 2.0
		var dir = vel
		dir.y = 0.0
		wake_pos = wake_pos + dir.normalized() * size / 2.0
		var time_mod = lerp(3.0, 1.2, size / 50)
		wake_template.emit(wake_pos, dir, size, 1, time_mod)

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
	var space_state = Engine.get_main_loop().get_root().get_world_3d().direct_space_state

	# Exclude own ship's OBB from the broadphase ray so we don't block on ourselves.
	var exclude_rids: Array = []
	if PrecisionPhysicsWorld != null:
		var entry: Dictionary = PrecisionPhysicsWorld.get_ship_entry(ship)
		if not entry.is_empty():
			exclude_rids.append(entry["obb_body"].get_rid())

	# Delegate the heavy loop to C++:
	#   - Terrain: zero-cost height-grid lookup via NavigationMap (no physics queries)
	#   - Ships:   single segment ray per step against OBB broadphase layer (1 << 4)
	var result: Dictionary = ProjectilePhysicsWithDragV2.sim_can_shoot_over_terrain(
		pos,
		launch_vector,
		flight_time,
		shell_params,
		NavigationMapManager.get_map(),
		space_state,
		exclude_rids
	)

	# Terrain blocked the shot.
	if result["terrain_blocked"]:
		return ShootOver.new(false, true)

	# An OBB was hit — resolve team identity in GDScript.
	if result["obb_hit"]:
		var collider = result["obb_collider"]
		if collider != null and PrecisionPhysicsWorld != null:
			var hit_ship: Ship = PrecisionPhysicsWorld.get_ship_from_obb(collider)
			if hit_ship != null:
				if hit_ship.team.team_id != ship.team.team_id:
					# Enemy ship is in the flight path — firing is allowed.
					return ShootOver.new(true, true)
				else:
					# Friendly ship is in the flight path — do not fire.
					return ShootOver.new(true, false)

	# Nothing blocked the trajectory.
	return ShootOver.new(true, true)
