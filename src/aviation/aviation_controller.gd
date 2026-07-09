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

var game_world: Node3D

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship
	# instantiate squadrons
	for i in range(params.size()):
		params[i] = params[i].instantiate(_ship) as AircraftParams
		tool_tips.append(func () -> String:
			var p = params[i].p()
			return "%s\nRange: %.1f\nSpeed: %.1f" % [p.type, p._range, p.speed]
		)
		button_names.append(params[i].type)

		var squadron := Squadron.new()
		squadron.setup(params[i], launcher, _ship)
		squadrons.append(squadron)

	shell_index = 0
	game_world = _ship.get_parent() as Node3D
	set_physics_process(true)


# Called every physics tick. Runs on every peer (not gated to authority) so
# the ground/waypoint marker raycasts - which must happen on the physics
# thread, since PhysicsDirectSpaceState3D is unavailable during _process() -
# stay up to date everywhere; flight/attack logic below remains
# authority-only.
func _physics_process(delta: float) -> void:
	for squadron in squadrons:
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
		if squadron.all_finished_attack():
			recall_squadron(i)

	if attack_point != null and not fire_held and active_squadrons.has(shell_index): # release ordnance at drop point
		var squadron := squadrons[shell_index]
		var offset = aim_point - attack_point
		offset = Vector2(offset.x, offset.z)
		if offset.length() > 10.0:
			aim_direction = offset.normalized()
		else:
			# no meaningful aim offset (e.g. tapped fire without dragging); fall
			# back to the direction from the squadron to the attack point so the
			# spread doesn't collapse
			var to_target := Vector2(attack_point.x, attack_point.z) - Vector2(_ship.global_position.x, _ship.global_position.z)
			if to_target.length_squared() < 0.0001:
				aim_direction = Vector2(0.0, 1.0)
			else:
				aim_direction = to_target.normalized()

		squadron.set_attack(Vector2(attack_point.x, attack_point.z), aim_direction)
		attack_point = null
		aim_direction = Vector2.ZERO


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
	aim_point = point

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
	if not active_squadrons.has(shell_index):
		launch_squadron(shell_index)

	squadrons[shell_index].set_waypoint(Vector2(aim_point.x, aim_point.z), append)

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
		writer.put_var(params[index].to_bytes())
	return writer.data_array

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	for squadron in squadrons:
		for plane in squadron.aircraft:
			plane.visible = false

	var active_count = reader.get_u8()
	for i in range(active_count):
		var index = reader.get_u8()
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
			if squadron != null and j < squadron.aircraft.size():
				var plane = squadron.aircraft[j]
				plane.global_position = plane_pos
				plane.global_rotation = plane_rot
				plane.visible = true
		if index < params.size():
			var params_bytes = reader.get_var()
			params[index].from_bytes(params_bytes)
