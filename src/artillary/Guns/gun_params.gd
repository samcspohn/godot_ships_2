# extends Moddable
@tool
extends TurretParams
class_name GunParams

# @export var reload_time: float
# @export var traverse_speed: float
@export var elevation_speed: float
# @export var _range: float
@export var shell1: ShellParams
@export var shell2: ShellParams

## Sigma and the dispersion ellipse, as a resource of its own so a whole line
## can share one set of values. See DispersionParams: the ellipse is authored at
## a reference range (20 km for a main battery), not at this gun's own range.
## The read-only "Dispersion At Max Range" row below the resource resolves those
## numbers against this gun's range.
@export var dispersion: DispersionParams = preload("res://src/artillary/Dispersion/default_main.tres"):
	set(value):
		_unwatch_dispersion()
		dispersion = value
		_watch_dispersion()

## Name of the transient inspector row; not stored, not a script variable, so it
## stays out of Moddable's copy plans and out of the .tres file.
const MAX_RANGE_DISPERSION := &"dispersion_at_max_range"


func _init() -> void:
	_watch_dispersion()


## The ellipse this gun actually throws at its own maximum range. The numbers on
## `dispersion` are quoted at that resource's reference range (20 km for a main
## battery) so a whole line can share one resource - which means they are NOT the
## spread this particular gun gets. This row is, so it is what to read when
## tuning range or dispersion.
func _get_property_list() -> Array[Dictionary]:
	return [{
		"name": MAX_RANGE_DISPERSION,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
		"usage": PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY,
	}]


func _get(property: StringName) -> Variant:
	if property != MAX_RANGE_DISPERSION:
		return null
	if dispersion == null:
		return "(no dispersion params)"
	var d: Vector2 = dispersion.dispersion_at_max_range(_range)
	return "%.0f x %.0f m   at %.1f km" % [d.x, d.y, _range / 1000.0]


## Editing the shared DispersionParams (or a curve on it) has to redraw the row
## above, and nothing propagates a sub-resource's change to its owner on its own.
func _watch_dispersion() -> void:
	if not Engine.is_editor_hint():
		return
	if dispersion != null and not dispersion.changed.is_connected(notify_property_list_changed):
		dispersion.changed.connect(notify_property_list_changed)
	notify_property_list_changed()


func _unwatch_dispersion() -> void:
	if Engine.is_editor_hint() and dispersion != null \
			and dispersion.changed.is_connected(notify_property_list_changed):
		dispersion.changed.disconnect(notify_property_list_changed)


func from_params(gun_params: GunParams) -> void:
	reload_time = gun_params.reload_time
	traverse_speed = gun_params.traverse_speed
	elevation_speed = gun_params.elevation_speed
	_range = gun_params._range
	shell1 = gun_params.shell1
	shell2 = gun_params.shell2
	dispersion = gun_params.dispersion

func to_dict() -> Dictionary:
	var d := _disp()
	return {
		"reload_time": reload_time,
		"traverse_speed": traverse_speed,
		"elevation_speed": elevation_speed,
		"range": _range,
		"shell1": {
			"speed": shell1.speed,
			"drag": shell1.drag,
			"damage": shell1.damage
		},
		"shell2": {
			"speed": shell2.speed,
			"drag": shell2.drag,
			"damage": shell2.damage
		},
		"sigma": d.sigma,
		"h_disp": d.h_disp,
		"v_disp": d.v_disp,
		"reference_range": d.reference_range
	}


## The dispersion block, creating a default one if this params has none. Only the
## numbers travel over the wire / through a Dictionary — the curves come from the
## resource both ends loaded out of the ship scene.
func _disp() -> DispersionParams:
	if dispersion == null:
		dispersion = DispersionParams.new()
	return dispersion

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()

	writer.put_float(reload_time)
	writer.put_float(traverse_speed)
	writer.put_float(elevation_speed)
	writer.put_float(_range)

	writer.put_float(shell1.speed)
	writer.put_float(shell1.drag)
	writer.put_float(shell1.damage)
	writer.put_float(shell1.penetration_modifier)

	writer.put_float(shell2.speed)
	writer.put_float(shell2.drag)
	writer.put_float(shell2.damage)
	writer.put_float(shell2.penetration_modifier)

	var d := _disp()
	writer.put_float(d.sigma)
	writer.put_float(d.h_disp)
	writer.put_float(d.v_disp)
	writer.put_float(d.reference_range)

	return writer.get_data_array()


func from_dict(d: Dictionary) -> void:
	reload_time = d.get("reload_time", 1)
	traverse_speed = d.get("traverse_speed", deg_to_rad(40))
	elevation_speed = d.get("elevation_speed", deg_to_rad(40))
	_range = d.get("range", 20)
	var s1 = d.get("shell1", {})
	# shell1 = ShellParams.new()
	shell1.speed = s1.get("speed", 820)
	shell1.drag = s1.get("drag", 0.00895)
	shell1.damage = s1.get("damage", 10000)
	var s2 = d.get("shell2", {})
	# shell2 = ShellParams.new()
	shell2.speed = s2.get("speed", 820)
	shell2.drag = s2.get("drag", 0.00895)
	shell2.damage = s2.get("damage", 10000)
	var disp := _disp()
	disp.sigma = d.get("sigma", 1.8)
	disp.h_disp = d.get("h_disp", 270.0)
	disp.v_disp = d.get("v_disp", 135.0)
	disp.reference_range = d.get("reference_range", DispersionParams.MAIN_REFERENCE_RANGE)

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	reload_time = reader.get_float()
	traverse_speed = reader.get_float()
	elevation_speed = reader.get_float()
	_range = reader.get_float()
	shell1.speed = reader.get_float()
	shell1.drag = reader.get_float()
	shell1.damage = reader.get_float()
	shell1.penetration_modifier = reader.get_float()
	shell2.speed = reader.get_float()
	shell2.drag = reader.get_float()
	shell2.damage = reader.get_float()
	shell2.penetration_modifier = reader.get_float()
	var disp := _disp()
	disp.sigma = reader.get_float()
	disp.h_disp = reader.get_float()
	disp.v_disp = reader.get_float()
	disp.reference_range = reader.get_float()
