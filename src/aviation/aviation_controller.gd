extends Node
class_name AviationController


@export var params: Array[AircraftParams] = [] # plane params
@export var launcher: Node3D
# @export var planes: Array[Node3D] = []

var aircraft: Array[Node3D] = []
var active_planes: Dictionary[int, bool] = {}
var plane_index: int = 0
var _ship: Ship
var aim_point: Vector3
var fire_held: bool = false
var ordanance_drop_point = null
var aim_direction: Vector2 = Vector2.ZERO

var game_world: Node3D
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# pass # Replace with function body.
	_ship = get_parent().get_parent() as Ship
	# instantiate planes
	for i in range(params.size()):
		params[i] = params[i].instantiate(_ship) as AircraftParams
		var plane_scene = params[i].plane_scene.instantiate()
		if plane_scene:
			#var plane_instance = plane_scene.instantiate() as Node3D
			plane_scene.visible = false
			plane_scene.params = params[i]
			plane_scene._ship = _ship
			launcher.add_child(plane_scene)
			plane_scene.position = Vector3.ZERO
			aircraft.append(plane_scene)

	plane_index = 0
	game_world = _ship.get_parent() as Node3D
	if _Utils.authority():
		set_physics_process(true)
	else:
		set_physics_process(false)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if not _Utils.authority():
		return

	if plane_index >= params.size():
		plane_index = 0
	if ordanance_drop_point != null and not fire_held and active_planes.has(plane_index): # release ordnance at drop point
		var offset = aim_point - ordanance_drop_point
		offset = Vector2(offset.x, offset.z)
		if offset.length() > 1:
			aim_direction = offset.normalized()
		else:
			aim_direction = Vector2.ZERO

		var plane = aircraft[plane_index]
		var plane_params = plane.params.p() as AircraftParams
		if plane.has_method("drop_ordnance"):
			plane.call("drop_ordnance", ordanance_drop_point, aim_direction, plane_params)
		ordanance_drop_point = null
		aim_direction = Vector2.ZERO


func launch_plane(index: int):
	if index >= params.size():
		return
	var plane = launcher.get_child(index) as Node3D
	if plane:
		plane.visible = true
		active_planes[index] = true
		# place in game world
		plane.reparent(game_world)
		plane.global_position = launcher.global_position

func recall_plane(index: int):
	if active_planes.has(index):
		var plane = aircraft[index]
		plane.reparent(launcher)
		plane.position = Vector3.ZERO
		active_planes.erase(index)

func ensure_launched(index: int):
	if index >= params.size():
		return
	if game_world != aircraft[index].get_parent():
		launch_plane(index)

func get_weapon_ui() -> Array:
	var buttons := []
	for i in range(params.size()):
		var btn = Button.new()
		btn.text = params[i].type
		btn.set_meta("tooltip_provider", func() -> String:
			var p = params[i]
			return "%s\nRange: %.1f\nSpeed: %.1f" % [p.type, p._range, p.speed]
		)
		btn.pressed.connect(func(idx=i):
			_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
			select_shell(idx)
		)
		buttons.append(btn)
	return buttons

func get_aim_ui() -> Dictionary:
	if active_planes.size() == 0:
		return {
			"terrain_hit": false,
			"penetration_power": 0.0,
			"time_to_target": 0.0
		}
	if plane_index >= active_planes.size():
		plane_index = 0
	var plane := aircraft[plane_index]
	# var ship_position = _ship.global_position
	var plane_params := params[plane_index]
	var dist = plane.global_position.distance_to(aim_point)
	var speed := plane_params.speed
	var ui := {
		"terrain_hit": false,
		"penetration_power": 0.0,
		"time_to_target": dist / speed
	}
	return ui

func get_shell_params():
	return null

func get_params() -> AircraftParams:
	if plane_index >= params.size():
		return null
	return params[plane_index]

func get_max_range() -> float:
	return get_params()._range

func set_aim_input(point: Vector3) -> void:
	aim_point = point

@rpc("any_peer", "call_remote")
func fire_all() -> void:
	pass

@rpc("any_peer", "call_remote")
func fire_next_ready() -> void:
	# print("setting ordanance drop point to ", aim_point)
	if not active_planes.has(plane_index):
		launch_plane(plane_index)

	if ordanance_drop_point == null:
		ordanance_drop_point = aim_point

@rpc("any_peer", "call_remote")
func select_shell(_shell_index: int) -> void:
	if !(_Utils.authority()):
		return
	plane_index = _shell_index

@rpc("any_peer", "call_remote")
func set_fire_held(held: bool) -> void:
	fire_held = held

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_u8(active_planes.size())
	for plane_index in active_planes.keys():
		writer.put_u8(plane_index)
		writer.put_var(aircraft[plane_index].global_position)
		writer.put_var(aircraft[plane_index].global_rotation)
		writer.put_var(params[plane_index].to_bytes())
	return writer.data_array

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	var active_count = reader.get_u8()
	for plane in aircraft:
		plane.visible = false

	for i in range(active_count):
		var plane_index = reader.get_u8()
		var plane_pos = reader.get_var()
		var plane_rot = reader.get_var()
		var plane_params_bytes = reader.get_var()
		if plane_index < aircraft.size():
			var plane = aircraft[plane_index]
			ensure_launched(plane_index)
			plane.global_position = plane_pos
			plane.global_rotation = plane_rot
			plane.visible = true
			params[plane_index].from_bytes(plane_params_bytes)
