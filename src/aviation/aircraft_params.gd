extends Moddable
class_name AircraftParams

@export var type: String = "Spotter"
@export var _range: float = 6000.0
@export var speed: float = 300.0
@export var turning_radius: float = 100.0
@export var spotting_range: float = 1000.0
@export var idle_radius: float = 1000.0
@export var radio_range: float = 8000.0
@export var altitude: float = 200.0
@export var ordnance_scene: PackedScene
@export var plane_scene: PackedScene

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_string(type)
	writer.put_double(_range)
	writer.put_double(speed)
	writer.put_double(spotting_range)
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	type = reader.get_string()
	_range = reader.get_double()
	speed = reader.get_double()
	spotting_range = reader.get_double()
