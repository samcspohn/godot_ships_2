extends WeaponController
class_name AviationController


@export var params: Array[AircraftParams] = [] # plane params
@export var launcher: Node3D

var squadrons: Array[Squadron] = []
var active_squadrons: Dictionary[int, bool] = {}
var aim_point: Vector3
var fire_held: bool = false
var attack_point = null
var aim_direction: Vector2 = Vector2.ZERO
# Client-local only (never touched by set_fire_held's RPC path) - tracks the
# drag anchor for the live drop-pattern preview independently of the
# server-authoritative attack_point above, since that one is only ever reset
# to null inside the authority-gated block below and would otherwise go stale
# on every peer but the server. See update_local_drag_state().
var _preview_anchor: Vector3 = Vector3.ZERO
var _preview_holding: bool = false

var game_world: Node3D

func _ready() -> void:
	multi_select = true
	_ship = get_parent().get_parent() as Ship
	game_world = _ship.get_parent() as Node3D
	# instantiate squadrons
	for i in range(params.size()):
		params[i] = params[i].instantiate(_ship) as AircraftParams
		tool_tips.append(func () -> String:
			var p = params[i].p()
			return "%s\nRange: %.1f\nSpeed: %.1f" % [p.type, p._range, p.speed]
		)
		button_names.append(params[i].type)

		var squadron := Squadron.new()
		squadron.setup(params[i], launcher, _ship, game_world)
		squadrons.append(squadron)

	shell_index = 0
	set_physics_process(true)
	set_process(true)


# Runs every physics tick (fixed rate). Ground/waypoint marker raycasts need
# the physics thread (PhysicsDirectSpaceState3D is unavailable during
# _process()), and flight simulation/attack commits need to stay in lockstep
# with update_flight delta - both remain here. The reticle/committed
# drop-pattern preview used to also live here, but it has no raycast
# dependency anymore (see Aircraft.make_flat_marker) and was visibly
# lagging behind the mouse since physics ticks and render frames are not
# 1:1 - it now runs in _process below instead.
func _physics_process(delta: float) -> void:
	for i in range(squadrons.size()):
		var squadron = squadrons[i]
		squadron._update_ground_indicator()
		squadron._update_waypoint_indicators()

	if not _Utils.authority():
		return

	if shell_index >= params.size():
		shell_index = 0

	for i in range(squadrons.size()):
		var squadron = squadrons[i]
		if not squadron.active:
			continue
		squadron.update_flight(delta, _ship)
		if squadron.all_finished_attack() or squadron.all_dead():
			recall_squadron(i)

	assert(multi_select)
	if attack_point != null and not fire_held: # release ordnance at drop point
		for sh_index in shell_indices:
			if sh_index >= squadrons.size():
				continue
			var squadron := squadrons[sh_index]
			aim_direction = _drag_direction(attack_point, aim_point, _direction_to(_ship.global_position, attack_point))
			squadron.set_attack(Vector2(attack_point.x, attack_point.z), aim_direction)
		attack_point = null
		aim_direction = Vector2.ZERO

# Runs every rendered frame (not gated to authority) so the drop-pattern
# preview tracks the mouse/aim_point smoothly instead of lagging behind at
# the physics tick rate. Purely visual - see Squadron.update_reticle_preview
# and Squadron.update_committed_attack_preview.
func _process(delta: float) -> void:
	super._process(delta)
	var is_local_selection: bool = _ship.control is PlayerController and _ship.control.current_weapon_controller == self
	for i in range(squadrons.size()):
		var squadron = squadrons[i]
		# always show drop-pattern preview allowing for drop point updates
		_update_drop_preview(squadron, is_local_selection and i in shell_indices)
		# show committed drop-pattern
		if squadron.attack_point != null:
			squadron.update_committed_attack_preview()
			# squadron.update_reticle_preview(false, Vector2.ZERO, Vector2.ZERO)

# Live aiming preview: while held (dragging out an attack), the pattern
# freezes at the point the drag started and rotates to track the drag
# direction, matching what will be committed on release (see
# update_local_drag_state() for how the anchor itself is tracked). Otherwise
# it just follows the cursor, facing away from the ship.
func _update_drop_preview(squadron: Squadron, show: bool) -> void:
	if not show:
		squadron.update_reticle_preview(false, Vector2.ZERO, Vector2.ZERO)
		return

	var center: Vector3
	var direction: Vector2
	if _preview_holding:
		center = _preview_anchor
		direction = _drag_direction(_preview_anchor, aim_point, _direction_to(_ship.global_position, _preview_anchor))
	else:
		center = aim_point
		direction = _direction_to(_ship.global_position, aim_point)
	squadron.update_reticle_preview(true, Vector2(center.x, center.z), direction)

# Called directly (not via rpc) by the local player's PlayerController every
# frame so the preview anchor updates instantly instead of waiting on a
# server round-trip. Purely client-side visual state - the actual attack
# commit still goes through set_fire_held()/attack_point below. On release
# the reticle immediately resumes following the cursor (see
# _update_drop_preview() above) rather than waiting on the server to
# confirm the attack - once it does (squadron.attack_point becomes
# non-null), the committed drop-pattern preview takes over instead (see
# _process() and Squadron.update_committed_attack_preview()).
func update_local_drag_state(holding: bool) -> void:
	if holding and not _preview_holding:
		_preview_anchor = aim_point
	_preview_holding = holding

# Direction of the current mouse drag away from `anchor`, or `fallback` if the
# drag hasn't moved far enough to be meaningful (e.g. a tap instead of a
# drag).
static func _drag_direction(anchor: Vector3, current: Vector3, fallback: Vector2) -> Vector2:
	var offset := Vector2(current.x - anchor.x, current.z - anchor.z)
	if offset.length() > 10.0:
		return offset.normalized()
	return fallback

static func _direction_to(from: Vector3, to: Vector3) -> Vector2:
	var offset := Vector2(to.x - from.x, to.z - from.z)
	if offset.length_squared() < 0.0001:
		return Vector2(0.0, 1.0)
	return offset.normalized()


func launch_squadron(index: int) -> void:
	if index >= squadrons.size():
		return
	squadrons[index].launch(game_world, launcher.global_position, launcher.global_rotation)
	active_squadrons[index] = true

func recall_squadron(index: int) -> void:
	if active_squadrons.has(index):
		squadrons[index].recall(launcher)
		active_squadrons.erase(index)

func ensure_launched(index: int) -> void:
	if index >= squadrons.size():
		return
	if not squadrons[index].active:
		launch_squadron(index)

func get_aim_ui() -> Dictionary:
	if active_squadrons.size() == 0:
		return {
			"terrain_hit": false,
			"penetration_power": 0.0,
			"time_to_target": 0.0
		}
	if shell_index >= params.size():
		shell_index = 0
	var squadron := squadrons[shell_index]
	var plane_params := params[shell_index]
	var dist = squadron.node.global_position.distance_to(aim_point)
	var speed: float = plane_params.p().speed
	var ui := {
		"terrain_hit": false,
		"penetration_power": 0.0,
		"time_to_target": dist / speed
	}
	return ui

func get_shell_params():
	return null

func get_params() -> AircraftParams:
	if shell_index >= params.size():
		return null
	return params[shell_index]

func get_max_range() -> float:
	return get_params()._range

func set_aim_input(point: Vector3) -> void:
	var ship_pos := _ship.global_position
	ship_pos.y = 0.0
	var offset := Vector3(point.x - ship_pos.x, 0.0, point.z - ship_pos.z)
	var max_range := get_max_range()
	if offset.length() > max_range:
		offset = offset.normalized() * max_range
	aim_point = ship_pos + offset

@rpc("any_peer", "call_remote")
func fire_all() -> void:
	pass

@rpc("any_peer", "call_remote")
func fire_next_ready() -> void:
	if not active_squadrons.has(shell_index):
		launch_squadron(shell_index)

# Sends the selected squadron to the current aim point without attacking;
# launches it first if it isn't airborne yet (mirrors fire_next_ready()).
# append lets the player queue up a multi-leg route (spacebar modifier)
# instead of replacing the current waypoint.
@rpc("any_peer", "call_remote")
func set_waypoint_at_aim(append: bool) -> void:
	for sh_index in shell_indices:
		if sh_index >= squadrons.size():
			continue
		if not active_squadrons.has(sh_index):
			launch_squadron(sh_index)
		squadrons[sh_index].set_waypoint(Vector2(aim_point.x, aim_point.z), append)

@rpc("any_peer", "call_remote")
func set_fire_held(held: bool) -> void:
	if !fire_held and held and attack_point == null:
		attack_point = aim_point
	fire_held = held



func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_u8(active_squadrons.size())
	for index in active_squadrons.keys():
		var squadron = squadrons[index]
		writer.put_u8(index)
		writer.put_u8(squadron.aircraft.size())
		writer.put_var(squadron.node.global_position)
		writer.put_var(squadron.node.global_rotation)
		writer.put_var(squadron.idle_pos)
		writer.put_var(squadron.attack_point)
		writer.put_var(squadron.attack_direction)
		writer.put_u8(1 if squadron.holding_attack else 0)
		writer.put_u8(1 if squadron.in_attack_run else 0)
		writer.put_u8(1 if squadron.returning else 0)
		writer.put_u8(1 if squadron.in_landing_approach else 0)
		writer.put_u8(squadron.waypoints.size())
		for wp in squadron.waypoints:
			writer.put_var(wp)
		for plane in squadron.aircraft:
			writer.put_var(plane.global_position)
			writer.put_var(plane.global_rotation)
			writer.put_u8(1 if plane.dead else 0)
		writer.put_var(params[index].to_bytes())
	return writer.data_array

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	for squadron in squadrons:
		for plane in squadron.aircraft:
			plane.visible = false

	var seen_indices: Dictionary[int, bool] = {}
	var active_count = reader.get_u8()
	for i in range(active_count):
		var index = reader.get_u8()
		seen_indices[index] = true
		var plane_count = reader.get_u8()
		var squadron_pos = reader.get_var()
		var squadron_rot = reader.get_var()
		var squadron_idle_pos = reader.get_var()
		var squadron_attack_point = reader.get_var()
		var squadron_attack_direction = reader.get_var()
		var squadron_holding_attack = reader.get_u8()
		var squadron_in_attack_run = reader.get_u8()
		var squadron_returning = reader.get_u8()
		var squadron_in_landing_approach = reader.get_u8()
		var squadron_waypoint_count = reader.get_u8()
		var squadron_waypoints: Array[Vector2] = []
		for w in range(squadron_waypoint_count):
			squadron_waypoints.append(reader.get_var())
		ensure_launched(index)
		var squadron = squadrons[index] if index < squadrons.size() else null
		if squadron != null:
			squadron.node.global_position = squadron_pos
			squadron.node.global_rotation = squadron_rot
			squadron.idle_pos = squadron_idle_pos
			squadron.holding_attack = squadron_holding_attack != 0
			squadron.attack_direction = squadron_attack_direction
			squadron.attack_point = squadron_attack_point
			squadron.in_attack_run = squadron_in_attack_run != 0
			squadron.returning = squadron_returning != 0
			squadron.in_landing_approach = squadron_in_landing_approach != 0
			squadron.waypoints = squadron_waypoints
		for j in range(plane_count):
			var plane_pos = reader.get_var()
			var plane_rot = reader.get_var()
			var plane_dead = reader.get_u8()
			if squadron != null and j < squadron.aircraft.size():
				var plane = squadron.aircraft[j]
				plane.global_position = plane_pos
				plane.global_rotation = plane_rot
				plane.dead = plane_dead != 0
				plane.visible = not plane.dead
		if index < params.size():
			var params_bytes = reader.get_var()
			params[index].from_bytes(params_bytes)

	# A squadron missing from this snapshot but still marked active locally
	# means the server recalled it since the last update - replicate that
	# cleanup here since active_squadrons/active_count only ever tells us
	# what's currently active, never what just stopped being active.
	for index in range(squadrons.size()):
		if not seen_indices.has(index) and squadrons[index].active:
			squadrons[index].recall(launcher)
			active_squadrons.erase(index)
